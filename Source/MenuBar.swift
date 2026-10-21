import AppKit
import SwiftUI
import CoreText

struct MenuColumn: Identifiable, Codable, Equatable {
    var id = UUID()
    var enabled = true
    var top: String
    var bottom: String
    var topLabel = ""
    var bottomLabel = ""
    var color = "system"
}

struct MenuConfiguration: Codable, Equatable {
    var layout = "double"
    var fontSize = 9.0
    var spacing = 10.0
    var icon = "none"
    var showLabels = true
    var decimals = false
    var rateUnit = "bytes"
    var columns: [MenuColumn] = [
        MenuColumn(top: "cpu", bottom: "memory"),
        MenuColumn(top: "upload", bottom: "download"),
        MenuColumn(top: "power", bottom: "cpuTemp")
    ]
    static var reference: Self { Self() }
    static var compact: Self {
        var c = Self(); c.columns = [MenuColumn(top: "power", bottom: "cpuTemp")]; return c
    }
    static var performance: Self {
        var c = Self()
        c.columns = [MenuColumn(top: "cpu", bottom: "gpu"), MenuColumn(top: "memory", bottom: "cpuTemp"), MenuColumn(top: "upload", bottom: "download")]
        return c
    }
    func sanitized() -> Self {
        var copy = self
        copy.fontSize = min(11, max(8, fontSize.isFinite ? fontSize : 9))
        copy.spacing = min(20, max(4, spacing.isFinite ? spacing : 10))
        copy.layout = layout == "single" ? "single" : "double"
        copy.rateUnit = rateUnit == "bits" ? "bits" : "bytes"
        if !["none", "waveform.path.ecg", "cpu", "cat"].contains(icon) { copy.icon = "none" }
        copy.columns = Array(columns.prefix(6)).map { column in
            var c = column
            if MenuMetric.find(c.top) == nil { c.top = "none" }
            if MenuMetric.find(c.bottom) == nil { c.bottom = "none" }
            c.topLabel = String(c.topLabel.prefix(8)); c.bottomLabel = String(c.bottomLabel.prefix(8))
            if !["system", "blue", "green", "orange", "purple", "red"].contains(c.color) { c.color = "system" }
            return c
        }
        return copy
    }
}

struct MenuMetric: Identifiable {
    let id: String
    let name: String
    let label: String
    static let all: [Self] = [
        .init(id: "none", name: "不显示", label: ""),
        .init(id: "cpu", name: "CPU 使用率", label: "CPU"),
        .init(id: "gpu", name: "GPU 使用率", label: "GPU"),
        .init(id: "memory", name: "内存使用率", label: "MEM"),
        .init(id: "memoryUsed", name: "已用内存", label: "MEM"),
        .init(id: "power", name: "系统功耗", label: "PWR"),
        .init(id: "cpuPower", name: "CPU 功耗", label: "CPU"),
        .init(id: "gpuPower", name: "GPU 功耗", label: "GPU"),
        .init(id: "cpuTemp", name: "CPU 温度", label: "CPU"),
        .init(id: "gpuTemp", name: "GPU 温度", label: "GPU"),
        .init(id: "upload", name: "上传速度", label: "↑"),
        .init(id: "download", name: "下载速度", label: "↓"),
        .init(id: "diskRead", name: "磁盘读取", label: "读"),
        .init(id: "diskWrite", name: "磁盘写入", label: "写"),
        .init(id: "diskFree", name: "磁盘可用", label: "SSD"),
        .init(id: "fan", name: "风扇转速", label: "FAN"),
        .init(id: "battery", name: "电池电量", label: "BAT"),
        .init(id: "codexQuota", name: "Codex 剩余额度", label: "CDX"),
        .init(id: "claudeQuota", name: "Claude 剩余额度", label: "CLD")
    ]
    static func find(_ id: String) -> Self? { all.first { $0.id == id } }
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
        case "power", "cpuPower", "gpuPower": return config.decimals ? "1500.0 W" : "1500 W"
        case "cpuTemp", "gpuTemp": return config.decimals ? "130.0°C" : "130°C"
        case "fan": return "20000 RPM"
        case "upload", "download", "diskRead", "diskWrite": return "1024.0 MB/s"
        case "memoryUsed", "diskFree": return "1024.0 GB"
        default: return ""
        }
    }
}

