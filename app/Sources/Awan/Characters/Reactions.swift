import SwiftUI

/// Short character animations the editor and inspector can play (tap a portrait to boop it).
/// Every reaction is a pure function of progress 0…1, so snapshots can freeze any frame.
enum CharacterReaction: String, CaseIterable, Identifiable {
    case wave, wink, boop, giggle, celebrate, dance
    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var symbol: String {
        switch self {
        case .wave: return "hand.wave.fill"
        case .wink: return "eye"
        case .boop: return "hand.point.up.left.fill"
        case .giggle: return "face.smiling"
        case .celebrate: return "party.popper.fill"
        case .dance: return "music.note"
        }
    }
    var duration: Double {
        switch self {
        case .wave: return 1.5
        case .wink: return 0.95
        case .boop: return 0.75
        case .giggle: return 1.1
        case .celebrate: return 1.7
        case .dance: return 2.0
        }
    }
}

/// Where a reaction has the character at one instant.
struct ReactionPose: Equatable {
    var rotation: Double = 0                 // degrees, around the character's base
    var offset: CGSize = .zero               // fraction of the character's size
    var scale = CGSize(width: 1, height: 1)
    var expression: CharacterExpression? = nil
    var wink = false
    var hand: Double? = nil                  // wave: hand angle in degrees
    var handIn: Double = 0                   // wave: 0…1 hand shown
    var confetti: Double? = nil
    var notes: Double? = nil
    var boop: Double? = nil
    var sparkle: Double = 0

    static func at(_ reaction: CharacterReaction?, _ t0: Double) -> ReactionPose {
        guard let reaction else { return ReactionPose() }
        let t = min(1, max(0, t0))
        let bump = sin(t * .pi)
        var p = ReactionPose()
        switch reaction {
        case .wave:
            p.expression = .happy
            p.handIn = smooth(0, 0.14, t) * (1 - smooth(0.84, 1, t))
            p.hand = sin(t * .pi * 2 * 3) * 24
            p.rotation = sin(t * .pi * 2 * 1.5) * 3
        case .wink:
            p.expression = .idle
            p.wink = t > 0.12 && t < 0.72
            p.rotation = 6 * bump
            p.sparkle = sin(min(1, max(0, (t - 0.15) / 0.6)) * .pi)
        case .boop:
            let e = t < 0.3 ? sin(t / 0.3 * .pi) : -0.35 * sin((t - 0.3) / 0.7 * .pi * 2) * (1 - t)
            p.scale = CGSize(width: 1 + 0.1 * e, height: 1 - 0.14 * e)
            p.expression = t < 0.34 ? .surprised : .happy
            p.boop = t
        case .giggle:
            p.expression = .laughing
            p.rotation = sin(t * .pi * 2 * 4) * 7 * (1 - t * 0.7)
            p.offset = CGSize(width: 0, height: -abs(sin(t * .pi * 2 * 4)) * 0.025)
        case .celebrate:
            p.expression = .excited
            let hop1 = t < 0.45 ? sin(t / 0.45 * .pi) : 0
            let hop2 = t >= 0.45 && t < 0.72 ? sin((t - 0.45) / 0.27 * .pi) * 0.4 : 0
            p.offset = CGSize(width: 0, height: -0.13 * (hop1 + hop2))
            let land = t > 0.4 && t < 0.52 ? sin((t - 0.4) / 0.12 * .pi) : 0
            p.scale = CGSize(width: 1 + 0.06 * land, height: 1 - 0.08 * land)
            p.confetti = t
        case .dance:
            p.expression = .happy
            p.rotation = sin(t * .pi * 2 * 2) * 12
            p.offset = CGSize(width: sin(t * .pi * 2 * 2) * 0.05, height: -abs(sin(t * .pi * 2 * 4)) * 0.04)
            p.notes = t
        }
        return p
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let k = min(1, max(0, (x - a) / (b - a)))
        return k * k * (3 - 2 * k)
    }
}

