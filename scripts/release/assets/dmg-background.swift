// Renders the DMG window background (ADR-0047): 640×400 pt at 1× and 2×.
// usage: swift dmg-background.swift <out-1x.png> <out-2x.png>
// A calm teal surface in the app icon's colors, a soft top light, a frosted plate behind the two icons and a
// thin guide arrow. The label band stays near luminance 0.19 so Finder's black (light mode) and white (dark
// mode) icon labels both read at ≈4.5:1.
import AppKit
import CoreGraphics

func render(scale: CGFloat, to path: String) {
    let size = CGSize(width: 640 * scale, height: 400 * scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    // Base: vertical gradient (CG origin is bottom-left).
    let base = CGGradient(colorsSpace: space, colors: [rgb(0x3E7477), rgb(0x4A888B), rgb(0x55979A)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: 400), options: [])
    // Soft light from the top left.
    let light = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(light, startCenter: CGPoint(x: 150, y: 420), startRadius: 0,
                           endCenter: CGPoint(x: 150, y: 420), endRadius: 420, options: [])
    // Frosted plate behind the icons (Finder places them at y = 200 from the top → 200 from the bottom here).
    let plate = CGPath(roundedRect: CGRect(x: 70, y: 105, width: 500, height: 190), cornerWidth: 36,
                       cornerHeight: 36, transform: nil)
    ctx.addPath(plate)
    ctx.setFillColor(rgb(0xFFFFFF, 0.07))
    ctx.fillPath()
    ctx.addPath(plate)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.22))
    ctx.setLineWidth(1)
    ctx.strokePath()
    // Guide arrow between the app (x 170) and Applications (x 470).
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.75))
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 268, y: 214))
    ctx.addLine(to: CGPoint(x: 372, y: 214))
    ctx.move(to: CGPoint(x: 358, y: 226))
    ctx.addLine(to: CGPoint(x: 372, y: 214))
    ctx.addLine(to: CGPoint(x: 358, y: 202))
    ctx.strokePath()
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = CGSize(width: 640, height: 400)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
precondition(args.count == 3, "usage: dmg-background.swift <out-1x.png> <out-2x.png>")
render(scale: 1, to: args[1])
render(scale: 2, to: args[2])
