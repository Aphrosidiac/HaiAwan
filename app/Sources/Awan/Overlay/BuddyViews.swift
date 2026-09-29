// Adapted from farzaa/clicky (MIT) — triangle, waveform and spinner forms of the cursor buddy.
import SwiftUI
import AppKit

/// Geometry of the buddy, measured on the reference overlay.
enum BuddyMetrics {
    /// Sharp circumradius of the equilateral triangle. Rounding pulls each tip in by `cornerRadius`,
    /// so the visible tips sit 9.3 − 1.6 = 7.7 pt from the centroid (≈13.3 pt tip to tip) and the
    /// edges 4.65 pt from it — the reference's 7.7 / 4.6.
    static let circumradius: CGFloat = 9.3
    static let cornerRadius: CGFloat = 1.6
    /// Frame the glyph draws in (the glow spills outside it).
    static let frame: CGFloat = 20
}

/// The buddy's triangle: equilateral, centroid at the rect's centre, tip pointing up at 0°
/// (rest rotation −36° turns a tip to the right, tilted 6° up), corners softly rounded.
struct BuddyTriangleShape: Shape {
    var circumradius: CGFloat = BuddyMetrics.circumradius
    var cornerRadius: CGFloat = BuddyMetrics.cornerRadius

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let v = (0..<3).map { i -> CGPoint in
            let a = -Double.pi / 2 + Double(i) * 2 * .pi / 3
            return CGPoint(x: c.x + circumradius * CGFloat(cos(a)), y: c.y + circumradius * CGFloat(sin(a)))
        }
        var p = Path()
        p.move(to: CGPoint(x: (v[2].x + v[0].x) / 2, y: (v[2].y + v[0].y) / 2))
        p.addArc(tangent1End: v[0], tangent2End: v[1], radius: cornerRadius)
        p.addArc(tangent1End: v[1], tangent2End: v[2], radius: cornerRadius)
        p.addArc(tangent1End: v[2], tangent2End: v[0], radius: cornerRadius)
        p.closeSubpath()
        return p
    }
}

/// Idle/responding triangle, listening waveform, processing spinner — all kept in the tree and
/// cross-faded so switching state never "pops" the buddy.
struct BuddyGlyph: View {
    var state: VoiceState
    var color: Color
    var audioLevel: CGFloat
    var rotation: Double = BuddyModel.restRotation
    var scale: CGFloat = 1
    var animated = true
    /// Cat Mode: the cat replaces the triangle (and stays visible beside the waveform / spinner).
    var cat: CatState? = nil

    struct CatState: Equatable {
        var pose: CatPose
        var facingLeft: Bool
        var meow: Bool
    }

    var body: some View {
        if let cat { catBody(cat) } else { triangleBody }
    }

    private func catBody(_ cat: CatState) -> some View {
        ZStack {
            CatBuddy(pose: state == .listening || state == .processing ? .sit : cat.pose, collar: color,
                     facingLeft: cat.facingLeft, meow: cat.meow && state != .listening, animated: animated)
                .scaleEffect(scale)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: cat.meow)
            BuddyWaveform(color: color, level: audioLevel, animated: animated)
                .offset(x: cat.facingLeft ? -30 : 30, y: -8)
                .opacity(state == .listening ? 1 : 0)
            BuddySpinner(color: color, animated: animated)
                .offset(x: cat.facingLeft ? -26 : 26, y: -16)
                .opacity(state == .processing ? 1 : 0)
        }
        .frame(width: 40, height: 40)
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    private var triangleBody: some View {
        ZStack {
            BuddyTriangle(color: color, glowBoost: scale - 1)
                .rotationEffect(.degrees(rotation))
                .scaleEffect(scale)
                .opacity(state == .idle || state == .responding ? 1 : 0)
                .scaleEffect(state == .idle || state == .responding ? 1 : 0.6)
            BuddyWaveform(color: color, level: audioLevel, animated: animated)
                .opacity(state == .listening ? 1 : 0)
                .scaleEffect(state == .listening ? 1 : 0.6)
            BuddySpinner(color: color, animated: animated)
                .opacity(state == .processing ? 1 : 0)
                .scaleEffect(state == .processing ? 1 : 0.6)
        }
        .frame(width: 40, height: 40)
        .animation(.easeInOut(duration: 0.2), value: state)
    }
}

/// Solid fill, no outline, one soft glow in the same colour (reference: α≈0.17 1 pt out,
/// 0.10 at 5 pt, 0.04 at 10 pt, gone by 20 pt). The glow widens a touch while flying.
struct BuddyTriangle: View {
    var color: Color
    var glowBoost: CGFloat = 0

