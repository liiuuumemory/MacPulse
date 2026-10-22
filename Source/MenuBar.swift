import AppKit
import SwiftUI
import CoreText
import UniformTypeIdentifiers

/// How a widget writes its metric: one line, two metrics stacked, a caption over a larger value, or no text (graphic only).
enum WidgetStyle: String, CaseIterable, Codable, Identifiable {
    case text, stacked, mini, hidden
    var id: String { rawValue }
    var name: String {
        switch self {
        case .text: return "文字"
        case .stacked: return "双行"
        case .mini: return "迷你"
        case .hidden: return "不显示"
        }
    }
}

/// Optional graphic drawn left of a widget's text. Charts read the two-minute history.
enum WidgetChart: String, CaseIterable, Codable, Identifiable {
    case none, line, bar, ring, battery
    var id: String { rawValue }
    var name: String {
        switch self {
        case .none: return "无"
        case .line: return "折线"
        case .bar: return "柱状"
        case .ring: return "环形"
        case .battery: return "电池"
        }
    }
    var width: CGFloat {
        switch self {
        case .none: return 0
        case .ring: return 15
        case .battery: return 24
        case .line, .bar: return 30
        }
    }
    func supports(_ metric: MenuMetric) -> Bool {
        switch self {
        case .none: return true
        case .line, .bar: return metric.hasHistory
        case .ring, .battery: return metric.isPercent
        }
    }
    /// A custom color tints only the value graphic (line, bars, arc); text, labels and frames follow the menu bar,
    /// and the battery keeps its own state colors.
    var takesColor: Bool { self == .line || self == .bar || self == .ring }
}

/// One independently styled item in the menu bar: text in one of the styles, with an optional graphic on its left.
struct MenuWidget: Identifiable, Codable, Equatable {
    var id = UUID()
    var enabled = true
    var style: WidgetStyle = .text
    var chart: WidgetChart = .none
    var metric: String
    var secondary = "none"
    var labelMode = "text"
    var label = ""
    var secondaryLabel = ""
    var symbol = ""
    var secondarySymbol = ""
    var color = "system"
    init(_ style: WidgetStyle, _ metric: String, _ secondary: String = "none", labelMode: String = "text", color: String = "system", chart: WidgetChart = .none) {
        self.style = style; self.metric = metric; self.secondary = secondary; self.labelMode = labelMode; self.color = color; self.chart = chart
    }
    /// Before 2.1 a chart was a style of its own, with a separate "show value" switch.
    private enum LegacyKeys: String, CodingKey { case showValue }
    /// True when the widget was saved as a chart style; lets the configuration merge old chart + text pairs once.
    static func isLegacyChart(_ style: String) -> Bool { WidgetChart(rawValue: style).map { $0 != .none } ?? false }
    // Missing keys fall back to defaults so later fields never reset saved widgets.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let savedStyle = (try? c.decodeIfPresent(String.self, forKey: .style)) ?? "text"
        if Self.isLegacyChart(savedStyle), let old = WidgetChart(rawValue: savedStyle) {
            chart = old
            let showValue = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Bool.self, forKey: .showValue) ?? true
            style = showValue ? .text : .hidden
        } else {
            style = WidgetStyle(rawValue: savedStyle) ?? .text
            chart = (try? c.decodeIfPresent(WidgetChart.self, forKey: .chart)) ?? .none
        }
        metric = try c.decodeIfPresent(String.self, forKey: .metric) ?? "cpu"
        secondary = try c.decodeIfPresent(String.self, forKey: .secondary) ?? "none"
        labelMode = try c.decodeIfPresent(String.self, forKey: .labelMode) ?? "text"
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        secondaryLabel = try c.decodeIfPresent(String.self, forKey: .secondaryLabel) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? ""
        secondarySymbol = try c.decodeIfPresent(String.self, forKey: .secondarySymbol) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "system"
    }
}

/// Two-row group saved by 1.6 and earlier; decoded only to migrate.
private struct LegacyMenuColumn: Decodable {
    var enabled = true
    var top: String
    var bottom: String
    var topLabel = ""
    var bottomLabel = ""
    var color = "system"
}

enum MenuSymbols {
    static let appIcons = ["waveform.path.ecg", "cpu", "memorychip", "gauge.with.dots.needle.67percent", "speedometer",
                           "chart.bar.fill", "chart.line.uptrend.xyaxis", "bolt.fill", "thermometer.medium", "fan",
                           "flame", "leaf", "atom", "sparkles", "moon.stars", "heart.fill", "star.fill",
                           "desktopcomputer", "laptopcomputer", "cat", "dog", "bird", "fish", "pawprint.fill",
                           "hare.fill", "tortoise.fill"]
    static let labels = ["cpu", "memorychip", "square.stack.3d.up", "cube", "bolt.fill", "bolt", "thermometer.medium",
                         "thermometer.low", "thermometer.high", "flame", "arrow.up", "arrow.down", "arrow.up.circle",
                         "arrow.down.circle", "network", "wifi", "internaldrive", "externaldrive", "fan",
                         "battery.75percent", "gauge.with.needle", "sparkles", "asterisk", "leaf", "clock", "timer",
                         "chart.pie", "circle.grid.2x2", "cloud", "drop", "computermouse", "keyboard"]
    static let colors = ["system", "blue", "green", "orange", "purple", "red", "pink", "teal", "yellow", "gray"]
    static func exists(_ name: String) -> Bool { NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil }
    static func nsColor(_ name: String) -> NSColor {
        switch name {
        case "blue": return .systemBlue
        case "green": return .systemGreen
        case "orange": return .systemOrange
        case "purple": return .systemPurple
        case "red": return .systemRed
        case "pink": return .systemPink
        case "teal": return .systemTeal
        case "yellow": return .systemYellow
        case "gray": return .systemGray
        default: return .labelColor
        }
    }
}

struct MenuConfiguration: Codable, Equatable {
    static let maxWidgets = 10
    var widgets: [MenuWidget] = [
        MenuWidget(.stacked, "cpu", "memory"),
        MenuWidget(.stacked, "upload", "download"),
        MenuWidget(.stacked, "power", "cpuTemp")
    ]
    var fontSize = 9.0
    var spacing = 10.0
    var icon = "none"
    var iconPosition = "leading"
    var widthMode = "uniform"
    var alignment = "right"
    var separators = false
    var decimals = false
    var rateUnit = "bytes"

    init() {}
    private enum CodingKeys: String, CodingKey {
        case widgets, fontSize, spacing, icon, iconPosition, widthMode, alignment, separators, decimals, rateUnit
        case layout, showLabels, columns
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 9
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? 10
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "none"
        iconPosition = try c.decodeIfPresent(String.self, forKey: .iconPosition) ?? "leading"
        widthMode = try c.decodeIfPresent(String.self, forKey: .widthMode) ?? "uniform"
        alignment = try c.decodeIfPresent(String.self, forKey: .alignment) ?? "right"
        separators = try c.decodeIfPresent(Bool.self, forKey: .separators) ?? false
        decimals = try c.decodeIfPresent(Bool.self, forKey: .decimals) ?? false
        rateUnit = try c.decodeIfPresent(String.self, forKey: .rateUnit) ?? "bytes"
        if let saved = try c.decodeIfPresent([MenuWidget].self, forKey: .widgets) {
            widgets = saved
            // Saved before 2.1: a value-less chart followed by a text widget for the same metric becomes one widget.
            let styles = (try? c.decodeIfPresent([StyleProbe].self, forKey: .widgets)) ?? []
            if styles.contains(where: { MenuWidget.isLegacyChart($0.style ?? "") }) { widgets = Self.mergingChartPairs(widgets) }
        } else if let columns = try c.decodeIfPresent([LegacyMenuColumn].self, forKey: .columns) {
            let single = (try c.decodeIfPresent(String.self, forKey: .layout)) == "single"
            let mode = (try c.decodeIfPresent(Bool.self, forKey: .showLabels) ?? true) ? "text" : "none"
            widgets = columns.flatMap { column -> [MenuWidget] in
                let rows = [(column.top, column.topLabel), (column.bottom, column.bottomLabel)].filter { $0.0 != "none" }
                func widget(_ style: WidgetStyle, _ row: (String, String)) -> MenuWidget {
                    var w = MenuWidget(style, row.0, labelMode: mode, color: column.color)
                    w.enabled = column.enabled; w.label = row.1
                    return w
                }
                // A double-row group becomes one stacked widget; single-row groups split side by side.
                if !single && rows.count == 2 {
                    var w = widget(.stacked, rows[0])
                    w.secondary = rows[1].0; w.secondaryLabel = rows[1].1
                    return [w]
                }
                return rows.map { widget(.text, $0) }
            }
        }
    }
    private struct StyleProbe: Decodable { var style: String? }
    /// Joins a graphic-only widget with the text widget right after it when both show the same metric.
    static func mergingChartPairs(_ widgets: [MenuWidget]) -> [MenuWidget] {
        var result: [MenuWidget] = []
        var index = 0
        while index < widgets.count {
            let first = widgets[index]
            if first.style == .hidden, first.chart != .none, index + 1 < widgets.count {
                let next = widgets[index + 1]
                if next.chart == .none, next.style == .text || next.style == .mini, next.metric == first.metric, next.enabled == first.enabled {
                    var merged = next
                    merged.chart = first.chart; merged.color = first.color
                    result.append(merged); index += 2; continue
                }
            }
            result.append(first); index += 1
        }
        return result
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(widgets, forKey: .widgets)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(spacing, forKey: .spacing)
        try c.encode(icon, forKey: .icon)
        try c.encode(iconPosition, forKey: .iconPosition)
        try c.encode(widthMode, forKey: .widthMode)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(separators, forKey: .separators)
        try c.encode(decimals, forKey: .decimals)
        try c.encode(rateUnit, forKey: .rateUnit)
    }

