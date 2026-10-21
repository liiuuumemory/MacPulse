import AppKit
import SwiftUI
import Combine
import ServiceManagement

struct HistoryPoint: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let gpu: Double?
    let memory: Double?
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
    /// Wireless accessory batteries; a sleeping device keeps its last reading.
    private(set) var peripherals: [PeripheralBattery] = []
    /// Ten-minute battery readings per accessory for the last eight days; numbers only, kept on this Mac.
    private(set) var batteryHistory: [String: [BatteryPoint]] = {
        guard let data = UserDefaults.standard.data(forKey: "peripherals.history.v1"),
              let stored = try? JSONDecoder().decode([String: [BatteryPoint]].self, from: data) else { return [:] }
        return stored
    }()
    private var peripheralTimer: DispatchSourceTimer?
    private var peripheralsReadAt: Date?
    private var peripheralQueue: DispatchQueue { DeviceIO.queue }
    /// Mouse settings for the settings window; shares the device queue with battery polling.
    let mice = MouseCenter()
    /// Optional fan control; does nothing until the user turns it on.
    let fan = FanController()
    @Published var chip = "正在读取硬件…"
    @Published var model = ""
    @Published var interval: Double {
        didSet { UserDefaults.standard.set(interval, forKey: "interval"); restart() }
    }
    @Published var menuConfiguration: MenuConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(menuConfiguration.sanitized()) {
                // 1.7 widgets live under v2; v1 stays readable by older builds.
                UserDefaults.standard.set(data, forKey: "menuConfiguration.v2")
            }
            onChange?()
        }
    }
    @Published var menuPresets: [MenuLayoutPreset] {
        didSet {
            if let data = try? JSONEncoder().encode(menuPresets) { UserDefaults.standard.set(data, forKey: "menuPresets.v1") }
        }
    }
    /// The preset applied last (a built-in id or a saved preset's UUID), so later edits can be saved back to it.
    @Published var menuPresetSource: String? {
        didSet { UserDefaults.standard.set(menuPresetSource, forKey: "menuPresets.source") }
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
        if let data = UserDefaults.standard.data(forKey: "menuConfiguration.v2") ?? UserDefaults.standard.data(forKey: "menuConfiguration.v1"),
           let stored = try? JSONDecoder().decode(MenuConfiguration.self, from: data) {
            menuConfiguration = stored.sanitized()
        } else {
            menuConfiguration = .reference
        }
        let presets = UserDefaults.standard.data(forKey: "menuPresets.v1").flatMap { try? JSONDecoder().decode([MenuLayoutPreset].self, from: $0) } ?? []
        menuPresets = presets.prefix(MenuLayoutPreset.maxCount).map { var p = $0; p.configuration = p.configuration.sanitized(); return p }
        menuPresetSource = UserDefaults.standard.string(forKey: "menuPresets.source")
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
        peripheralTimer?.cancel(); peripheralTimer = nil
        lastEnergyDate = nil; lastWatts = nil
    }
    /// Panels and windows register while on screen; hidden ones cost no SwiftUI work.
    /// Saved presets first, then the built-in ones.
    var allMenuPresets: [(id: String, name: String, configuration: MenuConfiguration, builtIn: Bool)] {
        menuPresets.map { ($0.id.uuidString, $0.name, $0.configuration, false) } + MenuConfiguration.presets.map { ($0.id, $0.name, $0.value, true) }
    }
    /// The preset the menu bar shows right now; the one applied last wins over an identical twin.
    var currentMenuPresetID: String? {
        let all = allMenuPresets
        if let source = menuPresetSource, all.contains(where: { $0.id == source && $0.configuration.matches(menuConfiguration) }) { return source }
        return all.first { $0.configuration.matches(menuConfiguration) }?.id
    }
    func applyMenuPreset(_ id: String) {
        guard let preset = allMenuPresets.first(where: { $0.id == id }) else { return }
        menuPresetSource = id
        menuConfiguration = preset.configuration
    }
    /// Saves `configuration`, or the current layout (which then counts as applied from the new preset).
    @discardableResult func saveMenuPreset(named name: String, configuration: MenuConfiguration? = nil) -> MenuLayoutPreset? {
        guard menuPresets.count < MenuLayoutPreset.maxCount else { return nil }
        let preset = MenuLayoutPreset(name: MenuLayoutPreset.cleanName(name, existing: menuPresets), configuration: (configuration ?? menuConfiguration).sanitized())
        menuPresets.append(preset)
        if configuration == nil { menuPresetSource = preset.id.uuidString }
        return preset
    }
    func updateMenuPreset(_ id: UUID) {
        guard let index = menuPresets.firstIndex(where: { $0.id == id }) else { return }
        menuPresets[index].configuration = menuConfiguration.sanitized()
        menuPresetSource = id.uuidString
    }
    func renameMenuPreset(_ id: UUID, to name: String) {
        guard let index = menuPresets.firstIndex(where: { $0.id == id }) else { return }
        let others = menuPresets.filter { $0.id != id }
        menuPresets[index].name = MenuLayoutPreset.cleanName(name, existing: others)
    }
    func moveMenuPreset(_ id: UUID, by offset: Int) {
        guard let index = menuPresets.firstIndex(where: { $0.id == id }), menuPresets.indices.contains(index + offset) else { return }
        menuPresets.swapAt(index, index + offset)
    }
    func deleteMenuPreset(_ id: UUID) {
        menuPresets.removeAll { $0.id == id }
        if menuPresetSource == id.uuidString { menuPresetSource = nil }
    }

    func setVisible(_ id: String, _ visible: Bool) {
        if visible { objectWillChange.send(); viewers.insert(id) } else { viewers.remove(id) }
        // Opening a view refreshes accessory batteries if the last read is older than 15 seconds.
        if visible, timer != nil, peripheralsReadAt.map({ Date().timeIntervalSince($0) > 15 }) ?? true { readPeripherals() }
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
        // Accessory batteries change slowly; one query a minute is enough.
        let peripheralSource = DispatchSource.makeTimerSource(queue: peripheralQueue)
        peripheralSource.schedule(deadline: .now() + 1, repeating: 60, leeway: .seconds(10))
        peripheralSource.setEventHandler { [weak self] in self?.readPeripheralsNow(version: version) }
        peripheralTimer = peripheralSource; peripheralSource.resume()
    }
    private func readPeripherals() {
        let version = generation
        peripheralQueue.async { [weak self] in self?.readPeripheralsNow(version: version) }
    }
    private func readPeripheralsNow(version: UInt64) {
        let fresh = PeripheralReader.read()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == version else { return }
            self.peripheralsReadAt = Date()
            self.mergePeripherals(fresh)
        }
    }
    func mergePeripherals(_ fresh: [PeripheralBattery]) {
        var merged = fresh
        // Keep a sleeping device's last reading for up to a day.
        for old in peripherals where !fresh.contains(where: { $0.key == old.key }) && Date().timeIntervalSince(old.updated) < 86_400 {
            merged.append(old)
        }
        merged.sort { $0.name < $1.name }
        var history = batteryHistory
        for reading in fresh { history[reading.key] = BatteryHistory.append(reading, to: history[reading.key] ?? []) }
        if history != batteryHistory {
            batteryHistory = history
            if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: "peripherals.history.v1") }
        }
        guard merged != peripherals else { return }
        if hasVisibleViews { objectWillChange.send() }
        peripherals = merged
        onChange?()
    }
    /// `--simulate-fans N` (snapshots only) stands in N fans, so layouts can be checked on any Mac.
    private static let simulatedFans: [FanReading]? = {
        let arguments = CommandLine.arguments
        guard arguments.contains("--snapshot"), let flag = arguments.firstIndex(of: "--simulate-fans"),
              flag + 1 < arguments.count, let count = Int(arguments[flag + 1]) else { return nil }
        let fans = [FanReading(rpm: 2410, min: 1200, max: 6000), FanReading(rpm: 2280, min: 1200, max: 5600), FanReading(rpm: 1890, min: 1000, max: 4900)]
        return Array(fans.prefix(max(0, count)))
    }()
    func accept(_ value: Sample) {
        var value = value
        if let fans = Self.simulatedFans { value.smcAvailable = true; value.fans = fans }
        if hasVisibleViews { objectWillChange.send() }
        if let last = lastEnergyDate, let old = lastWatts, let watts = value.watts {
            let duration = value.date.timeIntervalSince(last)
            if duration > 0 && duration < 15 { energyWh += (old + watts) / 2 * duration / 3600 }
        }
        lastEnergyDate = value.date; lastWatts = value.watts
        sample = value
        let net = networkRates
        history.append(HistoryPoint(date: value.date, cpu: value.cpu, gpu: value.gpu,
                                    memory: value.memoryValid && value.memoryTotal > 0 ? value.memoryUsed / value.memoryTotal * 100 : nil, watts: value.watts, temperature: value.cpuTemp, download: net.0, upload: net.1))
        history.removeAll { $0.date < value.date.addingTimeInterval(-120) }
        if history.count > 241 { history.removeFirst(history.count - 241) }
        alerts.check(value, usage: aiUsage)
        fan.evaluate(cpuTemperature: value.cpuTemp)
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
