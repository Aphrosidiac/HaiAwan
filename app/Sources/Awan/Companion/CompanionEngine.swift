import AppKit
import AVFoundation
import ImageIO
import Combine
import Foundation
import SwiftUI

/// The voice/text companion.
///
/// Architecture (v2, modelled on the reference's realtime companion):
///   hold-to-talk → mic + live STT + screenshots (+ what the user drew)
///   → one ongoing conversation (`CompanionConversation`) that gets the user's words plus silent context notes
///     ([time], [app], [awans], [awan progress], [home], [open document], [drawing], screenshots when they changed)
///   → POST /v1/companion/turn, one streamed model round at a time: speech starts on the first sentence, tool calls
///     run here (`CompanionTools`), their results go back into the conversation, and the model continues
///   → `ask_deeper` hands screen-exact work (pointing, drawing, walkthroughs, typing into a visible field, reading the
///     open document) to a frontier vision model; its visuals are synced to the voice model's speech.
/// Agent announcements, walkthrough steps and follow-ups ride the same conversation, so "what did it find?" and
/// "do that again" resolve against everything that happened.
///
/// Public API (keep): voiceState, liveTranscript, responseText, isTextComposerOpen, audioLevel,
///   start(), beginListening(target:) (a target Awan slug routes the speech to that Awan), endListening(),
///   sendText(_:), cancel(), announce(_:), openTextComposer()
/// Also: isQuiet, lastUserText, isStreaming, composerDraft, history, closeTextComposer(), abortListening(),
///   toggleAlwaysOn(), handleEscape(), guidedStep, stopSpeaking(), toolStatus, agentUpdate(…)
@MainActor
final class CompanionEngine: ObservableObject {
    static let shared = CompanionEngine()

    @Published var voiceState: VoiceState = .idle
    @Published var liveTranscript = ""
    @Published var responseText = ""
    @Published var isTextComposerOpen = false
    @Published var audioLevel: Float = 0
    /// Loudest mic level in the current hold: tells "heard nothing" (silence, e.g. the mic is blocked) from "said nothing clear".
    private var peakLevel: Float = 0

    /// What the user said or typed for the current/last turn.
    @Published var lastUserText = ""
    /// The reply is still arriving.
    @Published var isStreaming = false
    /// The text composer's field.
    @Published var composerDraft = ""
    /// 0 = no walkthrough; otherwise the guided step number currently armed.
    @Published private(set) var guidedStep = 0
    /// What a running tool is doing ("Looking closer…"), for the cursor bubble and the notch.
    @Published private(set) var toolStatus: String?

    let conversation = CompanionConversation.shared
    /// Self-tests: no overlay, notch or cursor calls (the process has no UI).
    static var headless = false
    /// The exchanges so far (user ↔ Awan), newest last.
    var history: [CompanionExchange] {
        var out: [CompanionExchange] = []
        var pendingUser: String?
        for line in conversation.transcript {
            if line.role == "user" { pendingUser = line.text }
            if line.role == "awan", let u = pendingUser { out.append(CompanionExchange(user: u, assistant: line.text)); pendingUser = nil }
        }
        return out
    }

    /// A call or screen share is going on — skip unprompted speech (morning hello, agent announcements).
    var isQuiet: Bool { QuietContext.reason(companionMicActive: mic?.isRunning ?? false) != nil }

    static let maxGuidedSteps = 15
    static let historyLimit = 20
    /// Tool calls one user turn may make before the model must answer with what it has.
    static let toolCallCap = 6
    /// Model rounds per turn (a round = the model's text and/or tool calls).
    static let roundCap = 8

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
    private var documentTask: Task<ActiveDocument?, Never>?
    var responseTask: Task<Void, Never>?
    private var listenTarget: String?
    private var listenStartedAt = Date()
    private(set) var turnIsText = false
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    // Always-on voice
    private var alwaysOnMic: AudioCapture?
    private var vad = VoiceActivityDetector()
    private var alwaysOnTurn = false

    // Visual sync
    var pendingVisuals: [(sentence: Int, visual: ResolvedVisual)] = []
    private var sentencesStarted = -1
    private var clearTask: Task<Void, Never>?

    // Guided walkthrough
    struct Guided { var goal: String; var completed: [String] }
    var guided: Guided?

    private var pendingAnnouncements: [String] = []
    /// Agent updates that arrived while Awan was busy; spoken (through the conversation) once it's idle.
    private var pendingAgentUpdates: [String] = []
    /// When the last user turn went out (agent progress newer than this is news to the model).
    private var lastTurnAt = Date.distantPast
    /// Which Awan's chat the user last had open in Home, and until when (for the [awans] note).
    private var lastViewedAgent: (slug: String, until: Date)?

