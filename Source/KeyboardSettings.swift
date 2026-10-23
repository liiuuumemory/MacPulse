import SwiftUI
import AppKit

// Keep the property wrapper available when building with Command Line Tools.
private typealias KeyboardViewState<Value> = SwiftUI.State<Value>

// MARK: Peripherals overview

/// Settings › 外设: one card per mouse and keyboard; drivers open on their own page.
struct PeripheralsSettingsView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var mice: MouseCenter
    @ObservedObject var keyboards: KeyboardCenter
    var open: (String) -> Void
    private var batteryOnly: [PeripheralBattery] { monitor.peripherals.filter { $0.key.hasPrefix("bt-") } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if mice.busy || keyboards.busy { ProgressView().controlSize(.small) }
                if !mice.message.isEmpty {
                    Label(mice.message, systemImage: mice.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(mice.failed ? Color.orange : Color.green).lineLimit(2)
                }
                Spacer()
                Button { mice.refresh(); keyboards.refresh() } label: { Label("重新读取", systemImage: "arrow.clockwise") }.disabled(mice.busy)
            }
            section("鼠标") {
                ForEach(mice.wl) { device in
                    PeripheralRow(symbol: "computermouse.fill", title: device.name,
                                  subtitle: "WLMOUSE · \(device.connection)" + (device.battery.map { " · 电量 \($0.percent)%" } ?? "") + dpi(device.settings),
                                  action: { open("device:" + WLMouseModel.batteryKey(productID: device.id)) })
                }
                ForEach(mice.logi) { device in
                    PeripheralRow(symbol: "computermouse", title: device.name,
                                  subtitle: "罗技 HID++" + (device.battery.map { " · 电量 \($0.percent)%" } ?? "") + (device.dpi.map { " · \($0) DPI" } ?? ""),
                                  action: { open("device:logi-" + device.id) })
                }
                ForEach(mice.asleep, id: \.self) { name in
                    PeripheralRow(symbol: "moon.zzz.fill", title: name, subtitle: "接收器已连接，鼠标正在休眠。动一下鼠标，几秒内会自动读取", action: nil)
                }
                ForEach(batteryOnly.filter { !$0.isKeyboard }) { device in
                    PeripheralRow(symbol: device.symbol, title: device.name, subtitle: "蓝牙 · 电量 \(Format.number(device.percent, suffix: "%")) · 只读电量", action: nil)
                }
                if mice.loaded && mice.wl.isEmpty && mice.logi.isEmpty && mice.asleep.isEmpty && !batteryOnly.contains(where: { !$0.isKeyboard }) {
                    Text("没有找到鼠标。确认接收器已插好、鼠标已唤醒后点“重新读取”。").font(.callout).foregroundStyle(.secondary)
                }
            }
            section("键盘") {
                ForEach(keyboards.keyboards) { keyboard in
                    let state = keyboards.state(keyboard.id)
                    PeripheralRow(symbol: "keyboard", title: keyboard.name,
                                  subtitle: keyboards.problems[keyboard.id].map { "有线连接 · \($0)" } ?? Self.keyboardSummary(keyboard, state),
                                  action: keyboard.model == nil ? nil : { open("device:kbd-" + keyboard.id) })
                }
                ForEach(batteryOnly.filter(\.isKeyboard)) { device in
                    PeripheralRow(symbol: "keyboard", title: device.name, subtitle: "蓝牙 · 电量 \(Format.number(device.percent, suffix: "%")) · 只读电量，没有驱动", action: nil)
                }
                if keyboards.keyboards.isEmpty && !batteryOnly.contains(where: \.isKeyboard) {
                    Text("没有找到键盘。").font(.callout).foregroundStyle(.secondary)
                }
            }
            PeripheralSupportCard()
            if mice.logiPermissionDenied {
                PreferenceCard(title: "罗技设备需要输入监控权限") {
                    Text("macOS 要求先允许 MacPulse 使用“输入监控”，才能打开罗技接收器的设置通道。MacPulse 只发送 HID++ 设置命令，不记录按键。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("请求权限") { LogitechHIDPP.requestAccess() }
                        Button("打开系统设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!) }
                    }
                }
            }
        }
        .onAppear { if !mice.loaded { mice.refresh() }; keyboards.refreshIfStale(30) }
        .onReceive(DeviceIO.retryTick) { _ in if !mice.asleep.isEmpty && !mice.busy { mice.refresh() } }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
    private func dpi(_ s: WLMouseSettings) -> String {
        s.stages.indices.contains(s.activeStage - 1) ? " · \(s.stages[s.activeStage - 1]) DPI" : ""
    }
    static func keyboardSummary(_ keyboard: WiredKeyboard, _ state: KeyboardState?) -> String {
        guard let model = keyboard.model else { return "有线连接 · 不支持自定义" }
        var parts = ["有线连接", "VIA"]
        if let state {
            parts.append("\(state.layers) 层")
            if !model.knobs.isEmpty { parts.append("\(model.knobs.count) 个旋钮") }
            parts.append("宏 \(state.macrosInUse) / \(state.macroCount)")
            if let lighting = model.lighting, let values = state.lighting {
                parts.append(values.effect == 0 ? "灯光关" : (lighting.indicatorOnly ? "指示灯 " : "灯效 ") + lighting.effectName(values.effect))
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// One device on the overview: what it is and how it is connected; "自定义" opens its page.
struct PeripheralRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let action: (() -> Void)?
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action: action) { HStack(spacing: 3) { Text("自定义"); Image(systemName: "chevron.right").font(.caption.weight(.semibold)) } }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).settingsCard()
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }
}

