import AppKit
import SwiftUI
import Combine

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
    private var cancellables = Set<AnyCancellable>()
    /// True while we move the window programmatically, so windowDidMove doesn't
    /// mistake an enforcement move for a manual drag and re-save the position.
    private var isEnforcing = false

    init(poller: DataPoller, settings: Settings) {
        self.poller = poller
        self.settings = settings
        self.hosting = NSHostingView(
            rootView: FlowView(poller: poller, settings: settings,
                               displayMode: settings.displayMode, scale: CGFloat(settings.scale))
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
        applyConfig(scale: CGFloat(settings.scale), mode: settings.displayMode)  // launch

        // Live-apply on change. IMPORTANT: @Published emits in willSet (before
        // the stored value commits), so we must use the value DELIVERED by the
        // publisher — never read settings.scale/displayMode back inside the sink,
        // which would still hold the OLD value and re-apply the previous config.
        settings.$scale.dropFirst().removeDuplicates()
            .sink { [weak self] newScale in
                guard let self else { return }
                self.applyConfig(scale: CGFloat(newScale), mode: self.settings.displayMode)
            }
            .store(in: &cancellables)
        settings.$displayMode.dropFirst().removeDuplicates()
            .sink { [weak self] newMode in
                guard let self else { return }
                self.applyConfig(scale: CGFloat(self.settings.scale), mode: newMode)
            }
            .store(in: &cancellables)

        // Pin-to-display: when the user selects a screen, snapshot the current
        // position relative to it, then enforce.
        settings.$pinnedScreenName.dropFirst().removeDuplicates()
            .sink { [weak self] name in self?.handlePinSelection(name) }
            .store(in: &cancellables)

        // Re-enforce the pin whenever the display arrangement changes or the Mac
        // wakes — this is when a window drifts off an (un)plugged screen.
        delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screensChanged),
            name: NSWorkspace.didWakeNotification, object: nil)

        enforcePin()   // land on the pinned screen at launch
    }

    // MARK: - Pin to display

    /// The pinned NSScreen if present, matched by name (primary) or displayID
    /// (fallback). Returns nil when unpinned or the screen is absent.
    private func pinnedScreen() -> NSScreen? {
        guard !settings.pinnedScreenName.isEmpty else { return nil }
        if let s = NSScreen.screens.first(where: { $0.localizedName == settings.pinnedScreenName }) {
            return s
        }
        if settings.pinnedDisplayID != 0 {
            return NSScreen.screens.first { Self.displayID(of: $0) == CGDirectDisplayID(settings.pinnedDisplayID) }
        }
        return nil
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Move the window to the saved relative position on the pinned screen if it
    /// isn't already there. No-op when unpinned or the screen is absent (leave the
    /// window wherever macOS put it; it re-places when the screen returns).
    func enforcePin() {
        guard let screen = pinnedScreen() else { return }
        let desired = Self.desiredOrigin(screenFrame: screen.frame, windowSize: frame.size,
                                         relX: settings.pinnedRelX, relY: settings.pinnedRelY)
        if abs(frame.origin.x - desired.x) > 1 || abs(frame.origin.y - desired.y) > 1 {
            isEnforcing = true
            setFrameOrigin(desired)
            isEnforcing = false
        }
    }

    /// Pure placement math: window origin for `relX/relY` (0=flush left/bottom,
    /// 1=flush right/top, 0.5=centered) within a screen's placeable area. Clamped
    /// so the window stays fully on-screen.
    static func desiredOrigin(screenFrame sf: NSRect, windowSize w: NSSize,
                              relX: Double, relY: Double) -> NSPoint {
        let rx = min(max(relX, 0), 1)
        let ry = min(max(relY, 0), 1)
        let x = sf.origin.x + CGFloat(rx) * max(sf.width - w.width, 0)
        let y = sf.origin.y + CGFloat(ry) * max(sf.height - w.height, 0)
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    /// Save the window's current origin normalised within a screen's placeable
    /// area (see Settings.pinnedRelX/Y).
    private func saveRelative(on screen: NSScreen) {
        let sf = screen.frame
        let w = frame.size
        let denomX = sf.width - w.width
        let denomY = sf.height - w.height
        let relX = denomX > 0 ? (frame.origin.x - sf.origin.x) / denomX : 0
        let relY = denomY > 0 ? (frame.origin.y - sf.origin.y) / denomY : 0
        settings.pinnedRelX = min(max(relX, 0), 1)
        settings.pinnedRelY = min(max(relY, 0), 1)
    }

    private func handlePinSelection(_ name: String) {
        guard !name.isEmpty, let screen = pinnedScreen() else { return }
        saveRelative(on: screen)   // remember where it is on the newly-pinned screen
        enforcePin()
    }

    @objc private func screensChanged() {
        // Defer one runloop turn so NSScreen.screens reflects the new arrangement.
        DispatchQueue.main.async { [weak self] in self?.enforcePin() }
    }

    /// Rebuild the content for the given scale + display mode, resizing the
    /// window while keeping the top-left corner fixed so it doesn't jump. Text
    /// stays crisp (FlowView is parameterized, not rasterized). The 28 pt corner
    /// radius stays fixed via the resizable mask.
    func applyConfig(scale: CGFloat, mode: DisplayMode) {
        hosting.rootView = FlowView(poller: poller, settings: settings,
                                    displayMode: mode, scale: scale)

        let cs = FlowView.contentSize(displayMode: mode, scale: scale)
        let newSize = NSSize(width: cs.width, height: cs.height)
        let old = frame
        let topLeftY = old.origin.y + old.size.height   // AppKit origin is bottom-left
        let newOrigin = NSPoint(x: old.origin.x, y: topLeftY - newSize.height)
        setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: false)
        invalidateShadow()
        enforcePin()   // a resize can push the window off the pinned screen
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

extension WidgetWindow: NSWindowDelegate {
    /// A manual drag that lands on the pinned screen updates the saved position;
    /// a drag onto another screen is temporary (it snaps back on the next
    /// screen-change or resize event).
    func windowDidMove(_ notification: Notification) {
        guard !isEnforcing, let screen = pinnedScreen(), let current = self.screen else { return }
        if Self.displayID(of: screen) == Self.displayID(of: current) {
            saveRelative(on: screen)
        }
    }
}
