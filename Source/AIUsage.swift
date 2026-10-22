import Foundation
import AppKit
import Combine
import Security
import LocalAuthentication
import SQLite3
import CryptoKit

/// An AI coding service. Codex and Claude carry account quotas; every other service, whether read
/// from its own logs or discovered in CC Switch, reports usage and estimated cost only.
struct AIProvider: RawRepresentable, Hashable, Identifiable, Codable {
    let rawValue: String
    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
    private init(_ id: String) { rawValue = id }
    var id: String { rawValue }
    static let codex = Self("codex"), claude = Self("claude"), gemini = Self("gemini"), qwen = Self("qwen"), opencode = Self("opencode")
    static let quotaProviders: [Self] = [.codex, .claude]
    /// Services whose local logs MacPulse reads itself when CC Switch has no rows for them.
    static let localSources: [Self] = [.codex, .claude, .gemini, .qwen, .opencode]
    var hasQuota: Bool { Self.quotaProviders.contains(self) }
    var title: String {
        switch rawValue {
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "gemini": return "Gemini"
        case "qwen": return "Qwen"
        case "opencode": return "OpenCode"
        case "grokbuild": return "Grok Build"
        case "agy": return "Antigravity"
        case "claude-desktop": return "Claude 桌面版"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

struct UsageEvent {
    var id: String
    var date: Date
    var input: Double // every input token, including cache reads and writes
    var output: Double
    var cached: Double // cache reads
    var cacheWrite = 0.0 // short-lived cache writes (Claude 5 min, OpenAI)
    var cacheWriteLong = 0.0 // Claude 1 h cache writes
    var model = ""
    var reportedCost: Double? // the agent's own cost figure (OpenCode), preferred over list prices
    var total: Double { input + output }
    func merged(with other: Self) -> Self {
        Self(id: id, date: min(date, other.date), input: max(input, other.input),
             output: max(output, other.output), cached: max(cached, other.cached),
             cacheWrite: max(cacheWrite, other.cacheWrite), cacheWriteLong: max(cacheWriteLong, other.cacheWriteLong),
             model: model.isEmpty ? other.model : model, reportedCost: reportedCost ?? other.reportedCost)
    }
}
struct UsageDay: Identifiable {
    var date: Date
    var tokens: Double
    var cost = 0.0
    var id: Date { date }
}
struct ModelUsage: Identifiable {
    var model: String
    var tokens = 0.0
    var cost: Double?
    var requests = 0
    var id: String { model }
}
struct TokenActivity {
    var days: [UsageDay] = []
    var models: [ModelUsage] = []
    var unpricedTokens = 0.0
    var requests = 0
    var loaded = false
    var error: String?
    var note: String?
    var source = "本机日志"
    var latest: Date?
    var updatedAt: Date?
    var total: Double { days.reduce(0) { $0 + $1.tokens } }
    var totalCost: Double { days.reduce(0) { $0 + $1.cost } }
    func tokens(since date: Date) -> Double { days.filter { $0.date >= date }.reduce(0) { $0 + $1.tokens } }
    func cost(since date: Date) -> Double { days.filter { $0.date >= date }.reduce(0) { $0 + $1.cost } }
    static var todayStart: Date { Calendar.current.startOfDay(for: Date()) }
    static var weekStart: Date { Calendar.current.date(byAdding: .day, value: -6, to: todayStart)! }
    var today: Double { tokens(since: Self.todayStart) }
    var week: Double { tokens(since: Self.weekStart) }
    var todayCost: Double { cost(since: Self.todayStart) }
    var weekCost: Double { cost(since: Self.weekStart) }
    /// Made-up usage for `--snapshot-demo`, so published screenshots carry no real usage or spend.
    static func demo(seed: UInt64, scale: Double) -> Self {
        var state = seed
        func next() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 33) / Double(1 << 31) }
        let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
        var activity = TokenActivity(loaded: true)
        for offset in (0..<150).reversed() {
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            let weekend = calendar.isDateInWeekend(date)
            guard next() > (weekend ? 0.65 : 0.25) else { continue }
            let tokens = (1.5 + next() * 14) * 1_000_000 * scale
            activity.days.append(UsageDay(date: date, tokens: tokens, cost: tokens / 1_000_000 * 0.42))
        }
        activity.latest = Date(); activity.updatedAt = Date()
        return activity
    }
}

/// List prices in USD per million tokens, used only for a local estimate. Subscription
/// plans are not billed per token, so the figure is "what this would cost on the API".
enum ModelPricing {
    struct Price { let input: Double; let output: Double; let cacheRead: Double }
    static let updated = "2026-10"
    // Longest prefix wins, so dated snapshot IDs resolve to their family.
    // Cache writes follow the published multipliers: 1.25x input (5 min), 2x input (1 h).
    // Long-context surcharges (Haiku 5.5 > 100K, GPT-6 Astra > 272K) are not modelled.
    static let table: [(prefix: String, price: Price)] = [
        ("claude-fable-5-1", Price(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", Price(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", Price(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", Price(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", Price(input: 4, output: 20, cacheRead: 0.2)),
        ("claude-opus-5", Price(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-8", Price(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-7", Price(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-6", Price(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-5", Price(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4", Price(input: 15, output: 75, cacheRead: 1.5)),
        ("claude-sonnet-5-5", Price(input: 2, output: 10, cacheRead: 0.2)),
        ("claude-sonnet-5", Price(input: 2, output: 10, cacheRead: 0.2)),
        ("claude-sonnet-4", Price(input: 3, output: 15, cacheRead: 0.3)),
        ("claude-haiku-5-5", Price(input: 0.1, output: 0.5, cacheRead: 0.01)),
        ("claude-haiku-4-5", Price(input: 1, output: 5, cacheRead: 0.1)),
        ("gpt-6-astra", Price(input: 10, output: 50, cacheRead: 1))
    ].sorted { $0.prefix.count > $1.prefix.count }
    /// Built-in prices first, then `extra` (CC Switch's table), matching provider-prefixed and dated IDs.
    static func price(_ model: String, extra: [String: Price] = [:]) -> Price? {
        var id = model.lowercased()
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) } // "google/gemini-…"
        func matches(_ prefix: String) -> Bool { id == prefix || id.hasPrefix(prefix + "-") || id.hasPrefix(prefix + "@") }
        if let builtIn = table.first(where: { matches($0.prefix) })?.price { return builtIn }
        if let exact = extra[id] { return exact }
        return extra.keys.filter(matches).max { $0.count < $1.count }.flatMap { extra[$0] }
    }
    static func cost(_ event: UsageEvent, extra: [String: Price] = [:]) -> Double? {
        cost(event, price: event.reportedCost == nil ? price(event.model, extra: extra) : nil)
    }
    static func cost(_ event: UsageEvent, price: Price?) -> Double? {
        if let reported = event.reportedCost { return reported }
        guard let price else { return nil }
        let uncached = max(0, event.input - event.cached - event.cacheWrite - event.cacheWriteLong)
        let dollars = uncached * price.input + event.cacheWrite * price.input * 1.25 + event.cacheWriteLong * price.input * 2
            + event.cached * price.cacheRead + event.output * price.output
        return dollars / 1_000_000
    }
}

struct QuotaWindow: Identifiable {
    var title: String
    var usedPercent: Double
    var resetAt: Date?
    var id: String { title }
    func remaining(at date: Date = Date()) -> Double? {
        if let resetAt, resetAt <= date { return nil }
        return max(0, min(100, 100 - usedPercent))
    }
}
struct AccountQuota {
    var account = "当前账户"
    var windows: [QuotaWindow] = []
    var balance: Double?
    var unit = "USD"
    var unlimited = false
    var fetchedAt: Date?
    var error: String?
    var identity = ""
    var website = URL(string: "https://chatgpt.com/codex/settings/usage")!
    var hasData: Bool { balance != nil || unlimited || !windows.isEmpty }
    var stale: Bool { error != nil || (fetchedAt.map { Date().timeIntervalSince($0) > 600 } ?? true) }
}

struct ServiceStatus {
    var indicator: String // Statuspage: none, minor, major, critical, maintenance
    var description: String
    var fetchedAt: Date
    var degraded: Bool { indicator != "none" }
    var label: String {
        switch indicator {
        case "none": return "运行正常"
        case "minor": return "部分功能异常"
        case "major": return "主要服务中断"
        case "critical": return "严重故障"
        case "maintenance": return "维护中"
        default: return "状态未知"
        }
    }
}

struct CustomQuota: Codable, Equatable {
    var enabled = false
    var total = 100.0
    var used = 0.0
    var unit = "USD"
    var period = "none"
    var updatedAt = Date()
    func periodStart(at date: Date, calendar: Calendar = .current) -> Date? {
        switch period {
        case "day": return calendar.startOfDay(for: date)
        case "week":
            var c = calendar; c.firstWeekday = 2
            return c.dateInterval(of: .weekOfYear, for: date)?.start
        case "month": return calendar.dateInterval(of: .month, for: date)?.start
        default: return nil
        }
    }
    func effectiveUsed(at date: Date = Date(), calendar: Calendar = .current) -> Double {
        if let start = periodStart(at: date, calendar: calendar), updatedAt < start { return 0 }
        return used
    }
    func remaining(at date: Date = Date(), calendar: Calendar = .current) -> Double {
        max(0, total - effectiveUsed(at: date, calendar: calendar))
    }
    func resetAt(at date: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let start = periodStart(at: date, calendar: calendar) else { return nil }
        return calendar.date(byAdding: period == "day" ? .day : period == "week" ? .weekOfYear : .month, value: 1, to: start)
    }
    var valid: Bool { total.isFinite && used.isFinite && total > 0 && used >= 0 && ["USD", "CNY", "Token", "次", "%"].contains(unit) && ["none", "day", "week", "month"].contains(period) }
}

enum UsageFormat {
    static func tokens(_ value: Double) -> String {
        if value >= 1e8 { return String(format: "%.2f 亿", value / 1e8) }
        if value >= 1e4 { return String(format: "%.1f 万", value / 1e4) }
        return String(format: "%.0f", value)
    }
    static func amount(_ value: Double, unit: String) -> String {
        switch unit {
        case "USD": return String(format: "$%.2f", value)
        case "CNY": return String(format: "¥%.2f", value)
        case "Token": return tokens(value) + " Token"
        case "%": return String(format: "%.1f%%", value)
        default: return String(format: "%.0f %@", value, unit)
        }
    }
    private static let todayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm 重置"; return f }()
    private static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M/d HH:mm 重置"; return f }()
    static func countdown(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "不自动重置" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "等待更新" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes) 分钟后重置" }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 24 { return rest == 0 ? "\(hours) 小时后重置" : "\(hours) 小时 \(rest) 分后重置" }
        return hours % 24 == 0 ? "\(hours / 24) 天后重置" : "\(hours / 24) 天 \(hours % 24) 小时后重置"
    }
    static func reset(_ date: Date?) -> String {
        guard let date else { return "不自动重置" }
        if date <= Date() { return "等待更新" }
        return (Calendar.current.isDateInToday(date) ? todayFormatter : dayFormatter).string(from: date)
    }
}

/// Scans only usage metadata; never retains messages, prompts or tool payloads.
final class UsageLogScanner {
    /// Resumable per-file parse state: growing session logs are read from the last complete line.
    struct ParseState {
        var offset: UInt64 = 0
        var tail = Data() // the last bytes before `offset`, to detect a rewritten file
        var previous = 0.0
        var index = 0 // records seen, for agents whose lines carry no message ID
        var sessionID: String
        var model = ""
        var turnModels: [String: String] = [:]
        var modern: [String: UsageEvent] = [:]
        var legacy: [String: UsageEvent] = [:]
        var events: [String: UsageEvent] {
            guard let first = modern.values.map(\.date).min() else { return legacy }
            // A file may span the transition to per-response records. Preserve its older usage.
            var result = modern
            for (id, event) in legacy where event.date < first { result[id] = event }
            return result
        }
    }
    struct FileCache { var size: Int; var modified: Date; var identity: NSObject?; var state: ParseState; var events: [String: UsageEvent] }
    private var cache: [URL: FileCache] = [:]
    private var openCodeDatabase: (signature: String, events: [String: UsageEvent])?
    private let fractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private let plain = ISO8601DateFormatter()
    func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text)
    }
    static func number(_ object: [String: Any], _ key: String) -> Double {
        guard let n = (object[key] as? NSNumber)?.doubleValue, n.isFinite, n >= 0 else { return 0 }
        return n
    }
    static func roots(_ provider: AIProvider, home: URL) -> [URL] {
        let paths: [String]
        switch provider {
        case .codex: paths = [".codex/sessions", ".codex/archived_sessions"]
        case .claude: paths = [".claude/projects"]
        case .gemini: paths = [".gemini/tmp"]
        case .qwen: paths = [".qwen/projects", ".qwen/tmp"]
        case .opencode: paths = [".local/share/opencode/storage/message"] // OpenCode before 1.2; newer versions use SQLite
        default: paths = []
        }
        return paths.map { home.appendingPathComponent($0) }
    }
    static func accepts(_ file: URL, provider: AIProvider) -> Bool {
        switch provider {
        case .gemini:
            // Chat recordings only; tmp/ also holds prompt logs and shell history.
            return ["json", "jsonl"].contains(file.pathExtension) && (file.path.contains("/chats/") || file.lastPathComponent.hasPrefix("session-"))
        case .opencode: return file.pathExtension == "json"
        default: return file.pathExtension == "jsonl"
        }
    }
    func scan(_ provider: AIProvider, home: URL = FileManager.default.homeDirectoryForCurrentUser, prices: [String: ModelPricing.Price] = [:]) -> TokenActivity {
        let roots = Self.roots(provider, home: home)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .fileResourceIdentifierKey]
        var merged: [String: UsageEvent] = [:]
        var readFailure = false
        var visited = Set<URL>()
        var compressed = 0
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, _ in readFailure = true; return true }) else { readFailure = true; continue }
            for case let file as URL in files {
                // Codex compresses older sessions to .jsonl.zst; macOS ships no zstd decoder.
                if provider == .codex && file.pathExtension == "zst" { compressed += 1; continue }
                guard Self.accepts(file, provider: provider) else { continue }
                guard let info = try? file.resourceValues(forKeys: Set(keys)), info.isRegularFile == true else { continue }
                visited.insert(file)
                let size = info.fileSize ?? 0, modified = info.contentModificationDate ?? .distantPast
                let identity = info.fileResourceIdentifier as? NSObject
                let events: [String: UsageEvent]
                if let saved = cache[file], saved.size == size && saved.modified == modified { events = saved.events }
                else if file.pathExtension == "json" {
                    // Whole-document formats (Gemini chat recordings, OpenCode messages) are re-read when changed.
                    do {
                        events = try parseDocument(file, provider: provider, modified: modified)
                        cache[file] = FileCache(size: size, modified: modified, identity: identity, state: ParseState(sessionID: file.lastPathComponent), events: events)
                    } catch { readFailure = true; cache[file] = nil; continue }
                } else {
                    // Append-only growth of the same file resumes; anything else is parsed afresh.
                    var state = ParseState(sessionID: file.lastPathComponent)
                    if let saved = cache[file], size >= saved.size, UInt64(size) >= saved.state.offset,
                       let old = saved.identity, let identity, old.isEqual(identity), Self.tailMatches(file, saved.state) { state = saved.state }
                    do {
                        try parseFile(file, provider: provider, state: &state)
                        events = state.events
                        cache[file] = FileCache(size: size, modified: modified, identity: identity, state: state, events: events)
                    } catch { readFailure = true; cache[file] = nil; continue }
                }
                for (id, value) in events { merged[id] = merged[id].map { $0.merged(with: value) } ?? value }
            }
        }
        // Drop obsolete file caches for this provider without touching the others.
        cache = cache.filter { key, _ in !roots.contains(where: { key.path.hasPrefix($0.path + "/") }) || visited.contains(key) }
        if provider == .opencode, let signature = OpenCodeStore.signature(home: home) {
            if openCodeDatabase?.signature != signature {
                if let events = OpenCodeStore.databaseEvents(home: home) { openCodeDatabase = (signature, events) } else { readFailure = true }
            }
            for (id, value) in openCodeDatabase?.events ?? [:] { merged[id] = merged[id].map { $0.merged(with: value) } ?? value }
        }
        let summary = Self.summarize(merged.values, prices: prices)
        return TokenActivity(days: summary.days, models: summary.models,
                             unpricedTokens: summary.unpriced, requests: merged.count, loaded: true,
                             error: readFailure ? "部分本地记录无法读取" : nil,
                             note: compressed > 0 ? "\(compressed) 个已压缩的会话（.zst）无法直接读取；安装 CC Switch 后可完整统计" : nil,
                             latest: merged.values.map(\.date).max(), updatedAt: Date())
    }
    static func summarize<Events: Sequence>(_ events: Events, prices: [String: ModelPricing.Price]) -> (days: [UsageDay], models: [ModelUsage], unpriced: Double) where Events.Element == UsageEvent {
        var days: [Date: UsageDay] = [:]
        var models: [String: ModelUsage] = [:]
        var priceCache: [String: ModelPricing.Price?] = [:]
        var unpriced = 0.0
        for event in events {
            let day = Calendar.current.startOfDay(for: event.date)
            let price: ModelPricing.Price?
            if let cached = priceCache[event.model] { price = cached } else { price = ModelPricing.price(event.model, extra: prices); priceCache[event.model] = price }
            let cost = ModelPricing.cost(event, price: price)
            days[day, default: UsageDay(date: day, tokens: 0)].tokens += event.total
            days[day, default: UsageDay(date: day, tokens: 0)].cost += cost ?? 0
            guard event.total > 0 else { continue }
            let name = event.model.isEmpty ? "未知模型" : event.model
            var usage = models[name] ?? ModelUsage(model: name)
            usage.tokens += event.total; usage.requests += 1
            if let cost { usage.cost = (usage.cost ?? 0) + cost } else { unpriced += event.total }
            models[name] = usage
        }
        return (days.values.sorted { $0.date < $1.date }, models.values.sorted { $0.tokens > $1.tokens }, unpriced)
    }
    func parseFile(_ url: URL, provider: AIProvider) throws -> [String: UsageEvent] {
        var state = ParseState(sessionID: url.lastPathComponent)
        try parseFile(url, provider: provider, state: &state)
        return state.events
    }
    private static func tailMatches(_ url: URL, _ state: ParseState) -> Bool {
        guard state.offset >= UInt64(state.tail.count), let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard (try? file.seek(toOffset: state.offset - UInt64(state.tail.count))) != nil else { return false }
        return (try? file.read(upToCount: state.tail.count)) ?? Data() == state.tail
    }
    static func contains(_ line: Data, _ needle: StaticString) -> Bool {
        line.withUnsafeBytes { raw in
            raw.count >= needle.utf8CodeUnitCount && memmem(raw.baseAddress, raw.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
        }
    }
    func parseFile(_ url: URL, provider: AIProvider, state: inout ParseState) throws {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        func consume(_ line: Data, _ state: inout ParseState) {
            if provider != .codex && provider != .claude { consumeAgentLine(line, provider: provider, state: &state); return }
            // Ignore non-usage records before decoding potentially large message bodies.
            if provider == .codex && !Self.contains(line, "token_usage_record") && !Self.contains(line, "token_count")
                && !Self.contains(line, "session_meta") && !Self.contains(line, "turn_context") { return }
            // Tool results quoting "usage" are common and huge; only assistant records carry billing usage.
            if provider == .claude && (!Self.contains(line, "\"usage\"") || !Self.contains(line, "\"assistant\"")) { return }
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let kind = entry["type"] as? String else { return }
            let payload = entry["payload"] as? [String: Any] ?? [:]
            if kind == "session_meta" { state.sessionID = payload["id"] as? String ?? state.sessionID; return }
            if kind == "turn_context" {
                if let model = payload["model"] as? String, !model.isEmpty {
                    state.model = model
                    if let turn = payload["turn_id"] as? String { state.turnModels[turn] = model }
                }
                return
            }
            guard let date = self.date(entry["timestamp"]) else { return }
            if provider == .codex {
                if kind == "token_usage_record", let usage = payload["usage"] as? [String: Any], let response = payload["response_id"] as? String, !response.isEmpty {
                    let output = Self.number(usage, "output_tokens")
                    let total = Self.number(usage, "total_tokens")
                    let input = total >= output && total > 0 ? total - output : Self.number(usage, "input_tokens")
                    let model = (payload["turn_id"] as? String).flatMap { state.turnModels[$0] } ?? state.model
                    let event = UsageEvent(id: "codex:" + response, date: date, input: input, output: output, cached: Self.number(usage, "cached_input_tokens"),
                                           cacheWrite: Self.number(usage, "cache_write_input_tokens"), model: model)
                    state.modern[event.id] = state.modern[event.id].map { $0.merged(with: event) } ?? event
                } else if kind == "event_msg", payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any] {
                    let cumulative = Self.number(total, "total_tokens")
                    if cumulative == state.previous { return }
                    let last = info["last_token_usage"] as? [String: Any] ?? [:]
                    let delta = cumulative >= state.previous ? cumulative - state.previous : Self.number(last, "total_tokens")
                    state.previous = cumulative
                    // Legacy totals cannot be split into input/cache/output, so they stay unpriced.
                    let id = "codex-legacy:\(state.sessionID):\(date.timeIntervalSince1970):\(cumulative)"
                    state.legacy[id] = UsageEvent(id: id, date: date, input: delta, output: 0, cached: 0)
                }
            } else if kind == "assistant", let message = entry["message"] as? [String: Any], let usage = message["usage"] as? [String: Any], let messageID = message["id"] as? String, !messageID.isEmpty {
                let creation = Self.number(usage, "cache_creation_input_tokens")
                let split = usage["cache_creation"] as? [String: Any] ?? [:]
                let long = min(creation, Self.number(split, "ephemeral_1h_input_tokens"))
                let input = Self.number(usage, "input_tokens") + creation + Self.number(usage, "cache_read_input_tokens")
                let event = UsageEvent(id: "claude:" + messageID, date: date, input: input, output: Self.number(usage, "output_tokens"), cached: Self.number(usage, "cache_read_input_tokens"),
                                       cacheWrite: creation - long, cacheWriteLong: long, model: message["model"] as? String ?? "")
                state.modern[event.id] = state.modern[event.id].map { $0.merged(with: event) } ?? event
            }
        }
        try file.seek(toOffset: state.offset)
        var pending = Data()
        var consumed = state.offset
        // Each chunk is drained in its own pool: FileHandle reads are autoreleased and would
        // otherwise keep every byte of the log alive until the whole scan returns.
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            pending.append(chunk)
            // Find line ends with memchr and walk a cursor; removing each line from the front was quadratic.
            var lines: [Range<Int>] = [], start = 0
            pending.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                while start < raw.count, let found = memchr(base + start, 10, raw.count - start) {
                    let end = base.distance(to: UnsafeRawPointer(found))
                    lines.append(start..<end); start = end + 1
                }
            }
            let origin = pending.startIndex
            for line in lines { consume(pending[(origin + line.lowerBound)..<(origin + line.upperBound)], &state) }
            consumed += UInt64(start)
            if start > 0 { state.tail = Data(pending[(origin + max(0, start - 256))..<(origin + start)]) }
            pending = Data(pending[(origin + start)...])
            // Never keep an unbounded malformed line in the monitoring process.
            if pending.count > 32 * 1024 * 1024 { throw CocoaError(.fileReadCorruptFile) }
            return true
        }) {}
        // An unterminated final line may still be being written; it is read on the next scan.
        state.offset = consumed
    }
}