struct PeripheralSupportCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("支持的设备").font(.headline)
            row("WLMOUSE 万灵", badge: "已实测 花•兽 Mini PRO", tested: true,
                devices: "花•兽 Mini / Mini PRO / X / X PRO / X V2 / MAX、幻 / 幻 M、影、剑 X、行者、BEAST MIAO、BEAST G（8K / 4K / 1K 接收器或有线）")
            row("罗技 Logitech", badge: "未经实测", tested: false,
                devices: "支持 HID++ 2.0 的鼠标：电量、DPI、SmartShift、滚轮方向")
            row("VIA 键盘", badge: "已实测读写", tested: true,
                devices: "BUFF67v3r2、Binepad BNK16（有线）：改键（含多层与旋钮）、宏、灯光")
            row("其他外设", badge: "仅电量或连接状态", tested: true,
                devices: "向系统报告电量的蓝牙外设，如妙控鼠标、妙控键盘、妙控板；其他 USB 键盘只显示连接状态")
            Text("设置保存在设备里，换电脑也有效。固件升级、重新配对、恢复出厂请用官方驱动；官方驱动打开时不要在这里同时修改，以免互相覆盖。")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).settingsCard()
    }
    private func row(_ title: String, badge: String, tested: Bool, devices: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title).font(.body.weight(.medium))
                Text(badge).font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background((tested ? Color.green : Color.orange).opacity(0.15), in: Capsule())
                    .foregroundStyle(tested ? Color.green : Color.orange)
            }
            Text(devices).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Second-level page

/// Settings › 外设 › one device: a back link and the device's driver settings.
struct PeripheralDetailPage: View {
    @ObservedObject var monitor: Monitor
    let device: String
    var back: () -> Void
    private var title: String {
        if device.hasPrefix("kbd-") { return monitor.keyboards.keyboard(String(device.dropFirst(4)))?.name ?? "键盘" }
        if let state = monitor.mice.wlState(forKey: device) { return state.name }
        if device.hasPrefix("logi-") { return monitor.mice.logi.first { "logi-" + $0.id == device }?.name ?? "罗技鼠标" }
        return "外设"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: back) { HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("外设") } }
                    .buttonStyle(.link)
                HStack(spacing: 12) {
                    SettingsIconTile(symbol: device.hasPrefix("kbd-") ? "keyboard" : "computermouse", color: SettingsGroup.group(of: "mouse")?.color ?? .systemBlue, size: 38)
                    Text(title).font(.system(size: 24, weight: .semibold))
                }
                Divider().padding(.top, 4)
            }
            if device.hasPrefix("kbd-") {
                let id = String(device.dropFirst(4))
                if let keyboard = monitor.keyboards.keyboard(id), let model = keyboard.model, let state = monitor.keyboards.state(id) {
                    KeyboardEditor(center: monitor.keyboards, keyboard: keyboard, model: model, saved: state)
                } else if let problem = monitor.keyboards.problems[id] {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("重新读取") { monitor.keyboards.refresh([id]) }
                } else if monitor.keyboards.keyboard(id) == nil {
                    Text("这把键盘已断开。").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在读取键盘设置…").foregroundStyle(.secondary) }
                        .onAppear { monitor.keyboards.refreshIfStale(30) }
                }
            } else {
                MouseSettingsView(center: monitor.mice, device: device)
            }
        }
    }
}

// MARK: Keyboard editor

