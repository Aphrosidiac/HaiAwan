import SwiftUI
import UniformTypeIdentifiers

/// Black shape hanging from the top edge: flat top, concave "shoulders", rounded bottom.
struct NotchShape: Shape {
    var bottomRadius: CGFloat = 18
    var shoulder: CGFloat = 8

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, shoulder) }
        set { bottomRadius = newValue.first; shoulder = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        // Clamp both radii so the path stays simple while the shape is tiny (collapsing into the 60×8 handle).
        let s = max(0, min(shoulder, r.width / 8, r.height / 4))
        let br = max(0, min(bottomRadius, r.height - s, (r.width - 2 * s) / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - s, y: r.minY + s), control: CGPoint(x: r.maxX - s, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - br))
        p.addQuadCurve(to: CGPoint(x: r.maxX - s - br, y: r.maxY), control: CGPoint(x: r.maxX - s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + s + br, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + s, y: r.maxY - br), control: CGPoint(x: r.minX + s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.minY + s))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: r.minX + s, y: r.minY))
        p.closeSubpath()
        return p
    }

    /// Corner radii per mode (the peek is measured: 6 pt shoulders, ≈16 pt bottom radius).
    static func radii(for mode: NotchMode) -> (bottom: CGFloat, shoulder: CGFloat) {
        switch mode {
        case .resting: return (10, 6)
        // Activity and cards are pure black with ≈8.5 pt shoulders and a ≈16 pt bottom radius (measured).
        case .activity: return (16, 8.5)
        case .peek: return (NotchPeekLayout.bottomRadius, NotchPeekLayout.shoulder)
        case .surface: return (16, 8.5)
        }
    }
}

/// Everything the notch shows, inside the fixed transparent panel. One container for every mode: the black shape
/// animates its size (spring) and its content is laid out at the final size, centred and pinned to the top, and
/// revealed by the growing clip. On Macs without a hardware notch, the resting state is just the handle.
struct NotchRootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var notch: NotchController

    var body: some View {
        let g = notch.geometry
        let mode = notch.mode
        let size = notch.sizeFor(mode)
        let hw = g.hasHardwareNotch
        let resting = mode == .resting
        let radii = NotchShape.radii(for: mode)
        let hot = CGSize(width: g.hotZone.width, height: g.hotZone.height)
        // Shape opacity: eases in (0.2 s) when it opens; on close eases to ~0.27 (0.3 s) while it shrinks, then
        // it is gone at once (no animation) and the handle fades back in.
        let shapeOpacity: Double = (!resting || hw) ? 1 : (notch.isCollapsing ? NotchController.Motion.collapsedOpacity : 0)
        let opacityAnimation: Animation? = (!resting || hw) ? NotchController.Motion.shapeFadeIn
            : (notch.isCollapsing ? NotchController.Motion.shapeFadeOut : nil)
        let handleVisible = !hw && resting && !notch.isCollapsing

        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                Color.black
                NotchModeContent(mode: mode)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .id(Self.contentKey(mode))
                    .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(NotchController.Motion.contentFadeOut)))
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(NotchShape(bottomRadius: radii.bottom, shoulder: radii.shoulder))
            .animation(opacityAnimation) { $0.opacity(shapeOpacity) }

            if !hw {
                // Stays on top while the shape grows out of it, and fades out.
                NotchHandle()
                    .padding(.top, NotchController.handleTop)
                    .animation(NotchController.Motion.handleFade) { $0.opacity(handleVisible ? 1 : 0) }
                    .allowsHitTesting(false)
            }
        }
        // Hit/drop area: the shape, or the handle's hot zone while the shape is smaller than it.
        .frame(width: max(size.width, hot.width), height: max(size.height, hot.height), alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture {
            if notch.mode == .resting || notch.mode == .activity { notch.notchClicked() }
        }
        .onDrop(of: [.fileURL], delegate: NotchDropDelegate())   // wave 2: drag files onto the notch
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static func contentKey(_ mode: NotchMode) -> String {
        switch mode {
        case .resting: return "resting"
        case .activity: return "activity"
        case .peek: return "peek"
        case let .surface(kind): return "surface-\(kind)"
        }
    }
}

/// What goes inside the shape for each mode (drawn at the shape's final size).
struct NotchModeContent: View {
    let mode: NotchMode
    var body: some View {
        switch mode {
        case .resting:
            Color.clear
        case .activity:
            ActivityNotch()
        case .peek:
            NotchPeekView()
        case let .surface(kind):
            NotchSurfaceView(kind: kind).padding(.horizontal, 10)
        }
    }
}

