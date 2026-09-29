import SwiftUI

/// Facial expression for any character.
enum CharacterMood: String, CaseIterable {
    case idle, blink, listening, thinking, speaking, sleeping, happy, running, sad
}

extension CharacterMood {
    /// The figure-rig pose for this mood; `resting` is the character's own face when idle.
    func figurePose(resting: CharacterExpression?) -> FigurePose {
        switch self {
        case .idle: return FigurePose(expression: resting ?? .idle)
        case .blink: return FigurePose(expression: resting ?? .idle, closed: .line)
        case .listening: return FigurePose(expression: .listening)
        case .thinking: return FigurePose(expression: .thinking)
        case .speaking: return FigurePose(expression: resting ?? .idle, mouthOpen: 0.5)
        case .sleeping: return FigurePose(expression: .sleepy, closed: .sleep)
        case .happy: return FigurePose(expression: .happy)
        case .running: return FigurePose(expression: .determined)
        case .sad: return FigurePose(expression: .sad)
        }
    }
}

// MARK: - Cloud body

/// A soft cumulus: a union of circles over a rounded base.
struct CloudShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        let blobs: [(CGFloat, CGFloat, CGFloat)] = [   // (cx, cy, radius) as fractions of width/height
            (0.22, 0.60, 0.21), (0.36, 0.40, 0.23), (0.56, 0.33, 0.25), (0.76, 0.48, 0.21),
            (0.84, 0.64, 0.16), (0.14, 0.72, 0.14), (0.50, 0.66, 0.30),
        ]
        for (cx, cy, rad) in blobs {
            let rr = rad * w
            p.addEllipse(in: CGRect(x: r.minX + cx * w - rr, y: r.minY + cy * h - rr * (h / w) * 1.05, width: rr * 2, height: rr * 2 * (h / w) * 1.05))
        }
        p.addRoundedRect(in: CGRect(x: r.minX + 0.08 * w, y: r.minY + 0.52 * h, width: 0.84 * w, height: 0.36 * h), cornerSize: CGSize(width: 0.16 * h, height: 0.16 * h))
        return p
    }
}

/// One cloud eye.
enum CloudEye { case arc, line, droop, dot, chevron, ring, heart, laughLeft, laughRight }

extension CharacterMood {
    var cloudEye: CloudEye {
        switch self {
        case .idle, .speaking, .happy: return .arc
        case .blink, .thinking: return .line
        case .sleeping, .sad: return .droop
        case .listening: return .dot
        case .running: return .chevron
        }
    }
}

extension CharacterExpression {
    var cloudEyes: (CloudEye, CloudEye) {
        switch self {
        case .idle, .happy, .shy, .excited: return (.arc, .arc)
        case .curious, .listening: return (.dot, .dot)
        case .thinking: return (.line, .line)
        case .sleepy, .sad: return (.droop, .droop)
        case .surprised: return (.ring, .ring)
        case .skeptical: return (.dot, .line)
        case .laughing: return (.laughLeft, .laughRight)
        case .determined: return (.chevron, .chevron)
        case .loving: return (.heart, .heart)
        }
    }
}

/// Eyes for the cloud, drawn by mood (or an explicit pair of eye shapes).
struct CloudEyes: View {
    var left: CloudEye
    var right: CloudEye
    var color: Color = .white
    var lineWidth: CGFloat

    init(mood: CharacterMood, color: Color = .white, lineWidth: CGFloat) {
        left = mood.cloudEye; right = mood.cloudEye
        self.color = color; self.lineWidth = lineWidth
    }
    init(left: CloudEye, right: CloudEye, color: Color = .white, lineWidth: CGFloat) {
        self.left = left; self.right = right; self.color = color; self.lineWidth = lineWidth
    }

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let eyeW = w * 0.20
            for (cx, eye) in [(w * 0.30, left), (w * 0.70, right)] {
                var path = Path()
                switch eye {
                case .arc:
                    path.move(to: CGPoint(x: cx - eyeW / 2, y: h * 0.62))
                    path.addQuadCurve(to: CGPoint(x: cx + eyeW / 2, y: h * 0.62), control: CGPoint(x: cx, y: h * 0.05))
                case .line:
                    path.move(to: CGPoint(x: cx - eyeW / 2, y: h * 0.5))
                    path.addLine(to: CGPoint(x: cx + eyeW / 2, y: h * 0.5))
                case .droop:
                    path.move(to: CGPoint(x: cx - eyeW / 2, y: h * 0.35))
                    path.addQuadCurve(to: CGPoint(x: cx + eyeW / 2, y: h * 0.35), control: CGPoint(x: cx, y: h * 0.95))
                case .dot:
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - eyeW * 0.28, y: h * 0.18, width: eyeW * 0.56, height: h * 0.64)), with: .color(color))
                    continue
                case .ring:
                    ctx.stroke(Path(ellipseIn: CGRect(x: cx - eyeW * 0.36, y: h * 0.06, width: eyeW * 0.72, height: h * 0.88)), with: .color(color), lineWidth: lineWidth * 0.85)
                    continue
                case .heart:
                    ctx.fill(heartPath(CGPoint(x: cx, y: h * 0.5), max(eyeW * 0.95, h * 0.95)), with: .color(Color(hex: 0xFF6F8E)))
                    continue
                case .chevron:
                    path.move(to: CGPoint(x: cx - eyeW / 2, y: h * 0.62))
                    path.addLine(to: CGPoint(x: cx, y: h * 0.25))
                    path.addLine(to: CGPoint(x: cx + eyeW / 2, y: h * 0.62))
                case .laughLeft, .laughRight:
                    let d: CGFloat = eye == .laughLeft ? 1 : -1
                    path.move(to: CGPoint(x: cx - d * eyeW * 0.4, y: h * 0.1))
                    path.addLine(to: CGPoint(x: cx + d * eyeW * 0.4, y: h * 0.5))
                    path.addLine(to: CGPoint(x: cx - d * eyeW * 0.4, y: h * 0.9))
                }
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// The cloud creature (Awan's mascot and every Awan Clouds character).
struct CloudCreature: View {
    var appearance: CharacterAppearance
    var mood: CharacterMood = .idle
    var showPaws = false
    var glow = true
    /// Explicit face (editor previews, reactions); otherwise the mood, or the look's resting face when idle.
    var expression: CharacterExpression? = nil
    var winkRight = false

