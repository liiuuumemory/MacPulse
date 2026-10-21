import AppKit
import SwiftUI
import Combine
import Foundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var panelHost: NSHostingController<PanelView>!
    private var panelHeight: CGFloat = 0
    private var statusConfiguration: MenuConfiguration?
    private var statusLayout: MenuBarLayout?
    private var statusStrings: [String] = []
    private var monitor: Monitor!
    private var subscriptions = Set<AnyCancellable>()
    private var snapshotWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let snapshot = CommandLine.arguments.firstIndex(of: "--snapshot")
        if snapshot == nil,
           let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        // Fixture applies only to this snapshot process; never writes account settings.
        if snapshot != nil && CommandLine.arguments.contains("--snapshot-custom") {
            let budget = CustomQuota(enabled: true, total: 100, used: 24, unit: "USD", period: "month", updatedAt: Date())
            if let data = try? JSONEncoder().encode(budget) {
                UserDefaults.standard.register(defaults: ["ai.custom.codex": data, "ai.custom.claude": data])
            }
        }
        monitor = Monitor(aiProvider: CommandLine.arguments.contains("--claude") ? .claude : nil)
        if snapshot != nil { monitor.setVisible("snapshot", true) }
        if CommandLine.arguments.contains("--ai-settings") { monitor.aiUsage.preferencesTab = "ai" }
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        panelHeight = Self.panelHeight(for: NSScreen.main)
        popover.contentSize = NSSize(width: PanelLayout.width, height: panelHeight)
        panelHost = NSHostingController(rootView: makePanel(height: panelHeight))
        popover.contentViewController = panelHost
        popover.contentViewController?.view.wantsLayer = true
        popover.contentViewController?.view.layer?.backgroundColor = NSColor.clear.cgColor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self; button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        monitor.onChange = { [weak self] in self?.updateStatus() }
        monitor.$pinned.sink { [weak self] pinned in self?.popover.behavior = pinned ? .applicationDefined : .transient }.store(in: &subscriptions)
        updateStatus()
        if let index = snapshot, CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.saveSnapshot(path) }
        } else if CommandLine.arguments.contains("--settings") || CommandLine.arguments.contains("--ai-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.showSettings() }
        } else if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.showPanel() }
        }
    }
    static func panelHeight(for screen: NSScreen?) -> CGFloat {
        min(PanelLayout.height, max(480, (screen?.visibleFrame.height ?? 800) - 50))
    }
    private func makePanel(height: CGFloat) -> PanelView {
        PanelView(monitor: monitor, height: height, dismiss: { [weak self] in self?.popover.performClose(nil) }, openSettings: { [weak self] in self?.showSettings() })
    }
    func updateStatus() {
        guard let button = statusItem?.button else { return }
        // Layout measurement depends only on configuration; rebuild it only when that changes.
        if statusConfiguration != monitor.menuConfiguration || statusLayout == nil {
            statusConfiguration = monitor.menuConfiguration
            statusLayout = MenuBarLayout(config: monitor.menuConfiguration)
            statusStrings = []
        }
        guard let layout = statusLayout else { return }
        let summary = layout.summary(monitor)
        button.toolTip = summary + "\n点击查看总览；右键打开设置"
        button.setAccessibilityLabel("MacPulse，" + summary)
        // Redraw only when a visible string or the appearance changed.
        let strings = layout.columns.flatMap { $0.rows.map { $0.metric.displayValue(monitor, config: layout.config) } } + [button.effectiveAppearance.name.rawValue]
        guard strings != statusStrings else { return }
        statusStrings = strings
        // The width is configuration-only; no sample or rendered string can change it.
        statusItem.length = layout.width
        button.title = ""
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            button.image = layout.image(monitor)
        }
    }
    @objc func showSettings() {
        popover?.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "MacPulse 设置"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 620, height: 620)
            window.contentViewController = NSHostingController(rootView: PreferencesView(monitor: monitor, initialTab: monitor.aiUsage.preferencesTab))
            window.center()
            window.delegate = self
            settingsWindow = window
        }
        monitor.setVisible("settings", true)
        monitor.loginEnabled = SMAppService.mainApp.status == .enabled
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "显示监控面板", action: #selector(openPanel), keyEquivalent: "").target = self
            menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "退出 MacPulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else { showPanel() }
    }
    @objc func openPanel() { showPanel() }
    func popoverWillShow(_ notification: Notification) { monitor.setVisible("panel", true) }
    func popoverDidClose(_ notification: Notification) { monitor.setVisible("panel", false) }
    func windowWillClose(_ notification: Notification) { monitor.setVisible("settings", false) }
    func windowDidMiniaturize(_ notification: Notification) { monitor.setVisible("settings", false) }
    func windowDidDeminiaturize(_ notification: Notification) { monitor.setVisible("settings", true) }
    func showPanel() {
        guard let button = statusItem.button else { return }
        // Follow the screen the menu bar is on now, not the one at launch.
        let height = Self.panelHeight(for: button.window?.screen ?? NSScreen.main)
        if height != panelHeight {
            panelHeight = height
            popover.contentSize = NSSize(width: PanelLayout.width, height: height)
            panelHost.rootView = makePanel(height: height)
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.isOpaque = false
        popover.contentViewController?.view.window?.backgroundColor = .clear
        popover.contentViewController?.view.window?.makeKey()
    }
    func applicationWillTerminate(_ notification: Notification) { monitor?.stop(); monitor?.aiUsage.pause() }
    func saveSnapshot(_ path: String) {
        // Render only our own view, without reading any desktop or other app pixels.
        let tab = CommandLine.arguments.firstIndex(of: "--snapshot-tab").flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil } ?? "overview"
        let dark = CommandLine.arguments.contains("--dark")
        // A neutral backing is used only for offscreen layout verification.
        // Real popovers use the live behind-window visual effect instead.
        if tab == "bar" { saveBarSnapshot(path, dark: dark); return }
        let content: AnyView
        let size: NSSize
        if tab == "overview" {
            let height: CGFloat = CommandLine.arguments.contains("--compact") ? 480 : PanelLayout.height
            content = AnyView(PanelView(monitor: monitor, height: height))
            size = NSSize(width: PanelLayout.width, height: height)
        } else {
            content = AnyView(PreferencesView(monitor: monitor, initialTab: tab == "settings" ? "general" : tab))
            size = CommandLine.arguments.contains("--small-window") ? NSSize(width: 620, height: 620) : NSSize(width: 640, height: 740)
        }
        let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        snapshotWindow = window
        host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(2) }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { exit(3) }
            do { try data.write(to: URL(fileURLWithPath: path)); print("Snapshot saved: \(path)"); NSApp.terminate(nil) }
            catch { fputs("Snapshot failed: \(error)\n", stderr); exit(4) }
        }
    }
    func saveBarSnapshot(_ path: String, dark: Bool) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            let layout = MenuBarLayout(config: monitor.menuConfiguration)
            let bar = layout.image(monitor)
            bar.isTemplate = false
            // Tint the monochrome mask for a faithful standalone menu-bar preview.
            if monitor.menuConfiguration.columns.allSatisfy({ $0.color == "system" }) {
                bar.lockFocus()
                NSColor.labelColor.setFill()
                NSRect(origin: .zero, size: bar.size).fill(using: .sourceIn)
                bar.unlockFocus()
            }
            let size = NSSize(width: layout.width + 24, height: 46)
            let output = NSImage(size: size)
            output.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
            bar.draw(in: NSRect(x: 12, y: 12, width: layout.width, height: 22))
            output.unlockFocus()
            guard let tiff = output.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { exit(5) }
            do { try png.write(to: URL(fileURLWithPath: path)); print("Menu bar snapshot saved: \(path)") }
            catch { exit(6) }
        }
        NSApp.terminate(nil)
    }

}

