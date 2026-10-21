import SwiftUI
import AppKit

// Keep the property wrapper available when building with Command Line Tools.
private typealias MouseViewState<Value> = SwiftUI.State<Value>

/// All accessory I/O runs here, one request at a time, so battery polling never interleaves with a settings write.
enum DeviceIO {
    static let queue = DispatchQueue(label: "local.macpulse.devices", qos: .utility)
    /// One shared tick for "retry while asleep"; views re-render every second, and a publisher
    /// created inside `body` would restart its countdown each time and never fire.
    static let retryTick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
}

/// Owns mouse discovery and settings for the settings window. Reads on open, writes only on "Apply".
final class MouseCenter: ObservableObject {
    struct WLState: Identifiable {
        let id: Int
        let name: String
        let connection: String
        let model: WLMouseModel
        var settings: WLMouseSettings
        var battery: (percent: Int, charging: Bool)?
    }
    struct LogiState: Identifiable {
        let id: String
        let name: String
        var battery: (percent: Int, charging: Bool)?
        var dpi: Int?
        var dpiOptions: [Int]
        var smartShift: SmartShiftState?
        var inverted: Bool?
    }
    @Published private(set) var wl: [WLState] = []
    @Published private(set) var logi: [LogiState] = []
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    private var loadedAt: Date?
    @Published private(set) var logiPermissionDenied = false
    /// Receivers that are plugged in but whose mouse did not answer (asleep or switched off).
    @Published private(set) var asleep: [String] = []
    @Published var message = ""
    @Published var failed = false
    private var wlChannels: [Int: WLMouseChannel] = [:]
    private var logiDevices: [String: LogitechDevice] = [:]

    func refreshIfStale(_ age: TimeInterval) {
        if loadedAt.map({ Date().timeIntervalSince($0) > age }) ?? true { refresh() }
    }
    /// The details shown next to an accessory's battery in the panel.
    func detail(for key: String) -> String? {
        if key.hasPrefix("wl-"), let pid = Int(key.dropFirst(3)), let state = wl.first(where: { $0.id == pid }) {
            let s = state.settings
            let dpi = s.stages.indices.contains(s.activeStage - 1) ? s.stages[s.activeStage - 1] : nil
            return [state.connection, dpi.map { "\($0) DPI" }, String(s.pollingRate) + " Hz"].compactMap { $0 }.joined(separator: " · ")
        }
        if key.hasPrefix("logi-"), let state = logi.first(where: { "logi-" + $0.id == key }) {
            return ["罗技", state.dpi.map { "\($0) DPI" }].compactMap { $0 }.joined(separator: " · ")
        }
        return nil
    }
    func refresh() {
        guard !busy else { return }
        busy = true
        DeviceIO.queue.async { [weak self] in
            var wl: [WLState] = [], channels: [Int: WLMouseChannel] = [:], problem: String?, asleep: [String] = []
            for channel in WLMouseChannel.find() {
                guard let model = channel.model else { continue }
                do {
                    try channel.withOpen {
                        let settings = try channel.readSettings()
                        let battery = (try? channel.battery()) ?? nil
                        wl.append(WLState(id: channel.productID, name: model.name, connection: model.connection(channel.productID),
                                          model: model, settings: settings, battery: battery.map { (percent: $0.percent, charging: $0.charging) }))
                    }
                    channels[channel.productID] = channel
                } catch WLMouseError.noReply { asleep.append(model.name) }
                catch { problem = error.localizedDescription }
            }
            let devices = LogitechHIDPP.discover()
            let logi = devices.map { device -> LogiState in
                let dpi = device.dpi()
                return LogiState(id: device.id, name: device.name, battery: device.battery(), dpi: dpi?.current,
                                 dpiOptions: dpi?.supported ?? [], smartShift: device.smartShift(), inverted: device.scrollInverted())
            }
            let denied = LogitechHIDPP.permissionDenied
            DispatchQueue.main.async {
                guard let self else { return }
                self.wl = wl; self.wlChannels = channels
                self.logi = logi; self.logiDevices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
                self.logiPermissionDenied = denied
                self.asleep = asleep
                self.busy = false; self.loaded = true; self.loadedAt = Date()
                if let problem { self.report(problem, failed: true) }
            }
        }
    }

