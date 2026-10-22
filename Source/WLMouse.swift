import Foundation
import IOKit.hid

/// Model limits from the WLMOUSE web hub's own model list (gm.wlmouse.gg, env-models.json).
/// Only models on the hub's "new protocol" are listed; their commands carry a profile byte.
struct WLMouseModel {
    let name: String
    let english: String
    let polling: [Int: [Int]]
    let wiredPID: Int?
    let maxDPI: Int
    let dpiStep: Int
    let maxStages: Int
    let lod: [Double]
    let hyperMode: Bool
    let angleTune: Bool
    let sleep: Bool
    let sleepInSeconds: Bool
    let independentXY: Bool

    static let all: [WLMouseModel] = [
        .init(name: "幻", english: "HUAN", polling: [0xA863: [125, 250, 500, 1000, 2000, 4000, 8000], 0xA864: [125, 250, 500, 1000, 2000, 4000, 8000]],
              wiredPID: 0xA864, maxDPI: 30000, dpiStep: 50, maxStages: 6,
              lod: [0.7, 1.0, 2.0], hyperMode: true, angleTune: true,
              sleep: true, sleepInSeconds: false, independentXY: true),
        .init(name: "幻 M", english: "HUAN M", polling: [0xA863: [125, 250, 500, 1000, 2000, 4000, 8000], 0xA859: [125, 250, 500, 1000, 2000, 4000, 8000]],
              wiredPID: 0xA859, maxDPI: 50000, dpiStep: 1, maxStages: 6,
              lod: [0.7, 1.0, 2.0], hyperMode: true, angleTune: true,
              sleep: true, sleepInSeconds: false, independentXY: true),
        .init(name: "BEAST MIAO", english: "BEAST MIAO", polling: [0xA866: [125, 250, 500, 1000, 2000, 4000, 8000], 0xA882: [125, 250, 500, 1000], 0xA867: [125, 250, 500, 1000]],
              wiredPID: 0xA867, maxDPI: 30000, dpiStep: 50, maxStages: 6,
              lod: [0.7, 1.0, 2.0], hyperMode: true, angleTune: true,
              sleep: true, sleepInSeconds: false, independentXY: true),
        .init(name: "行者", english: "STRIDER", polling: [0xA872: [125, 250, 500, 1000, 2000, 4000, 8000], 0xA882: [125, 250, 500, 1000], 0xA873: [125, 250, 500, 1000]],
              wiredPID: 0xA873, maxDPI: 30000, dpiStep: 50, maxStages: 6,
              lod: [0.7, 1.0, 2.0], hyperMode: true, angleTune: true,
              sleep: true, sleepInSeconds: false, independentXY: true),
        .init(name: "影", english: "YING", polling: [0xA874: [125, 250, 500, 1000, 2000, 4000, 8000], 0xA882: [125, 250, 500, 1000], 0xA875: [125, 250, 500, 1000]],
              wiredPID: 0xA875, maxDPI: 30000, dpiStep: 50, maxStages: 6,
              lod: [0.7, 1.0, 2.0], hyperMode: true, angleTune: true,
              sleep: true, sleepInSeconds: false, independentXY: true),
        .init(name: "剑 X", english: "SWORD X", polling: [0xA878: [125, 250, 500, 1000, 2000, 4000, 8000], 0xA882: [125, 250, 500, 1000], 0xA879: [125, 250, 500, 1000]],
              wiredPID: 0xA879, maxDPI: 30000, dpiStep: 50, maxStages: 6,
              lod: [0.7, 1.0, 2.0], hyperMode: true, angleTune: true,
              sleep: true, sleepInSeconds: false, independentXY: true),
        .init(name: "花•兽 Mini", english: "BEAST MINI", polling: [0xA885: [125, 250, 500, 1000, 2000, 4000, 8000], 0xA882: [125, 250, 500, 1000], 0xA886: [125, 250, 500, 1000]],
              wiredPID: 0xA886, maxDPI: 26000, dpiStep: 50, maxStages: 6,
              lod: [1.0, 2.0], hyperMode: true, angleTune: true,
              sleep: true, sleepInSeconds: false, independentXY: true),
        .init(name: "花•兽 Mini PRO", english: "BEAST MINI PRO", polling: [0xA868: [125, 250, 500, 1000, 2000, 4000, 8000], 0xA882: [125, 250, 500, 1000], 0xA869: [125, 250, 500, 1000]],
              wiredPID: 0xA869, maxDPI: 30000, dpiStep: 50, maxStages: 6,
              lod: [0.7, 1.0, 2.0], hyperMode: true, angleTune: true,
              sleep: true, sleepInSeconds: false, independentXY: true),
        .init(name: "花•兽 MAX", english: "BEAST MAX", polling: [0xA880: [125, 250, 500, 1000, 2000, 4000, 8000], 0xA882: [125, 250, 500, 1000], 0xA881: [125, 250, 500, 1000]],
              wiredPID: 0xA881, maxDPI: 30000, dpiStep: 50, maxStages: 6,
              lod: [0.7, 1.0, 2.0], hyperMode: true, angleTune: true,
              sleep: true, sleepInSeconds: false, independentXY: true),
        .init(name: "花•兽 X", english: "BEAST X", polling: [0xA883: [125, 250, 500, 1000, 2000, 4000, 8000], 0xA882: [125, 250, 500, 1000], 0xA884: [125, 250, 500, 1000]],
              wiredPID: 0xA884, maxDPI: 26000, dpiStep: 50, maxStages: 6,
              lod: [1.0, 2.0], hyperMode: true, angleTune: true,
              sleep: true, sleepInSeconds: false, independentXY: true),
        .init(name: "花•兽 X PRO", english: "BEAST X PRO", polling: [0xA870: [125, 250, 500, 1000, 2000, 4000, 8000], 0xA882: [125, 250, 500, 1000], 0xA871: [125, 250, 500, 1000]],
              wiredPID: 0xA871, maxDPI: 30000, dpiStep: 50, maxStages: 6,
              lod: [0.7, 1.0, 2.0], hyperMode: true, angleTune: true,
              sleep: true, sleepInSeconds: false, independentXY: true),
        .init(name: "BEAST G", english: "BEAST G", polling: [0xA860: [125, 250, 500, 1000, 2000, 4000, 8000], 0xA882: [125, 250, 500, 1000], 0xA861: [125, 250, 500, 1000, 2000, 4000, 8000]],
              wiredPID: 0xA861, maxDPI: 30000, dpiStep: 50, maxStages: 6,
              lod: [0.7, 1.0, 2.0], hyperMode: true, angleTune: true,
              sleep: true, sleepInSeconds: false, independentXY: true),
        .init(name: "花•兽 X V2", english: "BEAST X V2", polling: [0xA856: [125, 250, 500, 1000, 2000, 4000, 8000], 0xA857: [125, 250, 500, 1000, 2000, 4000, 8000]],
              wiredPID: 0xA857, maxDPI: 50000, dpiStep: 1, maxStages: 6,
              lod: [0.7, 1.0, 2.0], hyperMode: true, angleTune: true,
              sleep: true, sleepInSeconds: false, independentXY: true),
    ]

