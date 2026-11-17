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
// Shape: concentric. Card 24pt continuous with 16pt padding, so things inset in it get 24 - 16 = 8pt.
// Controls: bare glyphs, one solid play/pause disc in the album accent (the only tinted control).
// Edges: one soft rim and a two-layer shadow (tight contact + wide ambient), never a hard border.
// Type: one family, two steps. Title semibold, everything else regular or medium in the muted colour.
// Motion: hover and press are snappy and short (under 0.25 s); colour changes are smooth. The record
// turns at 33 1/3 rpm and slides out of its sleeve while playing. Reduce Motion stops both.

enum Radius {
    static let card: CGFloat = 24
    static let padding: CGFloat = 16
    static let inset: CGFloat = card - padding
    static let sleeve: CGFloat = inset
    static let thumb: CGFloat = 8
}

enum Motion {
    static let hover = Animation.snappy(duration: 0.2)
    static let press = Animation.snappy(duration: 0.18)
    static let colour = Animation.smooth(duration: 0.6)
}

extension View {
    /// Two shadows read as a real object: a tight one where it touches, a soft one for lift.
    func layeredShadow(_ strength: Double = 1, lift: CGFloat = 1) -> some View {
        shadow(color: .black.opacity(0.22 * strength), radius: 1.5 * lift, y: 1 * lift)
            .shadow(color: .black.opacity(0.26 * strength), radius: 14 * lift, y: 9 * lift)
    }
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
    /// The play/pause disc and its glyph: the strongest pair the look has.
    var primary: Color
    var onPrimary: Color
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
                 sleeveBlank: p.surface.color, primary: p.accent.color, onPrimary: p.background.color)
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
            // Text is black on a light backdrop, white on a dark one (see BackdropSampler). The
            // play disc is solid album accent: glass vibrancy turned a `.primary` disc muddy grey.
            return Look(fill: nil, text: .primary, muted: .secondary, accent: palette.accent.color,
                        onAccent: palette.background.color,
                        hairline: .white.opacity(increaseContrast ? 0.45 : 0.16),
                        sleeveBlank: Color.primary.opacity(0.12),
                        primary: palette.accent.color, onPrimary: palette.background.color)
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
        .overlay {
            // One rim only. Glass: light catching the top edge and fading round the sides.
            // Solid looks: a faint inner ring that separates the card from any desktop.
            if look.isGlass {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.05), .white.opacity(0.14)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            } else {
                shape.strokeBorder(look.hairline.opacity(0.7), lineWidth: 1)
            }
        }
        // No compositingGroup here: it renders off screen, so Liquid Glass couldn't see the desktop.
        .layeredShadow(1.15, lift: 1.5)
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

/// The record label, turned by Core Animation at 33 1/3 rpm. The window server runs the
/// rotation itself, at the display's frame rate, so it never hitches and costs the app nothing per
/// frame. (Driving it from the polled song position made it jump about every half turn.) When the
/// music pauses it stops where it is and carries on from there.
struct SpinningLabel: NSViewRepresentable {
    let artwork: NSImage?
    let color: NSColor
    let spinning: Bool

    func makeNSView(context: Context) -> LabelView { LabelView() }

    func updateNSView(_ view: LabelView, context: Context) {
        view.update(artwork: artwork, color: color, spinning: spinning)
    }

    final class LabelView: NSView {
        private let disc = CALayer()
        private weak var shownArtwork: NSImage?
        private var isSpinning = false
        private var angle = 0.0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            disc.masksToBounds = true
            disc.contentsGravity = .resizeAspectFill
            layer?.addSublayer(disc)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            disc.frame = bounds
            disc.cornerRadius = bounds.width / 2
            CATransaction.commit()
        }

