import AppKit
import Combine
import Foundation
import SwiftUI

/// The voice/text companion loop: hold-to-talk → mic + live STT + screenshots (+ spatial trail) →
/// POST /v1/companion/respond (SSE) → sentence-chunked speech, pointing/annotations synced to the voice,
/// agent hand-offs, guided walkthroughs, text mode, always-on voice.
///
/// Public API (keep): voiceState, liveTranscript, responseText, isTextComposerOpen, audioLevel,
///   start(), beginListening(target:) (a target Awan slug routes the speech to that Awan), endListening(),
///   sendText(_:), cancel(), announce(_:), openTextComposer()
/// Added: isQuiet, lastUserText, isStreaming, composerDraft, history, closeTextComposer(), abortListening(),
///   toggleAlwaysOn(), handleEscape(), guidedStep, stopSpeaking()
@MainActor
final class CompanionEngine: ObservableObject {
    static let shared = CompanionEngine()

    @Published var voiceState: VoiceState = .idle
    @Published var liveTranscript = ""
    @Published var responseText = ""
    @Published var isTextComposerOpen = false
    @Published var audioLevel: Float = 0

    /// What the user said or typed for the current/last turn.
    @Published var lastUserText = ""
    /// The reply is still arriving.
    @Published var isStreaming = false
    /// The text composer's field.
    @Published var composerDraft = ""
    /// 0 = no walkthrough; otherwise the guided step number currently armed.
    @Published private(set) var guidedStep = 0
    @Published private(set) var history: [CompanionExchange] = []

    /// A call or screen share is going on — skip unprompted speech (morning hello, agent announcements).
    var isQuiet: Bool { QuietContext.reason(companionMicActive: mic?.isRunning ?? false) != nil }

    static let maxGuidedSteps = 15
    static let historyLimit = 20

    private(set) lazy var player: SpeechPlayer = {
        let p = SpeechPlayer()
        p.onStart = { [weak self] in self?.speechStarted() }
        p.onSentenceStart = { [weak self] i in self?.sentenceStarted(i) }
        p.onFinish = { [weak self] in self?.speechFinished() }
        return p
    }()
    private var mic: AudioCapture?
    private var transcriber: TalkTranscriber?
    private var captureTask: Task<[ScreenCaptureFrame], Never>?
    private var responseTask: Task<Void, Never>?
    private var listenTarget: String?
    private var listenStartedAt = Date()
    private var turnIsText = false
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    // Always-on voice
    private var alwaysOnMic: AudioCapture?
    private var vad = VoiceActivityDetector()
    private var alwaysOnTurn = false

    // Visual sync
    private var pendingVisuals: [(sentence: Int, visual: ResolvedVisual)] = []
    private var sentencesStarted = -1
    private var clearTask: Task<Void, Never>?

    // Guided walkthrough
    private struct Guided { var goal: String; var requestId: String; var completed: [String] }
    private var guided: Guided?

    private var pendingAnnouncements: [String] = []

