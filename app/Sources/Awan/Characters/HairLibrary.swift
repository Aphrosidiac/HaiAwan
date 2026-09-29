import SwiftUI

/// Hairstyles (and headgear) for the figure rig, drawn in the head's unit square
/// (head ellipse ≈ x 0.14…0.86, y 0.25…0.87). `back` is drawn behind the head, `front` over it.
/// Indices 0–9 are the original Kawan styles and must never change; new styles are appended.
enum HairLibrary {
    struct Style { var back: [FigurePiece]; var front: [FigurePiece] }

    private static var cache: [Int: Style] = [:]
    private static let lock = NSLock()

    static func pieces(_ index: Int) -> Style {
        let i = CharacterCatalog.wrap(index, CharacterCatalog.hairstyleCount)
        lock.lock(); defer { lock.unlock() }
        if let s = cache[i] { return s }
        let s = build(i)
        cache[i] = s
        return s
    }

    // MARK: Shared shapes

    private static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    private static func legacyBack(_ s: Int) -> Path { KawanHairBack(style: s).path(in: unit) }
    private static func legacyFront(_ s: Int) -> Path { KawanHairFront(style: s).path(in: unit) }

    /// Rounded volume behind the head.
    private static var capBack: Path { ellipsePath(0.12, 0.12, 0.76, 0.6) }

    /// Soft fringe (the original default front).
    private static var softBangs: Path { legacyFront(0) }

    /// A dome over the top of the head down to a smooth hairline at `hairline` (y at the centre).
    private static func dome(top: CGFloat = 0.06, hairline: CGFloat = 0.3, edge: CGFloat = 0.44, inset: CGFloat = 0.15) -> Path {
        var p = Path()
        p.move(to: pt(inset, edge))
        // a quadratic's apex sits halfway between its ends and its control point
        p.addQuadCurve(to: pt(1 - inset, edge), control: pt(0.5, 2 * top - edge))
        p.addQuadCurve(to: pt(inset, edge), control: pt(0.5, 2 * hairline - edge))
        p.closeSubpath()
        return p
    }

    /// Slicked-back front with a smooth hairline.
    private static var slick: Path {
        var p = Path()
        p.move(to: pt(0.15, 0.44))
        p.addQuadCurve(to: pt(0.85, 0.44), control: pt(0.5, 0.04))
        p.addQuadCurve(to: pt(0.52, 0.32), control: pt(0.72, 0.3))
        p.addQuadCurve(to: pt(0.15, 0.44), control: pt(0.3, 0.3))
        p.closeSubpath()
        return p
    }

    /// Band across the forehead following the head's curve.
    private static func headband(y: CGFloat = 0.43, thickness: CGFloat = 0.065) -> Path {
        var p = Path()
        p.move(to: pt(0.145, y))
        p.addQuadCurve(to: pt(0.855, y), control: pt(0.5, y - 0.22))
        p.addLine(to: pt(0.86, y + thickness))
        p.addQuadCurve(to: pt(0.14, y + thickness), control: pt(0.5, y - 0.22 + thickness))
        p.closeSubpath()
        return p
    }

    private static func zigzag(_ pts: [(CGFloat, CGFloat)]) -> Path { polyPath(pts) }

    private static func hair(_ p: Path, _ ink: FigureInk = .hair, outlined: Bool = true, alpha: Double = 1) -> FigurePiece {
        FigurePiece(path: p, fill: ink, outlined: outlined, alpha: alpha)
    }
    private static func line(_ p: Path, _ ink: FigureInk = .shade, scale: CGFloat = 0.9) -> FigurePiece {
        FigurePiece(path: p, fill: nil, outlined: false, stroke: ink, strokeScale: scale)
    }

    // MARK: Styles

