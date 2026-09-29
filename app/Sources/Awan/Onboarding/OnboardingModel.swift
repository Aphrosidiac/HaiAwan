import AppKit
import SwiftUI
import Combine

/// Every screen of onboarding, in order. The tutorial runs micCheck…finale with the interview
/// folded in after the first hello (like the reference), so the squad is ready by the finale.
enum OnboardingStage: String, CaseIterable, Hashable {
    case intro, skills, signIn, permissions
    case micCheck, speakerCheck, voiceHello, interview, drawDemo, drawToAsk, textMode, emailDraft, dictation, finale
    case plans, squad

    static let tutorial: [OnboardingStage] = [.micCheck, .speakerCheck, .voiceHello, .interview, .drawDemo, .drawToAsk, .textMode, .emailDraft, .dictation, .finale]
    var isTutorial: Bool { Self.tutorial.contains(self) }
}

/// The interview questions (the last one is always about agents, like the reference).
enum InterviewScript {
    static let opener = "So, I'm Awan. I'm here to help you start a business, ship that side project, or just get through the job. Four quick questions."
    static let questions = [
        "What are you working on these days?",
        "What's the goal for the next few months?",
        "Which apps do you live in?",
        "Have you used AI agents before?",
    ]
    static let placeholders = [
        "A coffee brand, a thesis, a client site…",
        "Launch, get 100 customers, finish the draft…",
        "Figma, Gmail, Notion, Excel…",
        "Never, a little, every day…",
    ]
    static let channels = ["Instagram", "TikTok", "X", "YouTube", "A friend", "Search", "Other"]
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var stage: OnboardingStage = .intro
    @Published var isReplay = false

    // Skill picker (before sign-in)
    @Published var skillPicks: [String] = []

    // Sign in
    @Published var email = ""
    @Published var sending = false

    // Permissions
    @Published var permissionIndex = 0
    @Published var permissionStatus: [PermissionKind: PermissionStatus] = [:]
    private var waitingForSettings: Set<PermissionKind> = []

    // Tutorial
    @Published var completed: Set<OnboardingStage> = []
    @Published var micLevel: Float = 0
    @Published var heardFrames = 0
    @Published var practiceText = ""
    @Published var speakerMuted = false
    @Published var tourMusicOn = true
    /// The plan chooser was shown during onboarding (so the post-tour paywall is skipped).
    private(set) var plansShown = false
    private var sawListening = false
    private var sawThinking = false
    private var micMonitor: SpeechCapture?

    // Interview
    @Published var questionIndex = 0          // 0…3 questions, 4 = discovery channel
    @Published var answers = Array(repeating: "", count: InterviewScript.questions.count)
    @Published var discoveryChannel: String?
    @Published var recordingAnswer = false
    @Published var transcribing = false
    private var answerCapture: SpeechCapture?
    private var answerPrefix = ""

    // Squad
    enum CastState: Equatable {
        case idle, loading, skipped
        case ready(goal: String, awans: [AwanSpecDTO])
        case failed(String)
        static func == (a: CastState, b: CastState) -> Bool {
            switch (a, b) {
            case (.idle, .idle), (.loading, .loading), (.skipped, .skipped): return true
            case let (.ready(g1, a1), .ready(g2, a2)): return g1 == g2 && a1.map(\.slug) == a2.map(\.slug)
            case let (.failed(x), .failed(y)): return x == y
            default: return false
            }
        }
    }
    @Published var cast: CastState = .idle
    @Published var hatching = false

    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: Timer?
    private var autoAdvance: Task<Void, Never>?
    var onFinish: ((_ squad: [AwanSpecDTO]) -> Void)?
    var onClose: (() -> Void)?

    private var snapshot: Bool { CommandLine.arguments.contains("--snapshot") }