        func update(artwork: NSImage?, color: NSColor, spinning: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if artwork !== shownArtwork || artwork == nil {
                disc.contents = artwork?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                shownArtwork = artwork
            }
            disc.backgroundColor = color.cgColor
            CATransaction.commit()
            guard spinning != isSpinning else { return }
            isSpinning = spinning
            if spinning {
                // Pick up from wherever the record is now, even part-way through a coast.
                angle = (disc.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double) ?? angle
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                disc.removeAnimation(forKey: "coast")
                disc.setValue(angle, forKeyPath: "transform.rotation.z")
                CATransaction.commit()
                let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                turn.fromValue = angle
                turn.toValue = angle - 2 * .pi   // negative is clockwise here
                turn.duration = 1.8              // 33 1/3 rpm
                turn.repeatCount = .infinity
                turn.isRemovedOnCompletion = false
                disc.add(turn, forKey: "spin")
            } else {
                // Coast to a stop like a platter losing power, instead of freezing mid-turn.
                // At full speed it turns 2π per 1.8 s; an ease-out over 0.7 s covers about half that.
                let current = (disc.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double) ?? angle
                let coast = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.7
                angle = current - (2 * .pi / 1.8) * coast / 2
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                disc.removeAnimation(forKey: "spin")
                disc.setValue(angle, forKeyPath: "transform.rotation.z")
                CATransaction.commit()
                guard coast > 0 else { return }
                let stop = CABasicAnimation(keyPath: "transform.rotation.z")
                stop.fromValue = current
                stop.toValue = angle
                stop.duration = coast
                stop.timingFunction = CAMediaTimingFunction(name: .easeOut)
                disc.add(stop, forKey: "coast")
            }
        }
    }
}

struct RecordDisc: View {
    let diameter: CGFloat
    var spinning = false
    let artwork: NSImage?
    let labelColor: Color
    /// 38% is where real 12-inch labels sit; tiny discs (the notch) enlarge it so the cover reads.
    var labelRatio: CGFloat = 0.38