    /// Handoff "Ask Awan" (wave 2): selected screen regions that replace the screenshots for the next turn
    /// (typed or spoken). Consumed by that turn.
    var pendingRegions: [ScreenCaptureFrame] = []
    static let regionNote = "(the user drew a box around part of their screen and attached it — that image is what \"this\" refers to.)"
    /// The app the user was in when the turn began (typing goes back there; its document is read).
    private(set) var turnApp: NSRunningApplication?
    /// The turn in flight (its screens, document and drawing are what the tools see).
    private(set) var currentTurn: CompanionTurn?

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Prefs.shared.$alwaysOnVoice.removeDuplicates().sink { [weak self] on in
            Task { @MainActor in on ? self?.startAlwaysOn() : self?.stopAlwaysOn() }
        }.store(in: &cancellables)
        // Remember which Awan's chat the user was just looking at.
        let state = AppState.shared
        Publishers.CombineLatest(state.$isHomeOpen, state.$homePage).sink { [weak self] open, page in
            guard let self else { return }
            if let v = self.lastViewedAgent, !(open && page == .agent(v.slug)) {
                self.lastViewedAgent = (v.slug, Date())
            }
            if open, case let .agent(slug) = page { self.lastViewedAgent = (slug, .distantFuture) }
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
        // Barge-in: talking over Awan stops it. A quick tap (released within `stopTapWindow`) is just "stop".
        pressStoppedAwan = isBusy || guided != nil
        if pressStoppedAwan {
            pendingAnnouncements = []
            pendingAgentUpdates = []
            interruptResponse()
        }
        cancelGuided(silently: true)
        TalkTranscriber.requestAuthorizationIfNeeded()
        listenTarget = target
        listenStartedAt = Date()
        turnIsText = false
        turnApp = Self.userFrontApp()
        liveTranscript = ""
        responseText = ""
        lastUserText = ""
        Sounds.play(.listenStart)
        peakLevel = 0
        setVoice(.listening)
        CursorOverlayController.shared.clearAnnotations()
        CursorOverlayController.shared.beginSpatialTrail()

        let stt = TalkTranscriber()
        stt.onPartial = { [weak self] t in self?.liveTranscript = t }
        stt.start(contextualStrings: Prefs.shared.dictionary)
        transcriber = stt

        if let always = alwaysOnMic, always.isRunning {
            always.resetRecording(keepingLast: 0.35)
            always.onBuffer = { [weak stt] b in stt?.append(b) }
        } else {
            let capture = AudioCapture(deviceUID: Prefs.shared.microphoneUID)
            capture.onLevel = { [weak self] l in self?.audioLevel = l; if l > self?.peakLevel ?? 1 { self?.peakLevel = l } }
            capture.onBuffer = { [weak stt] b in stt?.append(b) }
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
        // Capture now (what the user is looking at when they start talking) and read the front document in
        // parallel; both are awaited on release.
        if target == nil {
            captureTask = Task { await Self.captureFrames() }
            let app = turnApp
            documentTask = Task { await Self.readActiveDocument(app: app) }
        }
    }

    func endListening() {
        guard voiceState == .listening else { return }
        if pressStoppedAwan, Date().timeIntervalSince(listenStartedAt) < Self.stopTapWindow {
            // Tapped the talk keys to shut Awan up: stop, don't listen or answer.
            pressStoppedAwan = false
            abortListening()
            stop()
            return
        }
        pressStoppedAwan = false
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
        let docTask = documentTask
        documentTask = nil
        let regions = pendingRegions
        pendingRegions = []
        let peak = peakLevel
        let held = Date().timeIntervalSince(listenStartedAt)

        responseTask?.cancel()
        responseTask = Task { [weak self] in
            // Only ask the server to transcribe when Apple Speech couldn't run and there was sound to transcribe:
            // silence sent to an audio model comes back as invented words (it echoed the dictionary, "Hai Awan").
            let serverFallback = peak >= Self.speechLevelFloor
            let text = await stt?.finish(pcm16: pcm, allowServerFallback: serverFallback) ?? ""
            guard let self, !Task.isCancelled else { return }
            let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.liveTranscript = transcript
            guard Self.isUtterance(transcript) else {
                let mic = AVCaptureDevice.authorizationStatus(for: .audio)
                Log.info("companion: heard nothing (held \(String(format: "%.1f", held)) s, mic \(mic == .authorized ? "allowed" : "not allowed"), peak level \(String(format: "%.3f", peak)))")
                capture?.cancel()
                docTask?.cancel()
                self.setVoice(.idle)
                // A quick tap is nothing; a real hold with no words gets one quiet line on the notch, never a reply.
                if mic != .authorized {
                    NotchController.shared.present(.message("I can't hear you. Turn on Microphone for Awan in System Settings → Privacy & Security."), for: 6)
                } else if held >= 0.8, peak < 0.02, self.alwaysOnMic == nil {
                    NotchController.shared.present(.message("I didn't hear anything. Check that your mic is on in Settings → Microphone."), for: 5)
                } else if held >= 0.8, self.alwaysOnMic == nil {
                    NotchController.shared.present(.message("I didn't catch that. Hold the keys and try again?"), for: 3)
                }
                return
            }
            self.lastUserText = transcript
            // Capture-only answers (Suggestions → Adjust, New Awan interview): hand the words back, don't reply.
            if target == VoiceAnswer.target || VoiceAnswer.shared.isWaiting {
                capture?.cancel(); docTask?.cancel()
                _ = VoiceAnswer.shared.deliver(transcript)
                self.setVoice(.idle)
                return
            }
            if let target {
                await self.followUp(transcript, to: target)
                return
            }
            var frames = regions.isEmpty ? (await capture?.value ?? []) : regions
            if !regions.isEmpty { capture?.cancel() }
            let document = await docTask?.value
            let drawing = CompanionNotes.drawing(trail, frames: frames)
            let marks = trail.filter(ScreenCapture.isMeaningfulTrail)
            if !marks.isEmpty, let i = frames.firstIndex(where: { $0.isCursorScreen }) {
                for stroke in marks { frames[i] = ScreenCapture.drawTrail(stroke, on: frames[i]) }
            }
            let turn = CompanionTurn(userText: regions.isEmpty ? transcript : transcript + "\n\n" + Self.regionNote, display: transcript,
                                     frames: frames, document: document, drawing: drawing, app: self.turnApp, speak: true)
            await self.runUserTurn(turn)
        }
    }

    /// A press of the talk keys shorter than this, while Awan is talking or thinking, only stops it.
    static let stopTapWindow: TimeInterval = 0.6
    private var pressStoppedAwan = false

    /// Below this smoothed mic level nothing was said (the level meter's scale: 0 = −55 dB, 1 = −10 dB; 0.45 ≈ −35 dB).
    static let speechLevelFloor: Float = 0.45

    /// A transcript worth answering: at least one letter or digit, not only filler.
    static func isUtterance(_ t: String) -> Bool {
        let words = t.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }
        let filler: Set<String> = ["uh", "um", "umm", "hmm", "mm", "mhm", "ah", "er", "erm"]
        return !words.allSatisfy { filler.contains($0) }
    }