    /// A PID shared by several models (the 1K dongle) gets the strictest common limits.
    static func resolve(productID: Int) -> WLMouseModel? {
        let matches = all.filter { $0.polling[productID] != nil }
        guard let first = matches.first else { return nil }
        if matches.count == 1 { return first }
        let lod = matches.dropFirst().reduce(Set(first.lod)) { $0.intersection($1.lod) }
        let polling = matches.dropFirst().reduce(Set(first.polling[productID]!)) { $0.intersection($1.polling[productID]!) }
        return WLMouseModel(name: "WLMOUSE（共用接收器）", english: "WLMOUSE", polling: [productID: polling.sorted()], wiredPID: nil,
                            maxDPI: matches.map(\.maxDPI).min()!, dpiStep: matches.map(\.dpiStep).max()!, maxStages: matches.map(\.maxStages).min()!,
                            lod: lod.sorted(), hyperMode: matches.allSatisfy(\.hyperMode), angleTune: matches.allSatisfy(\.angleTune),
                            sleep: matches.allSatisfy(\.sleep), sleepInSeconds: false, independentXY: matches.allSatisfy(\.independentXY))
    }
    /// Battery entry key: the wired PID reads as the model's own receiver, so a mouse charging on its cable
    /// stays one entry with one history instead of appearing twice.
    static func batteryKey(productID: Int) -> String {
        guard let model = all.first(where: { $0.wiredPID == productID }),
              let receiver = model.polling.keys.filter({ $0 != productID && resolve(productID: $0)?.name == model.name }).min()
        else { return "wl-\(productID)" }
        return "wl-\(receiver)"
    }
    func pollingRates(_ productID: Int) -> [Int] { polling[productID] ?? [125, 250, 500, 1000] }
    func connection(_ productID: Int) -> String {
        if productID == wiredPID { return "有线" }
        let top = pollingRates(productID).max() ?? 1000
        return top >= 8000 ? "8K 接收器" : top >= 4000 ? "4K 接收器" : "1K 接收器"
    }
}