    func apply(_ id: Int, _ settings: WLMouseSettings) {
        guard !busy, let channel = wlChannels[id], let index = wl.firstIndex(where: { $0.id == id }) else { return }
        let old = wl[index].settings
        busy = true
        DeviceIO.queue.async { [weak self] in
            let result = Result { try channel.withOpen { try channel.apply(settings, over: old) } }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let readBack):
                    if let i = self.wl.firstIndex(where: { $0.id == id }) { self.wl[i].settings = readBack }
                    self.report("已写入鼠标并读回校验", failed: false)
                case .failure(let error):
                    self.report(error.localizedDescription, failed: true)
                    self.refresh()
                }
            }
        }
    }

    func logitech(_ id: String, _ change: @escaping (LogitechDevice) -> Bool) {
        guard !busy, let device = logiDevices[id] else { return }
        busy = true
        DeviceIO.queue.async { [weak self] in
            let ok = change(device)
            let dpi = device.dpi(), shift = device.smartShift(), inverted = device.scrollInverted()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if let i = self.logi.firstIndex(where: { $0.id == id }) {
                    self.logi[i].dpi = dpi?.current; self.logi[i].smartShift = shift; self.logi[i].inverted = inverted
                }
                self.report(ok ? "已写入并读回校验" : "设备没有接受这个设置", failed: !ok)
            }
        }
    }

    private func report(_ text: String, failed: Bool) {
        message = text; self.failed = failed
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in if self?.message == text { self?.message = "" } }
    }
}

