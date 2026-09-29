import SwiftUI

/// Deterministic RNG (SplitMix64) so a sketch keeps the same wobble on every re-render.
struct SketchRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed ^ 0x5DEECE66D }

    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }

    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    mutating func jitter(_ amount: Double) -> CGFloat { CGFloat(range(-amount, amount)) }
}

/// Hand-drawn (Excalidraw-like) geometry. Every edge is drawn in two passes, each with jittered
/// ends and a gentle bow, so marks read as pen strokes rather than vector outlines.
/// All inputs/outputs are in the view's local, top-left-origin coordinates.
enum Sketch {
    /// One wobbly stroke from a to b, appended to `path`.
    static func stroke(_ path: inout Path, _ a: CGPoint, _ b: CGPoint, _ rng: inout SketchRandom, rough: Double = 1) {
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 0.5 else { return }
        let endJitter = min(3.2, Double(len) * 0.022 + 1.0) * rough
        let bow = min(5.5, Double(len) * 0.02 + 0.8) * rough
        let nx = -(b.y - a.y) / len, ny = (b.x - a.x) / len
        let a2 = CGPoint(x: a.x + rng.jitter(endJitter), y: a.y + rng.jitter(endJitter))
        let b2 = CGPoint(x: b.x + rng.jitter(endJitter), y: b.y + rng.jitter(endJitter))
        let o1 = rng.jitter(bow), o2 = rng.jitter(bow)
        let c1 = CGPoint(x: a2.x + (b2.x - a2.x) * 0.33 + nx * o1, y: a2.y + (b2.y - a2.y) * 0.33 + ny * o1)
        let c2 = CGPoint(x: a2.x + (b2.x - a2.x) * 0.70 + nx * o2, y: a2.y + (b2.y - a2.y) * 0.70 + ny * o2)
        path.move(to: a2)
        path.addCurve(to: b2, control1: c1, control2: c2)
    }

    /// Open or closed polyline, two passes (the second slightly rougher).
    static func polyline(_ points: [CGPoint], closed: Bool, seed: UInt64) -> Path {
        var rng = SketchRandom(seed: seed)
        var path = Path()
        guard points.count > 1 else { return path }
        var segments = zip(points, points.dropFirst()).map { ($0, $1) }
        if closed, let first = points.first, let last = points.last { segments.append((last, first)) }
        for pass in 0..<2 {
            for (a, b) in segments {
                // Overshoot a little at each end the way a quick pen stroke does.
                let len = max(hypot(b.x - a.x, b.y - a.y), 0.001)
                let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
                let over = CGFloat(min(6, Double(len) * 0.04)) * (pass == 0 ? 1 : 0.6)
                let a2 = CGPoint(x: a.x - ux * over * CGFloat(rng.next()), y: a.y - uy * over * CGFloat(rng.next()))
                let b2 = CGPoint(x: b.x + ux * over * CGFloat(rng.next()), y: b.y + uy * over * CGFloat(rng.next()))
                stroke(&path, a2, b2, &rng, rough: pass == 0 ? 1 : 1.35)
            }
        }
        return path
    }

    static func rect(_ r: CGRect, seed: UInt64) -> Path {
        polyline([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                  CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)], closed: true, seed: seed)
    }

    /// A loose ellipse that overlaps its start, drawn twice with drifting radius.
    static func ellipse(center c: CGPoint, rx: CGFloat, ry: CGFloat, seed: UInt64) -> Path {
        var rng = SketchRandom(seed: seed)
        var path = Path()
        let count = Int(min(30, max(12, Double(rx + ry) * 0.22)))
        for pass in 0..<2 {
            let start = rng.range(0, .pi * 2)
            let overlap = rng.range(0.25, 0.55) * (pass == 0 ? 1 : 0.55)
            let sweep = Double.pi * 2 + overlap
            let d0 = rng.range(-0.05, 0.05), d1 = rng.range(-0.06, 0.08)
            var pts: [CGPoint] = []
            for i in 0...count {
                let f = Double(i) / Double(count)
                let t = start + sweep * f
                let r = 1 + d0 + (d1 - d0) * f + rng.range(-0.012, 0.012)
                pts.append(CGPoint(x: c.x + CGFloat(cos(t) * r) * rx, y: c.y + CGFloat(sin(t) * r) * ry))
            }
            catmullRom(&path, pts)
        }
        return path
    }

    /// A smooth curve through the points, drawn twice with small jitter.
    static func curve(_ points: [CGPoint], seed: UInt64) -> Path {
        var rng = SketchRandom(seed: seed)
        var path = Path()
        guard points.count > 1 else { return path }
        if points.count == 2 {
            // A two-point "curve" is a bowed line.
            for pass in 0..<2 { stroke(&path, points[0], points[1], &rng, rough: pass == 0 ? 1.6 : 2) }
            return path
        }
        for pass in 0..<2 {
            let amount = pass == 0 ? 1.2 : 2.0
            catmullRom(&path, points.map { CGPoint(x: $0.x + rng.jitter(amount), y: $0.y + rng.jitter(amount)) })
        }
        return path
    }

    /// Shaft (straight or curved through the points) plus a two-stroke head at the last point.
    static func arrow(_ points: [CGPoint], seed: UInt64) -> Path {
        guard let tip = points.last, points.count > 1 else { return Path() }
        var path = points.count > 2 ? curve(points, seed: seed) : polyline(points, closed: false, seed: seed)
        let from = points[points.count - 2]
        let len = hypot(tip.x - from.x, tip.y - from.y)
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let head = min(20, max(11, len * 0.2))
        var rng = SketchRandom(seed: seed &+ 77)
        for pass in 0..<2 {
            for side in [-1.0, 1.0] {
                let a = Double(angle) + .pi + side * (0.47 + rng.range(-0.05, 0.05))
                let end = CGPoint(x: tip.x + CGFloat(cos(a)) * head, y: tip.y + CGFloat(sin(a)) * head)
                stroke(&path, tip, end, &rng, rough: pass == 0 ? 0.6 : 0.9)
            }
        }
        return path
    }

    /// Catmull-Rom spline through the points as cubic Béziers.
    static func catmullRom(_ path: inout Path, _ pts: [CGPoint]) {
        guard pts.count > 1 else { return }
        path.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    /// Smoothed freehand stroke (the spatial trail): quadratic segments through midpoints.
    static func freehand(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 2 else {
            if pts.count == 2 { path.addLine(to: pts[1]) } else { path.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            return path
        }
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i - 1])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }
}

/// A fixed path as a Shape (so it can be trimmed for the draw-in animation).
struct FixedPathShape: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path { path }
}