/// CC Switch keeps its own deduplicated, priced ledger of AI agent usage (Claude Code, Codex, Gemini,
/// Grok Build and others). It decodes Codex's compressed sessions and keeps daily rollups after
/// pruning old rows, so it is preferred for every app it has rows for. Read-only; only the usage
/// and price tables are queried, never provider credentials.
enum CCSwitchLedger {
    static func open(home: URL) -> OpaquePointer? {
        let file = home.appendingPathComponent(".cc-switch/cc-switch.db")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; return nil }
        sqlite3_busy_timeout(db, 1000)
        return db
    }
    private static func rows(_ db: OpaquePointer?, _ sql: String, bind: String? = nil, _ body: (OpaquePointer?) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        if let bind { sqlite3_bind_text(statement, 1, bind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        while sqlite3_step(statement) == SQLITE_ROW { body(statement) }
        return true
    }
    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    private static func hasColumn(_ db: OpaquePointer?, _ table: String, _ column: String) -> Bool {
        var found = false
        _ = rows(db, "PRAGMA table_info(\(table))") { if text($0, 1) == column { found = true } }
        return found
    }
    /// Apps with usage rows, e.g. claude, codex, gemini, grokbuild.
    static func appTypes(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        guard let db = open(home: home) else { return [] }
        defer { sqlite3_close(db) }
        var apps: [String] = []
        _ = rows(db, "SELECT app_type FROM proxy_request_logs UNION SELECT app_type FROM usage_daily_rollups") { statement in
            let app = text(statement, 0)
            if !app.isEmpty { apps.append(app) }
        }
        return apps
    }
    /// CC Switch's per-model price table, used for models missing from the built-in list.
    static func prices(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: ModelPricing.Price] {
        guard let db = open(home: home) else { return [:] }
        defer { sqlite3_close(db) }
        var prices: [String: ModelPricing.Price] = [:]
        _ = rows(db, "SELECT model_id, CAST(input_cost_per_million AS REAL), CAST(output_cost_per_million AS REAL), CAST(cache_read_cost_per_million AS REAL) FROM model_pricing") { statement in
            let id = text(statement, 0).lowercased()
            let values = (1...3).map { max(0, sqlite3_column_double(statement, Int32($0))) }
            if !id.isEmpty, values[0] > 0 || values[1] > 0 { prices[id] = ModelPricing.Price(input: values[0], output: values[1], cacheRead: values[2]) }
        }
        return prices
    }
    // Mirrors CC Switch's own normalisation (src-tauri/src/services/sql_helpers.rs, fresh_input_sql and
    // real_total_tokens_sql): these apps store input including cache, others store fresh input.
    static let cacheInclusiveApps = ["codex", "gemini", "grokbuild"]
    static func tokensSQL(semantics: Bool) -> String {
        let inclusive = cacheInclusiveApps.map { "'\($0)'" }.joined(separator: ", ")
        let mode = semantics ? "input_token_semantics" : "0"
        let fresh = """
        CASE WHEN \(mode) = 2 THEN input_tokens \
        WHEN app_type IN (\(inclusive)) AND \(mode) = 1 AND input_tokens >= cache_read_tokens + cache_creation_tokens THEN input_tokens - cache_read_tokens - cache_creation_tokens \
        WHEN app_type IN (\(inclusive)) AND \(mode) = 0 AND input_tokens >= cache_read_tokens THEN input_tokens - cache_read_tokens \
        ELSE input_tokens END
        """
        return "((\(fresh)) + output_tokens + cache_creation_tokens + cache_read_tokens)"
    }
    /// nil when CC Switch has no rows for this app, so local logs are used instead.
    static func activity(_ provider: AIProvider, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> TokenActivity? {
        guard let db = open(home: home) else { return nil }
        defer { sqlite3_close(db) }
        let seconds = "CASE WHEN created_at > 100000000000 THEN created_at / 1000 ELSE created_at END"
        let sql = """
        SELECT day, model, SUM(requests), SUM(tokens), SUM(cost), MAX(latest) FROM (
          SELECT date(\(seconds), 'unixepoch', 'localtime') AS day, model, COUNT(*) AS requests,
                 SUM(\(tokensSQL(semantics: hasColumn(db, "proxy_request_logs", "input_token_semantics")))) AS tokens,
                 SUM(CAST(total_cost_usd AS REAL)) AS cost, MAX(\(seconds)) AS latest
            FROM proxy_request_logs WHERE app_type = ?1 AND status_code BETWEEN 200 AND 299 GROUP BY day, model
          UNION ALL
          SELECT date, model, success_count, \(tokensSQL(semantics: hasColumn(db, "usage_daily_rollups", "input_token_semantics"))),
                 CAST(total_cost_usd AS REAL), NULL FROM usage_daily_rollups WHERE app_type = ?1
        ) GROUP BY day, model
        """
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        var days: [Date: UsageDay] = [:], models: [String: ModelUsage] = [:]
        var requests = 0, unpriced = 0.0, latest: TimeInterval = 0
        let ok = rows(db, sql, bind: provider.rawValue) { statement in
            guard let day = formatter.date(from: text(statement, 0)).map({ Calendar.current.startOfDay(for: $0) }) else { return }
            let model = text(statement, 1)
            let count = Int(sqlite3_column_int64(statement, 2))
            let used = max(0, sqlite3_column_double(statement, 3)), cost = max(0, sqlite3_column_double(statement, 4))
            latest = max(latest, sqlite3_column_double(statement, 5))
            guard used > 0 || count > 0 else { return }
            requests += count
            days[day, default: UsageDay(date: day, tokens: 0)].tokens += used
            days[day, default: UsageDay(date: day, tokens: 0)].cost += cost
            let name = model.isEmpty ? "未知模型" : model
            var usage = models[name] ?? ModelUsage(model: name)
            usage.tokens += used; usage.requests += count
            // CC Switch records 0 for models missing from its price table.
            if cost > 0 || used == 0 { usage.cost = (usage.cost ?? 0) + cost } else { unpriced += used }
            models[name] = usage
        }
        guard ok, requests > 0 || !days.isEmpty else { return nil }
        return TokenActivity(days: days.values.sorted { $0.date < $1.date }, models: models.values.filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens },
                             unpricedTokens: unpriced, requests: requests, loaded: true, source: "CC Switch",
                             latest: latest > 0 ? Date(timeIntervalSince1970: latest) : nil, updatedAt: Date())
    }
}

final class AIUsageMonitor: ObservableObject {
    @Published var selected: AIProvider {
        didSet { UserDefaults.standard.set(selected.rawValue, forKey: "ai.provider") }
    }
    @Published private(set) var activity: [AIProvider: TokenActivity] = [:]
    /// Codex and Claude always; any other service once it has usage.
    @Published private(set) var providers: [AIProvider] = AIProvider.quotaProviders
    @Published private(set) var accounts: [AIProvider: AccountQuota] = [:]
    @Published private(set) var custom: [AIProvider: CustomQuota] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var status: [AIProvider: ServiceStatus] = [:]
    @Published var syncEnabled: Bool {
        didSet { UserDefaults.standard.set(syncEnabled, forKey: "ai.sync"); if !syncEnabled { peers = []; syncMessage = "" }; refresh(remote: false) }
    }
    @Published private(set) var peers: [UsageSync.Device] = []
    @Published private(set) var syncMessage = ""
    private let deviceID: String
    private lazy var deviceName: String = Host.current().localizedName ?? "Mac" // usage queue only
    @Published var checkStatus: Bool {
        didSet { UserDefaults.standard.set(checkStatus, forKey: "ai.status"); if !checkStatus { status = [:] } }
    }
    @Published var preferencesTab = "menu"
    @Published var preferCCSwitch: Bool {
        didSet { UserDefaults.standard.set(preferCCSwitch, forKey: "ai.ccswitch"); refresh(remote: false) }
    }
    private let queue = DispatchQueue(label: "local.macpulse.ai-usage", qos: .utility)
    private let scanner = UsageLogScanner()
    private let quotaClient = QuotaClient()
    private var timer: Timer?
    private var lastRemote = Date.distantPast
    private var generation = 0
    init(start: Bool = true, initialProvider: AIProvider? = nil) {
        selected = initialProvider ?? AIProvider(rawValue: UserDefaults.standard.string(forKey: "ai.provider") ?? "") ?? .codex
        preferCCSwitch = UserDefaults.standard.object(forKey: "ai.ccswitch") as? Bool ?? true
        checkStatus = UserDefaults.standard.object(forKey: "ai.status") as? Bool ?? true
        syncEnabled = UserDefaults.standard.object(forKey: "ai.sync") as? Bool ?? false
        let savedID = UserDefaults.standard.string(forKey: "device.id")
        deviceID = savedID ?? UUID().uuidString
        if savedID == nil && start { UserDefaults.standard.set(deviceID, forKey: "device.id") }
        for provider in AIProvider.quotaProviders {
            if let data = UserDefaults.standard.data(forKey: "ai.custom.\(provider.rawValue)"), let budget = try? JSONDecoder().decode(CustomQuota.self, from: data), budget.valid { custom[provider] = budget }
        }
        if start { resume() }
    }
    deinit { timer?.invalidate() }
    func pause() { timer?.invalidate(); timer = nil; generation += 1; refreshing = false }
    func resume() {
        guard timer == nil else { return }
        refresh(remote: true)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh(remote: false) }
    }
    func budget(_ provider: AIProvider) -> CustomQuota { custom[provider] ?? CustomQuota() }
    struct QuotaStatus { var percent: Double; var label: String; var resetAt: Date?; var stale: Bool }
    /// The tightest remaining share: the custom budget when enabled, otherwise the account window closest to its limit.
    func remaining(_ provider: AIProvider, at date: Date = Date()) -> QuotaStatus? {
        let custom = budget(provider)
        if custom.enabled, custom.total > 0 {
            return QuotaStatus(percent: custom.remaining(at: date) / custom.total * 100, label: "自定义额度", resetAt: custom.resetAt(at: date), stale: false)
        }
        guard let account = accounts[provider], account.hasData,
              let tightest = account.windows.compactMap({ window in window.remaining(at: date).map { (window, $0) } }).min(by: { $0.1 < $1.1 }) else { return nil }
        return QuotaStatus(percent: tightest.1, label: tightest.0.title + "窗口", resetAt: tightest.0.resetAt, stale: account.stale)
    }
    func save(_ budget: CustomQuota, provider: AIProvider) {
        guard budget.valid, let data = try? JSONEncoder().encode(budget) else { return }
        UserDefaults.standard.set(data, forKey: "ai.custom.\(provider.rawValue)")
        custom[provider] = budget
    }
    func refresh(remote: Bool = true, allowClaudePrompt: Bool = false) {
        guard !refreshing else { return }
        refreshing = true
        let version = generation
        let ledger = preferCCSwitch, statusPages = checkStatus, sync = syncEnabled, deviceID = deviceID
        let demo = CommandLine.arguments.contains("--snapshot") && CommandLine.arguments.contains("--snapshot-demo")
        let queryRemote = !demo && (remote || Date().timeIntervalSince(lastRemote) >= 300)
        if queryRemote { lastRemote = Date() }
        queue.async { [weak self] in
            guard let self else { return }
            // CC Switch covers every app it has rows for; local logs fill in the rest.
            let ledgerApps = ledger ? Set(CCSwitchLedger.appTypes()) : []
            let prices = CCSwitchLedger.prices()
            var candidates = AIProvider.localSources
            for app in ledgerApps.sorted() { if let provider = AIProvider(rawValue: app), !candidates.contains(provider) { candidates.append(provider) } }
            var parsed: [AIProvider: TokenActivity] = [:]
            for provider in candidates {
                if ledgerApps.contains(provider.rawValue), let activity = CCSwitchLedger.activity(provider) { parsed[provider] = activity }
                else if AIProvider.localSources.contains(provider) { parsed[provider] = self.scanner.scan(provider, prices: prices) }
            }
            var shown = parsed, peers: [UsageSync.Device] = [], message = ""
            if sync {
                if UsageSync.available {
                    let used = parsed.filter { $0.key.hasQuota || $0.value.total > 0 }
                    let device = UsageSync.Device(id: deviceID, name: self.deviceName, updatedAt: Date(),
                                                  providers: Dictionary(uniqueKeysWithValues: used.map { ($0.key.rawValue, UsageSync.days($0.value)) }))
                    do { try UsageSync.publish(device) } catch { message = "无法写入 iCloud 云盘：\(error.localizedDescription)" }
                    peers = UsageSync.peers(excluding: deviceID)
                    // Services used only on another Mac still appear here.
                    var keys = Set(parsed.keys)
                    for peer in peers { for key in peer.providers.keys { if let provider = AIProvider(rawValue: key) { keys.insert(provider) } } }
                    for provider in keys {
                        shown[provider] = UsageSync.merge(parsed[provider] ?? TokenActivity(loaded: true), peers: peers.compactMap { $0.providers[provider.rawValue] })
                    }
                } else { message = "未找到 iCloud 云盘，请在“系统设置 → Apple 账户 → iCloud”中开启 iCloud 云盘。" }
            }
            if demo { shown = [.codex: .demo(seed: 7, scale: 0.6), .claude: .demo(seed: 42, scale: 1)]; peers = [] }
            let visible = AIProvider.quotaProviders + shown.filter { !$0.key.hasQuota && $0.value.total > 0 }
                .sorted { $0.value.total > $1.value.total }.map(\.key)
            DispatchQueue.main.async { [weak self] in
                guard let self, version == self.generation else { return }
                self.activity = shown
                self.providers = visible
                if !visible.contains(self.selected) { self.selected = visible[0] }
                if self.syncEnabled { self.peers = peers; self.syncMessage = message }
            }
            var quotas: [AIProvider: AccountQuota] = [:]
            var statuses: [AIProvider: ServiceStatus] = [:]
            if queryRemote {
                quotas[.codex] = self.quotaClient.codex()
                quotas[.claude] = self.quotaClient.claude(allowPrompt: allowClaudePrompt)
                if statusPages { for provider in AIProvider.quotaProviders { statuses[provider] = self.quotaClient.status(provider) } }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, version == self.generation else { return }
                if self.checkStatus { for (provider, value) in statuses { self.status[provider] = value } }
                for (provider, value) in quotas {
                    if value.error != nil, let old = self.accounts[provider], old.hasData, old.identity == value.identity, !value.identity.isEmpty {
                        var stale = old; stale.error = value.error; self.accounts[provider] = stale
                    } else { self.accounts[provider] = value }
                }
                self.refreshing = false
            }
        }
    }
}
