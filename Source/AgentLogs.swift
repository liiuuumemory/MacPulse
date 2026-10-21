import Foundation
import SQLite3

// Usage records of other coding agents. Formats follow the agents' own session files as documented
// by tokscale (github.com/junhoyeo/tokscale): Gemini CLI chat recordings, Qwen Code JSONL and
// OpenCode's SQLite store / legacy message files. Only token counts, model and time are kept.
extension UsageLogScanner {
    private static func first(_ object: [String: Any], _ keys: [String]) -> Double {
        for key in keys { if let n = (object[key] as? NSNumber)?.doubleValue, n.isFinite { return max(0, n) } }
        return 0
    }

    /// Gemini reports promptTokenCount including cached content; the recorded total tells whether
    /// this file's `input` was stored that way. Thoughts bill as output, tool-use prompts as input.
    static func geminiEvent(id: String, date: Date, model: String, tokens: [String: Any]) -> UsageEvent? {
        let input = first(tokens, ["input", "prompt", "input_tokens", "prompt_tokens", "promptTokenCount"])
        let output = first(tokens, ["output", "candidates", "output_tokens", "completion_tokens", "candidatesTokenCount"])
        let cached = first(tokens, ["cached", "cached_tokens", "cachedContentTokenCount"])
        let thoughts = first(tokens, ["thoughts", "reasoning", "thoughts_tokens"])
        let tool = first(tokens, ["tool", "tool_tokens"])
        let total = (tokens["total"] as? NSNumber)?.doubleValue
        let fresh = cached > 0 && total == input + output + thoughts + tool ? input - min(cached, input) : input
        guard fresh + cached + tool + output + thoughts > 0 else { return nil }
        return UsageEvent(id: id, date: date, input: fresh + tool + cached, output: output + thoughts, cached: cached, model: model)
    }

    /// Qwen Code's usageMetadata keeps cache hits separate from promptTokenCount.
    static func qwenEvent(id: String, date: Date, model: String, usage: [String: Any]) -> UsageEvent? {
        let prompt = first(usage, ["promptTokenCount"]), cached = first(usage, ["cachedContentTokenCount"])
        let output = first(usage, ["candidatesTokenCount"]) + first(usage, ["thoughtsTokenCount"])
        guard prompt + cached + output > 0 else { return nil }
        return UsageEvent(id: id, date: date, input: prompt + cached, output: output, cached: cached, model: model)
    }

    /// One JSONL record from Gemini CLI (session-*.jsonl) or Qwen Code.
    func consumeAgentLine(_ line: Data, provider: AIProvider, state: inout ParseState) {
        let marker: StaticString = provider == .qwen ? "usageMetadata" : "tokens"
        guard Self.contains(line, marker) || Self.contains(line, "essionId") || Self.contains(line, "ession_id"),
              let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let session = (entry["sessionId"] ?? entry["session_id"]) as? String, !session.isEmpty { state.sessionID = session }
        let index = state.index
        state.index += 1
        guard let date = self.date(entry["timestamp"]) else { return }
        let event: UsageEvent?
        if provider == .qwen {
            guard entry["type"] as? String == "assistant", let usage = entry["usageMetadata"] as? [String: Any] else { return }
            let key = entry["uuid"] as? String ?? "\(index)"
            event = Self.qwenEvent(id: "qwen:\(state.sessionID):\(key)", date: date, model: entry["model"] as? String ?? "", usage: usage)
        } else {
            guard let tokens = entry["tokens"] as? [String: Any], let model = entry["model"] as? String else { return }
            let key = entry["id"] as? String ?? "\(index)"
            event = Self.geminiEvent(id: "gemini:\(state.sessionID):\(key)", date: date, model: model, tokens: tokens)
        }
        // Streaming updates rewrite the same message; keep its largest counts.
        if let event { state.modern[event.id] = state.modern[event.id].map { $0.merged(with: event) } ?? event }
    }