struct KeyboardEditor: View {
    @ObservedObject var center: KeyboardCenter
    let keyboard: WiredKeyboard
    let model: KeyboardModel
    let saved: KeyboardState
    @KeyboardViewState private var tab = KeyboardEditor.initialTab
    @KeyboardViewState private var draft: KeyboardState?
    @KeyboardViewState private var layer = CommandLine.arguments.firstIndex(of: "--keyboard-layer").flatMap { CommandLine.arguments.count > $0 + 1 ? Int(CommandLine.arguments[$0 + 1]) : nil } ?? 0
    @KeyboardViewState private var selection: KeySlot?
    @KeyboardViewState private var restoring: URL?
    /// `--keyboard-tab keymap|macros|lighting` and `--keyboard-select r,c` pick what a snapshot shows.
    static let initialTab: String = CommandLine.arguments.firstIndex(of: "--keyboard-tab").flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil } ?? "keymap"
    private var current: KeyboardState { draft ?? saved }
    private var keyChanges: Int {
        var count = 0
        for (l, layer) in current.keymap.enumerated() where saved.keymap.indices.contains(l) {
            count += zip(layer, saved.keymap[l]).filter { $0 != $1 }.count
        }
        for (l, knobs) in current.encoders.enumerated() where saved.encoders.indices.contains(l) {
            count += zip(knobs, saved.encoders[l]).filter { $0 != $1 }.count
        }
        return count
    }
    private var macroChanges: Int { zip(current.macros, saved.macros).filter { $0 != $1 }.count }
    private var lightingChanged: Bool { current.lighting != saved.lighting }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    Text("改键").tag("keymap")
                    Text("宏").tag("macros")
                    if model.lighting != nil { Text(model.lighting!.indicatorOnly ? "指示灯" : "灯光").tag("lighting") }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text(PeripheralsSettingsView.keyboardSummary(keyboard, saved)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if !center.message.isEmpty {
                Label(center.message, systemImage: center.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(center.failed ? Color.orange : Color.green)
            }
            switch tab {
            case "macros": macroTab
            case "lighting": lightingTab
            default: keymapTab
            }
            footer
        }
        .onAppear {
            if let flag = CommandLine.arguments.firstIndex(of: "--keyboard-select"), CommandLine.arguments.count > flag + 1 {
                let value = CommandLine.arguments[flag + 1]
                if value.hasPrefix("knob") { selection = .knob(Int(value.dropFirst(4)) ?? 0, 1) }
                else if let key = (model.keys + model.knobs.compactMap(\.press)).first(where: { $0.id == value }) { selection = .key(key) }
            }
        }
        .onChange(of: saved) { _, fresh in if draft == fresh { draft = nil } }
        // A lighting preview that was not applied goes back to what the board has saved.
        .onDisappear { if let lighting = saved.lighting, draft?.lighting != nil, draft?.lighting != lighting { center.previewLighting(keyboard.id, lighting) } }
        .confirmationDialog("用这份备份覆盖键盘当前的键位、旋钮、宏和灯光？", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("恢复") { if let restoring { center.restore(keyboard.id, from: restoring) }; restoring = nil }
            Button("取消", role: .cancel) { restoring = nil }
        } message: {
            Text("恢复会和普通修改一样写入并读回校验。")
        }
    }

    private func edit(_ change: (inout KeyboardState) -> Void) {
        var next = current
        change(&next)
        draft = next == saved ? nil : next
    }

    // MARK: Keymap

    private var keymapTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("层").font(.headline)
                Picker("层", selection: $layer) {
                    ForEach(0..<current.layers, id: \.self) { Text("\($0)").tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text(layer == 0 ? "基础层：平时按下的键" : "按住切层键时生效，▽ 表示沿用下层").font(.subheadline).foregroundStyle(.secondary)
            }
            KeyboardDrawing(model: model, state: current, saved: saved, layer: layer, selection: $selection) { slot, code in
                edit { state in
                    switch slot {
                    case .key(let key): state.keymap[layer][key.row * model.cols + key.col] = code
                    case .knob(let index, let direction): state.encoders[layer][index][direction] = code
                    }
                }
            }
            .padding(14).frame(maxWidth: .infinity).settingsCard()
            HStack(spacing: 16) {
                legend(Color.accentColor, "已选中")
                legend(.orange, "已修改，未写入")
                Text("▽ 透明").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("点一个键或旋钮来修改").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).strokeBorder(color, lineWidth: 1.5).frame(width: 14, height: 12)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Macros

    private var macroTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("宏").font(.headline)
                Text("在改键里选 M0–M\(current.macroCount - 1) 即可把宏放到某个键上").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                let used = current.macroBytes
                Text("已用 \(used) / \(current.macroBufferSize) 字节").font(.subheadline).monospacedDigit()
                    .foregroundStyle(used > current.macroBufferSize ? Color.red : Color.secondary)
            }
            UsageBar(fraction: Double(current.macroBytes) / Double(max(1, current.macroBufferSize)), color: .accentColor, warnAbove: 0.9)
            VStack(spacing: 0) {
                ForEach(0..<current.macroCount, id: \.self) { index in
                    if index > 0 { Divider().padding(.leading, 12) }
                    MacroRow(index: index, steps: Binding(get: { current.macros.indices.contains(index) ? current.macros[index] : [] },
                                                          set: { steps in edit { $0.macros[index] = steps } }),
                             changed: current.macros[index] != saved.macros[index], model: model)
                }
            }.settingsCard()
            Text("文字只能是英文字母、数字和符号（键盘固件按美式键位逐个按出）；中文请用输入法切换后输入，或用组合键代替。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Lighting

    @ViewBuilder private var lightingTab: some View {
        if let lighting = model.lighting {
            LightingControls(lighting: lighting, values: Binding(get: { current.lighting ?? KeyboardLightingValues() },
                                                                  set: { values in edit { $0.lighting = values }; center.previewLighting(keyboard.id, values) }),
                             compact: false)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).settingsCard()
            Text(lighting.indicatorOnly ? "这把键盘只有一颗指示灯。拖动时指示灯会实时变化，点“应用到键盘”才保存。"
                                        : "拖动时灯光会实时变化，点“应用到键盘”才保存；点“还原”恢复原来的灯光。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        let total = keyChanges + macroChanges + (lightingChanged ? 1 : 0)
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 10) {
                if total > 0 {
                    Label(changeSummary, systemImage: "pencil.circle").font(.subheadline).foregroundStyle(.orange)
                } else {
                    Text("与键盘当前设置一致").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("备份") {
                    Text("每次启动后第一次写入前，会自动备份整套键位、旋钮、宏和灯光")
                    Divider()
                    let backups = center.backups(keyboard.id)
                    Menu("从备份恢复") {
                        ForEach(backups, id: \.self) { url in Button(Self.backupTitle(url)) { restoring = url } }
                        if backups.isEmpty { Text("还没有备份") }
                    }.disabled(backups.isEmpty || center.busy)
                    Button("在访达中显示备份") {
                        let folder = KeyboardBackup.folder(model)
                        if FileManager.default.fileExists(atPath: folder.path) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }.disabled(backups.isEmpty)
                }.fixedSize()
                Button("还原") {
                    draft = nil
                    if let lighting = saved.lighting { center.previewLighting(keyboard.id, lighting) }
                }.disabled(total == 0)
                Button("应用到键盘") { center.apply(keyboard.id, current) }.disabled(total == 0 || center.busy)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
    /// "2026-10-23 173012.json" reads as "2026-10-23 17:30:12".
    static func backupTitle(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: " ")
        guard parts.count == 2, parts[1].count == 6 else { return name }
        let t = Array(parts[1])
        return "\(parts[0]) \(String(t[0...1])):\(String(t[2...3])):\(String(t[4...5]))"
    }
    private var changeSummary: String {
        var parts: [String] = []
        if keyChanges > 0 { parts.append("\(keyChanges) 个键") }
        if macroChanges > 0 { parts.append("\(macroChanges) 个宏") }
        if lightingChanged { parts.append("灯光") }
        return parts.joined(separator: "、") + "已修改，未写入键盘"
    }
}

/// A key or one direction of a knob (0 counter-clockwise, 1 clockwise).
enum KeySlot: Hashable {
    case key(KeyboardKey)
    case knob(Int, Int)
}

// MARK: Drawing

/// The board drawn to scale from its VIA layout; each key shows the keycode on the chosen layer.
struct KeyboardDrawing: View {
    let model: KeyboardModel
    let state: KeyboardState
    let saved: KeyboardState
    let layer: Int
    @Binding var selection: KeySlot?
    var assign: (KeySlot, UInt16) -> Void
    private let gap: CGFloat = 4
    var body: some View {
        GeometryReader { geometry in
            let unit = geometry.size.width / model.width
            ZStack(alignment: .topLeading) {
                ForEach(model.keys) { key in keycap(key, unit: unit).offset(x: key.x * unit, y: key.y * unit) }
                ForEach(model.knobs) { knob in knobView(knob, unit: unit).offset(x: knob.x * unit, y: knob.y * unit) }
            }
        }
        // Keeps the board's own proportions, so the frame is exactly as tall as the keys.
        .aspectRatio(model.width / model.height, contentMode: .fit)
        .frame(maxWidth: 54 * model.width)
    }

    private func code(_ key: KeyboardKey, in state: KeyboardState) -> UInt16 { state.keycode(layer, key, cols: model.cols) }
    private func isSelected(_ slot: KeySlot) -> Binding<Bool> {
        Binding(get: { selection == slot }, set: { if !$0, selection == slot { selection = nil } })
    }

    private func keycap(_ key: KeyboardKey, unit: CGFloat) -> some View {
        let value = code(key, in: state)
        let label = Keycode.describe(value, model: model)
        let changed = value != code(key, in: saved)
        let selected = selection == .key(key)
        let wide = key.w > 1.2 || (0xE0...0xE7).contains(value)
        return Button { selection = .key(key) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: unit * 0.14, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(wide ? 0.11 : 0.06))
                RoundedRectangle(cornerRadius: unit * 0.14, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : changed ? Color.orange : Color.primary.opacity(0.12), lineWidth: selected || changed ? 1.6 : 0.6)
                Text(label.short)
                    .font(.system(size: unit * (label.short.count > 3 ? 0.22 : 0.3), weight: .medium))
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    .foregroundStyle(value == 1 ? Color.secondary : Color.primary)
                    .padding(3)
            }
            .frame(width: key.w * unit - gap, height: key.h * unit - gap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label.name)
        .popover(isPresented: isSelected(.key(key)), arrowEdge: .bottom) {
            KeyPicker(model: model, layers: state.layers, macros: state.macroCount, current: value) { assign(.key(key), $0) }
        }
        .accessibilityLabel("位置 \(key.id)：\(label.name)")
    }

    private func knobView(_ knob: KeyboardKnob, unit: CGFloat) -> some View {
        let size = knob.size * unit - gap
        let codes = state.encoders.indices.contains(layer) && state.encoders[layer].indices.contains(knob.index) ? state.encoders[layer][knob.index] : [0, 0]
        let old = saved.encoders.indices.contains(layer) && saved.encoders[layer].indices.contains(knob.index) ? saved.encoders[layer][knob.index] : [0, 0]
        let ccw = Keycode.describe(codes[0], model: model).short, cw = Keycode.describe(codes[1], model: model).short
        let selected: Bool = { if case .knob(knob.index, _) = selection { return true }; return false }()
        let press = knob.press.map { code($0, in: state) }
        return Button { selection = .knob(knob.index, 1) } label: {
            ZStack {
                Circle().fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.09))
                Circle().strokeBorder(selected ? Color.accentColor : codes != old ? Color.orange : Color.primary.opacity(0.15), lineWidth: selected || codes != old ? 1.6 : 0.8)
                VStack(spacing: knob.size > 1 ? 6 : 1) {
                    Text("↺ " + ccw).font(.system(size: unit * (knob.size > 1 ? 0.3 : 0.2), weight: .medium))
                    Text("↻ " + cw).font(.system(size: unit * (knob.size > 1 ? 0.3 : 0.2), weight: .medium))
                    if knob.size > 1 { Text("旋钮 \(knob.index + 1)").font(.system(size: unit * 0.22)).foregroundStyle(.secondary) }
                    else if let press { Text("按 " + Keycode.describe(press, model: model).short).font(.system(size: unit * 0.18)).foregroundStyle(.secondary) }
                }.lineLimit(1).minimumScaleFactor(0.6).padding(knob.size > 1 ? 10 : 5)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("旋钮 \(knob.index + 1)：逆时针 \(Keycode.describe(codes[0], model: model).name)，顺时针 \(Keycode.describe(codes[1], model: model).name)")
        .popover(isPresented: Binding(get: { selected }, set: { if !$0, selected { selection = nil } }), arrowEdge: .bottom) {
            KnobPicker(model: model, layers: state.layers, macros: state.macroCount, knob: knob, codes: codes, press: press, selection: $selection) { slot, code in assign(slot, code) }
        }
    }
}

/// A knob's three actions: turn left, turn right and, on push knobs, press.
struct KnobPicker: View {
    let model: KeyboardModel
    let layers: Int
    let macros: Int
    let knob: KeyboardKnob
    let codes: [UInt16]
    let press: UInt16?
    @Binding var selection: KeySlot?
    var assign: (KeySlot, UInt16) -> Void
    @KeyboardViewState private var part = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $part) {
                Text("逆时针 ↺").tag(0)
                Text("顺时针 ↻").tag(1)
                if knob.press != nil { Text("按下").tag(2) }
            }.pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top], 12)
            let current: UInt16 = part == 2 ? (press ?? 0) : codes[part]
            KeyPicker(model: model, layers: layers, macros: macros, current: current) { code in
                if part == 2, let key = knob.press { assign(.key(key), code) } else { assign(.knob(knob.index, part), code) }
            }
        }
    }
}