/// Idle on Macs without a notch: a small handle hints where Awan lives (measured: capsule 60×8 at y=4,
/// black α0.22, 0.5 pt light hairline). It does not react to hover — the peek's hover intent is the feedback.
struct NotchHandle: View {
    var body: some View {
        Capsule()
            .fill(Color.black.opacity(0.22))
            .overlay(Capsule().strokeBorder(Color(white: 0.71).opacity(0.5), lineWidth: 0.5))
            .frame(width: NotchController.handleSize.width, height: NotchController.handleSize.height)
    }
}

/// Compact live activity: who's working on the left, what's happening on the right. With nothing running and
/// finished work waiting, the reference shows only an unread-count gel badge (≈17 pt) on the left, right side empty.
struct ActivityNotch: View {
    @EnvironmentObject var state: AppState
    @Local private var pulse = false
    @Local private var hovering = false

    var body: some View {
        let running = state.agents.runningAgents
        HStack(spacing: 8) {
            leading
            Spacer()
            if hovering, state.companion.voiceState == .responding || state.companion.voiceState == .processing {
                // Click to stop (the notch's tap handler stops Awan while it's busy).
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.bone)
                    .help("Stop Awan (or press Esc)")
            } else {
                trailing(runningCount: running.count)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxHeight: .infinity)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var leading: some View {
        let running = state.agents.runningAgents
        if state.companion.voiceState != .idle {
            CloudCreature(appearance: .mascot, mood: mood, glow: false).frame(width: 26)
        } else if state.dictation.isDictating {
            Image(systemName: "character.cursor.ibeam").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.lime)
        } else if let a = running.first {
            HStack(spacing: -6) {
                ForEach(running.prefix(3)) { agent in
                    AgentAvatar(appearance: agent.character, size: 20, mood: .running, showRing: false)
                }
            }
            .id(a.slug)
        } else if state.agents.unreadCount > 0 {
            UnreadGelBadge(count: state.agents.unreadCount)
        }
    }

    @ViewBuilder private func trailing(runningCount: Int) -> some View {
        switch state.companion.voiceState {
        case .listening:
            WaveformBars(level: CGFloat(state.companion.audioLevel), color: Theme.lime).frame(width: 26, height: 14)
        case .processing:
            TypingDots(color: Theme.bone)
        case .responding:
            WaveformBars(level: 0.6, color: Theme.bone).frame(width: 26, height: 14)
        case .idle:
            if state.dictation.isDictating {
                WaveformBars(level: 0.5, color: Theme.lime).frame(width: 26, height: 14)
            } else if runningCount > 0 {
                TypingDots(color: Theme.bone)
            }
        }
    }

    private var mood: CharacterMood {
        switch state.companion.voiceState {
        case .listening: return .listening
        case .processing: return .thinking
        case .responding: return .speaking
        case .idle: return .idle
        }
    }
}

/// The activity notch's unread count: a small lime gel circle (the reference's is blue) with an ink digit.
struct UnreadGelBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.awan(10.5, .bold)).foregroundStyle(Theme.ink)
            .padding(.horizontal, count > 9 ? 4 : 0)
            .frame(minWidth: 17, minHeight: 17)
            .background(Capsule().fill(LinearGradient(colors: [Color(hex: 0xF1FFB8), Theme.lime, Theme.limeDeep], startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(Color(hex: 0x8FB000).opacity(0.7), lineWidth: 0.75))
            .overlay(alignment: .top) {
                Capsule().fill(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(height: 7).padding(.horizontal, 3).padding(.top, 1.5).allowsHitTesting(false)
            }
    }
}

// MARK: - Small animated bits shared across the app

struct TypingDots: View {
    var color: Color = Theme.textSecondary
    var dot: CGFloat = 5
    @Local private var phase = 0.0
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: dot * 0.7) {
                ForEach(0..<3) { i in
                    Circle().fill(color)
                        .frame(width: dot, height: dot)
                        .opacity(0.35 + 0.65 * max(0, sin((t * 5) - Double(i) * 0.7)))
                }
            }
        }
    }
}

struct WaveformBars: View {
    var level: CGFloat
    var color: Color = Theme.lime
    var bars = 5
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { g in
                HStack(alignment: .center, spacing: g.size.width * 0.08) {
                    ForEach(0..<bars, id: \.self) { i in
                        let wobble = 0.5 + 0.5 * sin(t * 9 + Double(i) * 1.3)
                        Capsule().fill(color)
                            .frame(width: g.size.width / CGFloat(bars) * 0.62,
                                   height: max(3, g.size.height * (0.25 + min(1, level * 1.6 + 0.15) * CGFloat(wobble) * 0.75)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