/// Applies a reaction's squash, tilt and hop to a character.
struct ReactionTransform: ViewModifier {
    let pose: ReactionPose
    let size: CGSize
    func body(content: Content) -> some View {
        content
            .scaleEffect(x: pose.scale.width, y: pose.scale.height, anchor: .bottom)
            .rotationEffect(.degrees(pose.rotation), anchor: .bottom)
            .offset(x: pose.offset.width * size.width, y: pose.offset.height * size.height)
    }
}

/// The bits a reaction adds around a character: a waving hand, confetti, notes, a boop ring.
struct ReactionOverlay: View {
    let pose: ReactionPose
    let appearance: CharacterAppearance
    /// Where the waving hand sits, as a fraction of the character's frame.
    var handAnchor = CGPoint(x: 0.84, y: 0.78)

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, s = min(w, h)
            func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * w, y: y * h) }
            let ink = Color(hex: 0x1F1A17)
            let lw = max(1, s * 0.018)

            if let angle = pose.hand, pose.handIn > 0.01 {
                let skin = appearance.pack.isFigure ? CharacterCatalog.skinColor(appearance) : CharacterCatalog.cloudColors(for: appearance).bottom
                let sleeve = appearance.pack.isFigure ? CharacterCatalog.outfitColor(appearance) : skin
                let wrist = P(handAnchor.x, handAnchor.y)
                var g = ctx
                g.translateBy(x: wrist.x, y: wrist.y)
                g.rotate(by: .degrees(angle - 12))
                g.scaleBy(x: pose.handIn, y: pose.handIn)
                let r = s * 0.1
                var arm = Path(); arm.move(to: CGPoint(x: -r * 0.2, y: r * 2.2)); arm.addLine(to: CGPoint(x: 0, y: -r * 0.2))
                g.stroke(arm, with: .color(ink), style: StrokeStyle(lineWidth: r * 1.05 + lw * 2, lineCap: .round))
                g.stroke(arm, with: .color(sleeve), style: StrokeStyle(lineWidth: r * 1.05, lineCap: .round))
                let palm = Path(ellipseIn: CGRect(x: -r, y: -r * 1.9, width: r * 2, height: r * 2.1))
                let thumb = Path(ellipseIn: CGRect(x: -r * 1.45, y: -r * 1.2, width: r * 0.9, height: r * 0.62))
                g.fill(thumb, with: .color(skin)); g.stroke(thumb, with: .color(ink), lineWidth: lw)
                g.fill(palm, with: .color(skin)); g.stroke(palm, with: .color(ink), lineWidth: lw)
                var motion = Path()
                motion.addArc(center: CGPoint(x: 0, y: -r * 0.8), radius: r * 1.9, startAngle: .degrees(-70), endAngle: .degrees(-30), clockwise: false)
                g.stroke(motion, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }

            if let t = pose.confetti {
                let colors: [Color] = [Color(hex: 0xF6C744), Color(hex: 0xF59AC0), Color(hex: 0x8DD3F7), Color(hex: 0x62C9A0), Color(hex: 0xF07A64), Color(hex: 0x9A7BE0)]
                let fade = 1 - max(0, (t - 0.7) / 0.3)
                for i in 0..<20 {
                    let fi = Double(i)
                    let a = -Double.pi / 2 + (fi / 19 - 0.5) * 2.8
                    let speed = 0.45 + 0.4 * (fi * 0.618).truncatingRemainder(dividingBy: 1)
                    let x = 0.5 + cos(a) * speed * t
                    let y = 0.3 + sin(a) * speed * t + 0.8 * t * t
                    var g = ctx
                    g.opacity = fade
                    g.translateBy(x: x * w, y: y * h)
                    g.rotate(by: .degrees(fi * 41 + t * 520))
                    let rect = CGRect(x: -s * 0.03, y: -s * 0.015, width: s * 0.06, height: s * 0.03)
                    g.fill(i % 3 == 0 ? Path(ellipseIn: rect.insetBy(dx: s * 0.004, dy: -s * 0.004)) : Path(rect), with: .color(colors[i % colors.count]))
                }
            }

            if let t = pose.notes {
                for (i, base) in [(0.14, 0.52), (0.86, 0.42), (0.24, 0.3)].enumerated() {
                    let k = (t * 1.6 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                    let c = P(base.0 + sin(k * .pi * 2) * 0.03, base.1 - k * 0.3)
                    var g = ctx
                    g.opacity = sin(k * .pi)
                    let r = s * 0.04
                    var note = Path(ellipseIn: CGRect(x: c.x - r * 1.2, y: c.y - r * 0.8, width: r * 2.2, height: r * 1.6))
                    note.addRect(CGRect(x: c.x + r * 0.7, y: c.y - r * 4, width: r * 0.42, height: r * 4))
                    note.addRect(CGRect(x: c.x + r * 0.7, y: c.y - r * 4, width: r * 1.6, height: r * 0.5))
                    g.fill(note, with: .color(.white))
                    g.stroke(note, with: .color(ink), lineWidth: max(0.8, lw * 0.8))
                }
            }

            if let t = pose.boop, t < 0.75 {
                let k = t / 0.75
                let c = P(0.5, appearance.pack.isFigure ? 0.52 : 0.6)
                var g = ctx
                g.opacity = 1 - k
                let r = s * (0.06 + 0.26 * k)
                g.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(.white), lineWidth: lw * 1.4)
                for j in 0..<3 {
                    let a = -Double.pi / 2 + Double(j - 1) * 0.9
                    let d = s * (0.12 + 0.2 * k)
                    g.fill(sparklePath(CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d), s * 0.035), with: .color(Color(hex: 0xF6C744)))
                }
            }

            if pose.sparkle > 0.01 {
                let c = P(appearance.pack.isFigure ? 0.76 : 0.74, appearance.pack.isFigure ? 0.4 : 0.36)
                let sp = sparklePath(c, s * 0.06 * pose.sparkle)
                ctx.fill(sp, with: .color(Color(hex: 0xF6C744)))
                ctx.stroke(sp, with: .color(ink), lineWidth: max(0.6, lw * 0.6))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Fires a reaction: bump `id` (use `fire(_:)`) and any `ReactiveCharacter` bound to it plays once.
struct ReactionTrigger: Equatable {
    var id = 0
    var reaction: CharacterReaction = .boop
    mutating func fire(_ r: CharacterReaction) { id += 1; reaction = r }
}

/// A character (big figure, or a round avatar when `avatarSize` is set) that plays reactions.
struct ReactiveCharacter: View {
    var appearance: CharacterAppearance
    var mood: CharacterMood = .idle
    var expression: CharacterExpression? = nil
    var avatarSize: CGFloat? = nil
    var showPaws = false
    var trigger: ReactionTrigger

    @Local private var playing: CharacterReaction? = nil
    @Local private var started = Date.distantPast
    @Local private var run = 0

    var body: some View {
        Group {
            if let r = playing {
                TimelineView(.animation) { tl in
                    character(r, min(1, tl.date.timeIntervalSince(started) / r.duration))
                }
            } else {
                character(nil, 0)
            }
        }
        .onChange(of: trigger) { _, t in play(t.reaction) }
    }

    @ViewBuilder private func character(_ r: CharacterReaction?, _ t: Double) -> some View {
        if let size = avatarSize {
            AgentAvatar(appearance: appearance, size: size, mood: mood, expression: expression, reaction: r, reactionProgress: t)
        } else {
            CharacterFigure(appearance: appearance, mood: mood, showPaws: showPaws, expression: expression, reaction: r, reactionProgress: t)
        }
    }

    private func play(_ r: CharacterReaction) {
        run += 1
        let mine = run
        started = Date()
        playing = r
        DispatchQueue.main.asyncAfter(deadline: .now() + r.duration + 0.05) {
            if run == mine { playing = nil }
        }
    }
}