    static var reference: Self { Self() }
    static var compact: Self {
        var c = Self(); c.widgets = [MenuWidget(.stacked, "power", "cpuTemp")]; return c
    }
    static var performance: Self {
        var c = Self()
        c.widgets = [MenuWidget(.stacked, "cpu", "gpu"), MenuWidget(.stacked, "memory", "cpuTemp"), MenuWidget(.stacked, "upload", "download")]
        return c
    }
    static var charts: Self {
        var c = Self()
        c.widthMode = "fit"; c.alignment = "left"; c.separators = true; c.icon = "waveform.path.ecg"
        c.widgets = [MenuWidget(.mini, "cpu", color: "blue", chart: .bar), MenuWidget(.mini, "memory", color: "green", chart: .ring),
                     MenuWidget(.mini, "power", color: "orange", chart: .line), MenuWidget(.stacked, "upload", "download")]
        return c
    }
    static var quota: Self {
        var c = Self()
        c.widthMode = "fit"; c.alignment = "left"; c.iconPosition = "trailing"
        c.widgets = [MenuWidget(.mini, "claudeQuota", color: "orange", chart: .ring), MenuWidget(.mini, "codexQuota", color: "teal", chart: .ring),
                     MenuWidget(.mini, "peripheral", chart: .battery), MenuWidget(.mini, "power", color: "green", chart: .line),
                     MenuWidget(.stacked, "upload", "download")]
        return c
    }
    static var symbols: Self {
        var c = Self()
        c.widthMode = "fit"; c.alignment = "left"; c.fontSize = 11; c.spacing = 14
        c.widgets = [MenuWidget(.text, "cpu", labelMode: "symbol"), MenuWidget(.text, "memory", labelMode: "symbol"),
                     MenuWidget(.stacked, "upload", "download", labelMode: "symbol"), MenuWidget(.text, "cpuTemp", labelMode: "symbol"),
                     MenuWidget(.text, "power", labelMode: "symbol")]
        return c
    }
    static let presets: [(id: String, name: String, value: Self)] = [
        ("reference", "参考布局", .reference), ("compact", "简洁", .compact), ("performance", "性能", .performance),
        ("charts", "图表", .charts), ("quota", "额度与外设", .quota), ("symbols", "图标", .symbols)
    ]

    /// Same arrangement and look; widget ids differ between a preset and the copy applied from it.
    func matches(_ other: Self) -> Bool {
        func plain(_ c: Self) -> Self {
            var copy = c.sanitized()
            copy.widgets = copy.widgets.map { var w = $0; w.id = Self.plainID; return w }
            return copy
        }
        return plain(self) == plain(other)
    }
    private static let plainID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    func sanitized() -> Self {
        var copy = self
        copy.fontSize = min(13, max(8, fontSize.isFinite ? fontSize : 9))
        copy.spacing = min(24, max(4, spacing.isFinite ? spacing : 10))
        copy.rateUnit = rateUnit == "bits" ? "bits" : "bytes"
        copy.widthMode = widthMode == "fit" ? "fit" : "uniform"
        copy.alignment = alignment == "left" ? "left" : "right"
        copy.iconPosition = iconPosition == "trailing" ? "trailing" : "leading"
        if icon != "none" && !MenuSymbols.appIcons.contains(icon) { copy.icon = "none" }
        copy.widgets = Array(widgets.prefix(Self.maxWidgets)).map { widget in
            var w = widget
            if MenuMetric.find(w.metric) == nil || w.metric == "none" { w.metric = "cpu" }
            if MenuMetric.find(w.secondary) == nil { w.secondary = "none" }
            // A graphic shows one metric, so two stacked metrics carry none; graphic-only needs a graphic.
            if w.style == .stacked || !w.chart.supports(MenuMetric.find(w.metric)!) { w.chart = .none }
            if w.style == .hidden && w.chart == .none { w.style = .text }
            if !["text", "symbol", "none"].contains(w.labelMode) { w.labelMode = "text" }
            w.label = String(w.label.prefix(8)); w.secondaryLabel = String(w.secondaryLabel.prefix(8))
            if !w.symbol.isEmpty && !MenuSymbols.exists(w.symbol) { w.symbol = "" }
            if !w.secondarySymbol.isEmpty && !MenuSymbols.exists(w.secondarySymbol) { w.secondarySymbol = "" }
            if !MenuSymbols.colors.contains(w.color) { w.color = "system" }
            return w
        }
        return copy
    }
}

/// A saved menu bar arrangement: every widget plus the overall look.
struct MenuLayoutPreset: Identifiable, Codable, Equatable {
    static let maxCount = 20
    static let maxName = 16
    var id = UUID()
    var name: String
    var configuration: MenuConfiguration
    /// "我的布局 N" with the smallest N no saved preset uses yet.
    static func defaultName(_ existing: [Self]) -> String {
        let names = Set(existing.map(\.name))
        return (1...).lazy.map { "我的布局 \($0)" }.first { !names.contains($0) }!
    }
    static func cleanName(_ name: String, existing: [Self]) -> String {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxName))
        return trimmed.isEmpty ? defaultName(existing) : trimmed
    }
}

