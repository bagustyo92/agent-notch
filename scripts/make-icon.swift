// Generates the app icon: `swift scripts/make-icon.swift <out-dir>` writes
// <out-dir>/AppIcon.icns and <out-dir>/icon-512.png. CoreGraphics + ImageIO only.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func spark(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, color: CGColor) {
    let k = r * 0.28
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y + k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - k, y: c.y + k))
    ctx.addPath(p); ctx.setFillColor(color); ctx.fillPath()
}

func render(_ px: Int) -> CGImage {
    let S = CGFloat(px), u = S / 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Squircle-ish tile with a violet → coral gradient (macOS grid: 824 tile in 1024 canvas).
    let tile = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 28 * u, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(rgb(0x2A1B6E)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [rgb(0x2A1B6E), rgb(0x6D3BEF), rgb(0xFF7A59)] as CFArray,
                              locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    // The notch: a black bar hanging from the top edge, with the "waiting" dot.
    let notch = CGRect(x: 512 * u - 170 * u, y: tile.maxY - 92 * u, width: 340 * u, height: 120 * u)
    ctx.addPath(CGPath(roundedRect: notch, cornerWidth: 46 * u, cornerHeight: 46 * u, transform: nil))
    ctx.setFillColor(rgb(0x0B0B10)); ctx.fillPath()
    ctx.setFillColor(rgb(0xFF9F0A)); ctx.fillEllipse(in: CGRect(x: 512 * u + 105 * u, y: tile.maxY - 58 * u, width: 30 * u, height: 30 * u))
    ctx.setFillColor(rgb(0x7CFFB2)); ctx.fillEllipse(in: CGRect(x: 512 * u - 135 * u, y: tile.maxY - 58 * u, width: 30 * u, height: 30 * u))
    ctx.restoreGState()

    // Bot head.
    let white = rgb(0xFFFFFF)
    let head = CGRect(x: 262 * u, y: 230 * u, width: 500 * u, height: 360 * u)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * u), blur: 24 * u, color: rgb(0x1A0F45, 0.45))
    ctx.addPath(CGPath(roundedRect: head, cornerWidth: 120 * u, cornerHeight: 120 * u, transform: nil))
    ctx.setFillColor(white); ctx.fillPath()
    ctx.restoreGState()
    // Visor + eyes.
    let visor = head.insetBy(dx: 58 * u, dy: 78 * u)
    ctx.addPath(CGPath(roundedRect: visor, cornerWidth: 90 * u, cornerHeight: 90 * u, transform: nil))
    ctx.setFillColor(rgb(0x14102B)); ctx.fillPath()
    ctx.setFillColor(rgb(0x7CFFB2))
    ctx.fillEllipse(in: CGRect(x: 395 * u, y: 362 * u, width: 66 * u, height: 96 * u))
    ctx.fillEllipse(in: CGRect(x: 563 * u, y: 362 * u, width: 66 * u, height: 96 * u))
    // Ears.
    ctx.setFillColor(white)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 222 * u, y: 350 * u, width: 56 * u, height: 120 * u), cornerWidth: 26 * u, cornerHeight: 26 * u, transform: nil)); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 746 * u, y: 350 * u, width: 56 * u, height: 120 * u), cornerWidth: 26 * u, cornerHeight: 26 * u, transform: nil)); ctx.fillPath()
    // Antenna + spark.
    ctx.setStrokeColor(white); ctx.setLineWidth(26 * u); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 512 * u, y: 590 * u)); ctx.addLine(to: CGPoint(x: 512 * u, y: 660 * u)); ctx.strokePath()
    spark(ctx, center: CGPoint(x: 512 * u, y: 712 * u), radius: 70 * u, color: rgb(0xFFE27A))
    spark(ctx, center: CGPoint(x: 735 * u, y: 690 * u), radius: 34 * u, color: rgb(0xFFFFFF, 0.9))
    spark(ctx, center: CGPoint(x: 300 * u, y: 655 * u), radius: 22 * u, color: rgb(0xFFFFFF, 0.75))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build", isDirectory: true)
let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    writePNG(render(px), to: iconset.appendingPathComponent("icon_\(name).png"))
}
writePNG(render(512), to: out.appendingPathComponent("icon-512.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: iconset)
print("wrote \(out.path)/AppIcon.icns")