struct MouseSettingsView: View {
    @ObservedObject var center: MouseCenter
    @MouseViewState private var drafts: [Int: WLMouseSettings] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("外设").font(.title2.weight(.semibold))
                if center.busy { ProgressView().controlSize(.small) }
                if !center.message.isEmpty {
                    Label(center.message, systemImage: center.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(center.failed ? Color.orange : Color.green).lineLimit(2)
                }
                Spacer()
                Button { center.refresh() } label: { Label("重新读取", systemImage: "arrow.clockwise") }.disabled(center.busy)
            }
            ForEach(center.asleep, id: \.self) { name in
                HStack(spacing: 12) {
                    Image(systemName: "moon.zzz.fill").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.headline)
                        Text("接收器已连接，但鼠标正在休眠或已关机。动一下鼠标，几秒内会自动读取。").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(16).settingsCard()
            }
            if center.loaded && center.wl.isEmpty && center.logi.isEmpty && center.asleep.isEmpty {
                PreferenceCard(title: "没有找到可设置的鼠标") {
                    Text("支持 WLMOUSE（新协议型号，接收器或有线）和罗技 HID++ 2.0 设备。确认接收器已插好、鼠标已唤醒后点“重新读取”。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if !center.loaded {
                Text("正在读取鼠标设置…").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(center.wl) { device in wlCard(device) }
            ForEach(center.logi) { device in logiCard(device) }
            supportCard
            if center.logiPermissionDenied {
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
        .onAppear { if !center.loaded { center.refresh() } }
        // A sleeping mouse wakes when moved; retry quietly while this page is open.
        .onReceive(DeviceIO.retryTick) { _ in
            if !center.asleep.isEmpty && !center.busy { center.refresh() }
        }
        .onReceive(center.$wl) { states in
            // A fresh read replaces drafts that have no pending edits.
            for state in states where drafts[state.id] == nil || drafts[state.id] == state.settings || !center.busy {
                drafts[state.id] = state.settings
            }
        }
    }

    private var supportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("支持的设备").font(.headline)
            supportRow("WLMOUSE 万灵", badge: "已实测 花•兽 Mini PRO", tested: true,
                       devices: "花•兽 Mini / Mini PRO / X / X PRO / X V2 / MAX、幻 / 幻 M、影、剑 X、行者、BEAST MIAO、BEAST G（8K / 4K / 1K 接收器或有线）",
                       driver: "官方驱动：WLMOUSE HUB 网页版", link: "https://gm.wlmouse.gg")
            supportRow("罗技 Logitech", badge: "未经实测", tested: false,
                       devices: "支持 HID++ 2.0 的鼠标，经 Bolt / Unifying / Lightspeed 接收器、蓝牙或有线连接，如 MX Master、MX Anywhere、G 系列：电量、DPI、SmartShift、滚轮方向",
                       driver: "官方驱动：Logi Options+ / G HUB", link: nil)
            supportRow("其他蓝牙外设", badge: "仅电量", tested: true,
                       devices: "向系统报告电量的设备，如妙控鼠标、妙控键盘、妙控板", driver: nil, link: nil)
            Text("设置保存在鼠标里，换电脑也有效。固件升级、重新配对、恢复出厂、按键与宏请用官方驱动；官方驱动打开时不要在这里同时修改，以免互相覆盖。")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).settingsCard()
    }
    private func supportRow(_ title: String, badge: String, tested: Bool, devices: String, driver: String?, link: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title).font(.body.weight(.medium))
                Text(badge).font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background((tested ? Color.green : Color.orange).opacity(0.15), in: Capsule())
                    .foregroundStyle(tested ? Color.green : Color.orange)
            }
            Text(devices).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let driver {
                HStack(spacing: 4) {
                    Text(driver).font(.subheadline).foregroundStyle(.secondary)
                    if let link, let url = URL(string: link) { Link(link.replacingOccurrences(of: "https://", with: ""), destination: url).font(.subheadline) }
                }
            }
        }
    }

    // MARK: WLMOUSE

    private func draft(_ device: MouseCenter.WLState) -> Binding<WLMouseSettings> {
        Binding(get: { drafts[device.id] ?? device.settings }, set: { drafts[device.id] = $0 })
    }

    @ViewBuilder private func wlCard(_ device: MouseCenter.WLState) -> some View {
        let s = draft(device)
        let model = device.model
        let dirty = s.wrappedValue != device.settings
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "computermouse.fill").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.headline)
                    Text("WLMOUSE · \(device.connection)" + (device.battery.map { " · 电量 \($0.percent)%" + ($0.charging ? "（充电中）" : "") } ?? "")
                         + (device.settings.stages.indices.contains(device.settings.activeStage - 1) ? " · 当前 \(device.settings.stages[device.settings.activeStage - 1]) DPI" : ""))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("配置", selection: Binding(get: { device.settings.profile }, set: { profile in
                    var next = device.settings; next.profile = profile
                    center.apply(device.id, next)
                })) {
                    ForEach(1...max(1, device.settings.profileCount), id: \.self) { Text(device.settings.profileLabel($0)).tag($0) }
                }.labelsHidden().fixedSize().disabled(center.busy || dirty).help(dirty ? "先应用或还原当前修改" : "切换鼠标上的配置")
            }
            Divider()
            Group {
                profileNames(s)
                Divider()
                dpiSection(s, model: model)
                Divider()
                performanceSection(s, model: model, productID: device.id)
            }.disabled(center.busy)
            HStack(spacing: 10) {
                if dirty {
                    Label("\(Self.changeCount(s.wrappedValue, device.settings)) 项修改未写入鼠标", systemImage: "pencil.circle")
                        .font(.subheadline).foregroundStyle(.orange)
                } else {
                    Text("与鼠标当前设置一致").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("还原") { drafts[device.id] = device.settings }.disabled(!dirty || center.busy)
                Button("应用到鼠标") { center.apply(device.id, s.wrappedValue) }.disabled(!dirty || center.busy)
            }
        }.padding(16).settingsCard()
    }

    @ViewBuilder private func profileNames(_ s: Binding<WLMouseSettings>) -> some View {
        HStack {
            Text("配置名称").font(.headline)
            Text("保存在鼠标里，官方驱动中也会显示").font(.subheadline).foregroundStyle(.secondary)
        }
        HStack(spacing: 10) {
            ForEach(Array(s.wrappedValue.profileNames.indices), id: \.self) { i in
                VStack(alignment: .leading, spacing: 4) {
                    Text("配置 \(i + 1)" + (s.wrappedValue.profile == i + 1 ? " · 当前" : "")).font(.callout).foregroundStyle(.secondary)
                    TextField("配置 \(i + 1)", text: Binding(get: { s.wrappedValue.profileNames[i] },
                                                          set: { s.wrappedValue.profileNames[i] = WLMouseChannel.fitsName($0) }))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }.help("最多 30 字节（约 15 个汉字），只能使用 GBK 字符")
    }

    @ViewBuilder private func dpiSection(_ s: Binding<WLMouseSettings>, model: WLMouseModel) -> some View {
        HStack {
            Text("DPI 档位").font(.headline)
            Text("\(s.wrappedValue.stages.count) / \(model.maxStages) 档 · 范围 \(String(model.dpiStep))–\(String(model.maxDPI)) · 步进 \(String(model.dpiStep))").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            if model.independentXY { Toggle("X / Y 分别设置", isOn: s.independentXY).toggleStyle(.checkbox) }
        }
        ForEach(Array(s.wrappedValue.stages.indices), id: \.self) { i in
            HStack(spacing: 10) {
                Button { s.wrappedValue.activeStage = i + 1 } label: {
                    Image(systemName: s.wrappedValue.activeStage == i + 1 ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(s.wrappedValue.activeStage == i + 1 ? Color.accentColor : Color.secondary)
                }.buttonStyle(.plain).help("设为当前档位").accessibilityLabel("设第 \(i + 1) 档为当前档位")
                Text("第 \(i + 1) 档").frame(width: 56, alignment: .leading)
                dpiField(Binding(get: { s.wrappedValue.stages[i] }, set: { s.wrappedValue.stages[i] = $0 }), model: model, label: s.wrappedValue.independentXY ? "X" : "")
                if s.wrappedValue.independentXY {
                    dpiField(Binding(get: { s.wrappedValue.stagesY.indices.contains(i) ? s.wrappedValue.stagesY[i] : s.wrappedValue.stages[i] },
                                     set: { value in
                                         while s.wrappedValue.stagesY.count <= i { s.wrappedValue.stagesY.append(s.wrappedValue.stages[s.wrappedValue.stagesY.count]) }
                                         s.wrappedValue.stagesY[i] = value
                                     }), model: model, label: "Y")
                }
                Spacer()
                Button { removeStage(s, i) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).disabled(s.wrappedValue.stages.count <= 1).help("删除这一档").accessibilityLabel("删除第 \(i + 1) 档")
            }
        }
        Button { addStage(s, model: model) } label: { Label("添加档位", systemImage: "plus") }
            .disabled(s.wrappedValue.stages.count >= model.maxStages)
    }

    private func dpiField(_ value: Binding<Int>, model: WLMouseModel, label: String) -> some View {
        HStack(spacing: 4) {
            if !label.isEmpty { Text(label).foregroundStyle(.secondary) }
            TextField("DPI", value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = Self.clampDPI($0, model) }), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(width: 80).monospacedDigit()
            Stepper("", value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = Self.clampDPI($0, model) }),
                    in: model.dpiStep...model.maxDPI, step: model.dpiStep).labelsHidden()
        }
    }
    /// Number of fields that differ, for the "N 项修改" hint.
    static func changeCount(_ a: WLMouseSettings, _ b: WLMouseSettings) -> Int {
        zip(Mirror(reflecting: a).children, Mirror(reflecting: b).children).filter { "\($0.value)" != "\($1.value)" }.count
    }
    static func clampDPI(_ value: Int, _ model: WLMouseModel) -> Int {
        let stepped = (value / model.dpiStep) * model.dpiStep
        return min(model.maxDPI, max(model.dpiStep, stepped))
    }
    private func addStage(_ s: Binding<WLMouseSettings>, model: WLMouseModel) {
        let next = Self.clampDPI((s.wrappedValue.stages.last ?? 400) * 2, model)
        s.wrappedValue.stages.append(next)
        if s.wrappedValue.stagesY.count < s.wrappedValue.stages.count { s.wrappedValue.stagesY.append(next) }
    }
    private func removeStage(_ s: Binding<WLMouseSettings>, _ i: Int) {
        s.wrappedValue.stages.remove(at: i)
        if s.wrappedValue.stagesY.indices.contains(i) { s.wrappedValue.stagesY.remove(at: i) }
        s.wrappedValue.activeStage = min(s.wrappedValue.activeStage, s.wrappedValue.stages.count)
    }

    @ViewBuilder private func performanceSection(_ s: Binding<WLMouseSettings>, model: WLMouseModel, productID: Int) -> some View {
        Text("性能").font(.headline)
        HStack(alignment: .top, spacing: 20) {
            PreferenceField(title: "回报率") {
                Picker("回报率", selection: s.pollingRate) {
                    ForEach(model.pollingRates(productID), id: \.self) { Text(String($0) + " Hz").tag($0) }
                }.fixedSize().help("每秒向电脑报告位置的次数。越高越跟手，也越耗电；4000 Hz 以上需要 8K 接收器")
            }
            PreferenceField(title: "静默高度（LOD）") {
                Picker("静默高度", selection: s.lod) {
                    ForEach(model.lod, id: \.self) { Text(String(format: "%g mm", $0)).tag($0) }
                }.fixedSize().help("鼠标抬离桌面多高后停止追踪。越低，提起重放时越不容易误移动")
            }
            PreferenceField(title: "休眠时间") {
                Picker("休眠时间", selection: s.sleepSeconds) {
                    ForEach(Self.sleepChoices(current: s.wrappedValue.sleepSeconds), id: \.self) { Text(Self.sleepLabel($0)).tag($0) }
                }.fixedSize().help("闲置多久后进入休眠以省电；动一下鼠标即可唤醒")
            }
        }
        HStack(alignment: .top, spacing: 20) {
            PreferenceField(title: "按键去抖动") {
                HStack(spacing: 6) {
                    Text("\(s.wrappedValue.debounce) ms").monospacedDigit().frame(width: 44, alignment: .leading)
                    Stepper("去抖动", value: s.debounce, in: 0...15).labelsHidden()
                }.help("按键触发后忽略抖动的时间。出现单击变双击时调高；0 ms 响应最快")
            }
            if model.angleTune {
                PreferenceField(title: "角度微调 \(s.wrappedValue.angleTune)°") {
                    Slider(value: Binding(get: { Double(s.wrappedValue.angleTune) }, set: { s.wrappedValue.angleTune = Int($0.rounded()) }), in: -30...30, step: 1)
                        .frame(width: 220)
                }
            }
        }
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
            toggle("Motion Sync", "让传感器读数与回报同步，移动更平稳，延迟略增", s.motionSync)
            toggle("直线修正", "修正手绘直线时的抖动；游戏中一般关闭", s.angleSnap)
            toggle("波纹控制", "高 DPI 快速移动时抑制抖动", s.rippleControl)
            if model.hyperMode {
                toggle("高速模式", "降低输入延迟、加快传感器处理，略减续航", s.hyperMode)
                toggle("竞技模式", "固定 20K FPS 读取表面；需先开启高速模式", s.trackingMode).disabled(!s.wrappedValue.hyperMode)
            }
        }
    }
    private func toggle(_ title: String, _ help: String, _ value: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: value).toggleStyle(.checkbox)
            Text(help).font(.subheadline).foregroundStyle(.secondary).padding(.leading, 20).fixedSize(horizontal: false, vertical: true)
        }
    }
    static func sleepChoices(current: Int) -> [Int] {
        let base = [30, 60, 120, 180, 300, 600, 65535]
        return base.contains(current) ? base : (base + [current]).sorted()
    }
    static func sleepLabel(_ seconds: Int) -> String {
        if seconds == 65535 { return "不休眠（耗电）" }
        return seconds < 60 ? "\(seconds) 秒" : seconds % 60 == 0 ? "\(seconds / 60) 分钟" : "\(seconds) 秒"
    }

    // MARK: Logitech

    @ViewBuilder private func logiCard(_ device: MouseCenter.LogiState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "computermouse").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.headline)
                    Text("罗技 HID++ · 未经实机测试" + (device.battery.map { " · 电量 \($0.percent)%" + ($0.charging ? "（充电中）" : "") } ?? ""))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let dpi = device.dpi, !device.dpiOptions.isEmpty {
                PreferenceField(title: "DPI（当前 \(dpi)）") {
                    Picker("DPI", selection: Binding(get: { dpi }, set: { value in center.logitech(device.id) { $0.setDPI(value) } })) {
                        ForEach(device.dpiOptions.contains(dpi) ? device.dpiOptions : (device.dpiOptions + [dpi]).sorted(), id: \.self) { Text(String($0)).tag($0) }
                    }.fixedSize().disabled(center.busy)
                }
            }
            if let shift = device.smartShift {
                HStack(alignment: .top, spacing: 20) {
                    PreferenceField(title: "滚轮模式") {
                        Picker("滚轮模式", selection: Binding(get: { shift.wheelMode }, set: { mode in
                            var next = shift; next.wheelMode = mode
                            center.logitech(device.id) { $0.setSmartShift(next) }
                        })) { Text("段落").tag(UInt8(2)); Text("自由").tag(UInt8(1)) }
                            .pickerStyle(.segmented).fixedSize().disabled(center.busy)
                    }
                    PreferenceField(title: "SmartShift 自动切换") {
                        Toggle("SmartShift", isOn: Binding(get: { shift.autoDisengage != 255 }, set: { on in
                            var next = shift; next.autoDisengage = on ? 10 : 255
                            center.logitech(device.id) { $0.setSmartShift(next) }
                        })).toggleStyle(.checkbox).disabled(center.busy)
                    }
                }
            }
            if let inverted = device.inverted {
                Toggle("反转滚轮方向", isOn: Binding(get: { inverted }, set: { value in center.logitech(device.id) { $0.setScrollInverted(value) } }))
                    .toggleStyle(.checkbox).disabled(center.busy)
            }
            Text("按 OpenLogi 的 HID++ 实现编写（电量 0x1004/0x1000、DPI 0x2201、SmartShift 0x2110/0x2111、滚轮 0x2121），每次修改后读回校验。")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).settingsCard()
    }
}
