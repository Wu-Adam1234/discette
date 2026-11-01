import AppKit
import DiscetteCore
import SwiftUI

// MARK: - Design rules
//
// One object: record, controls and lyrics share a single card. Nothing floats on its own.
// Colour: from the album cover (Album colours), a neutral dark (Graphite), a light version
// of the cover colours (Paper), or the system material (Liquid Glass). Every pair is checked
// for contrast; Reduce Transparency turns glass into Graphite; Increase Contrast strengthens
// hairlines and secondary text.
// Shape: card 22pt continuous, sleeve 4pt, controls are circles.
// Motion: the record turns at 33 1/3 rpm and slides out of its sleeve while playing. Reduce
// Motion stops both.

enum Radius {
    static let card: CGFloat = 22
    static let sleeve: CGFloat = 4
    static let thumb: CGFloat = 6
}

extension RGB {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
}

private func circlePath(_ c: CGPoint, _ r: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}

// MARK: - Look

struct Look: Equatable {
    var fill: Color?          // nil = Liquid Glass
    var text: Color
    var muted: Color
    var accent: Color
    var onAccent: Color
    var hairline: Color
    var sleeveBlank: Color
    /// Liquid Glass only: 0 = frosted, 1 = clear.
    var glassClarity: Double = 0.6
    /// Liquid Glass only: 0 = no tint, 1 = strong album-colour tint.
    var glassTint: Double = 0.25

    var isGlass: Bool { fill == nil }

    static func make(_ look: PlayerLook, _ palette: ArtworkPalette, reduceTransparency: Bool, increaseContrast: Bool) -> Look {
        func from(_ p: ArtworkPalette) -> Look {
            Look(fill: p.background.color, text: p.text.color,
                 muted: (increaseContrast ? p.text : p.muted).color,
                 accent: p.accent.color, onAccent: p.background.color,
                 hairline: increaseContrast ? p.text.color.opacity(0.5) : p.surface.color,
                 sleeveBlank: p.surface.color)
        }
        switch look {
        case .album:
            return from(palette)
        case .graphite:
            var g = ArtworkPalette.fallback
            g.accent = ArtworkPalette.ensureContrast(palette.accent, on: g.background, minimum: 4.5)
            return from(g)
        case .paper:
            return from(palette.light)
        case .glass:
            if reduceTransparency {
                return make(.graphite, palette, reduceTransparency: true, increaseContrast: increaseContrast)
            }
            return Look(fill: nil, text: .primary, muted: .secondary, accent: palette.accent.color,
                        onAccent: palette.background.color,
                        hairline: .white.opacity(increaseContrast ? 0.45 : 0.16),
                        sleeveBlank: Color.primary.opacity(0.12))
        }
    }
}

struct CardSurface: ViewModifier {
    let look: Look
    var radius: CGFloat = Radius.card

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let fill = look.fill {
                content.background(shape.fill(fill))
            } else if #available(macOS 26.0, *) {
                // Apple's Liquid Glass. Clear glass above the halfway mark, regular below; a frost
                // layer thickens it as clarity drops; the album accent tints it; it reacts to the pointer.
                let base: Glass = look.glassClarity >= 0.5 ? .clear : .regular
                content
                    .background(shape.fill(Color(nsColor: .windowBackgroundColor).opacity((1 - look.glassClarity) * 0.55)))
                    .glassEffect(base.tint(look.accent.opacity(look.glassTint * 0.55)).interactive(), in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
                    .background(shape.fill(look.accent.opacity(look.glassTint * 0.3)))
            }
        }
        .overlay(shape.strokeBorder(look.hairline, lineWidth: 1).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.32), radius: 22, y: 14)
    }
}

/// Reads the accessibility environment once and builds the look.
struct LookReader<Content: View>: View {
    let style: PlayerLook
    let palette: ArtworkPalette
    var glassClarity: Double = 0.6
    var glassTint: Double = 0.25
    @ViewBuilder let content: (Look) -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        var look = Look.make(style, palette, reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased)
        look.glassClarity = glassClarity
        look.glassTint = glassTint
        return content(look)
    }
}

