import SwiftUI
import AppKit
import ServiceManagement

// Keep the property wrapper available when building with Command Line Tools.
private typealias ViewState<Value> = SwiftUI.State<Value>

enum PanelLayout {
    static let width: CGFloat = 356
    static let height: CGFloat = 750
    static var cornerRadius: CGFloat { GlassPanel.cornerRadius }
    /// Side margin of every page; wide enough to hold a scroller without moving the content.
    static let gutter: CGFloat = 20
    /// The panel's glass. "system" is plain regular glass, which follows the system's Liquid Glass setting;
    /// "custom" goes from clear glass at 0 to a strong tint at 1.
    static func glass(mode: String, tint: Double, dark: Bool) -> Glass {
        guard mode == "custom" else { return .regular }
        guard tint > 0.02 else { return .clear }
        return .regular.tint(dark ? Color.black.opacity(0.65 * tint) : Color.white.opacity(0.8 * tint))
    }
}

/// One type scale for the panel, so labels, values and headings read as distinct levels.
enum PanelFont {
    static let heading = Font.system(size: 13, weight: .semibold)
    static let label = Font.system(size: 11)
    static let hero = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let value = Font.system(size: 13, weight: .medium)
    static let tile = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let row = Font.system(size: 12)
}

/// The four data colors of the app icon: CPU, GPU, memory, temperature.
enum LogoPalette {
    static let all = [Color(red: 0.04, green: 0.45, blue: 1.0), Color(red: 0.62, green: 0.22, blue: 0.95),
                      Color(red: 0.13, green: 0.72, blue: 0.33), Color(red: 1.0, green: 0.55, blue: 0.0)]
}

/// The app icon's four rings, flat, on its 100-unit grid.
struct LogoRings: View {
    let dark: Bool
    var body: some View {
        Canvas { context, canvas in
            let k = canvas.width / 100
            let rings: [(CGFloat, CGFloat, Double)] = [(31, 31, 0.7), (69, 31, 0.55), (31, 69, 0.8), (69, 69, 0.45)]
            for (i, ring) in rings.enumerated() {
                let center = CGPoint(x: ring.0 * k, y: ring.1 * k)
                var track = Path(); track.addArc(center: center, radius: 12 * k, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                context.stroke(track, with: .color(dark ? .white.opacity(0.17) : .black.opacity(0.13)), lineWidth: 9 * k)
                var arc = Path(); arc.addArc(center: center, radius: 12 * k, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * ring.2), clockwise: false)
                context.stroke(arc, with: .color(LogoPalette.all[i]), style: StrokeStyle(lineWidth: 9 * k, lineCap: .round))
            }
        }.accessibilityHidden(true)
    }
}

/// The four rings in one ink, as the menu bar draws them.
struct LogoGlyph: View {
    var body: some View {
        Canvas { context, canvas in
            let k = canvas.width / 100
            for (cx, cy, fill) in [(31.0, 31.0, 0.7), (69.0, 31.0, 0.55), (31.0, 69.0, 0.8), (69.0, 69.0, 0.45)] {
                let center = CGPoint(x: cx * k, y: cy * k)
                var track = Path(); track.addArc(center: center, radius: 12 * k, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                context.stroke(track, with: .color(.primary.opacity(0.35)), lineWidth: 10 * k)
                var arc = Path(); arc.addArc(center: center, radius: 12 * k, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fill), clockwise: false)
                context.stroke(arc, with: .color(.primary), style: StrokeStyle(lineWidth: 10 * k, lineCap: .round))
            }
        }.accessibilityHidden(true)
    }
}

/// The app icon drawn live: glow below, one glass slab, the flat rings on top.
struct AppLogo: View {
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        let tile = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        ZStack {
            tile.fill(dark ? Color(white: 0.12) : Color(white: 0.97))
            LogoRings(dark: dark).blur(radius: size * 0.04).opacity(0.35)
            LogoRings(dark: dark).padding(size * 0.015)
                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: size * 0.21, style: .continuous))
        }
        .frame(width: size, height: size)
        .clipShape(tile)
    }
}

/// A plain symbol button for the footer strip; the strip itself is the glass.
struct FooterButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @ViewState private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help(help).accessibilityLabel(help)
    }
}