func diagnostics() {
    let collector = MetricsCollector()
    _ = collector.sample()
    Thread.sleep(forTimeInterval: 1.1)
    let start = ProcessInfo.processInfo.systemUptime
    let sample = collector.sample()
    let duration = ProcessInfo.processInfo.systemUptime - start
    Thread.sleep(forTimeInterval: 1)
    let summaryStart = ProcessInfo.processInfo.systemUptime
    _ = collector.sample(detailed: false)
    let summaryDuration = ProcessInfo.processInfo.systemUptime - summaryStart
    let payload: [String: Any] = [
        "chip": collector.chip,
        "model": collector.model,
        "sampleMilliseconds": duration * 1000,
        "summarySampleMilliseconds": summaryDuration * 1000,
        "cpuPercent": sample.cpu as Any? ?? NSNull(),
        "logicalCores": sample.cores.count,
        "gpuPercent": sample.gpu as Any? ?? NSNull(),
        "cpuTemperatureC": sample.cpuTemp as Any? ?? NSNull(),
        "gpuTemperatureC": sample.gpuTemp as Any? ?? NSNull(),
        "systemPowerW": sample.watts as Any? ?? NSNull(),
        "cpuPowerW": sample.cpuPower as Any? ?? NSNull(),
        "gpuPowerW": sample.gpuPower as Any? ?? NSNull(),
        "anePowerW": sample.anePower as Any? ?? NSNull(),
        "powerSource": sample.powerSource,
        "memoryUsedBytes": sample.memoryUsed,
        "memoryTotalBytes": sample.memoryTotal,
        "memoryPressure": sample.pressure,
        "diskFreeBytes": sample.diskFree,
        "diskReadBytesPerSecond": sample.diskRead as Any? ?? NSNull(),
        "diskWriteBytesPerSecond": sample.diskWrite as Any? ?? NSNull(),
        "networks": sample.networks.map { ["interface": $0.name, "downloadBytesPerSecond": $0.download, "uploadBytesPerSecond": $0.upload, "receivedBytes": $0.received, "sentBytes": $0.sent, "fullCounters": $0.fullCounters] as [String: Any] },
        "temperatureSensors": sample.sensors.filter { $0.kind == "°C" }.count,
        "fans": sample.sensors.filter { $0.kind == "RPM" }.map { ["key": $0.key, "rpm": $0.value] as [String: Any] },
        "thermalState": sample.thermal,
        "smcConnected": sample.smcAvailable,
        "batteryHealthPercent": sample.batteryHealth as Any? ?? NSNull(),
        "batteryCycles": sample.batteryCycles as Any? ?? NSNull(),
        "topProcesses": sample.processes.filter { $0.cpu != nil }.sorted { $0.cpu! > $1.cpu! }.prefix(3).map { ["name": $0.name, "cpuPercent": $0.cpu!, "memoryBytes": $0.memory] as [String: Any] },
        "processesHidden": sample.processesHidden
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
    let valid = sample.cpu.map { (0...100).contains($0) } == true && sample.memoryValid && sample.networkValid && sample.diskTotal > 0
    if !valid { exit(1) }
}
func tests() {
    testAIUsage()
    precondition(counterDelta(200, 100) == 100)
    precondition(counterDelta(100, 200) == 0, "counter reset must not underflow")
    precondition(counterDelta(0x100001000, 0xfffff000) == 8192, "network counters must retain upper 32 bits")
    let network = parseNetworkCounters("""
    Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
    en0 1500 <Link#7> 00:11:22:33:44:55 10 0 478176695034 20 0 21432108979 0
    en0 1500 192.168.0 192.168.0.2 10 - 478176695034 20 - 21432108979 -
    lo0 16384 <Link#1> 10 0 90 10 0 90 0
    """)
    precondition(network.count == 1 && network["en0"]?.0 == 478176695034 && network["en0"]?.1 == 21432108979, "parse full network counters without duplicate IP rows")
    precondition(Format.rate(nil) == "—")
    precondition(Format.bytes(1024) == "1.0 KB")
    precondition(Format.number(.nan) == "—")
    let monitor = Monitor(start: false)
    let base = Date()
    var value = Sample()
    value.date = base; value.watts = 60
    monitor.accept(value)
    value.date = base.addingTimeInterval(6); value.watts = 120
    monitor.accept(value)
    precondition(abs(monitor.energyWh - 0.15) < 0.00001, "energy integrates trapezoidal power")
    value.date = base.addingTimeInterval(1000)
    monitor.accept(value)
    precondition(abs(monitor.energyWh - 0.15) < 0.00001, "sleep gap must not add energy")
    precondition(monitor.history.count == 1, "history must expire")
    value.watts = nil; value.date = base.addingTimeInterval(1001)
    monitor.accept(value)
    value.watts = 120; value.date = base.addingTimeInterval(1002)
    monitor.accept(value)
    precondition(abs(monitor.energyWh - 0.15) < 0.00001, "missing sensors must not be interpolated")
    var configuration = MenuConfiguration.reference
    let encoded = try! JSONEncoder().encode(configuration)
    precondition(try! JSONDecoder().decode(MenuConfiguration.self, from: encoded) == configuration)
    precondition(MenuMetric.rate(1024, bits: false) == "1.0 KB/s")
    precondition(MenuMetric.rate(125000, bits: true) == "1.0 Mb/s")
    precondition(MenuMetric.rate(nil, bits: false) == "—")
    for mode in ["double", "single"] {
        configuration.layout = mode
        let expected = MenuBarLayout(config: configuration)
        precondition(Set(expected.columns.map(\.width)).count == 1, "all menu groups must have equal widths")
        let cpuRow = expected.columns[0].rows[0]
        precondition(cpuRow.width == ceil(("CPU" as NSString).size(withAttributes: [.font: expected.labelFont]).width) + 4 + ceil(("100%" as NSString).size(withAttributes: [.font: expected.font]).width) + 2,
                     "group width must match the original CPU percentage width")
        for speed in [0.0, 1, 9.95, 999, 999.5, 1023, 1024, 10239, 102400, 1022976, 1048576, 1073741824, 1e12] {
            var sample = Sample()
            sample.networkValid = true
            sample.networks = [NetworkValue(name: "en0", download: speed, upload: speed)]
            sample.cpu = 100; sample.memoryValid = true; sample.memoryUsed = sample.memoryTotal
            monitor.accept(sample)
            let actual = MenuBarLayout(config: configuration)
            precondition(actual.width == expected.width)
            precondition(actual.columns.map(\.width) == expected.columns.map(\.width))
            for column in actual.columns { for row in column.rows {
                let string = row.metric.displayValue(monitor, config: configuration) as NSString
                precondition(string.size(withAttributes: [.font: row.valueFont]).width <= row.valueWidth,
                             "formatted metric must fit its reserved slot")
            } }
        }
    }
    configuration.columns = []
    precondition(MenuBarLayout(config: configuration).showsIcon && MenuBarLayout(config: configuration).width > 0)
    var engine = AlertEngine()
    precondition(!engine.evaluate("x", active: true, now: base, sustain: 30), "alerts wait for the sustain period")
    precondition(engine.evaluate("x", active: true, now: base.addingTimeInterval(30), sustain: 30))
    precondition(!engine.evaluate("x", active: true, now: base.addingTimeInterval(60), sustain: 30), "an ongoing condition notifies once")
    precondition(!engine.evaluate("x", active: false, now: base.addingTimeInterval(70)))
    precondition(!engine.evaluate("x", active: true, now: base.addingTimeInterval(80), cooldown: 1800), "flapping respects the cooldown")
    precondition(engine.evaluate("x", active: true, now: base.addingTimeInterval(2000), cooldown: 1800))
    let alerts = AlertCenter(live: false)
    alerts.settings.enabled = true
    var hot = Sample(); hot.cpuTemp = 99
    precondition(alerts.evaluate(hot, usage: nil, now: base).isEmpty)
    precondition(alerts.evaluate(hot, usage: nil, now: base.addingTimeInterval(31)).map(\.id) == ["cpuTemp"], "sustained heat notifies")
    hot.cpuTemp = 92
    precondition(alerts.evaluate(hot, usage: nil, now: base.addingTimeInterval(4000)).isEmpty, "hysteresis keeps the alert latched near the limit")
    hot.cpuTemp = 89
    _ = alerts.evaluate(hot, usage: nil, now: base.addingTimeInterval(4010))
    hot.cpuTemp = 99
    _ = alerts.evaluate(hot, usage: nil, now: base.addingTimeInterval(4020))
    precondition(alerts.evaluate(hot, usage: nil, now: base.addingTimeInterval(4051)).count == 1, "cooling below the hysteresis re-arms")
    var low = Sample(); low.batteryPercent = 10; low.charging = true
    precondition(alerts.evaluate(low, usage: nil, now: base).isEmpty, "charging suppresses the battery alert")
    precondition(UsageFormat.countdown(base.addingTimeInterval(2 * 3600 + 13 * 60), now: base) == "2 小时 13 分后重置")
    precondition(UsageFormat.countdown(base.addingTimeInterval(-1), now: base) == "等待更新")
    precondition(UpdateChecker.isNewer("v1.6", than: "1.5") && UpdateChecker.isNewer("1.5.1", than: "1.5") && UpdateChecker.isNewer("2.0", than: "1.10"))
    precondition(!UpdateChecker.isNewer("v1.5", than: "1.5") && !UpdateChecker.isNewer("1.5.0", than: "1.5") && !UpdateChecker.isNewer("1.9", than: "1.10"), "versions compare numerically")
    precondition(!UpdateChecker.isNewer("nightly", than: "1.5"), "unparseable tags never prompt")
    let release = UpdateChecker.parse(["tag_name": "v1.6", "html_url": "https://evil.example/x", "body": "notes"])!
    precondition(release.version == "1.6" && release.url == UpdateChecker.releasesPage, "only this repository's pages are opened")
    precondition(UpdateChecker(live: false).updateAvailable == false)
    print("PASS: fixed menu widths across units, configuration round-trip, menu formatting, fallback icon; network counters, energy and history; alert sustain, latch, hysteresis and cooldown; update version comparison")
}

if CommandLine.arguments.contains("--diagnose") { diagnostics() }
else if CommandLine.arguments.contains("--test") { tests() }
else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