// MARK: - Record, sleeve, turntable

struct RecordDisc: View {
    let diameter: CGFloat
    let angle: Double
    let artwork: NSImage?
    let labelColor: Color

    var body: some View {
        Canvas { ctx, _ in
            let r = diameter / 2
            let c = CGPoint(x: r, y: r)
            let disc = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            ctx.fill(Path(ellipseIn: disc), with: .radialGradient(
                Gradient(colors: [Color(white: 0.12), Color(white: 0.045)]), center: c, startRadius: r * 0.3, endRadius: r))
            ctx.stroke(circlePath(c, r * 0.985), with: .color(.white.opacity(0.07)), lineWidth: 1)
            if diameter > 60 {
                var groove = r * 0.40
                let step = max(1.5, r * 0.018)
                while groove < r * 0.955 {
                    ctx.stroke(circlePath(c, groove), with: .color(.white.opacity(0.035)), lineWidth: 0.5)
                    groove += step
                }
                for f in [0.56, 0.69, 0.82] {
                    ctx.stroke(circlePath(c, r * f), with: .color(.black.opacity(0.55)), lineWidth: max(1, r * 0.009))
                }
            }
            ctx.fill(Path(ellipseIn: disc), with: .conicGradient(Gradient(stops: [
                .init(color: .clear, location: 0), .init(color: .white.opacity(0.10), location: 0.07),
                .init(color: .clear, location: 0.19), .init(color: .clear, location: 0.5),
                .init(color: .white.opacity(0.06), location: 0.57), .init(color: .clear, location: 0.69),
                .init(color: .clear, location: 1),
            ]), center: c, angle: .degrees(-35)))
            let lr = r * 0.33
            let labelRect = CGRect(x: c.x - lr, y: c.y - lr, width: lr * 2, height: lr * 2)
            var label = ctx
            label.translateBy(x: c.x, y: c.y)
            label.rotate(by: .degrees(angle))
            label.translateBy(x: -c.x, y: -c.y)
            label.clip(to: Path(ellipseIn: labelRect))
            if let artwork {
                label.draw(label.resolve(Image(nsImage: artwork).resizable()), in: labelRect)
            } else {
                label.fill(Path(ellipseIn: labelRect), with: .color(labelColor))
            }
            ctx.stroke(circlePath(c, lr), with: .color(.black.opacity(0.35)), lineWidth: 1)
            ctx.fill(circlePath(c, max(1.5, r * 0.022)), with: .color(Color(white: 0.03)))
        }
        .frame(width: diameter, height: diameter)
    }
}

struct Sleeve: View {
    let side: CGFloat
    let artwork: NSImage?
    let look: Look

    var body: some View {
        ZStack {
            if let artwork {
                Image(nsImage: artwork).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                // Opaque, so the record behind never shows through (glass look included).
                look.fill ?? Color(nsColor: .windowBackgroundColor)
                look.sleeveBlank
                DiscetteMarkShape().fill(look.muted.opacity(0.35)).frame(width: side * 0.3, height: side * 0.3)
            }
            LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sleeve, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.sleeve, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 6)
    }
}

/// The cover, with the record sliding out while it plays and back in when it stops.
struct SleeveDeck: View {
    let side: CGFloat
    let angle: Double
    let playing: Bool
    let hasTrack: Bool
    let artwork: NSImage?
    let look: Look
    let reduceMotion: Bool

    static func width(side: CGFloat) -> CGFloat { side * 1.42 }

    var body: some View {
        let d = side * 0.94
        let slide = !hasTrack ? side * 0.03 : (playing ? side * 0.42 : side * 0.16)
        let motion: Animation? = reduceMotion ? nil : .spring(duration: 1.2, bounce: 0.14)
        ZStack(alignment: .topLeading) {
            RecordDisc(diameter: d, angle: angle, artwork: artwork, labelColor: look.accent)
                .shadow(color: .black.opacity(0.45), radius: 8, x: 2, y: 6)
                .offset(x: (side - d) / 2 + slide, y: (side - d) / 2)
                .animation(motion, value: playing)
                .animation(motion, value: hasTrack)
            Sleeve(side: side, artwork: artwork, look: look)
        }
        .frame(width: Self.width(side: side), height: side, alignment: .topLeading)
    }
}

