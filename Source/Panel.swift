import SwiftUI
import AppKit
import ServiceManagement

// Keep the property wrapper available when building with Command Line Tools.
private typealias ViewState<Value> = SwiftUI.State<Value>

enum PanelLayout {
    static let width: CGFloat = 300
    static let height: CGFloat = 780
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
            var path = Path()
            var connected = false
            for (date, value) in values {
                guard let value, value.isFinite else { connected = false; continue }
                let x = size.width * max(0, min(1, (date.timeIntervalSince(end) + 120) / 120))
                let y = size.height - 1 - min(1, max(0, value / maximum)) * (size.height - 2)
                let point = CGPoint(x: x, y: y)
                if connected { path.addLine(to: point) } else { path.move(to: point); connected = true }
            }
            context.stroke(path, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
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
    var condensed = false
    var body: some View {
        VStack(alignment: .leading, spacing: condensed ? 1 : 3) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .regular)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
            Sparkline(values: values, fixedMax: max).frame(height: condensed ? 8 : 14)
            Text(note).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.85).help(note)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
    @ViewState private var showAIOnly = false
    @ViewState private var processSort = "cpu"
    var height: CGFloat = PanelLayout.height
    var dismiss: () -> Void = {}
    var openSettings: () -> Void = {}
    init(monitor: Monitor, height: CGFloat = PanelLayout.height, dismiss: @escaping () -> Void = {}, openSettings: @escaping () -> Void = {}) {
        self.monitor = monitor
        self.height = height
        self.dismiss = dismiss
        self.openSettings = openSettings
    }
    private var s: Sample { monitor.sample }
    private var sectionGap: CGFloat { 5 }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: sectionGap) {
                if height >= PanelLayout.height || !showAIOnly { overview }
                if height >= PanelLayout.height { Divider() }
                if height >= PanelLayout.height || showAIOnly { AIUsagePanel(usage: monitor.aiUsage, openSettings: openSettings) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
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
                    .font(.caption).foregroundStyle(.secondary)
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
            .padding(.horizontal, 12).padding(.vertical, 8)
    }
    @ViewBuilder private var overview: some View {
        HStack(alignment: .top, spacing: 12) {
            CompactMetric(title: "系统功耗", value: Format.number(s.watts, suffix: " W", decimals: 1),
                          note: "本次 \(Format.number(monitor.energyWh, decimals: 2)) Wh",
                          values: monitor.history.map { ($0.date, $0.watts) }, condensed: true)
            CompactMetric(title: "CPU 温度", value: Format.number(s.cpuTemp, suffix: " °C", decimals: 1),
                          note: "最高值 · \(s.thermal)",
                          values: monitor.history.map { ($0.date, $0.temperature) }, max: 110, condensed: true)
        }
        HStack(alignment: .top, spacing: 12) {
            CompactMetric(title: "CPU", value: Format.number(s.cpu, suffix: "%", decimals: 1),
                          note: "用户 \(Format.number(s.cpuUser))% · 系统 \(Format.number(s.cpuSystem))%",
                          values: monitor.history.map { ($0.date, $0.cpu) }, max: 100, condensed: true)
            CompactMetric(title: "GPU", value: Format.number(s.gpu, suffix: "%"),
                          note: "温度 \(Format.number(s.gpuTemp, suffix: " °C", decimals: 1))",
                          values: monitor.history.map { ($0.date, $0.gpu) }, max: 100, condensed: true)
        }
        Divider()
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("网络").font(.callout.weight(.medium))
                Text(monitor.networkLabel).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).help(monitor.networkLabel)
                networkMetric("↓ 下载", value: monitor.networkAvailable ? monitor.networkRates.0 : nil,
                              values: monitor.history.map { ($0.date, $0.download) })
                networkMetric("↑ 上传", value: monitor.networkAvailable ? monitor.networkRates.1 : nil,
                              values: monitor.history.map { ($0.date, $0.upload) })
                let first = monitor.networks.first(where: { !$0.address.isEmpty })
                informationCell(first.map { "\($0.name) · IP" } ?? "IP", first?.address ?? "—")
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                Text("内存与磁盘").font(.callout.weight(.medium))
                informationCell("内存已用 / 总量", s.memoryValid ? "\(Format.bytes(s.memoryUsed)) / \(Format.bytes(s.memoryTotal))" : "—")
                informationCell("压力 / 交换", "\(s.pressure) / \(Format.bytes(s.swap))", warning: s.pressure == "紧张")
                informationCell("磁盘可用", s.diskTotal > 0 ? Format.bytes(s.diskFree) : "—")
                VStack(alignment: .leading, spacing: 3) {
                    diskMetric("读", value: s.diskRead)
                    diskMetric("写", value: s.diskWrite)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        Divider()
        VStack(spacing: 4) {
            let fans = s.sensors.filter { $0.kind == "RPM" }
            summaryRow("风扇", fans.isEmpty ? "—" : fans.map { Format.number($0.value) }.joined(separator: " / ") + " RPM")
                .help(fans.map { "\($0.name)：\(Format.number($0.value)) RPM" }.joined(separator: "\n"))
            summaryRow("负载", s.load.map { Format.number($0, decimals: 2) }.joined(separator: " / "))
                .help("最近 1 / 5 / 15 分钟的系统负载")
            if s.cpuPower != nil {
                summaryRow("芯片功耗", "CPU \(Format.number(s.cpuPower, suffix: " W", decimals: 2)) · GPU \(Format.number(s.gpuPower, suffix: " W", decimals: 2)) · ANE \(Format.number(s.anePower, suffix: " W", decimals: 2))")
                    .help("CPU、GPU 与神经网络引擎的分项功耗（AppleCLPC 能耗计数器），已包含在系统功耗中")
            }
            HStack(spacing: 4) {
                Text("已运行 \(Format.uptime(s.uptime))").lineLimit(1)
                Spacer(minLength: 4)
                if let battery = s.batteryPercent {
                    Image(systemName: s.charging ? "battery.100percent.bolt" : "battery.100percent")
                    Text(Format.number(battery, suffix: "%") + (s.batteryHealth.map { " · 健康 " + Format.number($0, suffix: "%") } ?? "")
                         + (s.batteryCycles.map { " · \($0) 次" } ?? "")).monospacedDigit().lineLimit(1)
                }
            }.font(.caption).foregroundStyle(.secondary).frame(height: 16).help(batteryHelp)
            HStack(spacing: 3) {
                ForEach(Array(s.cores.enumerated()), id: \.offset) { i, value in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor.opacity(0.65))
                            .frame(height: max(2, 12 * value / 100))
                    }.frame(maxWidth: .infinity).frame(height: 12)
                        .help("核心 \(i + 1)：\(Format.number(value, suffix: "%"))")
                }
            }.frame(height: 12).accessibilityLabel("各逻辑核心负载")
        }
        Divider()
        processSection
    }
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("进程").font(.callout.weight(.medium))
                Spacer()
                Picker("进程排序", selection: $processSort) { Text("CPU").tag("cpu"); Text("内存").tag("memory") }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(width: 96)
            }
            let top = Self.sortedProcesses(s.processes, by: processSort).prefix(3)
            if top.isEmpty {
                Text("正在采集…").font(.caption).foregroundStyle(.secondary).frame(height: 14)
            }
            ForEach(Array(top)) { process in
                HStack(spacing: 6) {
                    Text(process.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(Format.number(process.cpu, suffix: "%", decimals: 1)).frame(width: 46, alignment: .trailing)
                    Text(Format.bytes(process.memory)).frame(width: 62, alignment: .trailing)
                }.font(.caption).monospacedDigit().frame(height: 14)
                    .help("\(process.name)（PID \(process.pid)）：CPU \(Format.number(process.cpu, suffix: "%", decimals: 1))，内存 \(Format.bytes(process.memory))")
            }
        }
    }
    private func summaryRow(_ title: String, _ value: String, warning: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary).fixedSize()
            Text(value).monospacedDigit().lineLimit(1).truncationMode(.middle)
                .foregroundStyle(warning ? Color.orange : Color.primary)
            Spacer(minLength: 0)
        }.font(.caption).frame(height: 16).help("\(title)：\(value)")
    }
    private func informationCell(_ title: String, _ value: String, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.9).truncationMode(.middle)
                .foregroundStyle(warning ? Color.orange : Color.primary)
        }.frame(maxWidth: .infinity, alignment: .leading).help("\(title)：\(value)")
    }
    private func diskMetric(_ title: String, value: Double?) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(Format.rate(value)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).frame(height: 16)
    }
    private func networkMetric(_ title: String, value: Double?, values: [(Date, Double?)]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Format.rate(value)).font(.system(size: 14)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.85)
            Sparkline(values: values).frame(height: 8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Text("\(Format.number(monitor.interval, decimals: monitor.interval < 1 ? 1 : 0)) 秒刷新")
            if !s.smcAvailable { Image(systemName: "exclamationmark.triangle").help("部分传感器不可用") }
            if height < PanelLayout.height {
                Button(showAIOnly ? "总览" : "AI 用量") { showAIOnly.toggle() }.buttonStyle(.borderless)
            }
            UpdateBadge(updater: monitor.updater) { monitor.aiUsage.preferencesTab = "general"; openSettings() }
            Spacer()
            Text(s.date, style: .time).monospacedDigit()
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).padding(.leading, 6).help("打开设置窗口").accessibilityLabel("打开设置窗口")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).padding(.leading, 6).help("退出 MacPulse").accessibilityLabel("退出 MacPulse")
        }.font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 9)
    }
}