/// A small round glass button for panel chrome (pin, close, settings, quit).
struct PanelIconButton: View {
    let symbol: String
    let help: String
    var prominent = false
    /// Inside the scrolling page rather than in the header.
    var inPage = false
    let action: () -> Void
    var body: some View {
        Group {
            if inPage {
                Button(action: action) { Image(systemName: symbol).frame(width: 28, height: 28).contentShape(Circle()) }
                    .buttonStyle(.plain).pageGlass(Circle())
            } else if prominent {
                Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 24) }.buttonStyle(.glassProminent)
            } else {
                Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 24) }.buttonStyle(.glass)
            }
        }
        .buttonBorderShape(.circle).controlSize(.small)
        .help(help).accessibilityLabel(help)
    }
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
    @ViewState private var processSort = UserDefaults.standard.string(forKey: "panel.processSort") == "memory" ? "memory" : "cpu"
    @ViewState private var page: String
    var height: CGFloat = PanelLayout.height
    var dismiss: () -> Void = {}
    var openSettings: () -> Void = {}
    static let pages: [(String, String)] = [("system", "系统"), ("devices", "外设"), ("ai", "AI 用量")]
    init(monitor: Monitor, height: CGFloat = PanelLayout.height, page: String? = nil, dismiss: @escaping () -> Void = {}, openSettings: @escaping () -> Void = {}) {
        self.monitor = monitor
        self.height = height
        self.dismiss = dismiss
        self.openSettings = openSettings
        // The last page reopens; it is a per-Mac convenience only.
        let saved = page ?? UserDefaults.standard.string(forKey: "panel.page") ?? "system"
        _page = ViewState(initialValue: Self.pages.contains { $0.0 == saved } ? saved : "system")
    }
    @Environment(\.colorScheme) private var scheme
    private var s: Sample { monitor.sample }
    private var sectionGap: CGFloat { 16 }
    var body: some View {
        // Content that outgrows the page (several devices, a short screen) scrolls under the header and footer bars,
        // which fade it out with the scroll edge effect. Glass inside the page is not clipped by a scroll view's
        // edges, so it has to pass under a bar rather than stop at a hard edge beside one.
        PanelScroll(margin: PanelLayout.gutter) {
                VStack(alignment: .leading, spacing: sectionGap) {
                    switch page {
                    case "devices": DevicesPanelPage(peripherals: monitor.peripherals, history: monitor.batteryHistory, mice: monitor.mice, keyboards: monitor.keyboards, open: openMouseSettings)
                    case "ai": AIUsagePanel(usage: monitor.aiUsage, openSettings: openSettings)
                    default: overview
                    }
                }
                .padding(.top, 4).padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        // The page fades out under the header, so nothing reads beside the logo; the tabs still show it through their glass.
        .mask {
            // Measured from the panel's top edge, not from below the header.
            VStack(spacing: 0) {
                Color.clear.frame(height: 50)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 60)
                Color.black
            }.ignoresSafeArea()
        }
        // No backing behind the bars: the page shows through the footer's glass with a light blur.
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .safeAreaBar(edge: .top) {
            VStack(spacing: 0) {
                header
                GlassTabs(items: Self.pages, selection: Binding(get: { page }, set: { page = $0; UserDefaults.standard.set($0, forKey: "panel.page") }))
                    .padding(.horizontal, PanelLayout.gutter).padding(.bottom, 14)
            }
        }
        .safeAreaBar(edge: .bottom) { footer }
        .font(.callout)
        .frame(width: PanelLayout.width, height: height)
        // The page scrolls under the bars but never past the panel's own edge.
        .clipShape(RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous))
        .foregroundStyle(.primary)
        // One glass surface for the whole panel, as clear or tinted as set in Settings → General.
        .glassEffect(PanelLayout.glass(mode: monitor.glassMode, tint: monitor.glassTint, dark: scheme == .dark),
                     in: RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous))
    }
    private var header: some View {
        HStack(spacing: 10) {
            AppLogo(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("MacPulse").font(.system(size: 14, weight: .semibold))
                Text(monitor.chip)
                    .font(PanelFont.label).foregroundStyle(.secondary)
            }
            Spacer()
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    PanelIconButton(symbol: monitor.pinned ? "pin.fill" : "pin", help: monitor.pinned ? "取消固定面板" : "固定面板",
                                    prominent: monitor.pinned) { monitor.pinned.toggle() }
                    PanelIconButton(symbol: "xmark", help: "关闭面板", action: dismiss)
                }
            }
        }
        .padding(.horizontal, PanelLayout.gutter).padding(.top, 16).padding(.bottom, 12)
    }
    @ViewBuilder private var overview: some View {
        let temperature = s.cpuTemp
        HStack(spacing: 0) {
            RingGauge(label: "CPU", value: Format.number(s.cpu, suffix: "%"), fraction: s.cpu.map { $0 / 100 }, color: LogoPalette.all[0])
                .jump(.activityMonitor(.cpu), detail: "CPU \(Format.number(s.cpu, suffix: "%", decimals: 1))：用户 \(Format.number(s.cpuUser))% · 系统 \(Format.number(s.cpuSystem))%", highlight: .tile, openSettings: openPage)
                .frame(maxWidth: .infinity)
            // Activity Monitor's CPU tab can show a % GPU column per process.
            RingGauge(label: "GPU", value: Format.number(s.gpu, suffix: "%"), fraction: s.gpu.map { $0 / 100 }, color: LogoPalette.all[1])
                .jump(.activityMonitor(.cpu), detail: "GPU \(Format.number(s.gpu, suffix: "%")) · 温度 \(Format.number(s.gpuTemp, suffix: " °C", decimals: 1))", highlight: .tile, openSettings: openPage)
                .frame(maxWidth: .infinity)
            RingGauge(label: "内存", value: s.memoryValid && s.memoryTotal > 0 ? Format.number(s.memoryUsed / s.memoryTotal * 100, suffix: "%") : "—",
                      fraction: s.memoryValid && s.memoryTotal > 0 ? s.memoryUsed / s.memoryTotal : nil, color: s.pressure == "紧张" ? .orange : LogoPalette.all[2])
                .jump(.activityMonitor(.memory), detail: "内存 \(Format.bytes(s.memoryUsed)) / \(Format.bytes(s.memoryTotal)) · 压力\(s.pressure)", highlight: .tile, openSettings: openPage)
                .frame(maxWidth: .infinity)
            // 30–110 °C fills the arc; red from 90 °C.
            RingGauge(label: "温度", value: Format.number(temperature, suffix: "°"), fraction: temperature.map { ($0 - 30) / 80 },
                      color: (temperature ?? 0) >= 90 ? .red : LogoPalette.all[3])
                .jump(.settings("sensors"), detail: "CPU 最高温度 \(Format.number(temperature, suffix: " °C", decimals: 1)) · \(s.thermal)", highlight: .tile, openSettings: openPage)
                .frame(maxWidth: .infinity)
        }
        if !s.fans.isEmpty {
            FanUnit(fan: monitor.fan, readings: s.fans, openPage: openPage)
        }
        metricTiles
        diskCard
        processSection
    }
    /// Network and power as two cards side by side: label, reading, one more line, then a curve.
    private var metricTiles: some View {
        let down = monitor.history.map { ($0.date, Optional($0.download)) }
        let up = monitor.history.map { ($0.date, Optional($0.upload)) }
        // Both directions share one scale so the curves compare honestly.
        let peak = max(1, (monitor.history.map { max($0.download, $0.upload) }.max() ?? 1) * 1.15)
        let downRate = monitor.networkAvailable ? monitor.networkRates.0 : nil
        let upRate = monitor.networkAvailable ? monitor.networkRates.1 : nil
        return HStack(alignment: .top, spacing: 10) {
            tile("网络", "network",
                 primary: Text("\(Text(Image(systemName: "arrow.down")).font(.system(size: 12, weight: .bold)).foregroundColor(.green)) \(MenuMetric.compactRate(downRate, bits: false))"),
                 secondary: Text("\(Text(Image(systemName: "arrow.up")).font(.system(size: 9, weight: .bold)).foregroundColor(.blue)) \(MenuMetric.compactRate(upRate, bits: false))")) {
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
        }
    }
    private func tile<Footer: View>(_ title: String, _ symbol: String, primary: Text, secondary: Text, @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // A fixed icon box keeps both titles on one line whatever the symbol's height.
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10)).frame(width: 12, height: 12)
                Text(title)
            }.font(PanelFont.label).foregroundStyle(.secondary).frame(height: 14)
            // Fixed line boxes, so both cards' reading and sub-line sit on the same baselines.
            primary.font(PanelFont.tile).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                .frame(height: 24, alignment: .bottomLeading).padding(.top, 3)
            secondary.font(PanelFont.label).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                .frame(height: 16, alignment: .leading)
            footer().frame(height: 18).padding(.top, 6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
    /// Up to three disks across the full width, one line each: icon, name, free of total, and a usage bar.
    @ViewBuilder private var diskCard: some View {
        let volumes = monitor.panelVolumes
        if !volumes.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 4) {
                    Image(systemName: "internaldrive").font(.system(size: 10)).frame(width: 12, height: 12)
                    Text("磁盘")
                    Spacer()
                    Text("可用 / 总容量")
                }.font(PanelFont.label).foregroundStyle(.secondary)
                ForEach(volumes) { volume in DiskRow(volume: volume) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.05)))
            .jump(.diskUtility, detail: volumes.map { "\($0.name)：可用 \(Format.bytes($0.free)) / \(Format.bytes($0.total))" }.joined(separator: "\n"),
                  highlight: .card, openSettings: openPage)
        }
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
        VStack(alignment: .leading, spacing: 6) {
            // Column titles sort the list.
            HStack(spacing: 6) {
                Text("进程").font(PanelFont.heading)
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
                }.buttonStyle(.borderless).foregroundStyle(.secondary).help("打开活动监视器").accessibilityLabel("打开活动监视器")
                Spacer()
                HStack(spacing: 0) {
                    SortHeader(title: "CPU", active: processSort == "cpu") { processSort = "cpu"; UserDefaults.standard.set("cpu", forKey: "panel.processSort") }.frame(width: 70, alignment: .trailing)
                    SortHeader(title: "内存", active: processSort == "memory") { processSort = "memory"; UserDefaults.standard.set("memory", forKey: "panel.processSort") }.frame(width: 78, alignment: .trailing)
                }.font(.system(size: 12, weight: .semibold))
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
                    // Values end where their column title's arrow ends.
                    Text(Format.number(process.cpu, suffix: "%", decimals: 1)).frame(width: 64, alignment: .trailing).padding(.trailing, 6)
                        .foregroundStyle(processSort == "cpu" ? Color.primary : Color.secondary)
                    Text(Format.bytes(process.memory)).frame(width: 72, alignment: .trailing).padding(.trailing, 6)
                        .foregroundStyle(processSort == "memory" ? Color.primary : Color.secondary)
                }.font(PanelFont.row).monospacedDigit().frame(height: 20)
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
            Text(s.date, style: .time).monospacedDigit().font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
            FooterButton(symbol: "gearshape", help: "打开设置窗口", action: openSettings)
            FooterButton(symbol: "power", help: "退出 MacPulse") { NSApp.terminate(nil) }
        }.font(.system(size: 12)).foregroundStyle(.secondary)
            // A glass strip pinned to the bottom.
            .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 5)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 10).padding(.bottom, 10)
    }
}