struct MenuMetric: Identifiable {
    let id: String
    let name: String
    let label: String
    let symbol: String
    static let all: [Self] = [
        .init(id: "none", name: "不显示", label: "", symbol: ""),
        .init(id: "cpu", name: "CPU 使用率", label: "CPU", symbol: "cpu"),
        .init(id: "gpu", name: "GPU 使用率", label: "GPU", symbol: "square.stack.3d.up"),
        .init(id: "memory", name: "内存使用率", label: "MEM", symbol: "memorychip"),
        .init(id: "memoryUsed", name: "已用内存", label: "MEM", symbol: "memorychip"),
        .init(id: "power", name: "系统功耗", label: "PWR", symbol: "bolt.fill"),
        .init(id: "cpuPower", name: "CPU 功耗", label: "CPU", symbol: "bolt"),
        .init(id: "gpuPower", name: "GPU 功耗", label: "GPU", symbol: "bolt"),
        .init(id: "cpuTemp", name: "CPU 温度", label: "CPU", symbol: "thermometer.medium"),
        .init(id: "gpuTemp", name: "GPU 温度", label: "GPU", symbol: "thermometer.low"),
        .init(id: "upload", name: "上传速度", label: "↑", symbol: "arrow.up"),
        .init(id: "download", name: "下载速度", label: "↓", symbol: "arrow.down"),
        .init(id: "diskRead", name: "磁盘读取", label: "读", symbol: "arrow.down.circle"),
        .init(id: "diskWrite", name: "磁盘写入", label: "写", symbol: "arrow.up.circle"),
        .init(id: "diskFree", name: "磁盘可用", label: "SSD", symbol: "internaldrive"),
        .init(id: "fan", name: "风扇转速", label: "FAN", symbol: "fan"),
        .init(id: "battery", name: "电池电量", label: "BAT", symbol: "battery.75percent"),
        .init(id: "peripheral", name: "鼠标 / 外设电量", label: "MOU", symbol: "computermouse"),
        .init(id: "codexQuota", name: "Codex 剩余额度", label: "CDX", symbol: "sparkles"),
        .init(id: "claudeQuota", name: "Claude 剩余额度", label: "CLD", symbol: "asterisk")
    ]
    static func find(_ id: String) -> Self? { all.first { $0.id == id } }
    var isPercent: Bool { ["cpu", "gpu", "memory", "battery", "peripheral", "codexQuota", "claudeQuota"].contains(id) }
    /// The accessory that most needs charging.
    static func lowestPeripheral(_ m: Monitor) -> PeripheralBattery? { m.peripherals.min { $0.percent < $1.percent } }
    var hasHistory: Bool { ["cpu", "gpu", "memory", "power", "cpuTemp", "upload", "download"].contains(id) }
    /// Fixed chart ceiling; nil scales to the visible history.
    var chartMax: Double? { isPercent ? 100 : id == "cpuTemp" ? 110 : nil }
    func fraction(_ m: Monitor) -> Double? {
        let s = m.sample
        let value: Double?
        switch id {
        case "cpu": value = s.cpu
        case "gpu": value = s.gpu
        case "memory": value = s.memoryValid && s.memoryTotal > 0 ? s.memoryUsed / s.memoryTotal * 100 : nil
        case "battery": value = s.batteryPercent
        case "peripheral": value = Self.lowestPeripheral(m)?.percent
        case "codexQuota": value = m.aiUsage.remaining(.codex)?.percent
        case "claudeQuota": value = m.aiUsage.remaining(.claude)?.percent
        default: value = nil
        }
        return value.map { max(0, min(1, $0 / 100)) }
    }
    func series(_ m: Monitor) -> [Double?] {
        m.history.map { point in
            switch id {
            case "cpu": return point.cpu
            case "gpu": return point.gpu
            case "memory": return point.memory
            case "power": return point.watts
            case "cpuTemp": return point.temperature
            case "upload": return point.upload
            case "download": return point.download
            default: return nil
            }
        }
    }
    static func rate(_ value: Double?, bits: Bool) -> String {
        guard let value, value.isFinite else { return "—" }
        var n = max(0, value) * (bits ? 8 : 1)
        let base = bits ? 1000.0 : 1024.0
        let units = bits ? ["b/s", "Kb/s", "Mb/s", "Gb/s", "Tb/s", "Pb/s"] : ["B/s", "KB/s", "MB/s", "GB/s", "TB/s", "PB/s"]
        var i = 0
        while n >= base && i < units.count - 1 { n /= base; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.1f %@", n, units[i])
    }
    func value(_ m: Monitor, config: MenuConfiguration) -> String {
        let s = m.sample, d = config.decimals ? 1 : 0
        switch id {
        case "cpu": return Format.number(s.cpu, suffix: "%", decimals: d)
        case "gpu": return Format.number(s.gpu, suffix: "%", decimals: d)
        case "memory": return Format.number(s.memoryValid && s.memoryTotal > 0 ? s.memoryUsed / s.memoryTotal * 100 : nil, suffix: "%", decimals: d)
        case "memoryUsed": return s.memoryValid ? Format.bytes(s.memoryUsed) : "—"
        case "power": return Format.number(s.watts, suffix: " W", decimals: d)
        case "cpuPower": return Format.number(s.cpuPower, suffix: " W", decimals: d)
        case "gpuPower": return Format.number(s.gpuPower, suffix: " W", decimals: d)
        case "cpuTemp": return Format.number(s.cpuTemp, suffix: "°C", decimals: d)
        case "gpuTemp": return Format.number(s.gpuTemp, suffix: "°C", decimals: d)
        case "upload": return Self.rate(m.networkAvailable ? m.networkRates.1 : nil, bits: config.rateUnit == "bits")
        case "download": return Self.rate(m.networkAvailable ? m.networkRates.0 : nil, bits: config.rateUnit == "bits")
        case "diskRead": return Self.rate(s.diskRead, bits: false)
        case "diskWrite": return Self.rate(s.diskWrite, bits: false)
        case "diskFree": return s.diskTotal > 0 ? Format.bytes(s.diskFree) : "—"
        case "fan": return Format.number(s.sensors.first { $0.kind == "RPM" }?.value, suffix: " RPM")
        case "battery": return Format.number(s.batteryPercent, suffix: "%", decimals: d)
        case "peripheral": return Format.number(Self.lowestPeripheral(m)?.percent, suffix: "%")
        case "codexQuota": return Format.number(m.aiUsage.remaining(.codex)?.percent, suffix: "%", decimals: d)
        case "claudeQuota": return Format.number(m.aiUsage.remaining(.claude)?.percent, suffix: "%", decimals: d)
        default: return ""
        }
    }
    static func compactRate(_ value: Double?, bits: Bool) -> String {
        guard let value, value.isFinite else { return "—" }
        var n = max(0, value) * (bits ? 8 : 1)
        let base = bits ? 1000.0 : 1024.0
        let units = bits ? ["b/s", "Kb/s", "Mb/s", "Gb/s", "Tb/s", "Pb/s"] : ["B/s", "KB/s", "MB/s", "GB/s", "TB/s", "PB/s"]
        var i = 0
        // Promote before rounding would require four digits in a compact slot.
        while n >= 999.5 && i < units.count - 1 { n /= base; i += 1 }
        return String(format: i > 0 && n < 9.95 ? "%.1f%@" : "%.0f%@", n, units[i])
    }
    func displayValue(_ m: Monitor, config: MenuConfiguration) -> String {
        switch id {
        case "upload": return Self.compactRate(m.networkAvailable ? m.networkRates.1 : nil, bits: config.rateUnit == "bits")
        case "download": return Self.compactRate(m.networkAvailable ? m.networkRates.0 : nil, bits: config.rateUnit == "bits")
        case "diskRead": return Self.compactRate(m.sample.diskRead, bits: false)
        case "diskWrite": return Self.compactRate(m.sample.diskWrite, bits: false)
        default: return value(m, config: config).replacingOccurrences(of: " ", with: "")
        }
    }
    func displayWidthSample(_ config: MenuConfiguration) -> String {
        switch id {
        case "upload", "download", "diskRead", "diskWrite": return "999MB/s"
        default: return widthSample(config).replacingOccurrences(of: " ", with: "")
        }
    }
    // Width envelopes depend only on the selected metric and formatting, never a sample.
    func widthSample(_ config: MenuConfiguration) -> String {
        switch id {
        case "cpu", "gpu", "memory", "battery", "codexQuota", "claudeQuota": return config.decimals ? "100.0%" : "100%"
        case "peripheral": return "100%"
        case "power", "cpuPower", "gpuPower": return config.decimals ? "1500.0 W" : "1500 W"
        case "cpuTemp", "gpuTemp": return config.decimals ? "130.0°C" : "130°C"
        case "fan": return "20000 RPM"
        case "upload", "download", "diskRead", "diskWrite": return "1024.0 MB/s"
        case "memoryUsed", "diskFree": return "1024.0 GB"
        default: return ""
        }
    }
}

/// Measures every widget from the configuration alone, then draws live values into those fixed slots.
struct MenuBarLayout {
    struct Line {
        var metric: MenuMetric
        var label: String
        var symbol: String?
        var labelWidth: CGFloat
        var valueWidth: CGFloat
        var labelFont: NSFont
        var valueFont: NSFont
        var width: CGFloat { labelWidth + (labelWidth > 0 ? 4 : 0) + valueWidth }
    }
    struct Item {
        var widget: MenuWidget
        var lines: [Line]
        var chartWidth: CGFloat
        var width: CGFloat
    }
    static let chartGap: CGFloat = 4
    var items: [Item]
    var width: CGFloat
    var height: CGFloat
    var config: MenuConfiguration
    var showsIcon: Bool
    var hasCharts: Bool { items.contains { $0.widget.chart != .none } }

