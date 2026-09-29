import SwiftUI
import AppKit
import AVFoundation
import CoreText

// MARK: - 4. Tutorial panel (500×571, one step at a time; each step detects its own success)
//
// Layout measured on the reference's tutorial window: dark translucent panel,
// page dots + Back / ♫ / Skip demo on top, 20 pt semibold title and 13 pt body centred, the step's visual,
// a peach hint bubble with a pointer notch, and a gel Continue at the bottom that stays dim until the step
// is satisfied. Positions below are absolute (panel points, top-left origin) so they can be measured 1:1.

enum TutorialLayout {
    static let size = CGSize(width: 500, height: 571)
    static let radius: CGFloat = 12
    /// Centre line of the Back / ♫ / Skip demo row, and of the page dots.
    static let chromeY: CGFloat = 37.5
    static let dotsY: CGFloat = 40
    /// Top of the title's text box, and of the body's.
    static let titleTop: CGFloat = 91.5
    static let bodyTop: CGFloat = 124
    static let bodyWidth: CGFloat = 360
    /// Continue gel: centre and outer size (1 pt rim included).
    static let continueCenterY: CGFloat = 526.5
    static let continueSize = CGSize(width: 106, height: 42)
}

/// The seven dotted steps (the interview, speaker check and finale ride along without a dot, like the reference).
extension OnboardingStage {
    static let dotted: [OnboardingStage] = [.micCheck, .voiceHello, .drawDemo, .drawToAsk, .textMode, .emailDraft, .dictation]
    /// Tutorial stages shown in the tutorial panel (the interview keeps the big onboarding window).
    var usesTutorialPanel: Bool { isTutorial && self != .interview }
    var dotIndex: Int {
        switch self {
        case .speakerCheck: return 0
        case .interview: return 1
        case .finale: return Self.dotted.count
        default: return Self.dotted.firstIndex(of: self) ?? 0
        }
    }
    /// Where ‹ Back goes: the previous panel step (the interview is skipped; it has its own Back).
    var previousPanelStage: OnboardingStage? {
        let t = Self.tutorial.filter(\.usesTutorialPanel)
        guard let i = t.firstIndex(of: self), i > 0 else { return nil }
        return t[i - 1]
    }
}

struct TutorialCopy {
    let title: String
    let subtitle: String

    static func of(_ s: OnboardingStage) -> TutorialCopy {
        switch s {
        case .micCheck:
            return .init(title: "First, let me hear you", subtitle: "Talk out loud for a moment. If the bars move, your mic is fine. Built-in and wired mics work best; Bluetooth ones can drop out.")
        case .speakerCheck:
            return .init(title: "Can you hear me?", subtitle: "I just said hello. If you heard me, you're all set. If not, turn your Mac's sound up and play it again.")
        case .voiceHello:
            return .init(title: "Hold two keys and talk", subtitle: "Keep them held, say hi or tell me your name, then let go. I listen for as long as you hold on.")
        case .drawDemo:
            return .init(title: "I can point at things", subtitle: "I see what you see. Hold the keys, ask me to point at something, and watch your cursor fly.")
        case .drawToAsk:
            return .init(title: "Circle it, then ask", subtitle: "Hold the keys, click and drag a loop around something, and ask me about it.")
        case .textMode:
            return .init(title: "Rather type?", subtitle: "Double-tap Control and a text box opens right under the notch. Handy in a quiet room.")
        case .emailDraft:
            return .init(title: "I can draft replies", subtitle: "Hold the keys over an email and ask for a reply. I write it; you read it and hit send.")
        case .dictation:
            return .init(title: "Talk instead of typing", subtitle: "Click in the box, hold fn + Control, speak, then let go. I tidy it up and type it for you, in any app.")
        case .finale:
            return .init(title: "That's it, I'm all yours", subtitle: "Hold Control + Option whenever you need me. Next, pick a plan, then meet the Awans I made for you.")
        default:
            return .init(title: "", subtitle: "")
        }
    }
}

// MARK: - Panel