struct MenuBarLayout {
    struct Row {
        var metric: MenuMetric
        var label: String
        var labelWidth: CGFloat
        var valueWidth: CGFloat
        var valueFont: NSFont
        var width: CGFloat { labelWidth + (label.isEmpty ? 0 : 4) + valueWidth }
    }
    struct Column { var rows: [Row]; var color: String; var width: CGFloat }
    var columns: [Column]
    var font: NSFont
    var labelFont: NSFont
    var width: CGFloat
    var height: CGFloat
    var config: MenuConfiguration
    var showsIcon: Bool

    init(config original: MenuConfiguration, height: CGFloat = 22) {
        let c = original.sanitized()
        config = c; self.height = height
        // Fit two lines into the native menu bar without changing the chosen width per sample.
        let size = c.layout == "double" ? min(c.fontSize, 10) : c.fontSize
        font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        labelFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let numberFont = font, textFont = labelFont
        let cpuLabelWidth = ceil(("CPU" as NSString).size(withAttributes: [.font: textFont]).width)
        let cpuValueWidth = ceil((MenuMetric.find("cpu")!.widthSample(c) as NSString).size(withAttributes: [.font: numberFont]).width) + 2
        let rowWidth = cpuLabelWidth + 4 + cpuValueWidth
        let groupWidth = c.layout == "double" ? rowWidth : rowWidth * 2 + 8
        columns = c.columns.filter { $0.enabled }.compactMap { column in
            let pairs = [(column.top, column.topLabel), (column.bottom, column.bottomLabel)]
            let rows: [Row] = pairs.compactMap { id, custom in
                guard let metric = MenuMetric.find(id), id != "none" else { return nil }
                let label = c.showLabels ? (custom.isEmpty ? metric.label : custom) : ""
                let labelWidth = min(cpuLabelWidth, ceil((label as NSString).size(withAttributes: [.font: textFont]).width))
                let valueWidth = rowWidth - labelWidth - (label.isEmpty ? 0 : 4)
                let sampleWidth = ceil((metric.displayWidthSample(c) as NSString).size(withAttributes: [.font: numberFont]).width)
                let valueFont = NSFont.monospacedDigitSystemFont(ofSize: size * min(1, valueWidth / max(1, sampleWidth)), weight: .medium)
                return Row(metric: metric, label: label, labelWidth: labelWidth, valueWidth: valueWidth, valueFont: valueFont)
            }
            guard !rows.isEmpty else { return nil }
            return Column(rows: rows, color: column.color, width: groupWidth)
        }
        showsIcon = c.icon != "none" || columns.isEmpty
        width = ceil(8 + (showsIcon ? 20 : 0) + columns.map(\.width).reduce(0, +) + CGFloat(max(0, columns.count - 1)) * c.spacing)
    }
    func summary(_ monitor: Monitor) -> String {
        columns.flatMap(\.rows).map { "\($0.metric.name) \($0.metric.value(monitor, config: config))" }.joined(separator: "，")
    }
    func image(_ monitor: Monitor) -> NSImage {
        // Values affect only alignment inside each fixed slot, never its width.
        let strings = columns.map { $0.rows.map { $0.metric.displayValue(monitor, config: config) } }
        let monochrome = columns.allSatisfy { $0.color == "system" }
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            func color(_ name: String) -> NSColor {
                if monochrome { return .black }
                switch name {
                case "blue": return .systemBlue
                case "green": return .systemGreen
                case "orange": return .systemOrange
                case "purple": return .systemPurple
                case "red": return .systemRed
                default: return .labelColor
                }
            }
            var x: CGFloat = 4
            if showsIcon {
                let name = config.icon == "none" ? "waveform.path.ecg" : config.icon
                if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                    let icon = symbol.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) ?? symbol
                    icon.draw(in: NSRect(x: x, y: (height - 15) / 2, width: 15, height: 15))
                }
                x += 20
            }
            for (ci, column) in columns.enumerated() {
                var rowX = x
                for (ri, row) in column.rows.enumerated() {
                    let lineHeight = config.layout == "double" && column.rows.count == 2 ? height / 2 : height
                    let rowY = config.layout == "double" && column.rows.count == 2 ? height - CGFloat(ri + 1) * lineHeight : 0
                    let ascent = max(font.ascender, labelFont.ascender)
                    let descent = min(font.descender, labelFont.descender)
                    let baseline = rowY + (lineHeight - (ascent - descent)) / 2 - descent
                    let availableWidth = config.layout == "double" ? column.width : row.width
                    let valueX = rowX + availableWidth - row.valueWidth
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: NSRect(x: rowX, y: rowY, width: availableWidth, height: lineHeight)).addClip()
                    if let context = NSGraphicsContext.current?.cgContext {
                        // Both fonts share an explicit baseline; bounding-box origins differ
                        // between SF Mono labels and SF Pro monospaced digits.
                        func draw(_ text: String, font: NSFont, x: CGFloat, slotWidth: CGFloat, rightAligned: Bool) {
                            var line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
                                attributes: [.font: font, .foregroundColor: color(column.color)]))
                            if CTLineGetTypographicBounds(line, nil, nil, nil) > slotWidth {
                                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: color(column.color)]))
                                line = CTLineCreateTruncatedLine(line, Double(slotWidth), .end, token) ?? token
                            }
                            let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                            context.saveGState()
                            context.clip(to: CGRect(x: x, y: rowY, width: slotWidth, height: lineHeight))
                            context.textMatrix = .identity
                            context.textPosition = CGPoint(x: rightAligned ? x + slotWidth - advance : x, y: baseline)
                            CTLineDraw(line, context)
                            context.restoreGState()
                        }
                        draw(row.label, font: labelFont, x: rowX, slotWidth: row.labelWidth, rightAligned: false)
                        draw(strings[ci][ri], font: row.valueFont, x: valueX, slotWidth: row.valueWidth, rightAligned: true)
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    if config.layout == "single" { rowX += row.width + 8 }
                }
                x += column.width + config.spacing
            }
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
                Text("实时预览").font(.callout.weight(.medium))
                Text("修改即时生效").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                Image(nsImage: MenuBarLayout(config: monitor.menuConfiguration).image(monitor))
                    .padding(10)
            }.frame(height: 44)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            Text("宽度 \(Int(MenuBarLayout(config: monitor.menuConfiguration).width)) pt · 各组等宽，数值变化时保持固定")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MenuBarEditor: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("预设").font(.callout).foregroundStyle(.secondary)
                Button("参考布局") { monitor.menuConfiguration = .reference }
                Button("简洁") { monitor.menuConfiguration = .compact }
                Button("性能") { monitor.menuConfiguration = .performance }
            }
            PreferenceCard(title: "外观与格式") {
                HStack(alignment: .top, spacing: 16) {
                    PreferenceField(title: "布局") {
                        Picker("布局", selection: $monitor.menuConfiguration.layout) {
                            Text("双行").tag("double"); Text("单行").tag("single")
                        }.pickerStyle(.segmented)
                    }
                    PreferenceField(title: "图标") {
                        Picker("图标", selection: $monitor.menuConfiguration.icon) {
                            Text("不显示").tag("none"); Text("波形").tag("waveform.path.ecg")
                            Text("芯片").tag("cpu"); Text("猫").tag("cat")
                        }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    PreferenceField(title: "字号") {
                        Picker("字号", selection: $monitor.menuConfiguration.fontSize) {
                            ForEach([8.0, 9.0, 10.0], id: \.self) { Text("\(Int($0)) pt").tag($0) }
                        }
                    }
                    PreferenceField(title: "组间距") {
                        Picker("组间距", selection: $monitor.menuConfiguration.spacing) {
                            ForEach([4.0, 6.0, 10.0, 14.0, 20.0], id: \.self) { Text("\(Int($0)) pt").tag($0) }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    PreferenceField(title: "网速单位") {
                        Picker("网速单位", selection: $monitor.menuConfiguration.rateUnit) {
                            Text("字节 / 秒（B/s）").tag("bytes"); Text("比特 / 秒（b/s）").tag("bits")
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("显示标签", isOn: $monitor.menuConfiguration.showLabels)
                        Toggle("保留一位小数", isOn: $monitor.menuConfiguration.decimals)
                    }.toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 10) {
                Text("显示分组").font(.callout.weight(.medium))
                Text("\(monitor.menuConfiguration.columns.count) / 6").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { monitor.menuConfiguration.columns.append(MenuColumn(top: "gpu", bottom: "gpuTemp")) } label: { Label("添加分组", systemImage: "plus") }
                    .disabled(monitor.menuConfiguration.columns.count >= 6)
            }
            ForEach($monitor.menuConfiguration.columns) { $column in
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Text("第 \((monitor.menuConfiguration.columns.firstIndex(where: { $0.id == column.id }) ?? 0) + 1) 组")
                                .font(.callout.weight(.medium))
                            Toggle("显示", isOn: $column.enabled).toggleStyle(.checkbox)
                            Spacer()
                            Button { move(column.id, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(monitor.menuConfiguration.columns.first?.id == column.id)
                                .help("向前移动").accessibilityLabel("向前移动分组")
                            Button { move(column.id, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(monitor.menuConfiguration.columns.last?.id == column.id)
                                .help("向后移动").accessibilityLabel("向后移动分组")
                            Button { monitor.menuConfiguration.columns.removeAll { $0.id == column.id } } label: { Image(systemName: "minus.circle") }
                                .help("移除分组").accessibilityLabel("移除分组")
                        }
                        metricPicker(monitor.menuConfiguration.layout == "double" ? "上行指标" : "第一项", metric: $column.top, label: $column.topLabel)
                        metricPicker(monitor.menuConfiguration.layout == "double" ? "下行指标" : "第二项", metric: $column.bottom, label: $column.bottomLabel)
                        HStack(spacing: 8) {
                            Text("颜色").font(.caption).foregroundStyle(.secondary)
                            Picker("颜色", selection: $column.color) {
                                Text("跟随系统").tag("system"); Text("蓝色").tag("blue")
                                Text("绿色").tag("green"); Text("橙色").tag("orange")
                                Text("紫色").tag("purple"); Text("红色").tag("red")
                            }.labelsHidden().frame(width: 130)
                        }
                    }.padding(8)
                }
            }
            Text("标签留空使用默认文字，最多 8 个字符。全部关闭时保留图标入口。菜单栏空间不足时可减少分组或选择简洁布局。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.controlSize(.small)
    }
    private func metricPicker(_ title: String, metric: Binding<String>, label: Binding<String>) -> some View {
        HStack(alignment: .top, spacing: 16) {
            PreferenceField(title: title) {
                Picker(title, selection: metric) { ForEach(MenuMetric.all) { Text($0.name).tag($0.id) } }
            }
            PreferenceField(title: "自定义标签") {
                TextField("默认：\(MenuMetric.find(metric.wrappedValue)?.label ?? "无")", text: Binding(get: { label.wrappedValue }, set: { label.wrappedValue = String($0.prefix(8)) }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("\(title)的自定义标签")
            }
        }
    }
    private func move(_ id: UUID, by offset: Int) {
        guard let index = monitor.menuConfiguration.columns.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard monitor.menuConfiguration.columns.indices.contains(destination) else { return }
        monitor.menuConfiguration.columns.swapAt(index, destination)
    }
}
