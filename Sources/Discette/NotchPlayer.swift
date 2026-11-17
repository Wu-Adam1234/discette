import AppKit
import Combine
import DiscetteCore
import SwiftUI

// MARK: - Design rules
//
// Colour: pure black, the one place Discette uses it, because only #000 matches the notch hardware.
// Text and the accent come from the Graphite look, so the notch reads like the rest of the app.
// Shape: the top edge is the screen edge and its top corners curve outward like the notch's own
// shoulders; bottom corners are 10pt collapsed and the card's 24pt open (16pt padding, so the
// record and buttons inside stay concentric).
// Collapsed: exactly the notch with nothing playing (invisible); while a song is loaded, two ears
// grow out of it: the spinning record on the left, an accent progress ring on the right.
// Open (pointer on it): the same record, title, scrubber, controls and lyric line as the card.

/// The notch silhouette: concave shoulders at the top, round corners at the bottom.
struct NotchShape: Shape {
    var shoulder: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottom) }
        set { shoulder = newValue.first; bottom = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(0, min(shoulder, rect.width / 4, rect.height / 2))
        let b = max(0, min(bottom, rect.height - s, (rect.width - s * 2) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.minX + s, y: rect.minY), tangent2End: CGPoint(x: rect.minX + s, y: rect.maxY), radius: s)
        p.addArc(tangent1End: CGPoint(x: rect.minX + s, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: b)
        p.addArc(tangent1End: CGPoint(x: rect.maxX - s, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - s, y: rect.minY), radius: b)
        p.addArc(tangent1End: CGPoint(x: rect.maxX - s, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: s)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var expanded = false
    let geometry: NotchGeometry
    /// The shape's size as last laid out, including shoulders: the hover zone while open.
    var shapeSize: CGSize = .zero

    init(geometry: NotchGeometry) { self.geometry = geometry }

    static let shoulderClosed: CGFloat = 6
    static let shoulderOpen: CGFloat = 14
}

struct NotchPlayerView: View {
    @ObservedObject var hub: PlaybackHub
    @ObservedObject var lyrics: LyricsController
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: NotchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LookReader(style: .graphite, palette: hub.palette) { base in
            shape(look: Self.look(base))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Graphite's text and accent on the notch's black.
    static func look(_ base: Look) -> Look {
        var look = base
        look.fill = .black
        look.sleeveBlank = Color(white: 0.12)
        return look
    }

    private func shape(look: Look) -> some View {
        let g = model.geometry
        let track = hub.nowPlaying
        let open = model.expanded && track != nil
        // No shoulders while idle, so the shape is exactly the notch and nothing shows beside it.
        let shoulder = open ? NotchModel.shoulderOpen : (track == nil ? 0 : NotchModel.shoulderClosed)
        let bottom = open ? Radius.card : 10
        let collapsed = g.collapsedSize(hasTrack: track != nil)
        let notchShape = NotchShape(shoulder: shoulder, bottom: bottom)
        let motion: Animation? = reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.16)

        return ZStack(alignment: .top) {
            if open {
                openContent(look: look)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                            .animation(reduceMotion ? nil : .smooth(duration: 0.3).delay(0.08)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            } else if track != nil {
                ears(look: look)
                    .frame(width: collapsed.width, height: collapsed.height)
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
            }
        }
        .frame(width: open ? NotchGeometry.openWidth : collapsed.width,
               height: open ? nil : collapsed.height, alignment: .top)
        .padding(.horizontal, shoulder)
        .background(notchShape.fill(Color.black))
        .clipShape(notchShape)
        .shadow(color: .black.opacity(open ? 0.4 : 0), radius: 18, y: 10)
        .animation(motion, value: open)
        .animation(motion, value: track != nil)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.shapeSize = $0 }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Discette in the notch")
    }

    // MARK: Collapsed

    private func ears(look: Look) -> some View {
        let g = model.geometry
        let track = hub.nowPlaying
        let playing = track?.isPlaying ?? false
        let disc = g.notch.height - 10
        return HStack(spacing: 0) {
            // Black vinyl vanishes on the black notch, so the cover fills most of this one, with a
            // thin rim of record and a hairline to separate it.
            RecordDisc(diameter: disc, spinning: settings.spinRecord && !reduceMotion && playing,
                       artwork: hub.artwork, labelColor: look.accent, labelRatio: 0.74)
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                .frame(width: g.ear)
                .offset(x: 2)   // a hair toward the notch, so it sits in the ear's optical middle
            Spacer(minLength: 0)
            TimelineView(.animation(minimumInterval: 1, paused: !playing)) { timeline in
                ZStack {
                    Circle().stroke(look.text.opacity(0.18), lineWidth: 2.5)
                    Circle().trim(from: 0, to: track?.progress(at: timeline.date) ?? 0)
                        .stroke(look.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if !playing {
                        Image(systemName: "pause.fill").font(.system(size: 6.5, weight: .black)).foregroundStyle(look.muted)
                    }
                }
                .frame(width: disc - 4, height: disc - 4)
            }
            .frame(width: g.ear)
            .offset(x: -2)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(track.map { "\($0.title) by \($0.artist)" } ?? "Nothing playing")
    }

    // MARK: Open

    private func openContent(look: Look) -> some View {
        let g = model.geometry
        let track = hub.nowPlaying
        let playing = track?.isPlaying ?? false
        return TimelineView(.animation(minimumInterval: 0.5, paused: !playing)) { timeline in
            let position = track?.position(at: timeline.date) ?? 0
            VStack(alignment: .leading, spacing: 0) {
                // The hardware notch sits in this band.
                Color.clear.frame(height: g.notch.height)
                HStack(spacing: 12) {
                    RecordDisc(diameter: 54, spinning: settings.spinRecord && !reduceMotion && playing,
                               artwork: hub.artwork, labelColor: look.accent)
                        .layeredShadow(1, lift: 0.4)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track?.title ?? "Nothing playing")
                            .font(.system(size: 15, weight: .semibold))
                            .tracking(-0.2)
                            .foregroundStyle(look.text)
                        Text(track?.artist ?? "")
                            .font(.system(size: 12.5))
                            .foregroundStyle(look.muted)
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
                .padding(.bottom, 12)
                VStack(spacing: 6) {
                    Scrubber(track: track, position: position, look: look) { hub.seek(to: $0) }
                    ControlsRow(hub: hub, look: look, controls: settings.controls.filter { $0 != .queue }, scale: 0.95)
                        .frame(maxWidth: .infinity)
                }
                if settings.lyricsEnabled {
                    LyricsBlock(lyrics: lyrics, look: look, track: track, fontSize: min(settings.lyricsFontSize, 14))
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, Radius.padding + 2)
            .padding(.bottom, Radius.padding)
            .frame(width: NotchGeometry.openWidth, alignment: .leading)
        }
    }
}

// MARK: - Window

/// A borderless panel above the menu bar, hanging from the notch. It lets every click through
/// while collapsed (so it never blocks the menu bar) and opens when the pointer reaches it.
@MainActor
final class NotchController {
    let model: NotchModel
    private let panel: NSPanel
    private let hasTrack: () -> Bool
    private var monitors: [Any] = []
    private var collapse: DispatchWorkItem?
    private var opening: DispatchWorkItem?

    /// Room around the open shape for its shadow, and enough height for the tallest content.
    static let margin: CGFloat = 32
    static let maxHeight: CGFloat = 300

    static func geometry(for screen: NSScreen) -> NotchGeometry? {
        NotchGeometry(screenFrame: screen.frame, topInset: screen.safeAreaInsets.top,
                      leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
    }

    /// The built-in display, if it has a notch.
    static var notchedScreen: NSScreen? { NSScreen.screens.first { geometry(for: $0) != nil } }

    init(geometry: NotchGeometry, hub: PlaybackHub, lyrics: LyricsController, settings: AppSettings) {
        model = NotchModel(geometry: geometry)
        hasTrack = { hub.nowPlaying != nil }
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: NotchPlayerView(hub: hub, lyrics: lyrics, settings: settings, model: model))
        host.sizingOptions = []
        panel.contentView = host
        let width = NotchGeometry.openWidth + NotchModel.shoulderOpen * 2 + Self.margin * 2
        panel.setFrame(geometry.windowFrame(size: CGSize(width: width, height: Self.maxHeight)), display: false)
        panel.orderFrontRegardless()

        let handler: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.pointerMoved() } }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        collapse?.cancel()
        opening?.cancel()
        panel.orderOut(nil)
    }

    private func pointerMoved() {
        let g = model.geometry
        if !hasTrack() {
            if model.expanded { setExpanded(false) }
            opening?.cancel()
            opening = nil
            return
        }
        // Collapsed: only the notch itself opens it, so status items beside the ears stay usable.
        let hot = model.expanded ? g.hangingRect(size: model.shapeSize).insetBy(dx: -8, dy: -8) : g.notch
        let inside = hot.contains(NSEvent.mouseLocation)
        // Catch clicks only over the open shape; everywhere else (margins, shadow) they go through.
        panel.ignoresMouseEvents = !(inside && model.expanded)
        if inside {
            collapse?.cancel()
            collapse = nil
            if !model.expanded, opening == nil {
                // Open on a short dwell, not on a pointer just crossing the notch.
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.opening = nil
                        if self.model.geometry.notch.contains(NSEvent.mouseLocation), self.hasTrack() { self.setExpanded(true) }
                    }
                }
                opening = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            }
        } else if !model.expanded {
            opening?.cancel()
            opening = nil
        } else if collapse == nil {
            // A short grace period, so brushing past the edge doesn't snap it shut.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.collapse = nil
                    self?.setExpanded(false)
                }
            }
            collapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func setExpanded(_ open: Bool) {
        model.expanded = open
        panel.ignoresMouseEvents = !open
    }
}

// MARK: - Preview (development only)

/// `Discette --notch-preview` opens an ordinary window that draws this Mac's notch geometry (or a
/// 14-inch MacBook Pro's) over a mock desktop, with the notch player collapsed, open, and switching
/// between the two every 2 s. It shows the design without putting anything over the real notch, and
/// it never writes settings.
@MainActor
final class NotchPreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var hub: PlaybackHub!
    private var lyrics: LyricsController!
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        hub = PlaybackHub()
        lyrics = LyricsController()
        let settings = AppSettings()
        hub.$nowPlaying.sink { [weak self] track in
            DispatchQueue.main.async { self?.lyrics.update(for: track, enabled: true) }
        }.store(in: &bag)

        let real = NotchController.notchedScreen.flatMap(NotchController.geometry)
        let notchSize = real?.notch.size ?? CGSize(width: 190, height: 32)
        let mock = CGSize(width: 520, height: 330)
        func model(_ expanded: Bool) -> NotchModel {
            let frame = CGRect(origin: .zero, size: mock)
            let left = CGRect(x: 0, y: mock.height - notchSize.height, width: (mock.width - notchSize.width) / 2, height: notchSize.height)
            let right = left.offsetBy(dx: left.width + notchSize.width, dy: 0)
            let m = NotchModel(geometry: NotchGeometry(screenFrame: frame, topInset: notchSize.height, leftArea: left, rightArea: right)!)
            m.expanded = expanded
            return m
        }
        let toggling = model(false)
        let hub = self.hub!, lyrics = self.lyrics!
        let stage = HStack(spacing: 12) {
            NotchPreviewStage(notch: notchSize) { NotchPlayerView(hub: hub, lyrics: lyrics, settings: settings, model: model(false)) }
            NotchPreviewStage(notch: notchSize) { NotchPlayerView(hub: hub, lyrics: lyrics, settings: settings, model: model(true)) }
            NotchPreviewStage(notch: notchSize) { NotchPlayerView(hub: hub, lyrics: lyrics, settings: settings, model: toggling) }
        }
        .frame(height: mock.height)
        .padding(12)
        .background(Color(white: 0.1))

        let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: mock.width * 3 + 48, height: mock.height + 24),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Discette notch preview"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: stage)
        w.makeKeyAndOrderFront(nil)
        window = w
        print("NOTCH_PREVIEW_WINDOW \(w.windowNumber) notch \(Int(notchSize.width))x\(Int(notchSize.height)) real=\(real != nil)")
        fflush(stdout)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { toggling.expanded.toggle() }
        }
    }
}

/// A slice of desktop: wallpaper, a dark translucent menu bar and the hardware notch, with the
/// player drawn on top exactly where the real panel would hang.
private struct NotchPreviewStage<Player: View>: View {
    let notch: CGSize
    @ViewBuilder let player: () -> Player

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.36), Color(red: 0.42, green: 0.27, blue: 0.40),
                                    Color(red: 0.86, green: 0.55, blue: 0.42)], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.black.opacity(0.35)).frame(height: notch.height)
            HStack {
                Text("Music  File  Edit").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text("Mon 9:41").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 14)
            .frame(height: notch.height)
            // The hardware notch: flat top, rounded bottom corners.
            UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9).fill(.black)
                .frame(width: notch.width, height: notch.height)
            player()
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
