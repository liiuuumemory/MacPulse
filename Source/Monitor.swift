import AppKit
import SwiftUI
import Combine
import ServiceManagement

struct HistoryPoint: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let gpu: Double?
    let watts: Double?
    let temperature: Double?
    let download: Double
    let upload: Double
}

final class Monitor: ObservableObject {
    let aiUsage: AIUsageMonitor
    let alerts: AlertCenter
    let updater: UpdateChecker
    // Live readings are not @Published: views are only invalidated while one is visible.
    private(set) var sample = Sample()
    private(set) var history: [HistoryPoint] = []
    private(set) var energyWh = 0.0
    @Published var chip = "正在读取硬件…"
    @Published var model = ""
    @Published var interval: Double {
        didSet { UserDefaults.standard.set(interval, forKey: "interval"); restart() }
    }
    @Published var menuConfiguration: MenuConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(menuConfiguration.sanitized()) {
                UserDefaults.standard.set(data, forKey: "menuConfiguration.v1")
            }
            onChange?()
        }
    }
    @Published var selectedInterface: String {
        didSet { UserDefaults.standard.set(selectedInterface, forKey: "interface"); history.removeAll() }
    }
    @Published var pinned = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var settingsMessage = ""
    private let queue = DispatchQueue(label: "local.macpulse.metrics", qos: .utility)
    private var collector: MetricsCollector?
    private var timer: DispatchSourceTimer?
    private var lastEnergyDate: Date?
    private var lastWatts: Double?
    private var observers: [NSObjectProtocol] = []
    private var generation: UInt64 = 0
    private var viewers = Set<String>()
    private var detailed = false // metrics queue only
    private var screensAsleep = false
    var onChange: (() -> Void)?
    var hasVisibleViews: Bool { !viewers.isEmpty }

    init(start: Bool = true, aiProvider: AIProvider? = nil) {
        aiUsage = AIUsageMonitor(start: start, initialProvider: aiProvider)
        alerts = AlertCenter(live: start)
        updater = UpdateChecker(live: start)
        let saved = UserDefaults.standard.double(forKey: "interval")
        interval = [0.5, 1, 2, 5].contains(saved) ? saved : 1
        if let data = UserDefaults.standard.data(forKey: "menuConfiguration.v1"),
           let stored = try? JSONDecoder().decode(MenuConfiguration.self, from: data) {
            menuConfiguration = stored.sanitized()
        } else {
            menuConfiguration = .reference
        }
        selectedInterface = UserDefaults.standard.string(forKey: "interface") ?? "auto"
        if start {
            restart()
            let center = NSWorkspace.shared.notificationCenter
            observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.stop(); self?.aiUsage.pause() })
            observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.restart(reset: true); self?.aiUsage.resume() })
            // Nobody can see the menu bar with the display off; sample slowly but keep energy and alerts going.
            observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.screensAsleep = true; self?.restart() })
            observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.screensAsleep = false; self?.restart() })
        }
    }
    deinit {
        timer?.cancel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
    func stop() {
        generation &+= 1
        timer?.cancel(); timer = nil
        lastEnergyDate = nil; lastWatts = nil
    }
    /// Panels and windows register while on screen; hidden ones cost no SwiftUI work.
    func setVisible(_ id: String, _ visible: Bool) {
        if visible { objectWillChange.send(); viewers.insert(id) } else { viewers.remove(id) }
        let detailed = !viewers.isEmpty
        queue.async { [weak self] in self?.detailed = detailed }
    }
    func restart(reset: Bool = false) {
        stop()
        let version = generation
        let period = screensAsleep ? max(interval, 5) : interval
        queue.async { [weak self] in
            guard let self else { return }
            if self.collector == nil { self.collector = MetricsCollector() }
            if reset { self.collector?.reset() }
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        // A 10% leeway lets the system coalesce wakeups with other timers.
        source.schedule(deadline: .now(), repeating: period, leeway: .milliseconds(max(20, Int(period * 100))))
        source.setEventHandler { [weak self] in
            guard let self, let collector = self.collector else { return }
            let value = collector.sample(detailed: self.detailed)
            let chip = collector.chip, model = collector.model
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == version else { return }
                if self.chip != chip { self.chip = chip }
                if self.model != model { self.model = model }
                self.accept(value)
            }
        }
        timer = source; source.resume()
    }
    func accept(_ value: Sample) {
        if hasVisibleViews { objectWillChange.send() }
        if let last = lastEnergyDate, let old = lastWatts, let watts = value.watts {
            let duration = value.date.timeIntervalSince(last)
            if duration > 0 && duration < 15 { energyWh += (old + watts) / 2 * duration / 3600 }
        }
        lastEnergyDate = value.date; lastWatts = value.watts
        sample = value
        let net = networkRates
        history.append(HistoryPoint(date: value.date, cpu: value.cpu, gpu: value.gpu, watts: value.watts, temperature: value.cpuTemp, download: net.0, upload: net.1))
        history.removeAll { $0.date < value.date.addingTimeInterval(-120) }
        if history.count > 241 { history.removeFirst(history.count - 241) }
        alerts.check(value, usage: aiUsage)
        onChange?()
    }
    var networks: [NetworkValue] {
        selectedInterface == "auto" ? sample.networks : sample.networks.filter { $0.name == selectedInterface }
    }
    var networkRates: (Double, Double) {
        networks.reduce((0, 0)) { ($0.0 + $1.download, $0.1 + $1.upload) }
    }
    var networkAvailable: Bool { sample.networkValid && !networks.isEmpty }
    var networkLabel: String {
        let active = networks.filter { !$0.address.isEmpty }.map(\.name)
        return active.isEmpty ? "未连接" : active.joined(separator: " + ")
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            settingsMessage = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许 MacPulse。" : ""
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            settingsMessage = "未能更改登录项：\(error.localizedDescription)；请将应用放入 Applications 后重试。"
        }
    }
    func copyReport() {
        let s = sample
        let report = """
        MacPulse · \(s.date.formatted())
        \(chip) / \(model)
        CPU: \(Format.number(s.cpu, suffix: "%", decimals: 1)) · GPU: \(Format.number(s.gpu, suffix: "%"))
        CPU 温度（最高传感器）: \(Format.number(s.cpuTemp, suffix: "°C", decimals: 1))
        GPU 温度（最高传感器）: \(Format.number(s.gpuTemp, suffix: "°C", decimals: 1))
        功耗: \(Format.number(s.watts, suffix: " W", decimals: 1)) [\(s.powerSource)]
        内存: \(Format.bytes(s.memoryUsed)) / \(Format.bytes(s.memoryTotal)) · 压力 \(s.pressure)
        交换空间: \(Format.bytes(s.swap))
        网络（\(networkLabel)）: ↓ \(Format.rate(networkRates.0)) ↑ \(Format.rate(networkRates.1))
        磁盘可用: \(Format.bytes(s.diskFree)) / \(Format.bytes(s.diskTotal))
        热状态: \(s.thermal) · 运行时间: \(Format.uptime(s.uptime))
        \(s.sensors.map { "\($0.name) [\($0.key)]: \(Format.number($0.value, decimals: 1)) \($0.kind)" }.joined(separator: "\n"))
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        settingsMessage = "诊断信息已复制。"
    }
}
