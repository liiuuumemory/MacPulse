import SwiftUI
import AppKit
import ServiceManagement

// Keep the property wrapper available when building with Command Line Tools.
private typealias ViewState<Value> = SwiftUI.State<Value>

enum PanelLayout {
    static let width: CGFloat = 330
    static let height: CGFloat = 530
}

/// One type scale for the panel, so labels, values and headings read as distinct levels.
enum PanelFont {
    static let heading = Font.system(size: 13, weight: .semibold)
    static let label = Font.system(size: 11)
    static let hero = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let value = Font.system(size: 13, weight: .medium)
    static let tile = Font.system(size: 16, weight: .semibold, design: .rounded)
    static let row = Font.system(size: 12)
}

/// Native, adaptive macOS backdrop. No opaque SwiftUI surface covers the effect.
struct PanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct Sparkline: View {
    let values: [(Date, Double?)]
    var color: Color = .accentColor
    var fixedMax: Double? = nil
    var body: some View {
        Canvas { context, size in
            guard values.count > 1, let end = values.last?.0 else { return }
            let maximum = max(1, fixedMax ?? (values.compactMap(\.1).max() ?? 1) * 1.15)
            // Gaps in the data split the curve into separate filled segments.
            var segments: [[CGPoint]] = [[]]
            for (date, value) in values {
                guard let value, value.isFinite else { if !segments[segments.count - 1].isEmpty { segments.append([]) }; continue }
                let x = size.width * max(0, min(1, (date.timeIntervalSince(end) + 120) / 120))
                let y = size.height - 1 - min(1, max(0, value / maximum)) * (size.height - 2)
                segments[segments.count - 1].append(CGPoint(x: x, y: y))
            }
            let fill = Gradient(colors: [color.opacity(0.28), color.opacity(0.02)])
            for points in segments where points.count > 1 {
                var line = Path()
                line.addLines(points)
                var area = line
                area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
                area.addLine(to: CGPoint(x: points[0].x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(fill, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }.accessibilityHidden(true)
    }
}

struct DetailRow: View {
    let title: String
    let value: String
    var warning = false
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(title).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 4)
                Text(value).monospacedDigit().fixedSize()
                    .foregroundStyle(warning ? Color.orange : Color.primary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.secondary)
                Text(value).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(warning ? Color.orange : Color.primary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.font(.callout).help(value)
    }
}

/// Thin capsule showing how full something is; turns orange near the limit.
struct UsageBar: View {
    let fraction: Double
    var color: Color = .accentColor
    /// Usage bars warn when nearly full; battery bars pass nil and choose their own color.
    var warnAbove: Double? = 0.9
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(warnAbove.map { fraction > $0 } == true ? Color.orange : color)
                    .frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }.frame(height: 4).accessibilityHidden(true)
    }
}

struct SectionTitle: View {
    let title: String
    var note: String = ""
    var body: some View {
        HStack {
            Text(title).font(.callout.weight(.medium))
            Spacer()
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct CompactMetric: View {
    let title: String
    let value: String
    let note: String
    let values: [(Date, Double?)]
    var max: Double? = nil
    var color: Color = .accentColor
    var warning = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(PanelFont.label).foregroundStyle(.secondary)
            }
            Text(value).font(PanelFont.hero).monospacedDigit()
                .foregroundStyle(warning ? Color.orange : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.8)
            Sparkline(values: values, color: color, fixedMax: max).frame(height: 18)
            Text(note).font(PanelFont.label).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.85).help(note)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

struct UpdateBadge: View {
    @ObservedObject var updater: UpdateChecker
    var action: () -> Void
    var body: some View {
        if updater.updateAvailable, let latest = updater.latest {
            Button(action: action) { Label("新版本 \(latest.version)", systemImage: "arrow.down.circle") }
                .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
                .help("MacPulse \(latest.version) 已发布，点击查看").accessibilityLabel("MacPulse \(latest.version) 已发布")
        }
    }
}

struct PanelView: View {
    @ObservedObject var monitor: Monitor
    @ViewState private var processSort = "cpu"
    @ViewState private var page: String
    var height: CGFloat = PanelLayout.height
    var dismiss: () -> Void = {}
    var openSettings: () -> Void = {}
    static let pages = [("system", "系统"), ("devices", "外设"), ("ai", "AI 用量")]
    init(monitor: Monitor, height: CGFloat = PanelLayout.height, page: String? = nil, dismiss: @escaping () -> Void = {}, openSettings: @escaping () -> Void = {}) {
        self.monitor = monitor
        self.height = height
        self.dismiss = dismiss
        self.openSettings = openSettings
        // The last page reopens; it is a per-Mac convenience only.
        let saved = page ?? UserDefaults.standard.string(forKey: "panel.page") ?? "system"
        _page = ViewState(initialValue: Self.pages.contains { $0.0 == saved } ? saved : "system")
    }
    private var s: Sample { monitor.sample }
    private var sectionGap: CGFloat { 7 }
    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("面板页面", selection: Binding(get: { page }, set: { page = $0; UserDefaults.standard.set($0, forKey: "panel.page") })) {
                ForEach(Self.pages, id: \.0) { Text($0.1).tag($0.0) }
            }.pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 14).padding(.bottom, 8)
            Divider()
            // Content that outgrows the page (several mice, a short screen) scrolls instead of clipping.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: sectionGap) {
                    switch page {
                    case "devices": DevicesPanelPage(peripherals: monitor.peripherals, history: monitor.batteryHistory, mice: monitor.mice, open: openMouseSettings)
                    case "ai": AIUsagePanel(usage: monitor.aiUsage, openSettings: openSettings, roomy: true)
                    default: overview
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            // A visible scroller would take width from the page whenever a mouse is connected.
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .font(.callout)
        .frame(width: PanelLayout.width, height: height)
        .foregroundStyle(.primary)
        .background { PanelMaterial() }
    }
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("MacPulse").font(.headline)
                Text(monitor.chip)
                    .font(PanelFont.label).foregroundStyle(.secondary)
            }
            Spacer()
            Button { monitor.pinned.toggle() } label: {
                Image(systemName: monitor.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(monitor.pinned ? Color.accentColor : Color.secondary)
            }.help(monitor.pinned ? "取消固定面板" : "固定面板")
                .accessibilityLabel(monitor.pinned ? "取消固定面板" : "固定面板")
            Button(action: dismiss) { Image(systemName: "xmark").foregroundStyle(.secondary) }
                .help("关闭面板").accessibilityLabel("关闭面板")
        }.buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 8)
    }
    @ViewBuilder private var overview: some View {
        let temperature = s.cpuTemp
        HStack(spacing: 2) {
            RingGauge(label: "CPU", value: Format.number(s.cpu, suffix: "%"), fraction: s.cpu.map { $0 / 100 }, color: .blue)
                .jump(.activityMonitor(.cpu), detail: "CPU \(Format.number(s.cpu, suffix: "%", decimals: 1))：用户 \(Format.number(s.cpuUser))% · 系统 \(Format.number(s.cpuSystem))%", openSettings: openPage)
            // Activity Monitor's CPU tab can show a % GPU column per process.
            RingGauge(label: "GPU", value: Format.number(s.gpu, suffix: "%"), fraction: s.gpu.map { $0 / 100 }, color: .purple)
                .jump(.activityMonitor(.cpu), detail: "GPU \(Format.number(s.gpu, suffix: "%")) · 温度 \(Format.number(s.gpuTemp, suffix: " °C", decimals: 1))", openSettings: openPage)
            RingGauge(label: "内存", value: s.memoryValid && s.memoryTotal > 0 ? Format.number(s.memoryUsed / s.memoryTotal * 100, suffix: "%") : "—",
                      fraction: s.memoryValid && s.memoryTotal > 0 ? s.memoryUsed / s.memoryTotal : nil, color: s.pressure == "紧张" ? .orange : .green)
                .jump(.activityMonitor(.memory), detail: "内存 \(Format.bytes(s.memoryUsed)) / \(Format.bytes(s.memoryTotal)) · 压力\(s.pressure)", openSettings: openPage)
            // 30–110 °C fills the arc; red from 90 °C.
            RingGauge(label: "温度", value: Format.number(temperature, suffix: "°"), fraction: temperature.map { ($0 - 30) / 80 },
                      color: (temperature ?? 0) >= 90 ? .red : .orange)
                .jump(.settings("sensors"), detail: "CPU 最高温度 \(Format.number(temperature, suffix: " °C", decimals: 1)) · \(s.thermal)", openSettings: openPage)
        }
        if !s.fans.isEmpty {
            FanUnit(fan: monitor.fan, readings: s.fans, openPage: openPage)
        }
        metricTiles
        Divider()
        processSection
    }
    /// Network, power and disk as three equal cards: label, reading, then a curve or a usage bar.
    private var metricTiles: some View {
        let down = monitor.history.map { ($0.date, Optional($0.download)) }
        let up = monitor.history.map { ($0.date, Optional($0.upload)) }
        // Both directions share one scale so the curves compare honestly.
        let peak = max(1, (monitor.history.map { max($0.download, $0.upload) }.max() ?? 1) * 1.15)
        let downRate = monitor.networkAvailable ? monitor.networkRates.0 : nil
        let upRate = monitor.networkAvailable ? monitor.networkRates.1 : nil
        return HStack(spacing: 8) {
            // Every card has the same rows: title, one 16 pt reading, one 11 pt line, then a curve or bar.
            tile("网络", "network",
                 primary: Text(Image(systemName: "arrow.down")).font(.system(size: 12, weight: .bold)).foregroundColor(.green) + Text(" " + MenuMetric.compactRate(downRate, bits: false)),
                 secondary: Text(Image(systemName: "arrow.up")).font(.system(size: 9, weight: .bold)).foregroundColor(.blue) + Text(" " + MenuMetric.compactRate(upRate, bits: false))) {
                ZStack {
                    Sparkline(values: down, color: .green, fixedMax: peak)
                    Sparkline(values: up, color: .blue, fixedMax: peak)
                }
            }
            .jump(.activityMonitor(.network), detail: "网络（\(monitor.networkLabel)）：下载 \(Format.rate(monitor.networkRates.0))，上传 \(Format.rate(monitor.networkRates.1))",
                  highlight: .card, openSettings: openPage)
            tile("功耗", "bolt",
                 primary: Text(Format.number(s.watts, suffix: " W", decimals: 1)),
                 secondary: Text("本次 \(Format.number(monitor.energyWh, decimals: 2)) Wh")) {
                Sparkline(values: monitor.history.map { ($0.date, $0.watts) }, color: .orange)
            }
            .jump(.activityMonitor(.energy), detail: "系统功耗 \(Format.number(s.watts, suffix: " W", decimals: 1))", highlight: .card, openSettings: openPage)
            tile("磁盘可用", "internaldrive",
                 primary: Text(s.diskTotal > 0 ? Format.bytes(s.diskFree) : "—"),
                 secondary: Text(s.diskTotal > 0 ? "共 \(Format.bytes(s.diskTotal))" : " ")) {
                UsageBar(fraction: s.diskTotal > 0 ? 1 - s.diskFree / s.diskTotal : 0, color: .blue)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .jump(.diskUtility, detail: "磁盘可用 \(Format.bytes(s.diskFree)) / \(Format.bytes(s.diskTotal))", highlight: .card, openSettings: openPage)
        }
    }
    private func tile<Footer: View>(_ title: String, _ symbol: String, primary: Text, secondary: Text, @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // A fixed icon box keeps the three titles on one line whatever the symbol's height.
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10)).frame(width: 12, height: 12)
                Text(title)
            }.font(PanelFont.label).foregroundStyle(.secondary).frame(height: 14)
            // Fixed line boxes, so every card's reading and sub-line sit on the same baselines.
            primary.font(PanelFont.tile).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                .frame(height: 24, alignment: .bottomLeading).padding(.top, 4)
            secondary.font(PanelFont.label).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                .frame(height: 16, alignment: .leading)
            Spacer(minLength: 0)
            footer().frame(height: 18)
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 98, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
    private func openMouseSettings() { monitor.aiUsage.preferencesTab = "mouse"; openSettings() }
    /// Opens a MacPulse settings page by its sidebar id.
    private func openPage(_ page: String) { monitor.aiUsage.preferencesTab = page; openSettings() }
    private var batteryHelp: String {
        guard s.batteryPercent != nil else { return "" }
        var lines = ["电量 \(Format.number(s.batteryPercent, suffix: "%"))" + (s.charging ? "，正在充电" : "")]
        if let capacity = s.batteryCapacity { lines.append("最大容量 \(Format.number(s.batteryHealth, suffix: "%"))（\(Format.number(capacity.full)) / \(Format.number(capacity.design)) mAh）") }
        if let cycles = s.batteryCycles { lines.append("循环次数 \(cycles)" + (s.batteryDesignCycles.map { " / 设计 \($0)" } ?? "")) }
        return lines.joined(separator: "\n")
    }
    static func sortedProcesses(_ list: [ProcessUsage], by key: String) -> [ProcessUsage] {
        key == "memory" ? list.sorted { $0.memory > $1.memory } : list.filter { $0.cpu != nil }.sorted { $0.cpu! > $1.cpu! }
    }
    private var processSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("进程").font(PanelFont.heading)
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
                }.buttonStyle(.borderless).foregroundStyle(.secondary).help("打开活动监视器").accessibilityLabel("打开活动监视器")
                Spacer()
                Picker("进程排序", selection: $processSort) { Text("CPU").tag("cpu"); Text("内存").tag("memory") }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(width: 96)
            }
            let top = Self.sortedProcesses(s.processes, by: processSort).prefix(3)
            if top.isEmpty {
                Text("正在采集…").font(PanelFont.label).foregroundStyle(.secondary).frame(height: 18)
            }
            ForEach(Array(top)) { process in
                HStack(spacing: 6) {
                    Text(process.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    // The sorted column stays primary; the other one steps back.
                    Text(Format.number(process.cpu, suffix: "%", decimals: 1)).frame(width: 50, alignment: .trailing)
                        .foregroundStyle(processSort == "cpu" ? Color.primary : Color.secondary)
                    Text(Format.bytes(process.memory)).frame(width: 68, alignment: .trailing)
                        .foregroundStyle(processSort == "memory" ? Color.primary : Color.secondary)
                }.font(PanelFont.row).monospacedDigit().frame(height: 19)
                    .jump(.activityMonitor(processSort == "memory" ? .memory : .cpu),
                          detail: "\(process.name)（PID \(process.pid)）：CPU \(Format.number(process.cpu, suffix: "%", decimals: 1))，内存 \(Format.bytes(process.memory))",
                          highlight: .halo(horizontal: 8, vertical: 3), openSettings: openPage)
            }
        }
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Text("已运行 \(Format.uptime(s.uptime))").lineLimit(1)
                .help("每 \(Format.number(monitor.interval, decimals: monitor.interval < 1 ? 1 : 0)) 秒刷新一次")
            if let battery = s.batteryPercent {
                HStack(spacing: 2) {
                    Image(systemName: s.charging ? "battery.100percent.bolt" : "battery.100percent")
                    Text(Format.number(battery, suffix: "%")).monospacedDigit()
                }.jump(.batterySettings, detail: batteryHelp, openSettings: openPage)
            }
            if !s.smcAvailable { Image(systemName: "exclamationmark.triangle").help("部分传感器不可用") }
            UpdateBadge(updater: monitor.updater) { monitor.aiUsage.preferencesTab = "general"; openSettings() }
            Spacer()
            Text(s.date, style: .time).monospacedDigit()
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).padding(.leading, 6).help("打开设置窗口").accessibilityLabel("打开设置窗口")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).padding(.leading, 6).help("退出 MacPulse").accessibilityLabel("退出 MacPulse")
        }.font(PanelFont.label).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

