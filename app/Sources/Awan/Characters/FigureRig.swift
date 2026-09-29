import SwiftUI
import AppKit

// The figure rig: one procedural portrait (hair back → neck → outfit → head → face → hair front)
// shared by the Kawan, Pahlawan, Arked, Gebu and Hikayat packs. Everything is drawn in a unit
// square inside a single Canvas, so a portrait stays crisp from a 20 pt notch avatar to a 220 pt hero.

/// What part of the character a portrait shows.
enum FigureFraming: Hashable {
    case bust      // head and shoulders (avatars, previews)
    case face      // head only (hair tiles, peeking over edges)
    case outfit    // zoomed on the outfit (outfit tiles)
}

/// How a pack draws eyes.
enum FigureFaceStyle { case sclera, pixel, dot, bead }
/// The pack's head silhouette.
enum FigureHeadShape { case round, square, blob }

extension CharacterPack {
    var faceStyle: FigureFaceStyle {
        switch self {
        case .arked: return .pixel
        case .gebu: return .dot
        case .hikayat: return .bead
        default: return .sclera
        }
    }
    var headShape: FigureHeadShape {
        switch self {
        case .arked: return .square
        case .gebu: return .blob
        default: return .round
        }
    }
    /// Pahlawan always wear their brows; other packs only show them when the face needs them.
    var alwaysBrows: Bool { self == .pahlawan }
}

/// Eyes closed for a moment (blinks, sleep, winks) — overrides the expression's eyes.
enum ClosedEyes: Hashable { case line, sleep, happy }

/// Everything that varies frame to frame on top of the appearance.
struct FigurePose: Hashable {
    var expression: CharacterExpression = .idle
    var closed: ClosedEyes? = nil
    var winkRight = false          // right eye closed happy, left open
    var mouthOpen: CGFloat? = nil  // 0…1 while speaking
    var showExtras = true
}

struct FigurePortrait: View {
    var appearance: CharacterAppearance
    var pose = FigurePose()
    var framing: FigureFraming = .bust

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            FigureRig(appearance: appearance, pose: pose).draw(in: &ctx, size: size, framing: framing)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: - Palette

struct FigurePalette {
    let hair, hairShade, hairLight: Color
    let skin, skinShade: Color
    let iris: Color
    let outfit, outfitShade, outfitLight: Color
    let accent, accentShade: Color
    let ink = Color(hex: 0x1F1A17)
    let metal = Color(hex: 0xC7CFDA), metalShade = Color(hex: 0x8C96A5)
    let white = Color(hex: 0xFFFDF8)
    let inner = Color(hex: 0xF7B3C2)
    let blush = Color(hex: 0xFF7F96)
    let heart = Color(hex: 0xF0506E)
    let mouth = Color(hex: 0x7A2B33), tongue = Color(hex: 0xF08A94)

    init(_ a: CharacterAppearance) {
        let h = CharacterCatalog.hairColor(a)
        hair = h; hairShade = h.mixed(with: .black, 0.28); hairLight = h.mixed(with: .white, 0.38)
        let s = CharacterCatalog.skinColor(a)
        skin = s; skinShade = s.mixed(with: Color(hex: 0x8A4B3A), 0.22)
        iris = CharacterCatalog.eyeColor(a)
        let o = CharacterCatalog.outfitColor(a)
        outfit = o; outfitShade = o.mixed(with: .black, 0.2); outfitLight = o.mixed(with: .white, 0.35)
        let c = CharacterCatalog.accentColor(a)
        accent = c; accentShade = c.mixed(with: .black, 0.22)
    }