    /// Handoff "Ask Awan" (wave 2): selected screen regions that replace the screenshots for the next turn
    /// (typed or spoken). Consumed by that turn.
    var pendingRegions: [ScreenCaptureFrame] = []
    static let regionNote = "(the user drew a box around part of their screen and attached it — that image is what \"this\" refers to.)"
    /// The app the user was in when the turn began (typing goes back there; its document is read).
    private(set) var turnApp: NSRunningApplication?
    /// This voice turn runs on OpenAI Realtime (features.realtime) instead of STT → chat → TTS.
    private var realtimeTurn = false

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Prefs.shared.$alwaysOnVoice.removeDuplicates().sink { [weak self] on in
            Task { @MainActor in on ? self?.startAlwaysOn() : self?.stopAlwaysOn() }
        }.store(in: &cancellables)
        MorningGreeting.shared.start()
    }

    /// The frontmost app, unless it's Awan itself.
    static func userFrontApp() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        return front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
    }

    // MARK: - Voice turn

    func beginListening(target: String? = nil) {
        if voiceState == .listening { return }
        // Barge-in: talking over Awan stops it.
        if voiceState == .responding || voiceState == .processing || player.isActive { interruptResponse() }
        cancelGuided(silently: true)
        TalkTranscriber.requestAuthorizationIfNeeded()
        listenTarget = target
        listenStartedAt = Date()
        turnIsText = false
        turnApp = Self.userFrontApp()
        realtimeTurn = target == nil && RealtimeVoiceSession.isEnabled
        if realtimeTurn { RealtimeVoiceSession.shared.beginTurn() }
        let feeder = realtimeTurn ? RealtimeVoiceSession.shared.feeder : nil
        liveTranscript = ""
        responseText = ""
        lastUserText = ""
        Sounds.play(.listenStart)
        setVoice(.listening)
        CursorOverlayController.shared.clearAnnotations()
        CursorOverlayController.shared.beginSpatialTrail()

        let stt = TalkTranscriber()
        stt.onPartial = { [weak self] t in self?.liveTranscript = t }
        stt.start(contextualStrings: Prefs.shared.dictionary)
        transcriber = stt

        if let always = alwaysOnMic, always.isRunning {
            always.resetRecording(keepingLast: 0.35)
            always.onBuffer = { [weak stt] b in stt?.append(b); feeder?.append(b) }
        } else {
            let capture = AudioCapture(deviceUID: Prefs.shared.microphoneUID)
            capture.onLevel = { [weak self] l in self?.audioLevel = l }
            capture.onBuffer = { [weak stt] b in stt?.append(b); feeder?.append(b) }
            do {
                try capture.start()
                mic = capture
            } catch {
                Log.error("mic: \(error.localizedDescription)")
                transcriber?.cancel(); transcriber = nil
                _ = CursorOverlayController.shared.endSpatialTrail()
                setVoice(.idle)
                NotchController.shared.present(.message((error as? LocalizedError)?.errorDescription ?? "The microphone didn't start."), for: 5)
                return
            }
        }
        // Capture now (what the user is looking at when they start talking); awaited on release.
        if target == nil {
            captureTask = Task { await Self.captureFrames() }
        }
    }

    func endListening() {
        guard voiceState == .listening else { return }
        Sounds.play(.listenEnd)
        let trail = CursorOverlayController.shared.endSpatialTrail()
        setVoice(.processing)
        let pcm: Data
        if let always = alwaysOnMic, always.isRunning {
            pcm = always.recordedPCM16
            always.onBuffer = nil
        } else {
            pcm = mic?.stop() ?? Data()
            mic = nil
        }
        audioLevel = 0
        let stt = transcriber
        transcriber = nil
        let target = listenTarget
        listenTarget = nil
        let capture = captureTask
        captureTask = nil
        let regions = pendingRegions
        pendingRegions = []

        responseTask?.cancel()
        responseTask = Task { [weak self] in
            let text = await stt?.finish(pcm16: pcm) ?? ""
            guard let self, !Task.isCancelled else { return }
            let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.liveTranscript = transcript
            guard !transcript.isEmpty else {
                Log.info("companion: heard nothing")
                capture?.cancel()
                self.setVoice(.idle)
                return
            }
            self.lastUserText = transcript
            // Capture-only answers (Suggestions → Adjust, New Awan interview): hand the words back, don't reply.
            if target == VoiceAnswer.target || VoiceAnswer.shared.isWaiting {
                capture?.cancel()
                _ = VoiceAnswer.shared.deliver(transcript)
                self.setVoice(.idle)
                return
            }
            if let target {
                self.sendToAwan(transcript, slug: target, display: transcript, announce: false)
                self.setVoice(.idle)
                return
            }
            if !regions.isEmpty {
                capture?.cancel()
                await self.respond(to: transcript + "\n\n" + Self.regionNote, display: transcript, frames: regions, requestId: UUID().uuidString, speak: true)
                return
            }
            async let docTask = Self.readDocumentIfAsked(transcript, app: self.turnApp)
            var frames = await capture?.value ?? []
            let document = await docTask
            var prompt = transcript
            if ScreenCapture.isMeaningfulTrail(trail), let i = frames.firstIndex(where: { $0.isCursorScreen }) {
                frames[i] = ScreenCapture.drawTrail(trail, on: frames[i])
                prompt += "\n\n(the user circled/scribbled on the highlighted area — the translucent lime stroke on screen \(frames[i].index) — while talking; that's what \"this\"/\"here\" refers to.)"
            }
            if self.realtimeTurn, RealtimeVoiceSession.isEnabled {
                await self.respondRealtime(note: prompt == transcript ? nil : prompt, display: transcript, frames: frames, document: document, requestId: UUID().uuidString)
                return
            }
            await self.respond(to: prompt, display: transcript, frames: frames, requestId: UUID().uuidString, speak: true, document: document)
        }
    }

    /// Talk key tapped too briefly (or a shortcut was typed over it): throw the turn away.
    func abortListening() {
        guard voiceState == .listening else { return }
        _ = CursorOverlayController.shared.endSpatialTrail()
        transcriber?.cancel(); transcriber = nil
        if let always = alwaysOnMic, always.isRunning { always.onBuffer = nil } else { mic?.stop(); mic = nil }
        captureTask?.cancel(); captureTask = nil
        listenTarget = nil
        pendingRegions = []
        audioLevel = 0
        if realtimeTurn { RealtimeVoiceSession.shared.feeder.detach(); realtimeTurn = false }
        setVoice(.idle)
    }

    // MARK: - Text mode

    func openTextComposer() {
        if voiceState == .listening { return }
        turnApp = Self.userFrontApp()
        isTextComposerOpen = true
        composerDraft = ""
        Sounds.play(.textOpen)
        NotchController.shared.present(.textInput, for: nil)
    }

    func closeTextComposer() {
        guard isTextComposerOpen else { return }
        isTextComposerOpen = false
        Sounds.play(.textClose)
        NotchFocus.release()
        NotchController.shared.dismissSurface()
    }

    func sendText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        interruptResponse()
        cancelGuided(silently: true)
        isTextComposerOpen = false
        composerDraft = ""
        NotchFocus.release()
        Sounds.play(.textSend)
        turnIsText = true
        lastUserText = t
        liveTranscript = t
        responseText = ""
        setVoice(.processing)
        NotchController.shared.present(.textResponse, for: nil)
        responseTask?.cancel()
        let regions = pendingRegions
        pendingRegions = []
        let app = turnApp
        responseTask = Task { [weak self] in
            async let docTask = Self.readDocumentIfAsked(t, app: app)
            let frames = regions.isEmpty ? await Self.captureFrames() : regions
            let document = await docTask
            guard let self, !Task.isCancelled else { return }
            // Library mode: typed replies stream as text AND are read aloud.
            let prompt = regions.isEmpty ? t : t + "\n\n" + Self.regionNote
            await self.respond(to: prompt, display: t, frames: frames, requestId: UUID().uuidString, speak: true, document: document)
        }
    }

    // MARK: - Interrupts

    func cancel() {
        abortListening()
        interruptResponse()
        cancelGuided(silently: true)
        CursorOverlayController.shared.clearAnnotations()
        setVoice(.idle)
    }

    /// Esc: cancel a walkthrough, stop talking, or close the composer.
    func handleEscape() {
        if guided != nil { cancelGuided(silently: false); return }
        if voiceState == .responding || voiceState == .processing || player.isActive { cancel(); return }
        if isTextComposerOpen { closeTextComposer() }
    }

    func stopSpeaking() {
        player.stop()
        if voiceState == .responding { setVoice(.idle) }
    }

    private func interruptResponse() {
        if realtimeTurn || RealtimeVoiceSession.shared.isConnected { RealtimeVoiceSession.shared.cancelResponse() }
        responseTask?.cancel()
        responseTask = nil
        player.stop()
        isStreaming = false
        pendingVisuals = []
        CursorOverlayController.shared.showCursorBubble(nil)
    }

    // MARK: - Speaking a line

    /// Speaks a short line (agents, billing, tips). Skipped while the user is on a call; waits if Awan is busy.
    func announce(_ line: String) {
        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return }
        if let why = QuietContext.reason(companionMicActive: mic?.isRunning ?? false) {
            Log.info("announce skipped (quiet: \(why)): \(l)")
            return
        }
        if voiceState != .idle || player.isActive {
            pendingAnnouncements.append(l)
            return
        }
        speakLine(l)
    }

    /// Speaks without the quiet-context check (answers to something the user just did).
    func speakLine(_ line: String) {
        if SystemAudio.isMuted {
            NotchController.shared.present(.message(line), for: 5)
            return
        }
        player.begin(serverSpeech: AppState.shared.serverFeatures.serverSpeech)
        player.enqueue(line)
        player.finishInput()
        // No caption beside the cursor while onboarding is up — it would sit on top of the panel's buttons.
        if Prefs.shared.showUpdatesBesideCursor, !OnboardingController.shared.isShowing { CursorOverlayController.shared.showCursorBubble(line) }
    }

    // MARK: - The response pipeline

    struct RespondBody: Encodable {
        var transcript: String
        var images: [[String: String]]
        var history: [CompanionExchange]
        var requestId: String
        var context: String?
        /// The document open in the front window (whole-document context), when the question is about it.
        var document: [String: String]?
        /// Slugs of the active Skills (the server adds an `<active_skills>` block); nil = the account's set.
        var activeSkills: [String]?
    }

    /// Builds the request for a turn (also used by `--companion-selftest`).
    static func requestBody(transcript: String, frames: [ScreenCaptureFrame], history: [CompanionExchange], requestId: String, document: ActiveDocument? = nil) -> RespondBody {
        RespondBody(transcript: transcript, images: frames.map(\.requestImage), history: Array(history.suffix(historyLimit)),
                    requestId: requestId, context: contextBlock(), document: document?.requestBody,
                    activeSkills: SkillsStore.shared.companionSlugs)
    }

    /// Reads the front window's document when the question plausibly refers to it (else nil, no latency).
    static func readDocumentIfAsked(_ question: String, app: NSRunningApplication?) async -> ActiveDocument? {
        guard ActiveDocumentReader.refersToDocument(question), let app else { return nil }
        let doc = await ActiveDocumentReader.read(app: app)
        if let doc { Log.info("companion: reading \(doc.kind) \"\(doc.name)\" (\(doc.text.count) chars, \(doc.source))") }
        return doc
    }

    /// PROFILE.md + VOLATILE.md (if present) + the current local time.
    static func contextBlock() -> String {
        var parts: [String] = []
        for name in ["PROFILE.md", "VOLATILE.md"] {
            let url = Paths.memory.appendingPathComponent(name)
            if let s = try? String(contentsOf: url, encoding: .utf8), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("<\(name)>\n\(s.prefix(6000))\n</\(name)>")
            }
        }
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy, h:mm a zzz"
        parts.append("[current local time: \(f.string(from: Date()))]")
        return parts.joined(separator: "\n\n")
    }

    static func captureFrames() async -> [ScreenCaptureFrame] {
        do { return try await ScreenCapture.captureAll() } catch {
            Log.error("screen capture: \(error.localizedDescription)")
            return []
        }
    }

    private func respond(to prompt: String, display: String, frames: [ScreenCaptureFrame], requestId: String, speak: Bool, document: ActiveDocument? = nil) async {
        let muted = SystemAudio.isMuted
        let voice = speak && !muted
        let geometries = frames.map(\.geometry)
        let body = Self.requestBody(transcript: prompt, frames: frames, history: history, requestId: requestId, document: document)
        var chunker = SentenceChunker()
        var streamed = ""
        pendingVisuals = []
        sentencesStarted = -1
        clearTask?.cancel()
        isStreaming = true
        responseText = ""
        if voice { player.begin(serverSpeech: AppState.shared.serverFeatures.serverSpeech) }

        do {
            for try await (event, data) in APIClient.shared.events("v1/companion/respond", body: body) {
                if Task.isCancelled { return }
                let json = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] ?? [:]
                switch event {
                case "delta":
                    let d = json["text"] as? String ?? ""
                    streamed += d
                    responseText = CompanionTagParser.stripTags(streamed).trimmingCharacters(in: .whitespacesAndNewlines)
                    if voice { chunker.push(d).map(CompanionTagParser.stripTags).forEach(player.enqueue) }
                case "done":
                    let raw = json["text"] as? String ?? streamed
                    var reply = CompanionTagParser.parse(raw)
                    if reply.tags.isEmpty, let pts = json["points"] as? [[String: Any]] {
                        reply.tags = pts.compactMap { p in
                            guard let x = p["x"] as? Double, let y = p["y"] as? Double else { return nil }
                            return CompanionTag(visual: .point(x: x, y: y, label: p["label"] as? String), screen: p["screen"] as? Int, spokenOffset: reply.spokenText.count)
                        }
                    }
                    if reply.agentTask == nil { reply.agentTask = json["agentTask"] as? String }
                    responseText = reply.spokenText
                    isStreaming = false
                    if voice, let rest = chunker.flush() { player.enqueue(CompanionTagParser.stripTags(rest)) }
                    finishTurn(reply, display: display, requestId: requestId, geometries: geometries, voice: voice, muted: muted && speak)
                    return
                case "error":
                    throw APIError.transport(json["error"] as? String ?? "The reply broke off.")
                default:
                    break
                }
            }
            // Stream ended without `done`.
            isStreaming = false
            if voice { if let rest = chunker.flush() { player.enqueue(rest) }; player.finishInput() } else { setVoice(.idle) }
        } catch {
            guard !Task.isCancelled else { return }
            isStreaming = false
            player.stop()
            handleFailure(error)
        }
    }

    private func finishTurn(_ reply: ParsedReply, display: String, requestId: String, geometries: [CaptureGeometry], voice: Bool, muted: Bool) {
        history.append(CompanionExchange(user: display, assistant: reply.spokenText))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }

        // Resolve visuals and bind each to the sentence it belongs to.
        let total = max(1, reply.spokenText.count)
        let sentenceEnds = cumulativeSentenceFractions()
        var target: CompanionTag?
        for tag in reply.tags {
            if tag.visual.isTarget {
                if guidedStepsLeft() <= 0 { continue }
                if target != nil { continue }
                target = tag
            }
            guard let resolved = CompanionVisualMapper.resolve(tag, in: geometries) else { continue }
            let fraction = Double(tag.anchorOffset) / Double(total)
            let sentence = voice ? (sentenceEnds.firstIndex { fraction < $0 } ?? max(0, sentenceEnds.count - 1)) : 0
            pendingVisuals.append((sentence, resolved))
        }
        if !voice || player.sentences.isEmpty { fireVisuals(upTo: Int.max) } else { fireVisuals(upTo: sentencesStarted) }

        // Pictures under the notch.
        if let q = reply.imagesQuery { ImageAnswerCard.shared.show(query: q) }

        // Type into the user's field.
        if let request = reply.typeRequest { typeForUser(request, geometries: geometries) }

        // Hand work to an Awan.
        if let task = reply.agentTask {
            if let name = sendToAwan(task, slug: nil, display: display, announce: false) {
                if voice { player.enqueue("sending that to \(name).") }
            }
        }

        // Guided walkthrough: arm the target and wait for the click.
        if let target {
            guided = guided ?? Guided(goal: display, requestId: requestId, completed: [])
            guidedStep += 1
            CursorOverlayController.shared.onTargetHit = { [weak self] label in
                Task { @MainActor in self?.guidedTargetHit(label ?? target.visual.label) }
            }
        } else if guided != nil {
            // No further target: the walkthrough is complete.
            guided = nil
            guidedStep = 0
            CursorOverlayController.shared.onTargetHit = nil
        }

        if voice {
            player.finishInput()
        } else {
            setVoice(.idle)
            if muted, !turnIsText {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(reply.spokenText, forType: .string)
                NotchController.shared.present(.unmuteFallback, for: 8)
            }
            scheduleClear()
            if turnIsText { scheduleTextDismiss() }
        }
    }

    private func handleFailure(_ error: Error) {
        Log.error("companion: \(error.localizedDescription)")
        setVoice(.idle)
        if case APIError.quotaExceeded = error {
            AppState.shared.presentPaywall(.limitHit)
            responseText = "you're out of talks for this month."
            speakLine("i'm out of juice for this month. upgrade and i'm all yours again.")
            return
        }
        if case APIError.unauthorized = error {
            responseText = "sign in to Awan and I'm all yours."
        } else {
            responseText = "hmm, I couldn't reach my brain just now. try again in a sec."
        }
        if turnIsText { scheduleTextDismiss() } else { NotchController.shared.present(.message(responseText), for: 5) }
    }

    // MARK: - Speech callbacks

    private func speechStarted() {
        if voiceState != .listening { setVoice(.responding) }
    }

    private func sentenceStarted(_ i: Int) {
        sentencesStarted = max(sentencesStarted, i)
        fireVisuals(upTo: i)
    }

    private func speechFinished() {
        if voiceState == .responding || voiceState == .processing { setVoice(.idle) }
        CursorOverlayController.shared.showCursorBubble(nil)
        fireVisuals(upTo: Int.max)
        scheduleClear()
        if turnIsText { scheduleTextDismiss() }
        if !pendingAnnouncements.isEmpty {
            let next = pendingAnnouncements.removeFirst()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.announce(next)
            }
        }
    }

    private func cumulativeSentenceFractions() -> [Double] {
        let lengths = player.sentences.map { Double(max(1, $0.count)) }
        let sum = lengths.reduce(0, +)
        guard sum > 0 else { return [] }
        var acc = 0.0
        return lengths.map { acc += $0; return acc / sum }
    }

    private func fireVisuals(upTo sentence: Int) {
        let due = pendingVisuals.filter { $0.sentence <= sentence }
        guard !due.isEmpty else { return }
        pendingVisuals.removeAll { $0.sentence <= sentence }
        let points = due.compactMap { if case let .point(p) = $0.visual { return p } else { return nil } }
        let annotations = due.compactMap { if case let .annotation(a) = $0.visual { return a } else { return nil } }
        if !annotations.isEmpty { CursorOverlayController.shared.annotate(annotations) }
        if !points.isEmpty { CursorOverlayController.shared.fly(to: points) }
    }

    /// Highlights and shapes clear a moment after Awan stops talking (an armed target stays).
    private func scheduleClear() {
        clearTask?.cancel()
        guard guided == nil else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self, self.guided == nil, self.voiceState == .idle else { return }
            CursorOverlayController.shared.clearAnnotations()
        }
    }

    /// When the text reply card will close (drives its countdown ring) and over how long.
    @Published private(set) var textDismissAt: Date?
    @Published private(set) var textDismissDuration: Double = 0

    /// Auto-dismiss the text reply after its reading time (≈3.2 words/s + 4 s, at least 6 s).
    private func scheduleTextDismiss() {
        let words = responseText.split(separator: " ").count
        let seconds = max(6, Double(words) / 3.2 + 4)
        textDismissDuration = seconds
        textDismissAt = Date().addingTimeInterval(seconds)
        NotchController.shared.present(.textResponse, for: seconds)
    }

    /// Hovering the reply pauses the countdown; leaving resumes with what was left.
    func pauseTextDismiss(_ paused: Bool) {
        guard case .surface(.textResponse) = NotchController.shared.mode else { return }
        if paused, let at = textDismissAt {
            let left = max(2, at.timeIntervalSinceNow)
            pausedRemaining = left
            textDismissAt = nil
            NotchController.shared.present(.textResponse, for: nil)
        } else if let left = pausedRemaining {
            pausedRemaining = nil
            textDismissAt = Date().addingTimeInterval(left)
            NotchController.shared.present(.textResponse, for: left)
        }
    }
    private var pausedRemaining: Double? { didSet { isTextDismissPaused = pausedRemaining != nil } }
    @Published private(set) var isTextDismissPaused = false

    func dismissTextResponse() {
        textDismissAt = nil
        pausedRemaining = nil
        NotchController.shared.dismissSurface()
    }

    // MARK: - Typing ([TYPE]…[/TYPE])

    private func typeForUser(_ request: CompanionTypeRequest, geometries: [CaptureGeometry]) {
        var point: CGPoint?
        if let x = request.x, let y = request.y {
            let tag = CompanionTag(visual: .point(x: x, y: y, label: request.label), screen: request.screen, spokenOffset: 0)
            if case let .point(p)? = CompanionVisualMapper.resolve(tag, in: geometries) { point = p.point }
        }
        let app = turnApp
        Task { @MainActor [weak self] in
            let result = await CompanionTyper.type(request, into: app, at: point)
            Log.info("companion typed: \(result)")
            self?.reportTyping(result, text: request.text)
        }
    }

    private func reportTyping(_ result: CompanionTyper.Result, text: String) {
        switch result {
        case .typed, .nothingToType:
            break
        case .refusedSecure:
            speakLine("that's a password field, so that one's yours to type.")
        case let .refusedApp(name):
            speakLine("i don't type into \(name). that stays yours.")
        case .refusedAddressBar:
            TextInserter.copy(text)
            NotchController.shared.present(.message("That's the address bar, so I put it on your clipboard instead."), for: 5)
        case .clipboard:
            NotchController.shared.present(.message("Copied to your clipboard. Paste it where you want it."), for: 5)
        }
    }

    // MARK: - Realtime voice

    /// A push-to-talk turn on OpenAI Realtime: the audio was streamed while the key was held; now commit it,
    /// attach the screenshots, play the answer's audio as it arrives and act on its tags when it's done.
    private func respondRealtime(note: String?, display: String, frames: [ScreenCaptureFrame], document: ActiveDocument?, requestId: String) async {
        let muted = SystemAudio.isMuted
        let geometries = frames.map(\.geometry)
        pendingVisuals = []
        sentencesStarted = -1
        clearTask?.cancel()
        isStreaming = true
        responseText = ""
        if !muted { player.begin(serverSpeech: true) }
        var texts: [String] = []
        if let note { texts.append(note) }
        if let document, let block = Self.documentText(document) { texts.append(block) }
        var transcript = ""
        var toolTags: [String] = []
        do {
            let images = frames.map { (label: $0.label, jpeg: $0.jpeg) }
            for try await event in RealtimeVoiceSession.shared.finishTurn(images: images, texts: texts, context: Self.contextBlock()) {
                if Task.isCancelled { return }
                switch event {
                case let .audioDelta(pcm): if !muted { player.playPCM16(pcm) }
                case let .transcriptDelta(d):
                    transcript += d
                    responseText = CompanionTagParser.stripTags(transcript).trimmingCharacters(in: .whitespacesAndNewlines)
                case let .transcriptDone(t): if !t.isEmpty { transcript = t }
                case let .functionCall(name, _, args):
                    if name == RealtimeCodec.toolName, let tags = RealtimeCodec.tagsArgument(args) { toolTags.append(tags) }
                default: break
                }
            }
            let reply = Self.realtimeReply(transcript: transcript, toolTags: toolTags)
            responseText = reply.spokenText
            isStreaming = false
            finishTurn(reply, display: display, requestId: requestId, geometries: geometries, voice: !muted, muted: muted)
        } catch {
            guard !Task.isCancelled else { return }
            isStreaming = false
            player.stop()
            handleFailure(error)
        }
    }

    /// The spoken transcript plus the tags that came through `show_on_screen` (anchored at the end).
    static func realtimeReply(transcript: String, toolTags: [String]) -> ParsedReply {
        var reply = CompanionTagParser.parse(transcript)
        for tags in toolTags {
            let t = CompanionTagParser.parse(tags)
            reply.tags += t.tags.map { var x = $0; x.spokenOffset = reply.spokenText.count; return x }
            reply.agentTask = reply.agentTask ?? t.agentTask
            reply.imagesQuery = reply.imagesQuery ?? t.imagesQuery
            reply.typeRequest = reply.typeRequest ?? t.typeRequest
            reply.saidPointNone = reply.saidPointNone || t.saidPointNone
        }
        return reply
    }

    /// Same wrapper the server adds on the pipeline path.
    static func documentText(_ doc: ActiveDocument) -> String? {
        let text = doc.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let name = doc.name.replacingOccurrences(of: "\"", with: " ")
        return "the user has this \(doc.kind) open in the front window; its full text is below.\n<document name=\"\(name)\">\n\(text.prefix(60_000))\n</document>"
    }

    // MARK: - Guided walkthrough

    private func guidedStepsLeft() -> Int { Self.maxGuidedSteps - guidedStep }

    private func guidedTargetHit(_ label: String?) {
        guard var g = guided else { return }
        CursorOverlayController.shared.onTargetHit = nil
        CursorOverlayController.shared.clearAnnotations()
        interruptResponse()
        let step = guidedStep
        g.completed.append(label ?? "step \(step)")
        guided = g
        let prompt = Self.guidedStepPrompt(step: step, label: label, goal: g.goal, completed: g.completed)
        setVoice(.processing)
        turnIsText = false
        responseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450)) // let the click's effect render
            let frames = await Self.captureFrames()
            guard let self, !Task.isCancelled else { return }
            await self.respond(to: prompt, display: "[Guided step \(step) done]", frames: frames, requestId: g.requestId, speak: true)
        }
    }

    /// The follow-up sent after the user clicks an armed [TARGET] (same requestId → the walkthrough costs one talk).
    static func guidedStepPrompt(step: Int, label: String?, goal: String, completed: [String]) -> String {
        let remaining = maxGuidedSteps - step
        return """
        [Guided step \(step) done] the user clicked inside the target "\(label ?? "")". goal: \(goal)
        completed steps: \(completed.joined(separator: ", ")).
        remaining click-to-advance turns: \(remaining). look at the new screenshot as the truth, then give the ONE next step with a [TARGET], or say in one sentence that it's done (no tag). \(remaining <= 0 ? "do not emit [TARGET]." : "")
        """
    }

    private func cancelGuided(silently: Bool) {
        guard guided != nil else { return }
        guided = nil
        guidedStep = 0
        CursorOverlayController.shared.onTargetHit = nil
        CursorOverlayController.shared.clearAnnotations()
        if !silently {
            interruptResponse()
            setVoice(.idle)
            speakLine("okay, stopping the walkthrough.")
        }
    }

    // MARK: - Agents

    /// Sends work to an Awan (`slug` nil = pick the best one). Returns the Awan's name.
    @discardableResult
    func sendToAwan(_ task: String, slug: String?, display: String, announce: Bool) -> String? {
        let store = AgentStore.shared
        guard let chosen = slug ?? AgentRouter.bestSlug(for: task, among: store.visibleAgents), let agent = store.agent(chosen) else {
            Log.info("companion: no Awan to take \"\(task)\"")
            return nil
        }
        guard store.send(task, to: chosen, display: display, source: "voice") != nil else { return nil }
        Sounds.play(.agentLaunch)
        Log.info("companion → \(chosen): \(task)")
        if announce { speakLine("sending that to \(agent.name).") }
        return agent.name
    }

    // MARK: - Always-on voice

    func toggleAlwaysOn() {
        Prefs.shared.alwaysOnVoice.toggle()
        speakLine(Prefs.shared.alwaysOnVoice ? "always-on voice is on. talk whenever, no keys needed." : "always-on voice is off.")
    }

    private func startAlwaysOn() {
        guard alwaysOnMic == nil else { return }
        if AudioCapture.defaultOutputIsBuiltInSpeaker, !UserDefaults.standard.bool(forKey: "awan.voice.alwaysOnHeadphonesWarned") {
            UserDefaults.standard.set(true, forKey: "awan.voice.alwaysOnHeadphonesWarned")
            speakLine("heads up, always-on works best with headphones, so i don't hear myself talking.")
        }
        let capture = AudioCapture(deviceUID: Prefs.shared.microphoneUID)
        capture.onLevel = { [weak self] l in self?.alwaysOnLevel(l) }
        do {
            try capture.start()
            alwaysOnMic = capture
            vad.reset()
            Log.info("always-on voice: listening")
        } catch {
            Log.error("always-on voice: \(error.localizedDescription)")
            Prefs.shared.alwaysOnVoice = false
        }
    }

    private func stopAlwaysOn() {
        guard let capture = alwaysOnMic else { return }
        if alwaysOnTurn, voiceState == .listening { abortListening() }
        capture.stop()
        alwaysOnMic = nil
        alwaysOnTurn = false
        Log.info("always-on voice: off")
    }

    private func alwaysOnLevel(_ level: Float) {
        if voiceState == .listening { audioLevel = level }
        guard let event = vad.feed(level: level, at: ProcessInfo.processInfo.systemUptime) else { return }
        switch event {
        case .speechStarted:
            // Barge-in only with headphones (no echo cancellation on speakers).
            if voiceState == .responding || player.isActive {
                guard !AudioCapture.defaultOutputIsBuiltInSpeaker else { return }
            }
            guard voiceState != .listening, !isTextComposerOpen, !DictationManager.shared.isDictating else { return }
            alwaysOnTurn = true
            beginListening()
        case .speechEnded:
            if alwaysOnTurn, voiceState == .listening { alwaysOnTurn = false; endListening() }
        }
    }

    // MARK: - State

    /// Snapshot harness only: seed the text surfaces without a network turn.
    func debugSeed(user: String, reply: String, draft: String, streaming: Bool) {
        lastUserText = user
        responseText = reply
        composerDraft = draft
        isStreaming = streaming
        isTextComposerOpen = true
        voiceState = streaming ? .responding : .idle
        textDismissDuration = 12
        textDismissAt = streaming ? nil : Date().addingTimeInterval(8)
    }

    private func setVoice(_ s: VoiceState) {
        if voiceState != s { voiceState = s }
        CursorOverlayController.shared.setVoiceState(s)
    }
}
