import Foundation
import IOKit.hid

/// Logitech HID++ 2.0 over the vendor collections. Message layout, feature numbers and payload
/// offsets follow OpenLogi (github.com/AprilNEA/OpenLogi, MIT / Apache-2.0).
/// Request: 0x11, device index, feature index, function << 4 | software id, parameters (20 bytes).
enum HIDPPError: Error {
    case timeout, unreachable, feature(UInt8), notPermitted, sendFailed
}

final class HIDPPChannel {
    static let vendorID = 0x046D
    static let softwareID: UInt8 = 0x0A
    let device: IOHIDDevice
    let productID: Int
    let isReceiver: Bool
    fileprivate var inbox: [[UInt8]] = []
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    init(device: IOHIDDevice) {
        self.device = device
        productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        // Unifying, Bolt, Nano and Lightspeed receivers all sit in the 0xC5xx block.
        isReceiver = productID & 0xFF00 == 0xC500
    }
    deinit { buffer.deallocate() }

    static func find() -> [HIDPPChannel] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Long HID++ reports: 0xFF00/0x0002 on receivers and wired devices, 0xFF43/0x0202 over Bluetooth.
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDVendorIDKey: vendorID, kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 0x0002],
            [kIOHIDVendorIDKey: vendorID, kIOHIDPrimaryUsagePageKey: 0xFF43, kIOHIDPrimaryUsageKey: 0x0202]
        ] as CFArray)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return [] }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        return devices.map(HIDPPChannel.init)
    }

    /// Opens, schedules input on this thread's run loop, runs `body`, and tears everything down again.
    func session<T>(_ body: () throws -> T) throws -> T {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnNotPermitted { throw HIDPPError.notPermitted }
        guard result == kIOReturnSuccess else { throw HIDPPError.unreachable }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, _, report, length in
            guard let context else { return }
            Unmanaged<HIDPPChannel>.fromOpaque(context).takeUnretainedValue().inbox.append(Array(UnsafeBufferPointer(start: report, count: length)))
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        defer {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            inbox.removeAll()
        }
        return try body()
    }

    /// Sends one request and waits for its reply (16 payload bytes) or the matching error.
    func request(_ index: UInt8, feature: UInt8, function: UInt8, _ parameters: [UInt8] = [], timeout: TimeInterval = 0.6) throws -> [UInt8] {
        var message = [UInt8](repeating: 0, count: 20)
        message[0] = 0x11; message[1] = index; message[2] = feature; message[3] = function << 4 | Self.softwareID
        for (i, value) in parameters.prefix(16).enumerated() { message[4 + i] = value }
        inbox.removeAll()
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, message, message.count) == kIOReturnSuccess else { throw HIDPPError.sendFailed }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
            while !inbox.isEmpty {
                let reply = inbox.removeFirst()
                guard reply.count >= 7, reply[0] == 0x10 || reply[0] == 0x11, reply[1] == index else { continue }
                if reply[2] == feature && reply[3] == message[3] {
                    return Array(reply.dropFirst(4)) + [UInt8](repeating: 0, count: max(0, 20 - reply.count))
                }
                if reply[2] == 0xFF && reply[3] == feature && reply[4] == message[3] { throw HIDPPError.feature(reply[5]) }
                // HID++ 1.0 error: an empty receiver slot, or a device that is asleep.
                if reply[2] == 0x8F && reply[3] == feature { throw HIDPPError.unreachable }
            }
        }
        throw HIDPPError.timeout
    }
}

struct SmartShiftState: Equatable, CustomStringConvertible {
    /// 1 = free spin, 2 = ratchet.
    var wheelMode: UInt8
    /// Speed threshold for switching to free spin; 255 keeps the ratchet engaged (SmartShift off).
    var autoDisengage: UInt8
    var torque: UInt8?
    var description: String { "mode \(wheelMode) threshold \(autoDisengage)" + (torque.map { " torque \($0)" } ?? "") }
}

final class LogitechDevice: Identifiable {
    static let root: UInt8 = 0
    let channel: HIDPPChannel
    let index: UInt8
    let name: String
    /// Feature ID → index on this device.
    let features: [UInt16: UInt8]
    var id: String { "\(channel.productID)-\(index)" }

    init(channel: HIDPPChannel, index: UInt8, name: String, features: [UInt16: UInt8]) {
        self.channel = channel; self.index = index; self.name = name; self.features = features
    }

    private func call(_ feature: UInt16, _ function: UInt8, _ parameters: [UInt8] = []) -> [UInt8]? {
        guard let featureIndex = features[feature] else { return nil }
        return try? channel.session { try channel.request(index, feature: featureIndex, function: function, parameters) }
    }

    func battery() -> (percent: Int, charging: Bool)? {
        // Unified Battery (0x1004) status: percent, level, charging status.
        if let p = call(0x1004, 1), p[0] > 0 { return (Int(p[0]), [1, 2, 3, 4].contains(p[2])) }
        // Battery Status (0x1000): discharge level, next level, status.
        if let p = call(0x1000, 0), p[0] > 0 { return (Int(p[0]), [1, 2, 3].contains(p[2])) }
        return nil
    }