    var body: some View {
        let r = diameter / 2
        let lr = r * labelRatio
        ZStack {
            Canvas { ctx, _ in
                let c = CGPoint(x: r, y: r)
                let disc = CGRect(x: 0, y: 0, width: diameter, height: diameter)
                ctx.fill(Path(ellipseIn: disc), with: .radialGradient(
                    Gradient(colors: [Color(white: 0.12), Color(white: 0.045)]), center: c, startRadius: r * 0.3, endRadius: r))
                ctx.stroke(circlePath(c, r * 0.985), with: .color(.white.opacity(0.07)), lineWidth: 1)
                if diameter > 60 {
                    var groove = r * 0.44
                    let step = max(1.5, r * 0.018)
                    while groove < r * 0.955 {
                        ctx.stroke(circlePath(c, groove), with: .color(.white.opacity(0.035)), lineWidth: 0.5)
                        groove += step
                    }
                    for f in [0.56, 0.69, 0.82] {
                        ctx.stroke(circlePath(c, r * f), with: .color(.black.opacity(0.55)), lineWidth: max(1, r * 0.009))
                    }
                }
                // The sheen stays put while the record turns under it, like light on real vinyl.
                ctx.fill(Path(ellipseIn: disc), with: .conicGradient(Gradient(stops: [
                    .init(color: .clear, location: 0), .init(color: .white.opacity(0.10), location: 0.07),
                    .init(color: .clear, location: 0.19), .init(color: .clear, location: 0.5),
                    .init(color: .white.opacity(0.06), location: 0.57), .init(color: .clear, location: 0.69),
                    .init(color: .clear, location: 1),
                ]), center: c, angle: .degrees(-35)))
            }
            // Only the label turns: grooves look the same at any angle.
            SpinningLabel(artwork: artwork, color: NSColor(labelColor), spinning: spinning)
                .frame(width: lr * 2, height: lr * 2)
            Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1).frame(width: lr * 2, height: lr * 2)
            Circle().fill(Color(white: 0.03)).frame(width: max(3, r * 0.044), height: max(3, r * 0.044))
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
        .overlay(RoundedRectangle(cornerRadius: Radius.sleeve, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .layeredShadow(1.1, lift: 0.8)
    }
}

/// The cover, with the record sliding out while it plays and back in when it stops.
struct SleeveDeck: View {
    let side: CGFloat
    let spinning: Bool
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
            RecordDisc(diameter: d, spinning: spinning, artwork: artwork, labelColor: look.accent)
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
    let spinning: Bool
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
            RecordDisc(diameter: geo.diameter, spinning: spinning, artwork: artwork, labelColor: look.accent)
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
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// One transport control. Secondary controls are bare glyphs with a soft circle on hover;
/// play/pause is a solid disc in the strongest colour pair the look has, so it reads on any
/// backdrop. Shuffle, repeat and the like show they're on with the accent colour and a dot.
struct ControlButton: View {
    let symbol: String
    let label: String
    let look: Look
    var scale: CGFloat = 1
    var prominent = false
    var active = false
    var enabled = true
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let side = (prominent ? 38 : 30) * scale
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: (prominent ? 15 : 13) * scale, weight: prominent ? .bold : .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(prominent ? look.onPrimary : (active ? look.accent : look.text.opacity(hovering && enabled ? 1 : 0.86)))
                // A play triangle's visual weight sits left of its box; nudge it to look centred.
                .offset(x: symbol == "play.fill" ? 1.5 * scale : 0)
                .frame(width: side, height: side)
                .background {
                    if prominent {
                        Circle().fill(look.primary)
                            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                            .shadow(color: look.primary.opacity(hovering && enabled ? 0.55 : 0.35), radius: hovering ? 9 : 6, y: 2)
                    } else {
                        Circle().fill(look.text.opacity(hovering && enabled ? 0.10 : 0))
                    }
                }
                .overlay(alignment: .bottom) {
                    if active, !prominent {
                        Circle().fill(look.accent).frame(width: 3.5 * scale, height: 3.5 * scale).offset(y: -1 * scale)
                    }
                }
                .scaleEffect(prominent && hovering && enabled ? 1.04 : 1)
                .animation(Motion.hover, value: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .help(help ?? label)
    }
}

/// The controls the user picked in Settings, in a fixed, familiar order.
struct ControlsRow: View {
    @ObservedObject var hub: PlaybackHub
    let look: Look
    let controls: [PlayerControl]
    var scale: CGFloat = 1
    var keyboard = false
    /// Up next toggle; nil where there is no room for the list (menu bar, full screen).
    var queueOpen = false
    var onQueue: (() -> Void)?

    var body: some View {
        HStack(spacing: 6 * scale) {
            ForEach(controls) { control in button(control) }
        }
    }

    @ViewBuilder
    private func button(_ control: PlayerControl) -> some View {
        let track = hub.nowPlaying
        switch control {
        case .playPause:
            let playing = track?.isPlaying == true
            ControlButton(symbol: playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play",
                          look: look, scale: scale, prominent: true) { hub.playPause() }
                .keyboardShortcut(keyboard ? KeyboardShortcut(.space, modifiers: []) : nil)
        case .previous:
            ControlButton(symbol: "backward.fill", label: "Previous track", look: look, scale: scale) { hub.previous() }
                .keyboardShortcut(keyboard ? KeyboardShortcut(.leftArrow, modifiers: []) : nil)
        case .next:
            ControlButton(symbol: "forward.fill", label: "Next track", look: look, scale: scale) { hub.next() }
                .keyboardShortcut(keyboard ? KeyboardShortcut(.rightArrow, modifiers: []) : nil)
        case .shuffle:
            ControlButton(symbol: "shuffle", label: track?.shuffle == true ? "Shuffle is on" : "Shuffle is off",
                          look: look, scale: scale, active: track?.shuffle == true, enabled: track?.shuffle != nil) {
                hub.toggleShuffle()
            }
        case .repeatMode:
            let mode = track?.repeatMode
            ControlButton(symbol: mode == .one ? "repeat.1" : "repeat",
                          label: mode == .one ? "Repeat one" : (mode == .all ? "Repeat all" : "Repeat is off"),
                          look: look, scale: scale, active: (mode ?? .off) != .off, enabled: mode != nil) {
                hub.cycleRepeat()
            }
        case .favorite:
            let favorite = track?.favorite
            ControlButton(symbol: favorite == true ? "heart.fill" : "heart",
                          label: favorite == true ? "Remove from favourites" : "Add to favourites",
                          look: look, scale: scale, active: favorite == true, enabled: favorite != nil,
                          help: favorite == nil && track?.source == .spotify
                              ? "Spotify doesn't let other apps save songs" : nil) {
                hub.toggleFavorite()
            }
        case .queue:
            if let onQueue {
                ControlButton(symbol: "list.bullet", label: queueOpen ? "Hide up next" : "Show up next",
                              look: look, scale: scale, active: queueOpen, action: onQueue)
            }
        }
    }
}

/// Live levels from the player's audio, drawn as five thin bars in the accent colour.
struct LevelBars: View {
    @ObservedObject var visualizer: Visualizer
    let color: Color
    var height: CGFloat = 16

    /// Watches the visualizer itself, so its 30 updates a second redraw only the bars.
    var body: some View {
        if visualizer.status == .running {
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<Visualizer.bandCount, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: max(3, height * CGFloat(visualizer.levels[i])))
                }
            }
            .frame(height: height)
            .animation(.linear(duration: 0.07), value: visualizer.levels)
            .accessibilityHidden(true)
        }
    }
}

