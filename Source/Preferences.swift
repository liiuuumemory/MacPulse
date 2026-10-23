import AppKit
import SwiftUI

private typealias PreferenceState<Value> = SwiftUI.State<Value>

struct SettingsPage: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let detail: String
}

struct SettingsGroup: Identifiable {
    let id: String
    let title: String
    /// One tile color per group, stepping blue → indigo → violet, with slate for the app-wide page.
    let color: NSColor
    let pages: [SettingsPage]
    static let all: [SettingsGroup] = [
        SettingsGroup(id: "display", title: "显示", color: NSColor(srgbRed: 0.231, green: 0.608, blue: 0.965, alpha: 1), pages: [
            SettingsPage(id: "menu", title: "菜单栏", symbol: "menubar.rectangle", detail: "自定义菜单栏中显示的小部件、顺序与外观，修改即时生效。"),
        ]),
        SettingsGroup(id: "monitor", title: "监控", color: NSColor(srgbRed: 0.231, green: 0.471, blue: 0.965, alpha: 1), pages: [
            SettingsPage(id: "sensors", title: "传感器", symbol: "thermometer.medium", detail: "查看芯片、内存、电池等全部温度、功耗与风扇读数，以及系统运行概要。"),
            SettingsPage(id: "processes", title: "进程", symbol: "list.bullet.rectangle", detail: "列出 CPU 与内存占用最高的进程，快速找到拖慢 Mac 的程序。"),
        ]),
        SettingsGroup(id: "hardware", title: "硬件", color: NSColor(srgbRed: 0.357, green: 0.424, blue: 0.941, alpha: 1), pages: [
            SettingsPage(id: "fan", title: "风扇", symbol: "fan", detail: "查看风扇转速，选择预设或自定义温度曲线来控制风扇。"),
            SettingsPage(id: "mouse", title: "外设", symbol: "powerplug.portrait", detail: "查看鼠标、键盘的电量与连接状态；点“自定义”进入设备页，调整 DPI、改键、宏与灯光。"),
        ]),
        SettingsGroup(id: "service", title: "服务", color: NSColor(srgbRed: 0.486, green: 0.361, blue: 0.902, alpha: 1), pages: [
            SettingsPage(id: "ai", title: "AI 用量", symbol: "sparkles", detail: "汇总 Codex、Claude 等 AI 工具的本地用量与账户额度，可设置自定义额度。"),
            SettingsPage(id: "alerts", title: "提醒", symbol: "bell.badge", detail: "温度过高、内存紧张、磁盘或电量不足、AI 额度将尽时发送系统通知。"),
        ]),
        SettingsGroup(id: "system", title: "系统", color: NSColor(srgbRed: 0.478, green: 0.518, blue: 0.580, alpha: 1), pages: [
            SettingsPage(id: "general", title: "常规", symbol: "gearshape", detail: "刷新间隔、登录启动、网络接口、电池信息、更新检查与诊断工具。"),
        ]),
    ]
    static func group(of page: String) -> SettingsGroup? { all.first { $0.pages.contains { $0.id == page } } }
}