/// Turntable geometry. The arm pivots at a fixed point and its stylus travels from the outer
/// groove to the inner groove as the song plays, like a real arm.
struct DeckGeometry {
    let diameter: CGFloat

    var r: CGFloat { diameter / 2 }
    var size: CGSize { CGSize(width: diameter * 1.30, height: diameter * 1.04) }
    var center: CGPoint { CGPoint(x: r * 1.04, y: size.height / 2) }
    var pivot: CGPoint { CGPoint(x: center.x + r * 0.98, y: center.y - r * 0.82) }
    private var pivotToCenter: CGFloat { hypot(center.x - pivot.x, center.y - pivot.y) }
    var armLength: CGFloat { pivotToCenter * 0.97 }

    func armAngle(stylusRadius rho: CGFloat) -> Angle {
        let d = pivotToCenter, l = armLength
        let base = atan2(center.y - pivot.y, center.x - pivot.x)
        let cosPhi = max(-1, min(1, (d * d + l * l - rho * rho) / (2 * d * l)))
        return .radians(Double(base - acos(cosPhi)))
    }

    static let outerGroove: CGFloat = 0.93
    static let innerGroove: CGFloat = 0.42
    static let rest: CGFloat = 1.10
}

struct ArmShape: Shape {
    let pivot: CGPoint
    let length: CGFloat
    let r: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: pivot.x - r * 0.30, y: pivot.y - r * 0.06, width: r * 0.16, height: r * 0.12),
                         cornerSize: CGSize(width: r * 0.03, height: r * 0.03))
        p.addRoundedRect(in: CGRect(x: pivot.x - r * 0.16, y: pivot.y - r * 0.014, width: length + r * 0.08, height: r * 0.028),
                         cornerSize: CGSize(width: r * 0.014, height: r * 0.014))
        p.addRoundedRect(in: CGRect(x: pivot.x + length - r * 0.10, y: pivot.y - r * 0.04, width: r * 0.15, height: r * 0.08),
                         cornerSize: CGSize(width: r * 0.015, height: r * 0.015))
        p.addEllipse(in: CGRect(x: pivot.x - r * 0.05, y: pivot.y - r * 0.05, width: r * 0.10, height: r * 0.10))
        return p
    }
}

/// The card itself is the plinth: platter, record and arm sit straight on it.
struct TurntableDeck: View {
    let geo: DeckGeometry
    let angle: Double
    let playing: Bool
    let progress: Double
    let artwork: NSImage?
    let look: Look
    let reduceMotion: Bool

    var body: some View {
        let rho = playing
            ? geo.r * (DeckGeometry.outerGroove - (DeckGeometry.outerGroove - DeckGeometry.innerGroove) * progress)
            : geo.r * DeckGeometry.rest
        ZStack(alignment: .topLeading) {
            Circle().fill(Color(white: 0.06))
                .frame(width: geo.r * 2.06, height: geo.r * 2.06)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
                .position(geo.center)
            RecordDisc(diameter: geo.diameter, angle: angle, artwork: artwork, labelColor: look.accent)
                .position(geo.center)
            Circle().fill(look.hairline)
                .frame(width: geo.r * 0.24, height: geo.r * 0.24)
                .position(geo.pivot)
            ArmShape(pivot: geo.pivot, length: geo.armLength, r: geo.r)
                .fill(LinearGradient(colors: [Color(white: 0.88), Color(white: 0.55)], startPoint: .top, endPoint: .bottom))
                .frame(width: geo.size.width, height: geo.size.height)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 2)
                .rotationEffect(geo.armAngle(stylusRadius: rho),
                                anchor: UnitPoint(x: geo.pivot.x / geo.size.width, y: geo.pivot.y / geo.size.height))
                .animation(reduceMotion ? nil : .spring(duration: 0.9, bounce: 0.12), value: playing)
        }
        .frame(width: geo.size.width, height: geo.size.height)
    }
}

// MARK: - Controls

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: configuration.isPressed)
    }
}

