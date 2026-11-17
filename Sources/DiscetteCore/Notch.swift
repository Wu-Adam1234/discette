import CoreGraphics

/// Where the notch is on a screen, and where the notch player's window goes around it.
/// All rects are in AppKit screen coordinates (origin bottom-left, y up).
public struct NotchGeometry: Equatable, Sendable {
    public let screenFrame: CGRect
    /// The notch itself: between the two menu bar areas macOS reports beside it.
    public let notch: CGRect

    /// Width of each "ear" beside the notch while collapsed: room for a small record or ring.
    public var ear: CGFloat { notch.height + 6 }

    /// Body width when the player drops open.
    public static let openWidth: CGFloat = 400

    /// nil on screens without a notch (no top safe-area inset, or no menu bar areas beside it).
    public init?(screenFrame: CGRect, topInset: CGFloat, leftArea: CGRect?, rightArea: CGRect?) {
        guard topInset > 0, let left = leftArea, let right = rightArea, right.minX > left.maxX else { return nil }
        self.screenFrame = screenFrame
        notch = CGRect(x: left.maxX, y: screenFrame.maxY - topInset, width: right.minX - left.maxX, height: topInset)
    }

    /// Body size while collapsed. With nothing playing it is exactly the notch, so it disappears.
    public func collapsedSize(hasTrack: Bool) -> CGSize {
        hasTrack ? CGSize(width: notch.width + ear * 2, height: notch.height) : notch.size
    }

    /// A window of `size`, centred on the notch with its top on the screen's top edge.
    public func windowFrame(size: CGSize) -> CGRect {
        CGRect(x: (notch.midX - size.width / 2).rounded(), y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }

    /// A shape of `size` hanging from the top edge, centred on the notch: the hover zone.
    public func hangingRect(size: CGSize) -> CGRect {
        CGRect(x: notch.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }
}