/// Panel page for mice and other accessories: battery, connection and the mouse's current settings.
struct DevicesPanelPage: View {
    let peripherals: [PeripheralBattery]
    let history: [String: [BatteryPoint]]
    @ObservedObject var mice: MouseCenter
    var open: () -> Void
    /// Battery polling and the settings read both report WLMOUSE batteries; whichever arrived first is shown.
    private var items: [PeripheralBattery] {
        var list = peripherals
        for state in mice.wl where !list.contains(where: { $0.key == WLMouseModel.batteryKey(productID: state.id) }) {
            guard let battery = state.battery else { continue }
            list.append(PeripheralBattery(key: WLMouseModel.batteryKey(productID: state.id), name: state.name, percent: Double(battery.percent),
                                          charging: battery.charging, updated: Date(), source: "WLMOUSE 接收器"))
        }
        return list
    }
    var body: some View {
        let items = items
        VStack(alignment: .leading, spacing: 10) {
            ForEach(mice.asleep.filter { name in !items.contains { $0.name.hasSuffix(name) } }, id: \.self) { name in
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(PanelFont.heading)
                        Text("正在休眠，动一下鼠标即可").font(PanelFont.label).foregroundStyle(.secondary)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            if items.isEmpty && mice.asleep.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "computermouse").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("没有检测到无线外设").font(PanelFont.value)
                    Text("支持 WLMOUSE、罗技 HID++ 鼠标，以及向系统报告电量的蓝牙外设。").font(PanelFont.label)
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.top, 40)
            }
            ForEach(items) { device in card(device) }
            Button(action: open) { Label("鼠标设置与支持的设备", systemImage: "slider.horizontal.3") }
                .buttonStyle(.borderless).font(PanelFont.label)
        }
        .onAppear { mice.refreshIfStale(60) }
        .onReceive(DeviceIO.retryTick) { _ in
            if !mice.asleep.isEmpty { mice.refreshIfStale(0) }
        }
    }
    private func card(_ device: PeripheralBattery) -> some View {
        let low = device.percent <= 15 && !device.charging
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: device.symbol).font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(PanelFont.heading).lineLimit(1).truncationMode(.middle)
                    Text(subtitle(device)).font(PanelFont.label).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 2) {
                    if device.charging { Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(.green) }
                    Text(Format.number(device.percent, suffix: "%")).font(PanelFont.hero).monospacedDigit()
                        .foregroundStyle(low ? Color.orange : Color.primary)
                }
            }
            UsageBar(fraction: device.percent / 100, color: low ? .orange : .green, warnAbove: nil)
            let points = history[device.key] ?? []
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("近 7 天").font(PanelFont.label).foregroundStyle(.secondary)
                    Spacer()
                    Text(estimate(points, device)).font(PanelFont.label).foregroundStyle(.secondary)
                }
                BatteryHistoryChart(points: points).frame(height: 34)
            }
            if let state = wlState(device), state.settings.profileCount > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("配置").font(PanelFont.label).foregroundStyle(.secondary)
                    Picker("配置", selection: Binding(get: { state.settings.profile }, set: { profile in
                        var next = state.settings; next.profile = profile
                        mice.apply(state.id, next)
                    })) {
                        ForEach(1...state.settings.profileCount, id: \.self) { Text(state.settings.profileLabel($0)).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().disabled(mice.busy)
                        .help("切换鼠标上的配置；每套配置有自己的 DPI、回报率等设置")
                }
            }
            let facts = details(device)
            if !facts.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(facts, id: \.0) { fact in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fact.0).font(PanelFont.label).foregroundStyle(.secondary)
                            Text(fact.1).font(PanelFont.value).monospacedDigit().lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .contentShape(Rectangle()).onTapGesture(perform: open)
        .help("点击打开鼠标设置")
    }
    private func wlState(_ device: PeripheralBattery) -> MouseCenter.WLState? {
        mice.wlState(forKey: device.key)
    }
    private func estimate(_ points: [BatteryPoint], _ device: PeripheralBattery) -> String {
        if device.charging { return "充电中" }
        guard let days = BatteryHistory.daysLeft(points) else { return "预计续航：数据积累中" }
        return days >= 1 ? "预计还能用 \(Int(days.rounded())) 天" : "预计还能用 \(max(1, Int((days * 24).rounded()))) 小时"
    }
    private func subtitle(_ device: PeripheralBattery) -> String {
        var parts = [device.key.hasPrefix("wl-") ? "WLMOUSE" : device.key.hasPrefix("logi-") ? "罗技" : "蓝牙"]
        if let state = mice.wlState(forKey: device.key) { parts.append(state.connection) }
        if device.charging { parts.append("充电中") }
        if device.stale { parts.append(device.updated.formatted(date: .omitted, time: .shortened) + " 的读数") }
        return parts.joined(separator: " · ")
    }
    private func details(_ device: PeripheralBattery) -> [(String, String)] {
        if let state = mice.wlState(forKey: device.key) {
            let s = state.settings
            let dpi = s.stages.indices.contains(s.activeStage - 1) ? "\(s.stages[s.activeStage - 1])" : "—"
            return [("当前 DPI", dpi + "（第 \(s.activeStage) / \(s.stages.count) 档）"), ("回报率", String(s.pollingRate) + " Hz"),
                    ("静默高度", String(format: "%g mm", s.lod)),
                    ("高速 / 竞技", (s.hyperMode ? "开" : "关") + " / " + (s.trackingMode ? "开" : "关")),
                    ("休眠", MouseSettingsView.sleepLabel(s.sleepSeconds))]
        }
        if device.key.hasPrefix("logi-"), let state = mice.logi.first(where: { "logi-" + $0.id == device.key }) {
            var facts: [(String, String)] = []
            if let dpi = state.dpi { facts.append(("DPI", String(dpi))) }
            if let shift = state.smartShift {
                facts.append(("滚轮", shift.wheelMode == 1 ? "自由" : "段落"))
                facts.append(("SmartShift", shift.autoDisengage == 255 ? "关" : "开"))
            }
            if let inverted = state.inverted { facts.append(("滚轮方向", inverted ? "反向" : "标准")) }
            return facts
        }
        return []
    }
}

