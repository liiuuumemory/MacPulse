import Foundation
import IOKit
import IOKit.hid

struct PeripheralBattery: Identifiable, Equatable {
    var id: String { key }
    /// Stable identity: "wl-<pid>", "logi-<device>" or "bt-<name>"; lets views join battery with settings.
    let key: String
    let name: String
    let percent: Double
    let charging: Bool
    let updated: Date
    let source: String
    var isKeyboard: Bool { name.localizedCaseInsensitiveContains("keyboard") || name.contains("键盘") }
    var symbol: String { isKeyboard ? "keyboard" : name.localizedCaseInsensitiveContains("trackpad") ? "rectangle.and.hand.point.up.left" : "computermouse" }
    var stale: Bool { Date().timeIntervalSince(updated) > 120 }
}

/// One stored battery reading; the history feeds the panel's 7-day curve and the runtime estimate.
struct BatteryPoint: Codable, Equatable {
    let date: Date
    let percent: Double
    let charging: Bool
}

enum BatteryHistory {
    static let keep: TimeInterval = 8 * 86_400
    static let spacing: TimeInterval = 600

    /// Days left from the latest discharge run: needs six hours and a two-point drop, otherwise nil.
    static func daysLeft(_ points: [BatteryPoint]) -> Double? {
        guard let last = points.last, !last.charging else { return nil }
        var start = points.count - 1
        // Walk back while the battery was only discharging.
        while start > 0, !points[start - 1].charging, points[start - 1].percent >= points[start].percent - 1 { start -= 1 }
        let first = points[start]
        let hours = last.date.timeIntervalSince(first.date) / 3600
        let drop = first.percent - last.percent
        guard hours >= 6, drop >= 2 else { return nil }
        return last.percent / (drop / hours) / 24
    }
    static func append(_ reading: PeripheralBattery, to points: [BatteryPoint]) -> [BatteryPoint] {
        var list = points.filter { reading.updated.timeIntervalSince($0.date) < keep }
        if let last = list.last, reading.updated.timeIntervalSince(last.date) < spacing, last.charging == reading.charging { return list }
        list.append(BatteryPoint(date: reading.updated, percent: reading.percent, charging: reading.charging))
        return list
    }
}

/// Reads wireless peripheral batteries without writing any settings:
/// devices that publish `BatteryPercent` in the I/O Registry (Apple Bluetooth accessories), and
/// WLMOUSE receivers through the read-only battery query (0x83) their official web hub sends.
enum PeripheralReader {
    static let wlmouseVendor = 0x36a7

    static func read(now: Date = Date()) -> [PeripheralBattery] {
        registryBatteries(now: now) + wlmouseBatteries(now: now) + logitechBatteries(now: now)
    }

    // Probing receiver slots is slow, so the Logitech device list is refreshed every ten minutes.
    // Only touched on DeviceIO.queue.
    private static var logitech: [LogitechDevice] = []
    private static var logitechScanned: Date?
    private static func logitechBatteries(now: Date) -> [PeripheralBattery] {
        if logitechScanned.map({ now.timeIntervalSince($0) > 600 }) ?? true {
            logitech = LogitechHIDPP.discover(); logitechScanned = now
        }
        return logitech.compactMap { device in
            device.battery().map { PeripheralBattery(key: "logi-" + device.id, name: device.name, percent: Double($0.percent), charging: $0.charging, updated: now, source: "罗技 HID++") }
        }
    }

    /// Reply layout from the web hub: `A1 .. 02 .. 83 charging percent`, sometimes shifted by the report ID byte.
    static func parseWLMouseReply(_ reply: [UInt8]) -> (charging: Bool, percent: Int)? {
        let offset: Int
        if reply.count > 8 && reply[1] == 0xA1 && reply[4] == 2 && reply[6] == 0x83 { offset = 7 }
        else if reply.count > 7 && reply[0] == 0xA1 && reply[3] == 2 && reply[5] == 0x83 { offset = 6 }
        else { return nil }
        let percent = Int(reply[offset + 1])
        // The receiver answers 0 while the mouse sleeps; that is not a reading.
        guard (1...100).contains(percent) else { return nil }
        return (reply[offset] == 1, percent)
    }

    static func displayName(_ product: String) -> String {
        var name = product.trimmingCharacters(in: .whitespaces)
        for suffix in [" RECEIVER", " Receiver", " 8K", " 4K", " 2K", " 1K"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.isEmpty ? "WLMOUSE" : name
    }

    private static func registryBatteries(now: Date) -> [PeripheralBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [PeripheralBattery] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            func property(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            guard let percent = property("BatteryPercent") as? Int, (0...100).contains(percent) else { continue }
            let name = property("Product") as? String ?? "蓝牙设备"
            result.append(PeripheralBattery(key: "bt-" + name, name: name, percent: Double(percent), charging: false, updated: now, source: "系统报告"))
        }
        return result
    }

    private static func wlmouseBatteries(now: Date) -> [PeripheralBattery] {
        WLMouseChannel.find().compactMap { channel in
            guard let value = (try? channel.withOpen { try channel.battery() }) ?? nil else { return nil }
            let name = channel.model?.name ?? displayName(channel.product)
            return PeripheralBattery(key: "wl-\(channel.productID)", name: name, percent: Double(value.percent), charging: value.charging, updated: now, source: "WLMOUSE 接收器")
        }
    }
}
