import AppKit
import DiscetteCore
import ScreenCaptureKit
import SwiftUI

// MARK: - Panel events

/// What the floating player reports back to the app: hover (for the idle timer),
/// clicks (to open the mini disc) and the right-click menu.
@MainActor
final class PanelEvents {
    var onHover: (Bool) -> Void = { _ in }
    var onActivity: () -> Void = {}
    var onClick: () -> Void = {}
    var onShrink: () -> Void = {}
    var menu: () -> NSMenu? = { nil }
    var canDrag: () -> Bool = { true }
}

/// Sits behind the player's content. Drag to move (unless pinned), click, right-click for
/// the menu. Hover is tracked even while Discette is in the background.
struct WindowDragArea: NSViewRepresentable {
    let events: PanelEvents

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.events = events
        return view
    }

    func updateNSView(_ view: DragView, context: Context) { view.events = events }

    final class DragView: NSView {
        var events: PanelEvents?
        private var tracking: NSTrackingArea?
        private var mouseStart: NSPoint?
        private var originStart: NSPoint?
        private var moved = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { MainActor.assumeIsolated { events?.onHover(true) } }
        override func mouseExited(with event: NSEvent) { MainActor.assumeIsolated { events?.onHover(false) } }
        override func mouseMoved(with event: NSEvent) { MainActor.assumeIsolated { events?.onActivity() } }

        override func mouseDown(with event: NSEvent) {
            mouseStart = NSEvent.mouseLocation
            originStart = window?.frame.origin
            moved = false
            MainActor.assumeIsolated { events?.onActivity() }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseStart, let origin = originStart,
                  MainActor.assumeIsolated({ events?.canDrag() ?? true }) else { return }
            let now = NSEvent.mouseLocation
            let dx = now.x - start.x, dy = now.y - start.y
            if !moved, hypot(dx, dy) < 3 { return }
            moved = true
            window?.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
        }

        override func mouseUp(with event: NSEvent) {
            if !moved { MainActor.assumeIsolated { events?.onClick() } }
            mouseStart = nil
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = events?.menu() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

// MARK: - Floating panel

/// A borderless panel that floats over every app and Space and never steals focus.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    private var host: NSHostingController<AnyView>!

    convenience init(name: String, root: AnyView) {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        host = NSHostingController(rootView: root)
        // place() sizes and anchors the window. Left on, SwiftUI resized it to fit by itself,
        // pinned at the top-left, so the mini disc ended up in the card's top-left corner.
        host.sizingOptions = []
        host.view.autoresizingMask = [.width, .height]
        contentView = host.view
        if !setFrameUsingName("Discette.\(name)"), let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.maxX - frame.width, y: screen.minY))
        }
        setFrameAutosaveName("Discette.\(name)")
    }

    /// The size SwiftUI wants for the current content.
    func idealSize() -> CGSize {
        host.sizeThatFits(in: CGSize(width: 5000, height: 5000))
    }

    /// Resize and position. Pinned: snap to that corner of the screen. Free: keep the corner of
    /// the window that is nearest a screen corner where it is, so the player grows and shrinks
    /// from the place you left it.
    func place(size: CGSize, pin: PinCorner) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let current = frame
        let left: Bool, bottom: Bool
        switch pin {
        case .topLeft: (left, bottom) = (true, false)
        case .topRight: (left, bottom) = (false, false)
        case .bottomLeft: (left, bottom) = (true, true)
        case .bottomRight: (left, bottom) = (false, true)
        // Free: shrink into, and grow back out of, the player's own bottom-right corner.
        case .free: (left, bottom) = (false, true)
        }
        let pinned = pin != .free
        var x = left ? (pinned ? visible.minX : current.minX) : (pinned ? visible.maxX : current.maxX) - size.width
        var y = bottom ? (pinned ? visible.minY : current.minY) : (pinned ? visible.maxY : current.maxY) - size.height
        x = min(max(x, visible.minX), visible.maxX - size.width)
        y = min(max(y, visible.minY), visible.maxY - size.height)
        let target = NSRect(x: x, y: y, width: size.width, height: size.height).integral
        if target != current { setFrame(target, display: true) }
    }
}

// MARK: - What's behind the player