struct Transport: View {
    @ObservedObject var hub: PlaybackHub
    let look: Look
    var scale: CGFloat = 1
    var keyboard = false

    var body: some View {
        let playing = hub.nowPlaying?.isPlaying == true
        HStack(spacing: 4 * scale) {
            skip("backward.fill", "Previous track", .leftArrow) { hub.previous() }
            Button { hub.playPause() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14 * scale, weight: .bold))
                    .foregroundStyle(look.onAccent)
                    .frame(width: 38 * scale, height: 38 * scale)
                    .background(Circle().fill(look.accent))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .keyboardShortcut(keyboard ? KeyboardShortcut(.space, modifiers: []) : nil)
            .accessibilityLabel(playing ? "Pause" : "Play")
            .help(playing ? "Pause" : "Play")
            skip("forward.fill", "Next track", .rightArrow) { hub.next() }
        }
    }

    private func skip(_ symbol: String, _ label: String, _ key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13 * scale, weight: .bold))
                .foregroundStyle(look.text)
                .frame(width: 32 * scale, height: 32 * scale)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .keyboardShortcut(keyboard ? KeyboardShortcut(key, modifiers: []) : nil)
        .accessibilityLabel(label)
        .help(label)
    }
}

struct Scrubber: View {
    let track: NowPlaying?
    let position: Double
    let look: Look
    let onSeek: (Double) -> Void
    @State private var dragFraction: Double?

    var body: some View {
        let duration = track?.duration ?? 0
        let fraction = dragFraction ?? (duration > 0 ? min(1, position / duration) : 0)
        VStack(spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(look.text.opacity(0.16))
                    Capsule().fill(look.accent).frame(width: max(4, geo.size.width * fraction))
                }
                .frame(height: dragFraction == nil ? 4 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { dragFraction = clamp($0.location.x / geo.size.width) }
                    .onEnded { value in
                        dragFraction = nil
                        onSeek(clamp(value.location.x / geo.size.width) * duration)
                    })
            }
            .frame(height: 14)
            .accessibilityElement()
            .accessibilityLabel("Song position")
            .accessibilityValue("\(clock(fraction * duration)) of \(clock(duration))")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onSeek(min(duration, position + 10))
                case .decrement: onSeek(max(0, position - 10))
                @unknown default: break
                }
            }
            HStack {
                Text(clock(fraction * duration))
                Spacer()
                Text("-" + clock(max(0, duration - fraction * duration)))
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(look.muted)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        .opacity(track == nil ? 0 : 1)
        .disabled(track == nil)
    }

    private func clamp(_ x: Double) -> Double { max(0, min(1, x)) }

    private func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Shrinks the open player back to the mini disc. Solid backing so it reads over cover art.
struct ShrinkButton: View {
    let look: Look
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(look.text)
                .frame(width: 26, height: 26)
                .background(Circle().fill(look.fill ?? Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(look.hairline, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Shrink to mini disc")
        .help("Shrink to mini disc")
    }
}

// MARK: - Lyrics

struct LyricsBlock: View {
    @ObservedObject var lyrics: LyricsController
    let look: Look
    let position: Double
    let lines: Int
    let fontSize: Double
    var large = false
    /// 0...1 through the song; moves unsynced lyrics along roughly with the music.
    var progress: Double = 0

    private var currentSize: Double { fontSize + (large ? 16 : 4) }

    /// Unsynced text without blank lines or section labels such as "[Chorus]".
    static func plainLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !($0.hasPrefix("[") && $0.hasSuffix("]")) }
    }
    private var otherSize: Double { fontSize + (large ? 6 : 0) }