struct TutorialPanelView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var companion = CompanionEngine.shared
    var close: () -> Void = {}

    private var s: OnboardingStage { model.stage }
    private var copy: TutorialCopy { .of(s) }

    var body: some View {
        ZStack(alignment: .top) {
            TutorialMaterial()
            chrome
            VStack(spacing: 0) {
                Text(copy.title)
                    .font(.awan(20, .semibold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .padding(.top, TutorialLayout.titleTop)
                Text(copy.subtitle)
                    .font(.awan(13))
                    .foregroundStyle(TutorialPalette.secondary)
                    .multilineTextAlignment(.center)
                    .linePitch(TutorialPalette.bodyLinePitch, fontSize: 13)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: TutorialLayout.bodyWidth)
                    .padding(.top, TutorialLayout.bodyTop - TutorialLayout.titleTop - TutorialPalette.titleBoxHeight)
            }
            .id(s)
            .transition(.opacity)
            TutorialStepVisual(model: model, companion: companion)
                .id(s)
                .transition(.opacity.combined(with: .offset(y: 6)))
            continueButton
        }
        .frame(width: TutorialLayout.size.width, height: TutorialLayout.size.height)
        .clipShape(RoundedRectangle(cornerRadius: TutorialLayout.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TutorialLayout.radius, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
        .animation(Theme.spring, value: s)
        .preferredColorScheme(.dark)
    }

    // MARK: Chrome: ‹ Back · dots · ♫ · Skip demo

    private var chrome: some View {
        ZStack(alignment: .top) {
            TutorialDots(current: s)
                .frame(height: 7)
                .offset(y: TutorialLayout.dotsY - 3.5)
            HStack(spacing: 0) {
                if canGoBack {
                    Button { model.back() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            Text("Back").font(.awan(13, .medium))
                        }
                        .foregroundStyle(TutorialPalette.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 20)
                    .help("Back")
                }
                Spacer()
            }
            .frame(height: 24)
            .offset(y: TutorialLayout.chromeY - 12)
            // ♫ centred at x 389.5 and "Skip demo" right-aligned at x 477.5 (measured), independent of label widths.
            if s != .micCheck {
                Button { model.toggleTourMusic() } label: {
                    Text("\u{266B}")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(TutorialPalette.secondary.opacity(model.tourMusicOn ? 1 : 0.45))
                        .overlay {
                            if !model.tourMusicOn {
                                Rectangle().fill(TutorialPalette.secondary).frame(width: 1.2, height: 14).rotationEffect(.degrees(-40))
                            }
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.tourMusicOn ? "Turn tour music off" : "Turn tour music on")
                .position(x: 389.5, y: TutorialLayout.chromeY)
            }
            HStack(spacing: 0) {
                Spacer()
                Button { model.skipDemo() } label: {
                    Text("Skip demo").font(.awan(13, .medium)).foregroundStyle(TutorialPalette.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // With no \u{266B} in the row the reference's label sits 2 pt higher (the row is shorter).
                .offset(y: s == .micCheck ? -2 : 0)
                .padding(.trailing, 21.5)
            }
            .frame(height: 24)
            .offset(y: TutorialLayout.chromeY - 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var canGoBack: Bool { s != .micCheck && s != OnboardingStage.tutorial.first }

    // MARK: Continue

    private var satisfied: Bool { model.isSatisfied(s) }

    private var continueButton: some View {
        Button { model.advance() } label: { Text("Continue") }
            .buttonStyle(TutorialGelStyle(enabled: satisfied))
            .allowsHitTesting(satisfied)
            .keyboardShortcut(satisfied ? .defaultAction : nil)
            .accessibilityAddTraits(satisfied ? [] : .isStaticText)
            .position(x: TutorialLayout.size.width / 2, y: TutorialLayout.continueCenterY)
            .frame(width: TutorialLayout.size.width, height: TutorialLayout.size.height)
    }
}

enum TutorialPalette {
    /// Body copy, Back / Skip demo, status line (the reference's cool #9093A0, in Awan's warm grey).
    static let secondary = Color(hex: 0x96948B)
    /// Panel tint over the behind-window material (and the flat stand-in used by snapshots).
    static let tint = Color(hex: 0x141413).opacity(0.62)
    /// Baseline-to-baseline distance of the body copy (measured 18 on the reference).
    static let bodyLinePitch: CGFloat = 18
    /// Height of the 20 pt title's text box (Instrument Sans line height at 20 pt).
    static let titleBoxHeight: CGFloat = 24
    // Peach hint bubble (Awan's warm take on the reference's peach callout)
    static let peachTop = Color(hex: 0xFDE4D0)
    static let peachMid = Color(hex: 0xFCD0A9)
    static let peachBottom = Color(hex: 0xFCE3CF)
    static let peachRim = Color(hex: 0x92582D)
}

/// Dark translucent panel: behind-window HUD material with an ink tint. Snapshots can't capture a
/// behind-window blur, so there the tint alone is drawn (over the grey the reference was composited on).
struct TutorialMaterial: View {
    var body: some View {
        ZStack {
            if !CommandLine.arguments.contains("--snapshot") {
                BehindWindowBlur()
            }
            TutorialPalette.tint
        }
    }
}

struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Page dots (7; done = small lime dot, current = elongated lime capsule)

struct TutorialDots: View {
    var current: OnboardingStage
    var body: some View {
        let idx = current.dotIndex
        HStack(spacing: 10) {
            ForEach(0 ..< OnboardingStage.dotted.count, id: \.self) { i in
                if i == idx {
                    Capsule().fill(TutorialGel.fill)
                        .overlay(Capsule().strokeBorder(TutorialGel.rim, lineWidth: 1))
                        .frame(width: 23, height: 7)
                } else if i < idx {
                    Circle().fill(TutorialGel.fill)
                        .overlay(Circle().strokeBorder(TutorialGel.rim, lineWidth: 1))
                        .frame(width: 7, height: 7)
                } else {
                    Circle().fill(Color.white.opacity(0.12)).frame(width: 7, height: 7)
                }
            }
        }
        .animation(Theme.spring, value: idx)
    }
}

// MARK: - Continue gel (lime, 104×40 + 1 pt rim; dim until the step is satisfied)

enum TutorialGel {
    static let fill = LinearGradient(colors: [Color(hex: 0xF1FFB5), Color(hex: 0xDDFF52), Color(hex: 0xC6EC2A)], startPoint: .top, endPoint: .bottom)
    static let rim = Color(hex: 0x5E7400)
    /// Continue before the step is done: the same gel, drained to a grey-olive.
    static let dimFill = LinearGradient(colors: [Color(hex: 0xA3A68F), Color(hex: 0x8B8F74), Color(hex: 0x7C8066)], startPoint: .top, endPoint: .bottom)
}

struct TutorialGelStyle: ButtonStyle {
    var enabled: Bool
    var size: CGSize = TutorialLayout.continueSize
    var fontSize: CGFloat = 15
    /// Bone (white) gel for secondary actions (the plan chooser's paid plans).
    var bone = false

    private var fill: LinearGradient {
        if !enabled { return TutorialGel.dimFill }
        return bone ? LinearGradient(colors: [Color.white, Color(hex: 0xF4F1E8), Color(hex: 0xDAD5C8)], startPoint: .top, endPoint: .bottom) : TutorialGel.fill
    }
    private var rim: Color { bone ? Color(hex: 0x6E6A60) : TutorialGel.rim }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.awan(fontSize, .semibold))
            .foregroundStyle(enabled ? Theme.ink : Color(hex: 0x3A3D2C))
            .frame(width: size.width, height: size.height)
            .background(
                Capsule().fill(fill)
            )
            .overlay(alignment: .top) {
                // specular band across the top
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(enabled ? 0.75 : 0.28), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(height: size.height * 0.36)
                    .padding(.horizontal, size.height * 0.26)
                    .padding(.top, 2)
            }
            .overlay(alignment: .bottom) {
                // soft refraction line near the bottom edge
                Capsule().fill(Color.white.opacity(enabled ? 0.45 : 0.16))
                    .frame(height: 1)
                    .padding(.horizontal, size.height * 0.45)
                    .padding(.bottom, 4)
            }
            .overlay(Capsule().strokeBorder(enabled ? rim : Color(hex: 0x5F6350), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
            .animation(Theme.gentle, value: enabled)
            .contentShape(Capsule())
    }
}

// MARK: - Step visuals (absolute positions from the reference's mic and talk steps)

struct TutorialStepVisual: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var companion: CompanionEngine

    private var s: OnboardingStage { model.stage }
    private var done: Bool { model.completed.contains(s) }
    private var pressed: Bool { companion.voiceState == .listening }

    var body: some View {
        ZStack(alignment: .top) {
            switch s {
            case .micCheck:
                TutorialMicMeter(level: model.micLevel).frame(width: 234, height: 26).offset(y: 260)
                TutorialHintBubble(text: "\u{201C}Hello? Can you hear me?\u{201D}").offset(y: 354.5)
                TutorialMicMenu().offset(y: 414.5)
            case .speakerCheck:
                speaker
            case .voiceHello:
                TutorialHoldRow(keys: [.control, .option], pressed: pressed, trailing: "and say").offset(y: 237)
                TutorialHintBubble(text: "\u{201C}\(helloLine)\u{201D}").offset(y: 330.5)
                TutorialStatusLine(state: companion.voiceState, done: done).offset(y: 388)
            case .drawDemo:
                TutorialHoldRow(keys: [.control, .option], pressed: pressed, trailing: "and say").offset(y: 237)
                TutorialHintBubble(text: "\u{201C}Point at something fun on my screen\u{201D}").offset(y: 330.5)
                TutorialStatusLine(state: companion.voiceState, done: done).offset(y: 388)
                Button("or just show me") { model.drawDemo() }
                    .buttonStyle(.plain).font(.awan(12, .medium)).foregroundStyle(TutorialPalette.secondary.opacity(0.8))
                    .underline()
                    .offset(y: 420)
                    .disabled(done)
            case .drawToAsk:
                CircleDemo().frame(width: 300, height: 96).offset(y: 196)
                TutorialHoldRow(keys: [.control, .option], pressed: pressed, trailing: "and ask", size: .compact).offset(y: 312)
                TutorialHintBubble(text: "\u{201C}What's this one?\u{201D}").offset(y: 370)
                TutorialStatusLine(state: companion.voiceState, done: done).offset(y: 428)
            case .textMode:
                TutorialHoldRow(keys: [.control], pressed: companion.isTextComposerOpen, leading: "Double-tap", trailing: "to type").offset(y: 237)
                TutorialHintBubble(text: "Two quick taps", icon: "keyboard").offset(y: 330.5)
                TutorialStatusLine(text: done ? "there's your text box" : "ready when you are\u{2026}").offset(y: 388)
            case .emailDraft:
                SampleEmailCard().offset(y: 196)
                TutorialHoldRow(keys: [.control, .option], pressed: pressed, trailing: "and say", size: .compact).offset(y: 312)
                TutorialHintBubble(text: "\u{201C}Write a reply to this email\u{201D}").offset(y: 370)
                TutorialStatusLine(state: companion.voiceState, done: done).offset(y: 428)
            case .dictation:
                PracticeBox(text: $model.practiceText).offset(y: 196)
                TutorialHoldRow(keys: [.fn, .control], pressed: false, trailing: "and talk", size: .compact).offset(y: 312)
                TutorialStatusLine(text: done ? "typed it for you" : "ready when you are\u{2026}").offset(y: 388)
            case .finale:
                TutorialHoldRow(keys: [.control, .option], pressed: pressed, trailing: "anywhere").offset(y: 237)
                TutorialHintBubble(text: "\u{201C}Hey Awan, what's on my screen?\u{201D}").offset(y: 330.5)
            default:
                EmptyView()
            }
        }
        .frame(width: TutorialLayout.size.width, height: TutorialLayout.size.height, alignment: .top)
    }

    private var helloLine: String {
        if let name = AppState.shared.user?.firstName, !name.isEmpty {
            return "Hi Awan, I'm \(name.prefix(1).uppercased() + name.dropFirst())"
        }
        return "Hi Awan, it's me"
    }

    private var speaker: some View {
        ZStack(alignment: .top) {
            TutorialMicMeter(level: 0.55, lit: companion.voiceState == .responding).frame(width: 234, height: 26).offset(y: 260)
            if model.speakerMuted {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.slash.fill").foregroundStyle(Theme.warning)
                    Text("Your Mac is muted.").font(.awan(13, .medium)).foregroundStyle(Theme.text)
                    Button("Unmute") { model.unmute() }.buttonStyle(.gel(.bone, height: 26, padding: 12, fontSize: 12))
                }
                .padding(.horizontal, 14).frame(height: 40)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .offset(y: 354.5)
            } else {
                TutorialHintBubble(text: "Can you hear me? If you can, we're good to go.", icon: "speaker.wave.2.fill").offset(y: 354.5)
            }
            HStack(spacing: 10) {
                Button { model.sayTestLine() } label: { Label("Play it again", systemImage: "speaker.wave.2.fill") }
                    .buttonStyle(.gel(.dark, height: 34, padding: 16, fontSize: 13))
            }
            .offset(y: 417)
        }
    }
}

// MARK: - Mic meter (16 bars 9×26, gap 6)

struct TutorialMicMeter: View {
    var level: Float
    var lit: Bool = true
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: CommandLine.arguments.contains("--snapshot"))) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let n = 16
                let w: CGFloat = 9, gap: CGFloat = 6
                for i in 0 ..< n {
                    let r = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)
                    g.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .color(.white.opacity(0.12)))
                    guard lit, level > 0.05 else { continue }
                    // lit bars grow from the centre of the row, like a voice level
                    let centre = 1 - abs(Double(i) - Double(n - 1) / 2) / (Double(n) / 2)
                    let wobble = 0.65 + 0.35 * sin(t * 9 + Double(i) * 0.9)
                    let v = Double(level) * 1.35 * wobble - (1 - centre) * 0.9
                    guard v > 0.08 else { continue }
                    let h = max(w, size.height * CGFloat(min(1, 0.45 + v)))
                    let lr = CGRect(x: r.minX, y: (size.height - h) / 2, width: w, height: h)
                    g.fill(Path(roundedRect: lr, cornerRadius: w / 2), with: .color(Theme.lime))
                }
            }
        }
        .accessibilityLabel("Mic level")
    }
}

