import SwiftUI
import AppKit

/// Everything drawn on one display's click-through overlay. Each layer observes only its own
/// model, so the 60 fps buddy updates don't re-render the annotations or the trail.
struct OverlayCanvas: View {
    let frame: CGRect
    let buddy: BuddyModel
    let marks: AnnotationModel
    let trail: TrailModel

    var body: some View {
        let map = OverlayMapper(frame: frame)
        ZStack(alignment: .topLeading) {
            AnnotationLayer(map: map, model: marks)
            TrailLayer(map: map, model: trail)
            BuddyLayer(map: map, model: buddy)
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - Buddy

struct BuddyLayer: View {
    let map: OverlayMapper
    @ObservedObject var model: BuddyModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.visible, map.isNear(model.position) {
                let p = map.local(model.position)
                BuddyGlyph(state: model.voiceState, color: model.color, audioLevel: model.audioLevel,
                           rotation: model.rotation, scale: model.scale,
                           cat: model.catMode ? .init(pose: model.catPose, facingLeft: model.catFacingLeft, meow: model.catMeow) : nil)
                    .opacity(model.opacity)
                    .position(p)
                if model.pointLabelVisible, !model.pointLabel.isEmpty {
                    // Below-right of the triangle like the reference; flipped to its left when the
                    // label would run off the screen (the reference clips it at the edge).
                    let o = PointLabelBubble.offset
                    let full = TextMeasure.width(model.pointLabel, size: PointLabelBubble.font, weight: .semibold, max: 240, slack: 0) + 16
                    let flip = p.x + o.dx + full > map.frame.width - 4
                    PointLabelBubble(text: model.pointLabel, color: model.color)
                        .scaleEffect(model.pointLabelScale, anchor: flip ? .topTrailing : .topLeading)
                        .pinned(at: CGPoint(x: flip ? p.x - o.dx : p.x + o.dx, y: p.y + o.dy), flip ? .topTrailing : .topLeading)
                        .transition(.opacity)
                }
            }
            if let text = model.bubbleText, map.isNear(model.bubbleAnchor) {
                let a = map.local(model.bubbleAnchor)
                let o = CursorTextBubble.offset
                let flip = a.x + o.dx + CursorTextBubble.maxWidth > map.frame.width - 4
                // Below the typed point label when both show, so they never overlap.
                let dy = o.dy + (model.pointLabelVisible && !model.pointLabel.isEmpty ? 14 : 0)
                CursorTextBubble(text: text, streaming: model.bubbleStreaming, accent: model.color)
                    .pinned(at: CGPoint(x: flip ? a.x - o.dx : a.x + o.dx, y: a.y + dy), flip ? .topTrailing : .topLeading)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
        .frame(width: map.frame.width, height: map.frame.height, alignment: .topLeading)
    }
}

// MARK: - Spatial trail

struct TrailLayer: View {
    let map: OverlayMapper
    @ObservedObject var model: TrailModel

    var body: some View {
        ZStack {
            ForEach(model.strokes.indices, id: \.self) { i in
                if model.strokes[i].count > 1 {
                    let path = Sketch.freehand(model.strokes[i].map(map.local))
                    FixedPathShape(path: path)
                        .stroke(model.color.opacity(0.16), style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
                    FixedPathShape(path: path)
                        .stroke(model.color.opacity(0.55), style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .opacity(model.opacity)
    }
}

// MARK: - Annotations

struct AnnotationLayer: View {
    let map: OverlayMapper
    @ObservedObject var model: AnnotationModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.items) { live in
                if AnnotationGeometry.bounds(of: live.item).insetBy(dx: -300, dy: -300).intersects(map.frame) {
                    AnnotationSketch(live: live, map: map, color: model.color,
                                     animated: model.animated, reduceMotion: model.reduceMotion)
                }
            }
        }
        .frame(width: map.frame.width, height: map.frame.height, alignment: .topLeading)
    }
}

enum AnnotationGeometry {
    /// Global bounds of an annotation (for culling to a screen).
    static func bounds(of item: Annotation) -> CGRect {
        switch item {
        case .highlight(let rect, _):
            return rect
        case .shape(let kind, let points, _, _):
            if kind == .circle, points.count >= 2 {
                let r = hypot(points[1].x - points[0].x, points[1].y - points[0].y)
                return CGRect(x: points[0].x - r, y: points[0].y - r, width: r * 2, height: r * 2)
            }
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .target(let center, let radius, _, _):
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
    }
}

/// One hand-drawn mark with its label chip. Draws itself in like a pen stroke.
struct AnnotationSketch: View {
    let live: LiveAnnotation
    let map: OverlayMapper
    let color: Color
    let animated: Bool
    let reduceMotion: Bool
    @Local private var drawn: CGFloat
    @Local private var pulse = false
    @Local private var labelShown: Bool

    init(live: LiveAnnotation, map: OverlayMapper, color: Color, animated: Bool, reduceMotion: Bool) {
        self.live = live
        self.map = map
        self.color = color
        self.animated = animated
        self.reduceMotion = reduceMotion
        let still = !animated || reduceMotion
        _drawn = Local(wrappedValue: still ? 1 : 0)
        _labelShown = Local(wrappedValue: still)
    }

    var body: some View {
        let g = geometry
        ZStack(alignment: .topLeading) {
            if let fill = g.fill {
                FixedPathShape(path: fill).fill(color.opacity(g.fillOpacity)).opacity(Double(drawn))
            }
            if case .target(_, _, _, _) = live.item { targetRing(g) }
            FixedPathShape(path: g.stroke)
                .trim(from: 0, to: drawn)
                .stroke(Theme.ink.opacity(0.5), style: StrokeStyle(lineWidth: 5.2, lineCap: .round, lineJoin: .round))
            FixedPathShape(path: g.stroke)
                .trim(from: 0, to: drawn)
                .stroke(color, style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
            if let label = g.label, !label.isEmpty {
                AnnotationChip(text: label, color: color)
                    .opacity(labelShown ? 1 : 0)
                    .scaleEffect(labelShown ? 1 : 0.85, anchor: .leading)
                    .pinned(at: g.labelAnchor, g.labelAlignment)
            }
        }
        .frame(width: map.frame.width, height: map.frame.height, alignment: .topLeading)
        .opacity(live.fading ? 0 : (reduceMotion && !labelShown ? 0 : 1))
        .scaleEffect(live.hit ? 1.04 : 1)
        .animation(.easeOut(duration: 0.35), value: live.fading)
        .onAppear {
            guard animated else { return }
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.25)) { labelShown = true }
            } else {
                withAnimation(.easeOut(duration: g.drawDuration)) { drawn = 1 }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.7).delay(g.drawDuration * 0.6)) { labelShown = true }
            }
            if live.isTarget {
                withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true }
            }
        }
    }

    @ViewBuilder private func targetRing(_ g: Geometry) -> some View {
        if case .target(let c, let r, _, _) = live.item {
            let p = map.local(c)
            // Expanding ping + a soft disc so the target reads at a glance.
            Circle()
                .stroke(color.opacity(0.9), lineWidth: 2.2)
                .frame(width: r * 2, height: r * 2)
                .scaleEffect(live.hit ? 1.9 : (pulse ? 1.6 : 1))
                .opacity(live.hit ? 0 : (pulse ? 0 : 0.85))
                .position(p)
            Circle()
                .fill(color.opacity(live.hit ? 0.45 : 0.1))
                .frame(width: r * 2, height: r * 2)
                .position(p)
        }
    }

    struct Geometry {
        var stroke: Path
        var fill: Path?
        var fillOpacity: Double = 0.12
        var label: String?
        var labelAnchor: CGPoint
        var labelAlignment: Alignment
        var drawDuration: Double
    }

    private var geometry: Geometry {
        switch live.item {
        case .highlight(let rect, let label):
            let r = map.local(rect).insetBy(dx: -4, dy: -4)
            return Geometry(stroke: Sketch.rect(r, seed: live.seed), fill: Path(roundedRect: r, cornerRadius: 6), fillOpacity: 0.10,
                            label: label, labelAnchor: CGPoint(x: r.minX, y: r.minY - 8), labelAlignment: .bottomLeading, drawDuration: 0.45)
        case .shape(let kind, let points, let label, let filled):
            let pts = points.map(map.local)
            switch kind {
            case .circle:
                let c = pts.first ?? .zero
                let edge = pts.count > 1 ? pts[1] : CGPoint(x: c.x + 30, y: c.y)
                let r = max(10, hypot(edge.x - c.x, edge.y - c.y))
                let rx = r * 1.08, ry = r * 0.98
                let rect = CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2)
                return Geometry(stroke: Sketch.ellipse(center: c, rx: rx, ry: ry, seed: live.seed),
                                fill: filled ? Path(ellipseIn: rect) : nil, fillOpacity: 0.16, label: label,
                                labelAnchor: CGPoint(x: rect.maxX + 10, y: c.y), labelAlignment: .leading, drawDuration: 0.5)
            case .arrow:
                let tail = pts.first ?? .zero
                let tip = pts.last ?? .zero
                // Label sits behind the tail, on the side away from the head.
                let leftward = tip.x >= tail.x
                return Geometry(stroke: Sketch.arrow(pts, seed: live.seed), label: label,
                                labelAnchor: CGPoint(x: tail.x + (leftward ? -8 : 8), y: tail.y),
                                labelAlignment: leftward ? .trailing : .leading, drawDuration: 0.45)
            case .line:
                let a = pts.first ?? .zero
                return Geometry(stroke: Sketch.polyline(pts, closed: false, seed: live.seed), label: label,
                                labelAnchor: CGPoint(x: a.x, y: a.y - 8), labelAlignment: .bottomLeading, drawDuration: 0.4)
            case .curve:
                let a = pts.first ?? .zero
                return Geometry(stroke: Sketch.curve(pts, seed: live.seed), label: label,
                                labelAnchor: CGPoint(x: a.x, y: a.y - 8), labelAlignment: .bottomLeading, drawDuration: 0.5)
            case .polygon:
                var fillPath = Path()
                fillPath.addLines(pts)
                fillPath.closeSubpath()
                let top = pts.min { $0.y < $1.y } ?? .zero
                return Geometry(stroke: Sketch.polyline(pts, closed: true, seed: live.seed), fill: filled ? fillPath : nil,
                                fillOpacity: 0.16, label: label, labelAnchor: CGPoint(x: top.x, y: top.y - 8),
                                labelAlignment: .bottom, drawDuration: 0.55)
            }
        case .target(let center, let radius, let label, _):
            let c = map.local(center)
            let r = max(radius, 12)
            return Geometry(stroke: Sketch.ellipse(center: c, rx: r + 4, ry: r + 3, seed: live.seed), label: label,
                            labelAnchor: CGPoint(x: c.x + r + 14, y: c.y), labelAlignment: .leading, drawDuration: 0.45)
        }
    }
}

/// Label chip on a mark: ink pill, bone text, a dot in the mark's colour.
struct AnnotationChip: View {
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.awan(12, .semibold))
                .foregroundStyle(Theme.bone)
                .lineLimit(2)
                .frame(width: TextMeasure.width(text, size: 12, weight: .semibold, max: 220), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 8)
        .padding(.trailing, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.ink.opacity(0.9)))
        .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }
}
