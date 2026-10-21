import Foundation
import AppKit
import SwiftUI
import UserNotifications

/// Built-in fan presets: "自动" plus four scenario curves (CPU temperature → share of the fan's own
/// min…max range). The Mac mini's own curve idles at 1000 RPM and stays low under load, letting the
/// chip run into the 80s–90s °C and lower its clocks after 10–15 minutes; around 3000 RPM is clearly
/// audible. The scenarios trade between those two ends.
struct FanPreset: Identifiable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    /// nil hands the fan back to macOS.
    let points: [CurvePoint]?
    var curve: FanCurve? { points.map { FanCurve(name: name, points: $0) } }

    static let all: [FanPreset] = [
        .init(id: "auto", name: "自动", detail: "由 macOS 控制，和不装 MacPulse 时一样", symbol: "a.circle", points: nil),
        .init(id: "silent", name: "静音办公", detail: "网页、文档、开会：70 °C 前保持最低转速", symbol: "moon",
              points: [CurvePoint(temp: 70, percent: 0), CurvePoint(temp: 85, percent: 15), CurvePoint(temp: 95, percent: 40)]),
        .init(id: "daily", name: "日常均衡", detail: "编程、多开应用：55 °C 起平缓加速", symbol: "dial.medium",
              points: [CurvePoint(temp: 55, percent: 0), CurvePoint(temp: 70, percent: 15), CurvePoint(temp: 85, percent: 45), CurvePoint(temp: 95, percent: 75)]),
        .init(id: "sustained", name: "持续性能", detail: "编译、导出、本地模型：提前加速，减少降频", symbol: "hammer",
              points: [CurvePoint(temp: 45, percent: 10), CurvePoint(temp: 65, percent: 30), CurvePoint(temp: 80, percent: 65), CurvePoint(temp: 90, percent: 100)]),
        .init(id: "cooling", name: "极限散热", detail: "游戏、长时间满载：温度优先，噪音较大", symbol: "wind",
              points: [CurvePoint(temp: 40, percent: 30), CurvePoint(temp: 60, percent: 60), CurvePoint(temp: 75, percent: 100)]),
    ]
    /// Earlier preset ids map to their closest scenario; the removed fixed speed returns to "自动".
    static let aliases = ["quiet": "silent", "balanced": "daily", "cool": "sustained", "max": "cooling", "custom": "auto"]
    static func find(_ id: String) -> FanPreset { all.first { $0.id == (aliases[id] ?? id) } ?? all[0] }
}

/// A point on a user curve: CPU temperature (°C) → share of the fan's min…max range (0–100 %).
struct CurvePoint: Codable, Equatable, Hashable {
    var temp: Double
    var percent: Double
}

/// A saved, named fan preset. `points` is fan 1's curve; `extraFans[i]` is fan i + 2's own curve,
/// and any fan without one follows fan 1. Points stay sorted by temperature; between points the speed
/// is linear, below the first and above the last it holds that point's speed.
struct FanCurve: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var points: [CurvePoint]
    var extraFans: [[CurvePoint]] = []
    static let tempRange = 30.0...100.0
    /// At most four points keeps a curve easy to read and to drag.
    static let maxPoints = 4

    init(id: UUID = UUID(), name: String, points: [CurvePoint], extraFans: [[CurvePoint]] = []) {
        self.id = id; self.name = name; self.points = points; self.extraFans = extraFans
    }
    // Curves saved before per-fan curves existed have no `extraFans`; they keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "自定义曲线"
        points = try c.decodeIfPresent([CurvePoint].self, forKey: .points) ?? []
        extraFans = try c.decodeIfPresent([[CurvePoint]].self, forKey: .extraFans) ?? []
    }

    func points(for fan: Int) -> [CurvePoint] {
        fan >= 1 && fan <= extraFans.count && !extraFans[fan - 1].isEmpty ? extraFans[fan - 1] : points
    }
    /// Whether this fan has a curve of its own rather than following fan 1.
    func hasOwnCurve(_ fan: Int) -> Bool { fan >= 1 && fan <= extraFans.count && !extraFans[fan - 1].isEmpty }
    mutating func setPoints(_ list: [CurvePoint], for fan: Int) {
        if fan == 0 { points = list; return }
        while extraFans.count < fan { extraFans.append([]) }
        extraFans[fan - 1] = list
    }
    /// Gives every fan up to `count` fan 1's curve.
    mutating func copyFirstToAll() { extraFans = [] }

    func share(at temperature: Double, fan: Int = 0) -> Double {
        Self.share(points(for: fan), at: temperature)
    }
    static func share(_ points: [CurvePoint], at temperature: Double) -> Double {
        let sorted = points.sorted { $0.temp < $1.temp }
        guard let first = sorted.first, let last = sorted.last else { return 1 }
        if temperature <= first.temp { return first.percent / 100 }
        if temperature >= last.temp { return last.percent / 100 }
        for (a, b) in zip(sorted, sorted.dropFirst()) where temperature <= b.temp {
            let t = (temperature - a.temp) / max(0.001, b.temp - a.temp)
            return (a.percent + (b.percent - a.percent) * t) / 100
        }
        return last.percent / 100
    }
    /// Starting points for "新建曲线", matching the built-in presets.
    static var templates: [(name: String, points: [CurvePoint])] {
        [("空白", [CurvePoint(temp: 40, percent: 0), CurvePoint(temp: 70, percent: 50), CurvePoint(temp: 90, percent: 100)])]
            + FanPreset.all.compactMap { preset in preset.points.map { (preset.name, $0) } }
    }
}

