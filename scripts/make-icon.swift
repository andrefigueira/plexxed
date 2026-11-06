// Draws the Plexxed mark (a P whose bowl is a play triangle) and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift [preview-dir]
import AppKit

let background = CGColor(red: 0x14 / 255, green: 0x15 / 255, blue: 0x18 / 255, alpha: 1)
let ink = CGColor(red: 0xF2 / 255, green: 0xF0 / 255, blue: 0xEA / 255, alpha: 1)

/// The mark in a unit square (y up): a solid P, and the P's counter shaped as a play triangle.
/// PlexxedMark in the app draws the same geometry.
/// Stem and bowl are separate paths, filled one after the other so their overlap stays solid.
func letterPaths(in rect: CGRect) -> [CGPath] {
    let u = rect.width
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * u, y: rect.minY + y * u) }
    let stem = CGRect(x: rect.minX + 0.24 * u, y: rect.minY + 0.10 * u, width: 0.18 * u, height: 0.80 * u)
    let stemPath = CGPath(roundedRect: stem, cornerWidth: 0.07 * u, cornerHeight: 0.07 * u, transform: nil)
    // Bowl: flat top and bottom, a full semicircle on the right.
    let path = CGMutablePath()
    path.move(to: p(0.33, 0.90))
    path.addLine(to: p(0.59, 0.90))
    path.addArc(center: p(0.59, 0.67), radius: 0.23 * u, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
    path.addLine(to: p(0.33, 0.44))
    path.closeSubpath()
    return [stemPath, path]
}

func counterPath(in rect: CGRect) -> CGPath {
    let u = rect.width
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * u, y: rect.minY + y * u) }
    let a = p(0.42, 0.80), b = p(0.42, 0.54), c = p(0.66, 0.67)
    let r = 0.025 * u
    let path = CGMutablePath()
    path.move(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
    path.addArc(tangent1End: b, tangent2End: c, radius: r)
    path.addArc(tangent1End: c, tangent2End: a, radius: r)
    path.addArc(tangent1End: a, tangent2End: b, radius: r)
    path.closeSubpath()
    return path
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Standard macOS icon grid: an 824/1024 rounded square, centred.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil))
    ctx.setFillColor(background)
    ctx.fillPath()
    // The letter's bounding box runs 0.24...0.82 across, so shift it to sit optically centred.
    let markSize = body.width * 0.64
    let markRect = CGRect(x: body.midX - markSize * 0.53, y: body.midY - markSize / 2, width: markSize, height: markSize)
    ctx.setFillColor(ink)
    for part in letterPaths(in: markRect) {
        ctx.addPath(part)
        ctx.fillPath()
    }
    ctx.addPath(counterPath(in: markRect))
    ctx.setFillColor(background)
    ctx.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
if CommandLine.arguments.count > 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[1])
    try render(1024).write(to: dir.appendingPathComponent("icon-1024.png"))
    try render(64).write(to: dir.appendingPathComponent("icon-64.png"))
    print("Wrote previews to \(dir.path)")
}
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
