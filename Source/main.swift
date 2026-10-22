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
            // An in-memory sample curve for the fan page; registered defaults are never saved.
            var fan = FanSettings()
            fan.curves = [FanCurve(name: "我的日常均衡", points: FanPreset.find("daily").points!, extraFans: [FanPreset.find("silent").points!])]
            fan.fanNames = ["左侧", "右侧"]
            if let data = try? JSONEncoder().encode(fan) { UserDefaults.standard.register(defaults: ["fan.v1": data]) }
            // Two sample layout presets; the first counts as applied and edited since.
            var work = MenuConfiguration.performance; work.separators = true
            var travel = MenuConfiguration.compact; travel.widgets.append(MenuWidget(.hidden, "battery", labelMode: "none", chart: .battery))
            let presets = [MenuLayoutPreset(name: "工作", configuration: work), MenuLayoutPreset(name: "外出", configuration: travel)]
            if let data = try? JSONEncoder().encode(presets) {
                UserDefaults.standard.register(defaults: ["menuPresets.v1": data, "menuPresets.source": presets[0].id.uuidString])
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
            if CommandLine.arguments.contains("mouse") || CommandLine.arguments.contains("devices") { monitor.mice.refresh() }
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
        let strings = layout.signature(monitor) + [button.effectiveAppearance.name.rawValue]
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
            let window = Self.makeSettingsWindow(monitor: monitor, tab: monitor.aiUsage.preferencesTab)
            window.center()
            window.delegate = self
            settingsWindow = window
        }
        monitor.setVisible("settings", true)
        monitor.loginEnabled = SMAppService.mainApp.status == .enabled
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    /// System Settings–style window: the split view runs full height, under the titlebar.
    static func makeSettingsWindow(monitor: Monitor, tab: String, size: NSSize = NSSize(width: 840, height: 740)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "MacPulse 设置"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 800, height: 620)
        let host = NSHostingController(rootView: PreferencesView(monitor: monitor, initialTab: tab))
        // Lets the split view's toolbar (back / forward, page title) reach this window.
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = host
        window.setContentSize(size)
        return window
    }
    @objc func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "显示监控面板", action: #selector(openPanel), keyEquivalent: "").target = self
            menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
            menu.addItem(NSMenuItem.separator())
            menu.addItem(presetMenu())
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "退出 MacPulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else { showPanel() }
    }
    /// Switches the menu bar layout without opening settings: saved presets, then built-in ones.
    private func presetMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "布局预设", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = monitor.currentMenuPresetID
        let all = monitor.allMenuPresets
        for (index, preset) in all.enumerated() {
            if index > 0 && preset.builtIn && !all[index - 1].builtIn { submenu.addItem(NSMenuItem.separator()) }
            if index == 0 && preset.builtIn { submenu.addItem(withTitle: "还没有保存的预设", action: nil, keyEquivalent: "").isEnabled = false; submenu.addItem(NSMenuItem.separator()) }
            let entry = NSMenuItem(title: preset.name, action: #selector(applyPreset(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = preset.id
            entry.state = preset.id == current ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(withTitle: "管理预设…", action: #selector(showMenuSettings), keyEquivalent: "").target = self
        item.submenu = submenu
        return item
    }
    @objc func applyPreset(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { monitor.applyMenuPreset(id) }
    }
    @objc func showMenuSettings() {
        monitor.aiUsage.preferencesTab = "menu"
        showSettings()
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
    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop(); monitor?.aiUsage.pause()
        // Hand fans back right away instead of waiting for the helper's 45-second watchdog.
        if let fan = monitor?.fan, !fan.passive, fan.settings.enabled, fan.settings.preset != "auto" { _ = FanHelperClient.send("auto") }
    }
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
            let page = CommandLine.arguments.firstIndex(of: "--panel-page").flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil }
            content = AnyView(PanelView(monitor: monitor, height: height, page: page ?? "system"))
            size = NSSize(width: PanelLayout.width, height: height)
        } else {
            let size = CommandLine.arguments.contains("--small-window") ? NSSize(width: 800, height: 620)
                : NSSize(width: 840, height: CommandLine.arguments.contains("--tall") ? 1900 : 740)
            let window = Self.makeSettingsWindow(monitor: monitor, tab: tab == "settings" ? "general" : tab, size: size)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            snapshotWindow = window
            saveWindowSnapshot(window, path)
            return
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
    /// Renders the whole window frame (titlebar and toolbar included) from this process only.
    func saveWindowSnapshot(_ window: NSWindow, _ path: String) {
        guard let frame = window.contentView?.superview else { exit(2) }
        // Materials only draw on screen; --onscreen shows the window so it can be captured with screencapture -l.
        if CommandLine.arguments.contains("--onscreen") {
            window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            print("Window: \(window.windowNumber)"); fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { NSApp.terminate(nil) }
            return
        }
        frame.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { exit(2) }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { exit(3) }
            do { try data.write(to: URL(fileURLWithPath: path)); print("Snapshot saved: \(path)"); NSApp.terminate(nil) }
            catch { fputs("Snapshot failed: \(error)\n", stderr); exit(4) }
        }
    }
    func saveBarSnapshot(_ path: String, dark: Bool) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            // A preset renders in memory only; saved settings are never touched.
            let preset = CommandLine.arguments.firstIndex(of: "--snapshot-menu-preset").flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil }
            let configuration = MenuConfiguration.presets.first { $0.id == preset }?.value ?? monitor.menuConfiguration
            let layout = MenuBarLayout(config: configuration)
            let bar = layout.image(monitor)
            let template = bar.isTemplate
            bar.isTemplate = false
            // Tint the monochrome mask for a faithful standalone menu-bar preview.
            if template {
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
    // Settings saved by 1.6 and earlier migrate to widgets with the same look.
    let legacy = #"{"showLabels":true,"spacing":10,"decimals":false,"fontSize":9,"rateUnit":"bytes","layout":"double","icon":"cpu","columns":[{"id":"498F0E39-5E78-430A-BFAB-18DCCA3FF6CB","top":"cpu","topLabel":"","bottomLabel":"","enabled":true,"color":"system","bottom":"memory"},{"id":"D3B44FEB-57B9-4A3D-9C2A-18C4C111A861","top":"upload","topLabel":"UP","bottomLabel":"","enabled":false,"color":"blue","bottom":"none"}]}"#
    let migrated = try! JSONDecoder().decode(MenuConfiguration.self, from: Data(legacy.utf8))
    precondition(migrated.icon == "cpu" && migrated.widgets.count == 2, "legacy groups migrate")
    precondition(migrated.widgets[0].style == .stacked && migrated.widgets[0].metric == "cpu" && migrated.widgets[0].secondary == "memory")
    precondition(migrated.widgets[1].style == .text && !migrated.widgets[1].enabled && migrated.widgets[1].color == "blue" && migrated.widgets[1].label == "UP")
    var single = try! JSONDecoder().decode(MenuConfiguration.self, from: Data(legacy.replacingOccurrences(of: #""layout":"double""#, with: #""layout":"single""#).utf8))
    precondition(single.widgets.count == 3 && single.widgets.allSatisfy { $0.style == .text }, "single-row groups split side by side")
    single.widgets[0].chart = .ring; single.widgets[0].metric = "fan"
    precondition(single.sanitized().widgets[0].chart == .none, "unsupported graphics are dropped")
    single.widgets[0].style = .hidden
    precondition(single.sanitized().widgets[0].style == .text, "graphic-only without a graphic falls back to text")
    single.widgets[0] = MenuWidget(.stacked, "cpu", "memory", chart: .ring)
    precondition(single.sanitized().widgets[0].chart == .none, "two stacked metrics carry no graphic")
    // Before 2.1 a chart was its own widget: a value-less chart followed by text for the same metric merges into one.
    let charted = #"{"widgets":[{"style":"ring","metric":"claudeQuota","labelMode":"none","color":"orange","showValue":false},{"style":"mini","metric":"claudeQuota"},"#
        + #"{"style":"battery","metric":"peripheral","showValue":true},{"style":"line","metric":"power","showValue":false},{"style":"mini","metric":"cpu"},{"style":"stacked","metric":"upload","secondary":"download"}]}"#
    let merged = try! JSONDecoder().decode(MenuConfiguration.self, from: Data(charted.utf8)).widgets
    precondition(merged.map(\.style) == [.mini, .text, .hidden, .mini, .stacked], "only same-metric pairs merge")
    precondition(merged[0].chart == .ring && merged[0].color == "orange" && merged[1].chart == .battery && merged[2].chart == .line && merged[3].chart == .none)
    precondition(MenuConfiguration.presets.allSatisfy { try! JSONDecoder().decode(MenuConfiguration.self, from: JSONEncoder().encode($0.value)).matches($0.value) },
                 "presets round-trip without being merged again")
    precondition(MenuMetric.rate(1024, bits: false) == "1.0 KB/s")
    precondition(MenuMetric.rate(125000, bits: true) == "1.0 Mb/s")
    precondition(MenuMetric.rate(nil, bits: false) == "—")
    let reference = MenuBarLayout(config: .reference)
    precondition(Set(reference.items.map(\.width)).count == 1, "uniform stacked widgets share one width")
    let digits = MenuBarLayout.numberFont(9), mono = MenuBarLayout.textFont(9)
    precondition(reference.items[0].width == MenuBarLayout.measure("CPU", mono) + 4 + MenuBarLayout.measure("100%", digits) + 2,
                 "widget width must match the original CPU percentage width")
    for mode in ["uniform", "fit"] {
        configuration = .reference
        configuration.widthMode = mode; configuration.alignment = mode == "fit" ? "left" : "right"
        configuration.separators = true; configuration.icon = "fan"; configuration.iconPosition = "trailing"
        configuration.widgets = WidgetStyle.allCases.map { MenuWidget($0, "cpu", $0 == .stacked ? "download" : "none", chart: $0 == .hidden ? .bar : .none) }
            + WidgetChart.allCases.map { MenuWidget(.mini, "cpu", chart: $0) }
            + [MenuWidget(.stacked, "upload", "download", labelMode: "symbol"), MenuWidget(.text, "upload", chart: .line)]
        configuration.widgets.append(contentsOf: [MenuWidget(.text, "fan", labelMode: "none")])
        configuration.widgets = Array(configuration.widgets.prefix(MenuConfiguration.maxWidgets))
        let expected = MenuBarLayout(config: configuration)
        precondition(expected.items.count == configuration.widgets.count, "every widget is laid out")
        for speed in [0.0, 1, 9.95, 999, 999.5, 1023, 1024, 10239, 102400, 1022976, 1048576, 1073741824, 1e12] {
            var sample = Sample()
            sample.networkValid = true
            sample.networks = [NetworkValue(name: "en0", download: speed, upload: speed)]
            sample.cpu = 100; sample.memoryValid = true; sample.memoryUsed = sample.memoryTotal
            sample.cores = [100, 50, 0]; sample.watts = 1500
            monitor.accept(sample)
            let actual = MenuBarLayout(config: configuration)
            precondition(actual.width == expected.width)
            precondition(actual.items.map(\.width) == expected.items.map(\.width))
            for item in actual.items { for line in item.lines {
                let string = line.metric.displayValue(monitor, config: configuration) as NSString
                precondition(string.size(withAttributes: [.font: line.valueFont]).width <= line.valueWidth,
                             "formatted metric must fit its reserved slot")
            } }
            precondition(actual.image(monitor).size.width == expected.width)
        }
    }
    configuration.widgets = []
    precondition(MenuBarLayout(config: configuration).showsIcon && MenuBarLayout(config: configuration).width > 0)
    // WLMOUSE replies with or without the leading report ID; 0 means the mouse is asleep.
    var reply = [UInt8](repeating: 0, count: 64)
    reply[0] = 0xA1; reply[3] = 2; reply[5] = 0x83; reply[6] = 1; reply[7] = 90
    precondition(PeripheralReader.parseWLMouseReply(reply)! == (true, 90))
    precondition(PeripheralReader.parseWLMouseReply([0] + reply)! == (true, 90))
    reply[7] = 0
    precondition(PeripheralReader.parseWLMouseReply(reply) == nil && PeripheralReader.parseWLMouseReply([1, 2, 3]) == nil)
    precondition(PeripheralReader.displayName("WLMOUSE MINI PRO 8K RECEIVER") == "WLMOUSE MINI PRO")
    // WLMOUSE encodings match the web hub: LOD 0.7 mm is 7 | 0x80, polling codes are bit flags.
    for mm in [0.7, 1.0, 1.5, 2.0] { precondition(WLMouseChannel.decodeLOD(WLMouseChannel.encodeLOD(mm)) == mm, "LOD \(mm) round-trips") }
    precondition(WLMouseChannel.encodeLOD(0.7) == 0x87 && WLMouseChannel.encodeLOD(1.5) == 0x15)
    for rate in [125, 250, 500, 1000, 2000, 4000, 8000] { precondition(WLMouseChannel.pollingRate(code: WLMouseChannel.pollingCode(rate)!) == rate) }
    precondition(WLMouseChannel.normalize([0xA1, 0, 2]) == [0, 0xA1, 0, 2] && WLMouseChannel.normalize([0, 0xA1]) == [0, 0xA1])
    precondition(WLMouseModel.resolve(productID: 0xA868)?.name == "花•兽 Mini PRO" && WLMouseModel.resolve(productID: 0xA868)?.maxDPI == 30000)
    // A mouse on its cable (wired PID) is the same battery entry as its receiver; the shared 1K dongle keeps its own.
    precondition(WLMouseModel.batteryKey(productID: 0xA869) == "wl-\(0xA868)" && WLMouseModel.batteryKey(productID: 0xA868) == "wl-\(0xA868)")
    precondition(WLMouseModel.batteryKey(productID: 0xA882) == "wl-\(0xA882)" && WLMouseModel.batteryKey(productID: 0x1234) == "wl-\(0x1234)")
    let shared = WLMouseModel.resolve(productID: 0xA882)!
    precondition(shared.maxDPI == 26000 && shared.lod == [1.0, 2.0], "a shared receiver uses the strictest limits")
    let command = WLMouseChannel.command(group: 1, code: 0x81, length: 10, [1, 6])
    precondition(command[2] == 2 && command[3] == 10 && command[4] == 1 && command[5] == 0x81 && command[6] == 1 && command[7] == 6)
    // Profile names: GBK, capped at 30 bytes without splitting a character.
    precondition(WLMouseChannel.encodeName("办公") == [0xB0, 0xEC, 0xB9, 0xAB] && WLMouseChannel.fitsName("游戏 FPS") == "游戏 FPS")
    precondition(WLMouseChannel.encodeName(String(repeating: "长", count: 20)).count == 30)
    var nameReply = [UInt8](repeating: 0, count: 64); nameReply[8] = 4; nameReply[9...12] = [0xB0, 0xEC, 0xB9, 0xAB]
    precondition(WLMouseChannel.decodeName(nameReply) == "办公")
    // Fan presets and the helper's status line.
    let parsedFan = FanHelperClient.parseStatus("ok version=1 fans=1 manual=0 f0=999,1000,4900,1000,0")!
    precondition(parsedFan.version == 1 && parsedFan.fans == [FanInfo(actual: 999, min: 1000, max: 4900, target: 1000, manual: false)])
    precondition(FanHelperClient.parseStatus("error unknown") == nil)
    // Four scenario presets, each within the four-point limit; old ids map to the closest one.
    precondition(FanPreset.all.count == 5 && FanPreset.all.allSatisfy { ($0.points?.count ?? 0) <= FanCurve.maxPoints })
    precondition(FanPreset.find("silent").curve!.share(at: 60) == 0 && abs(FanPreset.find("daily").curve!.share(at: 85) - 0.45) < 0.001)
    precondition(FanPreset.find("cooling").curve!.share(at: 30) == 0.3 && FanPreset.find("sustained").curve!.share(at: 95) == 1)
    precondition(FanPreset.find("balanced").id == "daily" && FanPreset.find("custom").id == "auto" && FanPreset.find("auto").curve == nil)
    precondition(FanSettings().enabled == false, "fan control is off by default")
    // User curves interpolate linearly and hold their end speeds; old settings without curves still load.
    let curve = FanCurve(name: "测试", points: [CurvePoint(temp: 80, percent: 100), CurvePoint(temp: 40, percent: 20)])
    precondition(curve.share(at: 30) == 0.2 && curve.share(at: 60) == 0.6 && curve.share(at: 95) == 1)
    let oldFan = try! JSONDecoder().decode(FanSettings.self, from: Data(#"{"enabled":true,"preset":"balanced","customRPM":2000,"safetyLimit":90}"#.utf8))
    precondition(oldFan.enabled && oldFan.curves.isEmpty && oldFan.preset == "daily", "old preset ids migrate")
    precondition(oldFan.menuPresets == ["auto", "silent", "daily", "sustained"], "four presets are pinned by default")
    let pinnedFan = try! JSONDecoder().decode(FanSettings.self, from: Data(#"{"menuPresets":["quiet","max","auto","daily","cool"]}"#.utf8))
    precondition(pinnedFan.menuPresets == ["silent", "cooling", "auto", "daily"], "pins migrate and stop at four")
    var savedFan = FanSettings(); savedFan.curves = [FanCurve(name: "测试", points: curve.points.sorted { $0.temp < $1.temp })]
    precondition(try! JSONDecoder().decode(FanSettings.self, from: JSONEncoder().encode(savedFan)) == savedFan)
    // Loading sorts points and keeps at most four.
    savedFan.curves = [FanCurve(name: "多点", points: (0..<6).map { CurvePoint(temp: 90 - Double($0) * 10, percent: Double($0) * 10) })]
    let trimmed = try! JSONDecoder().decode(FanSettings.self, from: JSONEncoder().encode(savedFan)).curves[0].points
    precondition(trimmed.count == FanCurve.maxPoints && trimmed.map(\.temp) == [40, 50, 60, 70])
    // Several fans: each follows fan 1 unless it has its own curve, and each target sits in its own range.
    var twoFan = FanCurve(name: "双风扇", points: [CurvePoint(temp: 40, percent: 0), CurvePoint(temp: 80, percent: 100)])
    precondition(twoFan.points(for: 2) == twoFan.points && !twoFan.hasOwnCurve(1))
    twoFan.setPoints([CurvePoint(temp: 30, percent: 50)], for: 1)
    precondition(twoFan.hasOwnCurve(1) && twoFan.share(at: 60, fan: 1) == 0.5 && twoFan.share(at: 60) == 0.5 && twoFan.share(at: 80, fan: 2) == 1)
    let fanInfos = [FanInfo(actual: 0, min: 1000, max: 5000, target: 0, manual: false), FanInfo(actual: 0, min: 1200, max: 6000, target: 0, manual: false)]
    precondition(FanController.targets(for: twoFan, fans: fanInfos, temperature: 40) == [1000, 3600])
    precondition(FanController.targets(for: twoFan, fans: fanInfos, temperature: nil) == [5000, 6000], "no reading runs every fan at full speed")
    twoFan.copyFirstToAll(); precondition(!twoFan.hasOwnCurve(1))
    let oldCurve = try! JSONDecoder().decode(FanCurve.self, from: Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"旧","points":[{"temp":50,"percent":40}]}"#.utf8))
    precondition(oldCurve.extraFans.isEmpty && oldCurve.share(at: 70, fan: 1) == 0.4, "curves saved before per-fan curves still load")
    var namedFan = FanSettings(); namedFan.fanNames = ["左侧", " "]
    precondition(namedFan.fanName(0) == "左侧" && namedFan.fanName(1) == "风扇 2" && namedFan.fanName(2) == "风扇 3")
    precondition(try! JSONDecoder().decode(FanSettings.self, from: JSONEncoder().encode(namedFan)).fanNames == ["左侧", " "])
    precondition(FanReading(rpm: 3000, min: 1000, max: 5000).fraction == 0.5 && FanReading(rpm: 0, min: 1000, max: 5000).fraction == 0)
    // Battery runtime: 90% → 84% over 12 hours is 0.5%/h, so 84% lasts 7 days; short or charging runs give no estimate.
    let points = (0...12).map { BatteryPoint(date: base.addingTimeInterval(Double($0) * 3600), percent: 90 - Double($0) * 0.5, charging: false) }
    precondition(abs(BatteryHistory.daysLeft(points)! - 7) < 0.01)
    precondition(BatteryHistory.daysLeft(Array(points.prefix(4))) == nil)
    precondition(BatteryHistory.daysLeft(points + [BatteryPoint(date: base.addingTimeInterval(13 * 3600), percent: 84, charging: true)]) == nil)
    let recharged = [BatteryPoint(date: base, percent: 20, charging: false), BatteryPoint(date: base.addingTimeInterval(3600), percent: 60, charging: true)] + points.map {
        BatteryPoint(date: $0.date.addingTimeInterval(7200), percent: $0.percent, charging: false) }
    precondition(abs(BatteryHistory.daysLeft(recharged)! - 7) < 0.01, "the estimate starts after the last charge")
    // The one-second charge check redraws only when the level, charge state or staleness changes, not the timestamp.
    let reading = PeripheralBattery(key: "wl-1", name: "鼠标", percent: 72, charging: false, updated: Date(), source: "")
    precondition(reading.sameReading(as: PeripheralBattery(key: "wl-1", name: "鼠标", percent: 72, charging: false, updated: Date().addingTimeInterval(-1), source: "")))
    precondition(!reading.sameReading(as: PeripheralBattery(key: "wl-1", name: "鼠标", percent: 72, charging: true, updated: Date(), source: "")))
    precondition(!reading.sameReading(as: PeripheralBattery(key: "wl-1", name: "鼠标", percent: 72, charging: false, updated: Date().addingTimeInterval(-300), source: "")))
    // HID++ DPI lists: explicit values, and 0xE0xx step markers that expand up to the next value.
    precondition(LogitechDevice.parseDPIList([0x01, 0x90, 0x03, 0x20, 0x06, 0x40, 0x00, 0x00]) == [400, 800, 1600])
    precondition(LogitechDevice.parseDPIList([0x01, 0x90, 0xE1, 0x90, 0x06, 0x40, 0x00, 0x00]) == [400, 800, 1200, 1600])
    precondition(LogitechDevice.parseDPIList([0xE0, 0x32, 0x1F, 0x40]) == nil && LogitechDevice.parseDPIList([0x00, 0x00]) == nil)
    for preset in MenuConfiguration.presets { precondition(MenuBarLayout(config: preset.value).width > 0) }
    // Layout presets: matching ignores widget ids, and saved presets round-trip.
    var reordered = MenuConfiguration.reference
    precondition(reordered.matches(.reference) && !MenuConfiguration.reference.matches(.compact))
    reordered.widgets = reordered.widgets.map { var w = $0; w.id = UUID(); return w }
    precondition(reordered != .reference && reordered.matches(.reference), "fresh widget ids still match")
    reordered.widgets.swapAt(0, 1)
    precondition(!reordered.matches(.reference), "order matters")
    let layoutPreset = MenuLayoutPreset(name: "工作", configuration: .charts)
    precondition(try! JSONDecoder().decode([MenuLayoutPreset].self, from: JSONEncoder().encode([layoutPreset])) == [layoutPreset])
    precondition(MenuLayoutPreset.defaultName([]) == "我的布局 1" && MenuLayoutPreset.defaultName([MenuLayoutPreset(name: "我的布局 1", configuration: .reference)]) == "我的布局 2")
    precondition(MenuLayoutPreset.cleanName("  ", existing: []) == "我的布局 1" && MenuLayoutPreset.cleanName(String(repeating: "长", count: 30), existing: []).count == MenuLayoutPreset.maxName)
    for name in MenuSymbols.appIcons + MenuSymbols.labels + MenuMetric.all.map(\.symbol).filter({ !$0.isEmpty }) {
        precondition(MenuSymbols.exists(name), "missing symbol \(name)")
    }
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
    print("PASS: fixed menu widths across units and widget styles, configuration round-trip and 1.6 migration, menu formatting, fallback icon, accessory battery replies, WLMOUSE and HID++ encodings; network counters, energy and history; alert sustain, latch, hysteresis and cooldown; update version comparison")
}

/// Read-only dump of every supported mouse's settings; never writes to a device.
func mouseDump() {
    for channel in WLMouseChannel.find() {
        print("WLMOUSE \(channel.product) PID \(String(format: "0x%04X", channel.productID)) model \(channel.model?.name ?? "unknown")")
        do {
            try channel.withOpen {
                if let battery = try channel.battery() { print("  battery \(battery.percent)% charging \(battery.charging)") }
                print("  \(try channel.readSettings())")
            }
        } catch { print("  error: \(error.localizedDescription)") }
    }
    for device in LogitechHIDPP.discover() {
        print("Logitech \(device.name) index \(device.index) features \(device.features.map { String(format: "%04X@%d", $0.key, $0.value) }.sorted())")
        if let battery = device.battery() { print("  battery \(battery.percent)% charging \(battery.charging)") }
        if let dpi = device.dpi() { print("  dpi \(dpi.current) of \(dpi.supported.count) values") }
        if let shift = device.smartShift() { print("  smartshift \(shift)") }
        if let inverted = device.scrollInverted() { print("  scroll inverted \(inverted)") }
    }
    exit(0)
}

/// Write-path check on the first WLMOUSE: flips angle snap, verifies, then restores and verifies the original.
func mouseRoundTrip() {
    guard let channel = WLMouseChannel.find().first else { print("no WLMOUSE"); exit(1) }
    do {
        try channel.withOpen {
            let original = try channel.readSettings()
            if CommandLine.arguments.contains("--names"), original.profileNames.count >= 3 {
                var named = original; named.profileNames[2] = "测试"
                let after = try channel.apply(named, over: original)
                print("named profile 3: \(after.profileNames)")
                let restored = try channel.apply(original, over: after)
                print("restored: \(restored == original ? "identical to original" : "DIFFERENT: \(restored.profileNames)")")
                return
            }
            var flipped = original; flipped.angleSnap.toggle()
            let after = try channel.apply(flipped, over: original)
            print("flipped angle snap: \(original.angleSnap) -> \(after.angleSnap)")
            let restored = try channel.apply(original, over: after)
            print("restored: \(restored == original ? "identical to original" : "DIFFERENT: \(restored)")")
        }
    } catch { print("error: \(error.localizedDescription)"); exit(1) }
    exit(0)
}

/// Queries one account's quota and prints only the plan, windows and any error; never the token.
func quotaCheck() {
    let client = QuotaClient()
    let quota = CommandLine.arguments.contains("codex") ? client.codex() : client.claude(allowPrompt: true)
    print("account: \(quota.account)")
    for window in quota.windows {
        print("  \(window.title): 已用 \(Format.number(window.usedPercent, suffix: "%", decimals: 1))" + (window.resetAt.map { " · 重置 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
    }
    if let balance = quota.balance { print("  balance: \(balance) \(quota.unit)") }
    print(quota.error.map { "error: \($0)" } ?? "ok")
    exit(0)
}

if CommandLine.arguments.contains("--diagnose") { diagnostics() }
else if CommandLine.arguments.contains("--quota-check") { quotaCheck() }
else if let index = CommandLine.arguments.firstIndex(of: "--open-monitor"), CommandLine.arguments.count > index + 1,
        let tab = Int(CommandLine.arguments[index + 1]).flatMap(SystemJump.MonitorTab.init) {
    // Exercises the panel's Activity Monitor jump from the terminal.
    SystemJump.openActivityMonitor(tab)
    RunLoop.main.run(until: Date().addingTimeInterval(6))
    exit(0)
}
else if CommandLine.arguments.contains("--mouse-roundtrip") { mouseRoundTrip() }
else if CommandLine.arguments.contains("--mouse-dump") { mouseDump() }
else if CommandLine.arguments.contains("--test") { tests() }
else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