    /// Fixed height so the player never jumps as lines change.
    static func height(lines: Int, fontSize: Double, large: Bool) -> CGFloat {
        let current = (fontSize + (large ? 16 : 4)) * 1.3 * 2
        let other = (fontSize + (large ? 6 : 0)) * 1.32 + 6
        return CGFloat(current + Double(max(0, lines - 1)) * other + 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: effectiveHeight, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lyrics")
        .accessibilityValue(spoken)
    }

    @ViewBuilder
    private var content: some View {
        switch lyrics.state {
        case .loaded(.synced(let all)):
            let current = lyrics.currentIndex(at: position)
            let first = current ?? 0
            ForEach(first..<min(all.count, first + lines), id: \.self) { i in
                let isCurrent = i == current
                Text(all[i].text.isEmpty ? "♪" : all[i].text)
                    .font(.system(size: isCurrent ? currentSize : otherSize, weight: isCurrent ? .bold : .semibold))
                    .tracking(isCurrent ? -0.4 : -0.2)
                    .foregroundStyle(isCurrent ? look.text : look.muted)
                    .lineLimit(isCurrent ? 2 : 1)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
            }
            .animation(.spring(duration: 0.45, bounce: 0.1), value: current)
        case .loaded(.plain(let text)):
            // No timing: follow the song's progress, in the secondary colour so it never
            // pretends to be exactly in sync.
            let all = Self.plainLines(text)
            let start = all.isEmpty ? 0 : min(all.count - 1, Int(progress * Double(all.count)))
            ForEach(start..<min(all.count, start + lines + 1), id: \.self) { i in
                Text(all[i])
                    .font(.system(size: otherSize + 1, weight: .semibold))
                    .foregroundStyle(look.muted)
                    .lineLimit(1)
            }
            .animation(.easeOut(duration: 0.4), value: start)
        case .loaded(.instrumental): status("Instrumental")
        case .loading: status("Looking for lyrics…")
        case .notFound: status("No lyrics for this song")
        case .failed: status("Lyrics aren't available right now")
        case .waiting, .off: EmptyView()
        }
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.system(size: otherSize, weight: .medium))
            .foregroundStyle(look.muted)
            .lineLimit(1)
    }

    /// Full height only for synced lyrics; one line for a status; nothing when idle.
    private var effectiveHeight: CGFloat {
        switch lyrics.state {
        case .loaded(.synced), .loaded(.plain): return Self.height(lines: lines, fontSize: fontSize, large: large)
        case .waiting, .off: return 0
        default: return CGFloat(otherSize * 1.4)
        }
    }

    private var spoken: String {
        switch lyrics.state {
        case .loaded(.synced): return lyrics.currentLine(at: position) ?? "Waiting for the first line"
        case .loaded(.plain): return "Lyrics without timing"
        case .loaded(.instrumental): return "Instrumental"
        case .loading: return "Looking for lyrics"
        case .notFound: return "No lyrics for this song"
        case .failed: return "Lyrics aren't available right now"
        case .waiting, .off: return "None"
        }
    }
}

// MARK: - The player card

struct PlayerCard: View {
    @ObservedObject var hub: PlaybackHub
    @ObservedObject var lyrics: LyricsController
    @ObservedObject var settings: AppSettings
    let events: PanelEvents
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let margin: CGFloat = 28

    var body: some View {
        LookReader(style: settings.look, palette: hub.palette, glassClarity: settings.glassClarity,
                   glassTint: settings.glassTint) { look in
            card(look)
        }
        .padding(Self.margin)
        .fixedSize()
    }