struct FanSettings: Codable, Equatable {
    var enabled = false
    var preset = "auto"
    var customRPM = 2000.0
    var safetyLimit = 90.0
    var curves: [FanCurve] = []
    /// Presets pinned to the panel's fan menu, at most four.
    var menuPresets = ["auto", "silent", "daily", "sustained"]
    static let maxMenuPresets = 4
    /// Names the user gave each fan, by fan order; empty means the default "风扇 n".
    var fanNames: [String] = []
    static let maxNameLength = 10
    func fanName(_ index: Int) -> String {
        index < fanNames.count && !fanNames[index].trimmingCharacters(in: .whitespaces).isEmpty ? fanNames[index] : "风扇 \(index + 1)"
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? "auto"
        customRPM = try c.decodeIfPresent(Double.self, forKey: .customRPM) ?? 2000
        safetyLimit = try c.decodeIfPresent(Double.self, forKey: .safetyLimit) ?? 90
        curves = (try c.decodeIfPresent([FanCurve].self, forKey: .curves) ?? []).map { curve in
            var trimmed = curve
            trimmed.points = Array(curve.points.sorted { $0.temp < $1.temp }.prefix(FanCurve.maxPoints))
            trimmed.extraFans = curve.extraFans.map { Array($0.sorted { $0.temp < $1.temp }.prefix(FanCurve.maxPoints)) }
            return trimmed
        }
        fanNames = (try c.decodeIfPresent([String].self, forKey: .fanNames) ?? []).map { String($0.prefix(Self.maxNameLength)) }
        if let alias = FanPreset.aliases[preset] { preset = alias }
        if let pinned = try c.decodeIfPresent([String].self, forKey: .menuPresets) {
            menuPresets = Array(pinned.map { FanPreset.aliases[$0] ?? $0 }.prefix(Self.maxMenuPresets))
        }
    }
}

struct FanInfo: Equatable {
    var actual: Int, min: Int, max: Int, target: Int, manual: Bool
}

/// Talks to the root helper over its socket. Every call is short and runs off the main thread.
enum FanHelperClient {
    static let socketPath = "/var/run/local.macpulse.fanhelper.sock"
    static let label = "local.macpulse.fanhelper"
    static let installedPath = "/Library/PrivilegedHelperTools/local.macpulse.fanhelper"
    static let plistPath = "/Library/LaunchDaemons/local.macpulse.fanhelper.plist"
    static let version = 1

