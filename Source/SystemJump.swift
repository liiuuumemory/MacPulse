import AppKit
import SwiftUI

// Keep the property wrapper available when building with Command Line Tools.
private typealias JumpState<Value> = SwiftUI.State<Value>

/// Where a panel reading leads: the matching macOS tool, or a MacPulse settings page.
enum SystemJump {
    /// Activity Monitor's tabs, in its own `SelectedTab` numbering.
    enum MonitorTab: Int { case cpu = 0, memory = 1, energy = 2, disk = 3, network = 4 }
    case activityMonitor(MonitorTab)
    case diskUtility
    case batterySettings
    case settings(String)

    var hint: String {
        switch self {
        case .activityMonitor(let tab):
            return "点击打开活动监视器 · " + ["CPU", "内存", "能耗", "磁盘", "网络"][tab.rawValue]
        case .diskUtility: return "点击打开磁盘工具"
        case .batterySettings: return "点击打开系统设置 · 电池"
        case .settings(let page): return "点击打开 MacPulse 设置 · " + (page == "fan" ? "风扇" : page == "sensors" ? "传感器" : "设置")
        }
    }

    static let activityMonitorID = "com.apple.ActivityMonitor"

    /// Opens Activity Monitor on a tab. It only reads `SelectedTab` at launch and writes it back on quit,
    /// so a running copy on another tab is asked to quit (it holds nothing to save) and reopened.
    static func openActivityMonitor(_ tab: MonitorTab) {
        let key = "SelectedTab" as CFString, domain = activityMonitorID as CFString
        func launch() {
            CFPreferencesSetAppValue(key, NSNumber(value: tab.rawValue), domain)
            CFPreferencesSetAppValue("OpenMainWindow" as CFString, kCFBooleanTrue, domain)
            CFPreferencesAppSynchronize(domain)
            open("/System/Applications/Utilities/Activity Monitor.app")
        }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: activityMonitorID).first else { return launch() }
        CFPreferencesAppSynchronize(domain)
        if (CFPreferencesCopyAppValue(key, domain) as? Int) == tab.rawValue {
            // Already on that tab: just bring it forward.
            return open("/System/Applications/Utilities/Activity Monitor.app")
        }
        running.terminate()
        func waitThenLaunch(_ tries: Int) {
            if running.isTerminated || tries == 0 { launch(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { waitThenLaunch(tries - 1) }
        }
        waitThenLaunch(30)
    }

    private static func open(_ path: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
    }

    /// Performs the jump; MacPulse's own pages go through `openSettings`.
    func perform(openSettings: (String) -> Void) {
        switch self {
        case .activityMonitor(let tab): Self.openActivityMonitor(tab)
        case .diskUtility: Self.open("/System/Applications/Utilities/Disk Utility.app")
        case .batterySettings: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
        case .settings(let page): openSettings(page)
        }
    }
}

/// Makes a panel reading clickable: a soft highlight and pointing hand on hover, a tooltip naming the destination.
/// How a clickable reading shows hover: a halo with clear space around loose content,
/// or, for content that is already a card, the card itself darkening.
enum JumpHighlight {
    case halo(horizontal: CGFloat, vertical: CGFloat)
    case card
    static let standard = JumpHighlight.halo(horizontal: 7, vertical: 6)
}

struct JumpTarget: ViewModifier {
    let jump: SystemJump
    let detail: String?
    let highlight: JumpHighlight
    let openSettings: (String) -> Void
    // Snapshots can show every highlight at once to check their spacing.
    @JumpState private var hovering = CommandLine.arguments.contains("--snapshot-hover")
    func body(content: Content) -> some View {
        Button { jump.perform(openSettings: openSettings) } label: {
            switch highlight {
            case .halo(let horizontal, let vertical):
                // The halo reaches past the content on every side without moving it.
                content
                    .padding(.horizontal, horizontal).padding(.vertical, vertical)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
                    .contentShape(Rectangle())
                    .padding(.horizontal, -horizontal).padding(.vertical, -vertical)
            case .card:
                content
                    .overlay(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help((detail.map { $0 + "\n" } ?? "") + jump.hint)
        .accessibilityHint(jump.hint)
    }
}

extension View {
    func jump(_ target: SystemJump, detail: String? = nil, highlight: JumpHighlight = .standard, openSettings: @escaping (String) -> Void) -> some View {
        modifier(JumpTarget(jump: target, detail: detail, highlight: highlight, openSettings: openSettings))
    }
}