// MARK: - Peach hint bubble ("Say: …") with a pointer notch on top

struct TutorialHintBubble: View {
    var text: String
    var icon: String = "waveform"

    static let tail: CGFloat = 8
    static let bodyHeight: CGFloat = 36.5

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).font(.awan(13.5, .semibold)).lineLimit(1)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 19)
        .frame(height: Self.bodyHeight)
        .background(
            TutorialBubbleShape(tail: Self.tail)
                .fill(LinearGradient(stops: [
                    .init(color: TutorialPalette.peachTop, location: 0),
                    .init(color: TutorialPalette.peachMid, location: 0.45),
                    .init(color: TutorialPalette.peachMid, location: 0.7),
                    .init(color: TutorialPalette.peachBottom, location: 1),
                ], startPoint: .top, endPoint: .bottom))
                .padding(.top, -Self.tail)
        )
        .overlay(alignment: .top) {
            Capsule().fill(Color.white.opacity(0.55)).frame(height: 5).padding(.horizontal, 16).padding(.top, 2.5)
        }
        .overlay(
            TutorialBubbleShape(tail: Self.tail).stroke(TutorialPalette.peachRim.opacity(0.9), lineWidth: 1)
                .padding(.top, -Self.tail)
        )
        .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
        .padding(.top, Self.tail)
        .accessibilityLabel("Say: \(text)")
    }
}