    func color(_ ink: FigureInk) -> Color {
        switch ink {
        case .hair: return hair
        case .shade: return hairShade
        case .light: return hairLight
        case .accent: return accent
        case .accentShade: return accentShade
        case .metal: return metal
        case .metalShade: return metalShade
        case .white: return white
        case .inner: return inner
        case .ink: return self.ink
        case .skin: return skin
        case .outfit: return outfit
        case .outfitShade: return outfitShade
        case .outfitLight: return outfitLight
        case .gold: return Color(hex: 0xF4C548)
        case .leather: return Color(hex: 0x7A5134)
        }
    }
}

enum FigureInk { case hair, shade, light, accent, accentShade, metal, metalShade, white, inner, ink, skin, outfit, outfitShade, outfitLight, gold, leather }

/// One filled (and usually outlined) shape of hair, headgear or outfit, in unit coordinates.
struct FigurePiece {
    var path: Path
    var fill: FigureInk?
    var outlined = true
    var alpha: Double = 1
    var stroke: FigureInk? = nil       // stroke-only detail lines (seams, veins, stripes)
    var strokeScale: CGFloat = 1
    var glow = false                   // soft halo behind (lantern flames)
}

extension Color {
    /// Linear mix in sRGB (t = 0 → self, 1 → other).
    func mixed(with other: Color, _ t: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .gray
        func m(_ x: CGFloat, _ y: CGFloat) -> Double { Double(x + (y - x) * CGFloat(t)) }
        return Color(.sRGB, red: m(a.redComponent, b.redComponent), green: m(a.greenComponent, b.greenComponent),
                     blue: m(a.blueComponent, b.blueComponent), opacity: m(a.alphaComponent, b.alphaComponent))
    }
}

// MARK: - Path helpers (unit coordinates)

@inline(__always) func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

func ellipsePath(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path { Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h)) }
func circlePath(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)) }
func polyPath(_ pts: [(CGFloat, CGFloat)], close: Bool = true) -> Path {
    var p = Path()
    guard let f = pts.first else { return p }
    p.move(to: pt(f.0, f.1))
    for q in pts.dropFirst() { p.addLine(to: pt(q.0, q.1)) }
    if close { p.closeSubpath() }
    return p
}
func mirrored(_ p: Path) -> Path { p.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0)) }
func rotated(_ p: Path, _ degrees: CGFloat, around c: CGPoint) -> Path {
    p.applying(CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180)).concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
}
/// A lens-shaped leaf from `a` to `b`, `width` as a fraction of its length.
func leafPath(from a: CGPoint, to b: CGPoint, width: CGFloat = 0.45) -> Path {
    let dx = b.x - a.x, dy = b.y - a.y
    let nx = -dy * width, ny = dx * width
    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    var p = Path()
    p.move(to: a)
    p.addQuadCurve(to: b, control: CGPoint(x: mid.x + nx, y: mid.y + ny))
    p.addQuadCurve(to: a, control: CGPoint(x: mid.x - nx, y: mid.y - ny))
    return p
}
func starPath(_ c: CGPoint, _ r: CGFloat, points: Int = 5, inner: CGFloat = 0.46, rotation: CGFloat = -90) -> Path {
    var pts: [(CGFloat, CGFloat)] = []
    for i in 0..<(points * 2) {
        let rr = i % 2 == 0 ? r : r * inner
        let a = (rotation + CGFloat(i) * 180 / CGFloat(points)) * .pi / 180
        pts.append((c.x + cos(a) * rr, c.y + sin(a) * rr))
    }
    return polyPath(pts)
}
func heartPath(_ c: CGPoint, _ s: CGFloat) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: c.x, y: c.y + s * 0.42))
    p.addCurve(to: CGPoint(x: c.x - s * 0.5, y: c.y - s * 0.1), control1: CGPoint(x: c.x - s * 0.18, y: c.y + s * 0.26), control2: CGPoint(x: c.x - s * 0.5, y: c.y + s * 0.12))
    p.addCurve(to: CGPoint(x: c.x, y: c.y - s * 0.22), control1: CGPoint(x: c.x - s * 0.5, y: c.y - s * 0.42), control2: CGPoint(x: c.x - s * 0.08, y: c.y - s * 0.42))
    p.addCurve(to: CGPoint(x: c.x + s * 0.5, y: c.y - s * 0.1), control1: CGPoint(x: c.x + s * 0.08, y: c.y - s * 0.42), control2: CGPoint(x: c.x + s * 0.5, y: c.y - s * 0.42))
    p.addCurve(to: CGPoint(x: c.x, y: c.y + s * 0.42), control1: CGPoint(x: c.x + s * 0.5, y: c.y + s * 0.12), control2: CGPoint(x: c.x + s * 0.18, y: c.y + s * 0.26))
    p.closeSubpath()
    return p
}
/// Four-point sparkle.
func sparklePath(_ c: CGPoint, _ r: CGFloat) -> Path { starPath(c, r, points: 4, inner: 0.32, rotation: -90) }

// MARK: - Rig

struct FigureRig {
    let appearance: CharacterAppearance
    let pose: FigurePose
    let pal: FigurePalette

    init(appearance: CharacterAppearance, pose: FigurePose) {
        self.appearance = appearance
        self.pose = pose
        self.pal = FigurePalette(appearance)
    }

    /// Head square inside the bust square.
    static let headScale: CGFloat = 0.78
    static let headOrigin = CGPoint(x: 0.11, y: 0.03)

