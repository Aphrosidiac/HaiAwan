import SwiftUI

/// Outfits for the figure rig: a shoulders-and-chest strip under the head, drawn in the bust's unit
/// square (shoulders ≈ y 0.745, strip runs off the bottom edge). Indices are stored — append only.
enum OutfitLibrary {
    private static var cache: [String: [FigurePiece]] = [:]
    private static let lock = NSLock()

    static func pieces(_ index: Int, detailed: Bool = true) -> [FigurePiece] {
        let i = CharacterCatalog.wrap(index, CharacterCatalog.outfitCount)
        let key = "\(i)-\(detailed)"
        lock.lock(); defer { lock.unlock() }
        if let p = cache[key] { return p }
        let p = build(i, detailed: detailed)
        cache[key] = p
        return p
    }

    // MARK: Shared shapes

    /// Rounded shoulders and chest.
    static var torso: Path {
        var p = Path()
        p.move(to: pt(0.14, 1.06))
        p.addLine(to: pt(0.155, 0.9))
        p.addCurve(to: pt(0.36, 0.745), control1: pt(0.16, 0.8), control2: pt(0.24, 0.755))
        p.addLine(to: pt(0.64, 0.745))
        p.addCurve(to: pt(0.845, 0.9), control1: pt(0.76, 0.755), control2: pt(0.84, 0.8))
        p.addLine(to: pt(0.86, 1.06))
        p.closeSubpath()
        return p
    }

    /// Skin showing at a round neckline.
    private static func crewNeck(depth: CGFloat = 0.05, width: CGFloat = 0.085) -> Path {
        var p = Path()
        p.move(to: pt(0.5 - width, 0.745))
        p.addQuadCurve(to: pt(0.5 + width, 0.745), control: pt(0.5, 0.745 + depth * 2))
        p.closeSubpath()
        return p
    }

    private static func vNeck(depth: CGFloat = 0.9, width: CGFloat = 0.085) -> Path {
        polyPath([(0.5 - width, 0.745), (0.5, depth), (0.5 + width, 0.745)])
    }

    /// Arm seams at the shoulders.
    private static var seams: Path {
        var p = Path()
        p.move(to: pt(0.255, 0.79)); p.addQuadCurve(to: pt(0.27, 1.02), control: pt(0.29, 0.9))
        p.move(to: pt(0.745, 0.79)); p.addQuadCurve(to: pt(0.73, 1.02), control: pt(0.71, 0.9))
        return p
    }

    /// Skin showing through a neckline is never outlined (the collar line gives it its edge).
    private static func fill(_ p: Path, _ ink: FigureInk, outlined: Bool? = nil, alpha: Double = 1) -> FigurePiece {
        FigurePiece(path: p, fill: ink, outlined: outlined ?? (ink != .skin), alpha: alpha)
    }
    private static func line(_ p: Path, _ ink: FigureInk = .outfitShade, scale: CGFloat = 0.9) -> FigurePiece {
        FigurePiece(path: p, fill: nil, outlined: false, stroke: ink, strokeScale: scale)
    }
    private static func base(_ ink: FigureInk = .outfit) -> FigurePiece { fill(torso, ink) }

    // MARK: Styles