    @Local private var bob = false

    private var face: CharacterExpression? { expression ?? (mood == .idle ? appearance.expression : nil) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let colors = CharacterCatalog.cloudColors(for: appearance)
            let eyes = face?.cloudEyes ?? (mood.cloudEye, mood.cloudEye)
            ZStack {
                if glow {
                    CloudShape()
                        .fill(colors.bottom.opacity(0.55))
                        .blur(radius: w * 0.08)
                        .scaleEffect(1.04)
                }
                CloudShape()
                    .fill(LinearGradient(colors: [colors.top, colors.bottom], startPoint: .top, endPoint: .bottom))
                CloudShape()
                    .fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .init(x: 0.38, y: 0.3), startRadius: 0, endRadius: w * 0.45))
                    .blendMode(.softLight)
                if let f = face, [.shy, .loving, .happy, .laughing, .excited].contains(f) {
                    HStack(spacing: w * 0.3) {
                        Ellipse().fill(Color(hex: 0xFF8FA6).opacity(f == .shy || f == .loving ? 0.55 : 0.35))
                        Ellipse().fill(Color(hex: 0xFF8FA6).opacity(f == .shy || f == .loving ? 0.55 : 0.35))
                    }
                    .frame(width: w * 0.56, height: h * 0.07)
                    .offset(y: h * 0.16)
                }
                CloudEyes(left: eyes.0, right: winkRight ? .arc : eyes.1, color: .white, lineWidth: max(1.6, w * 0.06))
                    .frame(width: w * 0.46, height: h * 0.16)
                    .offset(y: h * 0.06)
                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                if mood == .speaking && face == nil {
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: w * 0.08, height: h * (bob ? 0.07 : 0.03))
                        .offset(y: h * 0.22)
                        .animation(.easeInOut(duration: 0.18).repeatForever(autoreverses: true), value: bob)
                }
                if let f = face {
                    switch f {
                    case .laughing, .excited:
                        UnevenRoundedRectangle(topLeadingRadius: w * 0.01, bottomLeadingRadius: w * 0.07, bottomTrailingRadius: w * 0.07, topTrailingRadius: w * 0.01)
                            .fill(Color.white.opacity(0.92))
                            .frame(width: w * (f == .laughing ? 0.16 : 0.12), height: h * 0.08)
                            .offset(y: h * 0.23)
                    case .surprised:
                        Ellipse().stroke(Color.white.opacity(0.92), lineWidth: max(1.2, w * 0.035))
                            .frame(width: w * 0.07, height: h * 0.08).offset(y: h * 0.24)
                    default: EmptyView()
                    }
                }
                if mood == .sleeping || face == .sleepy {
                    Text("z").font(.system(size: w * 0.16, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .offset(x: w * 0.36, y: -h * 0.30)
                }
                if showPaws {
                    HStack(spacing: w * 0.36) {
                        Capsule().fill(colors.bottom).frame(width: w * 0.16, height: h * 0.14)
                        Capsule().fill(colors.bottom).frame(width: w * 0.16, height: h * 0.14)
                    }
                    .offset(y: h * 0.42)
                }
            }
            .offset(y: mood == .running ? (bob ? -h * 0.03 : h * 0.02) : 0)
            .animation(mood == .running ? .easeInOut(duration: 0.32).repeatForever(autoreverses: true) : .default, value: bob)
            .onAppear { bob = true }
        }
        .aspectRatio(1.35, contentMode: .fit)
    }
}