/// System Settings–style icon tile: a white symbol on a softly graded group color.
struct SettingsIconTile: View {
    let symbol: String
    let color: NSColor
    var size: CGFloat = 22
    var body: some View {
        let top = color.blended(withFraction: 0.18, of: .white) ?? color
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color(nsColor: top), Color(nsColor: color)], startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.55, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

struct PreferencesView: View {
    @ObservedObject var monitor: Monitor
    /// Visited pages, newest last; `cursor` points at the page on screen so back and forward can walk it.
    @PreferenceState private var history: [String]
    @PreferenceState private var cursor = 0
    init(monitor: Monitor, initialTab: String = "menu") {
        self.monitor = monitor
        self._history = State<[String]>(initialValue: [initialTab])
    }
    /// Fanless Macs (MacBook Air, some minis) get no fan page; until the SMC answers, keep it.
    private var hasFans: Bool { !monitor.sample.smcAvailable || !monitor.sample.fans.isEmpty }
    private var groups: [SettingsGroup] {
        SettingsGroup.all.map { SettingsGroup(id: $0.id, title: $0.title, color: $0.color, pages: $0.pages.filter { $0.id != "fan" || hasFans }) }
    }
    /// The page on screen: a jump to the fan page on a fanless Mac lands on sensors.
    private var current: String {
        let selection = history[cursor]
        return selection == "fan" && !hasFans ? "sensors" : selection
    }
    /// A device page ("device:<id>") sits under 外设 in the sidebar.
    private var sidebarPage: String { current.hasPrefix("device:") ? "mouse" : current }
    private var page: SettingsPage {
        SettingsGroup.all.flatMap(\.pages).first { $0.id == sidebarPage } ?? SettingsGroup.all[0].pages[0]
    }
    private func go(_ id: String) {
        guard id != history[cursor] else { return }
        history = Array(history.prefix(cursor + 1)) + [id]
        cursor = history.count - 1
    }
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .frame(width: 220)
                .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(page.title)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        ControlGroup {
                            Button { cursor -= 1 } label: { Label("后退", systemImage: "chevron.left") }
                                .disabled(cursor == 0).keyboardShortcut("[", modifiers: .command)
                            Button { cursor += 1 } label: { Label("前进", systemImage: "chevron.right") }
                                .disabled(cursor >= history.count - 1).keyboardShortcut("]", modifiers: .command)
                        }.controlGroupStyle(.navigation)
                    }
                }
        }
        .frame(minWidth: 800, minHeight: 580)
        .onReceive(monitor.aiUsage.$preferencesTab.dropFirst()) { go($0) }
        .onChange(of: current, initial: true) { monitor.setSettingsPage(current) }
    }
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if current.hasPrefix("device:") {
                    PeripheralDetailPage(monitor: monitor, device: String(current.dropFirst(7))) {
                        // Back returns to the overview it came from rather than stacking another visit.
                        if cursor > 0 && history[cursor - 1] == "mouse" { cursor -= 1 } else { go("mouse") }
                    }
                } else { header }
                if current == "menu" { MenuBarPreview(monitor: monitor); MenuBarEditor(monitor: monitor) }
                else if current == "sensors" { SensorSettingsView(monitor: monitor) }
                else if current == "processes" { ProcessSettingsView(monitor: monitor) }
                else if current == "alerts" { AlertSettingsView(alerts: monitor.alerts) }
                else if current == "ai" { AIUsageSettingsView(usage: monitor.aiUsage) }
                else if current == "mouse" { PeripheralsSettingsView(monitor: monitor, mice: monitor.mice, keyboards: monitor.keyboards, open: go) }
                else if current.hasPrefix("device:") { EmptyView() }
                else if current == "fan" { FanSettingsView(fan: monitor.fan, temperature: monitor.sample.cpuTemp, readings: monitor.sample.fans) }
                else { GeneralSettingsView(monitor: monitor) }
            }.frame(maxWidth: 620, alignment: .leading).padding(24)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        // The content column may shrink; anything still too wide is clipped instead of pushing the sidebar.
        .frame(minWidth: 0, maxWidth: .infinity).clipped()
    }
    /// Page header: icon and large title, one line on what the page is for, then a rule.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SettingsIconTile(symbol: page.symbol, color: SettingsGroup.group(of: page.id)?.color ?? .systemBlue, size: 38)
                Text(page.title).font(.system(size: 24, weight: .semibold))
            }
            Text(page.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().padding(.top, 4)
        }
    }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    /// The system sidebar list, so it gets the Liquid Glass sidebar and selection of macOS 26 and later.
    private var sidebar: some View {
        List(selection: Binding<String?>(get: { sidebarPage }, set: { if let id = $0 { go(id) } })) {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.pages) { page in
                        Label { Text(page.title) } icon: { SettingsIconTile(symbol: page.symbol, color: group.color) }
                            .tag(page.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                // Drawn live: the Dock's cached app icon can lag behind a new icon file.
                AppLogo(size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MacPulse").font(.system(size: 14, weight: .semibold))
                    Text("版本 \(version)").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 8)
        }
    }
}