    func draw(in ctx: inout GraphicsContext, size: CGSize, framing: FigureFraming) {
        let S = min(size.width, size.height)
        guard S > 1 else { return }
        var g = ctx
        g.translateBy(x: (size.width - S) / 2, y: (size.height - S) / 2)
        g.scaleBy(x: S, y: S)
        // Outline weight in unit space: 2 % of the portrait, but never thinner than ~0.8 pt on screen.
        let lw = max(0.02, 0.8 / S)
        let detailed = S >= 36
        let extras = pose.showExtras && S >= 44

        switch framing {
        case .face:
            // a little headroom so tall hair and hats stay inside the tile
            var h = g
            h.translateBy(x: 0.04, y: 0.07)
            h.scaleBy(x: 0.92, y: 0.92)
            drawHead(&h, lw: lw / 0.92, detailed: detailed, extras: extras)
        case .bust:
            var h = g
            h.translateBy(x: Self.headOrigin.x, y: Self.headOrigin.y)
            h.scaleBy(x: Self.headScale, y: Self.headScale)
            drawLayers(body: &g, head: &h, lw: lw, detailed: detailed, extras: extras)
        case .outfit:
            // the bust's lower square (x 0.17…0.83, y 0.42…1.08) blown up to fill the tile
            let side: CGFloat = 0.66, k = 1 / side
            var b = g
            b.scaleBy(x: k, y: k)
            b.translateBy(x: -0.17, y: -0.42)
            var h = b
            h.translateBy(x: Self.headOrigin.x, y: Self.headOrigin.y)
            h.scaleBy(x: Self.headScale, y: Self.headScale)
            drawLayers(body: &b, head: &h, lw: lw / k, detailed: true, extras: false)
        }
    }

    private func drawLayers(body g: inout GraphicsContext, head h: inout GraphicsContext, lw: CGFloat, detailed: Bool, extras: Bool) {
        let hlw = lw / Self.headScale
        let hair = HairLibrary.pieces(appearance.hairstyle)
        render(hair.back, in: &h, lw: hlw)
        if appearance.pack.headShape != .blob { drawNeck(&g, lw: lw) }
        render(OutfitLibrary.pieces(appearance.outfitStyle, detailed: detailed), in: &g, lw: lw)
        drawHeadShape(&h, lw: hlw)
        drawFace(&h, lw: hlw, detailed: detailed)
        render(hair.front, in: &h, lw: hlw)
        drawBrows(&h, lw: hlw)
        if extras { drawExtras(&h, lw: hlw) }
    }

    private func drawHead(_ g: inout GraphicsContext, lw: CGFloat, detailed: Bool, extras: Bool) {
        let hair = HairLibrary.pieces(appearance.hairstyle)
        render(hair.back, in: &g, lw: lw)
        drawHeadShape(&g, lw: lw)
        drawFace(&g, lw: lw, detailed: detailed)
        render(hair.front, in: &g, lw: lw)
        drawBrows(&g, lw: lw)
        if extras { drawExtras(&g, lw: lw) }
    }

    func render(_ pieces: [FigurePiece], in g: inout GraphicsContext, lw: CGFloat) {
        for piece in pieces {
            var c = g
            c.opacity = piece.alpha
            if piece.glow, let f = piece.fill {
                let b = piece.path.boundingRect
                let r = max(b.width, b.height) * 0.8
                c.fill(Path(ellipseIn: b.insetBy(dx: -r * 0.5, dy: -r * 0.5)),
                       with: .radialGradient(Gradient(colors: [pal.color(f).opacity(0.55), pal.color(f).opacity(0)]), center: CGPoint(x: b.midX, y: b.midY), startRadius: 0, endRadius: r))
            }
            if let f = piece.fill { c.fill(piece.path, with: .color(pal.color(f))) }
            if let s = piece.stroke {
                c.stroke(piece.path, with: .color(pal.color(s)), style: StrokeStyle(lineWidth: lw * piece.strokeScale, lineCap: .round, lineJoin: .round))
            } else if piece.outlined {
                c.stroke(piece.path, with: .color(pal.ink), style: StrokeStyle(lineWidth: lw * piece.strokeScale, lineCap: .round, lineJoin: .round))
            }
        }
    }

    // MARK: Head

    static func headPath(_ shape: FigureHeadShape) -> Path {
        switch shape {
        case .round:
            return ellipsePath(0.14, 0.25, 0.72, 0.62)
        case .square:
            return Path(roundedRect: CGRect(x: 0.15, y: 0.26, width: 0.70, height: 0.60), cornerRadius: 0.2, style: .continuous)
        case .blob:
            var p = Path()
            p.move(to: pt(0.5, 0.25))
            p.addCurve(to: pt(0.89, 0.64), control1: pt(0.76, 0.25), control2: pt(0.89, 0.42))
            p.addCurve(to: pt(0.5, 0.89), control1: pt(0.89, 0.84), control2: pt(0.72, 0.89))
            p.addCurve(to: pt(0.11, 0.64), control1: pt(0.28, 0.89), control2: pt(0.11, 0.84))
            p.addCurve(to: pt(0.5, 0.25), control1: pt(0.11, 0.42), control2: pt(0.24, 0.25))
            p.closeSubpath()
            return p
        }
    }

