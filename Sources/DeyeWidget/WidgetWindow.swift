import AppKit
import SwiftUI

/// Transparent overlay that turns the whole widget surface into a drag handle.
/// The window content is non-interactive, so catching every click for dragging
/// is exactly what we want; a plain click (no movement) is a no-op.
private final class DragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override var mouseDownCanMoveWindow: Bool { true }
    // The app is accessory/non-activating: without this, the first click on an
    // inactive window is consumed as activation and never reaches mouseDown, so
    // dragging silently stops after the app loses focus. Returning true delivers
    // that first click straight to us so performDrag always fires.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless, desktop-level translucent window that hosts the flow graph.
final class WidgetWindow: NSWindow {
    private let cornerRadius: CGFloat = 28
    private let poller: DataPoller
    private let settings: Settings
    private let hosting: NSHostingView<FlowView>

    init(poller: DataPoller, settings: Settings) {
        self.poller = poller
        self.settings = settings
        self.hosting = NSHostingView(
            rootView: FlowView(poller: poller, settings: settings,
                               showChart: settings.showChart, scale: settings.sizePreset.scale)
        )

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true                 // shadow follows the rounded mask (below)
        isMovableByWindowBackground = true
        ignoresMouseEvents = false

        // Float just above native desktop widgets / icons but under normal app
        // windows (desktopIconWindow + 1 so macOS's own desktop widgets don't
        // draw over ours; this also helps click delivery).
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Do not steal focus.
        isReleasedWhenClosed = false

        // Real vibrancy behind the SwiftUI content.
        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        // maskImage rounds the vibrancy AND makes the window shadow follow the
        // rounded shape (no pale square corners).
        visual.maskImage = Self.roundedMaskImage(radius: cornerRadius)
        // layer masking additionally clips the SwiftUI content (its full-bleed
        // gradient) to the rounded rect so nothing renders past the corners.
        visual.wantsLayer = true
        visual.layer?.cornerRadius = cornerRadius
        visual.layer?.cornerCurve = .continuous
        visual.layer?.masksToBounds = true

        hosting.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(hosting)

        // Drag overlay on top so click-drag works everywhere on the widget.
        let dragView = DragView()
        dragView.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(dragView)

        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: visual.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
            dragView.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            dragView.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            dragView.topAnchor.constraint(equalTo: visual.topAnchor),
            dragView.bottomAnchor.constraint(equalTo: visual.bottomAnchor)
        ])

        contentView = visual
        invalidateShadow()  // recompute shadow from the rounded mask

        setFrameAutosaveName("DeyeWidgetWindow")
        if frame.origin == .zero {
            center()
        }
        applyConfig()  // apply persisted size preset + chart visibility on launch
    }

    /// Rebuild the content for the current size preset and chart visibility,
    /// resizing the window while keeping the top-left corner fixed so it doesn't
    /// jump. Text stays crisp (FlowView is parameterized, not rasterized). The
    /// 28 pt corner radius stays fixed via the resizable mask.
    func applyConfig() {
        let scale = settings.sizePreset.scale
        let showChart = settings.showChart
        hosting.rootView = FlowView(poller: poller, settings: settings,
                                    showChart: showChart, scale: scale)

        let cs = FlowView.contentSize(showChart: showChart, scale: scale)
        let newSize = NSSize(width: cs.width, height: cs.height)
        let old = frame
        let topLeftY = old.origin.y + old.size.height   // AppKit origin is bottom-left
        let newOrigin = NSPoint(x: old.origin.x, y: topLeftY - newSize.height)
        setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: false)
        invalidateShadow()
    }

    /// A resizable rounded-rect mask (black fill) with cap insets so it stretches
    /// cleanly to the window size — the canonical way to round an
    /// NSVisualEffectView and have its shadow follow the rounded shape.
    private static func roundedMaskImage(radius: CGFloat) -> NSImage {
        let diameter = radius * 2 + 1
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // Allow key so performDrag behaves consistently at desktopIconWindow level
    // (accessory app). Staying non-main avoids taking over as the app's main
    // window; being accessory means becoming key won't show a Dock icon.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