    private static func build(_ i: Int) -> Style {
        switch i {
        case 0...9:
            return Style(back: [hair(legacyBack(i))], front: [hair(legacyFront(i))])

        // ── Pahlawan ──────────────────────────────────────────────
        case 10: // Blaze — flames licking upward
            let flame = zigzag([(0.14, 0.46), (0.1, 0.24), (0.24, 0.3), (0.21, 0.06), (0.37, 0.2), (0.45, -0.04), (0.55, 0.16), (0.7, 0.0),
                                (0.72, 0.24), (0.9, 0.15), (0.86, 0.46), (0.74, 0.36), (0.62, 0.38), (0.53, 0.3), (0.44, 0.38), (0.3, 0.34)])
            let glint = zigzag([(0.33, 0.28), (0.38, 0.17), (0.43, 0.26)])
            return Style(back: [hair(capBack)], front: [hair(flame), hair(glint, .light, outlined: false)])
        case 11: // Ikat spikes — short spikes under a knotted headband
            let spikes = zigzag([(0.14, 0.44), (0.14, 0.26), (0.26, 0.22), (0.28, 0.08), (0.4, 0.16), (0.5, 0.03), (0.6, 0.16), (0.72, 0.08), (0.74, 0.22), (0.86, 0.26), (0.86, 0.44)])
            var t1 = Path()
            t1.move(to: pt(0.84, 0.43)); t1.addQuadCurve(to: pt(1.02, 0.52), control: pt(0.97, 0.4))
            t1.addLine(to: pt(0.97, 0.57)); t1.addQuadCurve(to: pt(0.84, 0.5), control: pt(0.92, 0.49)); t1.closeSubpath()
            var t2 = Path()
            t2.move(to: pt(0.84, 0.47)); t2.addQuadCurve(to: pt(0.95, 0.7), control: pt(0.96, 0.56))
            t2.addLine(to: pt(0.89, 0.69)); t2.addQuadCurve(to: pt(0.82, 0.51), control: pt(0.89, 0.58)); t2.closeSubpath()
            return Style(back: [hair(capBack)], front: [hair(spikes), hair(t2, .accentShade), hair(t1, .accent), hair(headband(), .accent), hair(circlePath(0.85, 0.47, 0.035), .accentShade)])
        case 12: // High tail — slicked up into a long ponytail
            var tail = Path()
            tail.move(to: pt(0.58, 0.12))
            tail.addCurve(to: pt(0.96, 0.62), control1: pt(0.86, -0.02), control2: pt(1.03, 0.24))
            tail.addCurve(to: pt(0.84, 0.62), control1: pt(0.93, 0.72), control2: pt(0.85, 0.72))
            tail.addCurve(to: pt(0.62, 0.22), control1: pt(0.9, 0.42), control2: pt(0.8, 0.26))
            tail.closeSubpath()
            let tie = Path(roundedRect: CGRect(x: 0.56, y: 0.08, width: 0.1, height: 0.07), cornerRadius: 0.02)
            return Style(back: [hair(tail), hair(capBack)], front: [hair(slick), hair(rotated(tie, 30, around: pt(0.61, 0.115)), .accent)])
        case 13: // Mohawk — shaved sides, tall crest
            let crest = zigzag([(0.38, 0.4), (0.35, 0.16), (0.42, 0.19), (0.43, -0.02), (0.5, 0.09), (0.57, -0.02), (0.58, 0.19), (0.65, 0.16), (0.62, 0.4), (0.5, 0.35)])
            return Style(back: [], front: [hair(dome(top: 0.25, hairline: 0.37, edge: 0.46), .shade, outlined: false, alpha: 0.3), hair(crest)])
        case 14: // Swoop — one big swept lock
            var p = Path()
            p.move(to: pt(0.14, 0.46))
            p.addQuadCurve(to: pt(0.5, 0.07), control: pt(0.14, 0.12))
            p.addQuadCurve(to: pt(0.88, 0.4), control: pt(0.86, 0.06))
            p.addLine(to: pt(0.86, 0.46))
            p.addQuadCurve(to: pt(0.64, 0.36), control: pt(0.76, 0.34))
            p.addQuadCurve(to: pt(0.38, 0.5), control: pt(0.56, 0.46))
            p.addQuadCurve(to: pt(0.46, 0.33), control: pt(0.46, 0.4))
            p.addQuadCurve(to: pt(0.14, 0.46), control: pt(0.26, 0.32))
            p.closeSubpath()
            var shine = Path()
            shine.move(to: pt(0.3, 0.2)); shine.addQuadCurve(to: pt(0.62, 0.14), control: pt(0.46, 0.12))
            return Style(back: [hair(capBack)], front: [hair(p), line(shine, .light, scale: 1.4)])
        case 15: // Wild — spiky everywhere
            var pts: [(CGFloat, CGFloat)] = []
            for k in 0..<18 {
                let a = CGFloat(k) / 18 * .pi * 2 - .pi / 2
                let r: CGFloat = k % 2 == 0 ? 0.47 : 0.36
                pts.append((0.5 + cos(a) * r, 0.46 + sin(a) * r * 0.86))
            }
            let front = zigzag([(0.14, 0.3), (0.3, 0.1), (0.5, 0.05), (0.7, 0.1), (0.86, 0.3), (0.85, 0.46), (0.8, 0.3), (0.72, 0.4), (0.67, 0.24),
                                (0.58, 0.36), (0.5, 0.22), (0.42, 0.36), (0.33, 0.24), (0.28, 0.4), (0.2, 0.3), (0.15, 0.46)])
            return Style(back: [hair(zigzag(pts))], front: [hair(front)])
        case 16: // Top knot with a band
            return Style(back: [hair(circlePath(0.5, 0.1, 0.11)), hair(capBack)],
                         front: [hair(slick), hair(Path(roundedRect: CGRect(x: 0.42, y: 0.17, width: 0.16, height: 0.05), cornerRadius: 0.02), .accent)])
        case 17: // Ribbon band — long tails trailing behind
            var t1 = Path()
            t1.move(to: pt(0.16, 0.42)); t1.addQuadCurve(to: pt(-0.02, 0.6), control: pt(0.02, 0.44))
            t1.addLine(to: pt(0.05, 0.64)); t1.addQuadCurve(to: pt(0.18, 0.48), control: pt(0.08, 0.52)); t1.closeSubpath()
            var t2 = Path()
            t2.move(to: pt(0.16, 0.45)); t2.addQuadCurve(to: pt(0.08, 0.78), control: pt(0.04, 0.6))
            t2.addLine(to: pt(0.15, 0.76)); t2.addQuadCurve(to: pt(0.2, 0.5), control: pt(0.13, 0.6)); t2.closeSubpath()
            let back = Path(roundedRect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.74), cornerRadius: 0.34)
            return Style(back: [hair(back)], front: [hair(softBangs), hair(t2, .accentShade), hair(t1, .accent), hair(headband(y: 0.4, thickness: 0.055), .accent)])
        case 18: // Buzz — close crop
            var p = Path()
            p.move(to: pt(0.15, 0.46))
            p.addQuadCurve(to: pt(0.5, 0.2), control: pt(0.13, 0.2))
            p.addQuadCurve(to: pt(0.85, 0.46), control: pt(0.87, 0.2))
            p.addQuadCurve(to: pt(0.5, 0.33), control: pt(0.8, 0.34))
            p.addQuadCurve(to: pt(0.15, 0.46), control: pt(0.2, 0.34))
            p.closeSubpath()
            var dots = Path()
            for (x, y) in [(0.3, 0.3), (0.42, 0.26), (0.56, 0.26), (0.68, 0.3), (0.36, 0.34), (0.62, 0.34), (0.5, 0.3)] as [(CGFloat, CGFloat)] {
                dots.move(to: pt(x, y)); dots.addLine(to: pt(x + 0.015, y - 0.012))
            }
            return Style(back: [], front: [hair(p), line(dots, .shade, scale: 0.8)])
        case 19: // Twin tails
            var l = Path()
            l.move(to: pt(0.2, 0.2))
            l.addCurve(to: pt(0.04, 0.68), control1: pt(0.0, 0.18), control2: pt(-0.05, 0.48))
            l.addCurve(to: pt(0.13, 0.6), control1: pt(0.08, 0.74), control2: pt(0.15, 0.68))
            l.addCurve(to: pt(0.25, 0.28), control1: pt(0.08, 0.44), control2: pt(0.14, 0.32))
            l.closeSubpath()
            let bangs = zigzag([(0.15, 0.44), (0.15, 0.3), (0.3, 0.12), (0.5, 0.08), (0.7, 0.12), (0.85, 0.3), (0.85, 0.44), (0.76, 0.34), (0.68, 0.42), (0.6, 0.32), (0.5, 0.4), (0.4, 0.32), (0.32, 0.42), (0.24, 0.34)])
            return Style(back: [hair(l), hair(mirrored(l)), hair(capBack)],
                         front: [hair(bangs), hair(circlePath(0.19, 0.23, 0.04), .accent), hair(circlePath(0.81, 0.23, 0.04), .accent)])

        // ── Arked ─────────────────────────────────────────────────
        case 20: // Visor cap
            var cap = Path()
            cap.move(to: pt(0.15, 0.42))
            cap.addQuadCurve(to: pt(0.5, 0.08), control: pt(0.14, 0.08))
            cap.addQuadCurve(to: pt(0.85, 0.42), control: pt(0.86, 0.08))
            cap.addQuadCurve(to: pt(0.15, 0.42), control: pt(0.5, 0.3))
            cap.closeSubpath()
            var visor = Path()
            visor.move(to: pt(0.46, 0.36))
            visor.addQuadCurve(to: pt(0.98, 0.38), control: pt(0.72, 0.28))
            visor.addQuadCurve(to: pt(0.92, 0.45), control: pt(1.0, 0.44))
            visor.addQuadCurve(to: pt(0.48, 0.43), control: pt(0.7, 0.4))
            visor.closeSubpath()
            var seam = Path(); seam.move(to: pt(0.5, 0.1)); seam.addQuadCurve(to: pt(0.46, 0.35), control: pt(0.44, 0.2))
            let tuft = zigzag([(0.15, 0.42), (0.17, 0.5), (0.22, 0.44), (0.27, 0.49), (0.3, 0.4)])
            return Style(back: [hair(ellipsePath(0.12, 0.2, 0.76, 0.5))],
                         front: [hair(tuft), hair(cap, .accent), line(seam, .accentShade, scale: 1), hair(visor, .accentShade), hair(circlePath(0.5, 0.085, 0.03), .accentShade)])
        case 21: // Racer helmet
            var dome = Path()
            dome.move(to: pt(0.13, 0.46))
            dome.addQuadCurve(to: pt(0.5, 0.1), control: pt(0.12, 0.1))
            dome.addQuadCurve(to: pt(0.87, 0.46), control: pt(0.88, 0.1))
            dome.addQuadCurve(to: pt(0.13, 0.46), control: pt(0.5, 0.3))
            dome.closeSubpath()
            let stripe = polyPath([(0.45, 0.11), (0.55, 0.11), (0.545, 0.33), (0.455, 0.33)])
            var visor = Path()
            visor.move(to: pt(0.17, 0.41)); visor.addQuadCurve(to: pt(0.83, 0.41), control: pt(0.5, 0.22))
            visor.addLine(to: pt(0.83, 0.46)); visor.addQuadCurve(to: pt(0.17, 0.46), control: pt(0.5, 0.29)); visor.closeSubpath()
            return Style(back: [hair(ellipsePath(0.07, 0.1, 0.86, 0.78), .accent)],
                         front: [hair(dome, .accent), hair(stripe, .white, outlined: false), hair(visor, .ink, outlined: true, alpha: 0.75)])
        case 22: // Antenna — bot dome with ear bolts
            var dome = Path()
            dome.move(to: pt(0.15, 0.42))
            dome.addQuadCurve(to: pt(0.5, 0.12), control: pt(0.15, 0.12))
            dome.addQuadCurve(to: pt(0.85, 0.42), control: pt(0.85, 0.12))
            dome.addQuadCurve(to: pt(0.15, 0.42), control: pt(0.5, 0.34))
            dome.closeSubpath()
            var ant = Path(); ant.move(to: pt(0.5, 0.13)); ant.addLine(to: pt(0.5, 0.02))
            var rivets = Path()
            for x in [0.3, 0.42, 0.58, 0.7] as [CGFloat] { rivets.addEllipse(in: CGRect(x: x - 0.012, y: 0.3 - 0.012 - (x == 0.42 || x == 0.58 ? 0.02 : 0), width: 0.024, height: 0.024)) }
            return Style(back: [hair(circlePath(0.13, 0.58, 0.055), .metal), hair(circlePath(0.87, 0.58, 0.055), .metal)],
                         front: [hair(dome, .metal), FigurePiece(path: rivets, fill: .metalShade, outlined: false),
                                 FigurePiece(path: ant, fill: nil, outlined: false, stroke: .ink, strokeScale: 1.3),
                                 hair(circlePath(0.5, 0.0, 0.045), .accent), hair(circlePath(0.11, 0.58, 0.022), .accent, outlined: false), hair(circlePath(0.89, 0.58, 0.022), .accent, outlined: false)])
        case 23: // Crown
            let crown = polyPath([(0.3, 0.25), (0.28, 0.06), (0.39, 0.15), (0.5, 0.0), (0.61, 0.15), (0.72, 0.06), (0.7, 0.25)])
            return Style(back: [hair(legacyBack(0))],
                         front: [hair(softBangs), hair(crown, .gold), hair(circlePath(0.5, 0.17, 0.028), .accent),
                                 hair(circlePath(0.28, 0.06, 0.018), .white), hair(circlePath(0.5, 0.0, 0.02), .white), hair(circlePath(0.72, 0.06, 0.018), .white)])
        case 24: // Goggles on a leather cap
            let strap = headband(y: 0.33, thickness: 0.05)
            return Style(back: [hair(capBack)],
                         front: [hair(dome(top: 0.06, hairline: 0.4, edge: 0.46)), hair(strap, .leather),
                                 hair(circlePath(0.37, 0.3, 0.085), .metal), hair(circlePath(0.63, 0.3, 0.085), .metal),
                                 hair(circlePath(0.37, 0.3, 0.058), .accent, alpha: 0.85), hair(circlePath(0.63, 0.3, 0.058), .accent, alpha: 0.85),
                                 line({ var p = Path(); p.addArc(center: pt(0.36, 0.29), radius: 0.035, startAngle: .degrees(200), endAngle: .degrees(260), clockwise: false); return p }(), .white, scale: 1.2),
                                 line({ var p = Path(); p.addArc(center: pt(0.62, 0.29), radius: 0.035, startAngle: .degrees(200), endAngle: .degrees(260), clockwise: false); return p }(), .white, scale: 1.2)])
        case 25: // Headphones over messy hair
            let messy = zigzag([(0.14, 0.3), (0.3, 0.1), (0.5, 0.06), (0.7, 0.1), (0.86, 0.3), (0.85, 0.45), (0.76, 0.34), (0.66, 0.42), (0.58, 0.3), (0.48, 0.4), (0.4, 0.3), (0.3, 0.42), (0.22, 0.34), (0.15, 0.45)])
            var band = Path()
            band.move(to: pt(0.1, 0.52))
            band.addQuadCurve(to: pt(0.9, 0.52), control: pt(0.5, -0.2))
            band.addLine(to: pt(0.84, 0.52))
            band.addQuadCurve(to: pt(0.16, 0.52), control: pt(0.5, -0.1))
            band.closeSubpath()
            let cupL = Path(roundedRect: CGRect(x: 0.04, y: 0.44, width: 0.13, height: 0.22), cornerRadius: 0.05)
            return Style(back: [hair(capBack)],
                         front: [hair(messy), hair(band, .ink), hair(cupL, .accent), hair(mirrored(cupL), .accent),
                                 hair(Path(roundedRect: CGRect(x: 0.06, y: 0.48, width: 0.05, height: 0.14), cornerRadius: 0.02), .accentShade, outlined: false),
                                 hair(mirrored(Path(roundedRect: CGRect(x: 0.06, y: 0.48, width: 0.05, height: 0.14), cornerRadius: 0.02)), .accentShade, outlined: false)])
        case 26: // Pixel quiff — stepped, blocky hair
            let back = polyPath([(0.12, 0.62), (0.12, 0.26), (0.18, 0.26), (0.18, 0.18), (0.26, 0.18), (0.26, 0.12), (0.74, 0.12), (0.74, 0.18), (0.82, 0.18), (0.82, 0.26), (0.88, 0.26), (0.88, 0.62)])
            let front = polyPath([(0.14, 0.46), (0.14, 0.3), (0.2, 0.3), (0.2, 0.22), (0.3, 0.22), (0.3, 0.08), (0.44, 0.08), (0.44, 0.0), (0.62, 0.0), (0.62, 0.08), (0.72, 0.08),
                                  (0.72, 0.2), (0.8, 0.2), (0.8, 0.3), (0.86, 0.3), (0.86, 0.46), (0.78, 0.46), (0.78, 0.38), (0.64, 0.38), (0.64, 0.3), (0.46, 0.3), (0.46, 0.38), (0.28, 0.38), (0.28, 0.46)])
            return Style(back: [hair(back)], front: [hair(front), hair(Path(CGRect(x: 0.48, y: 0.04, width: 0.06, height: 0.06)), .light, outlined: false),
                                                     hair(Path(CGRect(x: 0.34, y: 0.12, width: 0.06, height: 0.06)), .light, outlined: false)])
        case 27: // Bandana with a knot
            var cap = Path()
            cap.move(to: pt(0.14, 0.43))
            cap.addQuadCurve(to: pt(0.5, 0.1), control: pt(0.14, 0.1))
            cap.addQuadCurve(to: pt(0.86, 0.43), control: pt(0.86, 0.1))
            cap.addQuadCurve(to: pt(0.14, 0.43), control: pt(0.5, 0.31))
            cap.closeSubpath()
            let tail1 = polyPath([(0.15, 0.36), (0.0, 0.3), (0.04, 0.42)])
            let tail2 = polyPath([(0.15, 0.4), (0.02, 0.5), (0.1, 0.54)])
            var dots = Path()
            for (x, y) in [(0.34, 0.22), (0.5, 0.16), (0.66, 0.22), (0.42, 0.32), (0.6, 0.31), (0.26, 0.34), (0.75, 0.34)] as [(CGFloat, CGFloat)] {
                dots.addEllipse(in: CGRect(x: x - 0.016, y: y - 0.016, width: 0.032, height: 0.032))
            }
            return Style(back: [hair(ellipsePath(0.12, 0.26, 0.76, 0.5))],
                         front: [hair(tail2, .accentShade), hair(tail1, .accent), hair(cap, .accent), FigurePiece(path: dots, fill: .white, outlined: false, alpha: 0.9), hair(circlePath(0.155, 0.39, 0.035), .accentShade)])
        case 28: // Plume helm
            var helm = Path()
            helm.move(to: pt(0.12, 0.64))
            helm.addLine(to: pt(0.12, 0.4))
            helm.addQuadCurve(to: pt(0.5, 0.08), control: pt(0.12, 0.08))
            helm.addQuadCurve(to: pt(0.88, 0.4), control: pt(0.88, 0.08))
            helm.addLine(to: pt(0.88, 0.64))
            helm.addLine(to: pt(0.8, 0.64))
            helm.addLine(to: pt(0.8, 0.46))
            helm.addQuadCurve(to: pt(0.2, 0.46), control: pt(0.5, 0.32))
            helm.addLine(to: pt(0.2, 0.64))
            helm.closeSubpath()
            var plume = Path()
            plume.move(to: pt(0.4, 0.13))
            plume.addCurve(to: pt(0.95, 0.3), control1: pt(0.48, -0.04), control2: pt(0.88, 0.0))
            plume.addCurve(to: pt(0.52, 0.15), control1: pt(0.82, 0.14), control2: pt(0.64, 0.1))
            plume.closeSubpath()
            var ridge = Path(); ridge.move(to: pt(0.5, 0.09)); ridge.addLine(to: pt(0.5, 0.38))
            return Style(back: [], front: [hair(plume, .accent), hair(helm, .metal), line(ridge, .metalShade, scale: 1.2),
                                           hair(circlePath(0.16, 0.5, 0.014), .metalShade, outlined: false), hair(circlePath(0.84, 0.5, 0.014), .metalShade, outlined: false)])
        case 29: // Beanie with pompom
            var hat = Path()
            hat.move(to: pt(0.14, 0.4))
            hat.addQuadCurve(to: pt(0.5, 0.07), control: pt(0.14, 0.07))
            hat.addQuadCurve(to: pt(0.86, 0.4), control: pt(0.86, 0.07))
            hat.closeSubpath()
            var fold = Path()
            fold.move(to: pt(0.13, 0.33)); fold.addQuadCurve(to: pt(0.87, 0.33), control: pt(0.5, 0.26))
            fold.addLine(to: pt(0.87, 0.43)); fold.addQuadCurve(to: pt(0.13, 0.43), control: pt(0.5, 0.36)); fold.closeSubpath()
            var ribs = Path()
            for x in stride(from: 0.2, through: 0.8, by: 0.075) as StrideThrough<CGFloat> { ribs.move(to: pt(x, 0.345)); ribs.addLine(to: pt(x, 0.42)) }
            let tufts = zigzag([(0.14, 0.42), (0.16, 0.52), (0.21, 0.45), (0.25, 0.5), (0.27, 0.42)])
            return Style(back: [hair(ellipsePath(0.12, 0.2, 0.76, 0.52))],
                         front: [hair(tufts), hair(mirrored(tufts)), hair(hat, .accent), hair(fold, .accentShade), line(ribs, .accent, scale: 0.8), hair(circlePath(0.5, 0.06, 0.07), .white)])

        // ── Hikayat ───────────────────────────────────────────────
        case 30: // Leaf crown
            var leaves: [FigurePiece] = []
            for deg in [-64, -32, 0, 32, 64] as [CGFloat] {
                let a = (deg - 90) * .pi / 180
                let base = pt(0.5 + cos(a) * 0.2, 0.36 + sin(a) * 0.2)
                let tip = pt(0.5 + cos(a) * 0.36, 0.36 + sin(a) * 0.36)
                leaves.append(hair(leafPath(from: base, to: tip, width: 0.36), .accent))
                var vein = Path(); vein.move(to: base); vein.addLine(to: pt((base.x + tip.x) / 2, (base.y + tip.y) / 2))
                leaves.append(line(vein, .accentShade, scale: 0.8))
            }
            return Style(back: [hair(capBack)], front: leaves + [hair(softBangs)])
        case 31: // Petal hood
            var petals: [FigurePiece] = []
            for k in 0..<8 {
                let deg = CGFloat(k) * 45
                petals.append(hair(rotated(ellipsePath(0.37, -0.02, 0.26, 0.36), deg, around: pt(0.5, 0.55))))
            }
            var rim = Path()
            rim.move(to: pt(0.13, 0.5))
            rim.addQuadCurve(to: pt(0.5, 0.12), control: pt(0.12, 0.12))
            rim.addQuadCurve(to: pt(0.87, 0.5), control: pt(0.88, 0.12))
            rim.addQuadCurve(to: pt(0.5, 0.3), control: pt(0.8, 0.3))
            rim.addQuadCurve(to: pt(0.13, 0.5), control: pt(0.2, 0.3))
            rim.closeSubpath()
            return Style(back: petals, front: [hair(rim, .light), hair(circlePath(0.5, 0.17, 0.04), .accent)])
        case 32: // Moon hood
            var hood = Path()
            hood.move(to: pt(0.06, 0.86))
            hood.addQuadCurve(to: pt(0.5, 0.06), control: pt(0.0, 0.14))
            hood.addQuadCurve(to: pt(0.94, 0.86), control: pt(1.0, 0.14))
            hood.closeSubpath()
            var tip = Path()
            tip.move(to: pt(0.46, 0.07)); tip.addQuadCurve(to: pt(0.84, 0.0), control: pt(0.66, -0.08))
            tip.addQuadCurve(to: pt(0.64, 0.14), control: pt(0.72, 0.04)); tip.closeSubpath()
            var rim = Path()
            rim.move(to: pt(0.11, 0.66))
            rim.addQuadCurve(to: pt(0.5, 0.18), control: pt(0.09, 0.18))
            rim.addQuadCurve(to: pt(0.89, 0.66), control: pt(0.91, 0.18))
            rim.addLine(to: pt(0.85, 0.66))
            rim.addQuadCurve(to: pt(0.5, 0.29), control: pt(0.85, 0.29))
            rim.addQuadCurve(to: pt(0.15, 0.66), control: pt(0.15, 0.29))
            rim.closeSubpath()
            var moon = Path()
            moon.addArc(center: pt(0.5, 0.235), radius: 0.055, startAngle: .degrees(-60), endAngle: .degrees(60), clockwise: true)
            moon.addQuadCurve(to: pt(0.5 + 0.055 * cos(-.pi / 3), 0.235 + 0.055 * sin(-.pi / 3)), control: pt(0.47, 0.235))
            moon.closeSubpath()
            return Style(back: [hair(tip), hair(hood)], front: [hair(rim, .shade), hair(moon, .gold)])
        case 33: // Lantern flame tuft
            var flame = Path()
            flame.move(to: pt(0.5, -0.04))
            flame.addCurve(to: pt(0.59, 0.21), control1: pt(0.6, 0.06), control2: pt(0.66, 0.14))
            flame.addQuadCurve(to: pt(0.41, 0.21), control: pt(0.5, 0.27))
            flame.addCurve(to: pt(0.5, -0.04), control1: pt(0.34, 0.14), control2: pt(0.42, 0.06))
            flame.closeSubpath()
            var inner = Path()
            inner.move(to: pt(0.5, 0.08)); inner.addQuadCurve(to: pt(0.5, 0.22), control: pt(0.58, 0.17)); inner.addQuadCurve(to: pt(0.5, 0.08), control: pt(0.42, 0.17)); inner.closeSubpath()
            var fp = FigurePiece(path: flame, fill: .accent); fp.glow = true
            return Style(back: [hair(capBack)], front: [hair(softBangs), fp, hair(inner, .white, outlined: false, alpha: 0.85)])
        case 34: // Mushroom cap
            var cap = Path()
            cap.move(to: pt(0.02, 0.4))
            cap.addQuadCurve(to: pt(0.5, 0.02), control: pt(0.0, 0.02))
            cap.addQuadCurve(to: pt(0.98, 0.4), control: pt(1.0, 0.02))
            cap.addQuadCurve(to: pt(0.02, 0.4), control: pt(0.5, 0.3))
            cap.closeSubpath()
            var spots = Path()
            for (x, y, r) in [(0.3, 0.16, 0.06), (0.62, 0.1, 0.05), (0.8, 0.26, 0.04), (0.15, 0.3, 0.03), (0.49, 0.25, 0.035)] as [(CGFloat, CGFloat, CGFloat)] {
                spots.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            return Style(back: [hair(ellipsePath(0.14, 0.26, 0.72, 0.44))], front: [hair(cap, .accent), FigurePiece(path: spots, fill: .white, outlined: false, alpha: 0.95)])
        case 35: // Bunny hood
            let ear = rotated(ellipsePath(0.24, -0.14, 0.17, 0.42), -12, around: pt(0.32, 0.2))
            let earIn = rotated(ellipsePath(0.28, -0.08, 0.09, 0.3), -12, around: pt(0.32, 0.2))
            var rim = Path()
            rim.move(to: pt(0.12, 0.62))
            rim.addQuadCurve(to: pt(0.5, 0.16), control: pt(0.1, 0.16))
            rim.addQuadCurve(to: pt(0.88, 0.62), control: pt(0.9, 0.16))
            rim.addLine(to: pt(0.84, 0.62))
            rim.addQuadCurve(to: pt(0.5, 0.28), control: pt(0.84, 0.28))
            rim.addQuadCurve(to: pt(0.16, 0.62), control: pt(0.16, 0.28))
            rim.closeSubpath()
            return Style(back: [hair(ear), hair(earIn, .inner, outlined: false), hair(mirrored(ear)), hair(mirrored(earIn), .inner, outlined: false), hair(ellipsePath(0.07, 0.12, 0.86, 0.8))],
                         front: [hair(rim, .light)])
        case 36: // Fox ears
            let ear = polyPath([(0.17, 0.38), (0.19, 0.02), (0.43, 0.22)])
            let earIn = polyPath([(0.22, 0.31), (0.225, 0.1), (0.36, 0.22)])
            return Style(back: [hair(capBack)],
                         front: [hair(ear), hair(earIn, .inner, outlined: false), hair(mirrored(ear)), hair(mirrored(earIn), .inner, outlined: false), hair(legacyFront(6))])
        case 37: // Vine braids
            var back: [FigurePiece] = [hair(capBack)]
            for k in 0..<5 {
                let y = 0.5 + CGFloat(k) * 0.09
                back.append(hair(ellipsePath(0.12 - CGFloat(k) * 0.006, y, 0.11, 0.11)))
                back.append(hair(mirrored(ellipsePath(0.12 - CGFloat(k) * 0.006, y, 0.11, 0.11))))
            }
            back.append(hair(leafPath(from: pt(0.16, 0.94), to: pt(0.06, 1.02)), .accent))
            back.append(hair(mirrored(leafPath(from: pt(0.16, 0.94), to: pt(0.06, 1.02))), .accent))
            var bangs = Path()
            bangs.move(to: pt(0.15, 0.44))
            bangs.addQuadCurve(to: pt(0.5, 0.12), control: pt(0.16, 0.12))
            bangs.addQuadCurve(to: pt(0.85, 0.44), control: pt(0.84, 0.12))
            bangs.addQuadCurve(to: pt(0.52, 0.22), control: pt(0.72, 0.26))
            bangs.addLine(to: pt(0.48, 0.22))
            bangs.addQuadCurve(to: pt(0.15, 0.44), control: pt(0.28, 0.26))
            bangs.closeSubpath()
            return Style(back: back, front: [hair(bangs), hair(leafPath(from: pt(0.26, 0.26), to: pt(0.16, 0.16)), .accent)])
        case 38: // Star clip bob
            return Style(back: [hair(legacyBack(0))], front: [hair(softBangs), hair(starPath(pt(0.74, 0.3), 0.075), .accent)])
        case 39: // Story hat
            let brim = ellipsePath(-0.04, 0.24, 1.08, 0.16)
            var cone = Path()
            cone.move(to: pt(0.24, 0.31))
            cone.addLine(to: pt(0.44, -0.06))
            cone.addQuadCurve(to: pt(0.64, -0.1), control: pt(0.52, -0.16))
            cone.addQuadCurve(to: pt(0.56, -0.02), control: pt(0.58, -0.08))
            cone.addLine(to: pt(0.76, 0.31))
            cone.closeSubpath()
            var band = Path()
            band.move(to: pt(0.27, 0.25)); band.addLine(to: pt(0.73, 0.25)); band.addLine(to: pt(0.755, 0.31)); band.addLine(to: pt(0.245, 0.31)); band.closeSubpath()
            return Style(back: [hair(capBack)], front: [hair(softBangs), hair(brim, .shade), hair(cone, .shade), hair(band, .accent), hair(starPath(pt(0.5, 0.28), 0.03), .white, outlined: false)])

        // ── Gebu ──────────────────────────────────────────────────
        case 40: // Sprout
            var stem = Path(); stem.move(to: pt(0.5, 0.27)); stem.addQuadCurve(to: pt(0.5, 0.12), control: pt(0.47, 0.2))
            return Style(back: [], front: [FigurePiece(path: stem, fill: nil, outlined: false, stroke: .shade, strokeScale: 1.6),
                                           hair(leafPath(from: pt(0.5, 0.13), to: pt(0.32, 0.05), width: 0.42)),
                                           hair(leafPath(from: pt(0.5, 0.13), to: pt(0.7, 0.02), width: 0.42))])
        case 41: // Swirl
            var drop = Path()
            drop.move(to: pt(0.4, 0.28))
            drop.addQuadCurve(to: pt(0.52, 0.08), control: pt(0.36, 0.1))
            drop.addQuadCurve(to: pt(0.62, 0.22), control: pt(0.66, 0.1))
            drop.addQuadCurve(to: pt(0.56, 0.28), control: pt(0.6, 0.27))
            drop.closeSubpath()
            var curl = Path()
            curl.addArc(center: pt(0.52, 0.18), radius: 0.045, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: false)
            curl.addArc(center: pt(0.525, 0.19), radius: 0.02, startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: false)
            return Style(back: [], front: [hair(drop), line(curl, .shade, scale: 1.1)])
        case 42: // Tuft trio
            return Style(back: [hair(circlePath(0.38, 0.24, 0.06)), hair(circlePath(0.62, 0.24, 0.06)), hair(circlePath(0.5, 0.18, 0.075))], front: [])
        case 43: // Bean
            let bean = rotated(ellipsePath(0.44, 0.08, 0.14, 0.22), 28, around: pt(0.51, 0.19))
            return Style(back: [hair(bean)], front: [hair(rotated(ellipsePath(0.47, 0.11, 0.035, 0.08), 28, around: pt(0.51, 0.19)), .light, outlined: false)])
        case 44: // Cat ears
            let ear = polyPath([(0.16, 0.44), (0.2, 0.1), (0.42, 0.28)])
            let earIn = polyPath([(0.21, 0.36), (0.225, 0.17), (0.35, 0.28)])
            return Style(back: [hair(ear), hair(earIn, .inner, outlined: false), hair(mirrored(ear)), hair(mirrored(earIn), .inner, outlined: false)], front: [])
        case 45: // Bear ears
            return Style(back: [hair(circlePath(0.25, 0.28, 0.095)), hair(circlePath(0.25, 0.28, 0.05), .inner, outlined: false),
                                hair(circlePath(0.75, 0.28, 0.095)), hair(circlePath(0.75, 0.28, 0.05), .inner, outlined: false)], front: [])
        case 46: // Drop
            var d = Path()
            d.move(to: pt(0.5, 0.03))
            d.addQuadCurve(to: pt(0.585, 0.21), control: pt(0.585, 0.13))
            d.addQuadCurve(to: pt(0.415, 0.21), control: pt(0.5, 0.31))
            d.addQuadCurve(to: pt(0.5, 0.03), control: pt(0.415, 0.13))
            d.closeSubpath()
            return Style(back: [hair(d)], front: [hair(ellipsePath(0.455, 0.14, 0.03, 0.06), .light, outlined: false)])
        case 47: // Cloudlet
            var c = Path()
            for (x, y, r) in [(0.4, 0.2, 0.06), (0.5, 0.15, 0.075), (0.6, 0.2, 0.06), (0.5, 0.23, 0.07)] as [(CGFloat, CGFloat, CGFloat)] {
                c.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            return Style(back: [FigurePiece(path: c, fill: .hair, outlined: true)], front: [hair(ellipsePath(0.44, 0.1, 0.05, 0.03), .light, outlined: false)])
        case 48: // Nubs
            var nub = Path()
            nub.move(to: pt(0.28, 0.34))
            nub.addQuadCurve(to: pt(0.33, 0.14), control: pt(0.26, 0.2))
            nub.addQuadCurve(to: pt(0.4, 0.3), control: pt(0.4, 0.18))
            nub.closeSubpath()
            return Style(back: [hair(nub), hair(mirrored(nub))], front: [])
        default: // 49 Shine — no hair, just a glint
            var g = Path(); g.move(to: pt(0.3, 0.36)); g.addQuadCurve(to: pt(0.44, 0.285), control: pt(0.34, 0.3))
            return Style(back: [], front: [FigurePiece(path: g, fill: nil, outlined: false, alpha: 0.7, stroke: .white, strokeScale: 1.6)])
        }
    }
}

// MARK: - The original ten Kawan styles (geometry kept verbatim so saved looks render unchanged)

/// Hair drawn behind the head (volume) — ten styles.
struct KawanHairBack: Shape {
    var style: Int
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height)
        let o = CGPoint(x: r.midX - s / 2, y: r.midY - s / 2)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        var p = Path()
        switch style {
        case 0: p.addEllipse(in: CGRect(origin: pt(0.08, 0.10), size: CGSize(width: s * 0.84, height: s * 0.74)))                  // bob
        case 1: p.addEllipse(in: CGRect(origin: pt(0.14, 0.14), size: CGSize(width: s * 0.72, height: s * 0.58)))
                p.addEllipse(in: CGRect(origin: pt(0.36, 0.0), size: CGSize(width: s * 0.28, height: s * 0.24)))                      // top bun
        case 2: p.addEllipse(in: CGRect(origin: pt(0.12, 0.12), size: CGSize(width: s * 0.76, height: s * 0.6)))                     // spikes (front carries it)
        case 3: p.addEllipse(in: CGRect(origin: pt(0.14, 0.14), size: CGSize(width: s * 0.72, height: s * 0.58)))
                p.addEllipse(in: CGRect(origin: pt(0.02, 0.10), size: CGSize(width: s * 0.26, height: s * 0.26)))
                p.addEllipse(in: CGRect(origin: pt(0.72, 0.10), size: CGSize(width: s * 0.26, height: s * 0.26)))                      // twin buns
        case 4: p.addRoundedRect(in: CGRect(origin: pt(0.1, 0.1), size: CGSize(width: s * 0.8, height: s * 0.86)), cornerSize: CGSize(width: s * 0.36, height: s * 0.36)) // long
        case 5: for (x, y) in [(0.14, 0.2), (0.3, 0.08), (0.5, 0.05), (0.68, 0.1), (0.8, 0.24), (0.12, 0.42), (0.8, 0.44)] {
                    p.addEllipse(in: CGRect(origin: pt(CGFloat(x) - 0.08, CGFloat(y)), size: CGSize(width: s * 0.26, height: s * 0.26)))
                }                                                                                                                       // curls
        case 6: p.addEllipse(in: CGRect(origin: pt(0.12, 0.12), size: CGSize(width: s * 0.76, height: s * 0.6)))
                p.addEllipse(in: CGRect(origin: pt(0.74, 0.3), size: CGSize(width: s * 0.2, height: s * 0.46)))                       // side tail
        case 7: p.addEllipse(in: CGRect(origin: pt(0.1, 0.1), size: CGSize(width: s * 0.8, height: s * 0.66)))                       // fringe
        case 8: p.addEllipse(in: CGRect(origin: pt(0.12, 0.12), size: CGSize(width: s * 0.76, height: s * 0.6)))
                p.addRoundedRect(in: CGRect(origin: pt(0.12, 0.45), size: CGSize(width: s * 0.12, height: s * 0.5)), cornerSize: CGSize(width: s * 0.06, height: s * 0.06))
                p.addRoundedRect(in: CGRect(origin: pt(0.76, 0.45), size: CGSize(width: s * 0.12, height: s * 0.5)), cornerSize: CGSize(width: s * 0.06, height: s * 0.06)) // braids
        default: for i in 0..<9 {
                    let a = Double(i) / 9 * .pi * 2
                    p.addEllipse(in: CGRect(origin: pt(0.36 + 0.3 * CGFloat(cos(a)), 0.3 + 0.24 * CGFloat(sin(a))), size: CGSize(width: s * 0.3, height: s * 0.3)))
                }                                                                                                                        // puff
        }
        return p
    }
}

