import SwiftUI
import AppKit

// MARK: - Root + chrome

/// Window size per stage: the classic 720×480 card, the 500×571 tutorial panel, the 800×543 plan chooser.
enum OnboardingLayout {
    static let card = CGSize(width: 720, height: 480)
    static func size(for stage: OnboardingStage) -> CGSize {
        if stage.usesTutorialPanel { return TutorialLayout.size }
        if stage == .plans { return PlanChooserLayout.window }
        return card
    }
}

struct OnboardingRootView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var state = AppState.shared
    var close: () -> Void = {}

    var body: some View {
        ZStack {
            if model.stage.usesTutorialPanel {
                TutorialPanelView(model: model, close: close)
            } else if model.stage == .plans {
                PlanChooserView(model: model)
            } else {
                card
            }
            if let toast = state.toast {
                VStack {
                    Spacer()
                    Text(toast).font(.awan(12.5, .medium)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(Capsule().fill(Theme.bone))
                        .padding(.bottom, 18)
                }
                .transition(.opacity)
            }
        }
        .frame(width: OnboardingLayout.size(for: model.stage).width, height: OnboardingLayout.size(for: model.stage).height)
        .preferredColorScheme(.dark)
    }

    private var card: some View {
        ZStack {
            OnboardingBackdrop(stage: model.stage)
            VStack(spacing: 0) {
                topBar
                ZStack {
                    stageView
                        .id(model.stage)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity.combined(with: .offset(x: -24))))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: OnboardingLayout.card.width, height: OnboardingLayout.card.height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
    }

    private var topBar: some View {
        ZStack {
            HStack(spacing: 7) {
                AwanGlyph().frame(width: 20)
                Text("Awan").font(.awan(13, .semibold)).foregroundStyle(Theme.textSecondary)
                Spacer()
                CircleIconButton(systemName: "xmark", size: 24, help: "Finish later", action: close)
            }
            if model.stage == .interview {
                TutorialDots(current: model.stage)
            } else if model.stage == .permissions {
                Text("SETUP").font(.awan(10.5, .semibold)).tracking(1).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
    }

    @ViewBuilder private var stageView: some View {
        switch model.stage {
        case .intro: IntroStepView(model: model)
        case .skills: SkillPickerStepView(model: model)
        case .signIn: SignInStepView(model: model)
        case .permissions: PermissionsStepView(model: model)
        case .interview: InterviewStepView(model: model)
        case .squad: SquadStepView(model: model)
        default: EmptyView()
        }
    }
}

/// Ink with a soft sky glow behind the mascot (the only colour on the page besides one lime action).
struct OnboardingBackdrop: View {
    var stage: OnboardingStage
    var body: some View {
        ZStack {
            Theme.window
            RadialGradient(colors: [Color(hex: 0x5AA9FF).opacity(stage == .intro ? 0.20 : 0.11), .clear], center: .init(x: 0.5, y: 0.18), startRadius: 0, endRadius: 360)
            // faint dot grid, like the site's hero
            Canvas { ctx, size in
                let step: CGFloat = 22
                var y: CGFloat = step / 2
                while y < size.height {
                    var x: CGFloat = step / 2
                    while x < size.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(.white.opacity(0.045)))
                        x += step
                    }
                    y += step
                }
            }
        }
    }
}

/// Big display line in Instrument Serif, like the brand's headlines.
struct OnboardingTitle: View {
    let text: String
    var size: CGFloat = 34
    init(_ text: String, size: CGFloat = 34) { self.text = text; self.size = size }
    var body: some View {
        Text(text).font(.awanSerif(size)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
    }
}

struct OnboardingSubtitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.awan(14)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            .lineSpacing(2).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 480)
    }
}

struct PrivacyLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold))
            Text(text).font(.awan(11.5))
        }
        .foregroundStyle(Theme.textTertiary)
    }
}

/// The mascot pops out of nothing with a bounce (the "hatch").
struct HatchingMascot: View {
    var size: CGFloat = 140
    var mood: CharacterMood = .happy
    var animate = true
    @Local private var hatched = false

    var body: some View {
        CloudCreature(appearance: .mascot, mood: mood, showPaws: true)
            .frame(width: size)
            .scaleEffect(hatched ? 1 : 0.2, anchor: .bottom)
            .opacity(hatched ? 1 : 0)
            .rotationEffect(.degrees(hatched ? 0 : -8))
            .onAppear {
                guard animate else { hatched = true; return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.52).delay(0.12)) { hatched = true }
            }
    }
}

// MARK: - 1. Intro

struct IntroVoice: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let symbol: String
    let line: String
    static let showcase = [
        IntroVoice(id: "cedar", name: "Cedar", subtitle: "Warm, easy", symbol: "tree.fill", line: "hi, i'm awan. i'll keep you company while you work."),
        IntroVoice(id: "marin", name: "Marin", subtitle: "Bright, clear", symbol: "water.waves", line: "hey! i'm awan. show me what you're making."),
        IntroVoice(id: "verse", name: "Verse", subtitle: "Lively", symbol: "text.bubble.fill", line: "hello! i'm awan, and i'm ready when you are."),
    ]
}