    /// Talk key tapped too briefly (or a shortcut was typed over it): throw the turn away.
    func abortListening() {
        guard voiceState == .listening else { return }
        _ = CursorOverlayController.shared.endSpatialTrail()
        transcriber?.cancel(); transcriber = nil
        if let always = alwaysOnMic, always.isRunning { always.onBuffer = nil } else { mic?.stop(); mic = nil }
        captureTask?.cancel(); captureTask = nil
        documentTask?.cancel(); documentTask = nil
        listenTarget = nil
        pendingRegions = []
        audioLevel = 0
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

    func sendText(_ text: String, attachments: [URL] = []) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !attachments.isEmpty else { return }
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
            async let docTask = Self.readActiveDocument(app: app)
            let frames = regions.isEmpty ? await Self.captureFrames() : regions
            let document = await docTask
            guard let self, !Task.isCancelled else { return }
            // Typed replies stream as text AND are read aloud (unless muted).
            let words = t.isEmpty ? "(no message: the user sent only the attached file(s); look at them and respond to what they most likely want done.)" : t
            let turn = CompanionTurn(userText: regions.isEmpty ? words : words + "\n\n" + Self.regionNote, display: t.isEmpty ? "(sent \(attachments.count) file\(attachments.count == 1 ? "" : "s"))" : t,
                                     frames: frames, document: document, drawing: nil, app: app, speak: true)
            turn.attachments = attachments
            turn.attachedImages = Self.attachedImages(attachments)
            await self.runUserTurn(turn)
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

    /// Awan is talking, thinking or has speech queued (what a stop would end).
    var isBusy: Bool {
        voiceState == .responding || voiceState == .processing || player.isActive || currentTurn != nil
            || !pendingAnnouncements.isEmpty || !pendingAgentUpdates.isEmpty
    }

    /// Stop everything Awan is doing out loud, right now: the reply, its tools, a walkthrough, and anything queued to
    /// be said after it. (Esc, a quick tap of the talk keys, or a click on the notch.)
    func stop() {
        let wasBusy = isBusy || guided != nil
        pendingAnnouncements = []
        pendingAgentUpdates = []
        abortListening()
        interruptResponse()
        cancelGuided(silently: true)
        setVoice(.idle)
        if !Self.headless {
            CursorOverlayController.shared.clearAnnotations()
            CursorOverlayController.shared.showCursorBubble(nil)
            if case .surface(.textResponse) = NotchController.shared.mode { dismissTextResponse() }
        }
        if wasBusy { Log.info("companion: stopped by the user") }
    }

    /// Esc: stop Awan (talking, thinking, a walkthrough, queued speech), or close the composer.
    func handleEscape() {
        if voiceState == .listening { abortListening(); return }   // a hold whose release got lost: Esc always gets you out
        if isBusy || guided != nil { stop(); return }
        if isTextComposerOpen { closeTextComposer() }
    }

    func stopSpeaking() {
        player.stop()
        if voiceState == .responding { setVoice(.idle) }
    }

    private func interruptResponse() {
        // Keep what Awan had already said, so "as you were saying" and "no, the other one" still make sense.
        if currentTurn != nil {
            let said = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            conversation.closeDanglingToolCalls()
            if !said.isEmpty {
                conversation.append(.note("[app] the user cut awan off mid-reply. awan had said: \"\(said.prefix(600))\""))
                conversation.record("awan", said + " …(cut off)")
            }
            currentTurn = nil
        }
        responseTask?.cancel()
        responseTask = nil
        player.stop()
        isStreaming = false
        pendingVisuals = []
        setToolStatus(nil)
        conversation.closeDanglingToolCalls()
        if !Self.headless { CursorOverlayController.shared.showCursorBubble(nil) }
    }

    // MARK: - Speaking a line

    /// Speaks a short fixed line (billing, tips). Skipped while the user is on a call; waits if Awan is busy.
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

    // MARK: - Agent updates (through the conversation)

    /// An Awan finished or needs the user. The update goes into the conversation (so a later "what did it find?"
    /// works) and, unless Awan should stay quiet, the voice model tells the user in its own words.
    func agentUpdate(slug: String, name: String, summary: String?, spoken: String?, files: [String], needsYou: Bool, speak: Bool) {
        let what = (summary ?? spoken ?? "finished").trimmingCharacters(in: .whitespacesAndNewlines)
        var note = "[awan update] \(name) (awan_slug: \(slug)) \(needsYou ? "needs the user: " : "just finished: ")\"\(what)\""
        if !files.isEmpty { note += " files: \(files.prefix(4).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))." }
        conversation.record("event", "\(name) \(needsYou ? "needs you" : "finished"): \(what)")
        guard speak else {
            conversation.ensureSession()
            conversation.append(.note(note + " (the user was busy, so this wasn't announced. if they ask, answer from it.)"))
            return
        }
        note += needsYou
            ? " tell the user in one short sentence, in your own voice, what \(name) needs and that they can say yes or no. nothing else."
            : " tell the user in one or two short sentences, in your own voice, what \(name) made or found, keeping its specifics. if a file opened by itself, say it's open. no question at the end. nothing else."
        if voiceState != .idle || player.isActive || isTextComposerOpen {
            pendingAgentUpdates.append(note)
            return
        }
        speakAgentUpdate(note)
    }

    private func speakAgentUpdate(_ note: String) {
        turnIsText = false
        responseText = ""
        setVoice(.processing)
        let turn = CompanionTurn(userText: nil, display: "", frames: [], document: nil, drawing: nil, app: Self.userFrontApp(), speak: true)
        responseTask?.cancel()
        responseTask = Task { [weak self] in
            await self?.runNoteTurn(turn, note: note, toolChoice: "none")
        }
    }

    // MARK: - The conversation turn

    /// A user turn: context notes + the user's words (+ screenshots when the screen changed), then model rounds.
    func runUserTurn(_ turn: CompanionTurn) async {
        let convo = conversation
        convo.ensureSession()
        var notes: [String] = [CompanionNotes.time()]
        if let n = CompanionNotes.app(turn.app), convo.lastNotes["app"] != n { notes.append(n); convo.lastNotes["app"] = n }
        let roster = CompanionNotes.awans(lastViewed: lastViewedAgent)
        if convo.lastNotes["awans"] != roster { notes.append(roster); convo.lastNotes["awans"] = roster }
        if let p = CompanionNotes.progress(since: lastTurnAt) { notes.append(p) }
        if let h = CompanionNotes.home(), convo.lastNotes["home"] != h { notes.append(h); convo.lastNotes["home"] = h }
        if !AppState.shared.isHomeOpen { convo.lastNotes["home"] = nil }
        if let s = CompanionNotes.suggestions() { notes.append(s) }
        if let doc = turn.document {
            let n = CompanionNotes.document(doc)
            if convo.lastNotes["document"] != n { notes.append(n); convo.lastNotes["document"] = n }
        }
        if let d = turn.drawing { notes.append(d) }
        if !turn.attachments.isEmpty {
            notes.append(Self.attachmentsNote(turn))
            if turn.attachedImages.isEmpty {
                turn.capabilities = CompanionTools.capabilities.filter { !["ask_deeper", "read_file", "list_files", "look_at_screen"].contains($0) }
            }
        }
        notes.append(Self.voiceStyleNote())
        lastTurnAt = Date()
        for n in notes { convo.append(.note(n)) }
        convo.append(.utterance(turn.userText ?? "", images: screensToAttach(turn) + turn.attachedImages))
        convo.record("user", turn.display)
        await runRounds(turn, countUsage: true, toolChoice: "auto")
    }

    /// A turn the app starts (an agent update, a walkthrough step, a follow-up acknowledgement): a note, then rounds.
    func runNoteTurn(_ turn: CompanionTurn, note: String, toolChoice: String) async {
        conversation.ensureSession()
        conversation.append(.note(CompanionNotes.time()))
        conversation.append(.note(note))
        await runRounds(turn, countUsage: false, toolChoice: toolChoice)
    }

    /// This turn's spoken-preamble rule (the reference picks one per turn): one tiny beat, or silence, before a slow
    /// tool, and never narration between tool calls.
    static func voiceStyleNote() -> String {
        let beat = ["one sec.", "okay.", "mm-hm.", "sure, one sec.", ""].randomElement()!
        return beat.isEmpty
            ? "[voice style, this turn] if you call a slower tool, say nothing before it; speak only once the result is back. never talk between tool calls."
            : "[voice style, this turn] if you call a slower tool, the only words before it are \"\(beat)\" (in the user's language), then call it. never talk between tool calls; say the real answer once, at the end."
    }

    /// Tells the model what was attached and how to route it: at most two small images can be answered on the spot
    /// (the deeper pass sees them); anything else needs an Awan, and the files go with the task.
    static func attachmentsNote(_ turn: CompanionTurn) -> String {
        let names = turn.attachments.prefix(8).map(\.path).joined(separator: ", ")
        let route = !turn.attachedImages.isEmpty && turn.attachedImages.count == turn.attachments.count
            ? "they're small images, attached right after this. answer about them yourself or with ask_deeper, or call start_awan_task if the user wants work done with them."
            : "these need an awan: call start_awan_task now with the user's request (the files go to the awan automatically). don't read, open or look for them yourself, and don't call ask_deeper for them."
        return "[attachments] the user attached \(turn.attachments.count) file\(turn.attachments.count == 1 ? "" : "s"): \(names). the files and the user's words are the main subject of this turn; any screenshot is secondary. \(route)"
    }

    /// Up to two image files under 8 MB become pictures the models can see.
    static func attachedImages(_ urls: [URL]) -> [ScreenCaptureFrame] {
        let exts: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp"]
        let images = urls.filter { exts.contains($0.pathExtension.lowercased()) }
        guard images.count == urls.count, images.count <= 2 else { return [] }
        var out: [ScreenCaptureFrame] = []
        for (i, url) in images.enumerated() {
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 < 8_000_000,
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1280, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
                  let jpeg = ScreenCapture.jpegData(img) else { continue }
            out.append(ScreenCaptureFrame(index: i + 1, count: images.count, isCursorScreen: false, displayID: 0,
                                          geometry: CaptureGeometry(displayFrame: .zero, pixelSize: CGSize(width: img.width, height: img.height)),
                                          image: img, jpeg: jpeg,
                                          label: "attached image \(i + 1) of \(images.count): \(url.lastPathComponent) (\(img.width)x\(img.height) pixels; a file, not a screen, so never point at it)"))
        }
        return out.count == images.count ? out : []
    }

    /// Screenshots go into the conversation only when the screen changed since the model last saw it.
    private func screensToAttach(_ turn: CompanionTurn) -> [ScreenCaptureFrame] {
        guard !turn.frames.isEmpty else { return [] }
        let prints = turn.frames.map { CompanionNotes.fingerprint($0.image) }
        let unchanged = turn.drawing == nil && CompanionNotes.sameScreens(prints, conversation.lastScreenFingerprints)
            && Date().timeIntervalSince(conversation.lastScreenAt ?? .distantPast) < 10 * 60
        if unchanged { return [] }
        conversation.lastScreenFingerprints = prints
        conversation.lastScreenAt = Date()
        return turn.frames
    }

    private struct TurnBody: Encodable {
        var items: [JSON]
        var context: JSON
        var capabilities: [String]
        var requestId: String
        var countUsage: Bool
        var toolChoice: String
    }

    /// Streams model rounds until the model answers without calling a tool (or a cap is hit).
    private func runRounds(_ turn: CompanionTurn, countUsage: Bool, toolChoice firstChoice: String) async {
        currentTurn = turn
        let muted = SystemAudio.isMuted
        let voice = turn.speak && !muted
        pendingVisuals = []
        sentencesStarted = -1
        clearTask?.cancel()
        isStreaming = true
        responseText = ""
        if voice { player.begin(serverSpeech: AppState.shared.serverFeatures.serverSpeech) }
        turn.voice = voice
        var reply = ""
        var choice = firstChoice
        do {
            for round in 1 ... Self.roundCap {
                var text = ""
                var calls: [ToolCallItem] = []
                var chunker = SentenceChunker()
                let body = TurnBody(items: conversation.wireItems(), context: promptContext(muted: muted), capabilities: turn.capabilities ?? CompanionTools.capabilities,
                                    requestId: turn.id, countUsage: countUsage && round == 1, toolChoice: round == Self.roundCap ? "none" : choice)
                for try await (event, data) in APIClient.shared.events("v1/companion/turn", body: body) {
                    if Task.isCancelled { return }
                    let json = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] ?? [:]
                    switch event {
                    case "delta":
                        let d = json["text"] as? String ?? ""
                        text += d
                        responseText = Self.joinReply(reply, text)
                        // The first round streams (its opening beat should be heard at once). Later rounds follow a
                        // tool result and are held until they end: if they only lead into another tool call, they're
                        // narration and stay unspoken.
                        if voice, round == 1 { chunker.push(d).forEach(player.enqueue) }
                    case "tool_call":
                        calls.append(ToolCallItem(id: json["id"] as? String ?? UUID().uuidString, name: json["name"] as? String ?? "", arguments: json["arguments"] as? String ?? "{}"))
                    case "error":
                        throw APIError.transport(json["error"] as? String ?? "The reply broke off.")
                    default:
                        break
                    }
                }
                if voice, round == 1, let rest = chunker.flush() { player.enqueue(rest) }
                let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if voice, round > 1, calls.isEmpty, !said.isEmpty {
                    var c = SentenceChunker()
                    c.push(said).forEach(player.enqueue)
                    if let rest = c.flush() { player.enqueue(rest) }
                }
                // Unspoken narration stays out of what's shown and remembered as said.
                reply = round > 1 && !calls.isEmpty ? reply : Self.joinReply(reply, said)
                responseText = reply
                conversation.append(ConversationItem(role: .assistant, kind: .reply, text: said.isEmpty ? nil : said, toolCalls: calls))
                bindDeferredVisuals(turn)
                if calls.isEmpty || Task.isCancelled { break }

                // Run the tools; screenshots they take go in after all the results.
                if voiceState == .responding { setVoice(.processing) }
                var attachments: [ConversationItem] = []
                for call in calls {
                    if Task.isCancelled { return }
                    turn.toolCalls += 1
                    setToolStatus(CompanionTools.statusLabel(call))
                    Log.info("companion tool: \(call.name) \(call.arguments.prefix(300))")
                    let out = await CompanionTools.run(call, turn: turn, engine: self)
                    if Task.isCancelled { return }
                    conversation.append(ConversationItem(role: .tool, kind: .toolResult, text: out.result, toolCallID: call.id))
                    attachments += out.attachments
                }
                setToolStatus(nil)
                for a in attachments { conversation.append(a) }
                choice = turn.toolCalls >= Self.toolCallCap ? "none" : "auto"
            }
            isStreaming = false
            finishTurn(turn, reply: reply, voice: voice, muted: muted)
        } catch {
            guard !Task.isCancelled else { return }
            isStreaming = false
            setToolStatus(nil)
            conversation.closeDanglingToolCalls()
            player.stop()
            handleFailure(error)
        }
    }