    func dpi() -> (current: Int, supported: [Int])? {
        guard let list = call(0x2201, 1, [0]), list[0] == 0, let current = call(0x2201, 2, [0]) else { return nil }
        guard let values = Self.parseDPIList(Array(list.dropFirst())) else { return nil }
        return (Int(current[1]) << 8 | Int(current[2]), values)
    }
    func setDPI(_ value: Int) -> Bool {
        call(0x2201, 3, [0, UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) != nil && dpi()?.current == value
    }

    func smartShift() -> SmartShiftState? {
        if let p = call(0x2111, 1) { return SmartShiftState(wheelMode: p[0], autoDisengage: p[1], torque: p[2]) }
        if let p = call(0x2110, 0) { return SmartShiftState(wheelMode: p[0], autoDisengage: p[1], torque: nil) }
        return nil
    }
    func setSmartShift(_ state: SmartShiftState) -> Bool {
        // Zero leaves a field unchanged.
        if features[0x2111] != nil {
            return call(0x2111, 2, [state.wheelMode, state.autoDisengage, state.torque ?? 0]) != nil && smartShift() == state
        }
        return call(0x2110, 1, [state.wheelMode, state.autoDisengage, 0]) != nil && smartShift()?.wheelMode == state.wheelMode
    }

    /// Hi-res wheel (0x2121) mode flags: bit 0 target, bit 1 resolution, bit 2 inverted.
    func scrollInverted() -> Bool? { call(0x2121, 1).map { $0[0] & 0x04 != 0 } }
    func setScrollInverted(_ inverted: Bool) -> Bool {
        guard let mode = call(0x2121, 1) else { return false }
        // Keep target and resolution exactly as they are; only the direction changes.
        let flags = inverted ? mode[0] | 0x04 : mode[0] & ~0x04
        return call(0x2121, 2, [flags, mode[1], mode[2]]) != nil && scrollInverted() == inverted
    }

    /// DPI list: big-endian values, `0b111` in the top bits marks a step up to the next value, 0 ends the list.
    static func parseDPIList(_ bytes: [UInt8]) -> [Int]? {
        var values: [Int] = []
        var offset = 0
        while offset + 1 < bytes.count {
            let value = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            if value == 0 { break }
            if value >> 13 == 0b111 {
                let step = value & 0x1FFF
                guard step > 0, offset + 3 < bytes.count, let start = values.last else { return nil }
                let last = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                guard last >= start else { return nil }
                values += Array(stride(from: start + step, to: last, by: step)) + [last]
                offset += 4
            } else {
                values.append(value)
                offset += 2
            }
        }
        return values.isEmpty ? nil : Array(Set(values)).sorted()
    }
}

enum LogitechHIDPP {
    static let wanted: [UInt16] = [0x0005, 0x1000, 0x1004, 0x2110, 0x2111, 0x2121, 0x2201]
    private(set) static var permissionDenied = false

    /// Finds paired or directly connected HID++ 2.0 devices and maps the features MacPulse uses.
    static func discover() -> [LogitechDevice] {
        permissionDenied = false
        var found: [LogitechDevice] = []
        for channel in HIDPPChannel.find() {
            do {
                let devices = try channel.session { () -> [LogitechDevice] in
                    let candidates: [UInt8] = channel.isReceiver ? [1, 2, 3, 4, 5, 6] : [0xFF]
                    return candidates.compactMap { probe(channel, index: $0) }
                }
                found += devices
            } catch HIDPPError.notPermitted { permissionDenied = true } catch {}
        }
        return found
    }

    private static func probe(_ channel: HIDPPChannel, index: UInt8) -> LogitechDevice? {
        var features: [UInt16: UInt8] = [:]
        for id in wanted {
            // Root getFeature: an index of 0 means the device does not have it.
            guard let reply = try? channel.request(index, feature: LogitechDevice.root, function: 0, [UInt8(id >> 8), UInt8(id & 0xFF)], timeout: 0.4) else {
                if features.isEmpty && id == wanted[0] { return nil }
                continue
            }
            if reply[0] != 0 { features[id] = reply[0] }
        }
        var name = "Logitech 设备"
        if let nameIndex = features[0x0005], let count = try? channel.request(index, feature: nameIndex, function: 0) {
            var bytes: [UInt8] = []
            while bytes.count < Int(count[0]), let part = try? channel.request(index, feature: nameIndex, function: 1, [UInt8(bytes.count)]) {
                bytes += part.prefix(min(16, Int(count[0]) - bytes.count))
            }
            if let decoded = String(bytes: bytes, encoding: .utf8), !decoded.isEmpty { name = decoded }
        }
        return LogitechDevice(channel: channel, index: index, name: name, features: features)
    }

    /// Asks macOS for Input Monitoring, which some Logitech receivers need before their vendor channel opens.
    static func requestAccess() { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
}