    private func drawHeadShape(_ g: inout GraphicsContext, lw: CGFloat) {
        let head = Self.headPath(appearance.pack.headShape)
        g.fill(head, with: .color(pal.skin))
        if appearance.pack.headShape == .blob {
            // soft top light on the blob
            g.fill(ellipsePath(0.28, 0.30, 0.3, 0.14), with: .color(.white.opacity(0.28)))
        }
        g.stroke(head, with: .color(pal.ink), lineWidth: lw)
    }

    private func drawNeck(_ g: inout GraphicsContext, lw: CGFloat) {
        let neck = Path(CGRect(x: 0.445, y: 0.62, width: 0.11, height: 0.16))
        g.fill(neck, with: .color(pal.skin))
        g.fill(Path(CGRect(x: 0.445, y: 0.68, width: 0.11, height: 0.035)), with: .color(pal.skinShade.opacity(0.55)))
        var sides = Path()
        sides.move(to: pt(0.445, 0.62)); sides.addLine(to: pt(0.445, 0.78))
        sides.move(to: pt(0.555, 0.62)); sides.addLine(to: pt(0.555, 0.78))
        g.stroke(sides, with: .color(pal.ink), lineWidth: lw)
    }

    // MARK: Face

    private var eyeCenters: (CGPoint, CGPoint) {
        switch appearance.pack.faceStyle {
        case .sclera: return (pt(0.365, 0.575), pt(0.635, 0.575))
        case .pixel: return (pt(0.38, 0.575), pt(0.62, 0.575))
        case .dot: return (pt(0.395, 0.585), pt(0.605, 0.585))
        case .bead: return (pt(0.375, 0.58), pt(0.625, 0.58))
        }
    }

    private var eyeSize: CGSize {
        switch appearance.pack.faceStyle {
        case .sclera: return CGSize(width: 0.22, height: 0.24)
        case .pixel: return CGSize(width: 0.15, height: 0.18)
        case .dot: return CGSize(width: 0.085, height: 0.11)
        case .bead: return CGSize(width: 0.15, height: 0.185)
        }
    }

    private var mouthCenter: CGPoint {
        switch appearance.pack.faceStyle {
        case .dot: return pt(0.5, 0.69)
        case .pixel: return pt(0.5, 0.75)
        default: return pt(0.5, 0.765)
        }
    }

    enum EyeLid { case none, flat(CGFloat), angry, sad }
    struct EyeSpec {
        var closed: ClosedEyes? = nil
        var laugh = false
        var heart = false
        var scale: CGFloat = 1
        var pupil: CGFloat = 1
        var gaze = CGPoint.zero
        var lid: EyeLid = .none
        var sparkle = false
    }

    private func eyeSpecs() -> (EyeSpec, EyeSpec) {
        var l = EyeSpec(), r = EyeSpec()
        switch pose.expression {
        case .idle: break
        case .curious: l.scale = 1.05; l.gaze = pt(0.08, -0.1); r = l
        case .listening: l.pupil = 1.12; r = l
        case .thinking: l.gaze = pt(0.14, -0.16); l.lid = .flat(0.16); r = l
        case .happy: l.closed = .happy; r = l
        case .sleepy: l.lid = .flat(0.55); l.gaze = pt(0, 0.1); r = l
        case .surprised: l.scale = 1.12; l.pupil = 0.68; r = l
        case .skeptical: l.lid = .flat(0.12); l.gaze = pt(-0.1, 0); r = l; r.lid = .flat(0.48)
        case .shy: l.gaze = pt(-0.12, 0.16); l.scale = 0.94; r = l
        case .excited: l.sparkle = true; l.pupil = 1.1; l.scale = 1.05; r = l
        case .laughing: l.laugh = true; r = l
        case .determined: l.lid = .angry; r = l
        case .loving: l.heart = true; r = l
        case .sad: l.lid = .sad; l.gaze = pt(0, 0.08); r = l
        }
        if let c = pose.closed { l = EyeSpec(closed: c); r = l }
        if pose.winkRight { r = EyeSpec(closed: .happy); if l.closed != nil || l.laugh || l.heart { l = EyeSpec() } }
        return (l, r)
    }

    private func drawFace(_ g: inout GraphicsContext, lw: CGFloat, detailed: Bool) {
        let style = appearance.pack.faceStyle
        let (lc, rc) = eyeCenters
        let (ls, rs) = eyeSpecs()

        // cheeks
        let blushStrong: [CharacterExpression] = [.shy, .loving]
        let blushSoft: [CharacterExpression] = [.happy, .laughing, .excited]
        var blush: Double = style == .dot ? 0.42 : 0
        if blushStrong.contains(pose.expression) { blush = 0.6 } else if blushSoft.contains(pose.expression) { blush = max(blush, 0.34) }
        if blush > 0 {
            let y: CGFloat = style == .dot ? 0.665 : 0.695
            let dx: CGFloat = style == .dot ? 0.2 : 0.24
            for cx in [0.5 - dx, 0.5 + dx] {
                g.fill(ellipsePath(cx - 0.055, y - 0.028, 0.11, 0.056), with: .color(pal.blush.opacity(blush)))
            }
        }

        drawEye(&g, center: lc, spec: ls, style: style, lw: lw, isLeft: true)
        drawEye(&g, center: rc, spec: rs, style: style, lw: lw, isLeft: false)
        drawMouth(&g, lw: lw)
    }