/// Panel page for mice and other accessories: battery, connection and the mouse's current settings.
struct DevicesPanelPage: View {
    let peripherals: [PeripheralBattery]
    let history: [String: [BatteryPoint]]
    @ObservedObject var mice: MouseCenter
    @ObservedObject var keyboards: KeyboardCenter
    var open: () -> Void
    @ViewState private var openCard: String?
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
        let asleep = mice.asleep.filter { name in !items.contains { $0.name.hasSuffix(name) } }
        VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty && asleep.isEmpty && keyboards.keyboards.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "computermouse").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("没有检测到外设").font(PanelFont.value)
                    Text("支持 WLMOUSE、罗技 HID++ 鼠标，VIA 键盘，以及向系统报告电量的蓝牙外设。").font(PanelFont.label)
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.top, 40)
            }
            // One card per device: battery at a glance, the rest opens on hover.
            ForEach(items) { device in
                HoverCard(id: device.key, open: $openCard, alwaysOpen: items.count == 1) {
                    summary(device)
                } detail: {
                    detail(device)
                }
            }
            ForEach(asleep, id: \.self) { name in
                HStack(spacing: 12) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(PanelFont.heading)
                        Text("正在休眠，动一下鼠标即可").font(PanelFont.label).foregroundStyle(.secondary)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
            // Wired keyboards: connection, layers and macros at a glance; lighting can be set from here.
            ForEach(keyboards.keyboards) { keyboard in
                HoverCard(id: "kbd-" + keyboard.id, open: $openCard, alwaysOpen: items.isEmpty && keyboards.keyboards.count == 1) {
                    KeyboardPanelSummary(center: keyboards, keyboard: keyboard)
                } detail: {
                    KeyboardPanelDetail(center: keyboards, keyboard: keyboard)
                }
            }
            Button(action: open) {
                Label("外设设置与支持的设备", systemImage: "slider.horizontal.3").font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 34).contentShape(Capsule())
            }
            .buttonStyle(.plain).pageGlass(Capsule())
            .padding(.top, 4)
        }
        .onAppear {
            mice.refreshIfStale(60)
            keyboards.refreshIfStale(60)
            if PanelCards.snapshotOpensFirst, openCard == nil { openCard = PanelCards.snapshotCard ?? items.first?.key }
        }
        .onReceive(DeviceIO.retryTick) { _ in
            if !mice.asleep.isEmpty { mice.refreshIfStale(0) }
        }
    }
    /// Always visible: what the device is and how full its battery is.
    private func summary(_ device: PeripheralBattery) -> some View {
        let low = device.percent <= 15 && !device.charging
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: device.symbol).font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(PanelFont.heading).lineLimit(1).truncationMode(.middle)
                    Text(subtitle(device)).font(PanelFont.label).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 2) {
                    if device.charging { Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(.green) }
                    Text(Format.number(device.percent, suffix: "%")).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(low ? Color.orange : Color.primary)
                }
            }
            UsageBar(fraction: device.percent / 100, color: low ? .orange : .green, warnAbove: nil)
        }
    }
    /// Opens on hover: battery history, the mouse's profile and settings.
    private func detail(_ device: PeripheralBattery) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            let points = history[device.key] ?? []
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("近 7 天").font(PanelFont.label).foregroundStyle(.secondary)
                    Spacer()
                    Text(estimate(points, device)).font(PanelFont.label).foregroundStyle(.secondary)
                }
                BatteryHistoryChart(points: points).frame(height: 46)
            }
            if let state = wlState(device), state.settings.profileCount > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("配置").font(PanelFont.label).foregroundStyle(.secondary)
                    GlassTabs(items: (1...state.settings.profileCount).map { ($0, state.settings.profileLabel($0)) },
                              selection: Binding(get: { state.settings.profile }, set: { profile in
                                  var next = state.settings; next.profile = profile
                                  mice.apply(state.id, next)
                              }), height: 26, inPage: true)
                        .disabled(mice.busy)
                        .help("切换鼠标上的配置；每套配置有自己的 DPI、回报率等设置")
                }
            }
            let facts = details(device)
            if !facts.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                    ForEach(facts, id: \.0) { fact in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fact.0).font(PanelFont.label).foregroundStyle(.secondary)
                            Text(fact.1).font(PanelFont.value).monospacedDigit().lineLimit(1)
                        }
                    }
                }
            }
        }
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
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.10), lineWidth: 8)
                if let fraction, fraction > 0 {
                    Circle().trim(from: 0, to: min(1, fraction))
                        .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7).frame(width: 40)
            }.frame(width: 58, height: 58)
            Text(label).font(PanelFont.label).foregroundStyle(.secondary)
        }
        // The hover tile hugs this box, with room around the ring and short of the next column.
        .padding(.horizontal, 8).padding(.vertical, 8)
        .accessibilityElement(children: .ignore).accessibilityLabel("\(label) \(value)")
    }
}