// MARK: - Figure faces

/// Head-only figure (kept for callers of the original Kawan face).
struct KawanFace: View {
    var appearance: CharacterAppearance
    var mood: CharacterMood = .idle

    var body: some View {
        FigurePortrait(appearance: appearance, pose: mood.figurePose(resting: appearance.expression), framing: .face)
    }
}

/// A figure that animates its mouth while speaking.
struct FigureView: View {
    var appearance: CharacterAppearance
    var pose: FigurePose
    var framing: FigureFraming = .bust
    var speaking = false

    var body: some View {
        if speaking {
            TimelineView(.animation(minimumInterval: 1 / 12)) { tl in
                FigurePortrait(appearance: appearance, pose: talking(at: tl.date.timeIntervalSinceReferenceDate), framing: framing)
            }
        } else {
            FigurePortrait(appearance: appearance, pose: pose, framing: framing)
        }
    }

    private func talking(at t: TimeInterval) -> FigurePose {
        var p = pose
        p.mouthOpen = CGFloat(0.5 + 0.5 * sin(t * 13) * sin(t * 3.1))
        return p
    }
}

// MARK: - Portraits (round avatars) and full characters

/// Round avatar used in lists, the notch and the dock stack.
struct AgentAvatar: View {
    var appearance: CharacterAppearance
    var size: CGFloat = 44
    var mood: CharacterMood = .idle
    var showRing = true
    var expression: CharacterExpression? = nil
    var reaction: CharacterReaction? = nil
    var reactionProgress: Double = 0

    var body: some View {
        let rp = ReactionPose.at(reaction, reactionProgress)
        ZStack {
            Circle().fill(CharacterCatalog.backgroundColor(appearance))
            Group {
                if appearance.pack.isFigure {
                    FigureView(appearance: appearance, pose: pose(rp), framing: .bust, speaking: mood == .speaking && rp.expression == nil)
                        .frame(width: size * 1.04, height: size * 1.04)
                        .offset(y: size * 0.06)
                } else {
                    CloudCreature(appearance: appearance, mood: mood, glow: false, expression: rp.expression ?? expression, winkRight: rp.wink)
                        .frame(width: size * 0.78)
                        .offset(y: size * 0.02)
                }
            }
            .modifier(ReactionTransform(pose: rp, size: CGSize(width: size, height: size)))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(showRing ? 0.35 : 0), lineWidth: max(1, size * 0.035)))
        .overlay { if reaction != nil { ReactionOverlay(pose: rp, appearance: appearance, handAnchor: CGPoint(x: 0.82, y: 0.72)) } }
    }

    private func pose(_ rp: ReactionPose) -> FigurePose {
        var p = mood.figurePose(resting: appearance.expression)
        if let e = expression { p.expression = e; p.closed = nil }
        if let e = rp.expression { p.expression = e; p.closed = nil; p.mouthOpen = nil }
        p.winkRight = rp.wink
        p.showExtras = size >= 60
        return p
    }
}

/// Large character (home hero, inspector, editor preview).
struct CharacterFigure: View {
    var appearance: CharacterAppearance
    var mood: CharacterMood = .idle
    var showPaws = false
    var expression: CharacterExpression? = nil
    var framing: FigureFraming = .bust
    var reaction: CharacterReaction? = nil
    var reactionProgress: Double = 0

    var body: some View {
        let rp = ReactionPose.at(reaction, reactionProgress)
        GeometryReader { geo in
            Group {
                if appearance.pack.isFigure {
                    FigureView(appearance: appearance, pose: pose(rp), framing: framing, speaking: mood == .speaking && rp.expression == nil)
                } else {
                    CloudCreature(appearance: appearance, mood: mood, showPaws: showPaws, expression: rp.expression ?? expression, winkRight: rp.wink)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .modifier(ReactionTransform(pose: rp, size: geo.size))
            .overlay { if reaction != nil { ReactionOverlay(pose: rp, appearance: appearance, handAnchor: appearance.pack.isFigure ? CGPoint(x: 0.84, y: 0.78) : CGPoint(x: 0.9, y: 0.66)) } }
        }
        .aspectRatio(appearance.pack.isFigure ? 1 : 1.35, contentMode: .fit)
    }

    private func pose(_ rp: ReactionPose) -> FigurePose {
        var p = mood.figurePose(resting: appearance.expression)
        if let e = expression { p.expression = e; p.closed = nil }
        if let e = rp.expression { p.expression = e; p.closed = nil; p.mouthOpen = nil }
        p.winkRight = rp.wink
        return p
    }
}

/// Awan's own mascot (the product's cloud, used on Home and in the notch).
extension CharacterAppearance {
    static let mascot = CharacterAppearance(pack: .awanClouds, preset: "langit", cloudHue: 0.57)
}
