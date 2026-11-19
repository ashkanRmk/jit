// Draws a Finder background at 1× and 2× using the same icon geometry as the installer metadata.
import AppKit
import CoreGraphics
import CoreText

struct Layout: Decodable {
    let width: CGFloat
    let height: CGFloat
    let iconSize: CGFloat
    let iconY: CGFloat
    let jitX: CGFloat
    let applicationsX: CGFloat

    var size: CGSize { CGSize(width: width, height: height) }

    func rect(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: x, y: self.height - top - height, width: width, height: height)
    }
}

enum RenderError: Error {
    case colorSpaceUnavailable
    case bitmapUnavailable
    case gradientUnavailable
    case pngEncodingFailed
}

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ layout: Layout, logo: NSImage, scale: CGFloat, output: String) throws {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw RenderError.colorSpaceUnavailable }
    guard
        let ctx = CGContext(
            data: nil, width: Int(layout.width * scale), height: Int(layout.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw RenderError.bitmapUnavailable }
    ctx.scaleBy(x: scale, y: scale)

    func rounded(_ rect: CGRect, radius: CGFloat, fill: CGColor, stroke: CGColor? = nil) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
        if let stroke {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
    }

    func text(_ title: String, baseline: CGFloat, size: CGFloat, weight: NSFont.Weight, color: CGColor) {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: weight),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                ]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: (layout.width - width) / 2, y: layout.height - baseline)
        CTLineDraw(line, ctx)
    }

    guard
        let base = CGGradient(
            colorsSpace: space, colors: [rgb(0x101D23), rgb(0x17343D), rgb(0x205157)] as CFArray,
            locations: [0, 0.58, 1]),
        let glow = CGGradient(
            colorsSpace: space, colors: [rgb(0x67B5BA, alpha: 0.20), rgb(0x67B5BA, alpha: 0)] as CFArray,
            locations: [0, 1])
    else { throw RenderError.gradientUnavailable }
    ctx.drawLinearGradient(
        base, start: .zero, end: CGPoint(x: layout.width, y: layout.height), options: [.drawsAfterEndLocation])
    let glowCenter = CGPoint(x: layout.width / 2, y: layout.height + 30)
    ctx.drawRadialGradient(
        glow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: 350, options: [])

    // Subtle commit lanes echo the app icon and sit outside the drag targets.
    ctx.setLineWidth(1)
    ctx.setStrokeColor(rgb(0x9BDDE0, alpha: 0.24))
    for y in [layout.height - 46, layout.height - 64, layout.height - 82] {
        let edge = layout.width - 20
        ctx.move(to: CGPoint(x: edge - 117, y: y))
        ctx.addLine(to: CGPoint(x: edge - 62, y: y))
        ctx.addQuadCurve(to: CGPoint(x: edge - 37, y: y + 18), control: CGPoint(x: edge - 39, y: y))
        ctx.addLine(to: CGPoint(x: edge + 20, y: y + 18))
        ctx.strokePath()
        ctx.setFillColor(rgb(0x9BDDE0, alpha: 0.42))
        ctx.fillEllipse(in: CGRect(x: edge - 89, y: y - 2.5, width: 5, height: 5))
    }

    let logoWidth: CGFloat = 107
    let logoHeight = logoWidth * logo.size.height / logo.size.width
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    logo.draw(in: layout.rect(x: (layout.width - logoWidth) / 2, top: 18, width: logoWidth, height: logoHeight))
    NSGraphicsContext.restoreGraphicsState()
    text("Drag Jit to Applications", baseline: 112, size: 24, weight: .semibold, color: rgb(0xEFF8F8))

    let iconTop = layout.iconY - layout.iconSize / 2
    for x in [layout.jitX, layout.applicationsX] {
        rounded(
            layout.rect(x: x - 103, top: iconTop - 15, width: 206, height: layout.iconSize + 60), radius: 22,
            fill: rgb(0x162C34), stroke: rgb(0x9AD9DC, alpha: 0.30))
        // Finder selects black or white labels. This luminance supports either color.
        rounded(
            layout.rect(x: x - 68, top: layout.iconY + layout.iconSize / 2 + 3, width: 136, height: 27), radius: 9,
            fill: rgb(0x687880))
    }

    let arrowCenter = CGPoint(x: (layout.jitX + layout.applicationsX) / 2, y: layout.height - layout.iconY)
    rounded(
        CGRect(x: arrowCenter.x - 24, y: arrowCenter.y - 24, width: 48, height: 48), radius: 24,
        fill: rgb(0x27616A), stroke: rgb(0x9AD9DC, alpha: 0.55))
    ctx.setStrokeColor(rgb(0xD7F5F4))
    ctx.setLineWidth(2.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: arrowCenter.x - 10, y: arrowCenter.y))
    ctx.addLine(to: CGPoint(x: arrowCenter.x + 10, y: arrowCenter.y))
    ctx.move(to: CGPoint(x: arrowCenter.x + 3, y: arrowCenter.y + 7))
    ctx.addLine(to: CGPoint(x: arrowCenter.x + 10, y: arrowCenter.y))
    ctx.addLine(to: CGPoint(x: arrowCenter.x + 3, y: arrowCenter.y - 7))
    ctx.strokePath()

    text(
        "Open Jit from Applications when the copy finishes.", baseline: 358, size: 13,
        weight: .medium, color: rgb(0xA7C2C8))

    guard let image = ctx.makeImage() else { throw RenderError.bitmapUnavailable }
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = layout.size
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw RenderError.pngEncodingFailed }
    try png.write(to: URL(fileURLWithPath: output))
}

let args = CommandLine.arguments
precondition(args.count == 5, "usage: dmg-background.swift LAYOUT LOGO OUT-1X OUT-2X")
let layout = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
guard let logo = NSImage(contentsOfFile: args[2]) else { preconditionFailure("Could not load the Jit logo") }
try render(layout, logo: logo, scale: 1, output: args[3])
try render(layout, logo: logo, scale: 2, output: args[4])