/// One disk on the panel. Attached drives show the icon Finder gives them; the startup disk shows this kind of Mac.
struct DiskRow: View {
    let volume: VolumeInfo
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if volume.path == "/" {
                    Image(systemName: VolumeInfo.macSymbol).font(.system(size: 15)).foregroundStyle(.secondary)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: volume.path)).resizable().interpolation(.high)
                }
            }.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Long names end in an ellipsis; a disk never takes two lines.
                    Text(volume.name).font(PanelFont.row).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text("\(Format.bytes(volume.free)) / \(Format.bytes(volume.total))").font(PanelFont.label).monospacedDigit()
                        .foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                UsageBar(fraction: volume.total > 0 ? volume.used / volume.total : 0, color: .blue)
            }
        }
        .help(volume.name)
    }
}

/// The panel's fan block: the active mode and speeds on top, up to four preset buttons in one glass row below.
struct FanUnit: View {
    @ObservedObject var fan: FanController
    let readings: [FanReading]
    var openPage: (String) -> Void
    @Namespace private var presetGlass
    private func openSettings() { openPage("fan") }
    private var detail: String {
        readings.enumerated().map { index, reading in
            "\(fan.settings.fanName(index)) \(Int(reading.rpm.rounded())) RPM（\(Int(reading.min))–\(Int(reading.max))）"
        }.joined(separator: "\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "fan")
                        .foregroundStyle(fan.safetyOverride ? Color.orange : fan.settings.enabled ? Color.accentColor : Color.secondary)
                    Text(fan.activeLabel).lineLimit(1)
                        .foregroundStyle(fan.safetyOverride ? Color.orange : Color.primary)
                    Spacer(minLength: 6)
                    // One fan reads on this line; several get a row each below.
                    if readings.count == 1, let reading = readings.first {
                        Text(fan.settings.fanName(0)).font(PanelFont.label).foregroundStyle(.secondary)
                        Text(String(Int(reading.rpm.rounded()))).font(PanelFont.tile).monospacedDigit()
                        Text("RPM").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.font(.system(size: 12, weight: .semibold))
                if readings.count == 1, let reading = readings.first {
                    FanBar(reading: reading, height: 5)
                } else {
                    ForEach(Array(readings.enumerated()), id: \.offset) { index, reading in
                        FanSpeedRow(name: fan.settings.fanName(index), reading: reading)
                    }
                }
            }
            .jump(.settings("fan"), detail: detail, openSettings: openPage)
            if fan.settings.enabled {
                // Unselected presets are round icon buttons; the active one opens into a capsule with its name,
                // so even a long custom curve name fits.
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(fan.panelButtons, id: \.id) { preset in
                            let selected = fan.settings.preset == preset.id
                            Button { withAnimation(.bouncy(duration: 0.4)) { fan.select(preset.id) } } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: preset.symbol).font(.system(size: 14, weight: .semibold))
                                    if selected {
                                        Text(preset.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                    }
                                }
                                .padding(.horizontal, selected ? 12 : 0)
                                .frame(width: selected ? nil : 36, height: 36)
                                .frame(maxWidth: selected ? .infinity : nil)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .pageGlass(Capsule(), tint: selected ? .accentColor : nil)
                            .glassEffectID(preset.id, in: presetGlass)
                            .help(selected ? preset.name : "切换到“\(preset.name)”")
                            .accessibilityLabel(preset.name).accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("风扇由系统控制").font(PanelFont.value)
                        Text("开启后可在这里一键切换预设").font(PanelFont.label).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button(action: openSettings) {
                        Text("启用…").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).frame(height: 26).contentShape(Capsule())
                    }.buttonStyle(.plain).pageGlass(Capsule())
                }
            }
        }
    }
}

/// Where a fan's speed sits in its range.
struct FanBar: View {
    let reading: FanReading
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(Color.cyan).frame(width: max(proxy.size.height, proxy.size.width * reading.fraction))
                    .opacity(reading.rpm > 0 ? 1 : 0)
            }
        }.frame(height: height).accessibilityHidden(true)
    }
}

/// One fan in the panel: its name and speed on a line, a bar for where that speed sits in the fan's range.
struct FanSpeedRow: View {
    let name: String
    let reading: FanReading
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(String(Int(reading.rpm.rounded()))).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("RPM").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            FanBar(reading: reading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(Int(reading.rpm.rounded())) RPM")
    }
}