    static func numberFont(_ size: CGFloat) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: .medium) }
    static func textFont(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    static func measure(_ text: String, _ font: NSFont) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }

    init(config original: MenuConfiguration, height: CGFloat = 22) {
        let c = original.sanitized()
        config = c; self.height = height
        let uniform = c.widthMode == "uniform"
        func line(_ metricID: String, custom: String, symbol: String, mode: String, size: CGFloat, labelFont: NSFont? = nil) -> Line? {
            guard let metric = MenuMetric.find(metricID), metricID != "none" else { return nil }
            let numberFont = Self.numberFont(size), textFont = labelFont ?? Self.textFont(size)
            let cpuLabel = Self.measure("CPU", textFont)
            var label = "", symbolName: String? = nil, labelWidth: CGFloat = 0
            switch mode {
            case "text":
                label = custom.isEmpty ? metric.label : custom
                let measured = Self.measure(label, textFont)
                labelWidth = uniform ? min(cpuLabel, measured) : measured
            case "symbol":
                symbolName = symbol.isEmpty ? metric.symbol : symbol
                labelWidth = ceil(size + 3)
            default: break
            }
            let sampleWidth = Self.measure(metric.displayWidthSample(c), numberFont)
            if uniform {
                // Every slot matches the original CPU-percentage width; longer metrics shrink their font.
                let slot = (mode == "none" ? 0 : (mode == "symbol" ? ceil(size + 3) : cpuLabel) + 4) + Self.measure(MenuMetric.find("cpu")!.widthSample(c), numberFont) + 2
                let valueWidth = slot - labelWidth - (labelWidth > 0 ? 4 : 0)
                let font = Self.numberFont(size * min(1, valueWidth / max(1, sampleWidth)))
                return Line(metric: metric, label: label, symbol: symbolName, labelWidth: labelWidth, valueWidth: valueWidth, labelFont: textFont, valueFont: font)
            }
            return Line(metric: metric, label: label, symbol: symbolName, labelWidth: labelWidth, valueWidth: sampleWidth + 2, labelFont: textFont, valueFont: numberFont)
        }
        let base = CGFloat(c.fontSize)
        items = c.widgets.filter(\.enabled).compactMap { w in
            var lines: [Line] = []
            let chartWidth = w.chart.width
            switch w.style {
            case .text:
                lines = [line(w.metric, custom: w.label, symbol: w.symbol, mode: w.labelMode, size: base)].compactMap { $0 }
            case .stacked:
                // Two lines must fit the 22 pt bar.
                let size = min(base, 10)
                lines = [line(w.metric, custom: w.label, symbol: w.symbol, mode: w.labelMode, size: size),
                         line(w.secondary, custom: w.secondaryLabel, symbol: w.secondarySymbol, mode: w.labelMode, size: size)].compactMap { $0 }
            case .mini:
                // Small caption above, larger value below.
                let caption = NSFont.systemFont(ofSize: 7, weight: .semibold)
                guard var l = line(w.metric, custom: w.label, symbol: w.symbol, mode: "none", size: min(base + 2, 12)) else { return nil }
                if w.labelMode == "text" { l.label = w.label.isEmpty ? l.metric.label : w.label; l.labelWidth = Self.measure(l.label, caption) }
                if w.labelMode == "symbol" { l.symbol = w.symbol.isEmpty ? l.metric.symbol : w.symbol; l.labelWidth = 8 }
                l.labelFont = caption
                lines = [l]
            case .hidden:
                break
            }
            if lines.isEmpty && chartWidth == 0 { return nil }
            let textWidth: CGFloat = w.style == .mini ? lines.first.map { max($0.labelWidth, $0.valueWidth) } ?? 0 : lines.map(\.width).max() ?? 0
            let width = chartWidth + (chartWidth > 0 && textWidth > 0 ? Self.chartGap : 0) + textWidth
            return Item(widget: w, lines: lines, chartWidth: chartWidth, width: width)
        }
        showsIcon = c.icon != "none" || items.isEmpty
        width = ceil(8 + (showsIcon ? 20 : 0) + items.map(\.width).reduce(0, +) + CGFloat(max(0, items.count - 1)) * c.spacing)
    }
    func summary(_ monitor: Monitor) -> String {
        items.flatMap { item in
            [item.widget.metric, item.widget.style == .stacked ? item.widget.secondary : "none"].compactMap { id in
                guard id != "none", let metric = MenuMetric.find(id) else { return nil }
                return "\(metric.name) \(metric.value(monitor, config: config))"
            }
        }.joined(separator: "，")
    }
    /// Everything a redraw depends on; charts also change when history advances.
    func signature(_ monitor: Monitor) -> [String] {
        items.flatMap { $0.lines.map { $0.metric.displayValue(monitor, config: config) } }
            + (hasCharts ? [String(monitor.sample.date.timeIntervalSinceReferenceDate)] : [])
    }
    func image(_ monitor: Monitor) -> NSImage {
        // Values affect only alignment inside each fixed slot, never its width.
        let strings = items.map { $0.lines.map { $0.metric.displayValue(monitor, config: config) } }
        let metrics = items.map { MenuMetric.find($0.widget.metric)! }
        let series = zip(items, metrics).map { item, metric in item.widget.chart == .line || item.widget.chart == .bar ? metric.series(monitor) : [] }
        let fractions = metrics.map { $0.fraction(monitor) }
        let cores = monitor.sample.cores
        let charging = monitor.sample.charging
        let peripheralCharging = MenuMetric.lowestPeripheral(monitor)?.charging ?? false
        /// Battery-style system and accessory batteries: charging and low (under 20%, not charging) states.
        let batteryCharging = items.map { ($0.widget.metric == "battery" && charging) || ($0.widget.metric == "peripheral" && peripheralCharging) }
        let batteryFill: [NSColor?] = items.indices.map { i in
            let w = items[i].widget
            guard w.chart == .battery, w.metric == "battery" || w.metric == "peripheral" else { return nil }
            if batteryCharging[i] { return .systemGreen }
            return (fractions[i] ?? 1) < 0.2 ? .systemRed : nil
        }
        // A template image lets the system color it; any custom or state color needs a full-color image.
        let monochrome = items.allSatisfy { $0.widget.color == "system" || !$0.widget.chart.takesColor } && batteryFill.allSatisfy { $0 == nil }
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let height = self.height
            func tint(_ name: String) -> NSColor { monochrome ? .black : MenuSymbols.nsColor(name) }
            let foreground = tint("system")
            func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
                CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil)
            }
            // Both fonts share an explicit baseline; bounding-box origins differ between SF Mono and SF Pro digits.
            func text(_ string: String, font: NSFont, color: NSColor, x: CGFloat, width slot: CGFloat, y: CGFloat, lineHeight: CGFloat, baselineFonts: [NSFont], right: Bool) {
                var line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
                if CTLineGetTypographicBounds(line, nil, nil, nil) > slot {
                    let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: color]))
                    line = CTLineCreateTruncatedLine(line, Double(slot), .end, token) ?? token
                }
                let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let ascent = baselineFonts.map(\.ascender).max() ?? font.ascender
                let descent = baselineFonts.map(\.descender).min() ?? font.descender
                context.saveGState()
                context.clip(to: CGRect(x: x, y: y, width: slot, height: lineHeight))
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: right ? x + slot - advance : x, y: y + (lineHeight - (ascent - descent)) / 2 - descent)
                CTLineDraw(line, context)
                context.restoreGState()
            }
            func symbol(_ name: String, in rect: NSRect, color: NSColor) {
                guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
                let configured = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: rect.height, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))) ?? base
                let size = configured.size
                let scale = min(rect.width / max(1, size.width), rect.height / max(1, size.height))
                let fitted = NSSize(width: size.width * scale, height: size.height * scale)
                configured.draw(in: NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height))
            }
            func draw(_ line: Line, value: String, x: CGFloat, width slot: CGFloat, y: CGFloat, lineHeight: CGFloat, color: NSColor) {
                if let name = line.symbol {
                    let side = min(line.labelWidth - 2, lineHeight - 2)
                    symbol(name, in: NSRect(x: x, y: y + (lineHeight - side) / 2, width: line.labelWidth - 2, height: side), color: color)
                } else if !line.label.isEmpty {
                    text(line.label, font: line.labelFont, color: color, x: x, width: line.labelWidth, y: y, lineHeight: lineHeight, baselineFonts: [line.labelFont, line.valueFont], right: false)
                }
                // Left alignment keeps values beside their label; the slot itself never moves.
                let left = config.alignment == "left"
                let valueX = left ? x + line.labelWidth + (line.labelWidth > 0 ? 4 : 0) : x + slot - line.valueWidth
                text(value, font: line.valueFont, color: color, x: valueX, width: left ? slot - (valueX - x) : line.valueWidth, y: y, lineHeight: lineHeight,
                     baselineFonts: [line.labelFont, line.valueFont], right: !left)
            }
            var x: CGFloat = 4
            func appIcon() {
                let name = config.icon == "none" ? "waveform.path.ecg" : config.icon
                symbol(name, in: NSRect(x: x, y: (height - 15) / 2, width: 15, height: 15), color: foreground)
                x += 20
            }
            if showsIcon && (config.iconPosition == "leading" || items.isEmpty) { appIcon() }
            for (index, item) in items.enumerated() {
                let w = item.widget
                let color = w.chart.takesColor ? tint(w.color) : foreground
                let chart = NSRect(x: x, y: 3, width: item.chartWidth, height: height - 6)
                switch w.chart {
                case .line:
                    let values = series[index]
                    let top = metrics[index].chartMax ?? max(1, (values.compactMap { $0 }.max() ?? 1) * 1.15)
                    let count = max(2, values.count)
                    var points: [CGPoint] = []
                    for (i, value) in values.enumerated() {
                        guard let value, value.isFinite else { continue }
                        points.append(CGPoint(x: chart.minX + chart.width * CGFloat(i) / CGFloat(count - 1), y: chart.minY + chart.height * CGFloat(min(1, max(0, value / top)))))
                    }
                    let frame = rounded(chart, 3)
                    context.addPath(frame); context.setFillColor(foreground.withAlphaComponent(0.12).cgColor); context.fillPath()
                    if points.count > 1 {
                        let path = CGMutablePath(); path.addLines(between: points)
                        let area = path.mutableCopy()!
                        area.addLine(to: CGPoint(x: points.last!.x, y: chart.minY)); area.addLine(to: CGPoint(x: points[0].x, y: chart.minY)); area.closeSubpath()
                        context.saveGState()
                        context.addPath(frame); context.clip()
                        context.addPath(area); context.setFillColor(color.withAlphaComponent(0.3).cgColor); context.fillPath()
                        context.addPath(path); context.setStrokeColor(color.cgColor); context.setLineWidth(1.2)
                        context.setLineJoin(.round); context.setLineCap(.round); context.strokePath()
                        context.restoreGState()
                    }
                case .bar:
                    // CPU shows one bar per core; other metrics show their recent history.
                    let values: [Double?] = w.metric == "cpu" && !cores.isEmpty ? cores.map { Optional($0) } : Array(series[index].suffix(10))
                    let top = metrics[index].chartMax ?? max(1, (values.compactMap { $0 }.max() ?? 1) * 1.15)
                    let frame = rounded(chart, 3)
                    context.addPath(frame); context.setFillColor(foreground.withAlphaComponent(0.12).cgColor); context.fillPath()
                    let n = CGFloat(max(1, values.count))
                    let barWidth = max(1, (chart.width - (n - 1)) / n)
                    context.saveGState()
                    context.addPath(frame); context.clip()
                    context.setFillColor(color.cgColor)
                    for (i, value) in values.enumerated() {
                        guard let value, value.isFinite else { continue }
                        let h = max(1, chart.height * CGFloat(min(1, max(0, value / top))))
                        // Bars stand on the frame's floor; rounding the tops keeps thin bars soft.
                        let bar = CGRect(x: chart.minX + CGFloat(i) * (barWidth + 1), y: chart.minY - 2, width: barWidth, height: h + 2)
                        context.addPath(rounded(bar, min(1.5, barWidth / 2))); context.fillPath()
                    }
                    context.restoreGState()
                case .ring:
                    let center = CGPoint(x: chart.midX, y: height / 2), radius: CGFloat = 6
                    context.setLineWidth(2.5)
                    context.setStrokeColor(foreground.withAlphaComponent(0.25).cgColor)
                    context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false); context.strokePath()
                    if let fraction = fractions[index], fraction > 0 {
                        context.setStrokeColor(color.cgColor); context.setLineCap(.round)
                        context.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2 * CGFloat(fraction), clockwise: true)
                        context.strokePath()
                    }
                case .battery:
                    // The menu bar's own color, green while charging, red when low.
                    let body = CGRect(x: chart.minX + 0.5, y: height / 2 - 5.5, width: 20, height: 11)
                    context.setStrokeColor(foreground.withAlphaComponent(0.55).cgColor); context.setLineWidth(1)
                    context.addPath(rounded(body, 3.5)); context.strokePath()
                    context.addPath(rounded(CGRect(x: body.maxX + 1, y: height / 2 - 2, width: 1.8, height: 4), 0.9))
                    context.setFillColor(foreground.withAlphaComponent(0.55).cgColor); context.fillPath()
                    if let fraction = fractions[index] {
                        let inner = body.insetBy(dx: 2, dy: 2)
                        context.addPath(rounded(CGRect(x: inner.minX, y: inner.minY, width: max(1.5, inner.width * CGFloat(fraction)), height: inner.height), 2))
                        context.setFillColor((batteryFill[index] ?? foreground).cgColor); context.fillPath()
                    }
                    if batteryCharging[index] {
                        // A white bolt with a soft dark outline reads on green in both appearances.
                        let b = CGRect(x: body.midX - 3.4, y: body.midY - 5, width: 6.8, height: 10)
                        let bolt = CGMutablePath()
                        bolt.addLines(between: [CGPoint(x: b.minX + 0.62 * b.width, y: b.maxY), CGPoint(x: b.minX, y: b.minY + 0.43 * b.height),
                                                CGPoint(x: b.minX + 0.42 * b.width, y: b.minY + 0.43 * b.height), CGPoint(x: b.minX + 0.36 * b.width, y: b.minY),
                                                CGPoint(x: b.maxX, y: b.minY + 0.58 * b.height), CGPoint(x: b.minX + 0.58 * b.width, y: b.minY + 0.58 * b.height)])
                        bolt.closeSubpath()
                        context.setLineJoin(.round)
                        context.addPath(bolt); context.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor); context.setLineWidth(1.6); context.strokePath()
                        context.addPath(bolt); context.setFillColor(NSColor.white.cgColor); context.fillPath()
                        context.addPath(bolt); context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(0.5); context.strokePath()
                    }
                case .none: break
                }
                let textX = x + item.chartWidth + (item.chartWidth > 0 ? Self.chartGap : 0)
                let slot = item.width - (textX - x)
                if w.style == .mini, let line = item.lines.first {
                    // Caption in the top third, value below.
                    if let name = line.symbol { symbol(name, in: NSRect(x: textX, y: 13, width: 8, height: 8), color: foreground.withAlphaComponent(0.75)) }
                    else if !line.label.isEmpty {
                        text(line.label, font: line.labelFont, color: foreground.withAlphaComponent(0.75), x: textX, width: slot, y: 12, lineHeight: 10, baselineFonts: [line.labelFont], right: false)
                    }
                    let captioned = line.symbol != nil || !line.label.isEmpty
                    let left = config.alignment == "left"
                    text(strings[index][0], font: line.valueFont, color: foreground, x: left ? textX : textX + slot - line.valueWidth, width: left ? slot : line.valueWidth,
                         y: 0, lineHeight: captioned ? 13 : height, baselineFonts: [line.valueFont], right: !left)
                } else if item.lines.count == 2 {
                    for (row, line) in item.lines.enumerated() {
                        draw(line, value: strings[index][row], x: textX, width: slot, y: height - CGFloat(row + 1) * height / 2, lineHeight: height / 2, color: foreground)
                    }
                } else if let line = item.lines.first {
                    draw(line, value: strings[index][0], x: textX, width: slot, y: 0, lineHeight: height, color: foreground)
                }
                x += item.width
                if index < items.count - 1 {
                    if config.separators {
                        context.addPath(rounded(CGRect(x: x + CGFloat(config.spacing) / 2 - 0.5, y: 4, width: 1, height: height - 8), 0.5))
                        context.setFillColor(foreground.withAlphaComponent(0.3).cgColor); context.fillPath()
                    }
                    x += CGFloat(config.spacing)
                }
            }
            if showsIcon && config.iconPosition == "trailing" && !items.isEmpty { x += 4; appIcon() }
            return true
        }
        image.isTemplate = monochrome
        return image
    }
}