/// Capsule with a rounded pointer centred on its top edge (`tail` tall).
struct TutorialBubbleShape: Shape {
    var tail: CGFloat
    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + tail, width: rect.width, height: rect.height - tail)
        let r = body.height / 2
        var p = Path()
        p.addRoundedRect(in: body, cornerSize: CGSize(width: r, height: r), style: .continuous)
        var t = Path()
        let cx = rect.midX, halfW: CGFloat = 9
        t.move(to: CGPoint(x: cx - halfW, y: body.minY + 0.5))
        t.addCurve(to: CGPoint(x: cx - 1.6, y: rect.minY + 1), control1: CGPoint(x: cx - 4.5, y: body.minY), control2: CGPoint(x: cx - 3.4, y: rect.minY + 2.6))
        t.addQuadCurve(to: CGPoint(x: cx + 1.6, y: rect.minY + 1), control: CGPoint(x: cx, y: rect.minY - 0.4))
        t.addCurve(to: CGPoint(x: cx + halfW, y: body.minY + 0.5), control1: CGPoint(x: cx + 3.4, y: rect.minY + 2.6), control2: CGPoint(x: cx + 4.5, y: body.minY))
        t.closeSubpath()
        return p.union(t)
    }
}

// MARK: - Keycaps ("Hold [⌃ control] [⌥ option] and say")

