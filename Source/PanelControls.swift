import AppKit
import SwiftUI

// Keep the property wrapper available when building with Command Line Tools.
private typealias ControlState<Value> = SwiftUI.State<Value>

/// A full-width glass capsule of tabs; the selected tab sits on a pill that slides between them.
struct GlassTabs<Value: Hashable>: View {
    let items: [(Value, String)]
    @Binding var selection: Value
    var height: CGFloat = 28
    /// Inside the scrolling page rather than in the header.
    var inPage = false
    @Namespace private var pill
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let selected = selection == item.0
                Button { withAnimation(.bouncy(duration: 0.35)) { selection = item.0 } } label: {
                    Text(item.1).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity).frame(height: height)
                        .background {
                            if selected {
                                Capsule().fill(scheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.78))
                                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .opacity(enabled ? 1 : 0.5)
        .modifier(TabsGlass(inPage: inPage))
    }
}

private struct TabsGlass: ViewModifier {
    let inPage: Bool
    func body(content: Content) -> some View {
        if inPage { content.pageGlass(Capsule()) } else { content.glassEffect(.regular.interactive(), in: Capsule()) }
    }
}

/// A sortable column title: the active column is brighter and carries a down arrow; hovering shows it can be clicked.
struct SortHeader: View {
    let title: String
    let active: Bool
    let action: () -> Void
    @ControlState private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(active ? 1 : 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("按\(title)排序")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A reading that opens Settings: a soft rounded highlight and a pointing hand on hover.
struct PanelLink<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder var label: Label
    @ControlState private var hovering = false
    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, -6).padding(.vertical, -4)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(help)
    }
}

/// Vertical scrolling with the same margin on both sides. The margin also holds the scroller, so a
/// legacy scroller appearing (several devices, a short screen) never shifts the page off center.
struct PanelScroll<Content: View>: View {
    let margin: CGFloat
    @ViewBuilder var content: Content
    @ControlState private var contentHeight: CGFloat = 0
    @ControlState private var viewportHeight: CGFloat = 0
    @ControlState private var style = NSScroller.preferredScrollerStyle
    /// Shown once the page has stayed taller than the panel for a moment, hidden once it fits with room to spare.
    /// A page that is switched in lays out in steps and passes the panel's height on the way, and a legacy scroller
    /// takes width, re-wraps the text and shortens the page; without the wait and the margin the scroller blinks.
    @ControlState private var showsScroller = false
    @ControlState private var pendingShow: DispatchWorkItem?
    /// Width the scroller takes from the scroll view: only a legacy scroller, only while it is shown.
    private var scrollerWidth: CGFloat {
        guard style == .legacy, showsScroller else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }
    private func updateScroller() {
        if contentHeight > viewportHeight + 1 {
            guard !showsScroller, pendingShow == nil else { return }
            let work = DispatchWorkItem { pendingShow = nil; if contentHeight > viewportHeight + 1 { showsScroller = true } }
            pendingShow = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else {
            pendingShow?.cancel(); pendingShow = nil
            if contentHeight < viewportHeight - 24 { showsScroller = false }
        }
    }
    @ControlState private var position = ScrollPosition(edge: .top)
    var body: some View {
        ScrollView(.vertical) {
            content
                .padding(.leading, margin).padding(.trailing, max(0, margin - scrollerWidth))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        // The visible height between the bars; the proxy's size already leaves out their safe-area insets.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .scrollIndicators(showsScroller ? .automatic : .never)
        .onChange(of: contentHeight) { updateScroller() }
        .onChange(of: viewportHeight) { updateScroller() }
        .scrollPosition($position)
        .onAppear {
            guard let offset = PanelCards.snapshotScroll else { return }
            // After the page has laid out, so the offset is within its height.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { position.scrollTo(y: offset) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            style = NSScroller.preferredScrollerStyle
        }
    }
}

/// One item on the devices or AI usage page: a short summary that opens into details while the pointer rests
/// on it, or on click. Only one card is open per page.
struct HoverCard<Summary: View, Detail: View>: View {
    let id: String
    @Binding var open: String?
    /// A single card on its page stays open; there is nothing else to compare it with.
    var alwaysOpen = false
    @ViewBuilder var summary: Summary
    @ViewBuilder var detail: Detail
    @ControlState private var hovering = false
    @ControlState private var pending: DispatchWorkItem?
    private var isOpen: Bool { alwaysOpen || open == id }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if isOpen {
                detail
                    .padding(.top, 12)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -8)), removal: .opacity))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.primary.opacity(isOpen ? 0.08 : hovering ? 0.07 : 0.05)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { if !alwaysOpen { setOpen(open == id ? nil : id) } }
        .onHover { inside in
            hovering = inside
            // A snapshot keeps its chosen card open whatever the pointer is doing.
            guard !alwaysOpen, !PanelCards.snapshotOpensFirst else { return }
            // A short wait keeps cards from flickering while the pointer passes over them.
            schedule(after: inside ? 0.12 : 0.3) {
                if inside, hovering { setOpen(id) }
                if !inside, !hovering, open == id { setOpen(nil) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: isOpen ? "收起" : "展开") { setOpen(isOpen ? nil : id) }
    }
    private func setOpen(_ value: String?) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { open = value }
    }
    private func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem(block: action)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

extension View {
    /// Glass for a control inside the scrolling page, optionally tinted (a selected item).
    func pageGlass<S: InsettableShape>(_ shape: S, tint: Color? = nil) -> some View {
        glassEffect(tint.map { Glass.regular.tint($0) }?.interactive() ?? .regular.interactive(), in: shape)
    }
}

enum PanelCards {
    /// `--snapshot-scroll <points>` scrolls the page down, to show content under the bars.
    static let snapshotScroll: CGFloat? = {
        let arguments = CommandLine.arguments
        guard arguments.contains("--snapshot"), let flag = arguments.firstIndex(of: "--snapshot-scroll"), flag + 1 < arguments.count,
              let value = Double(arguments[flag + 1]) else { return nil }
        return CGFloat(value)
    }()
    /// `--snapshot-open` opens the first card on a page, so screenshots show a card's details.
    static let snapshotOpensFirst = CommandLine.arguments.contains("--snapshot") && CommandLine.arguments.contains("--snapshot-open")
    /// `--snapshot-card <id>` opens that card instead of the first.
    static let snapshotCard: String? = CommandLine.arguments.firstIndex(of: "--snapshot-card").flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil }
}
