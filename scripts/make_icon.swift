// Renders the Discette app icon at every macOS size into an .iconset folder.
// Usage: swift scripts/make_icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit
import SwiftUI

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

/// Same geometry as DiscetteMark in the app: a record cut flat on the left into a "D".
func markPath(in rect: CGRect, grooves: Bool) -> CGPath {
    let s = min(rect.width, rect.height)
    let origin = CGPoint(x: rect.midX - s / 2, y: rect.midY - s / 2)
    let c = CGPoint(x: origin.x + s * 0.42, y: origin.y + s * 0.5)
    func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
    let cutEdge = c.x - s * 0.30
    var mark = circle(s * 0.46).subtracting(Path(CGRect(x: origin.x - s, y: origin.y - s, width: cutEdge - (origin.x - s), height: s * 3)))
    if grooves { mark = mark.subtracting(circle(s * 0.25).strokedPath(StrokeStyle(lineWidth: s * 0.024))) }
    return mark.subtracting(circle(s * 0.075)).cgPath
}

func srgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1) // y-down, like SwiftUI

    // Apple's macOS icon grid: 824 pt body on a 1024 pt canvas.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(srgb(0x2F4CFF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [srgb(0x4664FF), srgb(0x1C30C9)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])
    let markRect = body.insetBy(dx: body.width * 0.17, dy: body.width * 0.17)
    ctx.setShadow(offset: CGSize(width: 0, height: s * 0.01), blur: s * 0.025, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(markPath(in: markRect, grooves: px >= 64))
    ctx.setFillColor(srgb(0xF5F6FA))
    ctx.fillPath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    try render(px).write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
}
print("wrote \(sizes.count) images to \(out)")