enum TutorialKey {
    case control, option, fn
    var symbol: String { switch self { case .control: return "control"; case .option: return "option"; case .fn: return "globe" } }
    var name: String { switch self { case .control: return "control"; case .option: return "option"; case .fn: return "fn" } }
}

struct TutorialHoldRow: View {
    enum CapSize { case regular, compact }
    var keys: [TutorialKey]
    var pressed: Bool
    var leading = "Hold"
    var trailing: String
    var size: CapSize = .regular

    /// Keycaps centred on the panel; "Hold" ends 10.5 pt before them and the trailing words start 9.5 pt after.
    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                TutorialKeyCap(key: k, pressed: pressed, side: size == .regular ? 84 : 46)
            }
        }
        .overlay(alignment: .leading) {
            Text(leading).font(.awan(13.5, .medium)).foregroundStyle(TutorialPalette.secondary)
                .fixedSize()
                .alignmentGuide(.leading) { d in d.width + 10.5 }
        }
        .overlay(alignment: .trailing) {
            Text(trailing).font(.awan(13.5, .medium)).foregroundStyle(TutorialPalette.secondary)
                .fixedSize()
                .alignmentGuide(.trailing) { d in -9.5 }
        }
    }
}

struct TutorialKeyCap: View {
    var key: TutorialKey
    var pressed: Bool
    var side: CGFloat = 84