    static func send(_ line: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { return nil }
        let message = line + "\n"
        guard message.withCString({ Darwin.send(fd, $0, strlen($0), 0) }) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// Parses `ok version=1 fans=1 manual=0 f0=actual,min,max,target,mode`.
    static func parseStatus(_ reply: String) -> (version: Int, fans: [FanInfo])? {
        let words = reply.split(separator: " ")
        guard words.first == "ok" else { return nil }
        var version = 0, fans: [FanInfo] = []
        for word in words.dropFirst() {
            let pair = word.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            if pair[0] == "version" { version = Int(pair[1]) ?? 0 }
            if pair[0].hasPrefix("f"), Int(pair[0].dropFirst()) != nil {
                let v = pair[1].split(separator: ",").compactMap { Int($0) }
                if v.count == 5 { fans.append(FanInfo(actual: v[0], min: v[1], max: v[2], target: v[3], manual: v[4] == 1)) }
            }
        }
        return (version, fans)
    }

    /// Copies the helper out of the app bundle and starts it as a LaunchDaemon. macOS asks for an administrator password.
    static func install() -> String? {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "MacPulseFanHelper")?.path else { return "应用包里没有风扇助手，请重新编译" }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(label)</string>
        <key>ProgramArguments</key><array><string>\(installedPath)</string><string>--owner</string><string>\(getuid())</string></array>
        <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
        </dict></plist>
        """
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("local.macpulse.fanhelper.plist")
        do { try plist.write(to: staged, atomically: true, encoding: .utf8) } catch { return "无法准备安装文件" }
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = [
            "mkdir -p /Library/PrivilegedHelperTools",
            "launchctl bootout system/\(label) 2>/dev/null || true",
            "cp \(quote(helper)) \(installedPath)", "chown root:wheel \(installedPath)", "chmod 755 \(installedPath)",
            "cp \(quote(staged.path)) \(plistPath)", "chown root:wheel \(plistPath)", "chmod 644 \(plistPath)",
            "launchctl bootstrap system \(plistPath)",
        ].joined(separator: " && ")
        return runAsAdministrator(script, prompt: "MacPulse 需要安装风扇助手才能调节风扇转速。")
    }

    static func uninstall() -> String? {
        _ = send("auto")
        let script = "launchctl bootout system/\(label) 2>/dev/null; rm -f \(installedPath) \(plistPath) \(socketPath); true"
        return runAsAdministrator(script, prompt: "MacPulse 将移除风扇助手，风扇交还系统控制。")
    }

    private static func runAsAdministrator(_ script: String, prompt: String) -> String? {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        // -128: the user cancelled the password dialog.
        return (error[NSAppleScript.errorNumber] as? Int) == -128 ? "已取消" : (error[NSAppleScript.errorMessage] as? String ?? "安装失败")
    }
}

/// Owns fan settings and drives the helper. Off by default; turning it on is the user's consent to install the helper.
final class FanController: ObservableObject {
    enum HelperState: Equatable { case unknown, missing, outdated, running }
    @Published var settings: FanSettings { didSet { save() } }
    @Published private(set) var helper: HelperState = .unknown
    @Published private(set) var fans: [FanInfo] = []
    @Published private(set) var busy = false
    @Published var message = ""
    private let queue = DispatchQueue(label: "local.macpulse.fan", qos: .utility)
    /// Last target sent to each fan, by fan order.
    private var lastSent: [Int: Int] = [:]
    private var lastSentAt = Date.distantPast
    private var lastStatus = Date.distantPast
    /// Snapshot and test processes only read: they must never fight the running app for the fan.
    let passive = CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--test")

    init() {
        if let data = UserDefaults.standard.data(forKey: "fan.v1"), let stored = try? JSONDecoder().decode(FanSettings.self, from: data) {
            settings = stored
        } else { settings = FanSettings() }
        if settings.enabled { refreshStatus() }
    }
    private func save() {
        guard !passive else { return }
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "fan.v1") }
    }

    var preset: FanPreset { FanPreset.find(settings.preset) }
    /// The saved curve that is active, if the selection is one.
    var activeCurve: FanCurve? { settings.curves.first { $0.id.uuidString == settings.preset } }
    /// Built-in presets followed by saved curves, for menus.
    var choices: [(id: String, name: String, symbol: String)] {
        FanPreset.all.map { ($0.id, $0.name, $0.symbol) } + settings.curves.map { ($0.id.uuidString, $0.name, "chart.xyaxis.line") }
    }
    @Published private(set) var safetyOverride = false
    func curve(for id: String) -> FanCurve? {
        settings.curves.first { $0.id.uuidString == id } ?? FanPreset.all.first { $0.id == id }?.curve
    }

    func saveCurve(_ curve: FanCurve) {
        var copy = curve
        copy.points.sort { $0.temp < $1.temp }
        copy.extraFans = copy.extraFans.map { $0.sorted { $0.temp < $1.temp } }
        copy.name = copy.name.trimmingCharacters(in: .whitespaces).isEmpty ? "自定义曲线" : copy.name
        if let index = settings.curves.firstIndex(where: { $0.id == copy.id }) { settings.curves[index] = copy } else { settings.curves.append(copy) }
        lastSent = [:]
    }
    func deleteCurve(_ id: UUID) {
        if settings.preset == id.uuidString { select("auto") }
        settings.curves.removeAll { $0.id == id }
        settings.menuPresets.removeAll { $0 == id.uuidString }
    }
    /// Pins or unpins a preset in the panel menu; a fifth pin is refused.
    func toggleMenu(_ id: String) {
        if let index = settings.menuPresets.firstIndex(of: id) { settings.menuPresets.remove(at: index) }
        else if settings.menuPresets.count < FanSettings.maxMenuPresets { settings.menuPresets.append(id) }
    }
    /// The panel's four buttons: pinned presets in display order; an unpinned active preset takes the last slot.
    var panelButtons: [(id: String, name: String, symbol: String)] {
        var list = choices.filter { settings.menuPresets.contains($0.id) }
        if !list.contains(where: { $0.id == settings.preset }), let active = choices.first(where: { $0.id == settings.preset }) {
            if list.count >= FanSettings.maxMenuPresets { list.removeLast() }
            list.append(active)
        }
        return Array(list.prefix(FanSettings.maxMenuPresets))
    }
    /// What the panel menu lists: pinned presets in display order, plus the active one if it is not pinned.
    var menuChoices: [(id: String, name: String, symbol: String)] {
        choices.filter { settings.menuPresets.contains($0.id) || $0.id == settings.preset }
    }
    /// Short enough for the panel's fan row; without fan control macOS is in charge, which is "自动".
    var activeLabel: String { !settings.enabled ? "自动" : safetyOverride ? "过热保护" : activeCurve?.name ?? preset.name }

    func refreshStatus() {
        queue.async { [weak self] in
            let reply = FanHelperClient.send("status")
            let parsed = reply.flatMap(FanHelperClient.parseStatus)
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastStatus = Date()
                if let parsed {
                    self.fans = parsed.fans
                    self.helper = parsed.version == FanHelperClient.version ? .running : .outdated
                } else {
                    self.helper = FileManager.default.fileExists(atPath: FanHelperClient.plistPath) ? .outdated : .missing
                }
            }
        }
    }

    /// Turning on installs (or updates) the helper first; the password dialog is the consent.
    func setEnabled(_ on: Bool) {
        guard !busy else { return }
        if !on {
            settings.enabled = false; lastSent = [:]
            queue.async { _ = FanHelperClient.send("auto") }
            message = "已交还系统控制"
            return
        }
        busy = true
        queue.async { [weak self] in
            var problem: String?
            if FanHelperClient.send("status").flatMap(FanHelperClient.parseStatus)?.version != FanHelperClient.version {
                problem = FanHelperClient.install()
                if problem == nil { for _ in 0..<20 where FanHelperClient.send("ping") == nil { usleep(250_000) } }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if let problem { self.message = problem; self.settings.enabled = false }
                else { self.settings.enabled = true; self.message = "风扇控制已开启"; self.lastSent = [:] }
                self.refreshStatus()
            }
        }
    }

    func uninstall() {
        busy = true
        settings.enabled = false
        queue.async { [weak self] in
            let problem = FanHelperClient.uninstall()
            DispatchQueue.main.async {
                self?.busy = false
                self?.message = problem ?? "风扇助手已移除"
                self?.refreshStatus()
            }
        }
    }

    func select(_ id: String) {
        settings.preset = id
        lastSent = [:]; safetyOverride = false
        if id == "auto", !passive { queue.async { _ = FanHelperClient.send("auto") } }
    }

    /// Each fan's target for a preset: its own curve's share of its own min…max range.
    /// Without a temperature reading every fan runs at full speed rather than guess low.
    static func targets(for curve: FanCurve, fans: [FanInfo], temperature: Double?) -> [Int] {
        fans.enumerated().map { index, fan in
            let share = temperature.map { curve.share(at: $0, fan: index) } ?? 1
            return min(fan.max, max(fan.min, fan.min + Int(Double(fan.max - fan.min) * share)))
        }
    }

    /// Called with every sample. Sends a fan a new target only when it moves by 100 RPM, or every 15 s as a keep-alive.
    func evaluate(cpuTemperature: Double?) {
        guard !passive else { return }
        guard settings.enabled, helper == .running, !fans.isEmpty else {
            if settings.enabled, Date().timeIntervalSince(lastStatus) > 10 { refreshStatus() }
            return
        }
        if Date().timeIntervalSince(lastStatus) > 5 { refreshStatus() }
        guard settings.preset != "auto" else { return }
        // Safety: at the limit macOS takes over; 5 °C below it the chosen preset resumes.
        if let t = cpuTemperature {
            if !safetyOverride, t >= settings.safetyLimit {
                safetyOverride = true; lastSent = [:]
                queue.async { _ = FanHelperClient.send("auto") }
                notify("CPU 温度达到 \(Int(t)) °C，风扇暂时交还系统控制，降温后自动恢复")
            } else if safetyOverride, t < settings.safetyLimit - 5 {
                safetyOverride = false
            }
        }
        if safetyOverride {
            // Keep the helper's watchdog fed without leaving system control.
            if Date().timeIntervalSince(lastSentAt) > 15 { lastSentAt = Date(); queue.async { _ = FanHelperClient.send("ping") } }
            return
        }
        guard let curve = activeCurve ?? preset.curve else { return }
        let targets = Self.targets(for: curve, fans: fans, temperature: cpuTemperature)
        let keepAlive = Date().timeIntervalSince(lastSentAt) >= 15
        let changed = targets.enumerated().filter { index, target in keepAlive || lastSent[index].map { abs($0 - target) >= 100 } ?? true }
        guard !changed.isEmpty else { return }
        for (index, target) in changed { lastSent[index] = target }
        lastSentAt = Date()
        queue.async { [weak self] in
            for (index, target) in changed {
                let reply = FanHelperClient.send("set \(index) \(target)")
                if reply?.hasPrefix("ok") != true {
                    DispatchQueue.main.async { self?.message = "风扇助手没有接受命令：\(reply ?? "无法连接")"; self?.lastSent = [:] }
                    return
                }
            }
        }
    }

    private func notify(_ text: String) {
        message = text
        let content = UNMutableNotificationContent()
        content.title = "MacPulse 风扇"; content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "fan.safety", content: content, trigger: nil))
    }
}

struct FanSettingsView: View {
    @ObservedObject var fan: FanController
    var temperature: Double?
    /// Live readings for every fan, from the sensor sample (available without the helper).
    var readings: [FanReading] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("风扇").font(.title2.weight(.semibold))
                if fan.busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            PreferenceCard(title: "风扇控制") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("启用风扇控制").font(.body.weight(.medium))
                        Text(statusLine).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("启用风扇控制", isOn: Binding(get: { fan.settings.enabled }, set: { fan.setEnabled($0) }))
                        .toggleStyle(.switch).labelsHidden().disabled(fan.busy)
                }
                Text("调节转速需要写入系统管理控制器（SMC），macOS 只允许管理员权限的程序这样做。首次开启时会请你输入管理员密码，安装一个只接受风扇命令的小助手（以 root 运行，仅你的账户可以连接）。转速始终限制在风扇自身的最低到最高之间；MacPulse 退出或崩溃后 45 秒内风扇自动交还系统控制。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !fan.message.isEmpty { Text(fan.message).font(.subheadline).foregroundStyle(.orange) }
                if fan.helper == .running || fan.helper == .outdated {
                    Button("移除风扇助手") { fan.uninstall() }.disabled(fan.busy)
                }
            }
            PreferenceCard(title: readings.count > 1 ? "风扇（\(readings.count) 个）" : "风扇") {
                ForEach(Array(readings.enumerated()), id: \.offset) { index, reading in
                    fanRow(index, reading)
                    if index < readings.count - 1 { Divider() }
                }
                Text(readings.count > 1 ? "名称会用在面板和曲线编辑器里。每条曲线可以给每个风扇单独设置，转速都按各自范围的百分比计算。" : "名称会用在面板和曲线编辑器里。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            PreferenceCard(title: "预设") {
                // Equal, side-by-side cards; the pin decides what the panel's fan menu offers.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 10)], spacing: 10) {
                    ForEach(fan.choices, id: \.id) { preset in presetCard(preset) }
                }
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill").foregroundStyle(Color.accentColor)
                    Text("点卡片右上角的图钉，选择面板风扇单元里的 4 个按钮 · 已选 \(fan.settings.menuPresets.count) / \(FanSettings.maxMenuPresets)")
                }.font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text("安全温度").foregroundStyle(.secondary)
                    Picker("安全温度", selection: $fan.settings.safetyLimit) {
                        ForEach([85.0, 90.0, 95.0], id: \.self) { Text("\(Int($0)) °C").tag($0) }
                    }.labelsHidden().fixedSize()
                    Text("任何预设下 CPU 达到此温度，系统都会临时接管；降到 5 °C 以下自动恢复").font(.subheadline).foregroundStyle(.secondary)
                }
            }.disabled(!fan.settings.enabled || fan.busy)
            PreferenceCard(title: "自定义曲线") {
                FanCurveEditor(fan: fan, temperature: temperature, readings: readings)
            }.disabled(fan.busy)
        }
        .onAppear { fan.refreshStatus() }
    }
    private func presetCard(_ preset: (id: String, name: String, symbol: String)) -> some View {
        let selected = fan.settings.preset == preset.id
        let pinned = fan.settings.menuPresets.contains(preset.id)
        let full = fan.settings.menuPresets.count >= FanSettings.maxMenuPresets
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: preset.symbol).font(.system(size: 22)).frame(width: 28, height: 28)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Spacer()
                Button { fan.toggleMenu(preset.id) } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 13))
                        .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!pinned && full)
                    .help(pinned ? "从面板下拉菜单移除" : full ? "面板下拉菜单最多 4 个，先取消一个" : "放进面板下拉菜单")
                    .accessibilityLabel(pinned ? "从面板下拉菜单移除\(preset.name)" : "把\(preset.name)放进面板下拉菜单")
            }
            Text(preset.name).font(.headline).lineLimit(1)
            Text(FanPreset.all.first { $0.id == preset.id }?.detail ?? "自定义曲线")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Group {
                if let curve = fan.curve(for: preset.id) {
                    CurveThumbnail(curve: curve)
                } else {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .overlay(Text("系统曲线").font(.caption).foregroundStyle(.secondary))
                }
            }.frame(height: 48)
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { fan.select(preset.id) }
        .accessibilityElement(children: .contain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func fanRow(_ index: Int, _ reading: FanReading) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "fan").font(.system(size: 16)).foregroundStyle(.cyan).frame(width: 22)
            TextField("风扇 \(index + 1)", text: Binding(
                get: { index < fan.settings.fanNames.count ? fan.settings.fanNames[index] : "" },
                set: { name in
                    while fan.settings.fanNames.count <= index { fan.settings.fanNames.append("") }
                    fan.settings.fanNames[index] = String(name.prefix(FanSettings.maxNameLength))
                }))
                .textFieldStyle(.roundedBorder).frame(width: 150)
                .help("自定义名称，最多 \(FanSettings.maxNameLength) 个字；留空使用“风扇 \(index + 1)”")
            Spacer()
            Text("\(Int(reading.rpm.rounded())) RPM").font(.body.weight(.medium)).monospacedDigit()
            Text("范围 \(Int(reading.min))–\(Int(reading.max))").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 110, alignment: .trailing)
        }
    }
    private var statusLine: String {
        let info = readings.isEmpty ? nil : readings.enumerated().map { index, reading in
            (readings.count > 1 ? fan.settings.fanName(index) + " " : "当前 ") + "\(Int(reading.rpm.rounded())) RPM"
        }.joined(separator: " · ")
        switch fan.helper {
        case .running: return ([info, fan.settings.enabled ? "预设：\(fan.activeLabel)" : "未启用，系统控制"].compactMap { $0 }).joined(separator: " · ")
        case .outdated: return "风扇助手需要更新，开启时会重新安装"
        case .missing: return "默认关闭；开启时安装风扇助手"
        case .unknown: return "正在检查风扇助手…"
        }
    }
}

private typealias CurveViewState<Value> = SwiftUI.State<Value>

/// Draggable fan curve: temperature across, fan share up, with the RPM scale and the current reading marked.
struct FanCurveChart: View {
    @Binding var points: [CurvePoint]
    @Binding var selected: Int?
    let fanRange: ClosedRange<Double>
    let temperature: Double?
    /// The other fans' curves, drawn faintly behind the one being edited.
    var others: [[CurvePoint]] = []
    private static let range = FanCurve.tempRange

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(x: 34, y: 10, width: geometry.size.width - 86, height: geometry.size.height - 32)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(&context, plot: plot) }
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    handle(index: index, point: point, plot: plot)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture(count: 2).onEnded { tap in addPoint(at: tap.location, plot: plot) })
        }
        .accessibilityLabel("风扇曲线编辑器")
    }

    private func position(_ p: CurvePoint, _ plot: CGRect) -> CGPoint {
        let span = Self.range.upperBound - Self.range.lowerBound
        return CGPoint(x: plot.minX + plot.width * CGFloat((p.temp - Self.range.lowerBound) / span),
                       y: plot.maxY - plot.height * CGFloat(p.percent / 100))
    }
    private func value(at location: CGPoint, _ plot: CGRect) -> CurvePoint {
        let span = Self.range.upperBound - Self.range.lowerBound
        let t = Self.range.lowerBound + Double((location.x - plot.minX) / plot.width) * span
        let pct = Double((plot.maxY - location.y) / plot.height) * 100
        return CurvePoint(temp: min(Self.range.upperBound, max(Self.range.lowerBound, t.rounded())), percent: min(100, max(0, pct.rounded())))
    }

    private func draw(_ context: inout GraphicsContext, plot: CGRect) {
        let grid = Color.secondary.opacity(0.18)
        for t in stride(from: 30.0, through: 100, by: 10) {
            let x = plot.minX + plot.width * CGFloat((t - 30) / 70)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) }, with: .color(grid), lineWidth: 0.5)
            context.draw(Text("\(Int(t))°").font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: x, y: plot.maxY + 11))
        }
        for pct in stride(from: 0.0, through: 100, by: 25) {
            let y = plot.maxY - plot.height * CGFloat(pct / 100)
            context.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: y)); $0.addLine(to: CGPoint(x: plot.maxX, y: y)) }, with: .color(grid), lineWidth: 0.5)
            context.draw(Text("\(Int(pct))%").font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: plot.minX - 16, y: y))
            let rpm = fanRange.lowerBound + (fanRange.upperBound - fanRange.lowerBound) * pct / 100
            context.draw(Text(String(Int(rpm))).font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: plot.maxX + 24, y: y))
        }
        for other in others {
            if let faint = path(other, plot) {
                context.stroke(faint, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round, dash: [4, 3]))
            }
        }
        guard let line = path(points, plot) else { return }
        var area = line
        area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY)); area.addLine(to: CGPoint(x: plot.minX, y: plot.maxY)); area.closeSubpath()
        context.fill(area, with: .color(.accentColor.opacity(0.12)))
        context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        guard let t = temperature, Self.range.contains(t) else { return }
        let x = plot.minX + plot.width * CGFloat((t - 30) / 70)
        context.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) },
                       with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        let y = plot.maxY - plot.height * CGFloat(FanCurve.share(points, at: t))
        context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(.orange))
        context.draw(Text("当前 \(Int(t))°").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange),
                     at: CGPoint(x: min(plot.maxX - 30, x + 30), y: plot.minY + 6))
    }

    /// Flat to the edges beyond the end points, as the controller holds them.
    private func path(_ list: [CurvePoint], _ plot: CGRect) -> Path? {
        let sorted = list.sorted { $0.temp < $1.temp }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        var line = Path()
        line.move(to: CGPoint(x: plot.minX, y: position(first, plot).y))
        for point in sorted { line.addLine(to: position(point, plot)) }
        line.addLine(to: CGPoint(x: plot.maxX, y: position(last, plot).y))
        return line
    }

    private func handle(index: Int, point: CurvePoint, plot: CGRect) -> some View {
        Circle()
            .fill(selected == index ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .frame(width: 14, height: 14)
            .position(position(point, plot))
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in move(index, from: point, to: drag.location, plot: plot) })
            .help("\(Int(point.temp)) °C → \(Int(point.percent))%")
    }
    /// A point cannot pass its neighbours, so the order never flips mid-drag.
    private func move(_ index: Int, from point: CurvePoint, to location: CGPoint, plot: CGRect) {
        selected = index
        var moved = value(at: location, plot)
        let neighbours = points.enumerated().filter { $0.offset != index }.map(\.element.temp)
        let lower = neighbours.filter { $0 < point.temp }.max().map { $0 + 1 } ?? Self.range.lowerBound
        let upper = neighbours.filter { $0 > point.temp }.min().map { $0 - 1 } ?? Self.range.upperBound
        moved.temp = min(upper, max(lower, moved.temp))
        points[index] = moved
    }
    private func addPoint(at location: CGPoint, plot: CGRect) {
        guard points.count < FanCurve.maxPoints, plot.insetBy(dx: -6, dy: -6).contains(location) else { return }
        let point = value(at: location, plot)
        guard !points.contains(where: { abs($0.temp - point.temp) < 1 }) else { return }
        var list = points
        list.append(point)
        list.sort { $0.temp < $1.temp }
        points = list
        selected = list.firstIndex(of: point)
    }
}

/// Saved curves: pick one to edit, start a new one from a template, rename, save, apply or delete.
struct FanCurveEditor: View {
    @ObservedObject var fan: FanController
    let temperature: Double?
    var readings: [FanReading] = []
    @CurveViewState private var draft: FanCurve?
    @CurveViewState private var selected: Int?
    /// Which fan's curve the chart is editing; every fan's curve is saved in the same preset.
    @CurveViewState private var editing = 0
    private var fanCount: Int { max(1, readings.count, fan.fans.count) }
    private var editingFan: Int { min(editing, fanCount - 1) }
    private var fanRange: ClosedRange<Double> {
        if editingFan < readings.count, readings[editingFan].max > readings[editingFan].min {
            return readings[editingFan].min...readings[editingFan].max
        }
        guard editingFan < fan.fans.count, fan.fans[editingFan].max > fan.fans[editingFan].min else { return 1000...4900 }
        return Double(fan.fans[editingFan].min)...Double(fan.fans[editingFan].max)
    }
    private var saved: FanCurve? { draft.flatMap { d in fan.settings.curves.first { $0.id == d.id } } }
    private var dirty: Bool { draft != nil && draft != saved }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(fan.settings.curves) { curve in
                    Button { open(curve) } label: {
                        Text(curve.name).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(draft?.id == curve.id ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05), in: Capsule())
                            .overlay(Capsule().strokeBorder(fan.settings.preset == curve.id.uuidString ? Color.accentColor : .clear, lineWidth: 1.5))
                    }.buttonStyle(.plain).help(fan.settings.preset == curve.id.uuidString ? "正在使用" : "编辑这条曲线")
                }
                Menu {
                    ForEach(FanCurve.templates, id: \.name) { template in
                        Button("从“\(template.name)”开始") { newCurve(template.points, name: template.name == "空白" ? "我的曲线" : "我的\(template.name)") }
                    }
                } label: { Label("新建曲线", systemImage: "plus") }.fixedSize()
                    .disabled(dirty).help(dirty ? "先保存或放弃当前修改" : "新建一条风扇曲线")
                Spacer()
            }
            if let current = draft {
                let binding = Binding(get: { draft ?? current }, set: { draft = $0 })
                HStack(spacing: 10) {
                    Text("名称").foregroundStyle(.secondary)
                    TextField("曲线名称", text: Binding(get: { binding.wrappedValue.name }, set: { binding.wrappedValue.name = String($0.prefix(16)) }))
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                    Spacer()
                    Text("拖动圆点调整，双击空白处添加点").font(.subheadline).foregroundStyle(.secondary)
                }
                let points = Binding(get: { binding.wrappedValue.points(for: editingFan) },
                                     set: { binding.wrappedValue.setPoints($0, for: editingFan) })
                if fanCount > 1 { fanPicker(binding) }
                FanCurveChart(points: points, selected: $selected, fanRange: fanRange, temperature: temperature,
                              others: fanCount > 1 ? (0..<fanCount).filter { $0 != editingFan }.map { binding.wrappedValue.points(for: $0) } : [])
                    .frame(height: 230)
                pointControls(points)
                HStack(spacing: 10) {
                    if dirty { Label("有未保存的修改", systemImage: "pencil.circle").font(.subheadline).foregroundStyle(.orange) }
                    Spacer()
                    Button("删除曲线", role: .destructive) { fan.deleteCurve(current.id); draft = fan.settings.curves.first; selected = nil }
                        .disabled(saved == nil)
                    Button("放弃修改") { draft = saved; selected = nil }.disabled(!dirty || saved == nil)
                    Button("保存") { fan.saveCurve(current); draft = fan.settings.curves.first { $0.id == current.id } }.disabled(!dirty)
                    Button("保存并使用") {
                        fan.saveCurve(current); fan.select(current.id.uuidString)
                        draft = fan.settings.curves.first { $0.id == current.id }
                    }.disabled(fan.settings.preset == current.id.uuidString && !dirty)
                }
            } else {
                Text("还没有自定义曲线。点“新建曲线”，从空白或某个内置预设开始调整。").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .onAppear { if draft == nil { draft = fan.activeCurve ?? fan.settings.curves.first } }
    }

    /// One segment per fan, by its custom name, plus a way to give every fan the curve on screen.
    private func fanPicker(_ curve: Binding<FanCurve>) -> some View {
        HStack(spacing: 10) {
            Text("风扇").foregroundStyle(.secondary)
            Picker("风扇", selection: Binding(get: { editingFan }, set: { editing = $0; selected = nil })) {
                ForEach(0..<fanCount, id: \.self) { Text(fan.settings.fanName($0)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            if editingFan > 0, !curve.wrappedValue.hasOwnCurve(editingFan) {
                Text("跟随\(fan.settings.fanName(0))，拖动后单独生效").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("复制到所有风扇") {
                let current = curve.wrappedValue.points(for: editingFan)
                curve.wrappedValue.points = current
                curve.wrappedValue.copyFirstToAll()
            }.help("让每个风扇都使用“\(fan.settings.fanName(editingFan))”这条曲线")
                .disabled(curve.wrappedValue.extraFans.allSatisfy(\.isEmpty) && editingFan == 0)
        }
    }

    @ViewBuilder private func pointControls(_ points: Binding<[CurvePoint]>) -> some View {
        HStack(spacing: 14) {
            if let i = selected, points.wrappedValue.indices.contains(i) {
                let point = points.wrappedValue[i]
                Text("选中的点").foregroundStyle(.secondary)
                Stepper("\(Int(point.temp)) °C", value: Binding(get: { point.temp }, set: { newValue in
                    let others = points.wrappedValue.enumerated().filter { $0.offset != i }.map(\.element.temp)
                    let lower = others.filter { $0 < point.temp }.max().map { $0 + 1 } ?? FanCurve.tempRange.lowerBound
                    let upper = others.filter { $0 > point.temp }.min().map { $0 - 1 } ?? FanCurve.tempRange.upperBound
                    points.wrappedValue[i].temp = min(upper, max(lower, newValue))
                }), in: FanCurve.tempRange, step: 1).monospacedDigit()
                Stepper("\(Int(point.percent))%（≈ \(Int(fanRange.lowerBound + (fanRange.upperBound - fanRange.lowerBound) * point.percent / 100)) RPM）",
                        value: Binding(get: { point.percent }, set: { points.wrappedValue[i].percent = min(100, max(0, $0)) }), in: 0...100, step: 5).monospacedDigit()
                Button { points.wrappedValue.remove(at: i); selected = nil } label: { Label("删除点", systemImage: "minus.circle") }
                    .disabled(points.wrappedValue.count <= 2)
            } else {
                Text("点一下圆点可以精确调整温度和转速").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { addPoint(points) } label: { Label("添加点", systemImage: "plus.circle") }
                .disabled(points.wrappedValue.count >= FanCurve.maxPoints)
        }.buttonStyle(.borderless)
    }

    private func open(_ curve: FanCurve) {
        guard !dirty || draft?.id == curve.id else { return }
        draft = curve; selected = nil
    }
    private func newCurve(_ points: [CurvePoint], name: String) {
        draft = FanCurve(name: name, points: points); selected = nil
    }
    /// Adds a point halfway along the widest gap between neighbouring points.
    private func addPoint(_ points: Binding<[CurvePoint]>) {
        let sorted = points.wrappedValue.sorted { $0.temp < $1.temp }
        let pairs = zip(sorted, sorted.dropFirst()).map { ($0, $1) }
        guard let gap = pairs.max(by: { $0.1.temp - $0.0.temp < $1.1.temp - $1.0.temp }), gap.1.temp - gap.0.temp >= 2 else { return }
        let point = CurvePoint(temp: ((gap.0.temp + gap.1.temp) / 2).rounded(), percent: ((gap.0.percent + gap.1.percent) / 2).rounded())
        let list = (sorted + [point]).sorted { $0.temp < $1.temp }
        points.wrappedValue = list
        selected = list.firstIndex(of: point)
    }
}

/// Small, non-interactive preview of a curve for preset tiles.
struct CurveThumbnail: View {
    let curve: FanCurve
    var body: some View {
        Canvas { context, size in
            func point(_ p: CurvePoint) -> CGPoint {
                CGPoint(x: size.width * CGFloat((p.temp - 30) / 70), y: size.height - size.height * CGFloat(p.percent / 100))
            }
            func path(_ list: [CurvePoint]) -> Path? {
                let sorted = list.sorted { $0.temp < $1.temp }
                guard let first = sorted.first, let last = sorted.last else { return nil }
                var line = Path()
                line.move(to: CGPoint(x: 0, y: point(first).y))
                for p in sorted { line.addLine(to: point(p)) }
                line.addLine(to: CGPoint(x: size.width, y: point(last).y))
                return line
            }
            context.stroke(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
            // Fans with a curve of their own show as dashed lines behind fan 1's.
            for extra in curve.extraFans where !extra.isEmpty {
                if let line = path(extra) { context.stroke(line, with: .color(.accentColor.opacity(0.6)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2])) }
            }
            if let line = path(curve.points) { context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)) }
        }.accessibilityHidden(true)
    }
}
