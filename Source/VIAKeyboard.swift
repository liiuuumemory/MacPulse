import Foundation
import IOKit.hid

enum VIAError: LocalizedError {
    case openFailed, noReply(UInt8), unsupported(UInt8), protocolMismatch(Int, Int), macrosTooLarge(Int, Int), verify(String)
    var errorDescription: String? {
        switch self {
        case .openFailed: return "无法打开键盘的 VIA 通道（可能正被 VIA 网页或官方配置器占用）"
        case .noReply(let command): return String(format: "键盘没有回应命令 0x%02X，请重新插拔后再试", command)
        case .unsupported(let command): return String(format: "键盘固件不支持命令 0x%02X", command)
        case .protocolMismatch(let found, let expected): return "键盘固件的 VIA 协议是 v\(found)，MacPulse 按 v\(expected) 适配，为安全起见不做修改"
        case .macrosTooLarge(let used, let size): return "宏一共 \(used) 字节，超过键盘的 \(size) 字节容量"
        case .verify(let what): return "写入后读回的\(what)与设定不一致"
        }
    }
}

/// A keyboard's VIA raw HID interface (usage page 0xFF60, usage 0x61): 32-byte output reports, each answered
/// by a 32-byte input report that echoes the command byte, or 0xFF for a command the firmware does not know.
/// Used only on DeviceIO.queue; replies are pumped on that thread's run loop in a private mode.
final class VIAChannel {
    let device: IOHIDDevice
    private var reply: [UInt8]?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private static let mode = CFRunLoopMode(rawValue: "local.macpulse.via" as CFString)

    private init(device: IOHIDDevice) { self.device = device }
    deinit { buffer.deallocate() }

    /// The raw interface of one keyboard; `location` tells two identical boards apart.
    static func find(vendorID: Int, productID: Int, location: Int) -> VIAChannel? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID,
                                                kIOHIDPrimaryUsagePageKey: 0xFF60, kIOHIDPrimaryUsageKey: 0x61] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        let match = devices.first { IOHIDDeviceGetProperty($0, kIOHIDLocationIDKey as CFString) as? Int == location } ?? devices.first
        return match.map(VIAChannel.init)
    }

    func withOpen<T>(_ body: () throws -> T) throws -> T {
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { throw VIAError.openFailed }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), Self.mode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, _, report, length in
            guard let context else { return }
            Unmanaged<VIAChannel>.fromOpaque(context).takeUnretainedValue().reply = Array(UnsafeBufferPointer(start: report, count: length))
        }, Unmanaged.passUnretained(self).toOpaque())
        defer {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), Self.mode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        return try body()
    }

    /// One command and its reply; a missing reply is retried twice.
    func transact(_ command: [UInt8]) throws -> [UInt8] {
        let packet = command + [UInt8](repeating: 0, count: max(0, 32 - command.count))
        for _ in 0..<3 {
            reply = nil
            guard IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, packet, packet.count) == kIOReturnSuccess else { usleep(50_000); continue }
            let deadline = Date().addingTimeInterval(0.4)
            while reply == nil && Date() < deadline { _ = CFRunLoopRunInMode(Self.mode, 0.01, true) }
            guard let answer = reply, answer.count >= 4 else { continue }
            if answer[0] == command[0] { return answer }
            if answer[0] == 0xFF { throw VIAError.unsupported(command[0]) }
        }
        throw VIAError.noReply(command[0])
    }

    // MARK: Reads

    func protocolVersion() throws -> Int { let r = try transact([0x01]); return Int(r[1]) << 8 | Int(r[2]) }
    func layerCount() throws -> Int { Int(try transact([0x11])[1]) }
    func macroCount() throws -> Int { Int(try transact([0x0C])[1]) }
    func macroBufferSize() throws -> Int { let r = try transact([0x0D]); return Int(r[1]) << 8 | Int(r[2]) }
    /// Reads `size` bytes from `start`, 28 at a time, with a buffer command (0x12 keymap, 0x0E macros).
    func readBuffer(_ command: UInt8, from start: Int = 0, size: Int) throws -> [UInt8] {
        var bytes: [UInt8] = []
        while bytes.count < size {
            let offset = start + bytes.count, count = min(28, size - bytes.count)
            let r = try transact([command, UInt8(offset >> 8), UInt8(offset & 0xFF), UInt8(count)])
            bytes += r[4..<4 + count]
        }
        return bytes
    }
    func encoder(layer: Int, index: Int, clockwise: Bool) throws -> UInt16 {
        let r = try transact([0x14, UInt8(layer), UInt8(index), clockwise ? 1 : 0])
        return UInt16(r[4]) << 8 | UInt16(r[5])
    }
    /// A custom menu value (VIA 0x08): channel, value id, then the value's bytes.
    func value(channel: UInt8, id: UInt8) throws -> [UInt8] {
        let r = try transact([0x08, channel, id])
        guard r[1] == channel, r[2] == id else { throw VIAError.noReply(0x08) }
        return Array(r[3...])
    }

    // MARK: Writes

    func setKeycode(layer: Int, row: Int, col: Int, _ code: UInt16) throws {
        _ = try transact([0x05, UInt8(layer), UInt8(row), UInt8(col), UInt8(code >> 8), UInt8(code & 0xFF)])
    }
    func setEncoder(layer: Int, index: Int, clockwise: Bool, _ code: UInt16) throws {
        _ = try transact([0x15, UInt8(layer), UInt8(index), clockwise ? 1 : 0, UInt8(code >> 8), UInt8(code & 0xFF)])
    }
    func writeMacroBuffer(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let chunk = Array(bytes[offset..<min(bytes.count, offset + 28)])
            _ = try transact([0x0F, UInt8(offset >> 8), UInt8(offset & 0xFF), UInt8(chunk.count)] + chunk)
            offset += chunk.count
        }
    }
    /// Sets a lighting value without saving it (the board shows it until replugged).
    func setValue(channel: UInt8, id: UInt8, _ bytes: [UInt8]) throws { _ = try transact([0x07, channel, id] + bytes) }
    /// Commits a channel's current values to the board's EEPROM.
    func save(channel: UInt8) throws { _ = try transact([0x09, channel]) }
}