struct Scrubber: View {
    let track: NowPlaying?
    let position: Double
    let look: Look
    let onSeek: (Double) -> Void
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        let duration = track?.duration ?? 0
        let fraction = dragFraction ?? (duration > 0 ? min(1, position / duration) : 0)
        let active = hovering || dragFraction != nil
        VStack(spacing: 4) {
            GeometryReader { geo in
                // A thin line at rest that firms up under the pointer, with a knob only while it can be grabbed.
                let barHeight: CGFloat = dragFraction != nil ? 7 : (hovering ? 5.5 : 3.5)
                ZStack(alignment: .leading) {
                    Capsule().fill(look.text.opacity(active ? 0.20 : 0.14))
                    Capsule().fill(look.accent).frame(width: max(barHeight, geo.size.width * fraction))
                }
                .frame(height: barHeight)
                // An overlay, so the knob never takes layout space (inside the stack it made the bar 11pt tall).
                .overlay(alignment: .leading) {
                    Circle().fill(look.accent)
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                        .frame(width: 11, height: 11)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .scaleEffect(active ? 1 : 0.3)
                        .opacity(active ? 1 : 0)
                        .offset(x: max(0, min(geo.size.width - 11, geo.size.width * fraction - 5.5)))
                }
                .frame(maxHeight: .infinity)
                .animation(Motion.hover, value: hovering)
                .animation(Motion.hover, value: dragFraction == nil)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
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
            .opacity(active ? 1 : 0.8)
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

/// Shrinks the open player back to the mini disc. Over the cover it is a dark smoked disc with a
/// white glyph, which reads on any artwork; in the header it sits in the look's own colours.
struct ShrinkButton: View {
    let look: Look
    var overArt = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(overArt ? .white : look.text)
                .frame(width: 26, height: 26)
                .background(Circle().fill(overArt ? Color.black.opacity(hovering ? 0.55 : 0.4)
                                                  : look.text.opacity(hovering ? 0.14 : 0.08)))
                .background { if overArt { Circle().fill(.ultraThinMaterial) } }
                .overlay(Circle().strokeBorder(.white.opacity(overArt ? 0.22 : 0.1), lineWidth: 0.5))
                .animation(Motion.hover, value: hovering)
                .contentShape(Circle())
        }
        .onHover { hovering = $0 }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Shrink to mini disc")
        .help("Shrink to mini disc")
    }
}

// MARK: - Lyrics

/// One line of lyrics that fills in as it is sung: the words appear as the song reaches them, and
/// a long line scrolls to keep the newest words in view. Always one line, at a fixed height, so
/// the player never changes size between songs.
struct LyricsBlock: View {
    @ObservedObject var lyrics: LyricsController
    let look: Look
    let track: NowPlaying?
    let fontSize: Double
    var large = false

    private var size: Double { fontSize + (large ? 16 : 4) }