struct IntroStepView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var prefs = Prefs.shared
    var animate = !CommandLine.arguments.contains("--snapshot")

    var body: some View {
        VStack(spacing: 0) {
            HatchingMascot(size: 132, animate: animate)
                .padding(.top, 4)
            OnboardingTitle("Hi, I'm Awan.", size: 40)
                .padding(.top, 14)
            OnboardingSubtitle("A friend that lives at the top of your screen. Hold two keys, talk, and I'll help, or send one of your Awans to do the work.")
                .padding(.top, 8)
            SectionLabel("Pick my voice").padding(.top, 22)
            HStack(spacing: 10) {
                ForEach(IntroVoice.showcase) { v in
                    VoiceCard(voice: v, selected: prefs.voiceID == v.id) {
                        prefs.voiceID = v.id
                        CompanionEngine.shared.announce(v.line)
                    }
                }
            }
            .padding(.top, 10)
            Spacer(minLength: 12)
            Button("Get started") { model.advance() }
                .buttonStyle(.gel(.lime, height: 40, padding: 30, fontSize: 14.5))
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 28)
        }
        .padding(.horizontal, 40)
    }
}

struct VoiceCard: View {
    let voice: IntroVoice
    let selected: Bool
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(selected ? Theme.lime : Theme.cardRaised)
                    Image(systemName: voice.symbol).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Theme.ink : Theme.textSecondary)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(voice.name).font(.awan(13.5, .semibold)).foregroundStyle(Theme.text)
                    Text(voice.subtitle).font(.awan(11.5)).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(hovering ? Theme.text : Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(width: 176, height: 54)
            .background(RoundedRectangle(cornerRadius: 14).fill(hovering ? Theme.cardRaised : Theme.card.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Theme.lime.opacity(0.8) : Theme.stroke, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 2. Sign in

struct SignInStepView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var state = AppState.shared

    var body: some View {
        VStack(spacing: 0) {
            switch state.signInState {
            case let .waitingForLink(email, devLink):
                checkEmail(email: email, devLink: devLink)
            default:
                form
            }
            Spacer(minLength: 10)
            PrivacyLine("Awan only looks at your screen when you hold your shortcut. Screenshots aren't stored.")
                .padding(.bottom, 22)
        }
        .padding(.horizontal, 40)
    }

    private var form: some View {
        VStack(spacing: 0) {
            HatchingMascot(size: 86, mood: .idle, animate: false).padding(.top, 10)
            OnboardingTitle("Let's get you signed in", size: 32).padding(.top, 12)
            OnboardingSubtitle("So your Awans, chats and plan follow you around.").padding(.top, 6)
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.fill").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    TextField("you@example.com", text: $model.email)
                        .textFieldStyle(.plain)
                        .font(.awan(14))
                        .foregroundStyle(Theme.text)
                        .onSubmit { model.sendMagicLink() }
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke, lineWidth: 1))

                Button(model.sending ? "Sending…" : "Email me a sign-in link") { model.sendMagicLink() }
                    .buttonStyle(.gel(.lime, height: 40, fullWidth: true, fontSize: 14))
                    .disabled(model.sending || model.email.isEmpty)

                HStack(spacing: 10) {
                    Rectangle().fill(Theme.stroke).frame(height: 1)
                    Text("or").font(.awan(11.5)).foregroundStyle(Theme.textTertiary)
                    Rectangle().fill(Theme.stroke).frame(height: 1)
                }
                .padding(.vertical, 2)

                Button { model.continueWithGoogle() } label: {
                    HStack(spacing: 8) {
                        Text("G").font(.system(size: 14, weight: .heavy, design: .rounded))
                        Text("Continue with Google")
                    }
                }
                .buttonStyle(.gel(.bone, height: 40, fullWidth: true, fontSize: 14))
            }
            .frame(width: 340)
            .padding(.top, 22)
        }
    }

    private func checkEmail(email: String, devLink: String?) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Theme.card).frame(width: 84, height: 84)
                Image(systemName: "envelope.open.fill").font(.system(size: 32)).foregroundStyle(Theme.bone)
            }
            .padding(.top, 26)
            OnboardingTitle("Check your email", size: 32).padding(.top, 16)
            OnboardingSubtitle("I sent a sign-in link to \(email). Open it on this Mac and you'll land right back here.").padding(.top, 6)
            HStack(spacing: 10) {
                if let devLink, let url = URL(string: devLink) {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open sign-in link (dev)", systemImage: "hammer.fill") }
                        .buttonStyle(.gel(.dark, height: 34, padding: 14, fontSize: 12.5))
                }
                Button("Use a different email") { state.signInState = .signedOut }
                    .buttonStyle(.gel(.dark, height: 34, padding: 14, fontSize: 12.5))
            }
            .padding(.top, 22)
            HStack(spacing: 8) {
                TypingDots(color: Theme.textTertiary, dot: 4)
                Text("Waiting for you to click the link").font(.awan(12)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.top, 18)
        }
    }
}