/// Reads and writes a whole keyboard over VIA. Only the commands below are ever sent; MacPulse never sends
/// bootloader jump (0x0B), EEPROM reset (0x0A), keymap reset (0x06), macro reset (0x10) or get-keyboard-value
/// (0x02, which stalls the BNK16), and never presses the definitions' reboot / factory reset / upgrade buttons.
enum VIAKeyboard {
    static func read(_ channel: VIAChannel, model: KeyboardModel) throws -> KeyboardState {
        let version = try channel.protocolVersion()
        guard version == model.protocolVersion else { throw VIAError.protocolMismatch(version, model.protocolVersion) }
        let layers = try channel.layerCount()
        let perLayer = model.rows * model.cols
        // One layer at a time: the BNK16 returns zeros for the part of a read that crosses into the next layer.
        let keymap = try (0..<layers).map { layer in
            let raw = try channel.readBuffer(0x12, from: layer * perLayer * 2, size: perLayer * 2)
            return stride(from: 0, to: raw.count - 1, by: 2).map { UInt16(raw[$0]) << 8 | UInt16(raw[$0 + 1]) }
        }
        let encoders = try (0..<layers).map { layer in
            try model.knobs.map { knob in [try channel.encoder(layer: layer, index: knob.index, clockwise: false),
                                           try channel.encoder(layer: layer, index: knob.index, clockwise: true)] }
        }
        let count = try channel.macroCount()
        let size = try channel.macroBufferSize()
        let macros = MacroCodec.decode(try channel.readBuffer(0x0E, size: size), count: count)
        var lighting: KeyboardLightingValues?
        if let menu = model.lighting {
            var values = KeyboardLightingValues()
            values.effect = Int(try channel.value(channel: menu.channel, id: menu.effectID)[0])
            values.brightness = Int(try channel.value(channel: menu.channel, id: menu.brightnessID)[0])
            if let id = menu.speedID { values.speed = Int(try channel.value(channel: menu.channel, id: id)[0]) }
            if let id = menu.colorID {
                let color = try channel.value(channel: menu.channel, id: id)
                values.hue = Int(color[0]); values.saturation = Int(color[1])
            }
            lighting = values
        }
        return KeyboardState(layers: layers, keymap: keymap, encoders: encoders, macroCount: count, macroBufferSize: size,
                             macros: macros, lighting: lighting)
    }

