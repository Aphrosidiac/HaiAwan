import SwiftUI
import CoreText

/// Snapshot registrations for the onboarding + dictation area ("onboarding-*", "dictation-*").
extension Snapshots {
    static var onboardingNames: [String] {
        ["onboarding-intro", "onboarding-signin", "onboarding-signin-check", "onboarding-permissions",
         "onboarding-tutorial-mic", "onboarding-tutorial-mic-active", "onboarding-tutorial-speaker", "onboarding-tutorial-voice",
         "onboarding-tutorial-voice-listening", "onboarding-tutorial-draw", "onboarding-tutorial-circle", "onboarding-tutorial-text",
         "onboarding-tutorial-email", "onboarding-tutorial-dictation", "onboarding-tutorial-finale", "onboarding-plans", "onboarding-interview", "onboarding-interview-discovery", "onboarding-squad",
         "onboarding-squad-loading", "onboarding-squad-error", "onboarding-tour",
         "dictation-pill", "dictation-pill-handsfree", "dictation-clipboard", "dictation-learned", "dictation-limit"]
    }

    /// Unbundled runs have no Fonts in Bundle.main; register the repo's copies so snapshots show real type.
    private static func registerRepoFonts() {
        let dir = Paths.resources.appendingPathComponent("Fonts")
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func onboarding(_ name: String) -> AnyView? {
        guard onboardingNames.contains(name) else { return nil }
        registerRepoFonts()
        let s = AppState.shared
        func panel(_ configure: (OnboardingModel) -> Void) -> AnyView {
            let m = OnboardingModel()
            configure(m)
            return AnyView(
                ZStack { Color(hex: 0x3A3F4A); OnboardingRootView(model: m).shadow(color: .black.opacity(0.5), radius: 30, y: 12) }
            )
        }
        /// Tutorial panel / plan chooser: composited flat on #808080 at the window's own size, like the reference
        /// captures (render with `--snapshot <name> out.png 500 571`, or `800 543` for onboarding-plans).
        func window(_ configure: (OnboardingModel) -> Void) -> AnyView {
            let m = OnboardingModel()
            configure(m)
            let size = OnboardingLayout.size(for: m.stage)
            return AnyView(
                ZStack(alignment: .topLeading) {
                    Color(hex: 0x808080)
                    OnboardingRootView(model: m).frame(width: size.width, height: size.height)
                }
            )
        }
        let tutorial = OnboardingStage.tutorial
        switch name {
        case "onboarding-intro":
            return panel { $0.stage = .intro }
        case "onboarding-signin":
            s.signInState = .signedOut
            return panel { $0.stage = .signIn; $0.email = "fakhrul@ffdev.studio" }
        case "onboarding-signin-check":
            s.signInState = .waitingForLink(email: "fakhrul@ffdev.studio", devLink: "http://127.0.0.1:8787/auth/verify?code=demo")
            return panel { $0.stage = .signIn }
        case "onboarding-permissions":
            return panel {
                $0.stage = .permissions
                $0.permissionIndex = 2
                $0.permissionStatus = [.microphone: .granted, .speech: .granted, .accessibility: .waiting, .screenRecording: .notDetermined]
            }
        case "onboarding-tutorial-mic":
            return window { $0.stage = .micCheck; $0.micLevel = 0 }
        case "onboarding-tutorial-mic-active":
            return window { $0.stage = .micCheck; $0.micLevel = 0.72; $0.completed = [.micCheck] }
        case "onboarding-tutorial-speaker":
            return window { $0.stage = .speakerCheck; $0.completed = [.micCheck] }
        case "onboarding-tutorial-voice":
            s.companion.voiceState = .idle
            return window { $0.stage = .voiceHello; $0.completed = [.micCheck, .speakerCheck] }
        case "onboarding-tutorial-voice-listening":
            s.companion.voiceState = .listening
            return window { $0.stage = .voiceHello; $0.completed = [.micCheck, .speakerCheck] }
        case "onboarding-tutorial-draw":
            return window { $0.stage = .drawDemo; $0.completed = Set(tutorial.prefix(4)) }
        case "onboarding-tutorial-circle":
            return window { $0.stage = .drawToAsk; $0.completed = Set(tutorial.prefix(5)) }
        case "onboarding-tutorial-text":
            return window { $0.stage = .textMode; $0.completed = Set(tutorial.prefix(6)) }
        case "onboarding-tutorial-email":
            return window { $0.stage = .emailDraft; $0.completed = Set(tutorial.prefix(7)) }
        case "onboarding-tutorial-dictation":
            return window {
                $0.stage = .dictation
                $0.practiceText = "Hey Mira, the menu photos will be with you on Wednesday. I'll send the full set in one folder."
                $0.completed = Set(tutorial.prefix(9))
            }
        case "onboarding-tutorial-finale":
            return window { $0.stage = .finale; $0.completed = Set(tutorial.prefix(9)) }
        case "onboarding-plans":
            return window { $0.stage = .plans }
        case "onboarding-interview":
            return panel {
                $0.stage = .interview
                $0.questionIndex = 1
                $0.answers = ["A small specialty coffee brand in KL, plus client websites on the side.", "", "", ""]
                $0.answers[1] = "Get the online shop live and land our first 100 subscribers"
            }
        case "onboarding-interview-discovery":
            return panel { $0.stage = .interview; $0.questionIndex = 4; $0.discoveryChannel = "Instagram" }
        case "onboarding-squad":
            return panel { $0.stage = .squad; $0.cast = .ready(goal: "You want Kopi Senja's online shop live and 100 subscribers by December, without dropping client work.", awans: demoSquad) }
        case "onboarding-squad-loading":
            return panel { $0.stage = .squad; $0.cast = .loading }
        case "onboarding-squad-error":
            return panel { $0.stage = .squad; $0.cast = .failed("Awan's server said 502: provider_error:402: insufficient credit") }
        case "onboarding-tour":
            s.homePage = .home
            return AnyView(ZStack {
                HomeRootView().environmentObject(s).environmentObject(s.agents).environmentObject(s.companion).environmentObject(RoutineScheduler.shared).environmentObject(Prefs.shared)
                GeometryReader { g in HomeTourView(size: g.size) {} }
            })
        case "dictation-pill":
            DictationManager.shared.installDemo(.live, partial: "so the plan for Thursday is we shoot the new menu in the morning and", handsFree: false)
            return pill()
        case "dictation-pill-handsfree":
            DictationManager.shared.installDemo(.live, partial: "okay hands free now, reply to Mira and say", handsFree: true)
            return pill()
        case "dictation-clipboard":
            DictationManager.shared.installDemo(.clipboard("Copied. Paste with ⌘V"), partial: "", handsFree: false)
            return pill()
        case "dictation-learned":
            DictationManager.shared.installDemo(.learned("Senja"), partial: "", handsFree: false)
            return pill()
        case "dictation-limit":
            DictationManager.shared.installDemo(.limit, partial: "", handsFree: false)
            return pill()
        default:
            return nil
        }
    }

    private static func pill() -> AnyView {
        let n = NotchController.shared
        n.mode = .surface(.dictation)
        let size = n.sizeFor(.surface(.dictation))
        return AnyView(
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(hex: 0x6B4FD8), Color(hex: 0x2B6CB0)], startPoint: .topLeading, endPoint: .bottomTrailing)
                NotchRootView().environmentObject(AppState.shared).environmentObject(n)
                    .frame(width: size.width, height: size.height)
            }
        )
    }

    static let demoSquad: [AwanSpecDTO] = [
        AwanSpecDTO(slug: "shop-builder", name: "Shop Builder", roleText: "Store Launcher", oneLiner: "Gets the Kopi Senja shop live: product pages, photos, checkout and a launch checklist.",
                    introMessages: [], suggestedAsks: [], baseHue: 0.12, routine: nil, suggestion: nil),
        AwanSpecDTO(slug: "subscriber-scout", name: "Subscriber Scout", roleText: "Growth Researcher", oneLiner: "Finds where KL coffee people hang out online and drafts posts that bring them in.",
                    introMessages: [], suggestedAsks: [], baseHue: 0.58, routine: RoutineSpec(everyMinutes: 1440, title: "Daily leads"), suggestion: nil),
        AwanSpecDTO(slug: "client-desk", name: "Client Desk", roleText: "Project Keeper", oneLiner: "Keeps your client sites on track: replies, invoices and a Monday status note.",
                    introMessages: [], suggestedAsks: [], baseHue: 0.82, routine: nil, suggestion: nil),
    ]
}
