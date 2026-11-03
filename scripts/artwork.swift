// Renders Clearspace's app icon and DMG background with CoreGraphics.
//   artwork icon <out.iconset>
//   artwork dmg-background <out.png> <scale>
import AppKit

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
}

func makeContext(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func writePNG(_ image: CGImage, to path: String) {
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(path)") }
}

/// Apple's icon tile is a continuous-corner rounded square; a superellipse is a close match.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = CGPoint(x: rect.midX + rect.width / 2 * copysign(pow(abs(c), 2 / n), c),
                            y: rect.midY + rect.height / 2 * copysign(pow(abs(s), 2 / n), s))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func withAppKit(_ ctx: CGContext, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func drawSymbol(_ name: String, pointSize: CGFloat, center: CGPoint, in ctx: CGContext) {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
        fatalError("missing SF Symbol \(name)")
    }
    let size = image.size
    withAppKit(ctx) {
        image.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
    }
}

func renderIcon(pixels: Int) -> CGImage {
    let ctx = makeContext(width: pixels, height: pixels)
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = squircle(in: CGRect(x: 100, y: 100, width: 824, height: 824))

    // Drop shadow under the tile, as in Apple's icon template.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0x000000, 0.28))
    ctx.addPath(tile)
    ctx.setFillColor(color(0x2F4BF5))
    ctx.fillPath()
    ctx.restoreGState()

    // Cyan → blue → indigo body with a soft top sheen.
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x5ED3FF), color(0x3B6BFF), color(0x2B2FD9)], [0, 0.55, 1]),
                           start: CGPoint(x: 180, y: 924), end: CGPoint(x: 844, y: 100), options: [])
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.26), color(0xFFFFFF, 0)], [0, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // A storage gauge: faint full track, bright three-quarter arc, sparkles in the middle.
    let center = CGPoint(x: 512, y: 512)
    ctx.setLineCap(.round)
    ctx.setLineWidth(64)
    ctx.setStrokeColor(color(0xFFFFFF, 0.22))
    ctx.addArc(center: center, radius: 270, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x101860, 0.35))
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.addArc(center: center, radius: 270, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 1.45, clockwise: true)
    ctx.strokePath()
    drawSymbol("sparkles", pointSize: 250, center: CGPoint(x: 512, y: 505), in: ctx)
    ctx.restoreGState()
    return ctx.makeImage()!
}

func drawText(_ text: String, size: CGFloat, weight: NSFont.Weight, color hex: UInt32, centerX: CGFloat, y: CGFloat, in ctx: CGContext) {
    let string = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(cgColor: color(hex))!,
    ])
    withAppKit(ctx) { string.draw(at: CGPoint(x: centerX - string.size().width / 2, y: y)) }
}

/// 660×420 pt window; icons sit at (165, 200) and (495, 200) from the top-left (see dmg-settings.py).
func renderBackground(scale: CGFloat) -> CGImage {
    let width: CGFloat = 660, height: CGFloat = 420
    let ctx = makeContext(width: Int(width * scale), height: Int(height * scale))
    ctx.scaleBy(x: scale, y: scale)
    ctx.drawLinearGradient(gradient([color(0xFFFFFF), color(0xECF1FA)], [0, 1]),
                           start: CGPoint(x: 0, y: height), end: .zero, options: [])
    ctx.drawRadialGradient(gradient([color(0x3B6BFF, 0.09), color(0x3B6BFF, 0)], [0, 1]),
                           startCenter: CGPoint(x: 330, y: 220), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 220), endRadius: 330, options: [])

    // Dotted arrow from the app to the Applications folder.
    let y = height - 200
    ctx.setStrokeColor(color(0x8A94A8))
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineDash(phase: 0, lengths: [0.1, 13])
    ctx.move(to: CGPoint(x: 262, y: y))
    ctx.addLine(to: CGPoint(x: 386, y: y))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.move(to: CGPoint(x: 384, y: y + 15))
    ctx.addLine(to: CGPoint(x: 399, y: y))
    ctx.addLine(to: CGPoint(x: 384, y: y - 15))
    ctx.strokePath()

    drawText("Drag Clearspace into your Applications folder", size: 15, weight: .semibold, color: 0x2A3142,
             centerX: width / 2, y: 92, in: ctx)
    drawText("Then open it from Applications or Launchpad.", size: 12, weight: .regular, color: 0x7A8396,
             centerX: width / 2, y: 70, in: ctx)
    return ctx.makeImage()!
}

let args = CommandLine.arguments
switch args.count > 2 ? args[1] : "" {
case "icon":
    let dir = args[2]
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        writePNG(renderIcon(pixels: points), to: "\(dir)/icon_\(points)x\(points).png")
        writePNG(renderIcon(pixels: points * 2), to: "\(dir)/icon_\(points)x\(points)@2x.png")
    }
case "dmg-background":
    writePNG(renderBackground(scale: CGFloat(Double(args.count > 3 ? args[3] : "1") ?? 1)), to: args[2])
default:
    FileHandle.standardError.write(Data("usage: artwork icon <out.iconset> | artwork dmg-background <out.png> <scale>\n".utf8))
    exit(1)
}
