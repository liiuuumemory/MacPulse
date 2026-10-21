import Foundation
import Security
import LocalAuthentication
import SQLite3
import CryptoKit

/// Read-only account queries. No credential or response body is persisted or logged.
final class QuotaClient: NSObject, URLSessionTaskDelegate {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12; c.timeoutIntervalForResource = 15
        c.httpCookieStorage = nil; c.urlCache = nil
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward account credentials to a redirected origin.
    }
    private final class Response: @unchecked Sendable {
        var data: Data?; var status: Int?; var failed = false
    }
    private func get(_ url: URL, headers: [String: String]) -> Result<[String: Any], QueryError> {
        guard url.scheme == "https", url.user == nil, url.password == nil else { return .failure(.message("账户查询需要 HTTPS 地址")) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"; request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MacPulse/1.6", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let result = Response(), done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            result.data = data; result.status = (response as? HTTPURLResponse)?.statusCode; result.failed = error != nil
            done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + 16) == .success else { task.cancel(); return .failure(.message("额度查询超时，请稍后刷新")) }
        guard !result.failed else { return .failure(.message("暂时无法连接额度服务")) }
        guard result.status == 200 else {
            switch result.status {
            case 401: return .failure(.message("登录已过期，请在原应用重新登录"))
            case 403: return .failure(.message("服务商拒绝了额度查询（403）"))
            case 404: return .failure(.message("服务商未提供兼容的额度接口"))
            case 429: return .failure(.message("查询过于频繁，5 分钟后重试"))
            default: return .failure(.message("额度服务暂不可用（\(result.status ?? 0)）"))
            }
        }
        guard let data = result.data, data.count <= 2 * 1024 * 1024, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.message("额度响应格式无法识别")) }
        return .success(object)
    }
    enum QueryError: Error { case message(String); var text: String { switch self { case .message(let s): return s } } }
    private func object(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), data.count < 2 * 1024 * 1024 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    private func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    private func codexBase(_ text: String) -> URL? {
        guard let provider = capture("^model_provider\\s*=\\s*\"([^\"]+)\"", text) else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: provider)
        guard let section = capture("(?s)\\[model_providers\\.\"?" + escaped + "\"?\\]([^\\[]*)", text), let raw = capture("^base_url\\s*=\\s*\"([^\"]+)\"", section) else { return nil }
        return URL(string: raw)
    }
    private func fingerprint(_ token: String, source: String) -> String {
        source + ":" + SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    private func switchKey(base: URL) -> String? {
        let file = home.appendingPathComponent(".cc-switch/cc-switch.db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT settings_config FROM providers WHERE app_type='codex' AND is_current=1 LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0), let data = String(cString: raw).data(using: .utf8), let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = settings["config"] as? String,
              let savedBase = codexBase(text), savedBase.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              let auth = settings["auth"] as? [String: Any] else { return nil }
        return auth["OPENAI_API_KEY"] as? String
    }
    func codex() -> AccountQuota {
        let text = (try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"))) ?? ""
        let auth = object(home.appendingPathComponent(".codex/auth.json")) ?? [:]
        if let base = codexBase(text), let host = base.host, !["api.openai.com", "chatgpt.com"].contains(host) {
            var result = AccountQuota(account: host)
            if let url = URL(string: "https://" + host) { result.website = url }
            guard base.scheme == "https", base.query == nil, base.fragment == nil else { result.error = "服务商地址无法用于安全查询"; return result }
            guard let key = (auth["OPENAI_API_KEY"] as? String) ?? switchKey(base: base), !key.isEmpty else { result.error = "未找到当前服务商的查询凭据"; return result }
            result.identity = fingerprint(key, source: base.absoluteString)
            switch get(base.appendingPathComponent("usage"), headers: ["Authorization": "Bearer " + key]) {
            case .success(let object): return Self.sub2api(object, base: result)
            case .failure(let error): result.error = error.text; return result
            }
        }
        var result = AccountQuota(account: "ChatGPT / Codex")
        guard let tokens = auth["tokens"] as? [String: Any], let access = tokens["access_token"] as? String, !access.isEmpty else { result.error = "未找到可读取的 Codex 登录"; return result }
        result.identity = fingerprint(access, source: "chatgpt.com")
        var headers = ["Authorization": "Bearer " + access]
        if let id = tokens["account_id"] as? String { headers["ChatGPT-Account-Id"] = id }
        switch get(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers) {
        case .success(let object): return Self.codexQuota(object, base: result)
        case .failure(let error): result.error = error.text; return result
        }
    }
    /// Shown when only the Claude desktop app is signed in: its token sits in the app's own encrypted
    /// storage, which MacPulse does not open. The command-line Claude Code keeps a readable login.
    static let desktopOnlyMessage = "Claude 桌面版的登录由桌面应用加密保存，无法读取；安装命令行版 Claude Code 并登录一次即可显示额度"

    func claude(allowPrompt: Bool) -> AccountQuota {
        var result = AccountQuota(account: "Claude", website: URL(string: "https://claude.ai/settings/usage")!)
        let profile = object(home.appendingPathComponent(".claude.json"))?["oauthAccount"] as? [String: Any]
        if let type = profile?["organizationType"] as? String {
            result.account = type.replacingOccurrences(of: "claude_", with: "Claude ").capitalized
        }
        var credentials = object(home.appendingPathComponent(".claude/.credentials.json"))
        var keychainMissing = false
        if credentials == nil {
            let context = LAContext(); context.interactionNotAllowed = !allowPrompt
            var item: CFTypeRef?
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Claude Code-credentials",
                                       kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                                       kSecUseAuthenticationContext as String: context]
            // LAContext alone does not silence the login keychain's ACL prompt; this does.
            if !allowPrompt { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data { credentials = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            else if status == errSecInteractionNotAllowed || status == errSecAuthFailed { result.error = "请在 AI 用量设置中连接 Claude 账户"; return result }
            keychainMissing = status == errSecItemNotFound
        }
        guard let oauth = credentials?["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String, !token.isEmpty else {
            // Signed in (the account profile exists) but no command-line login anywhere: the desktop app holds it.
            let desktop = FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Claude").path)
            result.error = keychainMissing && profile != nil && desktop ? Self.desktopOnlyMessage : "需要 Claude Code 登录，或设置自定义额度"
            return result
        }
        result.identity = fingerprint(token, source: "api.anthropic.com")
        if let expires = Self.number(oauth["expiresAt"]), expires / 1000 < Date().timeIntervalSince1970 { result.error = "Claude 登录已过期，请在原应用重新登录"; return result }
        switch get(URL(string: "https://api.anthropic.com/api/oauth/usage")!, headers: ["Authorization": "Bearer " + token, "anthropic-beta": "oauth-2025-04-20"]) {
        case .success(let object): return Self.claudeQuota(object, base: result)
        case .failure(let error): result.error = error.text; return result
        }
    }
    /// Public Statuspage summary; carries no credentials or local data.
    func status(_ provider: AIProvider) -> ServiceStatus? {
        let url = URL(string: provider == .codex ? "https://status.openai.com/api/v2/status.json" : "https://status.claude.com/api/v2/status.json")!
        guard case .success(let object) = get(url, headers: [:]) else { return nil }
        return Self.serviceStatus(object)
    }
    static func serviceStatus(_ object: [String: Any]) -> ServiceStatus? {
        guard let status = object["status"] as? [String: Any], let indicator = status["indicator"] as? String else { return nil }
        return ServiceStatus(indicator: indicator, description: status["description"] as? String ?? "", fetchedAt: Date())
    }
    static func number(_ object: Any?) -> Double? {
        let value = (object as? NSNumber)?.doubleValue ?? (object as? String).flatMap(Double.init)
        guard let value, value.isFinite else { return nil }; return value
    }
    static func date(_ object: Any?) -> Date? {
        if let number = object as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let string = object as? String else { return nil }
        let f = ISO8601DateFormatter()
        if let date = f.date(from: string) { return date }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: string)
    }
    static func codexQuota(_ object: [String: Any], base: AccountQuota = AccountQuota()) -> AccountQuota {
        var result = base
        if let plan = object["plan_type"] as? String { result.account = "Codex · " + plan.capitalized }
        let rates = object["rate_limit"] as? [String: Any] ?? [:]
        for (key, title) in [("primary_window", "当前周期"), ("secondary_window", "每周") ] {
            if let window = rates[key] as? [String: Any], let used = number(window["used_percent"]) {
                let seconds = number(window["limit_window_seconds"]) ?? 0
                let label = seconds == 18000 ? "5 小时" : seconds == 604800 ? "每周" : title
                result.windows.append(QuotaWindow(title: label, usedPercent: used, resetAt: date(window["reset_at"])))
            }
        }
        if let credits = object["credits"] as? [String: Any] {
            result.balance = number(credits["balance"]); result.unit = "credits"
            result.unlimited = credits["unlimited"] as? Bool ?? false
        }
        return finish(result)
    }
    static func claudeQuota(_ object: [String: Any], base: AccountQuota = AccountQuota()) -> AccountQuota {
        var result = base
        for (key, title) in [("five_hour", "5 小时"), ("seven_day", "每周")] {
            if let window = object[key] as? [String: Any], let used = number(window["utilization"]) {
                result.windows.append(QuotaWindow(title: title, usedPercent: used, resetAt: date(window["resets_at"])))
            }
        }
        return finish(result)
    }
    static func sub2api(_ object: [String: Any], base: AccountQuota = AccountQuota()) -> AccountQuota {
        var result = base
        let data = object["data"] as? [String: Any] ?? object
        result.balance = number(data["balance"]) ?? number(data["remaining"])
        result.unit = data["unit"] as? String ?? "USD"
        if let remaining = result.balance, remaining == -1, data["subscription"] != nil { result.unlimited = true; result.balance = nil }
        if let quota = data["quota"] as? [String: Any], let total = number(quota["limit"]), total > 0, let used = number(quota["used"]) {
            result.windows.append(QuotaWindow(title: "总额度", usedPercent: used / total * 100))
        }
        for window in data["rate_limits"] as? [[String: Any]] ?? [] {
            if let total = number(window["limit"]), total > 0, let used = number(window["used"]) {
                result.windows.append(QuotaWindow(title: window["window"] as? String ?? "周期", usedPercent: used / total * 100, resetAt: date(window["reset_at"])))
            }
        }
        if let subscription = data["subscription"] as? [String: Any] {
            for (key, title) in [("daily", "每日"), ("weekly", "每周"), ("monthly", "每月")] {
                if let limit = number(subscription[key + "_limit_usd"]), limit > 0, let used = number(subscription[key + "_usage_usd"]) {
                    let start = date(subscription[key + "_window_start"])
                    let reset = key == "weekly" ? start?.addingTimeInterval(7 * 86400) : nil
                    result.windows.append(QuotaWindow(title: title, usedPercent: used / limit * 100, resetAt: reset))
                }
            }
        }
        return finish(result)
    }
    private static func finish(_ value: AccountQuota) -> AccountQuota {
        var result = value
        if result.hasData { result.fetchedAt = Date() } else { result.error = "账户未返回可用额度数据" }
        return result
    }
}