    /// Whole-document formats: a Gemini chat recording or a single OpenCode message file.
    func parseDocument(_ url: URL, provider: AIProvider, modified: Date) throws -> [String: UsageEvent] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 64 * 1024 * 1024 + 1), data.count <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let object = try JSONSerialization.jsonObject(with: data)
        var events: [String: UsageEvent] = [:]
        if provider == .opencode {
            guard let message = object as? [String: Any] else { return [:] }
            if let event = OpenCodeStore.event(id: message["id"] as? String ?? url.deletingPathExtension().lastPathComponent, data: message) { events[event.id] = event }
            return events
        }
        // Gemini: {sessionId, startTime, lastUpdated, messages: [...]}, or a bare message array.
        let session = object as? [String: Any] ?? [:]
        let messages = session["messages"] as? [[String: Any]] ?? object as? [[String: Any]] ?? []
        let sessionID = (session["sessionId"] ?? session["session_id"]) as? String ?? url.deletingPathExtension().lastPathComponent
        let fallback = date(session["lastUpdated"]) ?? date(session["startTime"]) ?? modified
        for (index, message) in messages.enumerated() {
            guard let tokens = message["tokens"] as? [String: Any], let model = message["model"] as? String else { continue }
            let key = message["id"] as? String ?? "\(index)"
            if let event = Self.geminiEvent(id: "gemini:\(sessionID):\(key)", date: date(message["timestamp"]) ?? fallback, model: model, tokens: tokens) {
                events[event.id] = events[event.id].map { $0.merged(with: event) } ?? event
            }
        }
        return events
    }
}

/// OpenCode 1.2+ keeps messages in ~/.local/share/opencode/opencode.db; earlier versions wrote one
/// JSON file per message (handled by the file scan). Assistant messages carry tokens and OpenCode's
/// own cost figure, which is used as-is.
enum OpenCodeStore {
    static func database(home: URL) -> URL { home.appendingPathComponent(".local/share/opencode/opencode.db") }

    /// Changes whenever the database or its write-ahead log changes; nil when OpenCode is absent.
    static func signature(home: URL) -> String? {
        let db = database(home: home)
        guard let info = try? db.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let wal = try? URL(fileURLWithPath: db.path + "-wal").resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = { (date: Date?) in date.map { "\($0.timeIntervalSince1970)" } ?? "-" }
        return [info.fileSize.map(String.init) ?? "-", stamp(info.contentModificationDate), wal?.fileSize.map(String.init) ?? "-", stamp(wal?.contentModificationDate)]
            .joined(separator: ":")
    }

    static func event(id: String, data: [String: Any]) -> UsageEvent? {
        // v1 rows carry role; v2 session_message rows are filtered by type in SQL instead.
        if let role = data["role"] as? String, role != "assistant" { return nil }
        guard let tokens = data["tokens"] as? [String: Any] else { return nil }
        func number(_ object: [String: Any], _ key: String) -> Double {
            guard let n = (object[key] as? NSNumber)?.doubleValue, n.isFinite else { return 0 }
            return max(0, n)
        }
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        let input = number(tokens, "input"), read = number(cache, "read"), write = number(cache, "write")
        let output = number(tokens, "output") + number(tokens, "reasoning")
        guard input + read + write + output > 0,
              let created = ((data["time"] as? [String: Any])?["created"] as? NSNumber)?.doubleValue, created > 0 else { return nil }
        let model = data["modelID"] as? String ?? (data["model"] as? [String: Any])?["id"] as? String ?? ""
        let cost = (data["cost"] as? NSNumber)?.doubleValue
        return UsageEvent(id: "opencode:" + id, date: Date(timeIntervalSince1970: created > 1e11 ? created / 1000 : created),
                          input: input + read + write, output: output, cached: read, cacheWrite: write, model: model,
                          reportedCost: cost.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
    }

    /// nil when the database exists but cannot be read.
    static func databaseEvents(home: URL) -> [String: UsageEvent]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database(home: home).path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var events: [String: UsageEvent] = [:], readable = false
        for sql in ["SELECT id, data FROM message WHERE json_extract(data, '$.role') = 'assistant' AND json_extract(data, '$.tokens') IS NOT NULL",
                    "SELECT id, data FROM session_message WHERE type = 'assistant' AND json_extract(data, '$.tokens') IS NOT NULL"] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue } // table absent in this version
            readable = true
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawID = sqlite3_column_text(statement, 0), let rawData = sqlite3_column_text(statement, 1),
                      let object = try? JSONSerialization.jsonObject(with: Data(String(cString: rawData).utf8)) as? [String: Any],
                      let event = event(id: String(cString: rawID), data: object) else { continue }
                events[event.id] = event
            }
            sqlite3_finalize(statement)
        }
        return readable ? events : nil
    }
}