    private func card(_ look: Look) -> some View {
        let track = hub.nowPlaying
        let playing = track?.isPlaying ?? false
        let width = settings.size.width
        let inner = width - 36
        // "Slide the record back in": the cover stays, only the record goes home.
        let emptyWhilePaused = settings.pausedBehavior == .emptyPlayer && !playing
        let artwork = hub.artwork
        let spins = settings.spinRecord && !reduceMotion

        return TimelineView(.animation(minimumInterval: spins ? 1.0 / 30 : 0.25, paused: !playing)) { timeline in
            let position = track?.position(at: timeline.date) ?? 0
            let angle = spins ? position * 200 : 0
            VStack(alignment: .leading, spacing: 16) {
                if settings.layout != .minimal {
                    deck(inner: inner, angle: angle, playing: playing, progress: track?.progress(at: timeline.date) ?? 0,
                         artwork: artwork, hasTrack: track != nil && !emptyWhilePaused, look: look)
                        .frame(width: inner)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                header(look: look, angle: angle, artwork: artwork)
                Scrubber(track: track, position: position, look: look) { hub.seek(to: $0) }
                if settings.lyricsEnabled {
                    LyricsBlock(lyrics: lyrics, look: look, position: position, lines: settings.lyricsLines,
                                fontSize: settings.lyricsFontSize, progress: track?.progress(at: timeline.date) ?? 0)
                }
            }
            .padding(18)
            .frame(width: width, alignment: .leading)
            .background(WindowDragArea(events: events))
            .overlay(alignment: .topTrailing) {
                if settings.layout != .minimal {
                    ShrinkButton(look: look) { events.onShrink() }.padding(10)
                }
            }
            .modifier(CardSurface(look: look))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: look)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Discette player")
    }

    @ViewBuilder
    private func deck(inner: CGFloat, angle: Double, playing: Bool, progress: Double, artwork: NSImage?,
                      hasTrack: Bool, look: Look) -> some View {
        switch settings.layout {
        case .sleeve:
            SleeveDeck(side: inner / 1.42, angle: angle, playing: playing, hasTrack: hasTrack, artwork: artwork,
                       look: look, reduceMotion: reduceMotion)
        case .turntable:
            TurntableDeck(geo: DeckGeometry(diameter: inner / 1.30), angle: angle, playing: playing, progress: progress,
                          artwork: artwork, look: look, reduceMotion: reduceMotion)
        case .record:
            RecordDisc(diameter: inner * 0.88, angle: angle, artwork: artwork, labelColor: look.accent)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
        case .minimal:
            EmptyView()
        }
    }

    private func header(look: Look, angle: Double, artwork: NSImage?) -> some View {
        let track = hub.nowPlaying
        return HStack(spacing: 12) {
            if settings.layout == .minimal {
                RecordDisc(diameter: 46, angle: angle, artwork: artwork, labelColor: look.accent)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "Nothing playing")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(look.text)
                Text(subtitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(look.muted)
            }
            .lineLimit(1)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if track != nil { Transport(hub: hub, look: look) }
            if settings.layout == .minimal { ShrinkButton(look: look) { events.onShrink() } }
        }
    }

    private var subtitle: String {
        if let track = hub.nowPlaying { return track.artist }
        if let app = hub.needsPermission { return "Allow Discette to use \(app.displayName) in Privacy & Security" }
        return "Play something in Apple Music or Spotify"
    }
}

// MARK: - Mini disc (idle, or while another app is full screen)

struct MiniDiscView: View {
    @ObservedObject var hub: PlaybackHub
    @ObservedObject var settings: AppSettings
    let events: PanelEvents
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let diameter: CGFloat = 74
    static let margin: CGFloat = 18

