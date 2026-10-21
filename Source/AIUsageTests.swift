import Foundation
import SQLite3

func testAIUsage() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let before = ISO8601DateFormatter().date(from: "2026-10-20T23:59:00Z")!
    let after = ISO8601DateFormatter().date(from: "2026-10-21T00:01:00Z")!
    var custom = CustomQuota(enabled: true, total: 100, used: 24, unit: "USD", period: "day", updatedAt: before)
    precondition(custom.remaining(at: before, calendar: calendar) == 76)
    precondition(custom.remaining(at: after, calendar: calendar) == 100, "new day resets manual usage")
    custom.period = "none"
    precondition(custom.remaining(at: after, calendar: calendar) == 76, "nonrecurring budgets must not reset")
    custom.used = 120
    precondition(custom.remaining() == 0, "over-budget remaining must not go negative")
    precondition(try! JSONDecoder().decode(CustomQuota.self, from: JSONEncoder().encode(custom)) == custom)
    custom.total = .nan; precondition(!custom.valid)
    custom.total = 100; custom.period = "week"; custom.used = 20
    let monday = ISO8601DateFormatter().date(from: "2026-10-26T00:01:00Z")!
    precondition(custom.remaining(at: monday, calendar: calendar) == 100)
    custom.period = "month"
    let november = ISO8601DateFormatter().date(from: "2026-11-01T00:01:00Z")!
    precondition(custom.remaining(at: november, calendar: calendar) == 100)
    let absent = QuotaClient.claudeQuota([:]); precondition(!absent.hasData && absent.error != nil)
    let quota = QuotaClient.claudeQuota(["five_hour": ["utilization": 24, "resets_at": "2099-01-01T00:00:00Z"], "seven_day": ["utilization": 100]])
    precondition(quota.windows[0].remaining() == 76 && quota.windows[1].remaining() == 0)
    precondition(QuotaWindow(title: "expired", usedPercent: 40, resetAt: .distantPast).remaining() == nil)
    let wallet = QuotaClient.sub2api(["balance": 0, "unit": "USD"])
    precondition(wallet.balance == 0 && wallet.hasData && wallet.error == nil, "zero is valid; absent is not zero")
    let openai = QuotaClient.codexQuota(["rate_limit": ["primary_window": ["used_percent": 15, "limit_window_seconds": 18000]], "credits": ["balance": "2.5"]])
    precondition(openai.windows.first?.remaining() == 85 && openai.balance == 2.5)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("macpulse-usage-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appendingPathComponent(".codex/sessions"), claude = root.appendingPathComponent(".claude/projects")
    try! FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    func write(_ objects: [[String: Any]], _ path: URL) {
        var data = Data()
        for object in objects { data.append(try! JSONSerialization.data(withJSONObject: object)); data.append(10) }
        try! data.write(to: path)
    }
    let timestamp = "2026-10-20T12:00:00Z"
    let modern: [String: Any] = ["type": "token_usage_record", "timestamp": timestamp, "payload": ["response_id": "response-1", "usage": ["input_tokens": 150, "cached_input_tokens": 100, "output_tokens": 50, "total_tokens": 200]]]
    write([modern, modern], codex.appendingPathComponent("first.jsonl"))
    write([modern], codex.appendingPathComponent("copy.jsonl"))
    let scanner = UsageLogScanner()
    precondition(scanner.scan(.codex, home: root).total == 200, "deduplicate response IDs and do not double-count cached input")
    func legacy(_ total: Int) -> [String: Any] {
        ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": total], "last_token_usage": ["total_tokens": 50]]]]
    }
    write([legacy(100), legacy(100), legacy(150)], codex.appendingPathComponent("older.jsonl"))
    precondition(scanner.scan(.codex, home: root).total == 350, "legacy events use cumulative differences")
    func assistant(_ output: Int) -> [String: Any] {
        ["type": "assistant", "timestamp": timestamp, "message": ["id": "message-1", "usage": ["input_tokens": 10, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 20, "output_tokens": output]]]
    }
    write([assistant(5), assistant(15)], claude.appendingPathComponent("one.jsonl"))
    write([assistant(15)], claude.appendingPathComponent("copy.jsonl"))
    precondition(scanner.scan(.claude, home: root).total == 145, "Claude streaming/copy records count once with final usage")
    write([assistant(25)], claude.appendingPathComponent("one.jsonl"))
    precondition(scanner.scan(.claude, home: root).total == 155, "modified files invalidate the scan cache")
    func append(_ text: String, _ path: URL) {
        let handle = try! FileHandle(forWritingTo: path); try! handle.seekToEnd(); try! handle.write(contentsOf: Data(text.utf8)); try! handle.close()
    }
    func line(_ object: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n" }
    func priced(_ id: String, model: String = "claude-opus-5-5") -> [String: Any] {
        ["type": "assistant", "timestamp": timestamp, "message": ["id": id, "model": model, "usage": ["input_tokens": 10, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 20, "output_tokens": 15]]]
    }
    let growing = claude.appendingPathComponent("growing.jsonl")
    write([priced("grow-1")], growing)
    precondition(scanner.scan(.claude, home: root).total == 300, "new file adds 145")
    let partial = line(priced("grow-2"))
    append(String(partial.dropLast(20)), growing)
    precondition(scanner.scan(.claude, home: root).total == 300, "an unterminated line being written is not counted yet")
    append(String(partial.suffix(20)), growing)
    let resumed = scanner.scan(.claude, home: root)
    precondition(resumed.total == 445 && resumed.requests == 3, "appended lines resume from the last complete line without double counting")
    write([priced("other-1"), priced("other-2"), priced("other-3")], growing)
    precondition(scanner.scan(.claude, home: root).total == 590, "a rewritten file is parsed afresh even when it grew")
    // 10 uncached × $4 + 20 cache writes × $5 + 100 cache reads × $0.20 + 15 output × $20, per million tokens.
    let event = UsageEvent(id: "x", date: Date(), input: 130, output: 15, cached: 100, cacheWrite: 20, model: "claude-opus-5-5")
    precondition(abs(ModelPricing.cost(event)! - 460e-6) < 1e-12, "Claude cost uses separate cache read/write rates")
    precondition(ModelPricing.price("claude-opus-5-5-20260901") != nil && ModelPricing.price("claude-opus-5")?.input == 5 && ModelPricing.price("unknown-model") == nil)
    precondition(ModelPricing.price("claude-opus-5-5")?.input == 4, "longest prefix wins")
    write([["type": "turn_context", "timestamp": timestamp, "payload": ["turn_id": "t1", "model": "gpt-6-astra"]],
           ["type": "token_usage_record", "timestamp": timestamp, "payload": ["turn_id": "t1", "response_id": "response-2", "usage": ["input_tokens": 1000, "cached_input_tokens": 600, "output_tokens": 100, "total_tokens": 1100]]]],
          codex.appendingPathComponent("model.jsonl"))
    let codexActivity = scanner.scan(.codex, home: root)
    // 400 uncached × $10 + 600 cached × $1 + 100 output × $50.
    precondition(abs(codexActivity.totalCost - 9600e-6) < 1e-12 && codexActivity.models.contains { $0.model == "gpt-6-astra" }, "Codex turns inherit their model from turn_context")
    precondition(codexActivity.unpricedTokens == 350, "legacy totals and records without a known model stay unpriced")
    // CC Switch ledger: Codex rows count cache reads inside input; rollups add pruned history.
    let ledgerDir = root.appendingPathComponent(".cc-switch")
    try! FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
    var db: OpaquePointer?
    precondition(sqlite3_open(ledgerDir.appendingPathComponent("cc-switch.db").path, &db) == SQLITE_OK)
    precondition(sqlite3_exec(db, """
    CREATE TABLE proxy_request_logs (request_id TEXT PRIMARY KEY, app_type TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER,
      cache_read_tokens INTEGER, cache_creation_tokens INTEGER, total_cost_usd TEXT, status_code INTEGER, created_at INTEGER);
    CREATE TABLE usage_daily_rollups (date TEXT, app_type TEXT, model TEXT, request_count INTEGER, success_count INTEGER, input_tokens INTEGER,
      output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, total_cost_usd TEXT);
    INSERT INTO proxy_request_logs VALUES ('a', 'codex', 'gpt-6-astra', 1000, 100, 600, 0, '0.0096', 200, 1792500000);
    INSERT INTO proxy_request_logs VALUES ('b', 'codex', 'mystery', 50, 0, 0, 0, '0', 200, 1792500000);
    INSERT INTO proxy_request_logs VALUES ('c', 'codex', 'gpt-6-astra', 0, 0, 0, 0, '0', 500, 1792500000);
    INSERT INTO proxy_request_logs VALUES ('d', 'claude', 'claude-opus-5-5', 10, 15, 100, 20, '0.00046', 200, 1792500000);
    INSERT INTO usage_daily_rollups VALUES ('2026-05-27', 'codex', 'gpt-5.5', 3, 3, 500, 50, 400, 0, '1.5');
    """, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let ledger = CCSwitchLedger.activity(.codex, home: root)!
    precondition(ledger.total == 1700 && ledger.requests == 5 && abs(ledger.totalCost - 1.5096) < 1e-9, "ledger merges rows and rollups without re-adding cached input")
    precondition(ledger.unpricedTokens == 50 && ledger.source == "CC Switch", "zero-cost models with tokens are unpriced")
    precondition(CCSwitchLedger.activity(.claude, home: root)!.total == 145, "Claude rows add cache reads and writes to input")
    precondition(CCSwitchLedger.activity(.claude, home: codex) == nil, "missing ledger falls back to local logs")
    precondition(Set(CCSwitchLedger.appTypes(home: root)) == ["codex", "claude"], "apps are discovered from usage rows")
    // Current CC Switch rows record input semantics; Gemini, like Codex, stores input including cache.
    let current = root.appendingPathComponent("modern")
    try! FileManager.default.createDirectory(at: current.appendingPathComponent(".cc-switch"), withIntermediateDirectories: true)
    precondition(sqlite3_open(current.appendingPathComponent(".cc-switch/cc-switch.db").path, &db) == SQLITE_OK)
    precondition(sqlite3_exec(db, """
    CREATE TABLE proxy_request_logs (request_id TEXT PRIMARY KEY, app_type TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER,
      cache_read_tokens INTEGER, cache_creation_tokens INTEGER, input_token_semantics INTEGER, total_cost_usd TEXT, status_code INTEGER, created_at INTEGER);
    CREATE TABLE usage_daily_rollups (date TEXT, app_type TEXT, model TEXT, request_count INTEGER, success_count INTEGER, input_tokens INTEGER,
      output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, input_token_semantics INTEGER, total_cost_usd TEXT);
    CREATE TABLE model_pricing (model_id TEXT PRIMARY KEY, display_name TEXT, input_cost_per_million TEXT, output_cost_per_million TEXT,
      cache_read_cost_per_million TEXT, cache_creation_cost_per_million TEXT);
    INSERT INTO proxy_request_logs VALUES ('a', 'codex', 'gpt-6-astra', 1000, 0, 300, 200, 1, '0', 200, 1792500000);
    INSERT INTO proxy_request_logs VALUES ('b', 'gemini', 'gemini-2.5-pro', 1000, 100, 600, 0, 0, '0.001', 200, 1792500000);
    INSERT INTO model_pricing VALUES ('gemini-2.5-pro', 'Gemini 2.5 Pro', '1.25', '10', '0.125', '1.5625');
    """, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    precondition(CCSwitchLedger.activity(.codex, home: current)!.total == 1000, "total-inclusive rows subtract cache reads and writes once")
    precondition(CCSwitchLedger.activity(.gemini, home: current)!.total == 1100, "Gemini rows count cache inside input")
    precondition(CCSwitchLedger.activity(.claude, home: current) == nil, "an app without rows falls back to its local logs")
    let prices = CCSwitchLedger.prices(home: current)
    precondition(ModelPricing.price("google/gemini-2.5-pro-preview", extra: prices)?.input == 1.25, "CC Switch prices cover models missing from the built-in table")
    precondition(ModelPricing.price("claude-opus-5-5", extra: ["claude-opus-5-5": ModelPricing.Price(input: 99, output: 99, cacheRead: 99)])?.input == 4, "built-in prices win")

    // Gemini CLI: chat recordings (.json) and session JSONL; other tmp files are not usage.
    let geminiChats = root.appendingPathComponent(".gemini/tmp/project-hash/chats")
    try! FileManager.default.createDirectory(at: geminiChats, withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: ["sessionId": "g1", "startTime": timestamp, "lastUpdated": timestamp, "messages": [
        ["id": "u1", "type": "user", "timestamp": timestamp, "content": "hi"],
        ["id": "m1", "type": "gemini", "timestamp": timestamp, "model": "gemini-2.5-pro",
         "tokens": ["input": 1000, "output": 50, "cached": 600, "thoughts": 10, "tool": 0, "total": 1060]]
    ]], options: .prettyPrinted).write(to: geminiChats.appendingPathComponent("session-1.json"))
    write([["sessionId": "g2", "kind": "main"],
           ["id": "m2", "type": "gemini", "timestamp": timestamp, "model": "gemini-2.5-flash", "tokens": ["input": 100, "output": 5, "cached": 0, "total": 105]],
           ["id": "m2", "type": "gemini", "timestamp": timestamp, "model": "gemini-2.5-flash", "tokens": ["input": 100, "output": 5, "cached": 0, "total": 105]]],
          geminiChats.appendingPathComponent("session-2.jsonl"))
    try! JSONSerialization.data(withJSONObject: ["messages": [["id": "x", "model": "gemini-2.5-pro", "tokens": ["input": 999]]]])
        .write(to: root.appendingPathComponent(".gemini/tmp/project-hash/logs.json"))
    let gemini = scanner.scan(.gemini, home: root, prices: prices)
    precondition(gemini.total == 1165 && gemini.requests == 2, "Gemini cached input is not double counted and repeated records count once")
    // 400 fresh × $1.25 + 600 cached × $0.125 + 60 output (incl. thoughts) × $10; the flash model has no price here.
    precondition(abs(gemini.totalCost - 1175e-6) < 1e-12 && gemini.unpricedTokens == 105)

    // Qwen Code keeps cache hits outside promptTokenCount.
    let qwenChats = root.appendingPathComponent(".qwen/projects/p/chats")
    try! FileManager.default.createDirectory(at: qwenChats, withIntermediateDirectories: true)
    write([["type": "user", "timestamp": timestamp, "sessionId": "q1"],
           ["type": "assistant", "model": "qwen3-coder-plus", "timestamp": timestamp, "sessionId": "q1",
            "usageMetadata": ["promptTokenCount": 100, "candidatesTokenCount": 20, "thoughtsTokenCount": 5, "cachedContentTokenCount": 300]]],
          qwenChats.appendingPathComponent("a.jsonl"))
    precondition(scanner.scan(.qwen, home: root).total == 425)

    // OpenCode: legacy per-message JSON plus the 1.2+ SQLite store; the same message counts once.
    let legacyMessages = root.appendingPathComponent(".local/share/opencode/storage/message/ses_1")
    try! FileManager.default.createDirectory(at: legacyMessages, withIntermediateDirectories: true)
    let opencodeMessage: [String: Any] = ["id": "msg_1", "role": "assistant", "modelID": "claude-sonnet-4", "cost": 0.05,
                                          "tokens": ["input": 10, "output": 5, "reasoning": 2, "cache": ["read": 100, "write": 50]], "time": ["created": 1792500000000]]
    try! JSONSerialization.data(withJSONObject: opencodeMessage).write(to: legacyMessages.appendingPathComponent("msg_1.json"))
    precondition(sqlite3_open(root.appendingPathComponent(".local/share/opencode/opencode.db").path, &db) == SQLITE_OK)
    precondition(sqlite3_exec(db, "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT)", nil, nil, nil) == SQLITE_OK)
    for (id, object) in [("msg_1", opencodeMessage),
                         ("msg_2", ["role": "assistant", "model": ["id": "gpt-6-astra", "providerID": "openai"], "tokens": ["input": 1000, "output": 100], "time": ["created": 1792500000000]]),
                         ("msg_3", ["role": "user", "time": ["created": 1792500000000]])] {
        let json = String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!.replacingOccurrences(of: "'", with: "''")
        precondition(sqlite3_exec(db, "INSERT INTO message VALUES ('\(id)', 'ses_1', '\(json)')", nil, nil, nil) == SQLITE_OK)
    }
    sqlite3_close(db)
    let opencode = scanner.scan(.opencode, home: root)
    precondition(opencode.total == 1267 && opencode.requests == 2, "OpenCode SQLite and legacy files deduplicate by message ID")
    precondition(abs(opencode.totalCost - 0.065) < 1e-12, "OpenCode's own cost is used; missing cost falls back to list prices")
    precondition(AIProvider(rawValue: "grokbuild")?.title == "Grok Build" && AIProvider(rawValue: "") == nil && !AIProvider.gemini.hasQuota)

    try! Data([0x28, 0xb5, 0x2f, 0xfd]).write(to: codex.appendingPathComponent("old.jsonl.zst"))
    precondition(scanner.scan(.codex, home: root).note != nil, "compressed sessions are reported, not silently skipped")
    let outage = QuotaClient.serviceStatus(["status": ["indicator": "major", "description": "Partial outage"]])!
    precondition(outage.degraded && outage.label == "主要服务中断" && QuotaClient.serviceStatus(["page": [:]]) == nil)
    let monitor = AIUsageMonitor(start: false)
    precondition(monitor.remaining(.codex) == nil || monitor.budget(.codex).enabled, "no account data means no quota percentage")
    let syncFolder = root.appendingPathComponent("sync")
    let mine = UsageSync.Device(id: "a", name: "MacBook", updatedAt: Date(), providers: ["codex": [UsageSync.Day(date: "2026-10-20", tokens: 100, cost: 1)]])
    let other = UsageSync.Device(id: "b", name: "Mac mini", updatedAt: Date(), providers: ["codex": [UsageSync.Day(date: "2026-10-20", tokens: 50, cost: 0.5), UsageSync.Day(date: "2026-10-21", tokens: 7, cost: 0)]])
    try! UsageSync.publish(mine, in: syncFolder); try! UsageSync.publish(other, in: syncFolder)
    let peers = UsageSync.peers(excluding: "a", in: syncFolder)
    precondition(peers.map(\.id) == ["b"], "a Mac never merges its own file")
    let local = TokenActivity(days: [UsageDay(date: calendar.startOfDay(for: before), tokens: 100, cost: 1)], loaded: true)
    let combined = UsageSync.merge(local, peers: peers.compactMap { $0.providers["codex"] })
    precondition(combined.total == 157 && abs(combined.totalCost - 1.5) < 1e-9 && combined.days.count >= 2, "daily totals from other Macs add up")
    print("PASS: AI usage deduplication, cache invalidation, incremental resume, cost estimation, CC Switch ledger and app discovery, Gemini / Qwen / OpenCode logs, iCloud merge, quota parsing, missing/zero distinction, custom budget persistence and resets")
}
