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
    var body: some View {
        VStack(spacing: 0) {
            Picker("设置页面", selection: $selection) {
                Text("菜单栏").tag("menu")
                Text("传感器").tag("sensors")
                Text("进程").tag("processes")
                Text("常规").tag("general")
                Text("提醒").tag("alerts")
                Text("AI 用量").tag("ai")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 580).padding(16)
            if selection == "menu" {
                MenuBarPreview(monitor: monitor)
                    .frame(maxWidth: 600).padding(.horizontal, 20).padding(.bottom, 14)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if selection == "menu" { MenuBarEditor(monitor: monitor) }
                    else if selection == "sensors" { SensorSettingsView(monitor: monitor) }
                    else if selection == "processes" { ProcessSettingsView(monitor: monitor) }
                    else if selection == "alerts" { AlertSettingsView(alerts: monitor.alerts) }
                    else if selection == "ai" { AIUsageSettingsView(usage: monitor.aiUsage) }
                    else { GeneralSettingsView(monitor: monitor) }
                }.frame(maxWidth: 600, alignment: .leading).padding(20)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }.frame(minWidth: 600, minHeight: 580)
            .onReceive(monitor.aiUsage.$preferencesTab.dropFirst()) { selection = $0 }
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
            Text("传感器").font(.title3.weight(.medium))
            Text("\(monitor.sample.sensors.count) 项读数 · CPU / GPU 总览取各组最高温度")
                .font(.callout).foregroundStyle(.secondary)
            Picker("分组", selection: $filter) {
                ForEach(["全部", "CPU", "GPU", "内存", "功耗", "风扇", "其他"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if filtered.isEmpty { Text("此分组暂无可用传感器").foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(filtered) { sensor in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sensor.name).font(.callout).lineLimit(1)
                            Text(sensor.key).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }.frame(width: 80, alignment: .leading)
                        Text("\(Format.number(sensor.value, decimals: sensor.kind == "RPM" ? 0 : sensor.kind == "W" ? 2 : 1)) \(sensor.kind)")
                            .font(.system(size: 14)).monospacedDigit().lineLimit(1)
                            .foregroundStyle(sensor.kind == "°C" && sensor.value > 85 ? Color.orange : Color.primary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
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
                Text("进程").font(.title3.weight(.medium))
                Spacer()
                Button("打开活动监视器") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
            }
            HStack(alignment: .top, spacing: 12) {
                list("CPU 占用最高", PanelView.sortedProcesses(monitor.sample.processes, by: "cpu"))
                list("内存占用最高", PanelView.sortedProcesses(monitor.sample.processes, by: "memory"))
            }
            Text("CPU 为占单个核心的百分比，多线程进程可超过 100%；内存为物理占用，与活动监视器“内存”列口径一致。"
                 + (monitor.sample.processesHidden > 0 ? "另有 \(monitor.sample.processesHidden) 个系统或其他用户进程需要管理员权限，未列出。" : ""))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.controlSize(.small)
    }
    private func list(_ title: String, _ items: [ProcessUsage]) -> some View {
        PreferenceCard(title: title) {
            if items.isEmpty { Text("正在采集…").font(.callout).foregroundStyle(.secondary) }
            ForEach(Array(items.prefix(10))) { process in
                HStack(spacing: 8) {
                    Text(process.name).lineLimit(1).truncationMode(.middle).help("\(process.name)（PID \(process.pid)）")
                    Spacer(minLength: 6)
                    Text(Format.number(process.cpu, suffix: "%", decimals: 1)).frame(width: 52, alignment: .trailing)
                    Text(Format.bytes(process.memory)).frame(width: 66, alignment: .trailing)
                }.font(.callout).monospacedDigit()
            }
        }
    }
}

struct AlertSettingsView: View {
    @ObservedObject var alerts: AlertCenter
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("提醒").font(.title3.weight(.medium))
                Spacer()
                Button("发送测试通知") { alerts.sendTest() }.disabled(!alerts.settings.enabled)
            }
            Toggle("启用系统通知提醒", isOn: $alerts.settings.enabled).toggleStyle(.checkbox)
            if !alerts.status.isEmpty { Text(alerts.status).font(.caption).foregroundStyle(.orange) }
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
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.disabled(!alerts.settings.enabled)
            Text("每项条件触发后只提醒一次，恢复正常后才会再次提醒；温度恢复以低于阈值 5 °C 为准。提醒在本机生成，不联网发送。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.controlSize(.small)
    }
    private func rule<Control: View>(_ title: String, isOn: Binding<Bool>, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: isOn).toggleStyle(.checkbox)
            control().labelsHidden().frame(width: 100).disabled(!isOn.wrappedValue)
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
                    Text(latest.notes).font(.caption).foregroundStyle(.secondary).lineLimit(6).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("查看发布说明") { NSWorkspace.shared.open(latest.url) }
                    if updater.updateCommand != nil { Button("复制更新命令") { updater.copyUpdateCommand() } }
                }
                Text(updater.updateCommand.map { "源码目录是 git 仓库，在“终端”运行：\($0)" } ?? "下载新版本源码后，在源码目录运行 bash build.sh 重新编译安装。")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !updater.message.isEmpty { Text(updater.message).font(.caption).foregroundStyle(.secondary) }
            if let date = updater.lastChecked {
                Text("上次检查：" + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Text("只读取 github.com/\(UpdateChecker.repository) 的公开发布信息，不发送本机数据，不会自动下载或安装。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Labels stay immediately above controls instead of opposite the window edge.
struct PreferenceField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PreferenceCard<Content: View>: View {
    let title: String
    var minContentHeight: CGFloat = 0
    @ViewBuilder var content: () -> Content
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.callout.weight(.medium))
                content()
            }.frame(maxWidth: .infinity, minHeight: minContentHeight, alignment: .topLeading).padding(8)
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var monitor: Monitor
    private var s: Sample { monitor.sample }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("常规设置").font(.title3.weight(.medium))
            HStack(alignment: .top, spacing: 12) {
                PreferenceCard(title: "采样", minContentHeight: 96) {
                    PreferenceField(title: "刷新间隔") {
                        Picker("刷新间隔", selection: $monitor.interval) {
                            Text("0.5 秒").tag(0.5); Text("1 秒").tag(1.0)
                            Text("2 秒").tag(2.0); Text("5 秒").tag(5.0)
                        }
                    }
                    Text("曲线保留 2 分钟。间隔越长，采样开销越低。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                PreferenceCard(title: "启动", minContentHeight: 96) {
                    Toggle("登录时启动 MacPulse", isOn: Binding(get: { monitor.loginEnabled }, set: { monitor.setLogin($0) }))
                        .toggleStyle(.checkbox)
                    Text("启动后常驻菜单栏。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !monitor.settingsMessage.isEmpty {
                        Text(monitor.settingsMessage).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
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
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            PreferenceCard(title: "工具与关于") {
                HStack(spacing: 8) {
                    Button("打开活动监视器") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
                    Button("复制诊断信息") { monitor.copyReport() }
                }
                Divider()
                HStack(alignment: .top, spacing: 16) {
                    PreferenceField(title: "版本") { Text("MacPulse \(version)") }
                    PreferenceField(title: "设备") { Text(monitor.model) }
                }.font(.callout)
                UpdateSection(updater: monitor.updater)
                Text("功耗来源：\(s.powerSource)").font(.caption).foregroundStyle(.secondary)
                Text("数据仅在本机处理。系统功耗不等同于插座功率；不可用数据以 — 显示。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.controlSize(.small)
    }
}