    private var big: Bool { side > 60 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: big ? 17 : 11, style: .continuous)
                .fill(pressed
                      ? AnyShapeStyle(TutorialGel.fill)
                      : AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x353533), Color(hex: 0x252524), Color(hex: 0x222221)], startPoint: .top, endPoint: .bottom)))
            RoundedRectangle(cornerRadius: big ? 17 : 11, style: .continuous)
                .strokeBorder(pressed ? TutorialGel.rim : Color.white.opacity(0.10), lineWidth: pressed ? 1 : 0.5)
            if big {
                VStack(spacing: 0) {
                    Image(systemName: key.symbol).font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(pressed ? Theme.ink : Theme.text)
                        .frame(height: 26)
                        .padding(.top, 15)
                    Spacer(minLength: 0)
                    Text(key.name).font(.awan(11.5, .medium))
                        .foregroundStyle(pressed ? Theme.ink.opacity(0.7) : TutorialPalette.secondary)
                        .padding(.bottom, 16)
                }
            } else {
                VStack(spacing: 1) {
                    Image(systemName: key.symbol).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(pressed ? Theme.ink : Theme.text)
                    Text(key.name).font(.awan(9.5, .medium))
                        .foregroundStyle(pressed ? Theme.ink.opacity(0.7) : TutorialPalette.secondary)
                }
            }
        }
        .frame(width: big ? side : 58, height: side)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 5)
        .offset(y: pressed ? 1.5 : 0)
        .animation(Theme.snappy, value: pressed)
        .accessibilityLabel("\(key.name) key\(pressed ? ", pressed" : "")")
    }
}

// MARK: - Status line ("waiting for you…" / "listening…" / "thinking…" / "speaking…")

struct TutorialStatusLine: View {
    var text: String

    init(text: String) { self.text = text }

    init(state: VoiceState, done: Bool) {
        if done { text = "nice, that's it" } else {
            switch state {
            case .idle: text = "ready when you are\u{2026}"
            case .listening: text = "listening\u{2026}"
            case .processing: text = "thinking\u{2026}"
            case .responding: text = "talking\u{2026}"
            }
        }
    }

    var body: some View {
        Text(text).font(.awan(13, .medium)).foregroundStyle(TutorialPalette.secondary)
    }
}

// MARK: - Mic device menu (capsule-ish menu under the hint bubble)

struct TutorialMicMenu: View {
    @ObservedObject var prefs = Prefs.shared
    @Local private var devices: [MicDevice] = []

    private var currentName: String {
        if let d = devices.first(where: { $0.uid == prefs.microphoneUID }) { return d.name }
        if CommandLine.arguments.contains("--snapshot") { return "MacBook Pro Microphone" }
        return AVCaptureDevice.default(for: .audio)?.localizedName ?? "System microphone"
    }