struct WLMouseSettings: Equatable {
    var profile = 1
    var profileCount = 1
    /// Names stored on the mouse, one per profile; empty means unnamed.
    var profileNames: [String] = []
    var stages: [Int] = []
    var stagesY: [Int] = []
    var activeStage = 1
    var pollingRate = 1000
    var lod = 1.0
    var lodMode: UInt8 = 3
    var debounce = 0
    var motionSync = false
    var angleSnap = false
    var rippleControl = false
    var hyperMode = false
    var trackingMode = false
    var independentXY = false
    var angleTune = 0
    /// Seconds; 65535 keeps the mouse awake.
    var sleepSeconds = 60
    func profileLabel(_ index: Int) -> String {
        profileNames.indices.contains(index - 1) && !profileNames[index - 1].isEmpty ? profileNames[index - 1] : "配置 \(index)"
    }
}

enum WLMouseError: LocalizedError {
    case noReply(UInt8), openFailed, verify(String)
    var errorDescription: String? {
        switch self {
        case .noReply(let code): return String(format: "鼠标没有回应命令 0x%02X（可能在休眠，动一下鼠标后重试）", code)
        case .openFailed: return "无法打开接收器"
        case .verify(let field): return "写入后读回的\(field)与设定不一致"
        }
    }
}

/// The receiver's 64-byte vendor feature channel, speaking the web hub's command set.
/// Commands: byte 2 = 2, byte 3 = payload length, byte 4 = group, byte 5 = code (reads set bit 7), then parameters.
/// Replies are normalised so the 0xA1 status byte sits at index 1, matching the hub's indices.
final class WLMouseChannel {
    static let vendorID = 0x36A7
    let device: IOHIDDevice
    let productID: Int
    let product: String
    var model: WLMouseModel? { WLMouseModel.resolve(productID: productID) }

    private init(device: IOHIDDevice) {
        self.device = device
        productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "WLMOUSE"
    }