/// Seven days of battery percent, 0–100 %, charging stretches tinted green.
struct BatteryHistoryChart: View {
    let points: [BatteryPoint]
    var body: some View {
        Canvas { context, size in
            let end = Date(), span: TimeInterval = 7 * 86_400
            for fraction in [0.0, 0.5, 1.0] {
                var grid = Path(); let y = size.height * (1 - fraction)
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            }
            let visible = points.filter { end.timeIntervalSince($0.date) <= span }
            guard visible.count > 1 else {
                context.draw(Text("从现在开始记录，每 10 分钟一个点").font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            func point(_ p: BatteryPoint) -> CGPoint {
                CGPoint(x: size.width * (1 - end.timeIntervalSince(p.date) / span), y: size.height * (1 - p.percent / 100))
            }
            var line = Path(); line.addLines(visible.map(point))
            var area = line
            area.addLine(to: CGPoint(x: point(visible.last!).x, y: size.height)); area.addLine(to: CGPoint(x: point(visible[0]).x, y: size.height)); area.closeSubpath()
            context.fill(area, with: .color(.green.opacity(0.15)))
            context.stroke(line, with: .color(.green), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }.accessibilityLabel("近 7 天电量变化")
    }
}

/// A full ring that fills clockwise from the top, with the reading in the middle and its name below.
struct RingGauge: View {
    let label: String
    let value: String
    let fraction: Double?
    let color: Color
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 6)
                if let fraction, fraction > 0 {
                    Circle().trim(from: 0, to: min(1, fraction))
                        .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7).frame(width: 42)
            }.frame(width: 56, height: 56)
            Text(label).font(PanelFont.label).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(label) \(value)")
    }
}