    init() {
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        NotificationCenter.default.publisher(for: .awanDidSignIn)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.didSignIn() }
            .store(in: &cancellables)
        CompanionEngine.shared.$voiceState
            .receive(on: RunLoop.main)
            .sink { [weak self] s in self?.voiceStateChanged(s) }
            .store(in: &cancellables)
        CompanionEngine.shared.$isTextComposerOpen
            .receive(on: RunLoop.main)
            .sink { [weak self] open in if open, self?.stage == .textMode { self?.succeed(.textMode) } }
            .store(in: &cancellables)
        DictationManager.shared.$lastInsertedText
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] text in if text != nil, self?.stage == .dictation { self?.succeed(.dictation) } }
            .store(in: &cancellables)
    }

    // MARK: - Navigation

    func go(_ next: OnboardingStage) {
        leave(stage)
        autoAdvance?.cancel()
        withAnimation(Theme.spring) { stage = next }
        enter(next)
    }

    /// The stage after `stage`, skipping permissions/sign-in that are already done.
    func advance() {
        switch stage {
        case .intro:
            // Returning users who already finished onboarding skip the skill picker.
            if Prefs.shared.onboardingCompleted && !isReplay {
                if AppState.shared.signInState != .signedIn { go(.signIn) } else { afterSignIn() }
            } else {
                go(.skills)
            }
        case .skills:
            commitSkillPicks()
            if AppState.shared.signInState != .signedIn { go(.signIn) } else { afterSignIn() }
        case .signIn:
            afterSignIn()
        case .permissions:
            go(.micCheck)
        case .finale:
            go(.plans)
        case .plans:
            go(.squad)
        case .squad:
            break
        default:
            let t = OnboardingStage.tutorial
            if let i = t.firstIndex(of: stage), i + 1 < t.count { go(t[i + 1]) }
        }
    }

    private func afterSignIn() {
        // Signed-out returning user who already finished onboarding: just close.
        if Prefs.shared.onboardingCompleted && !isReplay {
            onClose?()
            AppState.shared.openHome()
            return
        }
        refreshPermissions()
        if PermissionKind.allCases.contains(where: { permissionStatus[$0] != .granted }) {
            go(.permissions)
        } else {
            go(.micCheck)
        }
    }

    // MARK: - Skill picks ("What should Awan be good at?")

    /// Toggle a pick; at most three (the Skills page's slot count). Returns false when full.
    @discardableResult
    func toggleSkillPick(_ slug: String) -> Bool {
        if let i = skillPicks.firstIndex(of: slug) {
            skillPicks.remove(at: i)
            if !snapshot { Sounds.play(.skillDown, volume: 0.4) }
            return true
        }
        guard skillPicks.count < SkillsStore.maxActive else { return false }
        skillPicks.append(slug)
        if !snapshot { Sounds.play(.skillUp, volume: 0.4) }
        return true
    }

    /// Picks are kept until there's an account, then switched on (SkillsStore listens for sign-in).
    private func commitSkillPicks() {
        guard !snapshot, !skillPicks.isEmpty else { return }
        SkillsStore.shared.pendingPicks = skillPicks
        if AppState.shared.signInState == .signedIn { Task { await SkillsStore.shared.applyPendingPicks() } }
    }

    private func didSignIn() {
        if stage == .skills { commitSkillPicks() }
        if stage == .signIn || stage == .intro || stage == .skills { afterSignIn() }
    }

    private func enter(_ s: OnboardingStage) {
        sawListening = false
        sawThinking = false
        if !snapshot {
            if s.usesTutorialPanel && s != .micCheck && tourMusicOn { TourMusic.shared.play() } else if !s.usesTutorialPanel { TourMusic.shared.stop() }
        }
        switch s {
        case .intro:
            if !snapshot { Sounds.play(.reveal) }
        case .permissions:
            refreshPermissions()
            permissionIndex = PermissionKind.allCases.firstIndex { permissionStatus[$0] != .granted } ?? 0
            startPolling()
        case .micCheck:
            heardFrames = 0
            startMicMonitor()
        case .speakerCheck:
            speakerMuted = SystemAudio.isMuted
            sayTestLine()
        case .interview:
            questionIndex = 0
            if !snapshot { CompanionEngine.shared.announce(InterviewScript.opener.lowercased() + " " + InterviewScript.questions[0].lowercased()) }
        case .plans:
            plansShown = true
            TourMusic.shared.stop()
        case .squad:
            if cast == .idle { cast = .skipped }
        default:
            break
        }
    }

    private func leave(_ s: OnboardingStage) {
        switch s {
        case .permissions:
            pollTimer?.invalidate(); pollTimer = nil
            PermissionGuidePanel.shared.hide()
        case .micCheck:
            stopMicMonitor()
        case .interview:
            if recordingAnswer { cancelAnswerRecording() }
        default: break
        }
    }

    func succeed(_ s: OnboardingStage) {
        guard stage == s, !completed.contains(s) else { return }
        completed.insert(s)
        Sounds.play(.thumbsUp, volume: 0.4)
        // No auto-advance: the Continue gel lights up and the user moves on (like the reference).
    }

    func skip() { advance() }

    // MARK: - Tutorial panel chrome

    /// Continue is live once the step has been done (speaker check and the finale are self-reported).
    func isSatisfied(_ s: OnboardingStage) -> Bool { Self.isSatisfied(s, completed: completed) }

    nonisolated static func isSatisfied(_ s: OnboardingStage, completed: Set<OnboardingStage>) -> Bool {
        switch s {
        case .speakerCheck, .finale: return true
        default: return completed.contains(s)
        }
    }

    /// ‹ Back: the previous panel step (the interview is skipped; it has its own Back).
    func back() {
        if let prev = stage.previousPanelStage { go(prev) }
    }

    /// "Skip demo": straight to the plan chooser (then the squad).
    func skipDemo() {
        if !completed.contains(.interview), cast == .idle { cast = .skipped }
        go(.plans)
    }

    func toggleTourMusic() {
        tourMusicOn.toggle()
        guard !snapshot else { return }
        if tourMusicOn { TourMusic.shared.play() } else { TourMusic.shared.stop() }
    }

    // MARK: - Plan chooser

    func choosePlan(_ tier: String?, yearly: Bool) {
        guard let tier else { advance(); return }
        Task {
            await AppState.shared.checkout(plan: tier, yearly: yearly)
            advance()
        }
    }

    // MARK: - Sign in

    func sendMagicLink() {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard e.contains("@"), e.contains(".") else { AppState.shared.show("That email doesn't look right."); return }
        sending = true
        Task {
            await AppState.shared.requestMagicLink(email: e)
            sending = false
        }
    }

    func continueWithGoogle() {
        var c = URLComponents(url: APIClient.shared.baseURL.appendingPathComponent("auth/google/start"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "redirect", value: "awan://auth")]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    // MARK: - Permissions

    func refreshPermissions() {
        for k in PermissionKind.allCases {
            var s = PermissionProbe.status(k)
            if s != .granted, waitingForSettings.contains(k) { s = .waiting }
            permissionStatus[k] = s
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollTick() }
        }
    }

    private func pollTick() {
        guard stage == .permissions else { return }
        let kind = PermissionKind.allCases[permissionIndex]
        let before = permissionStatus[kind]
        refreshPermissions()
        if before != .granted, permissionStatus[kind] == .granted {
            waitingForSettings.remove(kind)
            PermissionGuidePanel.shared.hide()
            OnboardingController.shared.comeBack()
            Sounds.play(.thumbsUp, volume: 0.4)
            autoAdvance = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.9))
                guard !Task.isCancelled else { return }
                self?.nextPermission()
            }
        }
    }

    func allow(_ kind: PermissionKind) {
        PermissionProbe.request(kind) { [weak self] in
            guard let self else { return }
            if kind.usesSettingsList {
                self.waitingForSettings.insert(kind)
                PermissionProbe.openSettings(kind)
                PermissionGuidePanel.shared.show(for: kind)
            }
            self.refreshPermissions()
        }
    }

    func openSettings(_ kind: PermissionKind) {
        waitingForSettings.insert(kind)
        PermissionProbe.openSettings(kind)
        if kind.usesSettingsList { PermissionGuidePanel.shared.show(for: kind) }
        refreshPermissions()
    }

    func nextPermission() {
        PermissionGuidePanel.shared.hide()
        let all = PermissionKind.allCases
        if let next = all.indices.first(where: { $0 > permissionIndex && permissionStatus[all[$0]] != .granted }) {
            withAnimation(Theme.spring) { permissionIndex = next }
        } else {
            advance()
        }
    }

    // MARK: - Mic check

    private func startMicMonitor() {
        guard !snapshot else { return }
        switch SpeechCapture.micStatus {
        case .notDetermined:
            PermissionProbe.request(.microphone) { [weak self] in self?.startMicMonitor() }
            return
        case .authorized: break
        default: return
        }
        let cap = SpeechCapture()
        cap.onLevel = { [weak self] l in
            guard let self else { return }
            self.micLevel = l
            if l > 0.42 { self.heardFrames += 1 }
            if self.heardFrames > 12 { self.succeed(.micCheck) }
        }
        do {
            try cap.start(locale: nil, recordTo: nil, recognize: false)
            micMonitor = cap
        } catch {
            Log.error("mic check failed: \(error.localizedDescription)")
        }
    }

    private func stopMicMonitor() {
        micMonitor?.cancel()
        micMonitor = nil
        micLevel = 0
    }

    // MARK: - Speaker check

    func sayTestLine() {
        guard !snapshot else { return }
        CompanionEngine.shared.announce("can you hear me? if you can, we're good to go.")
    }

    func unmute() {
        SystemAudio.unmute()
        speakerMuted = SystemAudio.isMuted
        sayTestLine()
    }

    // MARK: - Voice steps (voiceHello, drawToAsk, emailDraft)

    private func voiceStateChanged(_ s: VoiceState) {
        guard [.voiceHello, .drawDemo, .drawToAsk, .emailDraft].contains(stage) else { return }
        switch s {
        case .listening: sawListening = true
        case .processing, .responding: if sawListening { sawThinking = true }
        case .idle: if sawListening && sawThinking { succeed(stage) }
        }
    }

    func drawDemo() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let points = [
            ScreenPoint(point: CGPoint(x: f.midX + f.width * 0.18, y: f.midY + f.height * 0.16), label: "ooh, what's this?"),
            ScreenPoint(point: CGPoint(x: f.midX - f.width * 0.2, y: f.midY - f.height * 0.1), label: "and this bit!"),
        ]
        CursorOverlayController.shared.fly(to: points)
        CompanionEngine.shared.announce("see? i can fly over and point at things on your screen.")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            self?.succeed(.drawDemo)
        }
    }

    // MARK: - Interview

    var currentQuestion: String { InterviewScript.questions[min(questionIndex, InterviewScript.questions.count - 1)] }

    func nextQuestion() {
        if questionIndex < InterviewScript.questions.count - 1 {
            withAnimation(Theme.spring) { questionIndex += 1 }
            Sounds.play(.question, volume: 0.35)
            CompanionEngine.shared.announce(currentQuestion.lowercased())
        } else if questionIndex == InterviewScript.questions.count - 1 {
            withAnimation(Theme.spring) { questionIndex += 1 }   // discovery channel
        } else {
            finishInterview()
        }
    }

    func previousQuestion() {
        guard questionIndex > 0 else { return }
        withAnimation(Theme.spring) { questionIndex -= 1 }
    }

    func skipInterview() {
        cast = .skipped
        advance()
    }

    func finishInterview() {
        if let channel = discoveryChannel {
            Task { _ = try? await APIClient.shared.sendRaw("v1/me", method: "PATCH", body: ["discoveryChannel": channel]) }
        }
        requestCast()
        completed.insert(.interview)
        advance()
    }

    func requestCast() {
        var payload: [String: String] = [:]
        for (i, q) in InterviewScript.questions.enumerated() {
            let a = answers[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if !a.isEmpty { payload[q] = a }
        }
        guard !payload.isEmpty else { cast = .skipped; return }
        cast = .loading
        struct R: Decodable { var goalSummary: String; var awans: [AwanSpecDTO] }
        Task {
            do {
                let r: R = try await APIClient.shared.send("v1/onboarding/cast", method: "POST", body: ["answers": payload])
                cast = r.awans.isEmpty ? .failed("I couldn't come up with a squad this time.") : .ready(goal: r.goalSummary, awans: r.awans)
            } catch {
                cast = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Hold the mic button to answer out loud.
    func beginAnswerRecording() {
        guard !recordingAnswer else { return }
        if SpeechCapture.micStatus == .notDetermined {
            PermissionProbe.request(.microphone) { }
            return
        }
        guard SpeechCapture.micStatus == .authorized else {
            AppState.shared.show("Turn on the microphone to answer out loud, or just type.")
            return
        }
        let cap = SpeechCapture()
        let index = questionIndex
        let prefix = answers[index].isEmpty ? "" : answers[index] + " "
        answerPrefix = prefix
        cap.onPartial = { [weak self] t in self?.answers[index] = prefix + t }
        cap.onLevel = { [weak self] l in self?.micLevel = l }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("awan-answer-\(UUID().uuidString).wav")
        do {
            try cap.start(locale: nil, contextualStrings: Prefs.shared.dictionary, recordTo: url)
            answerCapture = cap
            recordingAnswer = true
            Sounds.play(.listenStart, volume: 0.3)
        } catch {
            AppState.shared.show("I couldn't open your microphone.")
        }
    }

    func endAnswerRecording() {
        guard recordingAnswer, let cap = answerCapture else { return }
        recordingAnswer = false
        answerCapture = nil
        micLevel = 0
        let index = questionIndex
        let prefix = answerPrefix
        Sounds.play(.listenEnd, volume: 0.3)
        transcribing = true
        Task {
            let (text, file) = await cap.stop()
            var result = text
            if result.isEmpty, let file {
                // Apple Speech unavailable: let Awan's server transcribe it (doesn't count as dictation).
                result = (try? await DictationCleanup.transcribe(file: file, requestId: UUID().uuidString, language: nil, dictionary: Prefs.shared.dictionary, countAsDictation: false)) ?? ""
            }
            if let file { try? FileManager.default.removeItem(at: file) }
            if !result.isEmpty { answers[index] = prefix + result }
            transcribing = false
        }
    }

    private func cancelAnswerRecording() {
        answerCapture?.cancel()
        answerCapture = nil
        recordingAnswer = false
    }

    // MARK: - Squad

    var squad: [AwanSpecDTO] {
        switch cast {
        case let .ready(_, awans): return awans
        default: return StarterCast.all.map(\.dto)
        }
    }

    func useSquad() {
        guard !hatching else { return }
        hatching = true
        onFinish?(cast == .skipped || isFailed ? [] : squad)
    }

    func useStarters() {
        cast = .skipped
        useSquad()
    }

    var isFailed: Bool { if case .failed = cast { return true } else { return false } }
}
