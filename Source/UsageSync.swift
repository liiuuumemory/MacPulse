import Foundation

/// Adds up AI usage across Macs through iCloud Drive. Each Mac writes one small file holding only
/// daily totals per service (date, tokens, estimated cost) — no sessions, prompts, paths or account data.
enum UsageSync {
    struct Day: Codable, Equatable { var date: String; var tokens: Double; var cost: Double }
    struct Device: Codable, Equatable {
        var id: String
        var name: String
        var updatedAt: Date
        var providers: [String: [Day]]
    }
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/MacPulse", isDirectory: true)
    }
    static var available: Bool {
        FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path)
    }
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func days(_ activity: TokenActivity) -> [Day] {
        activity.days.map { Day(date: dayFormatter.string(from: $0.date), tokens: $0.tokens, cost: $0.cost) }
    }
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
    /// Writes this Mac's file only when its content changed, so iCloud does not re-upload every minute.
    static func publish(_ device: Device, in folder: URL = folder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var unchanged = device; unchanged.updatedAt = .distantPast
        let file = folder.appendingPathComponent("usage-\(device.id).json")
        if let data = try? Data(contentsOf: file), var old = try? decoder().decode(Device.self, from: data) {
            old.updatedAt = .distantPast
            if old == unchanged { return }
        }
        try encoder().encode(device).write(to: file, options: .atomic)
    }
    static func peers(excluding id: String, in folder: URL = folder) -> [Device] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var result: [Device] = []
        for name in names {
            // Files not yet downloaded appear as ".usage-….json.icloud" placeholders.
            if name.hasPrefix(".usage-") && name.hasSuffix(".json.icloud") {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(real))
                continue
            }
            guard name.hasPrefix("usage-"), name.hasSuffix(".json"), name != "usage-\(id).json",
                  let data = try? Data(contentsOf: folder.appendingPathComponent(name)), data.count < 4 * 1024 * 1024,
                  let device = try? decoder().decode(Device.self, from: data), device.id != id else { continue }
            result.append(device)
        }
        return result.sorted { $0.name < $1.name }
    }
    /// Local detail (models, request counts) stays local; other Macs contribute daily totals.
    static func merge(_ local: TokenActivity, peers: [[Day]]) -> TokenActivity {
        guard !peers.isEmpty else { return local }
        var result = local
        var days = Dictionary(uniqueKeysWithValues: local.days.map { ($0.date, $0) })
        for peer in peers {
            for day in peer {
                guard let date = dayFormatter.date(from: day.date).map({ Calendar.current.startOfDay(for: $0) }),
                      day.tokens.isFinite, day.cost.isFinite, day.tokens >= 0, day.cost >= 0 else { continue }
                days[date, default: UsageDay(date: date, tokens: 0)].tokens += day.tokens
                days[date, default: UsageDay(date: date, tokens: 0)].cost += day.cost
            }
        }
        result.days = days.values.sorted { $0.date < $1.date }
        result.source = local.source + " + \(peers.count) 台 Mac"
        return result
    }
}
