import AppKit
import SwiftUI

/// The Discette mark: a record whose left edge is cut flat into a "D", with the spindle hole.
/// One shape, solid, so it stays crisp at 16 px in the menu bar and still reads at 1024 px.
enum DiscetteMark {
    static func path(in rect: CGRect, grooves: Bool = false) -> Path {
        let s = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - s / 2, y: rect.midY - s / 2)
        // Centre sits left of middle so the cut disc is optically centred in its box.
        let c = CGPoint(x: origin.x + s * 0.42, y: origin.y + s * 0.5)
        func circle(_ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        let cutEdge = c.x - s * 0.30
        let cut = Path(CGRect(x: origin.x - s, y: origin.y - s, width: cutEdge - (origin.x - s), height: s * 3))
        var mark = circle(s * 0.46).subtracting(cut)
        if grooves {
            mark = mark.subtracting(circle(s * 0.25).strokedPath(StrokeStyle(lineWidth: s * 0.024)))
        }
        return mark.subtracting(circle(s * 0.075))
    }

    /// Template image for the menu bar: macOS tints it for light, dark and highlighted states.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSColor.black.setFill()
            NSBezierPath(cgPath: path(in: rect.insetBy(dx: 1.5, dy: 1.5)).cgPath).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Discette"
        return image
    }
}

struct DiscetteMarkShape: Shape {
    var grooves = false
    func path(in rect: CGRect) -> Path { DiscetteMark.path(in: rect, grooves: grooves) }
}
