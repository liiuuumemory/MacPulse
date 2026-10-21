import Foundation
import AppKit

/// Checks GitHub Releases for a newer version. Read-only: it never downloads, builds or installs
/// anything; it only reports the release and, for a git checkout, the command to update it.
final class UpdateChecker: ObservableObject {
    static let repository = "liiuuumemory/MacPulse"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    struct Release: Equatable {
        let version: String
        let url: URL
        let notes: String
        let published: Date?
    }
    @Published private(set) var latest: Release?
    @Published private(set) var checking = false
    @Published private(set) var message = ""
    @Published private(set) var lastChecked: Date?
    @Published var automatic: Bool {
        didSet { if live { UserDefaults.standard.set(automatic, forKey: "update.auto") }; schedule() }
    }
    let current: String
    var updateAvailable: Bool { latest.map { Self.isNewer($0.version, than: current) } ?? false }
    private var timer: Timer?
    private let live: Bool
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15; c.timeoutIntervalForResource = 20
        c.httpCookieStorage = nil; c.urlCache = nil
        return URLSession(configuration: c)
    }()

    /// `live: false` (self-test) never reads or writes settings and never touches the network.
    init(live: Bool = true) {
        self.live = live
        current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        automatic = live ? UserDefaults.standard.object(forKey: "update.auto") as? Bool ?? true : false
        lastChecked = live ? UserDefaults.standard.object(forKey: "update.lastChecked") as? Date : nil
        schedule()
    }
    deinit { timer?.invalidate() }

    /// First check shortly after launch when a day has passed, then once a day.
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard live, automatic else { return }
        let since = lastChecked.map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = since >= 86400 ? 10 : 86400 - since
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.check(); self?.schedule()
        }
        timer?.tolerance = 60
    }

    func check() {
        guard live, !checking else { return }
        checking = true; message = ""
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MacPulse/\(current)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                let now = Date()
                switch status {
                case 200:
                    guard let object, let release = Self.parse(object) else { self.message = "发布信息格式无法识别"; return }
                    self.latest = release
                    self.lastChecked = now
                    UserDefaults.standard.set(now, forKey: "update.lastChecked")
                    self.message = self.updateAvailable ? "" : "已是最新版本"
                // Not a completed check: retry on the next launch instead of waiting a day.
                case 404: self.message = "仓库暂未发布版本"
                case 403, 429: self.message = "GitHub 请求过于频繁，请稍后再试"
                default: self.message = error == nil ? "GitHub 暂时不可用（\(status ?? 0)）" : "无法连接 GitHub"
                }
            }
        }.resume()
    }

    static func parse(_ object: [String: Any]) -> Release? {
        guard let tag = object["tag_name"] as? String, !version(tag).isEmpty else { return nil }
        // Only ever open this repository's pages, whatever the response says.
        let page = (object["html_url"] as? String).flatMap(URL.init(string:))
        let url = page.flatMap { $0.scheme == "https" && $0.host == "github.com" && $0.path.hasPrefix("/\(repository)/") ? $0 : nil } ?? releasesPage
        let published = (object["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let notes = String((object["body"] as? String ?? "").prefix(2000))
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")), url: url, notes: notes, published: published)
    }
    static func version(_ text: String) -> [Int] {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let core = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
        let parts = core.split(separator: ".").map { Int($0) }
        return parts.contains(nil) ? [] : parts.compactMap { $0 }
    }
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = version(candidate), b = version(current)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The source folder recorded by build.sh, when it is a git checkout of this project.
    var updateCommand: String? {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "MacPulseSourcePath") as? String,
              FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) else { return nil }
        return "cd '\(path.replacingOccurrences(of: "'", with: "'\\''"))' && git pull && bash build.sh"
    }
    func copyUpdateCommand() {
        guard let command = updateCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        message = "更新命令已复制，粘贴到“终端”运行后重新打开 MacPulse。"
    }
}