    private static func build(_ i: Int, detailed d: Bool) -> [FigurePiece] {
        switch i {
        case 0: // Tee
            return [base(), fill(crewNeck(), .skin), line(crewNeck(depth: 0.06, width: 0.095), .outfitShade, scale: 1.4)]
                + (d ? [line(seams), fill(starPath(pt(0.62, 0.88), 0.03), .accent)] : [])
        case 1: // Hoodie
            var hood = Path()
            hood.move(to: pt(0.33, 0.752))
            hood.addQuadCurve(to: pt(0.67, 0.752), control: pt(0.5, 0.7))
            hood.addQuadCurve(to: pt(0.5, 0.86), control: pt(0.66, 0.85))
            hood.addQuadCurve(to: pt(0.33, 0.752), control: pt(0.34, 0.85))
            hood.closeSubpath()
            var strings = Path()
            strings.move(to: pt(0.46, 0.84)); strings.addLine(to: pt(0.45, 0.95))
            strings.move(to: pt(0.54, 0.84)); strings.addLine(to: pt(0.55, 0.95))
            var pocket = Path(); pocket.move(to: pt(0.33, 1.0)); pocket.addQuadCurve(to: pt(0.67, 1.0), control: pt(0.5, 0.94))
            return [base(), fill(hood, .outfitShade), fill(crewNeck(depth: 0.04, width: 0.07), .skin), line(strings, .accent, scale: 1.3),
                    fill(circlePath(0.45, 0.955, 0.012), .accent, outlined: false), fill(circlePath(0.55, 0.955, 0.012), .accent, outlined: false)]
                + (d ? [line(pocket), line(seams)] : [])
        case 2: // Pinafore over a shirt
            let bib = Path(roundedRect: CGRect(x: 0.34, y: 0.82, width: 0.32, height: 0.3), cornerRadius: 0.04)
            var straps = Path()
            straps.move(to: pt(0.36, 0.83)); straps.addLine(to: pt(0.32, 0.755))
            straps.move(to: pt(0.64, 0.83)); straps.addLine(to: pt(0.68, 0.755))
            let skirt = polyPath([(0.2, 1.06), (0.3, 0.93), (0.7, 0.93), (0.8, 1.06)])
            return [base(.accent), fill(crewNeck(), .skin), line(crewNeck(depth: 0.06, width: 0.095), .accentShade, scale: 1.3),
                    fill(skirt, .outfit), fill(bib, .outfit), FigurePiece(path: straps, fill: nil, outlined: false, stroke: .outfit, strokeScale: 2.6),
                    fill(heartPath(pt(0.5, 0.88), 0.05), .accent)]
        case 3: // Overalls
            let bib = Path(roundedRect: CGRect(x: 0.35, y: 0.82, width: 0.3, height: 0.3), cornerRadius: 0.03)
            var straps = Path()
            straps.move(to: pt(0.38, 0.83)); straps.addLine(to: pt(0.33, 0.755))
            straps.move(to: pt(0.62, 0.83)); straps.addLine(to: pt(0.67, 0.755))
            let pocket = Path(roundedRect: CGRect(x: 0.43, y: 0.88, width: 0.14, height: 0.09), cornerRadius: 0.015)
            return [base(.accent), fill(crewNeck(), .skin), line(crewNeck(depth: 0.06, width: 0.095), .accentShade, scale: 1.3),
                    fill(bib, .outfit), FigurePiece(path: straps, fill: nil, outlined: false, stroke: .outfit, strokeScale: 2.8),
                    fill(circlePath(0.385, 0.84, 0.018), .gold), fill(circlePath(0.615, 0.84, 0.018), .gold)]
                + (d ? [fill(pocket, .outfitShade)] : [])
        case 4: // Jacket over a shirt
            let shirt = vNeck(depth: 1.06, width: 0.12)
            let lapL = polyPath([(0.37, 0.75), (0.46, 0.93), (0.4, 0.85), (0.33, 0.82)])
            var zipper = Path(); zipper.move(to: pt(0.46, 0.93)); zipper.addLine(to: pt(0.44, 1.06))
            return [base(), fill(shirt, .accent), fill(crewNeck(depth: 0.035, width: 0.07), .skin), fill(lapL, .outfitShade), fill(mirrored(lapL), .outfitShade)]
                + (d ? [line(zipper), line(mirrored(zipper)), line(seams)] : [])
        case 5: // Gi — wrapped collar
            let skinV = vNeck(depth: 0.88, width: 0.09)
            let bandL = polyPath([(0.38, 0.748), (0.44, 0.748), (0.62, 1.06), (0.55, 1.06)])
            let bandR = polyPath([(0.56, 0.748), (0.62, 0.748), (0.47, 0.95), (0.43, 0.9)])
            return [base(), fill(skinV, .skin), fill(bandR, .outfitShade), fill(bandL, .outfitShade)]
                + (d ? [fill(circlePath(0.3, 0.87, 0.035), .accent), line(seams)] : [])
        case 6: // Armour — pauldrons and a chest plate
            let plate = Path(roundedRect: CGRect(x: 0.34, y: 0.8, width: 0.32, height: 0.3), cornerRadius: 0.06)
            var padL = Path()
            padL.move(to: pt(0.13, 0.9)); padL.addQuadCurve(to: pt(0.36, 0.76), control: pt(0.14, 0.74))
            padL.addQuadCurve(to: pt(0.13, 0.9), control: pt(0.3, 0.9)); padL.closeSubpath()
            var ridge = Path(); ridge.move(to: pt(0.5, 0.82)); ridge.addLine(to: pt(0.5, 1.06))
            return [base(.outfitShade), fill(crewNeck(depth: 0.035, width: 0.07), .skin), fill(plate, .outfit), fill(padL, .accent), fill(mirrored(padL), .accent),
                    fill(starPath(pt(0.5, 0.88), 0.035, points: 4, inner: 0.45), .accent)]
                + (d ? [line(ridge, .outfitShade, scale: 1.1)] : [])
        case 7: // Track top
            let collar = Path(roundedRect: CGRect(x: 0.4, y: 0.725, width: 0.2, height: 0.06), cornerRadius: 0.02)
            var zip = Path(); zip.move(to: pt(0.5, 0.785)); zip.addLine(to: pt(0.5, 1.06))
            var stripes = Path()
            stripes.move(to: pt(0.34, 0.756)); stripes.addCurve(to: pt(0.17, 1.02), control1: pt(0.22, 0.78), control2: pt(0.18, 0.88))
            stripes.move(to: pt(0.66, 0.756)); stripes.addCurve(to: pt(0.83, 1.02), control1: pt(0.78, 0.78), control2: pt(0.82, 0.88))
            return [base(), FigurePiece(path: stripes, fill: nil, outlined: false, stroke: .accent, strokeScale: 2.4), fill(collar, .outfitShade)]
                + (d ? [line(zip, .outfitShade, scale: 1.2), fill(Path(roundedRect: CGRect(x: 0.487, y: 0.8, width: 0.026, height: 0.05), cornerRadius: 0.008), .accent)] : [])
        case 8: // Sash robe
            let sash = polyPath([(0.26, 0.77), (0.35, 0.755), (0.78, 1.06), (0.66, 1.06)])
            return [base(), fill(vNeck(depth: 0.86, width: 0.08), .skin), line(vNeck(depth: 0.87, width: 0.09), .outfitShade, scale: 1.3), fill(sash, .accent)]
                + (d ? [line(seams)] : [])
        case 9: // Flight suit
            let collarL = polyPath([(0.4, 0.748), (0.5, 0.8), (0.42, 0.84), (0.34, 0.76)])
            let pocket = Path(roundedRect: CGRect(x: 0.28, y: 0.86, width: 0.12, height: 0.1), cornerRadius: 0.015)
            var zip = Path(); zip.move(to: pt(0.5, 0.8)); zip.addLine(to: pt(0.5, 1.06))
            return [base(), fill(crewNeck(depth: 0.03, width: 0.07), .skin), fill(collarL, .outfitShade), fill(mirrored(collarL), .outfitShade),
                    fill(circlePath(0.65, 0.9, 0.045), .accent), fill(starPath(pt(0.65, 0.9), 0.025), .white, outlined: false)]
                + (d ? [line(zip), fill(pocket, .outfitShade)] : [])
        case 10: // Explorer — scarf and a strap
            var scarf = Path()
            scarf.move(to: pt(0.35, 0.745)); scarf.addQuadCurve(to: pt(0.65, 0.745), control: pt(0.5, 0.82))
            scarf.addLine(to: pt(0.64, 0.8)); scarf.addQuadCurve(to: pt(0.36, 0.8), control: pt(0.5, 0.87)); scarf.closeSubpath()
            let tail = polyPath([(0.54, 0.82), (0.62, 0.81), (0.64, 0.96), (0.57, 0.95)])
            let strap = polyPath([(0.24, 0.8), (0.3, 0.78), (0.8, 1.06), (0.72, 1.06)])
            return [base(), fill(crewNeck(depth: 0.03, width: 0.07), .skin), fill(strap, .leather), fill(tail, .accentShade), fill(scarf, .accent)]
                + (d ? [line(seams)] : [])
        case 11: // Knight — steel and a tabard
            let tabard = Path(roundedRect: CGRect(x: 0.37, y: 0.82, width: 0.26, height: 0.3), cornerRadius: 0.02)
            let gorget = Path(roundedRect: CGRect(x: 0.36, y: 0.725, width: 0.28, height: 0.07), cornerRadius: 0.035)
            var cross = Path()
            cross.move(to: pt(0.5, 0.86)); cross.addLine(to: pt(0.5, 1.0))
            cross.move(to: pt(0.44, 0.91)); cross.addLine(to: pt(0.56, 0.91))
            return [base(.metal), fill(tabard, .outfit), FigurePiece(path: cross, fill: nil, outlined: false, stroke: .accent, strokeScale: 2.4), fill(gorget, .metalShade)]
                + (d ? [line(seams, .metalShade)] : [])
        case 12: // Space suit
            var ring = Path()
            ring.addEllipse(in: CGRect(x: 0.33, y: 0.71, width: 0.34, height: 0.1))
            let panel = Path(roundedRect: CGRect(x: 0.4, y: 0.86, width: 0.2, height: 0.12), cornerRadius: 0.02)
            return [base(), fill(ring, .metal), fill(Path(ellipseIn: CGRect(x: 0.39, y: 0.725, width: 0.22, height: 0.055)), .skin, outlined: false),
                    fill(panel, .ink, alpha: 0.85), fill(circlePath(0.45, 0.92, 0.015), .accent, outlined: false),
                    fill(circlePath(0.5, 0.92, 0.015), .white, outlined: false), fill(circlePath(0.55, 0.92, 0.015), .accent, outlined: false)]
                + (d ? [line(seams)] : [])
        case 13: // Poncho — zigzag band
            var zig: [(CGFloat, CGFloat)] = []
            for k in 0...10 { zig.append((0.16 + CGFloat(k) * 0.068, k % 2 == 0 ? 0.9 : 0.86)) }
            var zz = Path(); zz.move(to: pt(zig[0].0, zig[0].1)); for q in zig.dropFirst() { zz.addLine(to: pt(q.0, q.1)) }
            var band2 = Path(); band2.move(to: pt(0.15, 0.95)); band2.addLine(to: pt(0.85, 0.95))
            return [base(), fill(crewNeck(depth: 0.04, width: 0.08), .skin), FigurePiece(path: zz, fill: nil, outlined: false, stroke: .accent, strokeScale: 2.2)]
                + (d ? [FigurePiece(path: band2, fill: nil, outlined: false, stroke: .outfitLight, strokeScale: 1.6)] : [])
        case 14: // Garden apron
            let apron = Path(roundedRect: CGRect(x: 0.33, y: 0.83, width: 0.34, height: 0.3), cornerRadius: 0.05)
            var ties = Path(); ties.move(to: pt(0.36, 0.84)); ties.addLine(to: pt(0.41, 0.75)); ties.move(to: pt(0.64, 0.84)); ties.addLine(to: pt(0.59, 0.75))
            let pocket = Path(roundedRect: CGRect(x: 0.42, y: 0.92, width: 0.16, height: 0.1), cornerRadius: 0.02)
            return [base(.accent), fill(crewNeck(), .skin), fill(apron, .outfit), FigurePiece(path: ties, fill: nil, outlined: false, stroke: .outfitShade, strokeScale: 1.4),
                    fill(pocket, .outfitShade), fill(leafPath(from: pt(0.5, 0.92), to: pt(0.46, 0.86)), .accent), fill(circlePath(0.53, 0.875, 0.018), .white)]
        case 15: // Lantern robe — high collar and a glowing charm
            let collar = Path(roundedRect: CGRect(x: 0.4, y: 0.72, width: 0.2, height: 0.07), cornerRadius: 0.025)
            var lantern = FigurePiece(path: Path(roundedRect: CGRect(x: 0.465, y: 0.87, width: 0.07, height: 0.09), cornerRadius: 0.025), fill: .accent)
            lantern.glow = true
            var cord = Path(); cord.move(to: pt(0.5, 0.79)); cord.addLine(to: pt(0.5, 0.87))
            var frogs = Path()
            for y in [0.99, 1.03] as [CGFloat] { frogs.move(to: pt(0.46, y)); frogs.addLine(to: pt(0.54, y)) }
            return [base(), fill(collar, .outfitShade), line(cord, .accentShade, scale: 1), lantern,
                    fill(Path(CGRect(x: 0.46, y: 0.862, width: 0.08, height: 0.014)), .accentShade, outlined: false)]
                + (d ? [line(frogs, .accent, scale: 1.4), line(seams)] : [])
        case 16: // Baju Melayu — cekak musang collar and buttons
            let collar = Path(roundedRect: CGRect(x: 0.405, y: 0.72, width: 0.19, height: 0.065), cornerRadius: 0.02)
            var placket = Path(); placket.move(to: pt(0.5, 0.785)); placket.addLine(to: pt(0.5, 0.95))
            return [base(), fill(collar, .outfitShade), line(placket, .outfitShade, scale: 1.1),
                    fill(circlePath(0.5, 0.82, 0.014), .accent), fill(circlePath(0.5, 0.87, 0.014), .accent), fill(circlePath(0.5, 0.92, 0.014), .accent)]
                + (d ? [line(seams)] : [])
        case 17: // Sailor collar
            let collar = polyPath([(0.3, 0.76), (0.4, 0.747), (0.5, 0.88), (0.6, 0.747), (0.7, 0.76), (0.66, 0.84), (0.5, 0.96), (0.34, 0.84)])
            var stripe = Path()
            stripe.move(to: pt(0.34, 0.8)); stripe.addLine(to: pt(0.5, 0.92)); stripe.addLine(to: pt(0.66, 0.8))
            let knot = polyPath([(0.45, 0.89), (0.55, 0.89), (0.5, 0.98)])
            return [base(), fill(vNeck(depth: 0.87, width: 0.1), .skin), fill(collar, .white), line(stripe, .accent, scale: 1.6), fill(knot, .accent)]
        case 18: // Cardigan over a shirt
            let left = polyPath([(0.14, 1.06), (0.155, 0.9), (0.2, 0.8), (0.36, 0.745), (0.43, 0.745), (0.47, 1.06)])
            return [base(.accent), fill(crewNeck(), .skin), line(crewNeck(depth: 0.06, width: 0.095), .accentShade, scale: 1.3),
                    fill(left, .outfit), fill(mirrored(left), .outfit),
                    fill(circlePath(0.445, 0.86, 0.013), .white), fill(circlePath(0.45, 0.94, 0.013), .white), fill(circlePath(0.455, 1.02, 0.013), .white)]
        default: // 19 Jersey with a number
            var seven = Path()
            seven.move(to: pt(0.455, 0.85)); seven.addLine(to: pt(0.545, 0.85)); seven.addLine(to: pt(0.49, 0.98))
            var shoulders = Path()
            shoulders.move(to: pt(0.2, 0.83)); shoulders.addQuadCurve(to: pt(0.32, 0.765), control: pt(0.24, 0.78))
            shoulders.move(to: pt(0.8, 0.83)); shoulders.addQuadCurve(to: pt(0.68, 0.765), control: pt(0.76, 0.78))
            return [base(), fill(vNeck(depth: 0.83, width: 0.08), .skin), line(vNeck(depth: 0.845, width: 0.095), .accent, scale: 2),
                    line(shoulders, .accent, scale: 2), FigurePiece(path: seven, fill: nil, outlined: false, stroke: .accent, strokeScale: 2.8)]
        }
    }
}