    /// Unsynced text without blank lines or section labels such as "[Chorus]".
    static func plainLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !($0.hasPrefix("[") && $0.hasSuffix("]")) }
    }

    static func height(fontSize: Double, large: Bool) -> CGFloat {
        CGFloat((fontSize + (large ? 16 : 4)) * 1.35 + 4)
    }

    var body: some View {
        Group {
            if let track, track.isPlaying, lyrics.syncedLines != nil {
                // Redraw only at the moments a word appears or the line changes, not every frame:
                // each redraw lays out the whole card, and doing that 15 times a second was most
                // of Discette's CPU.
                let now = track.position(at: Date())
                let dates = lyrics.changePositions(from: now).map { track.positionDate.addingTimeInterval($0 - track.position) }
                TimelineView(.explicit(dates)) { timeline in line(at: timeline.date) }
            } else {
                TimelineView(.animation(minimumInterval: 1, paused: !(track?.isPlaying ?? false))) { timeline in
                    line(at: timeline.date)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func line(at date: Date) -> some View {
        // A hair past the moment, so a word due exactly now is shown.
        let position = (track?.position(at: date) ?? 0) + 0.01
        return content(position: position, progress: track?.progress(at: date) ?? 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: effectiveHeight, alignment: .leading)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Lyrics")
            .accessibilityValue(spoken(at: position))
    }

    @ViewBuilder
    private func content(position: Double, progress: Double) -> some View {
        switch lyrics.state {
        case .loaded(.synced(let all)):
            let current = lyrics.currentIndex(at: position)
            let text = current.map { all[$0].text } ?? ""
            let shown = current == nil ? "" : (text.isEmpty ? "♪" : LyricsSync.revealed(text, progress: lyrics.lineProgress(at: position)))
            ZStack(alignment: .leading) {
                // Semibold, a step under the title, so the song name stays the headline.
                Text(shown)
                    .font(.system(size: size, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(look.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .id(current)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 5)),
                                            removal: .opacity.combined(with: .offset(y: -3))))
            }
            .animation(.smooth(duration: 0.25), value: current)
        case .loaded(.plain(let text)):
            // No timing: follow the song's progress, in the secondary colour so it never
            // pretends to be exactly in sync.
            let all = Self.plainLines(text)
            let i = all.isEmpty ? 0 : min(all.count - 1, Int(progress * Double(all.count)))
            Text(all.isEmpty ? "" : all[i])
                .font(.system(size: size - 2, weight: .semibold))
                .foregroundStyle(look.muted)
                .lineLimit(1)
        case .loaded(.instrumental): status("Instrumental")
        case .loading: status("Looking for lyrics…")
        case .notFound: status("No lyrics for this song")
        case .failed: status("Lyrics aren't available right now")
        case .waiting, .off: EmptyView()
        }
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.system(size: size - 3, weight: .medium))
            .foregroundStyle(look.muted)
            .lineLimit(1)
    }

    private var effectiveHeight: CGFloat {
        switch lyrics.state {
        case .waiting, .off: return 0
        default: return Self.height(fontSize: fontSize, large: large)
        }
    }

    private func spoken(at position: Double) -> String {
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

// MARK: - Up next

/// The next songs from the playlist Music is playing. Click one to play it.
struct QueueList: View {
    @ObservedObject var hub: PlaybackHub
    let look: Look

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(look.muted)
                .lineLimit(1)
                .padding(.bottom, 4)
            if let items = hub.queue?.items, !items.isEmpty {
                ForEach(items) { item in
                    QueueRow(item: item, look: look) { hub.playQueued(item.index) }
                }
            } else {
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundStyle(look.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        guard let q = hub.queue else { return "Up next" }
        // Music doesn't share the shuffled order, only the playlist's own.
        return q.shuffled ? "From \u{201C}\(q.playlist)\u{201D}, shuffled" : "Up next from \u{201C}\(q.playlist)\u{201D}"
    }

    private var emptyText: String {
        if hub.nowPlaying?.source == .spotify { return "Spotify doesn't share its queue with other apps." }
        if hub.queue != nil { return "That's the end of the playlist." }
        return "Music isn't playing from a playlist, so there's nothing to list."
    }
}

struct QueueRow: View {
    let item: PlayQueue.Item
    let look: Look
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(look.text)
                Text(item.artist).font(.system(size: 11)).foregroundStyle(look.muted)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(look.text.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(item.title) by \(item.artist)")
        .accessibilityHint("Plays this song")
        .help("Play \(item.title)")
    }
}

// MARK: - The player card

struct PlayerCard: View {
    @ObservedObject var hub: PlaybackHub
    @ObservedObject var lyrics: LyricsController
    @ObservedObject var settings: AppSettings
    let events: PanelEvents
    let visualizer: Visualizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var hovering = false

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
        let width = CGFloat(settings.playerWidth)
        let inner = width - Radius.padding * 2
        let scale = min(1.12, max(0.88, width / 320))
        // "Slide the record back in": the cover stays, only the record goes home.
        let emptyWhilePaused = settings.pausedBehavior == .emptyPlayer && !playing
        let artwork = hub.artwork
        let spins = settings.spinRecord && !reduceMotion

        // The record turns in Core Animation, so this only moves the scrubber and the arm.
        return TimelineView(.animation(minimumInterval: 0.5, paused: !playing)) { timeline in
            let position = track?.position(at: timeline.date) ?? 0
            let spinning = spins && playing
            // Spacing groups what belongs together: art, then the song, then the transport block
            // (scrubber hugging its buttons), then lyrics.
            VStack(alignment: .leading, spacing: 0) {
                if settings.layout != .minimal {
                    deck(inner: inner, spinning: spinning, playing: playing, progress: track?.progress(at: timeline.date) ?? 0,
                         artwork: artwork, hasTrack: track != nil && !emptyWhilePaused, look: look)
                        .frame(width: inner)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .padding(.bottom, 16)
                }
                header(look: look, spinning: spinning, artwork: artwork)
                    .padding(.bottom, 12)
                VStack(spacing: 6) {
                    Scrubber(track: track, position: position, look: look) { hub.seek(to: $0) }
                    if track != nil {
                        ControlsRow(hub: hub, look: look, controls: settings.controls, scale: scale,
                                    queueOpen: settings.showQueue, onQueue: { settings.showQueue.toggle() })
                            .frame(maxWidth: .infinity)
                    }
                }
                if settings.lyricsEnabled {
                    LyricsBlock(lyrics: lyrics, look: look, track: track, fontSize: settings.lyricsFontSize)
                        .padding(.top, 10)
                }
                if settings.showQueue, track != nil {
                    Rectangle().fill(look.text.opacity(0.08)).frame(height: 1).padding(.vertical, 12)
                    QueueList(hub: hub, look: look)
                }
            }
            .padding(Radius.padding)
            .frame(width: width, alignment: .leading)
            .background(WindowDragArea(events: events))
            .overlay(alignment: .topTrailing) {
                // Window chrome stays out of the way until the pointer is on the player.
                if settings.layout != .minimal {
                    ShrinkButton(look: look, overArt: true) { events.onShrink() }
                        .padding(Radius.inset + 2)
                        // Always shown with VoiceOver: a fully transparent view drops out of it.
                        .opacity(hovering || voiceOver ? 1 : 0)
                        .scaleEffect(hovering || voiceOver ? 1 : 0.9)
                        .animation(Motion.hover, value: hovering)
                }
            }
            .onHover { hovering = $0 }
            .modifier(CardSurface(look: look))
            .animation(reduceMotion ? nil : Motion.colour, value: look)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Discette player")
    }

    @ViewBuilder
    private func deck(inner: CGFloat, spinning: Bool, playing: Bool, progress: Double, artwork: NSImage?,
                      hasTrack: Bool, look: Look) -> some View {
        switch settings.layout {
        case .sleeve:
            SleeveDeck(side: inner / 1.42, spinning: spinning && hasTrack, playing: playing, hasTrack: hasTrack, artwork: artwork,
                       look: look, reduceMotion: reduceMotion)
        case .turntable:
            TurntableDeck(geo: DeckGeometry(diameter: inner / 1.30), spinning: spinning, playing: playing, progress: progress,
                          artwork: artwork, look: look, reduceMotion: reduceMotion)
        case .record:
            RecordDisc(diameter: inner * 0.88, spinning: spinning, artwork: artwork, labelColor: look.accent)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
        case .minimal:
            EmptyView()
        }
    }

    private func header(look: Look, spinning: Bool, artwork: NSImage?) -> some View {
        return HStack(spacing: 12) {
            if settings.layout == .minimal {
                RecordDisc(diameter: 46, spinning: spinning, artwork: artwork, labelColor: look.accent)
                    .layeredShadow(1, lift: 0.4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(hub.nowPlaying?.title ?? "Nothing playing")
                    .font(.system(size: 16.5, weight: .semibold))
                    .tracking(-0.25)
                    .foregroundStyle(look.text)
                Text(subtitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(look.muted)
            }
            .truncationMode(.tail)
            .lineLimit(1)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if settings.showVisualizer {
                LevelBars(visualizer: visualizer, color: look.accent, height: 18)
            }
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
    static let margin: CGFloat = PlayerCard.margin
    /// Known up front, so the window can shrink to it at once.
    static let windowSize = CGSize(width: diameter + 12 + margin * 2, height: diameter + 12 + margin * 2)

    var body: some View {
        LookReader(style: settings.look, palette: hub.palette) { look in
            let track = hub.nowPlaying
            let playing = track?.isPlaying ?? false
            let spins = settings.spinRecord && !reduceMotion
            TimelineView(.animation(minimumInterval: 0.5, paused: !playing)) { timeline in
                ZStack {
                    Circle().stroke(look.text.opacity(0.14), lineWidth: 3)
                    Circle().trim(from: 0, to: track?.progress(at: timeline.date) ?? 0)
                        .stroke(look.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    RecordDisc(diameter: Self.diameter, spinning: spins && playing,
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
    let visualizer: Visualizer

    var body: some View {
        switch state.presentation {
        case .mini: MiniDiscView(hub: hub, settings: settings, events: events)
        case .expanded, .hidden: PlayerCard(hub: hub, lyrics: lyrics, settings: settings, events: events, visualizer: visualizer)
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
    @ObservedObject var stats: StatsStore
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
                            Text(track?.title ?? "Nothing playing").font(.system(size: 14.5, weight: .semibold)).tracking(-0.2)
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
                        if track != nil { ControlsRow(hub: hub, look: look, controls: settings.controls, scale: 1.1, keyboard: true) }
                        Spacer()
                    }
                    if settings.lyricsEnabled, track != nil {
                        LyricsBlock(lyrics: lyrics, look: look, track: track, fontSize: 13)
                    }
                    Text("Today \(ListeningStats.format(stats.stats.today())), \(stats.stats.streak())-day streak")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(look.muted)
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
        return TimelineView(.animation(minimumInterval: 0.25, paused: !playing)) { timeline in
            let position = track?.position(at: timeline.date) ?? 0
            HStack(alignment: .center, spacing: width * 0.06) {
                SleeveDeck(side: side, spinning: spins && playing, playing: playing, hasTrack: track != nil,
                           artwork: hub.artwork, look: look, reduceMotion: reduceMotion)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(track?.title ?? "Nothing playing")
                            .font(.system(size: 42, weight: .bold)).tracking(-1.1)
                            .foregroundStyle(look.text)
                        Text(track?.artist ?? "Play something in Apple Music or Spotify")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(look.muted)
                    }
                    .lineLimit(2)
                    Scrubber(track: track, position: position, look: look) { hub.seek(to: $0) }
                    if track != nil { ControlsRow(hub: hub, look: look, controls: settings.controls, scale: 1.5, keyboard: true) }
                    if settings.lyricsEnabled {
                        LyricsBlock(lyrics: lyrics, look: look, track: track,
                                    fontSize: settings.lyricsFontSize, large: true)
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
    @ObservedObject var stats: StatsStore
    @State private var openAtLogin = LoginItem.isEnabled

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
                    ScreenCaptureRow()
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
                Slider(value: $settings.playerWidth, in: PlayerWidth.range) {
                    Text("Size")
                } minimumValueLabel: {
                    Text("Small").font(.caption)
                } maximumValueLabel: {
                    Text("Large").font(.caption)
                }
                Section("Controls on the player") {
                    ForEach(PlayerControl.allCases) { control in
                        Toggle(control.label, isOn: Binding(get: { settings.controls.contains(control) },
                                                            set: { settings.setControl(control, $0) }))
                    }
                }
                Toggle("Live visualizer", isOn: $settings.showVisualizer)
                Toggle("Spin the record", isOn: $settings.spinRecord)
                Text("The record stays still when Reduce Motion is on in System Settings. Liquid Glass becomes solid when Reduce Transparency is on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Player", systemImage: "opticaldisc") }

            Form {
                Toggle("Show the player", isOn: $settings.showPlayer)
                Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: { LoginItem.set($0); openAtLogin = LoginItem.isEnabled }))
                AccessibilityRow()
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
                Toggle(isOn: $settings.notchPlayer) {
                    Text("Show the song beside the notch")
                    Text("On MacBooks with a notch: a small record and progress ring sit beside it. Point at the notch to open the controls.")
                }
                .disabled(NotchController.notchedScreen == nil && !settings.notchPlayer)
                Text("Click the mini disc to open the player. Right-click the player or the menu bar icon for every option.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Behaviour", systemImage: "slider.horizontal.3") }

            Form {
                Toggle("Show lyrics", isOn: $settings.lyricsEnabled)
                Slider(value: $settings.lyricsFontSize, in: 12...22, step: 1) { Text("Text size") }
                    .disabled(!settings.lyricsEnabled)
                Slider(value: $settings.lyricsDelay, in: -3...3, step: 0.1) {
                    Text("Timing")
                } minimumValueLabel: {
                    Text("Later").font(.caption)
                } maximumValueLabel: {
                    Text("Earlier").font(.caption)
                }
                .disabled(!settings.lyricsEnabled)
                HStack {
                    Text(timingText).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("Reset") { settings.lyricsDelay = 0 }.disabled(settings.lyricsDelay == 0)
                }
                Text("Lyrics come from LRCLIB, a free community database. Discette sends only the song title, artist, album and length. Timing here applies to every song; fix a single song from the right-click menu.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Lyrics", systemImage: "text.quote") }

            StatsView(stats: stats)
                .tabItem { Label("Stats", systemImage: "chart.bar") }

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
        .frame(width: 520, height: 520)
    }
}

extension SettingsView {
    var timingText: String {
        let v = (settings.lyricsDelay * 10).rounded() / 10
        if v == 0 { return "In time with the song" }
        return String(format: v > 0 ? "%.1f s earlier" : "%.1f s later", abs(v))
    }
}

// MARK: - Settings pieces

/// Liquid Glass picks black or white text from what's behind it, which needs Screen Recording.
struct ScreenCaptureRow: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            if !BackdropSampler.isAllowed {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Match text to the background")
                        Text("Allow Discette in Privacy & Security, Screen & System Audio Recording, so glass text turns black on light backgrounds and white on dark ones. Discette looks only at a tiny thumbnail behind the player and keeps nothing.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Allow…") {
                        BackdropSampler.requestAccess()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }
}

/// Shows whether full-screen detection can work, with a way to fix it.
struct AccessibilityRow: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let granted = AccessibilityAccess.isGranted
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(granted ? "Full-screen detection is on" : "Full-screen detection needs permission")
                    Text(granted ? "Discette can tell when another app is full screen."
                                 : "Allow Discette in Privacy & Security, Accessibility.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if !granted {
                    Button("Allow…") {
                        AccessibilityAccess.prompt()
                        AccessibilityAccess.openSettings()
                    }
                }
            }
        }
    }
}

struct StatsView: View {
    @ObservedObject var stats: StatsStore
    @State private var confirmReset = false

    var body: some View {
        let s = stats.stats
        let streak = s.streak()
        Form {
            Section {
                HStack(spacing: 0) {
                    figure("Today", ListeningStats.format(s.today()))
                    figure("This week", ListeningStats.format(s.week()))
                    figure("Streak", streak == 1 ? "1 day" : "\(streak) days")
                }
                .padding(.vertical, 6)
            }
            Section("Top artists") {
                let top = s.topArtists(5)
                if top.isEmpty {
                    Text("Play some music and your most-played artists show up here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(top.enumerated()), id: \.offset) { index, artist in
                    HStack {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
                        Text(artist.name).lineLimit(1)
                        Spacer()
                        Text(ListeningStats.format(artist.seconds)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Section {
                Text("Counted while music plays. Kept on this Mac only.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Reset Stats…", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all listening stats?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { stats.reset() }
        }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 22, weight: .semibold).width(.expanded)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