/// Hair drawn over the forehead — the fringe that defines each style.
struct KawanHairFront: Shape {
    var style: Int
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height)
        let o = CGPoint(x: r.midX - s / 2, y: r.midY - s / 2)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        var p = Path()
        switch style {
        case 2: // spikes
            p.move(to: pt(0.14, 0.42))
            for (i, x) in stride(from: 0.2, through: 0.86, by: 0.11).enumerated() {
                p.addLine(to: pt(CGFloat(x), i % 2 == 0 ? 0.04 : 0.26))
            }
            p.addLine(to: pt(0.86, 0.42)); p.addQuadCurve(to: pt(0.14, 0.42), control: pt(0.5, 0.22))
        case 7: // heavy fringe
            p.move(to: pt(0.13, 0.46)); p.addQuadCurve(to: pt(0.87, 0.46), control: pt(0.5, 0.0))
            p.addQuadCurve(to: pt(0.13, 0.46), control: pt(0.5, 0.36))
        case 6: // swept
            p.move(to: pt(0.14, 0.44)); p.addQuadCurve(to: pt(0.86, 0.36), control: pt(0.4, 0.02))
            p.addQuadCurve(to: pt(0.14, 0.44), control: pt(0.52, 0.34))
        default:
            p.move(to: pt(0.15, 0.42)); p.addQuadCurve(to: pt(0.85, 0.42), control: pt(0.5, 0.06))
            p.addQuadCurve(to: pt(0.62, 0.34), control: pt(0.76, 0.3))
            p.addQuadCurve(to: pt(0.4, 0.36), control: pt(0.5, 0.28))
            p.addQuadCurve(to: pt(0.15, 0.42), control: pt(0.24, 0.32))
        }
        return p
    }
}