/// Tells whether the screen behind the player is light or dark, so the Liquid Glass look can
/// switch its text and buttons between black and white. It looks at a 24 x 24 thumbnail of the
/// area under the card (Discette's own windows left out) every 2 s, only while the glass look
/// is showing. Needs Screen Recording permission; without it the player keeps the system look.
@MainActor
final class BackdropSampler {
    /// true = light backdrop (black text), false = dark (white text), nil = unknown (system look).
    var onChange: (Bool?) -> Void = { _ in }
    private(set) var light: Bool?
    private var timer: Timer?
    private weak var window: NSWindow?
    private var busy = false

    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }
    static func requestAccess() { CGRequestScreenCaptureAccess() }

    func update(window: NSWindow, active: Bool) {
        self.window = window
        if active, Self.isAllowed {
            guard timer == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.sample() }
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
        } else {
            timer?.invalidate()
            timer = nil
            if light != nil { light = nil; onChange(nil) }
        }
    }

    private func sample() {
        guard !busy, let window, window.isVisible, let screen = window.screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        let card = window.frame.insetBy(dx: PlayerCard.margin, dy: PlayerCard.margin)
        guard card.width > 4, card.height > 4 else { return }
        // ScreenCaptureKit measures from the display's top-left corner.
        let rect = CGRect(x: card.minX - screen.frame.minX, y: screen.frame.maxY - card.maxY,
                          width: card.width, height: card.height)
        busy = true
        Task { [weak self] in
            let luminance = try? await Self.luminance(display: id, rect: rect)
            guard let self else { return }
            self.busy = false
            guard let luminance, self.timer != nil else { return }
            let next = Backdrop.prefersDarkText(luminance: luminance, current: self.light)
            if next != self.light {
                self.light = next
                self.onChange(next)
            }
        }
    }

    private nonisolated static func luminance(display id: CGDirectDisplayID, rect: CGRect) async throws -> Double? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = 24
        config.height = 24
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []),
            configuration: config)
        let pixels = image.samplePixels(side: 16)
        guard !pixels.isEmpty else { return nil }
        return pixels.reduce(0) { $0 + $1.luminance } / Double(pixels.count)
    }
}

// MARK: - Other apps in full screen

/// Notices when the frontmost app has a window covering a whole screen (native full screen,
/// games, presentations), so the player can stay, shrink or hide as the user chose.
@MainActor
final class FullScreenWatcher {
    var onChange: (Bool) -> Void = { _ in }
    private(set) var isFullScreen = false
    private var timer: Timer?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { MainActor.assumeIsolated { self?.check() } }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// The frontmost app counts as full screen when macOS says its window is, or when one of its
    /// own normal windows covers a whole display. Only the frontmost app: background windows that
    /// happen to be screen-sized (wallpaper and overlay apps) made the player shrink on the desktop.
    private let checkQueue = DispatchQueue(label: "app.discette.fullscreen", qos: .utility)
    private var checking = false

    func check() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard !checking, let front = NSWorkspace.shared.frontmostApplication else { return }
        // While Discette itself is in front (settings, full-screen player) keep the last answer.
        if front.processIdentifier == ownPID { return }
        let pid = front.processIdentifier
        let name = front.localizedName ?? "-"
        let screens = NSScreen.screens.map(\.frame.size)
        checking = true
        // Off the main thread: asking another app over Accessibility waits for it to answer,
        // and a busy app made the player stutter.
        checkQueue.async { [weak self] in
            let (full, owner) = Self.isFullScreen(pid: pid, name: name, screens: screens)
            DispatchQueue.main.async {
                self?.checking = false
                self?.report(full, owner: owner)
            }
        }
    }

    private nonisolated static func isFullScreen(pid: pid_t, name: String, screens: [CGSize]) -> (Bool, String) {
        // 1. Ask macOS (Accessibility): reliable for native full screen, including notched Macs.
        if AccessibilityAccess.focusedWindowIsFullScreen(pid: pid) { return (true, name) }
        // 2. Borderless full-screen windows (games, presentations) that cover the whole display,
        //    notch included. Exact screen size only: a maximised window is shorter.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let match = windows.first { w in
            guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return screens.contains { abs($0.width - rect.width) < 1 && abs($0.height - rect.height) < 1 }
        }
        return (match != nil, (match?[kCGWindowOwnerName as String] as? String) ?? "-")
    }

    private func report(_ full: Bool, owner: String) {
        guard full != isFullScreen else { return }
        isFullScreen = full
        NSLog("Discette: full screen elsewhere = %@ (%@)", full ? "yes" : "no", owner)
        onChange(full)
    }
}

// MARK: - Full-screen player

@MainActor
final class FullScreenPlayerController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onClose: () -> Void = {}
    var isOpen: Bool { window != nil }

    func open(root: AnyView) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let screen = NSScreen.main else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.collectionBehavior = [.fullScreenPrimary]
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.delegate = self
        w.contentView = NSHostingView(rootView: root)
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.toggleFullScreen(nil)
    }

    func close() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else { window.close() }
    }

    func windowDidExitFullScreen(_ notification: Notification) { window?.close() }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onClose()
    }
}