    static func find() -> [WLMouseChannel] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID, kIOHIDPrimaryUsagePageKey: 0xFFFF] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return [] }
        return channels((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [])
    }
    static func channels(_ devices: Set<IOHIDDevice>) -> [WLMouseChannel] {
        // Only the 64-byte command channel; a 512-byte one drives screens on other models.
        devices.filter { IOHIDDeviceGetProperty($0, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int == 64 }
            .map(WLMouseChannel.init).sorted { $0.productID < $1.productID }
    }

    static func normalize(_ raw: [UInt8]) -> [UInt8] {
        raw.first == 0xA1 ? [0] + raw : raw
    }
    static func command(group: UInt8, code: UInt8, length: UInt8, _ parameters: [UInt8] = []) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 64)
        c[2] = 2; c[3] = length; c[4] = group; c[5] = code
        for (i, value) in parameters.prefix(58).enumerated() { c[6 + i] = value }
        return c
    }

    func withOpen<T>(_ body: () throws -> T) throws -> T {
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { throw WLMouseError.openFailed }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        return try body()
    }

    /// One request/response, with the hub's retry rules: 0xA1 is done, a lower status means busy (poll again),
    /// a higher one means the command was not taken (send again).
    func transact(_ command: [UInt8]) throws -> [UInt8] {
        let code = command[5]
        for _ in 0..<5 {
            guard IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, command, command.count) == kIOReturnSuccess else { break }
            for _ in 0..<15 {
                usleep(30_000)
                var raw = [UInt8](repeating: 0, count: 65)
                var length = raw.count
                guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &raw, &length) == kIOReturnSuccess else { continue }
                let reply = Self.normalize(Array(raw.prefix(length)))
                guard reply.count > 8 else { continue }
                if reply[1] == 0xA1 && reply[6] == code { return reply }
                if reply[1] > 0xA1 { break }
            }
        }
        throw WLMouseError.noReply(code)
    }

    // MARK: Reads

    func battery() throws -> (charging: Bool, percent: Int)? {
        let reply = try transact(Self.command(group: 0, code: 0x83, length: 2))
        return PeripheralReader.parseWLMouseReply(reply)
    }

    func readSettings() throws -> WLMouseSettings {
        var s = WLMouseSettings()
        func get(_ group: UInt8, _ code: UInt8, _ length: UInt8, _ parameters: [UInt8]) throws -> [UInt8] {
            try transact(Self.command(group: group, code: code, length: length, parameters))
        }
        s.profile = max(1, Int(try get(0, 0x85, 1, [])[7]))
        s.profileCount = max(s.profile, Int(try get(0, 0x86, 1, [])[7]))
        s.profileNames = try (1...max(1, min(8, s.profileCount))).map { Self.decodeName(try get(0, 0x8E, 58, [UInt8($0)])) }
        let p = UInt8(s.profile)
        let stages = try get(1, 0x81, 10, [p, 6])
        let count = min(6, Int(stages[8]))
        for k in 0..<count {
            s.stages.append(Int(stages[9 + 4 * k]) << 8 | Int(stages[10 + 4 * k]))
            s.stagesY.append(Int(stages[11 + 4 * k]) << 8 | Int(stages[12 + 4 * k]))
        }
        s.activeStage = max(1, Int(try get(1, 0x82, 2, [p])[8]))
        s.pollingRate = Self.pollingRate(code: try get(1, 0x80, 2, [p])[8])
        let lod = try get(1, 0x88, 3, [p])
        s.lod = Self.decodeLOD(lod[8]); s.lodMode = lod[9]
        s.debounce = Int(try get(0, 0x88, 2, [p])[8])
        s.motionSync = try get(1, 0x89, 2, [p])[8] == 1
        s.angleSnap = try get(1, 0x84, 2, [p])[8] == 1
        s.rippleControl = try get(1, 0x8A, 2, [p])[8] == 1
        s.hyperMode = try get(1, 0x8B, 2, [p])[8] == 1
        s.trackingMode = try get(1, 0x93, 2, [p])[8] == 1
        s.independentXY = try get(1, 0x8D, 2, [p])[8] == 1
        let tune = Int(try get(1, 0x94, 2, [p])[8])
        s.angleTune = tune <= 30 ? tune : tune - 256
        let sleep = try get(0, 0x87, 3, [p])
        s.sleepSeconds = Int(sleep[8]) << 8 | Int(sleep[9])
        return s
    }

    // MARK: Writes

    /// Sends only what changed, then reads everything back and checks it.
    func apply(_ new: WLMouseSettings, over old: WLMouseSettings) throws -> WLMouseSettings {
        func set(_ group: UInt8, _ code: UInt8, _ length: UInt8, _ parameters: [UInt8]) throws {
            _ = try transact(Self.command(group: group, code: code, length: length, parameters))
        }
        for (i, name) in new.profileNames.enumerated() where i < old.profileNames.count && name != old.profileNames[i] {
            let bytes = Self.encodeName(name)
            try set(0, 0x0E, UInt8(bytes.count + 2), [UInt8(i + 1), UInt8(bytes.count)] + bytes)
        }
        if new.profile != old.profile {
            // Switching profile changes every other value; nothing else is written in the same step.
            try set(0, 0x05, 1, [UInt8(new.profile)])
            return try readSettings()
        }
        let p = UInt8(new.profile)
        if new.stages != old.stages || new.stagesY != old.stagesY || new.independentXY != old.independentXY {
            if new.independentXY != old.independentXY { try set(1, 0x0D, 2, [p, new.independentXY ? 1 : 0]) }
            var bytes: [UInt8] = []
            for (i, x) in new.stages.enumerated() {
                let y = new.independentXY ? (new.stagesY.indices.contains(i) ? new.stagesY[i] : x) : x
                bytes += [UInt8(x >> 8 & 0xFF), UInt8(x & 0xFF), UInt8(y >> 8 & 0xFF), UInt8(y & 0xFF)]
            }
            try set(1, 0x01, 26, [p, UInt8(new.stages.count)] + bytes)
        }
        let active = min(max(1, new.activeStage), max(1, new.stages.count))
        if active != old.activeStage || new.stages.count != old.stages.count { try set(1, 0x02, 2, [p, UInt8(active)]) }
        if new.pollingRate != old.pollingRate, let code = Self.pollingCode(new.pollingRate) { try set(1, 0x00, 2, [p, code]) }
        if new.lod != old.lod { try set(1, 0x08, 3, [p, Self.encodeLOD(new.lod), new.lodMode]) }
        if new.debounce != old.debounce { try set(0, 0x08, 2, [p, UInt8(min(15, max(0, new.debounce)))]) }
        if new.motionSync != old.motionSync { try set(1, 0x09, 2, [p, new.motionSync ? 1 : 0]) }
        if new.angleSnap != old.angleSnap { try set(1, 0x04, 2, [p, new.angleSnap ? 1 : 0]) }
        if new.rippleControl != old.rippleControl { try set(1, 0x0A, 2, [p, new.rippleControl ? 1 : 0]) }
        // Turbo needs high-speed mode, as in the hub: turning high-speed off also turns turbo off.
        let tracking = new.hyperMode && new.trackingMode
        if new.hyperMode != old.hyperMode { try set(1, 0x0B, 2, [p, new.hyperMode ? 1 : 0]) }
        if tracking != old.trackingMode { try set(1, 0x13, 2, [p, tracking ? 1 : 0]) }
        if new.angleTune != old.angleTune {
            let value = min(30, max(-30, new.angleTune))
            try set(1, 0x14, 2, [p, UInt8(truncatingIfNeeded: value)])
        }
        if new.sleepSeconds != old.sleepSeconds {
            let value = min(65535, max(1, new.sleepSeconds))
            try set(0, 0x07, 3, [p, UInt8(value >> 8), UInt8(value & 0xFF)])
        }
        let readBack = try readSettings()
        var expected = new
        expected.activeStage = active; expected.trackingMode = tracking
        if !expected.independentXY { expected.stagesY = readBack.stagesY }
        for (name, ok) in [("配置名称", readBack.profileNames == expected.profileNames), ("DPI 档位", readBack.stages == expected.stages), ("当前档位", readBack.activeStage == expected.activeStage),
                           ("回报率", readBack.pollingRate == expected.pollingRate), ("静默高度", readBack.lod == expected.lod),
                           ("去抖动", readBack.debounce == expected.debounce), ("Motion Sync", readBack.motionSync == expected.motionSync),
                           ("直线修正", readBack.angleSnap == expected.angleSnap), ("波纹控制", readBack.rippleControl == expected.rippleControl),
                           ("高速模式", readBack.hyperMode == expected.hyperMode), ("竞技模式", readBack.trackingMode == expected.trackingMode),
                           ("角度微调", readBack.angleTune == expected.angleTune), ("休眠时间", readBack.sleepSeconds == expected.sleepSeconds)] where !ok {
            throw WLMouseError.verify(name)
        }
        return readBack
    }

    // MARK: Encodings

    /// Profile names travel as GBK, like the web hub; at most 30 bytes so the command fits one report.
    static let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GBK_95.rawValue)))
    static let maxNameBytes = 30
    static func encodeName(_ name: String) -> [UInt8] {
        var bytes: [UInt8] = []
        // Drop characters GBK cannot carry and stop before the byte limit, never splitting a character.
        for character in name {
            guard let encoded = String(character).data(using: gbk), bytes.count + encoded.count <= maxNameBytes else { continue }
            bytes += encoded
        }
        return bytes
    }
    static func fitsName(_ name: String) -> String { String(data: Data(encodeName(name)), encoding: gbk) ?? "" }
    static func decodeName(_ reply: [UInt8]) -> String {
        let length = min(Int(reply[8]), reply.count - 9)
        guard length > 0 else { return "" }
        let text = String(data: Data(reply[9..<9 + length]), encoding: gbk) ?? ""
        return text.contains("\0") ? "" : text.trimmingCharacters(in: .whitespaces)
    }

    static let pollingCodes: [Int: UInt8] = [125: 8, 250: 4, 500: 2, 1000: 1, 2000: 32, 4000: 64, 8000: 128]
    static func pollingCode(_ rate: Int) -> UInt8? { pollingCodes[rate] }
    static func pollingRate(code: UInt8) -> Int { pollingCodes.first { $0.value == (code == 16 ? 1 : code) }?.key ?? 1000 }
    /// 0.7 mm travels as 7 | 0x80, whole millimetres as themselves, 1.x as 1 << 4 | x.
    static func encodeLOD(_ mm: Double) -> UInt8 {
        let tenths = Int((mm * 10).rounded())
        if tenths < 10 { return UInt8(tenths) | 0x80 }
        if tenths % 10 == 0 { return UInt8(tenths / 10) }
        return UInt8(tenths / 10) << 4 | UInt8(tenths % 10)
    }
    static func decodeLOD(_ byte: UInt8) -> Double {
        if byte >= 0x80 { return Double(byte - 0x80) / 10 }
        if byte == 1 || byte == 2 { return Double(byte) }
        return Double(Int(byte >> 4) * 10 + Int(byte & 0x0F)) / 10
    }
}