/// The panel's fan block: one speed bar per fan on the left, up to four preset buttons on the right.
struct FanUnit: View {
    @ObservedObject var fan: FanController
    let readings: [FanReading]
    var openPage: (String) -> Void
    private func openSettings() { openPage("fan") }
    private var detail: String {
        readings.enumerated().map { index, reading in
            "\(fan.settings.fanName(index)) \(Int(reading.rpm.rounded())) RPM（\(Int(reading.min))–\(Int(reading.max))）"
        }.joined(separator: "\n")
    }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: readings.count > 2 ? 5 : 8) {
                Label(fan.activeLabel, systemImage: "fan").font(PanelFont.label).lineLimit(1)
                    .foregroundStyle(fan.safetyOverride ? Color.orange : fan.settings.enabled ? Color.accentColor : Color.secondary)
                ForEach(Array(readings.enumerated()), id: \.offset) { index, reading in
                    FanSpeedRow(name: fan.settings.fanName(index), reading: reading, large: readings.count == 1)
                }
            }
            .frame(width: 124, alignment: .leading).frame(maxHeight: .infinity)
            .jump(.settings("fan"), detail: detail, openSettings: openPage)
            if fan.settings.enabled {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(fan.panelButtons, id: \.id) { preset in
                        let selected = fan.settings.preset == preset.id
                        Button { fan.select(preset.id) } label: {
                            VStack(spacing: 3) {
                                Image(systemName: preset.symbol).font(.system(size: 14))
                                Text(preset.name).font(.system(size: 11, weight: selected ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .foregroundStyle(selected ? Color.accentColor : Color.primary)
                            .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.2))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).help("切换到“\(preset.name)”").accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("风扇由系统控制").font(PanelFont.value)
                    Text("开启风扇控制后，可在这里一键切换预设").font(PanelFont.label).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("启用风扇控制…", action: openSettings).font(PanelFont.label)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

/// One fan in the panel: its name and speed on a line, a bar for where that speed sits in the fan's range.
struct FanSpeedRow: View {
    let name: String
    let reading: FanReading
    var large = false
    var body: some View {
        VStack(alignment: .leading, spacing: large ? 5 : 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(String(Int(reading.rpm.rounded()))).font(.system(size: large ? 20 : 13, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("RPM").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(Color.cyan).frame(width: max(proxy.size.height, proxy.size.width * reading.fraction))
                        .opacity(reading.rpm > 0 ? 1 : 0)
                }
            }.frame(height: large ? 7 : 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(Int(reading.rpm.rounded())) RPM")
    }
}