    private func drawEye(_ g: inout GraphicsContext, center c: CGPoint, spec: EyeSpec, style: FigureFaceStyle, lw: CGFloat, isLeft: Bool) {
        let base = eyeSize
        let w = base.width * spec.scale, h = base.height * spec.scale
        let strokeW = style == .dot ? lw * 1.25 : lw * 1.3

        if spec.heart {
            let s = max(w, h) * (style == .dot ? 1.6 : 1.05)
            let heart = heartPath(pt(c.x, c.y + h * 0.02), s)
            g.fill(heart, with: .color(pal.heart))
            g.stroke(heart, with: .color(pal.ink), lineWidth: lw * 0.9)
            g.fill(circlePath(c.x - s * 0.2, c.y - s * 0.1, s * 0.09), with: .color(.white.opacity(0.9)))
            return
        }
        if spec.laugh {
            var p = Path()
            let dir: CGFloat = isLeft ? 1 : -1
            let ww = max(w, 0.13) * 0.5, hh = max(h, 0.13) * 0.34
            p.move(to: pt(c.x - dir * ww * 0.8, c.y - hh))
            p.addLine(to: pt(c.x + dir * ww * 0.7, c.y))
            p.addLine(to: pt(c.x - dir * ww * 0.8, c.y + hh))
            g.stroke(p, with: .color(pal.ink), style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))
            return
        }
        if let closed = spec.closed {
            let ww = max(w, 0.12) * 0.46
            var p = Path()
            switch closed {
            case .happy:
                p.move(to: pt(c.x - ww, c.y + 0.02))
                p.addQuadCurve(to: pt(c.x + ww, c.y + 0.02), control: pt(c.x, c.y - 0.07))
            case .sleep:
                p.move(to: pt(c.x - ww, c.y))
                p.addQuadCurve(to: pt(c.x + ww, c.y), control: pt(c.x, c.y + 0.06))
            case .line:
                p.move(to: pt(c.x - ww, c.y + 0.01))
                p.addQuadCurve(to: pt(c.x + ww, c.y + 0.01), control: pt(c.x, c.y + 0.025))
            }
            g.stroke(p, with: .color(pal.ink), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
            // lashes on the sclera style's sleepy line
            if closed == .sleep && style == .sclera {
                var lash = Path()
                let side: CGFloat = isLeft ? -1 : 1
                lash.move(to: pt(c.x + side * ww, c.y)); lash.addLine(to: pt(c.x + side * (ww + 0.025), c.y - 0.012))
                g.stroke(lash, with: .color(pal.ink), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }
            return
        }

        let rect = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        let shape: Path = style == .pixel ? Path(roundedRect: rect, cornerRadius: w * 0.26, style: .continuous) : Path(ellipseIn: rect)
        let gx = spec.gaze.x * w, gy = spec.gaze.y * h

        var clip = g
        clip.clip(to: shape)
        switch style {
        case .sclera:
            g.fill(shape, with: .color(.white))
            let iw = w * 0.74, ih = h * 0.78
            let ic = pt(c.x + gx, c.y + h * 0.04 + gy)
            clip.fill(ellipsePath(ic.x - iw / 2, ic.y - ih / 2, iw, ih), with: .color(pal.iris))
            clip.fill(ellipsePath(ic.x - iw * 0.36, ic.y + ih * 0.02, iw * 0.72, ih * 0.44), with: .color(pal.iris.mixed(with: .white, 0.3)))
            let pw = w * 0.5 * spec.pupil, ph = h * 0.56 * spec.pupil
            clip.fill(ellipsePath(ic.x - pw / 2, ic.y - ph / 2 + h * 0.01, pw, ph), with: .color(pal.ink))
            highlights(&clip, at: ic, w: w, h: h, sparkle: spec.sparkle)
        case .pixel:
            clip.fill(shape, with: .color(pal.ink))
            let ir = CGRect(x: c.x - w * 0.36 + gx, y: c.y + h * 0.08 + gy, width: w * 0.72, height: h * 0.34)
            clip.fill(Path(roundedRect: ir, cornerRadius: w * 0.08), with: .color(pal.iris))
            if spec.sparkle {
                clip.fill(sparklePath(pt(c.x - w * 0.12 + gx, c.y - h * 0.14 + gy), w * 0.3), with: .color(.white))
            } else {
                let q = w * 0.3 * (spec.pupil < 1 ? 0.8 : 1)
                clip.fill(Path(CGRect(x: c.x - w * 0.3 + gx, y: c.y - h * 0.34 + gy, width: q, height: q)), with: .color(.white))
                clip.fill(Path(CGRect(x: c.x + w * 0.12 + gx, y: c.y - h * 0.3 + gy, width: q * 0.4, height: q * 0.4)), with: .color(.white.opacity(0.85)))
            }
        case .dot:
            let dw = w * (spec.pupil < 1 ? 0.8 : 1), dh = h * (spec.pupil < 1 ? 0.8 : 1)
            let dot = ellipsePath(c.x - dw / 2 + gx * 0.4, c.y - dh / 2 + gy * 0.4, dw, dh)
            g.fill(dot, with: .color(pal.ink))
            var dc = g; dc.clip(to: dot)
            if spec.sparkle {
                dc.fill(sparklePath(pt(c.x - w * 0.12, c.y - h * 0.14), w * 0.36), with: .color(.white))
            } else {
                dc.fill(circlePath(c.x - w * 0.16 + gx * 0.4, c.y - h * 0.18 + gy * 0.4, w * 0.2), with: .color(.white))
            }
        case .bead:
            clip.fill(shape, with: .color(pal.ink))
            let iw = w * 0.9, ih = h * 0.62
            clip.fill(ellipsePath(c.x - iw / 2 + gx, c.y + h * 0.1 + gy, iw, ih), with: .color(pal.iris.opacity(0.9)))
            let pw = w * 0.6 * spec.pupil, ph = h * 0.62 * spec.pupil
            clip.fill(ellipsePath(c.x - pw / 2 + gx, c.y - ph / 2 + gy, pw, ph), with: .color(pal.ink))
            highlights(&clip, at: pt(c.x + gx, c.y + gy), w: w, h: h, sparkle: spec.sparkle)
        }

        // lids (skin laid over the top of the eye, then a lid line)
        switch spec.lid {
        case .none: break
        case let .flat(k):
            let y = rect.minY + h * k
            clip.fill(Path(CGRect(x: rect.minX - 0.02, y: rect.minY - 0.02, width: w + 0.04, height: y - rect.minY + 0.02)), with: .color(pal.skin))
            var line = Path(); line.move(to: pt(rect.minX, y)); line.addLine(to: pt(rect.maxX, y))
            var lc = g; lc.clip(to: Path(rect.insetBy(dx: -0.01, dy: -0.01)))
            lc.stroke(line, with: .color(pal.ink), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
        case .angry, .sad:
            let innerX = isLeft ? rect.maxX : rect.minX, outerX = isLeft ? rect.minX : rect.maxX
            let (innerY, outerY): (CGFloat, CGFloat) = spec.lid.isAngry ? (rect.minY + h * 0.42, rect.minY + h * 0.08) : (rect.minY + h * 0.1, rect.minY + h * 0.4)
            let lid = polyPath([(outerX, rect.minY - 0.03), (innerX, rect.minY - 0.03), (innerX, innerY), (outerX, outerY)])
            clip.fill(lid, with: .color(pal.skin))
            var line = Path(); line.move(to: pt(outerX, outerY)); line.addLine(to: pt(innerX, innerY))
            var lc = g; lc.clip(to: Path(rect.insetBy(dx: -0.004, dy: -0.004)))
            lc.stroke(line, with: .color(pal.ink), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
        }

        if style == .sclera {
            g.stroke(shape, with: .color(pal.ink), lineWidth: lw * 1.05)
        }
    }

    private func highlights(_ g: inout GraphicsContext, at ic: CGPoint, w: CGFloat, h: CGFloat, sparkle: Bool) {
        if sparkle {
            g.fill(sparklePath(pt(ic.x - w * 0.14, ic.y - h * 0.14), w * 0.26), with: .color(.white))
            g.fill(circlePath(ic.x + w * 0.16, ic.y + h * 0.16, w * 0.06), with: .color(.white.opacity(0.9)))
        } else {
            g.fill(circlePath(ic.x - w * 0.13, ic.y - h * 0.13, w * 0.12), with: .color(.white))
            g.fill(circlePath(ic.x + w * 0.15, ic.y + h * 0.16, w * 0.05), with: .color(.white.opacity(0.85)))
        }
    }

    private func drawMouth(_ g: inout GraphicsContext, lw: CGFloat) {
        let m = mouthCenter
        var c = g
        c.translateBy(x: m.x, y: m.y)
        let k: CGFloat = appearance.pack.faceStyle == .dot ? 0.8 : 1
        c.scaleBy(x: k, y: k)
        let line = StrokeStyle(lineWidth: lw * 1.05 / k, lineCap: .round, lineJoin: .round)
        func stroke(_ p: Path) { c.stroke(p, with: .color(pal.ink), style: line) }
        func open(_ p: Path, tongue: Bool = true) {
            c.fill(p, with: .color(pal.mouth))
            if tongue {
                var t = c; t.clip(to: p)
                let b = p.boundingRect
                t.fill(ellipsePath(b.midX - b.width * 0.34, b.maxY - b.height * 0.42, b.width * 0.68, b.height * 0.6), with: .color(pal.tongue))
            }
            c.stroke(p, with: .color(pal.ink), style: line)
        }

        if let o = pose.mouthOpen {
            let hh = 0.012 + 0.04 * o
            open(ellipsePath(-0.028, -hh / 2, 0.056, hh), tongue: o > 0.4)
            return
        }
        var p = Path()
        switch pose.expression {
        case .idle, .listening:
            p.move(to: pt(-0.035, -0.008)); p.addQuadCurve(to: pt(0.035, -0.008), control: pt(0, 0.03)); stroke(p)
        case .happy, .loving:
            p.move(to: pt(-0.055, -0.014)); p.addQuadCurve(to: pt(0.055, -0.014), control: pt(0, 0.05)); stroke(p)
        case .curious, .sleepy:
            let r: CGFloat = pose.expression == .sleepy ? 0.014 : 0.018
            open(ellipsePath(-r, -r * 0.9, r * 2, r * 2.2), tongue: false)
        case .surprised:
            open(ellipsePath(-0.03, -0.028, 0.06, 0.07))
        case .thinking:
            p.move(to: pt(-0.015, 0.004)); p.addLine(to: pt(0.045, -0.006)); stroke(p)
        case .skeptical:
            p.move(to: pt(-0.04, 0.006)); p.addQuadCurve(to: pt(0.045, -0.012), control: pt(0.01, 0.006)); stroke(p)
        case .shy:
            p.move(to: pt(-0.032, 0)); p.addQuadCurve(to: pt(0, 0), control: pt(-0.016, -0.014)); p.addQuadCurve(to: pt(0.032, 0), control: pt(0.016, 0.014)); stroke(p)
        case .excited:
            var d = Path()
            d.move(to: pt(-0.055, -0.018)); d.addLine(to: pt(0.055, -0.018))
            d.addQuadCurve(to: pt(-0.055, -0.018), control: pt(0, 0.1)); d.closeSubpath()
            open(d)
        case .laughing:
            var d = Path()
            d.move(to: pt(-0.07, -0.024)); d.addLine(to: pt(0.07, -0.024))
            d.addQuadCurve(to: pt(-0.07, -0.024), control: pt(0, 0.13)); d.closeSubpath()
            open(d)
        case .determined:
            p.move(to: pt(-0.04, 0.008)); p.addQuadCurve(to: pt(0.04, 0.008), control: pt(0, -0.008)); stroke(p)
        case .sad:
            p.move(to: pt(-0.04, 0.016)); p.addQuadCurve(to: pt(0.04, 0.016), control: pt(0, -0.026)); stroke(p)
        }
    }

    // MARK: Brows

    private func drawBrows(_ g: inout GraphicsContext, lw: CGFloat) {
        let e = pose.expression
        let needs: [CharacterExpression] = [.surprised, .determined, .sad, .skeptical, .thinking]
        guard appearance.pack.alwaysBrows || needs.contains(e) else { return }
        guard pose.closed == nil || appearance.pack.alwaysBrows else { return }
        let (lc, rc) = eyeCenters
        let top = lc.y - eyeSize.height / 2 - (appearance.pack.faceStyle == .dot ? 0.05 : 0.04)
        let halfW: CGFloat = appearance.pack.faceStyle == .dot ? 0.045 : 0.065
        let thick = appearance.pack.alwaysBrows ? lw * 2.4 : lw * 1.5
        let color = appearance.pack.alwaysBrows ? pal.hairShade.mixed(with: pal.ink, 0.35) : pal.ink

        func brow(_ c: CGPoint, isLeft: Bool, raise: CGFloat, innerDrop: CGFloat, arch: CGFloat) {
            let inner = isLeft ? c.x + halfW : c.x - halfW
            let outer = isLeft ? c.x - halfW : c.x + halfW
            var p = Path()
            p.move(to: pt(outer, top - raise))
            p.addQuadCurve(to: pt(inner, top - raise + innerDrop), control: pt(c.x, top - raise - arch))
            g.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: thick, lineCap: .round))
        }
        switch e {
        case .surprised: brow(lc, isLeft: true, raise: 0.035, innerDrop: 0, arch: 0.02); brow(rc, isLeft: false, raise: 0.035, innerDrop: 0, arch: 0.02)
        case .determined: brow(lc, isLeft: true, raise: -0.005, innerDrop: 0.035, arch: 0); brow(rc, isLeft: false, raise: -0.005, innerDrop: 0.035, arch: 0)
        case .sad: brow(lc, isLeft: true, raise: 0.01, innerDrop: -0.03, arch: 0); brow(rc, isLeft: false, raise: 0.01, innerDrop: -0.03, arch: 0)
        case .skeptical: brow(lc, isLeft: true, raise: -0.005, innerDrop: 0.01, arch: 0); brow(rc, isLeft: false, raise: 0.03, innerDrop: 0, arch: 0.02)
        case .thinking: brow(lc, isLeft: true, raise: 0.0, innerDrop: 0, arch: 0.008); brow(rc, isLeft: false, raise: 0.03, innerDrop: 0, arch: 0.018)
        case .curious, .excited: brow(lc, isLeft: true, raise: 0.02, innerDrop: 0, arch: 0.015); brow(rc, isLeft: false, raise: 0.02, innerDrop: 0, arch: 0.015)
        default: brow(lc, isLeft: true, raise: 0.005, innerDrop: 0.008, arch: 0.01); brow(rc, isLeft: false, raise: 0.005, innerDrop: 0.008, arch: 0.01)
        }
    }

    // MARK: Extras (little marks around the head)

    private func drawExtras(_ g: inout GraphicsContext, lw: CGFloat) {
        let e = pose.closed == .sleep ? CharacterExpression.sleepy : pose.expression
        switch e {
        case .sleepy:
            for (x, y, s) in [(0.86, 0.22, 0.07), (0.95, 0.1, 0.05)] as [(CGFloat, CGFloat, CGFloat)] {
                var z = Path()
                z.move(to: pt(x, y)); z.addLine(to: pt(x + s, y)); z.addLine(to: pt(x, y + s)); z.addLine(to: pt(x + s, y + s))
                g.stroke(z, with: .color(.white), style: StrokeStyle(lineWidth: lw * 1.8, lineCap: .round, lineJoin: .round))
                g.stroke(z, with: .color(pal.ink.opacity(0.75)), style: StrokeStyle(lineWidth: lw * 0.7, lineCap: .round, lineJoin: .round))
            }
        case .sad:
            let c = pt(eyeCenters.0.x - 0.05, eyeCenters.0.y + eyeSize.height / 2 + 0.035)
            var d = Path()
            d.move(to: pt(c.x, c.y - 0.035))
            d.addQuadCurve(to: pt(c.x + 0.022, c.y + 0.012), control: pt(c.x + 0.02, c.y - 0.01))
            d.addQuadCurve(to: pt(c.x - 0.022, c.y + 0.012), control: pt(c.x, c.y + 0.04))
            d.addQuadCurve(to: pt(c.x, c.y - 0.035), control: pt(c.x - 0.02, c.y - 0.01))
            g.fill(d, with: .color(Color(hex: 0x8FD3FF)))
            g.stroke(d, with: .color(pal.ink), lineWidth: lw * 0.8)
        case .loving:
            for (x, y, s) in [(0.87, 0.28, 0.1), (0.95, 0.14, 0.07)] as [(CGFloat, CGFloat, CGFloat)] {
                let h = heartPath(pt(x, y), s)
                g.fill(h, with: .color(pal.heart)); g.stroke(h, with: .color(pal.ink), lineWidth: lw * 0.8)
            }
        case .excited:
            for (x, y, s) in [(0.1, 0.3, 0.06), (0.9, 0.26, 0.07), (0.84, 0.1, 0.04)] as [(CGFloat, CGFloat, CGFloat)] {
                let sp = sparklePath(pt(x, y), s)
                g.fill(sp, with: .color(Color(hex: 0xF6C744))); g.stroke(sp, with: .color(pal.ink), lineWidth: lw * 0.7)
            }
        case .thinking:
            for (x, y, r) in [(0.84, 0.3, 0.018), (0.89, 0.21, 0.025), (0.95, 0.1, 0.035)] as [(CGFloat, CGFloat, CGFloat)] {
                let d = circlePath(x, y, r)
                g.fill(d, with: .color(.white)); g.stroke(d, with: .color(pal.ink), lineWidth: lw * 0.7)
            }
        case .surprised:
            var p = Path()
            for (a, b) in [((0.86, 0.26), (0.92, 0.2)), ((0.9, 0.32), (0.97, 0.3)), ((0.83, 0.2), (0.85, 0.12))] as [((CGFloat, CGFloat), (CGFloat, CGFloat))] {
                p.move(to: pt(a.0, a.1)); p.addLine(to: pt(b.0, b.1))
            }
            g.stroke(p, with: .color(pal.ink), style: StrokeStyle(lineWidth: lw * 1.2, lineCap: .round))
        default: break
        }
    }
}

private extension FigureRig.EyeLid {
    var isAngry: Bool { if case .angry = self { return true } else { return false } }
}