    /// Lighting values in the board's own order; `save` commits them.
    static func setLighting(_ channel: VIAChannel, model: KeyboardModel, _ values: KeyboardLightingValues, over old: KeyboardLightingValues?, save: Bool) throws {
        guard let menu = model.lighting else { return }
        func clamp(_ value: Int, _ range: ClosedRange<Int>) -> UInt8 { UInt8(min(range.upperBound, max(range.lowerBound, value))) }
        if values.brightness != old?.brightness { try channel.setValue(channel: menu.channel, id: menu.brightnessID, [clamp(values.brightness, menu.brightness)]) }
        if let id = menu.speedID, let range = menu.speed, values.speed != old?.speed { try channel.setValue(channel: menu.channel, id: id, [clamp(values.speed, range)]) }
        if let id = menu.colorID, values.hue != old?.hue || values.saturation != old?.saturation {
            try channel.setValue(channel: menu.channel, id: id, [clamp(values.hue, 0...255), clamp(values.saturation, 0...255)])
        }
        // The effect goes last: turning the light on should show the new brightness and color at once.
        if values.effect != old?.effect { try channel.setValue(channel: menu.channel, id: menu.effectID, [clamp(values.effect, 0...255)]) }
        if save { try channel.save(channel: menu.channel) }
    }

    /// Writes only what changed, saves lighting, then reads everything back and checks it.
    static func apply(_ channel: VIAChannel, model: KeyboardModel, _ new: KeyboardState, over old: KeyboardState) throws -> KeyboardState {
        for (layer, codes) in new.keymap.enumerated() {
            for (index, code) in codes.enumerated() where old.keymap[layer][index] != code {
                guard !Keycode.blocked(code, model: model) else { continue }
                try channel.setKeycode(layer: layer, row: index / model.cols, col: index % model.cols, code)
            }
        }
        for (layer, knobs) in new.encoders.enumerated() {
            for (index, codes) in knobs.enumerated() {
                for direction in 0..<2 where old.encoders[layer][index][direction] != codes[direction] && !Keycode.blocked(codes[direction], model: model) {
                    try channel.setEncoder(layer: layer, index: model.knobs[index].index, clockwise: direction == 1, codes[direction])
                }
            }
        }
        let macroBytes = MacroCodec.encode(new.macros)
        if macroBytes != MacroCodec.encode(old.macros) {
            guard macroBytes.count <= new.macroBufferSize else { throw VIAError.macrosTooLarge(macroBytes.count, new.macroBufferSize) }
            // The whole buffer, so bytes left from longer old macros cannot run as part of a new one.
            try channel.writeMacroBuffer(macroBytes + [UInt8](repeating: 0, count: new.macroBufferSize - macroBytes.count))
        }
        if let lighting = new.lighting, lighting != old.lighting {
            try setLighting(channel, model: model, lighting, over: nil, save: true)
        }
        let readBack = try read(channel, model: model)
        var expected = new.keymap
        for (layer, codes) in expected.enumerated() {
            for index in codes.indices where Keycode.blocked(codes[index], model: model) { expected[layer][index] = old.keymap[layer][index] }
        }
        if readBack.keymap != expected { throw VIAError.verify("键位") }
        var expectedKnobs = new.encoders
        for (layer, knobs) in expectedKnobs.enumerated() {
            for (index, codes) in knobs.enumerated() {
                for direction in 0..<2 where Keycode.blocked(codes[direction], model: model) {
                    expectedKnobs[layer][index][direction] = old.encoders[layer][index][direction]
                }
            }
        }
        if readBack.encoders != expectedKnobs { throw VIAError.verify("旋钮") }
        if MacroCodec.encode(readBack.macros) != macroBytes { throw VIAError.verify("宏") }
        if let lighting = new.lighting, let back = readBack.lighting, !lightingMatches(back, lighting, model: model) { throw VIAError.verify("灯光") }
        return readBack
    }

    /// Values the effect does not use (speed, color) are not compared, and brightness is clamped like the board does.
    static func lightingMatches(_ a: KeyboardLightingValues, _ b: KeyboardLightingValues, model: KeyboardModel) -> Bool {
        guard let menu = model.lighting else { return true }
        let range = menu.brightness
        func clamped(_ v: Int) -> Int { min(range.upperBound, max(range.lowerBound, v)) }
        return a.effect == b.effect && clamped(a.brightness) == clamped(b.brightness)
            && (menu.speedID == nil || a.speed == b.speed)
            && (menu.colorID == nil || (a.hue == b.hue && a.saturation == b.saturation))
    }
}