    static func joinReply(_ a: String, _ b: String) -> String {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines), y = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if x.isEmpty { return y }
        if y.isEmpty { return x }
        return x + " " + y
    }

    private func finishTurn(_ turn: CompanionTurn, reply: String, voice: Bool, muted: Bool) {
        currentTurn = nil
        responseText = reply
        if !reply.isEmpty { conversation.record("awan", reply) }
        fireVisuals(upTo: voice && !player.sentences.isEmpty ? sentencesStarted : Int.max)
        if voice, !player.sentences.isEmpty {
            player.finishInput()
        } else {
            if voice { player.stop() }
            setVoice(.idle)
            if muted, turn.speak, !turnIsText, !reply.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(reply, forType: .string)
                NotchController.shared.present(.unmuteFallback, for: 8)
            }
            scheduleClear()
            if turnIsText, !Self.headless { scheduleTextDismiss() }
            drainQueuedSpeech()
        }
    }

    /// The session context the server renders into the instructions.
    func promptContext(muted: Bool) -> JSON {
        let connectors = ConnectorStore.shared.connectors
        let skills = SkillsStore.shared.activeItems.map { ["name": .string($0.title), "oneLiner": .string($0.oneLiner)] as JSON }
        var ctx: [String: JSON] = [
            "timeZone": .string(TimeZone.current.identifier),
            "connectedIntegrations": .array(connectors.filter { $0.status == "connected" }.map { .string($0.name) }),
            "needsReconnectIntegrations": .array(connectors.filter { $0.status == "needsSignIn" || $0.status == "rejected" }.map { .string($0.name) }),
            "activeSkills": .array(skills),
            "shortcuts": ["talk": "hold control + option", "text": "double-tap control", "dictation": "hold fn + control"],
            "priorMessageCount": .number(Double(conversation.priorMessageCount)),
            "alwaysOn": .bool(Prefs.shared.alwaysOnVoice),
            "muted": .bool(muted),
        ]
        if let name = AppState.shared.user?.firstName, !name.isEmpty { ctx["userFirstName"] = .string(name) }
        return .object(ctx)
    }

    private func handleFailure(_ error: Error) {
        Log.error("companion: \(error.localizedDescription)")
        currentTurn = nil
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
        if Self.headless { return }
        if turnIsText { scheduleTextDismiss() } else { NotchController.shared.present(.message(responseText), for: 5) }
    }

    func setToolStatus(_ s: String?) {
        if toolStatus != s { toolStatus = s }
        if Self.headless { return }
        if let s, Prefs.shared.showUpdatesBesideCursor, !turnIsText { CursorOverlayController.shared.showCursorBubble(s) }
        else if s == nil, voiceState == .processing { CursorOverlayController.shared.showCursorBubble(nil) }
    }

    // MARK: - Speech callbacks

    private func speechStarted() {
        if voiceState != .listening { setVoice(.responding) }
    }

    private func sentenceStarted(_ i: Int) {
        if voiceState == .processing { setVoice(.responding) }
        sentencesStarted = max(sentencesStarted, i)
        fireVisuals(upTo: i)
    }

    private func speechFinished() {
        if voiceState == .responding || voiceState == .processing, currentTurn == nil { setVoice(.idle) }
        guard currentTurn == nil else { return }   // a tool is still running; more speech is coming
        CursorOverlayController.shared.showCursorBubble(nil)
        fireVisuals(upTo: Int.max)
        scheduleClear()
        if turnIsText { scheduleTextDismiss() }
        drainQueuedSpeech()
    }

    /// Queued agent updates first (they go through the conversation), then fixed announcements.
    private func drainQueuedSpeech() {
        if !pendingAgentUpdates.isEmpty {
            let note = pendingAgentUpdates.removeFirst()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, self.voiceState == .idle, !self.player.isActive else { self?.pendingAgentUpdates.insert(note, at: 0); return }
                self.speakAgentUpdate(note)
            }
            return
        }
        if !pendingAnnouncements.isEmpty {
            let next = pendingAnnouncements.removeFirst()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.announce(next)
            }
        }
    }

    /// Binds the visuals a deeper pass produced to the sentences the voice model then spoke (the reference syncs
    /// drawing beats to playback the same way): a tag's position in the deeper answer picks the sentence.
    private func bindDeferredVisuals(_ turn: CompanionTurn) {
        guard !turn.deferredVisuals.isEmpty else { return }
        let base = turn.deferredSentenceBase
        let spoken = player.sentences.count - base
        for v in turn.deferredVisuals {
            let sentence = turn.voice && spoken > 0 ? base + min(spoken - 1, Int((v.fraction * Double(spoken)).rounded(.down))) : Int.max - 1
            pendingVisuals.append((turn.voice && spoken > 0 ? sentence : -1, v.visual))
        }
        turn.deferredVisuals = []
        fireVisuals(upTo: max(sentencesStarted, -1))
    }

    /// Every visual shown this process (self-tests read it).
    private(set) var firedVisuals: [ResolvedVisual] = []

    func fireVisuals(upTo sentence: Int) {
        let due = pendingVisuals.filter { $0.sentence <= sentence }
        guard !due.isEmpty else { return }
        pendingVisuals.removeAll { $0.sentence <= sentence }
        firedVisuals += due.map(\.visual)
        if Self.headless { return }
        let points = due.compactMap { if case let .point(p) = $0.visual { return p } else { return nil } }
        let annotations = due.compactMap { if case let .annotation(a) = $0.visual { return a } else { return nil } }
        if !annotations.isEmpty { CursorOverlayController.shared.annotate(annotations) }
        if !points.isEmpty { CursorOverlayController.shared.fly(to: points) }
    }

    /// Highlights and shapes clear a moment after Awan stops talking (an armed target stays).
    private func scheduleClear() {
        clearTask?.cancel()
        guard guided == nil, !Self.headless else { return }
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

    // MARK: - Screens and documents

    static func captureFrames() async -> [ScreenCaptureFrame] {
        do { return try await ScreenCapture.captureAll() } catch {
            Log.error("screen capture: \(error.localizedDescription)")
            return []
        }
    }

    /// The front window's document (whole text), read while the user talks. Gives up after 2.5 s (a folder-access
    /// prompt can hold the read) so the turn never waits on it.
    static func readActiveDocument(app: NSRunningApplication?) async -> ActiveDocument? {
        guard let app else { return nil }
        let doc = await withTaskGroup(of: ActiveDocument?.self) { group -> ActiveDocument? in
            group.addTask { await ActiveDocumentReader.read(app: app) }
            group.addTask { try? await Task.sleep(for: .seconds(2.5)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let doc { Log.info("companion: front document \(doc.kind) \"\(doc.name)\" (\(doc.text.count) chars, \(doc.source))") }
        return doc
    }

    /// Reads the front window's document when the question plausibly refers to it (else nil, no latency).
    static func readDocumentIfAsked(_ question: String, app: NSRunningApplication?) async -> ActiveDocument? {
        guard ActiveDocumentReader.refersToDocument(question), let app else { return nil }
        return await ActiveDocumentReader.read(app: app)
    }

    /// PROFILE.md + VOLATILE.md (if present) + the current local time (the deeper pass and legacy /respond).
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

    // MARK: - Legacy single-shot body (self-tests, onboarding demo)

    struct RespondBody: Encodable {
        var transcript: String
        var images: [[String: String]]
        var history: [CompanionExchange]
        var requestId: String
        var context: String?
        var document: [String: String]?
        var activeSkills: [String]?
    }

    static func requestBody(transcript: String, frames: [ScreenCaptureFrame], history: [CompanionExchange], requestId: String, document: ActiveDocument? = nil) -> RespondBody {
        RespondBody(transcript: transcript, images: frames.map(\.requestImage), history: Array(history.suffix(historyLimit)),
                    requestId: requestId, context: contextBlock(), document: document?.requestBody,
                    activeSkills: SkillsStore.shared.companionSlugs)
    }

    /// The spoken transcript plus tags that came through a realtime tool (anchored at the end).
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

    func guidedStepsLeft() -> Int { Self.maxGuidedSteps - guidedStep }

    /// Arms a walkthrough target from a deeper-pass answer.
    func armGuided(goal: String, label: String?) {
        guided = guided ?? Guided(goal: goal, completed: [])
        guidedStep += 1
        if Self.headless { return }
        CursorOverlayController.shared.onTargetHit = { [weak self] hit in
            Task { @MainActor in self?.guidedTargetHit(hit ?? label) }
        }
    }

    /// The walkthrough has no further target: it's complete.
    func endGuidedIfDone() {
        guard guided != nil else { return }
        guided = nil
        guidedStep = 0
        if !Self.headless { CursorOverlayController.shared.onTargetHit = nil }
    }

    /// The user clicked the armed target: the deeper pass looks at the new screen and plans the next step, then the
    /// voice model says it (one step per click, like the reference's click-to-advance loop).
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
        let app = Self.userFrontApp()
        responseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450)) // let the click's effect render
            let frames = await Self.captureFrames()
            guard let self, !Task.isCancelled else { return }
            let turn = CompanionTurn(userText: nil, display: "", frames: frames, document: nil, drawing: nil, app: app, speak: true)
            turn.guidedGoal = g.goal
            let note = await CompanionTools.guidedNote(prompt: prompt, step: step, turn: turn, engine: self)
            guard !Task.isCancelled else { return }
            await self.runNoteTurn(turn, note: note, toolChoice: "none")
        }
    }

    /// The follow-up sent after the user clicks an armed [TARGET] (the whole walkthrough costs one talk).
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

    /// Words spoken to a specific Awan (notch/HUD follow-up): delivered to it, and Awan acknowledges in one line.
    private func followUp(_ words: String, to slug: String) async {
        guard let name = sendToAwan(words, slug: slug, display: words, announce: false) else { setVoice(.idle); return }
        conversation.record("user", words)
        conversation.record("event", "(delivered to \(name) as a follow-up)")
        let turn = CompanionTurn(userText: nil, display: words, frames: [], document: nil, drawing: nil, app: turnApp, speak: true)
        let note = "[app] the user just spoke a follow-up to \(name), and awan already delivered their exact words to it: \"\(words.prefix(400))\". in ONE short warm sentence, acknowledge it in first person as if you're on it, reflecting back what they asked (\"on it, i'll make that page brighter.\"). don't mention agents or passing it along, don't do the task or answer it, and don't ask a question."
        await runNoteTurn(turn, note: note, toolChoice: "none")
    }

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
        Log.info("companion → \(chosen): \(task.prefix(200))")
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
        if voiceState == .listening { audioLevel = level; if level > peakLevel { peakLevel = level } }
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

    func setVoice(_ s: VoiceState) {
        if voiceState != s { voiceState = s }
        if !Self.headless { CursorOverlayController.shared.setVoiceState(s) }
    }
}