    var body: some View {
        LookReader(style: settings.look, palette: hub.palette) { look in
            let track = hub.nowPlaying
            let playing = track?.isPlaying ?? false
            let spins = settings.spinRecord && !reduceMotion
            TimelineView(.animation(minimumInterval: spins ? 1.0 / 30 : 1, paused: !playing)) { timeline in
                let position = track?.position(at: timeline.date) ?? 0
                ZStack {
                    Circle().stroke(look.text.opacity(0.14), lineWidth: 3)
                    Circle().trim(from: 0, to: track?.progress(at: timeline.date) ?? 0)
                        .stroke(look.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    RecordDisc(diameter: Self.diameter, angle: spins ? position * 200 : 0,
                               artwork: hub.artwork, labelColor: look.accent)
                }
                .frame(width: Self.diameter + 12, height: Self.diameter + 12)
                .allowsHitTesting(false)
                .background(WindowDragArea(events: events))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
            }
            .help(track.map { "\($0.title), \($0.artist). Click to open." } ?? "Discette. Click to open.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(track.map { "Discette, \($0.title) by \($0.artist)" } ?? "Discette, nothing playing")
            .accessibilityHint("Opens the player")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { events.onClick() }
            .accessibilityAction(named: playing ? "Pause" : "Play") { hub.playPause() }
        }
        .padding(Self.margin)
        .fixedSize()
    }
}

/// What the floating panel shows right now.
struct PlayerRoot: View {
    @ObservedObject var state: PlayerState
    let hub: PlaybackHub
    let lyrics: LyricsController
    let settings: AppSettings
    let events: PanelEvents

    var body: some View {
        switch state.presentation {
        case .mini: MiniDiscView(hub: hub, settings: settings, events: events)
        case .expanded, .hidden: PlayerCard(hub: hub, lyrics: lyrics, settings: settings, events: events)
        }
    }
}

// MARK: - Menu bar mini player

struct MenuBarActions {
    var playerVisible: () -> Bool
    var togglePlayer: () -> Void
    var openFullScreen: () -> Void
    var openSettings: () -> Void
}

struct MenuBarPlayerView: View {
    @ObservedObject var hub: PlaybackHub
    @ObservedObject var lyrics: LyricsController
    @ObservedObject var settings: AppSettings
    let actions: MenuBarActions

    var body: some View {
        // The popover already has the system material, so the mini player uses the glass look
        // with the cover's accent. Reduce Transparency still falls back to solid.
        LookReader(style: .glass, palette: hub.palette) { look in
            let track = hub.nowPlaying
            TimelineView(.animation(minimumInterval: 0.25, paused: !(track?.isPlaying ?? false))) { timeline in
                let position = track?.position(at: timeline.date) ?? 0
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Group {
                            if let art = hub.artwork {
                                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                look.sleeveBlank
                            }
                        }
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.thumb, style: .continuous))
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track?.title ?? "Nothing playing").font(.system(size: 14, weight: .semibold))
                            Text(track?.artist ?? "Play something in Apple Music or Spotify")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(look.muted)
                        }
                        .lineLimit(1)
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 0)
                    }
                    Scrubber(track: track, position: position, look: look) { hub.seek(to: $0) }
                    HStack {
                        Spacer()
                        if track != nil { Transport(hub: hub, look: look, scale: 1.1, keyboard: true) }
                        Spacer()
                    }
                    if settings.lyricsEnabled, track != nil {
                        LyricsBlock(lyrics: lyrics, look: look, position: position, lines: 2, fontSize: 13,
                                    progress: track?.progress(at: timeline.date) ?? 0)
                    }
                    Divider()
                    HStack(spacing: 14) {
                        footer(actions.playerVisible() ? "Hide player" : "Show player", "rectangle.on.rectangle", actions.togglePlayer)
                        footer("Full screen", "arrow.up.left.and.arrow.down.right", actions.openFullScreen)
                        Spacer()
                        footer("Settings", "gearshape", actions.openSettings)
                    }
                }
                .padding(16)
                .frame(width: 320)
            }
        }
    }

    private func footer(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Full-screen player

struct FullScreenPlayerView: View {
    @ObservedObject var hub: PlaybackHub
    @ObservedObject var lyrics: LyricsController
    @ObservedObject var settings: AppSettings
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LookReader(style: .album, palette: hub.palette) { look in
            GeometryReader { geo in
                let side = min(geo.size.height * 0.5, geo.size.width * 0.3)
                ZStack(alignment: .topLeading) {
                    backdrop(look).ignoresSafeArea()
                    stage(look: look, side: side, width: geo.size.width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(look.text)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(look.text.opacity(0.12)))
                    }
                    .buttonStyle(PressStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Exit full screen")
                    .help("Exit full screen (Esc)")
                    .padding(32)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9), value: look)
        }
    }

    private func backdrop(_ look: Look) -> some View {
        ZStack {
            look.fill ?? .black
            if let art = hub.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    .blur(radius: 90, opaque: true)
                    .saturation(1.3)
                    .opacity(0.55)
            }
            LinearGradient(colors: [.clear, (look.fill ?? .black).opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
    }

    private func stage(look: Look, side: CGFloat, width: CGFloat) -> some View {
        let track = hub.nowPlaying
        let playing = track?.isPlaying ?? false
        let spins = settings.spinRecord && !reduceMotion
        return TimelineView(.animation(minimumInterval: spins ? 1.0 / 30 : 0.25, paused: !playing)) { timeline in
            let position = track?.position(at: timeline.date) ?? 0
            HStack(alignment: .center, spacing: width * 0.06) {
                SleeveDeck(side: side, angle: spins ? position * 200 : 0, playing: playing, hasTrack: track != nil,
                           artwork: hub.artwork, look: look, reduceMotion: reduceMotion)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(track?.title ?? "Nothing playing")
                            .font(.system(size: 40, weight: .bold)).tracking(-0.8)
                            .foregroundStyle(look.text)
                        Text(track?.artist ?? "Play something in Apple Music or Spotify")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(look.muted)
                    }
                    .lineLimit(2)
                    Scrubber(track: track, position: position, look: look) { hub.seek(to: $0) }
                    if track != nil { Transport(hub: hub, look: look, scale: 1.5, keyboard: true) }
                    if settings.lyricsEnabled {
                        LyricsBlock(lyrics: lyrics, look: look, position: position, lines: 4,
                                    fontSize: settings.lyricsFontSize, large: true,
                                    progress: track?.progress(at: timeline.date) ?? 0)
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
            }
            .padding(.horizontal, width * 0.07)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView {
            Form {
                Picker("Layout", selection: $settings.layout) {
                    ForEach(PlayerLayout.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Look", selection: $settings.look) {
                    ForEach(PlayerLook.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if settings.look == .glass {
                    Slider(value: $settings.glassClarity, in: 0...1) {
                        Text("Transparency")
                    } minimumValueLabel: {
                        Text("Frosted").font(.caption)
                    } maximumValueLabel: {
                        Text("Clear").font(.caption)
                    }
                    Slider(value: $settings.glassTint, in: 0...1) {
                        Text("Tint")
                    } minimumValueLabel: {
                        Text("None").font(.caption)
                    } maximumValueLabel: {
                        Text("Album").font(.caption)
                    }
                }
                Picker("Size", selection: $settings.size) {
                    ForEach(PlayerSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Spin the record", isOn: $settings.spinRecord)
                Text("The record stays still when Reduce Motion is on in System Settings. Liquid Glass becomes solid when Reduce Transparency is on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Player", systemImage: "opticaldisc") }

            Form {
                Toggle("Show the player", isOn: $settings.showPlayer)
                Toggle("Shrink to a mini disc when I'm not using it", isOn: $settings.autoShrink)
                Picker("After", selection: $settings.autoShrinkAfter) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
                .disabled(!settings.autoShrink)
                Picker("When another app is full screen", selection: $settings.fullScreenBehavior) {
                    ForEach(FullScreenBehavior.allCases) { Text($0.label).tag($0) }
                }
                Picker("Position", selection: $settings.pinCorner) {
                    ForEach(PinCorner.allCases) { Text($0.label).tag($0) }
                }
                Picker("When music is paused", selection: $settings.pausedBehavior) {
                    ForEach(PausedBehavior.allCases) { Text($0.label).tag($0) }
                }
                Text("Click the mini disc to open the player. Right-click the player or the menu bar icon for every option.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Behaviour", systemImage: "slider.horizontal.3") }

            Form {
                Toggle("Show lyrics", isOn: $settings.lyricsEnabled)
                Picker("Lines", selection: $settings.lyricsLines) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .pickerStyle(.segmented)
                .disabled(!settings.lyricsEnabled)
                Slider(value: $settings.lyricsFontSize, in: 12...22, step: 1) { Text("Text size") }
                    .disabled(!settings.lyricsEnabled)
                Text("Lyrics come from LRCLIB, a free community database. Discette sends only the song title, artist, album and length. Fix timing from the right-click menu.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Lyrics", systemImage: "text.quote") }

            Form {
                Toggle("Show the song title next to the icon", isOn: $settings.menuBarShowsTitle)
                TextField("Format", text: $settings.titleFormat, prompt: Text("{title} by {artist}"))
                    .disabled(!settings.menuBarShowsTitle)
                Text("Use {title}, {artist} and {album}. Off by default, so the menu bar shows only the Discette mark.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Discette is free and open source under the MIT licence.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Menu bar", systemImage: "menubar.rectangle") }
        }
        .frame(width: 500, height: 440)
    }
}
