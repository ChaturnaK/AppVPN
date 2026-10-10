// Renders AppIcon.icns: one app tile inside a tunnel lane, other tiles left outside.
// Run: swift make-icon.swift   (writes AppIcon.icns next to this file; build.sh just copies it)
import AppKit

/// Superellipse approximates the macOS continuous-curve rounded rect.
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath(), n = 5.0, steps = 360
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi, c = cos(t), s = sin(t)
        let x = r.midX + r.width / 2 * CGFloat(copysign(pow(abs(c), 2 / n), c))
        let y = r.midY + r.height / 2 * CGFloat(copysign(pow(abs(s), 2 / n), s))
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

func gradient(_ stops: [(CGFloat, [CGFloat])]) -> CGGradient {
    CGGradient(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colorComponents: stops.flatMap { $0.1 }, locations: stops.map { $0.0 }, count: stops.count)!
}

func draw(_ c: CGContext, px: Int) {
    let k = CGFloat(px) / 1024
    c.scaleBy(x: k, y: k)
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)

    // Plate: drop shadow, then vertical gradient with a faint top glow.
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    c.addPath(squircle(plate)); c.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(squircle(plate)); c.clip()
    c.drawLinearGradient(gradient([(0, [0.30, 0.72, 1.0, 1]), (1, [0.16, 0.22, 0.82, 1])]),
                         start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    c.addPath(squircle(plate.insetBy(dx: 3, dy: 3))); c.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); c.setLineWidth(6); c.strokePath()

    // Tunnel lane: darker interior with bright edges, running edge to edge.
    let lane = CGRect(x: 100, y: 362, width: 824, height: 300)
    c.setFillColor(CGColor(red: 0.04, green: 0.08, blue: 0.40, alpha: 0.55)); c.fill(lane)
    c.setFillColor(CGColor(gray: 1, alpha: 0.7))
    c.fill(CGRect(x: 100, y: lane.maxY - 10, width: 824, height: 10))
    c.fill(CGRect(x: 100, y: lane.minY, width: 824, height: 10))

    // Traffic flowing through the lane, past the app.
    c.setLineWidth(48); c.setLineCap(.round); c.setLineJoin(.round); c.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
    for x: CGFloat in [250, 774] {
        c.move(to: CGPoint(x: x - 26, y: 512 + 70)); c.addLine(to: CGPoint(x: x + 26, y: 512)); c.addLine(to: CGPoint(x: x - 26, y: 512 - 70))
        c.strokePath()
    }

    // Apps left outside the tunnel.
    c.setFillColor(CGColor(gray: 1, alpha: 0.38))
    c.addPath(squircle(CGRect(x: 585, y: 700, width: 190, height: 190))); c.fillPath()
    c.addPath(squircle(CGRect(x: 249, y: 134, width: 190, height: 190))); c.fillPath()

    // The one app on the VPN.
    let tile = CGRect(x: 352, y: 352, width: 320, height: 320)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.4))
    c.addPath(squircle(tile)); c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fillPath()
    c.restoreGState()
    c.addPath(squircle(tile)); c.clip()
    c.drawLinearGradient(gradient([(0, [1, 1, 1, 1]), (1, [0.80, 0.88, 1.0, 1])]),
                         start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
    c.restoreGState()
}

func png(px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.cgContext.interpolationQuality = .high
    draw(ctx.cgContext, px: px)
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let set = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(px: base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(px: base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