/// Everything one turn knows (screens, document, drawing), shared by its model rounds and its tools.
@MainActor
final class CompanionTurn {
    let id = UUID().uuidString
    /// The user's words for the model (nil for app-started turns).
    let userText: String?
    /// What the user said, as shown and recorded.
    let display: String
    var frames: [ScreenCaptureFrame]
    var document: ActiveDocument?
    var drawing: String?
    let app: NSRunningApplication?
    let speak: Bool
    var voice = false
    var toolCalls = 0
    /// Visuals from a deeper pass, waiting to be bound to the sentences the voice model speaks next.
    var deferredVisuals: [(fraction: Double, visual: ResolvedVisual)] = []
    var deferredSentenceBase = 0
    /// Set for walkthrough steps (the goal the deeper pass keeps working toward).
    var guidedGoal: String?
    /// Files the user attached (dropped on the mascot). Small images also ride along as pictures.
    var attachments: [URL] = []
    var attachedImages: [ScreenCaptureFrame] = []
    /// Tools offered this turn (nil = all). Files that need an Awan leave only the hand-off tools.
    var capabilities: [String]?

    init(userText: String?, display: String, frames: [ScreenCaptureFrame], document: ActiveDocument?, drawing: String?, app: NSRunningApplication?, speak: Bool) {
        self.userText = userText
        self.display = display
        self.frames = frames
        self.document = document
        self.drawing = drawing
        self.app = app
        self.speak = speak
    }

    var geometries: [CaptureGeometry] { frames.map(\.geometry) }
}

