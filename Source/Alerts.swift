import Foundation
import AppKit
import UserNotifications

struct AlertSettings: Codable, Equatable {
    var enabled = false
    var cpuTemperature = true
    var cpuTemperatureLimit = 95.0
    var memoryPressure = true
    var diskFree = true
    var diskFreeLimitGB = 20.0
    var battery = true
    var batteryLimit = 15.0
    var aiQuota = true
    var aiQuotaLimit = 20.0
    func sanitized() -> Self {
        var c = self
        c.cpuTemperatureLimit = min(110, max(60, cpuTemperatureLimit.isFinite ? cpuTemperatureLimit : 95))
        c.diskFreeLimitGB = min(500, max(1, diskFreeLimitGB.isFinite ? diskFreeLimitGB : 20))
        c.batteryLimit = min(50, max(5, batteryLimit.isFinite ? batteryLimit : 15))
        c.aiQuotaLimit = min(50, max(5, aiQuotaLimit.isFinite ? aiQuotaLimit : 20))
        return c
    }
}

/// Edge-triggered rules: a condition must hold for `sustain` seconds, notifies once, and re-arms
/// only after it clears. `cooldown` limits how soon a flapping condition may notify again.
/// Free of notification APIs so the self-test can drive it with synthetic time.
struct AlertEngine {
    private struct Rule { var since: Date?; var firedAt: Date?; var armed = true }
    private var rules: [String: Rule] = [:]
    func isLatched(_ id: String) -> Bool { rules[id]?.armed == false }
    mutating func evaluate(_ id: String, active: Bool, now: Date, sustain: TimeInterval = 0, cooldown: TimeInterval = 1800) -> Bool {
        var rule = rules[id] ?? Rule()
        defer { rules[id] = rule }
        guard active else { rule.since = nil; rule.armed = true; return false }
        let since = rule.since ?? now
        rule.since = since
        guard rule.armed, now.timeIntervalSince(since) >= sustain else { return false }
        if let fired = rule.firedAt, now.timeIntervalSince(fired) < cooldown { return false }
        rule.armed = false; rule.firedAt = now
        return true
    }
}

final class AlertCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    struct Notice: Equatable { let id: String; let title: String; let body: String }
    @Published var settings: AlertSettings {
        didSet {
            // Values come from fixed pickers; stored data is sanitized on load. Reassigning here would recurse.
            guard live else { return }
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "alerts.v1") }
            if settings.enabled && !oldValue.enabled { requestAuthorization() }
        }
    }
    @Published var status = ""
    private var engine = AlertEngine()
    private let live: Bool

    /// `live: false` (self-test) never touches saved settings or the notification system.
    init(live: Bool = true) {
        self.live = live
        if live, let data = UserDefaults.standard.data(forKey: "alerts.v1"), let stored = try? JSONDecoder().decode(AlertSettings.self, from: data) {
            settings = stored.sanitized()
        } else { settings = AlertSettings() }
        super.init()
        if live && Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
    }

    /// Pure rule evaluation; returns what should be shown now.
    func evaluate(_ s: Sample, usage: AIUsageMonitor?, now: Date = Date()) -> [Notice] {
        let c = settings
        guard c.enabled else { return [] }
        var notices: [Notice] = []
        if c.cpuTemperature, let temperature = s.cpuTemp {
            // 5 °C hysteresis so a reading hovering at the limit does not re-arm.
            let limit = engine.isLatched("cpuTemp") ? c.cpuTemperatureLimit - 5 : c.cpuTemperatureLimit
            if engine.evaluate("cpuTemp", active: temperature >= limit, now: now, sustain: 30) {
                notices.append(Notice(id: "cpuTemp", title: "CPU 温度过高",
                                      body: "已持续 30 秒不低于 \(Format.number(c.cpuTemperatureLimit, suffix: " °C"))，当前 \(Format.number(temperature, suffix: " °C", decimals: 1))。"))
            }
        }
        if c.memoryPressure, s.memoryValid,
           engine.evaluate("memory", active: s.pressure == "紧张", now: now, sustain: 30) {
            notices.append(Notice(id: "memory", title: "内存压力紧张",
                                  body: "已用 \(Format.bytes(s.memoryUsed)) / \(Format.bytes(s.memoryTotal))，交换 \(Format.bytes(s.swap))。可在 MacPulse 进程页查看占用最高的程序。"))
        }
        if c.diskFree, s.diskTotal > 0 {
            let limit = c.diskFreeLimitGB * 1_073_741_824
            if engine.evaluate("disk", active: s.diskFree < limit, now: now, cooldown: 6 * 3600) {
                notices.append(Notice(id: "disk", title: "磁盘空间不足", body: "可用 \(Format.bytes(s.diskFree))，低于 \(Format.number(c.diskFreeLimitGB)) GB。"))
            }
        }
        if c.battery, let battery = s.batteryPercent,
           engine.evaluate("battery", active: battery <= c.batteryLimit && !s.charging, now: now) {
            notices.append(Notice(id: "battery", title: "电量低", body: "剩余 \(Format.number(battery, suffix: "%"))，未连接电源。"))
        }
        if c.aiQuota, let usage {
            for provider in AIProvider.quotaProviders {
                guard let quota = usage.remaining(provider, at: now), !quota.stale else { continue }
                if engine.evaluate("quota." + provider.rawValue, active: quota.percent < c.aiQuotaLimit, now: now, cooldown: 3600) {
                    notices.append(Notice(id: "quota." + provider.rawValue, title: "\(provider.title) 额度即将用完",
                                          body: "\(quota.label)剩余 \(Format.number(quota.percent, suffix: "%"))，\(UsageFormat.countdown(quota.resetAt, now: now))。"))
                }
            }
        }
        return notices
    }

    func check(_ s: Sample, usage: AIUsageMonitor?) {
        for notice in evaluate(s, usage: usage) { post(notice) }
    }

    func post(_ notice: Notice) {
        guard live, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title; content.body = notice.body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }

    func sendTest() {
        requestAuthorization { [weak self] granted in
            if granted { self?.post(Notice(id: "test", title: "MacPulse 提醒", body: "通知已开启，触发条件满足时会在这里提醒。")) }
        }
    }

    func requestAuthorization(_ completion: ((Bool) -> Void)? = nil) {
        guard live, Bundle.main.bundleIdentifier != nil else { completion?(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.status = granted ? "" : "通知未获允许，请在“系统设置 → 通知 → MacPulse”中开启。"
                completion?(granted)
            }
        }
    }

    // A menu bar app is always "active"; show banners anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