struct MenuBarPreview: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("实时预览").font(.headline)
                Text("修改即时生效").font(.subheadline).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                Image(nsImage: MenuBarLayout(config: monitor.menuConfiguration).image(monitor))
                    .padding(10)
            }.frame(height: 44)
                .settingsCard()
            Text("宽度 \(Int(MenuBarLayout(config: monitor.menuConfiguration).width)) pt · 宽度只随设置变化，数值跳动时不会挤动相邻内容")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private typealias EditorState<Value> = SwiftUI.State<Value>

/// Live rendering of one widget, used for the style thumbnails.
struct WidgetThumbnail: View {
    let monitor: Monitor
    let widget: MenuWidget
    let config: MenuConfiguration
    var fit = false
    var body: some View {
        var single = config
        single.widgets = [widget]; single.icon = "none"; single.separators = false
        let image = Image(nsImage: MenuBarLayout(config: single).image(monitor))
        return Group {
            if fit { image.resizable().aspectRatio(contentMode: .fit) } else { image }
        }
    }
}

struct MenuBarEditor: View {
    @ObservedObject var monitor: Monitor
    @EditorState private var expanded: Set<UUID> = []
    @EditorState private var dragging: UUID?
    private var config: Binding<MenuConfiguration> { $monitor.menuConfiguration }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MenuPresetSection(monitor: monitor) { expanded = [] }
            HStack(spacing: 10) {
                Text("小部件").font(.headline)
                Text("\(monitor.menuConfiguration.widgets.count) / \(MenuConfiguration.maxWidgets) · 拖动排序").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(MenuMetric.all.filter { $0.id != "none" }) { metric in
                        Button { add(metric.id) } label: { Label(metric.name, systemImage: metric.symbol) }
                    }
                } label: { Label("添加小部件", systemImage: "plus") }
                    .fixedSize()
                    .disabled(monitor.menuConfiguration.widgets.count >= MenuConfiguration.maxWidgets)
            }
            if monitor.menuConfiguration.widgets.isEmpty {
                Text("还没有小部件，菜单栏只显示图标。点击“添加小部件”开始。").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(config.widgets) { $widget in
                widgetCard($widget)
                    .opacity(dragging == widget.id ? 0.4 : 1)
                    .onDrag {
                        dragging = widget.id
                        return NSItemProvider(object: widget.id.uuidString as NSString)
                    }
                    .onDrop(of: [UTType.text], delegate: WidgetDropDelegate(target: widget.id, monitor: monitor, dragging: $dragging))
            }
            PreferenceCard(title: "整体外观") {
                HStack(alignment: .top, spacing: 16) {
                    PreferenceField(title: "数值宽度") {
                        Picker("数值宽度", selection: config.widthMode) {
                            Text("统一").tag("uniform"); Text("按内容").tag("fit")
                        }.pickerStyle(.segmented).fixedSize()
                    }
                    PreferenceField(title: "字号") {
                        Picker("字号", selection: config.fontSize) {
                            ForEach([8.0, 9.0, 10.0, 11.0, 12.0, 13.0], id: \.self) { Text("\(Int($0)) pt").tag($0) }
                        }.fixedSize()
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    PreferenceField(title: "小部件间距") {
                        Picker("小部件间距", selection: config.spacing) {
                            ForEach([4.0, 6.0, 10.0, 14.0, 20.0, 24.0], id: \.self) { Text("\(Int($0)) pt").tag($0) }
                        }.fixedSize()
                    }
                    PreferenceField(title: "网速单位") {
                        Picker("网速单位", selection: config.rateUnit) {
                            Text("字节 / 秒（B/s）").tag("bytes"); Text("比特 / 秒（b/s）").tag("bits")
                        }.fixedSize()
                    }
                }
                PreferenceField(title: "数值对齐") {
                    Picker("数值对齐", selection: config.alignment) {
                        Text("靠右").tag("right"); Text("靠左").tag("left")
                    }.pickerStyle(.segmented).fixedSize()
                }
                HStack(spacing: 20) {
                    Toggle("小部件之间加分隔线", isOn: config.separators)
                    Toggle("保留一位小数", isOn: config.decimals)
                }.toggleStyle(.checkbox)
                Text("“统一”让每个数值与 CPU 百分比同宽，较长的数值缩小字号；“按内容”按各指标可能出现的最长值留宽。靠右时单位上下对齐，靠左时数值紧跟标签。双行样式字号最大 10 pt。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            PreferenceCard(title: "菜单栏图标") {
                HStack(spacing: 12) {
                    Text("位置").font(.callout).foregroundStyle(.secondary)
                    Picker("位置", selection: config.iconPosition) {
                        Text("左侧").tag("leading"); Text("右侧").tag("trailing")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
                        .disabled(monitor.menuConfiguration.icon == "none")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 6)], spacing: 6) {
                    iconCell("none")
                    ForEach(MenuSymbols.appIcons, id: \.self) { iconCell($0) }
                }
                Text("没有小部件时始终保留图标，方便点击打开面板。").font(.subheadline).foregroundStyle(.secondary)
            }
        }.onAppear {
            // Open the first widget so the editing controls are visible right away.
            if expanded.isEmpty, let first = monitor.menuConfiguration.widgets.first { expanded = [first.id] }
        }
    }

    private func iconCell(_ name: String) -> some View {
        let selected = monitor.menuConfiguration.icon == name
        return Button { monitor.menuConfiguration.icon = name } label: {
            Group {
                if name == "none" { Text("无").font(.callout) } else { Image(systemName: name).font(.system(size: 15)) }
            }
            .frame(width: 38, height: 32)
            .background(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help(name == "none" ? "不显示图标" : name)
            .accessibilityLabel(name == "none" ? "不显示图标" : name)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func widgetCard(_ widget: Binding<MenuWidget>) -> some View {
        let w = widget.wrappedValue
        let isOpen = expanded.contains(w.id)
        let index = (monitor.menuConfiguration.widgets.firstIndex { $0.id == w.id } ?? 0) + 1
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).help("拖动排序")
                Toggle("显示", isOn: widget.enabled).toggleStyle(.checkbox).labelsHidden().help("显示这个小部件")
                Button { toggle(w.id) } label: {
                    HStack(spacing: 8) {
                        Text("\(index)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Text(summary(w)).font(.headline).lineLimit(1)
                        WidgetThumbnail(monitor: monitor, widget: w, config: monitor.menuConfiguration)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isOpen ? 0 : -90))
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(isOpen ? "收起\(summary(w))" : "编辑\(summary(w))")
                Button { move(w.id, by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 1).help("向前移动").accessibilityLabel("向前移动小部件")
                Button { move(w.id, by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == monitor.menuConfiguration.widgets.count).help("向后移动").accessibilityLabel("向后移动小部件")
                Button { duplicate(w) } label: { Image(systemName: "plus.square.on.square") }
                    .disabled(monitor.menuConfiguration.widgets.count >= MenuConfiguration.maxWidgets).help("复制").accessibilityLabel("复制小部件")
                Button { monitor.menuConfiguration.widgets.removeAll { $0.id == w.id } } label: { Image(systemName: "trash") }
                    .help("删除").accessibilityLabel("删除小部件")
            }.buttonStyle(.borderless)
            if isOpen { widgetEditor(widget) }
        }.padding(14).settingsCard()
    }

    @ViewBuilder private func widgetEditor(_ widget: Binding<MenuWidget>) -> some View {
        let w = widget.wrappedValue
        let metric = MenuMetric.find(w.metric) ?? MenuMetric.find("cpu")!
        let charts = WidgetChart.allCases.filter { $0 != .none }
        // Step 1: how the text reads. Graphic-only needs a graphic this metric can draw.
        PreferenceField(title: "文字格式") {
            tileRow(WidgetStyle.allCases, selected: w.style, name: \.name,
                    enabled: { $0 != .hidden || charts.contains { $0.supports(metric) } },
                    disabledHelp: "这个指标没有可用的图形",
                    preview: { styled(w, $0) }) { setStyle(widget, $0) }
        }
        HStack(alignment: .top, spacing: 16) {
            PreferenceField(title: w.style == .stacked ? "上行指标" : "指标") {
                Picker("指标", selection: Binding(get: { w.metric }, set: { setMetric(widget, $0) })) {
                    ForEach(MenuMetric.all.filter { $0.id != "none" }) { Label($0.name, systemImage: $0.symbol).tag($0.id) }
                }.fixedSize()
            }
            if w.style == .stacked {
                PreferenceField(title: "下行指标") {
                    Picker("下行指标", selection: widget.secondary) {
                        ForEach(MenuMetric.all) { Text($0.name).tag($0.id) }
                    }.fixedSize()
                }
            }
        }
        if w.style != .hidden {
            HStack(alignment: .top, spacing: 16) {
                PreferenceField(title: "标签") {
                    Picker("标签", selection: widget.labelMode) {
                        Text("文字").tag("text"); Text("图标").tag("symbol"); Text("不显示").tag("none")
                    }.pickerStyle(.segmented).frame(width: 190)
                }
                if w.labelMode == "text" {
                    PreferenceField(title: w.style == .stacked ? "自定义文字（上 / 下）" : "自定义文字") {
                        HStack(spacing: 6) {
                            labelField(widget.label, placeholder: metric.label)
                            if w.style == .stacked { labelField(widget.secondaryLabel, placeholder: MenuMetric.find(w.secondary)?.label ?? "") }
                        }
                    }
                } else if w.labelMode == "symbol" {
                    PreferenceField(title: w.style == .stacked ? "图标（上 / 下）" : "图标") {
                        HStack(spacing: 6) {
                            SymbolMenu(selection: widget.symbol, fallback: metric.symbol)
                            if w.style == .stacked { SymbolMenu(selection: widget.secondarySymbol, fallback: MenuMetric.find(w.secondary)?.symbol ?? "circle") }
                        }
                    }
                }
            }
        }
        Divider()
        // Step 2: an optional graphic on the left of the text.
        PreferenceField(title: "统计图形") {
            if w.style == .stacked {
                Text("双行显示两项不同数据，图形无法对应其中一项，所以不能添加。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if w.chart == .none {
                Menu {
                    ForEach(charts) { chart in
                        Button(chart.name) { widget.wrappedValue.chart = chart }.disabled(!chart.supports(metric))
                    }
                } label: { Label("添加图形", systemImage: "plus") }
                    .fixedSize()
                    .disabled(!charts.contains { $0.supports(metric) })
                    .help(charts.contains { $0.supports(metric) } ? "在文字左侧加一个图形" : "这个指标没有可用的图形")
            } else {
                HStack(alignment: .center, spacing: 10) {
                    tileRow(charts, selected: w.chart, name: \.name, enabled: { $0.supports(metric) },
                            disabledHelp: "环形和电池仅适用于百分比类指标，折线和柱状需要有历史曲线的指标",
                            preview: { chart in
                                // A graphic this metric can't draw is shown with CPU data, dimmed, so its shape still reads.
                                var copy = w; copy.chart = chart; copy.style = .hidden
                                if !chart.supports(metric) { copy.metric = "cpu" }
                                return copy
                            }) { widget.wrappedValue.chart = $0 }
                    Button { widget.wrappedValue.chart = .none } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).disabled(w.style == .hidden)
                        .help(w.style == .hidden ? "文字格式为“不显示”时必须保留图形" : "移除图形").accessibilityLabel("移除图形")
                }
            }
        }
        if w.chart == .battery && (w.metric == "battery" || w.metric == "peripheral") {
            Text("电池平时跟随菜单栏颜色，充电时变绿并显示闪电，电量低于 20% 时变红。")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        // Only the value graphic takes a color; text and battery states follow the menu bar.
        if w.chart.takesColor { PreferenceField(title: "数值图形颜色") {
            HStack(spacing: 8) {
                ForEach(MenuSymbols.colors, id: \.self) { name in
                    Button { widget.wrappedValue.color = name } label: {
                        Circle().fill(name == "system" ? Color.primary : Color(nsColor: MenuSymbols.nsColor(name)))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                            .padding(3)
                            .overlay(Circle().strokeBorder(w.color == name ? Color.accentColor : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).help(name == "system" ? "跟随系统" : name).accessibilityLabel(name == "system" ? "跟随系统颜色" : name)
                }
            }
        } }
    }

    /// A row of live-preview tiles; flexible columns keep it inside a narrow window.
    private func tileRow<Option: Identifiable & Equatable>(_ options: [Option], selected: Option, name: KeyPath<Option, String>,
                                                          enabled: @escaping (Option) -> Bool, disabledHelp: String,
                                                          preview: @escaping (Option) -> MenuWidget, choose: @escaping (Option) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 48), spacing: 6), count: options.count), spacing: 6) {
            ForEach(options) { option in
                let on = enabled(option)
                Button { if on { choose(option) } } label: {
                    VStack(spacing: 4) {
                        WidgetThumbnail(monitor: monitor, widget: preview(option), config: monitor.menuConfiguration, fit: true)
                            .frame(maxWidth: 70).frame(height: 22).padding(.horizontal, 4)
                        Text(option[keyPath: name]).font(.subheadline).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(option == selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(option == selected ? Color.accentColor : .clear, lineWidth: 1.5))
                    .opacity(on ? 1 : 0.35)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help(on ? option[keyPath: name] : disabledHelp)
                    .accessibilityLabel(option[keyPath: name]).accessibilityAddTraits(option == selected ? .isSelected : [])
            }
        }
    }

    private func labelField(_ text: Binding<String>, placeholder: String) -> some View {
        TextField("默认：\(placeholder)", text: Binding(get: { text.wrappedValue }, set: { text.wrappedValue = String($0.prefix(8)) }))
            .textFieldStyle(.roundedBorder).frame(width: 120)
    }
    private func summary(_ w: MenuWidget) -> String {
        let name = MenuMetric.find(w.metric)?.name ?? w.metric
        guard w.style == .stacked, let second = MenuMetric.find(w.secondary), second.id != "none" else { return name }
        return name + " / " + second.name
    }
    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
    /// The widget as it would look in another text style: stacked needs a second metric and drops the graphic,
    /// graphic-only needs one.
    private func styled(_ w: MenuWidget, _ style: WidgetStyle) -> MenuWidget {
        var copy = w
        copy.style = style
        if style == .stacked {
            copy.chart = .none
            if copy.secondary == "none" { copy.secondary = copy.metric == "upload" ? "download" : "memory" }
        }
        if style == .hidden && copy.chart == .none, let metric = MenuMetric.find(copy.metric) {
            copy.chart = [WidgetChart.ring, .line, .bar, .battery].first { $0.supports(metric) } ?? .none
        }
        return copy
    }
    private func setStyle(_ widget: Binding<MenuWidget>, _ style: WidgetStyle) {
        widget.wrappedValue = styled(widget.wrappedValue, style)
    }
    private func setMetric(_ widget: Binding<MenuWidget>, _ id: String) {
        widget.wrappedValue.metric = id
        widget.wrappedValue.symbol = ""
        guard let metric = MenuMetric.find(id), !widget.wrappedValue.chart.supports(metric) else { return }
        widget.wrappedValue.chart = .none
        if widget.wrappedValue.style == .hidden { widget.wrappedValue.style = .text }
    }
    private func add(_ metric: String) {
        var w = MenuWidget(metric == "upload" ? .stacked : .text, metric, metric == "upload" ? "download" : "none")
        if metric == "battery" || metric == "peripheral" { w.chart = .battery }
        monitor.menuConfiguration.widgets.append(w)
        expanded.insert(w.id)
    }
    private func duplicate(_ w: MenuWidget) {
        guard let index = monitor.menuConfiguration.widgets.firstIndex(where: { $0.id == w.id }) else { return }
        var copy = w; copy.id = UUID()
        monitor.menuConfiguration.widgets.insert(copy, at: index + 1)
    }
    private func move(_ id: UUID, by offset: Int) {
        guard let index = monitor.menuConfiguration.widgets.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard monitor.menuConfiguration.widgets.indices.contains(destination) else { return }
        monitor.menuConfiguration.widgets.swapAt(index, destination)
    }
}

/// Saved and built-in layouts as live thumbnails: click to switch, save the current layout,
/// save edits back to the preset they came from, or undo a switch.
struct MenuPresetSection: View {
    @ObservedObject var monitor: Monitor
    var onApply: () -> Void = {}
    @EditorState private var saving = false
    @EditorState private var renaming: UUID?
    @EditorState private var nameText = ""
    @EditorState private var deleting: MenuLayoutPreset?
    @EditorState private var hovered: String?
    @EditorState private var undo: Undo?
    @EditorState private var builtInsOpen: Bool?
    private struct Undo { let previous: MenuConfiguration; let source: String?; let applied: MenuConfiguration; let name: String }
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]
    private var full: Bool { monitor.menuPresets.count >= MenuLayoutPreset.maxCount }

    var body: some View {
        let current = monitor.currentMenuPresetID
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("布局预设").font(.headline)
                Text("点击切换 · 右键管理").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button { nameText = MenuLayoutPreset.defaultName(monitor.menuPresets); saving = true } label: {
                    Label("保存当前布局…", systemImage: "square.and.arrow.down")
                }.fixedSize().disabled(full)
                    .help(full ? "最多保存 \(MenuLayoutPreset.maxCount) 个预设，先删除不用的" : "把当前的小部件排列和整体外观保存为预设")
                    .popover(isPresented: $saving, arrowEdge: .bottom) {
                        nameForm(title: "保存为新预设", action: "保存") { monitor.saveMenuPreset(named: nameText); undo = nil; saving = false }
                    }
            }
            banner(current)
            Text("我的预设").font(.callout).foregroundStyle(.secondary)
            if monitor.menuPresets.isEmpty {
                Text("还没有保存的预设。调好下面的小部件后点“保存当前布局…”，以后可以在这里或菜单栏右键菜单里一键切换。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(monitor.menuPresets) { preset in
                        tile(id: preset.id.uuidString, name: preset.name, configuration: preset.configuration, current: current)
                            .contextMenu { savedActions(preset, current: current) }
                            .popover(isPresented: Binding(get: { renaming == preset.id }, set: { if !$0 { renaming = nil } }), arrowEdge: .bottom) {
                                nameForm(title: "重命名预设", action: "重命名") { monitor.renameMenuPreset(preset.id, to: nameText); renaming = nil }
                            }
                    }
                }
            }
            // Built-ins fold away once the user has layouts of their own, unless one is in use.
            let showBuiltIns = builtInsOpen ?? (monitor.menuPresets.isEmpty || MenuConfiguration.presets.contains { $0.id == current })
            Button { builtInsOpen = !showBuiltIns } label: {
                HStack(spacing: 5) {
                    Text("内置").font(.callout)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).rotationEffect(.degrees(showBuiltIns ? 0 : -90))
                }.foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(showBuiltIns ? "收起内置预设" : "展开内置预设")
            if showBuiltIns {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(MenuConfiguration.presets, id: \.id) { preset in
                        tile(id: preset.id, name: preset.name, configuration: preset.value, current: current)
                            .contextMenu { builtInActions(preset, current: current) }
                    }
                }
            }
        }.padding(16).settingsCard()
            .confirmationDialog("删除预设“\(deleting?.name ?? "")”？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("删除", role: .destructive) { if let p = deleting { monitor.deleteMenuPreset(p.id) }; deleting = nil }
            } message: { Text("菜单栏当前的显示不受影响。") }
    }

    /// One line under the header: undo right after a switch, otherwise whether the current layout is saved.
    @ViewBuilder private func banner(_ current: String?) -> some View {
        let source = monitor.menuPresetSource.flatMap { id in monitor.allMenuPresets.first { $0.id == id } }
        if let undo, monitor.menuConfiguration.matches(undo.applied), !undo.previous.matches(undo.applied) {
            bannerRow(symbol: "checkmark.circle.fill", tint: .accentColor, text: "已切换到“\(undo.name)”") {
                Button("撤销") { restore(undo) }
                Button { self.undo = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("关闭").accessibilityLabel("关闭提示")
            }
        } else if current == nil, let source {
            bannerRow(symbol: "circle.fill", tint: .orange, text: source.builtIn ? "基于内置“\(source.name)”，有未保存的修改" : "基于“\(source.name)”，有未保存的修改") {
                Button("还原") { monitor.applyMenuPreset(source.id); onApply() }.help("丢弃修改，恢复成“\(source.name)”")
                if !source.builtIn, let id = UUID(uuidString: source.id) {
                    Button("更新“\(source.name)”") { monitor.updateMenuPreset(id) }.help("用当前布局覆盖这个预设")
                }
            }
        } else if current == nil {
            bannerRow(symbol: "circle.fill", tint: .orange, text: "当前布局还没有保存为预设") { EmptyView() }
        }
    }

    private func bannerRow<Actions: View>(symbol: String, tint: Color, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: symbol == "circle.fill" ? 7 : 13)).foregroundStyle(tint)
            Text(text).font(.callout).lineLimit(1)
            Spacer(minLength: 8)
            actions()
        }.buttonStyle(.bordered).controlSize(.small)
            .padding(.horizontal, 10).frame(height: 32)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
    }

    private func tile(id: String, name: String, configuration: MenuConfiguration, current: String?) -> some View {
        let isCurrent = current == id
        let modified = current == nil && monitor.menuPresetSource == id
        let count = configuration.widgets.filter(\.enabled).count
        return Button { apply(id, name) } label: {
            VStack(alignment: .leading, spacing: 7) {
                Image(nsImage: MenuBarLayout(config: configuration).image(monitor))
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 22)
                    .frame(height: 36).padding(.horizontal, 8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 5) {
                    Text(name).font(.callout.weight(.medium)).lineLimit(1)
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).help("菜单栏正在使用")
                    } else if modified {
                        Circle().fill(Color.orange).frame(width: 6, height: 6).help("基于这个预设，有未保存的修改")
                    }
                    Spacer(minLength: 0)
                    Text(count == 0 ? "仅图标" : "\(count) 个小部件").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(8)
            .background(isCurrent ? Color.accentColor.opacity(0.12) : hovered == id ? Color.primary.opacity(0.06) : Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isCurrent ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isCurrent ? 1.5 : 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
            .help(isCurrent ? "“\(name)”正在使用" : "切换到“\(name)”")
            .accessibilityLabel(name).accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder private func savedActions(_ preset: MenuLayoutPreset, current: String?) -> some View {
        let id = preset.id.uuidString
        let index = monitor.menuPresets.firstIndex { $0.id == preset.id } ?? 0
        Button("应用") { apply(id, preset.name) }.disabled(current == id)
        Button("用当前布局更新") { monitor.updateMenuPreset(preset.id) }.disabled(preset.configuration.matches(monitor.menuConfiguration))
        Button("重命名…") { nameText = preset.name; renaming = preset.id }
        Button("复制") { monitor.saveMenuPreset(named: preset.name + " 副本", configuration: preset.configuration) }.disabled(full)
        Divider()
        Button("向前移动") { monitor.moveMenuPreset(preset.id, by: -1) }.disabled(index == 0)
        Button("向后移动") { monitor.moveMenuPreset(preset.id, by: 1) }.disabled(index == monitor.menuPresets.count - 1)
        Divider()
        Button("删除…", role: .destructive) { deleting = preset }
    }

    @ViewBuilder private func builtInActions(_ preset: (id: String, name: String, value: MenuConfiguration), current: String?) -> some View {
        Button("应用") { apply(preset.id, preset.name) }.disabled(current == preset.id)
        Button("复制到我的预设") { monitor.saveMenuPreset(named: preset.name, configuration: preset.value) }.disabled(full)
    }

    private func nameForm(title: String, action: String, commit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField("预设名称", text: Binding(get: { nameText }, set: { nameText = String($0.prefix(MenuLayoutPreset.maxName)) }))
                .textFieldStyle(.roundedBorder).frame(width: 220)
                .onSubmit(commit)
            Text("保存小部件的排列、样式和整体外观，最多 \(MenuLayoutPreset.maxName) 个字。").font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(width: 220, alignment: .leading)
            HStack {
                Spacer()
                Button("取消") { saving = false; renaming = nil }.keyboardShortcut(.cancelAction)
                Button(action, action: commit).keyboardShortcut(.defaultAction)
            }
        }.padding(14)
    }

    private func apply(_ id: String, _ name: String) {
        guard id != monitor.currentMenuPresetID else { return }
        let previous = monitor.menuConfiguration, source = monitor.menuPresetSource
        monitor.applyMenuPreset(id)
        undo = Undo(previous: previous, source: source, applied: monitor.menuConfiguration, name: name)
        onApply()
    }
    private func restore(_ undo: Undo) {
        monitor.menuConfiguration = undo.previous
        monitor.menuPresetSource = undo.source
        self.undo = nil
        onApply()
    }
}

/// Reorders while hovering, so the list shows the new order before the drop lands.
private struct WidgetDropDelegate: DropDelegate {
    let target: UUID
    let monitor: Monitor
    @Binding var dragging: UUID?
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = monitor.menuConfiguration.widgets.firstIndex(where: { $0.id == dragging }),
              let to = monitor.menuConfiguration.widgets.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            monitor.menuConfiguration.widgets.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

/// Picks a label symbol; the first entry restores the metric's own symbol.
struct SymbolMenu: View {
    @Binding var selection: String
    let fallback: String
    var body: some View {
        Menu {
            Button { selection = "" } label: { Label("默认", systemImage: fallback) }
            Divider()
            ForEach(MenuSymbols.labels, id: \.self) { name in
                Button { selection = name } label: { Label(name, systemImage: name) }
            }
        } label: {
            Image(systemName: selection.isEmpty ? fallback : selection)
        }.fixedSize().help("选择图标").accessibilityLabel("选择图标")
    }
}