/// Settings surfaces: borderless grouped boxes on the system window background, as in System Settings.
enum SettingsColor {
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
    static let card = adaptive(light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.055))
    static let border = adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
}

extension View {
    func settingsCard() -> some View {
        background(SettingsColor.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SensorSettingsView: View {
    @ObservedObject var monitor: Monitor
    @PreferenceState private var filter = "全部"
    private var filtered: [SensorValue] {
        monitor.sample.sensors.filter { sensor in
            filter == "全部" || sensor.name == filter ||
            (filter == "风扇" && sensor.kind == "RPM") ||
            (filter == "功耗" && sensor.kind == "W") ||
            (filter == "其他" && !["CPU", "GPU", "内存"].contains(sensor.name) && sensor.kind == "°C")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SystemDetailsCard(monitor: monitor)
            Text("\(monitor.sample.sensors.count) 项读数 · CPU / GPU 总览取各组最高温度")
                .font(.callout).foregroundStyle(.secondary)
            Picker("分组", selection: $filter) {
                ForEach(["全部", "CPU", "GPU", "内存", "功耗", "风扇", "其他"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if filtered.isEmpty { Text("此分组暂无可用传感器").foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(filtered) { sensor in
                    // One compact row per sensor: name and key on the left, the reading right-aligned.
                    HStack(spacing: 8) {
                        Text(sensor.name).font(.body).lineLimit(1)
                        Text(sensor.key).font(.system(.subheadline, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text("\(Format.number(sensor.value, decimals: sensor.kind == "RPM" ? 0 : sensor.kind == "W" ? 2 : 1)) \(sensor.kind)")
                            .font(.system(size: 14, weight: .medium)).monospacedDigit().lineLimit(1)
                            .foregroundStyle(sensor.kind == "°C" && sensor.value > 85 ? Color.orange : Color.primary)
                    }.padding(.horizontal, 12).padding(.vertical, 9)
                        .settingsCard()
                        .help("\(sensor.name) · \(sensor.key)")
                }
            }
        }
    }
}

struct ProcessSettingsView: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                list("CPU 占用最高", PanelView.sortedProcesses(monitor.sample.processes, by: "cpu"))
                list("内存占用最高", PanelView.sortedProcesses(monitor.sample.processes, by: "memory"))
            }
            Text("CPU 为占单个核心的百分比，多线程进程可超过 100%；内存为物理占用，与活动监视器“内存”列口径一致。"
                 + (monitor.sample.processesHidden > 0 ? "另有 \(monitor.sample.processesHidden) 个系统或其他用户进程需要管理员权限，未列出。" : ""))
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("打开活动监视器") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
        }
    }
    private func list(_ title: String, _ items: [ProcessUsage]) -> some View {
        PreferenceCard(title: title) {
            if items.isEmpty { Text("正在采集…").font(.callout).foregroundStyle(.secondary) }
            else {
                HStack(spacing: 8) {
                    Text("名称"); Spacer(minLength: 6)
                    Text("CPU").frame(width: 56, alignment: .trailing)
                    Text("内存").frame(width: 70, alignment: .trailing)
                }.font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array(items.prefix(10))) { process in
                HStack(spacing: 8) {
                    Text(process.name).lineLimit(1).truncationMode(.middle).help("\(process.name)（PID \(process.pid)）")
                    Spacer(minLength: 6)
                    Text(Format.number(process.cpu, suffix: "%", decimals: 1)).frame(width: 56, alignment: .trailing)
                    Text(Format.bytes(process.memory)).frame(width: 70, alignment: .trailing)
                }.font(.body).monospacedDigit()
            }
        }
    }
}

struct AlertSettingsView: View {
    @ObservedObject var alerts: AlertCenter
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("启用系统通知提醒").font(.body.weight(.medium))
                    Text("关闭时下方各项不会触发。").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("发送测试通知") { alerts.sendTest() }.disabled(!alerts.settings.enabled)
                Toggle("启用系统通知提醒", isOn: $alerts.settings.enabled).toggleStyle(.switch).labelsHidden()
            }.padding(16).settingsCard()
            if !alerts.status.isEmpty { Text(alerts.status).font(.subheadline).foregroundStyle(.orange) }
            PreferenceCard(title: "硬件") {
                rule("CPU 温度持续 30 秒不低于", isOn: $alerts.settings.cpuTemperature) {
                    Picker("温度", selection: $alerts.settings.cpuTemperatureLimit) {
                        ForEach([85.0, 90, 95, 100, 105], id: \.self) { Text("\(Int($0)) °C").tag($0) }
                    }
                }
                rule("内存压力持续 30 秒处于“紧张”", isOn: $alerts.settings.memoryPressure) { EmptyView() }
                rule("磁盘可用空间低于", isOn: $alerts.settings.diskFree) {
                    Picker("磁盘", selection: $alerts.settings.diskFreeLimitGB) {
                        ForEach([5.0, 10, 20, 50, 100], id: \.self) { Text("\(Int($0)) GB").tag($0) }
                    }
                }
                rule("未充电且电量不高于", isOn: $alerts.settings.battery) {
                    Picker("电量", selection: $alerts.settings.batteryLimit) {
                        ForEach([5.0, 10, 15, 20, 30], id: \.self) { Text("\(Int($0))%").tag($0) }
                    }
                }
            }.disabled(!alerts.settings.enabled)
            PreferenceCard(title: "AI 额度") {
                rule("Codex / Claude 剩余额度低于", isOn: $alerts.settings.aiQuota) {
                    Picker("额度", selection: $alerts.settings.aiQuotaLimit) {
                        ForEach([5.0, 10, 20, 30, 50], id: \.self) { Text("\(Int($0))%").tag($0) }
                    }
                }
                Text("按最紧张的额度窗口计算；启用自定义额度时按自定义剩余比例。旧数据不触发提醒。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.disabled(!alerts.settings.enabled)
            Text("每项条件触发后只提醒一次，恢复正常后才会再次提醒；温度恢复以低于阈值 5 °C 为准。提醒在本机生成，不联网发送。")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func rule<Control: View>(_ title: String, isOn: Binding<Bool>, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: isOn).toggleStyle(.checkbox)
            control().labelsHidden().frame(width: 110).disabled(!isOn.wrappedValue)
            Spacer(minLength: 0)
        }
    }
}

struct UpdateSection: View {
    @ObservedObject var updater: UpdateChecker
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(updater.checking ? "正在检查…" : "检查更新") { updater.check() }.disabled(updater.checking)
                Toggle("每天自动检查", isOn: $updater.automatic).toggleStyle(.checkbox)
                Spacer(minLength: 0)
            }
            if let latest = updater.latest, updater.updateAvailable {
                Text("发现新版本 \(latest.version)" + (latest.published.map { "（\($0.formatted(date: .abbreviated, time: .omitted)) 发布）" } ?? ""))
                    .font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
                if !latest.notes.isEmpty {
                    Text(latest.notes).font(.subheadline).foregroundStyle(.secondary).lineLimit(6).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("查看发布说明") { NSWorkspace.shared.open(latest.url) }
                    if updater.updateCommand != nil { Button("复制更新命令") { updater.copyUpdateCommand() } }
                }
                Text(updater.updateCommand.map { "源码目录是 git 仓库，在“终端”运行：\($0)" } ?? "下载新版本源码后，在源码目录运行 bash build.sh 重新编译安装。")
                    .font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !updater.message.isEmpty { Text(updater.message).font(.subheadline).foregroundStyle(.secondary) }
            if let date = updater.lastChecked {
                Text("上次检查：" + date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
            }
            Text("只读取 github.com/\(UpdateChecker.repository) 的公开发布信息，不发送本机数据，不会自动下载或安装。")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Labels stay immediately above controls instead of opposite the window edge.
struct PreferenceField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PreferenceCard<Content: View>: View {
    let title: String
    var minContentHeight: CGFloat = 0
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }.frame(maxWidth: .infinity, minHeight: minContentHeight, maxHeight: .infinity, alignment: .topLeading)
            .padding(16).settingsCard()
    }
}

/// Picks up to three disks for the panel's disk card, in the order they are ticked.
struct PanelDiskPicker: View {
    @ObservedObject var monitor: Monitor
    private var chosen: [String] { monitor.panelDisks ?? Monitor.defaultDisks(monitor.sample.volumes).map(\.id) }
    /// Connected disks, then chosen ones that are unplugged now.
    private var rows: [(id: String, name: String, volume: VolumeInfo?)] {
        let connected = monitor.sample.volumes.map { (id: $0.id, name: $0.name, volume: Optional($0)) }
        let missing = chosen.filter { id in !connected.contains { $0.id == id } }
            .map { (id: $0, name: monitor.knownVolumes[$0] ?? "未知磁盘", volume: VolumeInfo?.none) }
        return connected + missing
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.id) { row in
                let on = chosen.contains(row.id)
                Toggle(isOn: Binding(get: { on }, set: { toggle(row.id, $0) })) {
                    HStack(spacing: 8) {
                        Group {
                            if let volume = row.volume, volume.path != "/" {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: volume.path)).resizable()
                            } else {
                                Image(systemName: row.volume == nil ? "externaldrive.badge.xmark" : VolumeInfo.macSymbol).foregroundStyle(.secondary)
                            }
                        }.frame(width: 18, height: 18)
                        Text(row.name).lineLimit(1).truncationMode(.tail)
                        if let volume = row.volume {
                            Text("可用 \(Format.bytes(volume.free)) / \(Format.bytes(volume.total))").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("未连接").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!on && chosen.count >= Monitor.maxPanelDisks)
            }
            Text("最多选 \(Monitor.maxPanelDisks) 个，按勾选的先后排列。未连接的磁盘不显示，接上后自动出现。磁盘映像和网络磁盘不列出。")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func toggle(_ id: String, _ on: Bool) {
        var list = chosen.filter { $0 != id }
        if on { list.append(id) }
        monitor.panelDisks = Array(list.prefix(Monitor.maxPanelDisks))
    }
}

/// A small sample of the panel glass over a colorful backdrop, updated as the setting changes.
struct GlassPreview: View {
    let mode: String
    let tint: Double
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.25, green: 0.45, blue: 1), Color(red: 0.75, green: 0.35, blue: 0.85), Color(red: 1, green: 0.6, blue: 0.3)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text("MacPulse").font(.system(size: 13, weight: .semibold)).frame(width: 104, height: 56)
                .glassEffect(PanelLayout.glass(mode: mode, tint: tint, dark: scheme == .dark),
                             in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(width: 150, height: 86)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var monitor: Monitor
    private var s: Sample { monitor.sample }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                PreferenceCard(title: "采样", minContentHeight: 96) {
                    PreferenceField(title: "刷新间隔") {
                        Picker("刷新间隔", selection: $monitor.interval) {
                            Text("0.5 秒").tag(0.5); Text("1 秒").tag(1.0)
                            Text("2 秒").tag(2.0); Text("5 秒").tag(5.0)
                        }
                    }
                    Text("曲线保留 2 分钟。间隔越长，采样开销越低。")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                PreferenceCard(title: "启动", minContentHeight: 96) {
                    Toggle("登录时启动 MacPulse", isOn: Binding(get: { monitor.loginEnabled }, set: { monitor.setLogin($0) }))
                        .toggleStyle(.checkbox)
                    Text("启动后常驻菜单栏。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !monitor.settingsMessage.isEmpty {
                        Text(monitor.settingsMessage).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.fixedSize(horizontal: false, vertical: true)
            PreferenceCard(title: "面板玻璃") {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("透明度", selection: $monitor.glassMode) {
                            Text("跟随系统").tag("system"); Text("自定义").tag("custom")
                        }.pickerStyle(.segmented).labelsHidden().fixedSize()
                        HStack(spacing: 10) {
                            Text("清透").font(.subheadline).foregroundStyle(.secondary)
                            Slider(value: $monitor.glassTint, in: 0...1).frame(maxWidth: 240)
                            Text("着色").font(.subheadline).foregroundStyle(.secondary)
                        }.disabled(monitor.glassMode != "custom").opacity(monitor.glassMode == "custom" ? 1 : 0.45)
                        Text(monitor.glassMode == "system"
                             ? "面板用系统的液态玻璃外观，在系统设置里调整液态玻璃的透明度时一起变化。"
                             : "越靠近“清透”，面板越透明，后面的窗口和壁纸越明显；越靠近“着色”，面板越实，文字越清楚。固定面板后可以边调边看。")
                            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    GlassPreview(mode: monitor.glassMode, tint: monitor.glassTint)
                }
            }
            PreferenceCard(title: "面板中的磁盘") { PanelDiskPicker(monitor: monitor) }
            PreferenceCard(title: "网络") {
                PreferenceField(title: "统计接口") {
                    Picker("统计接口", selection: $monitor.selectedInterface) {
                        Text("自动（合计）").tag("auto")
                        ForEach(s.networks) { network in Text(network.name).tag(network.name) }
                        if monitor.selectedInterface != "auto" && !s.networks.contains(where: { $0.name == monitor.selectedInterface }) {
                            Text("\(monitor.selectedInterface) · 未连接").tag(monitor.selectedInterface)
                        }
                    }
                }.frame(width: 240)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                    ForEach(s.networks.filter { !$0.address.isEmpty }) { network in
                        PreferenceField(title: network.name) {
                            Text(network.address).font(.callout).monospacedDigit()
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("统计 Wi-Fi 与以太网，排除重复的虚拟接口。总览使用字节/秒（1 KB = 1024 B）。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let battery = s.batteryPercent {
                PreferenceCard(title: "电池") {
                    HStack(alignment: .top, spacing: 16) {
                        PreferenceField(title: "电量") { Text(Format.number(battery, suffix: "%") + (s.charging ? " · 充电中" : "")).font(.callout).monospacedDigit() }
                        PreferenceField(title: "最大容量") {
                            Text(Format.number(s.batteryHealth, suffix: "%") + (s.batteryCapacity.map { "（\(Format.number($0.full)) / \(Format.number($0.design)) mAh）" } ?? ""))
                                .font(.callout).monospacedDigit()
                        }
                        PreferenceField(title: "循环次数") {
                            Text(s.batteryCycles.map { "\($0)" + (s.batteryDesignCycles.map { " / \($0)" } ?? "") } ?? "—").font(.callout).monospacedDigit()
                        }
                    }
                    Text("最大容量为当前满充容量占设计容量的比例，与“系统设置 → 电池”接近，读数会随温度和校准小幅波动。")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            PreferenceCard(title: "外设电量") {
                if monitor.peripherals.isEmpty {
                    Text("未检测到可读取电量的无线外设。").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(monitor.peripherals) { device in
                    HStack(spacing: 12) {
                        Image(systemName: device.charging ? "bolt.fill" : "computermouse").frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.body)
                            Text(device.source + " · " + (Date().timeIntervalSince(device.updated) > 120
                                 ? device.updated.formatted(date: .omitted, time: .shortened) + " 的读数，设备可能在休眠"
                                 : "刚刚更新") + (device.charging ? " · 正在充电" : ""))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Format.number(device.percent, suffix: "%")).font(.system(size: 15, weight: .medium)).monospacedDigit()
                            .foregroundStyle(device.percent <= 15 && !device.charging ? Color.orange : Color.primary)
                        UsageBar(fraction: device.percent / 100, color: device.percent <= 15 && !device.charging ? .orange : .green, warnAbove: nil).frame(width: 80)
                    }
                }
                Text("每分钟读取一次，鼠标休眠时保留上次读数。可在“菜单栏”页添加“鼠标 / 外设电量”小部件。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("鼠标设置与支持的设备…") { monitor.aiUsage.preferencesTab = "mouse" }
            }
            PreferenceCard(title: "工具与关于") {
                HStack(spacing: 8) {
                    Button("打开活动监视器") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
                    Button("复制诊断信息") { monitor.copyReport() }
                }
                Divider()
                HStack(alignment: .top, spacing: 16) {
                    PreferenceField(title: "版本") { Text("MacPulse \(version)").font(.body) }
                    PreferenceField(title: "设备") { Text(monitor.model).font(.body) }
                }.font(.callout)
                UpdateSection(updater: monitor.updater)
                Text("功耗来源：\(s.powerSource)").font(.subheadline).foregroundStyle(.secondary)
                Text("数据仅在本机处理。系统功耗不等同于插座功率；不可用数据以 — 显示。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Details that used to crowd the panel's system page: cores, chip power, load, memory, disk, network addresses.
struct SystemDetailsCard: View {
    @ObservedObject var monitor: Monitor
    @PreferenceState private var copied: String?
    private var s: Sample { monitor.sample }
    var body: some View {
        PreferenceCard(title: "系统概要") {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 12) {
                fact("CPU", "\(Format.number(s.cpu, suffix: "%", decimals: 1))（用户 \(Format.number(s.cpuUser))% · 系统 \(Format.number(s.cpuSystem))%）")
                fact("芯片功耗", s.cpuPower == nil ? "—" : "CPU \(Format.number(s.cpuPower, suffix: " W", decimals: 2)) · GPU \(Format.number(s.gpuPower, suffix: " W", decimals: 2)) · ANE \(Format.number(s.anePower, suffix: " W", decimals: 2))")
                fact("系统负载（1 / 5 / 15 分钟）", s.load.map { Format.number($0, decimals: 2) }.joined(separator: " / "))
                fact("内存", s.memoryValid ? "\(Format.bytes(s.memoryUsed)) / \(Format.bytes(s.memoryTotal))" : "—")
                fact("内存压力 · 交换", "\(s.pressure) · \(Format.bytes(s.swap))")
                fact("磁盘可用", s.diskTotal > 0 ? "\(Format.bytes(s.diskFree)) / \(Format.bytes(s.diskTotal))" : "—")
                fact("磁盘读 / 写", "\(Format.rate(s.diskRead)) / \(Format.rate(s.diskWrite))")
                fact("GPU 温度", Format.number(s.gpuTemp, suffix: " °C", decimals: 1))
                fact("本次运行耗电", "\(Format.number(monitor.energyWh, decimals: 2)) Wh")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("各核心负载").font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(Array(s.cores.enumerated()), id: \.offset) { i, value in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.13))
                            RoundedRectangle(cornerRadius: 3).fill(value >= 80 ? Color.orange : Color.blue).frame(height: max(2, 28 * value / 100))
                        }.frame(maxWidth: .infinity).frame(height: 28).help("核心 \(i + 1)：\(Format.number(value, suffix: "%"))")
                    }
                }
            }
            let addresses = monitor.networks.filter { !$0.address.isEmpty }
            if !addresses.isEmpty {
                HStack(spacing: 16) {
                    ForEach(addresses) { network in
                        // Click to copy; the label confirms for two seconds.
                        Button {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(network.address, forType: .string)
                            copied = network.name
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == network.name { copied = nil } }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(copied == network.name ? "已复制到剪贴板" : "\(network.name) · IP · 点击复制").font(.callout).foregroundStyle(.secondary)
                                Text(network.address).font(.body).monospacedDigit()
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.body).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }
    }
}