/// Wired keyboards as macOS lists them: USB HID devices whose primary usage is a keyboard. Only properties
/// are read, so no device is opened and no input monitoring permission is needed. Callbacks run on DeviceIO.queue.
final class WiredKeyboardWatcher {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var pending = false
    var onChange: (([WiredKeyboard]) -> Void)?
    /// WLMOUSE and Logitech receivers also present a keyboard interface; they belong under mice.
    private static let mouseVendors: Set<Int> = [0x36A7, 0x046D]

    init() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: 6] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            Unmanaged<WiredKeyboardWatcher>.fromOpaque(context).takeUnretainedValue().devicesChanged()
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, callback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, callback, context)
        IOHIDManagerSetDispatchQueue(manager, DeviceIO.queue)
        IOHIDManagerActivate(manager)
    }
    deinit { IOHIDManagerCancel(manager) }

    static func keyboards(_ devices: Set<IOHIDDevice>) -> [WiredKeyboard] {
        var seen = Set<String>()
        return devices.compactMap { device -> WiredKeyboard? in
            func property(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
            guard property(kIOHIDTransportKey) as? String == "USB" else { return nil }
            let vendor = property(kIOHIDVendorIDKey) as? Int ?? 0, product = property(kIOHIDProductIDKey) as? Int ?? 0
            let location = property(kIOHIDLocationIDKey) as? Int ?? 0
            let name = (property(kIOHIDProductKey) as? String ?? "USB 键盘").trimmingCharacters(in: .whitespaces)
            guard !mouseVendors.contains(vendor),
                  !["receiver", "dongle", "mouse", "接收器"].contains(where: { name.localizedCaseInsensitiveContains($0) }) else { return nil }
            let id = String(format: "usb-%04x-%04x-%08x", vendor, product, location)
            guard seen.insert(id).inserted else { return nil }
            return WiredKeyboard(id: id, name: name.isEmpty ? "USB 键盘" : name, vendorID: vendor, productID: product, location: location)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// One keyboard shows several interfaces; wait half a second for them to settle, then report the list once.
    private func devicesChanged() {
        guard !pending else { return }
        pending = true
        DeviceIO.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.pending = false
            self.onChange?(Self.keyboards(IOHIDManagerCopyDevices(self.manager) as? Set<IOHIDDevice> ?? []))
        }
    }
}

/// A full copy of a keyboard's keymap, knobs, macros and lighting, taken before MacPulse first writes to it.
struct KeyboardBackup: Codable {
    let model: String
    let date: Date
    let layers: Int
    let keymap: [[UInt16]]
    let encoders: [[[UInt16]]]
    let macroCount: Int
    let macroBufferSize: Int
    let macroBytes: [UInt8]
    let lighting: KeyboardLightingValues?

    init(model: KeyboardModel, state: KeyboardState, date: Date = Date()) {
        self.model = model.name; self.date = date
        layers = state.layers; keymap = state.keymap; encoders = state.encoders
        macroCount = state.macroCount; macroBufferSize = state.macroBufferSize
        macroBytes = MacroCodec.encode(state.macros); lighting = state.lighting
    }
    var state: KeyboardState {
        KeyboardState(layers: layers, keymap: keymap, encoders: encoders, macroCount: macroCount, macroBufferSize: macroBufferSize,
                      macros: MacroCodec.decode(macroBytes, count: macroCount), lighting: lighting)
    }
    /// A backup restores only onto the same board shape.
    func fits(_ state: KeyboardState) -> Bool {
        layers == state.layers && keymap.map(\.count) == state.keymap.map(\.count) && encoders.map(\.count) == state.encoders.map(\.count)
            && macroCount == state.macroCount && macroBufferSize == state.macroBufferSize
    }

    static let keep = 20
    static func folder(_ model: KeyboardModel) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = model.name.replacingOccurrences(of: "/", with: "-")
        return base.appendingPathComponent("MacPulse/Keyboards/\(name)", isDirectory: true)
    }
    static func list(_ model: KeyboardModel) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(model), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    static func save(_ backup: KeyboardBackup, model: KeyboardModel) throws -> URL {
        let folder = folder(model)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HHmmss"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let url = folder.appendingPathComponent(formatter.string(from: backup.date) + ".json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(backup).write(to: url, options: .atomic)
        for old in list(model).dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
        return url
    }
    static func load(_ url: URL) throws -> KeyboardBackup {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(KeyboardBackup.self, from: Data(contentsOf: url))
    }
}
