// Renders Awan's app icon: Ink squircle, Bone cloud with ink ^ ^ eyes, a small Signal Lime cursor.
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowBlurRadius = s * 0.025; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.set()
    NSColor(srgbRed: 0.043, green: 0.043, blue: 0.039, alpha: 1).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    // subtle top sheen
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!.draw(in: squircle, angle: -90)

    // cloud (bone), in flipped-free coordinates
    let w = rect.width, x0 = rect.minX, y0 = rect.minY
    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: CGRect(x: x0 + cx * w - r * w, y: y0 + cy * w - r * w, width: 2 * r * w, height: 2 * r * w))
    }
    let bone = NSColor(srgbRed: 0.953, green: 0.937, blue: 0.894, alpha: 1)
    bone.setFill()
    for (cx, cy, r) in [(0.30, 0.44, 0.15), (0.42, 0.56, 0.17), (0.60, 0.58, 0.18), (0.73, 0.45, 0.14), (0.50, 0.42, 0.20)] as [(CGFloat, CGFloat, CGFloat)] {
        circle(cx, cy, r).fill()
    }
    NSBezierPath(roundedRect: CGRect(x: x0 + 0.18 * w, y: y0 + 0.28 * w, width: 0.66 * w, height: 0.20 * w), xRadius: 0.10 * w, yRadius: 0.10 * w).fill()

    // eyes ^ ^
    ctx.setStrokeColor(NSColor(srgbRed: 0.043, green: 0.043, blue: 0.039, alpha: 1).cgColor)
    ctx.setLineWidth(w * 0.042); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    for cx in [0.43, 0.59] as [CGFloat] {
        ctx.move(to: CGPoint(x: x0 + (cx - 0.055) * w, y: y0 + 0.44 * w))
        ctx.addLine(to: CGPoint(x: x0 + cx * w, y: y0 + 0.50 * w))
        ctx.addLine(to: CGPoint(x: x0 + (cx + 0.055) * w, y: y0 + 0.44 * w))
        ctx.strokePath()
    }
    // lime cursor triangle
    let lime = NSColor(srgbRed: 0.851, green: 1, blue: 0.263, alpha: 1)
    let tri = NSBezierPath()
    let tx = x0 + 0.70 * w, ty = y0 + 0.30 * w, ts = 0.15 * w
    tri.move(to: CGPoint(x: tx, y: ty))
    tri.line(to: CGPoint(x: tx + ts * 0.95, y: ty - ts * 0.35))
    tri.line(to: CGPoint(x: tx + ts * 0.35, y: ty - ts * 0.95))
    tri.close()
    tri.lineJoinStyle = .round
    lime.setFill(); tri.fill()
    NSColor(srgbRed: 0.043, green: 0.043, blue: 0.039, alpha: 1).setStroke(); tri.lineWidth = w * 0.018; tri.stroke()
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