    var body: some View {
        BuddyTriangleShape()
            .fill(color)
            .shadow(color: color, radius: 8.5 + glowBoost * 12)
            .frame(width: BuddyMetrics.frame, height: BuddyMetrics.frame)
    }
}

/// Five bars where the triangle was while the talk key is held, driven by the mic level.
/// Reference: bars 2 pt wide on a 4 pt pitch (18 pt across), 2 pt tall at rest, ≈11 pt at a
/// loud peak, the middle bar tallest; centred on the buddy's resting point.
struct BuddyWaveform: View {
    var color: Color
    var level: CGFloat
    var animated = true
    private let profile: [CGFloat] = [0.55, 0.75, 1.0, 0.8, 0.55]

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1 / 40)) { ctx in bars(ctx.date.timeIntervalSinceReferenceDate) }
        } else {
            bars(0.9)
        }
    }

    private func bars(_ t: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: height(i, t))
            }
        }
        .frame(height: 12)
        .shadow(color: color.opacity(0.5), radius: 4)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func height(_ i: Int, _ t: TimeInterval) -> CGFloat {
        let phase = CGFloat(t * 3.6) + CGFloat(i) * 0.55
        let eased = pow(min(max(level - 0.008, 0) * 2.85, 1), 0.76)
        let reactive = eased * 8.5 * profile[i]
        let idle = (sin(phase) + 1) / 2 * 0.8
        return 2 + reactive + idle
    }
}

/// A small arc spinner while Awan thinks (reference: ≈13 pt ring, 2 pt stroke, round caps,
/// the tail fading out, soft glow).
struct BuddySpinner: View {
    var color: Color
    var animated = true
    @Local private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.72)
            .stroke(AngularGradient(colors: [color.opacity(0), color], center: .center,
                                    startAngle: .degrees(0.08 * 360), endAngle: .degrees(0.72 * 360)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(spinning ? 360 : 30))
            .shadow(color: color.opacity(0.55), radius: 4)
            .onAppear {
                guard animated else { return }
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
            }
    }
}

/// Text colour on a buddy-coloured label: white on saturated colours (the reference's blue),
/// ink on Awan's light ones (lime, bone) so the label stays readable.
enum BuddyLabelInk {
    static func on(_ color: Color) -> Color {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return .white }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        return l > 0.4 ? Theme.ink : .white
    }
}

/// Shared look of the buddy's labels: a solid rounded rect in the buddy colour (radius 6),
/// no outline, a soft glow in the same colour.
private struct BuddyLabelBackground: ViewModifier {
    var color: Color

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color))
            .shadow(color: color.opacity(0.55), radius: 5)
    }
}

/// The label typed out beside a pointed-at target ("menu bar clock"). Reference: 21 pt tall,
/// text + 16 pt wide, top-left 10 pt right / 7.5 pt below the triangle's centroid.
struct PointLabelBubble: View {
    var text: String
    var color: Color
    static let font: CGFloat = 11.5
    static let offset = CGVector(dx: 10, dy: 7.5)

    var body: some View {
        Text(text)
            .font(.awan(Self.font, .semibold))
            .foregroundStyle(BuddyLabelInk.on(color))
            .lineLimit(1)
            .fixedSize()   // one line, sized by the renderer itself (a pre-measured width wrapped "menu bar clock")
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .modifier(BuddyLabelBackground(color: color))
    }
}

/// Text beside the cursor (agent replies, companion lines, onboarding captions). Reference: the
/// same buddy-coloured label, 12 pt semibold, at most ≈282 pt wide (then wraps), padding 8×4.5,
/// top-left 10 pt right / 18 pt below the triangle's centroid (pointer + 45, + 43).
struct CursorTextBubble: View {
    var text: String
    var streaming: Bool
    var accent: Color
    static let font: CGFloat = 12
    static let maxWidth: CGFloat = 282
    static let offset = CGVector(dx: 10, dy: 18)

    var body: some View {
        Text(text)
            .font(.awan(Self.font, .semibold))
            .foregroundStyle(BuddyLabelInk.on(accent))
            .lineSpacing(0.5)
            .frame(width: TextMeasure.width(text, size: Self.font, weight: .semibold, max: Self.maxWidth - 16, slack: 2), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .modifier(BuddyLabelBackground(color: accent))
    }
}

/// Single-line text width, so pinned bubbles can size to their text and wrap only past a maximum.
enum TextMeasure {
    static func width(_ text: String, size: CGFloat, weight: NSFont.Weight, max maxWidth: CGFloat, slack: CGFloat = 6) -> CGFloat {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: AwanFont.family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        let font = AwanFont.isAvailable ? (NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)) : .systemFont(ofSize: size, weight: weight)
        let longest = text.components(separatedBy: "\n").map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return min(maxWidth, max(4, ceil(longest) + slack))
    }
}
