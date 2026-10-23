import AppKit
import SwiftUI

/// The menu bar panel's window: borderless and transparent, so the SwiftUI glass inside is the
/// whole visible surface. It hangs under the status item like Control Center, without an arrow.
///
/// The window's own shadow follows the square window outline and shows as a thin frame around the
/// rounded corners, so the window carries no shadow and draws one in the panel's exact shape instead,
/// in a transparent margin around the content.
final class GlassPanel: NSPanel {
    static let margin: CGFloat = 32
    static let cornerRadius: CGFloat = 24
    /// Called for Escape; the owner decides whether a pinned panel closes too.
    var onCancel: () -> Void = {}
    private let content: NSView
    private let shade = NSView()
    init(content: NSView) {
        self.content = content
        let container = NSView()
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        shade.wantsLayer = true
        shade.layer?.shadowColor = NSColor.black.cgColor
        shade.layer?.shadowOpacity = 0.32
        shade.layer?.shadowRadius = 18
        shade.layer?.shadowOffset = CGSize(width: 0, height: -8)
        container.addSubview(shade)
        container.addSubview(content)
        // The scroll view inside is an AppKit view that SwiftUI's clip shape does not reach; the layer mask does.
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.cornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        contentView = container
        setPanelFrame(NSRect(origin: .zero, size: content.frame.size))
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }

    /// Sets where the visible panel goes, in screen coordinates; the window grows by the shadow margin.
    func setPanelFrame(_ rect: NSRect) {
        let m = Self.margin
        setFrame(rect.insetBy(dx: -m, dy: -m), display: false)
        let inner = NSRect(x: m, y: m, width: rect.width, height: rect.height)
        content.frame = inner
        shade.frame = inner
        shade.layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size),
                                         cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
        display()
    }

    /// Places the panel under `anchor` (a screen rect), centered on it and kept inside the screen.
    func place(below anchor: NSRect, on screen: NSScreen?, size: NSSize) {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let margin: CGFloat = 8
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + margin), visible.maxX - margin - size.width)
        let top = min(anchor.minY, visible.maxY) - 6
        setPanelFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height))
    }
}