// MARK: Key picker

/// Chooses a keycode: by category, by search, by pressing the key, or by building a combination.
struct KeyPicker: View {
    let model: KeyboardModel
    let layers: Int
    let macros: Int
    let current: UInt16
    var pick: (UInt16) -> Void
    @KeyboardViewState private var category = "basic"
    @KeyboardViewState private var search = ""
    @KeyboardViewState private var capturing = false
    @KeyboardViewState private var monitor: Any?
    @KeyboardViewState private var layerKind: UInt16 = 0x5220
    @KeyboardViewState private var mods: UInt16 = 0
    @KeyboardViewState private var rightSide = false
    @KeyboardViewState private var advancedKind = "mods"
    @KeyboardViewState private var tapLayer = 1
    @KeyboardViewState private var baseKey: UInt16 = 0x04
    @KeyboardViewState private var hex = ""
    private static let categories: [(String, String)] = [("basic", "基础"), ("numpad", "小键盘"), ("mods", "修饰"), ("media", "媒体"), ("layers", "层"),
                                                          ("macros", "宏"), ("lighting", "灯光"), ("custom", "专属"), ("advanced", "组合")]
    private var currentName: String { Keycode.describe(current, model: model).name }
    private var entries: [Keycode.Entry] {
        if !search.isEmpty {
            let all = Keycode.basic + Keycode.numpad + Keycode.modifiers + Keycode.media + Keycode.lighting + macroEntries + customEntries
            return all.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.short.localizedCaseInsensitiveContains(search) }
        }
        switch category {
        case "numpad": return Keycode.numpad
        case "mods": return Keycode.modifiers
        case "media": return Keycode.media
        case "lighting": return Keycode.lighting
        case "macros": return macroEntries
        case "custom": return customEntries
        default: return Keycode.basic
        }
    }
    private var macroEntries: [Keycode.Entry] {
        (0..<macros).map { Keycode.Entry(code: model.macroBase + UInt16($0), short: "M\($0)", name: "宏 \($0)") }
    }
    private var customEntries: [Keycode.Entry] {
        model.custom.enumerated().filter { !$0.element.hidden }.map { Keycode.Entry(code: model.customBase + UInt16($0.offset), short: $0.element.short, name: $0.element.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("当前：\(currentName)").font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                Button("无") { pick(0) }.help("这个键不发送任何东西")
                Button("透明 ▽") { pick(1) }.help("沿用下层同一位置的键")
            }
            HStack(spacing: 8) {
                TextField("搜索键名，如 F5、音量、Command", text: $search).textFieldStyle(.roundedBorder)
                Button { capturing ? stopCapture() : startCapture() } label: {
                    Label(capturing ? "请按键…" : "按键录入", systemImage: capturing ? "record.circle" : "keyboard")
                }.tint(capturing ? .red : nil).help("按下 Mac 键盘上的一个键，直接选中对应键码")
            }
            if search.isEmpty {
                // Buttons rather than a segmented control: nine segments outgrow the popover under Liquid Glass.
                HStack(spacing: 4) {
                    ForEach(Self.categories.filter { $0.0 != "custom" || !customEntries.isEmpty }, id: \.0) { item in
                        Button { category = item.0 } label: {
                            Text(item.1).font(.system(size: 12, weight: category == item.0 ? .semibold : .regular))
                                .padding(.horizontal, 8).frame(height: 24)
                                .background(Capsule().fill(category == item.0 ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                                .contentShape(Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(category == item.0 ? .isSelected : [])
                    }
                }
            }
            Group {
                if search.isEmpty && category == "layers" { layerGrid }
                else if search.isEmpty && category == "advanced" { advanced }
                else { grid(entries) }
            }.frame(minHeight: 150, alignment: .top)
        }
        .padding(14)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear(perform: stopCapture)
    }

    /// Every key of the category at once, so the popover needs no scroll bar of its own.
    private func grid(_ items: [Keycode.Entry]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 5)], spacing: 5) {
                ForEach(items) { entry in
                    Button { pick(entry.code) } label: {
                        Text(entry.short).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(entry.code == current ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(entry.name)
                }
        }
    }

    private var layerGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $layerKind) {
                ForEach(Keycode.layerKinds, id: \.base) { Text($0.short).tag($0.base) }
            }.pickerStyle(.segmented).labelsHidden()
            Text(Keycode.layerKinds.first { $0.base == layerKind }?.name ?? "").font(.caption).foregroundStyle(.secondary)
            grid((0..<layers).map { Keycode.Entry(code: layerKind + UInt16($0), short: "层 \($0)", name: Keycode.describe(layerKind + UInt16($0), model: model).name) })
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $advancedKind) {
                Text("组合键").tag("mods"); Text("按住修饰 / 点按").tag("modtap"); Text("按住切层 / 点按").tag("layertap"); Text("键码").tag("hex")
            }.pickerStyle(.segmented).labelsHidden()
            switch advancedKind {
            case "hex":
                HStack {
                    TextField("十六进制，如 5221", text: $hex).textFieldStyle(.roundedBorder).frame(width: 160).monospaced()
                    let value = UInt16(hex.replacingOccurrences(of: "0x", with: ""), radix: 16)
                    Button("使用") { if let value { pick(value) } }.disabled(value == nil || value.map { Keycode.blocked($0, model: model) } ?? true)
                    if let value { Text(Keycode.describe(value, model: model).name).font(.caption).foregroundStyle(.secondary) }
                }
            case "layertap":
                HStack {
                    Stepper("按住切到层 \(tapLayer)", value: $tapLayer, in: 0...min(15, layers - 1))
                    basePicker
                }
                Button("使用：按住切到层 \(tapLayer)，点按 \(Keycode.describe(baseKey, model: model).name)") { pick(0x4000 | UInt16(tapLayer) << 8 | baseKey) }
            default:
                HStack(spacing: 6) {
                    ForEach(Keycode.modBits, id: \.bit) { bit in
                        Toggle(bit.symbol + " " + bit.name, isOn: Binding(get: { mods & bit.bit != 0 }, set: { mods = $0 ? mods | bit.bit : mods & ~bit.bit }))
                            .toggleStyle(.button)
                    }
                    Toggle("右侧", isOn: $rightSide).toggleStyle(.checkbox)
                }
                basePicker
                let modValue = mods | (rightSide ? 0x10 : 0)
                let value = (advancedKind == "modtap" ? 0x2000 : 0) | modValue << 8 | baseKey
                Button("使用：" + Keycode.describe(value, model: model).name) { pick(value) }.disabled(mods == 0)
            }
            Spacer(minLength: 0)
        }
    }
    private var basePicker: some View {
        Picker("点按", selection: $baseKey) {
            ForEach(Keycode.basic + Keycode.numpad) { Text($0.name).tag($0.code) }
        }.fixedSize()
    }

    private func startCapture() {
        capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard let usage = Keycode.fromMac[event.keyCode] else { return event }
            if event.type == .flagsChanged, !(0xE0...0xE7).contains(usage) { return event }
            pick(UInt16(usage)); stopCapture()
            return nil
        }
    }
    private func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; capturing = false
    }
}

