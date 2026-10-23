import AppKit
import SwiftUI
import Combine
import Foundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    /// Built when the panel opens and released a minute after it closes, so an idle MacPulse
    /// keeps no SwiftUI tree; reopening within the minute reuses it.
    private var panel: GlassPanel?
    private var panelHost: NSHostingView<PanelView>?
    private var panelRelease: DispatchWorkItem?
    private var panelHeight: CGFloat = 0
    /// Clicks in other apps close an unpinned panel, as a popover would.
    private var outsideClicks: Any?
    /// Open or closed as the user sees it; the window may still be fading out.
    private var panelOpen = false
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
        // Switching to another app closes an unpinned panel.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in if self?.monitor.pinned == false { self?.closePanel() } }
            .store(in: &subscriptions)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self; button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        monitor.onChange = { [weak self] in self?.updateStatus() }
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
        PanelView(monitor: monitor, height: height, dismiss: { [weak self] in self?.closePanel() }, openSettings: { [weak self] in self?.showSettings() })
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
        closePanel()
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
        // Otherwise the first text field takes focus and the page scrolls to it.
        settingsWindow?.makeFirstResponder(nil)
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
        } else if panelOpen { closePanel() }
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
    func windowWillClose(_ notification: Notification) {
        monitor.setVisible("settings", false)
        // Drop the whole settings view tree; the next open builds a fresh window.
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        DispatchQueue.main.async { [weak self] in
            if self?.settingsWindow === window, window.isVisible == false {
                window.contentViewController = nil
                self?.settingsWindow = nil
            }
        }
    }
    func windowDidMiniaturize(_ notification: Notification) { monitor.setVisible("settings", false) }
    func windowDidDeminiaturize(_ notification: Notification) { monitor.setVisible("settings", true) }
    func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window, !panelOpen else { return }
        panelOpen = true
        // Follow the screen the menu bar is on now, not the one at launch.
        let screen = buttonWindow.screen ?? NSScreen.main
        let height = Self.panelHeight(for: screen)
        panelRelease?.cancel(); panelRelease = nil
        if let panelHost, height != panelHeight { panelHost.rootView = makePanel(height: height) }
        panelHeight = height
        let panel: GlassPanel
        if let existing = self.panel { panel = existing } else {
            let host = NSHostingView(rootView: makePanel(height: height))
            host.frame.size = NSSize(width: PanelLayout.width, height: height)
            panel = GlassPanel(content: host)
            panel.onCancel = { [weak self] in self?.closePanel() }
            self.panel = panel; panelHost = host
        }
        let size = NSSize(width: PanelLayout.width, height: height)
        panel.place(below: buttonWindow.convertToScreen(button.convert(button.bounds, to: nil)), on: screen, size: size)
        monitor.setVisible("panel", true)
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            if self?.monitor.pinned == false { self?.closePanel() }
        }
    }
    func closePanel() {
        guard let panel, panelOpen else { return }
        panelOpen = false
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        monitor.setVisible("panel", false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Reopened during the fade: keep the window up.
            guard let self, !self.panelOpen else { return }
            panel.orderOut(nil)
            let release = DispatchWorkItem { [weak self] in
                guard let self, !self.panelOpen else { return }
                self.panel = nil; self.panelHost = nil
            }
            self.panelRelease = release
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: release)
        })
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
        // The real panel is glass, which only draws on screen (see --onscreen below).
        if tab == "bar" { saveBarSnapshot(path, dark: dark); return }
        let content: AnyView
        let size: NSSize
        if tab == "keypicker" || tab == "knobpicker" {
            // Popovers draw in their own window; render the key picker by itself so its layout can be checked.
            let model = tab == "keypicker" ? KeyboardModel.buff67 : KeyboardModel.bnk16
            let picker = tab == "keypicker"
                ? AnyView(KeyPicker(model: model, layers: 4, macros: 16, current: 0x39) { _ in })
                : AnyView(KnobPicker(model: model, layers: 10, macros: 18, knob: model.knobs[0], codes: [0xBE, 0xBD], press: 0xAE, selection: .constant(nil)) { _, _ in })
            content = AnyView(picker.fixedSize())
            size = NSSize(width: 520, height: 560)
        } else if tab == "overview" {
            let custom = CommandLine.arguments.firstIndex(of: "--panel-height").flatMap { CommandLine.arguments.count > $0 + 1 ? Double(CommandLine.arguments[$0 + 1]) : nil }
            let height: CGFloat = custom.map { CGFloat($0) } ?? (CommandLine.arguments.contains("--compact") ? 480 : PanelLayout.height)
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
        // Glass only draws on screen; --onscreen shows the real panel window so it can be captured with screencapture -l.
        if CommandLine.arguments.contains("--onscreen") {
            // A fixed backdrop inside the panel gives the glass something to refract without showing the desktop.
            let backdrop = CommandLine.arguments.contains("--snapshot-backdrop")
            let root = backdrop ? AnyView(ZStack { SnapshotBackdrop(dark: dark); content }
                .clipShape(RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous))) : content
            let host = NSHostingView(rootView: root)
            host.frame.size = size
            let window = GlassPanel(content: host)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            // `--snapshot-at x,y` puts the panel's top-left there, in points from the main screen's top-left (for promo images).
            let at = CommandLine.arguments.firstIndex(of: "--snapshot-at").flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil }?
                .split(separator: ",").compactMap { Double($0) }
            if let at, at.count == 2, let screen = NSScreen.main?.frame {
                window.setPanelFrame(NSRect(x: at[0], y: screen.maxY - at[1] - size.height, width: size.width, height: size.height))
            } else if let visible = NSScreen.main?.visibleFrame {
                window.setPanelFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height))
            }
            snapshotWindow = window
            announceWhenKey(window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { NSApp.terminate(nil) }
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
            window.center()
            announceWhenKey(window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { NSApp.terminate(nil) }
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
    /// Shows a snapshot window and prints its number for screencapture -l, but only once it is key:
    /// until then controls, traffic lights and glass draw in their inactive look.
    private func announceWhenKey(_ window: NSWindow, attempt: Int = 0) {
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        // As in showSettings: no text field focus, so the page stays scrolled to the top.
        window.makeFirstResponder(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if !window.isKeyWindow && attempt < 10 { self?.announceWhenKey(window, attempt: attempt + 1); return }
            print("Window: \(window.windowNumber)"); fflush(stdout)
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
            // `--snapshot-transparent` leaves the background clear, for placing the bar on an image.
            if !CommandLine.arguments.contains("--snapshot-transparent") {
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: size).fill()
            }
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

/// Stand-in desktop behind the panel in README screenshots: soft color for the glass to pick up, nothing personal.
private struct SnapshotBackdrop: View {
    let dark: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: dark ? [Color(red: 0.11, green: 0.13, blue: 0.22), Color(red: 0.19, green: 0.14, blue: 0.27), Color(red: 0.26, green: 0.17, blue: 0.16)]
                                        : [Color(red: 0.83, green: 0.87, blue: 0.95), Color(red: 0.90, green: 0.86, blue: 0.93), Color(red: 0.96, green: 0.89, blue: 0.82)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.25, green: 0.5, blue: 1).opacity(dark ? 0.45 : 0.3), .clear], center: UnitPoint(x: 0.1, y: 0.85), startRadius: 10, endRadius: 360)
            RadialGradient(colors: [Color(red: 1, green: 0.6, blue: 0.3).opacity(dark ? 0.3 : 0.25), .clear], center: UnitPoint(x: 0.95, y: 0.1), startRadius: 10, endRadius: 320)
        }
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
    let panelStart = ProcessInfo.processInfo.systemUptime
    _ = collector.sample(detail: [.live, .processes])
    let panelDuration = ProcessInfo.processInfo.systemUptime - panelStart
    Thread.sleep(forTimeInterval: 1)
    let summaryStart = ProcessInfo.processInfo.systemUptime
    _ = collector.sample(detail: [])
    let summaryDuration = ProcessInfo.processInfo.systemUptime - summaryStart
    let payload: [String: Any] = [
        "chip": collector.chip,
        "model": collector.model,
        "sampleMilliseconds": duration * 1000,
        "panelSampleMilliseconds": panelDuration * 1000,
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
        "networks": sample.networks.map { ["interface": $0.name, "downloadBytesPerSecond": $0.download, "uploadBytesPerSecond": $0.upload, "receivedBytes": $0.received, "sentBytes": $0.sent] as [String: Any] },
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
    precondition(counterDelta(0x100001000, 0xfffff000) == 8192, "disk counters must retain upper 32 bits")
    precondition(wrappingDelta32(0x0000_0800, 0xffff_fc00) == 3072, "network counters wrap at 32 bits")
    precondition(wrappingDelta32(5_000, 5_000) == 0)
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
    // VIA keyboards: macro buffer round-trip, key names per protocol version, and blocked keys.
    let macros: [[MacroStep]] = [[.text("Hi"), .tap(0x28)], [], [.down(0xE3), .tap(0x06), .up(0xE3), .delay(150)]]
    let macroBytes = MacroCodec.encode(macros)
    precondition(macroBytes == [0x48, 0x69, 1, 1, 0x28, 0, 0, 1, 2, 0xE3, 1, 1, 0x06, 1, 3, 0xE3, 1, 4, 0x31, 0x35, 0x30, 0x7C, 0])
    precondition(MacroCodec.decode(macroBytes + [0, 0], count: 4) == macros + [[]], "empty slots pad to the macro count")
    precondition(Keycode.describe(0x5221, model: .buff67).short == "MO 1" && Keycode.describe(0x5262, model: .buff67).short == "TG 2")
    precondition(Keycode.describe(0x5203, model: .bnk16).short == "TO 3" && Keycode.describe(0x52C1, model: .bnk16).short == "TT 1")
    precondition(Keycode.describe(0x7F00, model: .buff67).short == "Win 锁" && Keycode.describe(0x7E05, model: .bnk16).short == "关灯")
    precondition(Keycode.describe(0x7702, model: .buff67).short == "M0" && Keycode.describe(0x7700, model: .bnk16).short == "M0", "macro base follows the VIA protocol")
    precondition(Keycode.describe(0x0804, model: .buff67).short == "⌘A" && Keycode.describe(0x0904, model: .buff67).short == "⌃⌘A" && Keycode.describe(0x4105, model: .buff67).short == "L1\nB")
    precondition(Keycode.blocked(0x7C00, model: .buff67) && Keycode.blocked(0x7E08, model: .bnk16) && !Keycode.blocked(0x7E05, model: .bnk16))
    let keyboardState = KeyboardState(layers: 2, keymap: [[0x29, 0x5221], [1, 0]], encoders: [[[0xAA, 0xA9]], [[0, 0]]], macroCount: 3, macroBufferSize: 64,
                                      macros: macros, lighting: KeyboardLightingValues(effect: 4, brightness: 200, speed: 3, hue: 10, saturation: 255))
    let backup = KeyboardBackup(model: .bnk16, state: keyboardState)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let restored = try! decoder.decode(KeyboardBackup.self, from: encoder.encode(backup)).state
    precondition(restored == keyboardState && backup.fits(keyboardState), "a backup restores the same keymap, knobs, macros and lighting")
    var other = keyboardState; other.layers = 3; other.keymap.append([0, 0])
    precondition(!backup.fits(other), "a backup never restores onto a different board shape")
    precondition(KeyboardEditor.backupTitle(URL(fileURLWithPath: "/x/2026-10-23 173012.json")) == "2026-10-23 17:30:12")
    var dim = KeyboardLightingValues(effect: 0, brightness: 0); var dimBack = dim; dimBack.brightness = 1; dimBack.speed = 9
    precondition(VIAKeyboard.lightingMatches(dim, dimBack, model: .bnk16) == false && VIAKeyboard.lightingMatches(dim, dimBack, model: .buff67) == false)
    dim.brightness = 1
    precondition(VIAKeyboard.lightingMatches(dim, dimBack, model: .buff67), "speed is not compared on a board without a speed setting")
    precondition(KeyboardModel.buff67.keys.count == 67 && KeyboardModel.buff67.width == 16 && KeyboardModel.bnk16.width == 7.5 && KeyboardModel.bnk16.height == 4)
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

/// Read-only dump of every wired keyboard and, for supported VIA boards, what the driver reads; never writes.
func keyboardDump() {
    // The same watcher and queue as the app: the list arrives on DeviceIO.queue, where the VIA reads run.
    let watcher = WiredKeyboardWatcher()
    watcher.onChange = { list in dumpKeyboards(list); exit(0) }
    RunLoop.main.run(until: Date().addingTimeInterval(8))
    print("no keyboards reported"); exit(1)
}
private func dumpKeyboards(_ list: [WiredKeyboard]) {
    for keyboard in list {
        print("\(keyboard.name) \(keyboard.id) model \(keyboard.model?.name ?? "none")")
        guard let model = keyboard.model else { continue }
        guard let channel = VIAChannel.find(vendorID: keyboard.vendorID, productID: keyboard.productID, location: keyboard.location) else { print("  no VIA channel"); continue }
        do {
            let state = try channel.withOpen { try VIAKeyboard.read(channel, model: model) }
            print("  layers \(state.layers), macros \(state.macrosInUse)/\(state.macroCount) using \(state.macroBytes)/\(state.macroBufferSize) bytes, lighting \(state.lighting.map { "\($0)" } ?? "none")")
            for layer in state.keymap.indices {
                print("  layer \(layer): " + model.keys.map { Keycode.describe(state.keycode(layer, $0, cols: model.cols), model: model).short.replacingOccurrences(of: "\n", with: "/") }.joined(separator: " "))
            }
            if CommandLine.arguments.contains("--raw") {
                for codes in state.keymap { print("  raw " + codes.map { String(format: "%04x", $0) }.joined(separator: ",")) }
            }
            for (layer, knobs) in state.encoders.enumerated() where !knobs.isEmpty {
                print("  knobs \(layer): " + knobs.map { $0.map { String(format: "%04X", $0) }.joined(separator: "/") }.joined(separator: " "))
            }
        } catch { print("  error: \(error.localizedDescription)") }
    }
}

/// Writes the driver tables MacPulse uses (keyboard and mouse models, keycode names, key mappings) as JSON,
/// so the same data can drive a port to another platform. Generated from the Swift tables, never edited by hand.
func exportDriverData() {
    guard let flag = CommandLine.arguments.firstIndex(of: "--export-driver-data"), CommandLine.arguments.count > flag + 1 else {
        print("usage: --export-driver-data <folder>"); exit(1)
    }
    let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
    func hex(_ value: Int, _ digits: Int = 4) -> String { String(format: "0x%0\(digits)X", value) }
    func write(_ name: String, _ object: Any) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try! data.write(to: folder.appendingPathComponent(name))
        print("wrote \(name)")
    }
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func key(_ k: KeyboardKey) -> [String: Any] { ["row": k.row, "col": k.col, "x": k.x, "y": k.y, "w": k.w, "h": k.h] }
    write("keyboards.json", KeyboardModel.all.map { m -> [String: Any] in
        var model: [String: Any] = [
            "name": m.name, "vendorId": hex(m.vendorID), "productId": hex(m.productID),
            "matrix": ["rows": m.rows, "cols": m.cols], "viaProtocol": m.protocolVersion,
            "macroKeycodeBase": hex(Int(m.macroBase)), "customKeycodeBase": hex(Int(m.customBase)),
            "layoutUnits": ["width": m.width, "height": m.height],
            "keys": m.keys.map(key),
            "knobs": m.knobs.map { k -> [String: Any] in
                var knob: [String: Any] = ["index": k.index, "x": k.x, "y": k.y, "size": k.size]
                if let press = k.press { knob["press"] = ["row": press.row, "col": press.col] }
                return knob
            },
            "customKeycodes": m.custom.enumerated().map { ["keycode": hex(Int(m.customBase) + $0.offset), "short": $0.element.short, "name": $0.element.name, "hiddenInPicker": $0.element.hidden] },
            "source": m.driverName,
        ]
        if let l = m.lighting {
            var lighting: [String: Any] = [
                "channel": Int(l.channel), "effectValueId": Int(l.effectID), "brightnessValueId": Int(l.brightnessID),
                "effects": l.effects.map { ["value": $0.value, "name": $0.name] },
                "brightness": [l.brightness.lowerBound, l.brightness.upperBound],
                "colorEffects": l.colorEffects.sorted(), "indicatorOnly": l.indicatorOnly,
            ]
            if let id = l.speedID { lighting["speedValueId"] = Int(id) }
            if let id = l.colorID { lighting["colorValueId"] = Int(id) }
            if let speed = l.speed { lighting["speed"] = [speed.lowerBound, speed.upperBound] }
            model["lighting"] = lighting
        }
        return model
    })
    func entries(_ list: [Keycode.Entry]) -> [[String: Any]] { list.map { ["keycode": hex(Int($0.code)), "short": $0.short, "name": $0.name] } }
    write("keycodes.json", [
        "note": "QMK keycodes as VIA protocol 11 and 12 send them. Macro and custom keycode bases differ per protocol; see keyboards.json.",
        "basic": entries(Keycode.basic), "numpad": entries(Keycode.numpad), "modifiers": entries(Keycode.modifiers),
        "media": entries(Keycode.media), "lighting": entries(Keycode.lighting),
        "special": [["keycode": "0x0000", "short": "", "name": "无 KC_NO"], ["keycode": "0x0001", "short": "▽", "name": "透明 KC_TRNS"]],
        "layerFunctions": Keycode.layerKinds.map { ["base": hex(Int($0.base)), "short": $0.short, "name": $0.name, "keycode": "base + layer (0–31)"] },
        "modifierBits": Keycode.modBits.map { ["bit": hex(Int($0.bit), 2), "symbol": $0.symbol, "name": $0.name] } + [["bit": "0x10", "symbol": "右", "name": "Right-hand modifiers"]],
        "ranges": [
            ["range": "0x0100–0x1FFF", "meaning": "modifiers + basic key: (mods << 8) | key"],
            ["range": "0x2000–0x3FFF", "meaning": "mod-tap: 0x2000 | (mods << 8) | key"],
            ["range": "0x4000–0x4FFF", "meaning": "layer-tap: 0x4000 | (layer << 8) | key"],
            ["range": "0x52A0–0x52BF", "meaning": "one-shot modifier: 0x52A0 | mods"],
            ["range": "0x7700/0x7702 + n", "meaning": "macro n (protocol 12 / 11)"],
            ["range": "0x7E00/0x7F00 + n", "meaning": "keyboard custom keycode n (protocol 12 / 11)"],
        ],
        "neverAssigned": ["0x7C00 QK_BOOT", "0x7C01 QK_REBOOT", "0x7C03 QK_CLEAR_EEPROM", "custom keycodes marked hiddenInPicker"],
    ])
    write("mac-virtual-keycode-to-hid.json", Dictionary(uniqueKeysWithValues: Keycode.fromMac.map { (hex(Int($0.key), 2), hex(Int($0.value), 2)) }))
    write("wlmouse-models.json", [
        "vendorId": hex(WLMouseChannel.vendorID),
        "pollingRateCodes": Dictionary(uniqueKeysWithValues: WLMouseChannel.pollingCodes.map { (String($0.key), hex(Int($0.value), 2)) }),
        "lodEncoding": Dictionary(uniqueKeysWithValues: [0.7, 1.0, 1.2, 2.0].map { (String($0), hex(Int(WLMouseChannel.encodeLOD($0)), 2)) }),
        "models": WLMouseModel.all.map { m -> [String: Any] in
            var model: [String: Any] = [
                "name": m.name, "english": m.english,
                "pollingRatesByProductId": Dictionary(uniqueKeysWithValues: m.polling.map { (hex($0.key), $0.value) }),
                "maxDPI": m.maxDPI, "dpiStep": m.dpiStep, "maxStages": m.maxStages, "lodMillimetres": m.lod,
                "hyperMode": m.hyperMode, "angleTune": m.angleTune, "sleep": m.sleep, "sleepInSeconds": m.sleepInSeconds, "independentXY": m.independentXY,
            ]
            if let wired = m.wiredPID { model["wiredProductId"] = hex(wired) }
            return model
        },
    ])
    exit(0)
}

/// Write-path check on each supported keyboard (or the one named after the flag): changes the last layer's first key,
/// a knob, the last macro slot and the lighting brightness, verifies, then restores the original and verifies again.
func keyboardRoundTrip() {
    let only = CommandLine.arguments.firstIndex(of: "--keyboard-roundtrip").flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil }
    let watcher = WiredKeyboardWatcher()
    watcher.onChange = { list in
        var failed = false
        for keyboard in list where keyboard.model != nil && (only == nil || keyboard.name.localizedCaseInsensitiveContains(only!)) {
            let model = keyboard.model!
            print("\(keyboard.name):")
            guard let channel = VIAChannel.find(vendorID: keyboard.vendorID, productID: keyboard.productID, location: keyboard.location) else { print("  no VIA channel"); failed = true; continue }
            do {
                try channel.withOpen {
                    let original = try VIAKeyboard.read(channel, model: model)
                    let url = try KeyboardBackup.save(KeyboardBackup(model: model, state: original), model: model)
                    print("  backup \(url.path)")
                    var changed = original
                    let layer = original.layers - 1, key = model.keys[0], index = key.row * model.cols + key.col
                    changed.keymap[layer][index] = original.keymap[layer][index] == 0x68 ? 0x69 : 0x68
                    if !model.knobs.isEmpty { changed.encoders[layer][0][1] = original.encoders[layer][0][1] == 0x68 ? 0x69 : 0x68 }
                    changed.macros[original.macroCount - 1] = [.text("mp")]
                    if var lighting = original.lighting, let menu = model.lighting {
                        lighting.brightness = lighting.brightness > menu.brightness.lowerBound + 40 ? lighting.brightness - 40 : lighting.brightness + 40
                        changed.lighting = lighting
                    }
                    let after = try VIAKeyboard.apply(channel, model: model, changed, over: original)
                    print("  wrote key \(key.id) on layer \(layer)" + (model.knobs.isEmpty ? "" : ", knob") + ", macro M\(original.macroCount - 1), brightness \(after.lighting?.brightness ?? -1): verified")
                    let restored = try VIAKeyboard.apply(channel, model: model, original, over: after)
                    let same = restored.keymap == original.keymap && restored.encoders == original.encoders
                        && MacroCodec.encode(restored.macros) == MacroCodec.encode(original.macros)
                        && (original.lighting == nil || VIAKeyboard.lightingMatches(restored.lighting!, original.lighting!, model: model))
                    print("  restored: \(same ? "identical to original" : "DIFFERENT")")
                    if !same { failed = true }
                }
            } catch { print("  error: \(error.localizedDescription)"); failed = true }
        }
        exit(failed ? 1 : 0)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(20))
    print("no keyboards reported"); exit(1)
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
else if CommandLine.arguments.contains("--keyboard-dump") { keyboardDump() }
else if CommandLine.arguments.contains("--keyboard-roundtrip") { keyboardRoundTrip() }
else if CommandLine.arguments.contains("--export-driver-data") { exportDriverData() }
else if CommandLine.arguments.contains("--test") { tests() }
else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