    var body: some View {
        Menu {
            Button("System default") { prefs.microphoneUID = "" }
            Divider()
            ForEach(devices, id: \.uid) { d in
                Button(d.name) { prefs.microphoneUID = d.uid }
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "mic.fill").font(.system(size: 12.5, weight: .medium)).foregroundStyle(TutorialPalette.secondary)
                Text(currentName).font(.awan(14, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(TutorialPalette.secondary)
            }
            .padding(.horizontal, 18)
            .frame(height: 39)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.17), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear { if !CommandLine.arguments.contains("--snapshot") { devices = MicDevice.all() } }
    }
}

// MARK: - Sample content used by the steps

/// A stand-in email to reply to (the emailDraft step).
struct SampleEmailCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: 0xE9A23B)).frame(width: 22, height: 22)
                    .overlay(Text("M").font(.awan(11, .bold)).foregroundStyle(Theme.ink))
                Text("Mira, Kopi Senja").font(.awan(12.5, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text("9:41").font(.awan(11)).foregroundStyle(Theme.ink.opacity(0.5))
            }
            Text("Photos for the new menu?").font(.awan(12.5, .semibold)).foregroundStyle(Theme.ink)
            Text("Hi! Could you send the menu photos by Thursday? We'd love them up before the weekend rush. Thank you!")
                .font(.awan(12)).foregroundStyle(Theme.ink.opacity(0.75)).lineLimit(2)
        }
        .padding(12)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bone))
        .rotationEffect(.degrees(-1))
    }
}

/// A looping sketch of "hold the keys, circle something, ask".
struct CircleDemo: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2
            Canvas { g, size in
                // a mock window with three blocks
                let win = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                g.fill(Path(roundedRect: win, cornerRadius: 10), with: .color(Color.white.opacity(0.06)))
                for (i, w) in [0.5, 0.34, 0.42].enumerated() {
                    g.fill(Path(roundedRect: CGRect(x: 16, y: 16 + CGFloat(i) * 20, width: size.width * w, height: 10), cornerRadius: 5), with: .color(.white.opacity(0.12)))
                }
                let target = CGRect(x: size.width * 0.62, y: 18, width: 70, height: 48)
                g.fill(Path(roundedRect: target, cornerRadius: 8), with: .color(Color(hex: 0x5AA9FF).opacity(0.45)))
                // the painted loop grows with t
                let progress = min(1, t / 0.7)
                let c = CGPoint(x: target.midX, y: target.midY)
                var loop = Path()
                let steps = 60
                for k in 0 ... Int(Double(steps) * progress) {
                    let a = Double(k) / Double(steps) * .pi * 2.1 - .pi / 2
                    let p = CGPoint(x: c.x + cos(a) * 50, y: c.y + sin(a) * 34)
                    if k == 0 { loop.move(to: p) } else { loop.addLine(to: p) }
                }
                g.stroke(loop, with: .color(Theme.lime.opacity(0.85)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                // cursor at the head of the stroke
                let a = Double(steps) * progress / Double(steps) * .pi * 2.1 - .pi / 2
                let head = CGPoint(x: c.x + cos(a) * 50, y: c.y + sin(a) * 34)
                var cursor = Path()
                cursor.move(to: head)
                cursor.addLine(to: CGPoint(x: head.x, y: head.y + 14))
                cursor.addLine(to: CGPoint(x: head.x + 4, y: head.y + 10))
                cursor.addLine(to: CGPoint(x: head.x + 10, y: head.y + 10))
                cursor.closeSubpath()
                g.fill(cursor, with: .color(.white))
                g.stroke(cursor, with: .color(.black), lineWidth: 1)
            }
        }
    }
}

/// The practice text box for the dictation step.
struct PracticeBox: View {
    @Binding var text: String
    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Your words show up here\u{2026}")
                    .font(.awan(14)).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.awan(14))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 9).padding(.vertical, 8)
        }
        .frame(width: 400, height: 96)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.strokeStrong, lineWidth: 1))
    }
}

// MARK: - Line pitch

extension View {
    /// Exact baseline-to-baseline distance (Instrument Sans' natural line height is ≈1.27× its size, much looser than
    /// the reference's system font). macOS 26+ uses `lineHeight(.exact)`; older systems fall back to line spacing.
    @ViewBuilder func linePitch(_ points: CGFloat, fontSize: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.lineHeight(.exact(points: points))
        } else {
            self.lineSpacing(max(0, points - fontSize * 1.27))
        }
    }
}