// MARK: Macros

struct MacroRow: View {
    let index: Int
    @Binding var steps: [MacroStep]
    let changed: Bool
    let model: KeyboardModel
    /// `--keyboard-macro <n>` opens that macro for a snapshot.
    @KeyboardViewState private var expanded = false
    init(index: Int, steps: Binding<[MacroStep]>, changed: Bool, model: KeyboardModel) {
        self.index = index; self._steps = steps; self.changed = changed; self.model = model
        let flag = CommandLine.arguments.firstIndex(of: "--keyboard-macro")
        _expanded = State(initialValue: flag.map { CommandLine.arguments.count > $0 + 1 && Int(CommandLine.arguments[$0 + 1]) == index } ?? false)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("M\(index)").font(.system(.body, design: .monospaced).weight(.semibold)).frame(width: 36, alignment: .leading)
                Text(steps.isEmpty ? "空" : summary).font(.callout).foregroundStyle(steps.isEmpty ? .secondary : .primary).lineLimit(1)
                if changed { Image(systemName: "pencil.circle.fill").foregroundStyle(.orange).help("已修改，未写入") }
                Spacer()
                Button(expanded ? "完成" : "编辑") { withAnimation(.snappy) { expanded.toggle() } }.controlSize(.small)
            }
            if expanded {
                ForEach(Array(steps.enumerated()), id: \.offset) { offset, step in
                    HStack(spacing: 8) {
                        stepEditor(offset, step)
                        Spacer()
                        Button { steps.remove(at: offset) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("删除这一步")
                    }
                }
                Menu {
                    Button("输入文字") { steps.append(.text("")) }
                    Button("点按一个键") { steps.append(.tap(0x04)) }
                    Button("按下（不松开）") { steps.append(.down(0xE3)) }
                    Button("松开") { steps.append(.up(0xE3)) }
                    Button("等待") { steps.append(.delay(100)) }
                } label: { Label("添加一步", systemImage: "plus") }.fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var summary: String {
        steps.map { step in
            switch step {
            case .text(let text): return "“\(text)”"
            case .tap(let code): return Keycode.describe(UInt16(code), model: model).short
            case .down(let code): return Keycode.describe(UInt16(code), model: model).short + "↓"
            case .up(let code): return Keycode.describe(UInt16(code), model: model).short + "↑"
            case .delay(let ms): return "\(ms) ms"
            }
        }.joined(separator: " → ")
    }
    @ViewBuilder private func stepEditor(_ offset: Int, _ step: MacroStep) -> some View {
        switch step {
        case .text(let text):
            Text("输入").frame(width: 56, alignment: .leading).foregroundStyle(.secondary)
            TextField("英文文字", text: Binding(get: { text }, set: { steps[offset] = .text($0) })).textFieldStyle(.roundedBorder).frame(width: 260)
        case .tap(let code): keyStep("点按", code) { steps[offset] = .tap($0) }
        case .down(let code): keyStep("按下", code) { steps[offset] = .down($0) }
        case .up(let code): keyStep("松开", code) { steps[offset] = .up($0) }
        case .delay(let ms):
            Text("等待").frame(width: 56, alignment: .leading).foregroundStyle(.secondary)
            TextField("毫秒", value: Binding(get: { ms }, set: { steps[offset] = .delay(min(9999, max(0, $0))) }), format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 80).monospacedDigit()
            Text("毫秒").foregroundStyle(.secondary)
        }
    }
    private func keyStep(_ title: String, _ code: UInt8, set: @escaping (UInt8) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 56, alignment: .leading).foregroundStyle(.secondary)
            Picker(title, selection: Binding(get: { UInt16(code) }, set: { set(UInt8($0)) })) {
                ForEach(Keycode.basic + Keycode.numpad + Keycode.modifiers) { Text($0.name).tag($0.code) }
            }.labelsHidden().fixedSize()
        }
    }
}

