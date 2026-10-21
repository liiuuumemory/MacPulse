import AppKit
import SwiftUI

private typealias PreferenceState<Value> = SwiftUI.State<Value>

struct PreferencesView: View {
    @ObservedObject var monitor: Monitor
    @PreferenceState private var selection: String
    init(monitor: Monitor, initialTab: String = "menu") {
        self.monitor = monitor
        self._selection = State<String>(initialValue: initialTab)
    }
    /// Fanless Macs (MacBook Air, some minis) get no fan page; until the SMC answers, keep it.
    private var hasFans: Bool { !monitor.sample.smcAvailable || !monitor.sample.fans.isEmpty }
    private var pages: [(id: String, title: String, symbol: String, color: Color)] { Self.allPages.filter { $0.id != "fan" || hasFans } }
    /// The page on screen: a jump to the fan page on a fanless Mac lands on sensors.
    private var current: String { selection == "fan" && !hasFans ? "sensors" : selection }
    private static let allPages: [(id: String, title: String, symbol: String, color: Color)] = [
        ("menu", "菜单栏", "menubar.rectangle", .blue),
        ("sensors", "传感器", "thermometer.medium", .red),
        ("fan", "风扇", "fan", .cyan),
        ("processes", "进程", "list.bullet.rectangle", .green),
        ("general", "常规", "gearshape", .gray),
        ("alerts", "提醒", "bell.badge", .orange),
        ("mouse", "外设", "computermouse", .teal),
        ("ai", "AI 用量", "sparkles", .purple),
    ]
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 180)
            Divider()
            VStack(spacing: 0) {
                if current == "menu" {
                    MenuBarPreview(monitor: monitor)
                        .frame(maxWidth: 620).padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
                        .frame(maxWidth: .infinity)
                    Divider()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if current == "menu" { MenuBarEditor(monitor: monitor) }
                        else if current == "sensors" { SensorSettingsView(monitor: monitor) }
                        else if current == "processes" { ProcessSettingsView(monitor: monitor) }
                        else if current == "alerts" { AlertSettingsView(alerts: monitor.alerts) }
                        else if current == "ai" { AIUsageSettingsView(usage: monitor.aiUsage) }
                        else if current == "mouse" { MouseSettingsView(center: monitor.mice) }
                        else if current == "fan" { FanSettingsView(fan: monitor.fan, temperature: monitor.sample.cpuTemp, readings: monitor.sample.fans) }
                        else { GeneralSettingsView(monitor: monitor) }
                    }.frame(maxWidth: 620, alignment: .leading).padding(24)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            // The content column may shrink; anything still too wide is clipped instead of shifting the sidebar.
            .frame(minWidth: 0, maxWidth: .infinity).clipped()
            .background(SettingsColor.content)
        }.frame(minWidth: 800, minHeight: 580)
            .onReceive(monitor.aiUsage.$preferencesTab.dropFirst()) { selection = $0 }
    }
    /// System Settings–style page list: a tinted icon tile plus a full-size label.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(pages, id: \.id) { page in
                Button { selection = page.id } label: {
                    HStack(spacing: 9) {
                        Image(systemName: page.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(page.color, in: RoundedRectangle(cornerRadius: 6))
                        Text(page.title).font(.system(size: 13, weight: current == page.id ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(current == page.id ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(current == page.id ? .isSelected : [])
            }
        }.padding(.horizontal, 10).padding(.top, 14)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(SettingsColor.sidebar)
    }
}

/// Settings surfaces: grey page, raised cards, so groups stay distinct in both appearances.
enum SettingsColor {
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
    static let content = adaptive(light: NSColor(white: 0.955, alpha: 1), dark: NSColor(white: 0.16, alpha: 1))
    static let sidebar = adaptive(light: NSColor(white: 0.925, alpha: 1), dark: NSColor(white: 0.12, alpha: 1))
    static let card = adaptive(light: .white, dark: NSColor(white: 1, alpha: 0.06))
    static let border = adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
}

extension View {
    func settingsCard() -> some View {
        background(SettingsColor.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsColor.border, lineWidth: 1))
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
            Text("传感器").font(.title2.weight(.semibold))
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
            HStack {
                Text("进程").font(.title2.weight(.semibold))
                Spacer()
                Button("打开活动监视器") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
            }
            HStack(alignment: .top, spacing: 12) {
                list("CPU 占用最高", PanelView.sortedProcesses(monitor.sample.processes, by: "cpu"))
                list("内存占用最高", PanelView.sortedProcesses(monitor.sample.processes, by: "memory"))
            }
            Text("CPU 为占单个核心的百分比，多线程进程可超过 100%；内存为物理占用，与活动监视器“内存”列口径一致。"
                 + (monitor.sample.processesHidden > 0 ? "另有 \(monitor.sample.processesHidden) 个系统或其他用户进程需要管理员权限，未列出。" : ""))
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Text("提醒").font(.title2.weight(.semibold))
                Spacer()
                Button("发送测试通知") { alerts.sendTest() }.disabled(!alerts.settings.enabled)
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("启用系统通知提醒").font(.body.weight(.medium))
                    Text("关闭时下方各项不会触发。").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
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

struct GeneralSettingsView: View {
    @ObservedObject var monitor: Monitor
    private var s: Sample { monitor.sample }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("常规设置").font(.title2.weight(.semibold))
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