// MARK: Lighting

/// Effect, brightness, speed and color, as the board's lighting menu allows; shared by settings and the panel.
struct LightingControls: View {
    let lighting: KeyboardLighting
    @Binding var values: KeyboardLightingValues
    let compact: Bool
    @KeyboardViewState private var lastEffect = 1
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack {
                Toggle(lighting.indicatorOnly ? "指示灯" : "灯光", isOn: Binding(get: { values.effect != 0 }, set: { on in
                    if !on { lastEffect = values.effect }
                    values.effect = on ? (lastEffect == 0 ? 1 : lastEffect) : 0
                })).toggleStyle(.switch).font(compact ? PanelFont.value : .headline)
                Spacer()
                Picker("效果", selection: $values.effect) {
                    ForEach(effectList, id: \.value) { Text($0.name).tag($0.value) }
                }.labelsHidden().fixedSize().disabled(values.effect == 0)
            }
            if values.effect != 0 {
                slider("亮度", value: $values.brightness, range: lighting.brightness, label: "\(Int((Double(values.brightness) / Double(lighting.brightness.upperBound) * 100).rounded()))%")
                if let speed = lighting.speed { slider("速度", value: $values.speed, range: speed, label: "\(values.speed)") }
                if lighting.colorID != nil && lighting.colorEffects.contains(values.effect) { color }
            }
        }
    }
    private var effectList: [(value: Int, name: String)] {
        let list = lighting.effects.filter { $0.value != 0 }
        return list.contains { $0.value == values.effect } || values.effect == 0 ? list : list + [(values.effect, lighting.effectName(values.effect))]
    }
    private func slider(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, label: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(compact ? PanelFont.label : .callout).foregroundStyle(.secondary).frame(width: compact ? 28 : 40, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
            Text(label).font(compact ? PanelFont.label : .callout).monospacedDigit().frame(width: 38, alignment: .trailing)
        }
    }
    private var color: some View {
        HStack(spacing: 10) {
            Text("颜色").font(compact ? PanelFont.label : .callout).foregroundStyle(.secondary).frame(width: compact ? 28 : 40, alignment: .leading)
            ZStack {
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) },
                               startPoint: .leading, endPoint: .trailing)
                    .clipShape(Capsule()).frame(height: 6)
                Slider(value: Binding(get: { Double(values.hue) }, set: { values.hue = Int($0.rounded()) }), in: 0...255).tint(.clear)
            }
            if !compact {
                Text("饱和").font(.callout).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(values.saturation) }, set: { values.saturation = Int($0.rounded()) }), in: 0...255).frame(width: 110)
            }
            Circle().fill(Color(hue: Double(values.hue) / 255, saturation: Double(values.saturation) / 255, brightness: 1))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2))).frame(width: 18, height: 18)
        }
    }
}

// MARK: Panel

/// Always visible on the panel's devices page: the keyboard, how it is connected, and a lighting switch.
struct KeyboardPanelSummary: View {
    @ObservedObject var center: KeyboardCenter
    let keyboard: WiredKeyboard
    var body: some View {
        let state = center.state(keyboard.id)
        HStack(spacing: 12) {
            Image(systemName: "keyboard").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(keyboard.name).font(PanelFont.heading).lineLimit(1)
                Text(subtitle(state)).font(PanelFont.label).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let lighting = keyboard.model?.lighting, let values = center.lighting(keyboard.id) {
                Toggle(lighting.indicatorOnly ? "指示灯" : "灯光", isOn: Binding(get: { values.effect != 0 }, set: { on in
                    var next = values
                    next.effect = on ? (center.state(keyboard.id)?.lighting?.effect).flatMap { $0 == 0 ? nil : $0 } ?? 1 : 0
                    center.setLightingDraft(keyboard.id, next)
                })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help(lighting.indicatorOnly ? "指示灯开关（预览，展开后保存）" : "灯光开关（预览，展开后保存）")
            }
        }
    }
    private func subtitle(_ state: KeyboardState?) -> String {
        guard let model = keyboard.model else { return "有线连接" }
        var parts = ["有线连接", "VIA"]
        if let state { parts.append("\(state.layers) 层") }
        if !model.knobs.isEmpty { parts.append("\(model.knobs.count) 个旋钮") }
        if center.lightingDrafts[keyboard.id] != nil { parts.append("灯光未保存") }
        return parts.joined(separator: " · ")
    }
}

/// Opens on hover: lighting controls, then the keyboard's layers and macros.
struct KeyboardPanelDetail: View {
    @ObservedObject var center: KeyboardCenter
    let keyboard: WiredKeyboard
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let model = keyboard.model, let state = center.state(keyboard.id) {
                if let lighting = model.lighting, let values = center.lighting(keyboard.id) {
                    LightingControls(lighting: lighting, values: Binding(get: { values }, set: { center.setLightingDraft(keyboard.id, $0) }), compact: true)
                    if center.lightingDrafts[keyboard.id] != nil {
                        HStack(spacing: 8) {
                            Text("预览中，尚未保存").font(PanelFont.label).foregroundStyle(.orange)
                            Spacer()
                            Button("还原") { center.revertLighting(keyboard.id) }.controlSize(.small)
                            Button("保存到键盘") { center.saveLighting(keyboard.id) }.controlSize(.small).buttonStyle(.borderedProminent)
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                    fact("层", "\(state.layers) 层")
                    fact("宏", "\(state.macrosInUse) / \(state.macroCount) 已用")
                    if !model.knobs.isEmpty { fact("旋钮", "\(model.knobs.count) 个") }
                    fact("连接", "USB 有线")
                }
            } else {
                Text("这把键盘只显示连接状态，MacPulse 不支持修改它的设置。").font(PanelFont.label).foregroundStyle(.secondary)
            }
        }
    }
    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(PanelFont.label).foregroundStyle(.secondary)
            Text(value).font(PanelFont.value).monospacedDigit().lineLimit(1)
        }
    }
}
