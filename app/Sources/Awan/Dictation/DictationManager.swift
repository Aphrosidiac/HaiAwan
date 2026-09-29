import AppKit
import AVFoundation
import Speech

/// Hold-to-dictate (fn ⌃) and hands-free dictation (double-tap fn ⌃).
/// start → live partials in the notch pill → stop → clean-up (server, else local) → typed at the cursor
/// (Accessibility, else ⌘V, else clipboard) → watch the field ~20 s to learn corrected spellings.
/// Public API (keep): isDictating, isHandsFree, partialText, start(handsFree:), stop(), cancel()
@MainActor
final class DictationManager: ObservableObject {
    static let shared = DictationManager()

    @Published var isDictating = false
    @Published var isHandsFree = false
    @Published var partialText = ""
    /// 0…1 mic level for the pill's waveform.
    @Published var level: Float = 0
    /// What the notch pill shows.
    @Published var surface: SurfaceState = .live
    /// The last text Awan typed (the tutorial watches this).
    @Published private(set) var lastInsertedText: String?
    @Published private(set) var lastOutcome: TextInserter.Outcome?

    enum SurfaceState: Equatable {
        case live                  // waveform + live words
        case finishing             // tidying up
        case clipboard(String)     // "Copied — paste with ⌘V" (or why)
        case learned(String)       // Added “X” to your dictionary
        case limit                 // free dictation used up (shown once per launch)
        case problem(String)       // mic missing / denied
    }

    static let keepRecordings = 10

    private var capture: SpeechCapture?
    private var requestID = ""
    private var startedAt = Date()
    private var shownLimitHint = false
    private var finishing = false
    private var snapshotMode: Bool { CommandLine.arguments.contains("--snapshot") }

    // MARK: - Public API

    func start(handsFree: Bool) {
        if isDictating {
            if handsFree { isHandsFree = true }
            return
        }
        guard !finishing else { return }
        switch SpeechCapture.micStatus {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                Task { @MainActor in
                    if ok { self.start(handsFree: handsFree) } else { self.showProblem("Awan can't hear you. Turn on the microphone in System Settings.") }
                }
            }
            return
        case .denied, .restricted:
            showProblem("Awan can't hear you. Turn on the microphone in System Settings.")
            return
        default: break
        }
        if SpeechCapture.speechStatus == .notDetermined {
            // Ask once; this dictation still works (the recording is transcribed by Awan's server).
            SFSpeechRecognizer.requestAuthorization { _ in }
        }

        let prefs = Prefs.shared
        let locale: Locale? = prefs.dictationAutoDetect ? nil : Locale(identifier: prefs.dictationLanguage)
        let cap = SpeechCapture()
        cap.onPartial = { [weak self] text in self?.partialText = text }
        cap.onLevel = { [weak self] l in self?.level = l }
        requestID = UUID().uuidString
        let url = snapshotMode ? nil : Paths.recordings.appendingPathComponent("dictation-\(Self.stamp()).wav")
        do {
            try cap.start(locale: locale, contextualStrings: prefs.dictionary, recordTo: url)
        } catch {
            Log.error("dictation start failed: \(error.localizedDescription)")
            showProblem("I couldn't open your microphone.")
            return
        }
        capture = cap
        partialText = ""
        level = 0
        surface = .live
        startedAt = Date()
        isHandsFree = handsFree
        isDictating = true
        DictionaryLearner.shared.cancel()
        Sounds.play(.listenStart, volume: 0.3)
        NotchController.shared.present(.dictation, for: nil)
    }

    func stop() {
        guard isDictating, let cap = capture else { return }
        isDictating = false
        isHandsFree = false
        capture = nil
        finishing = true
        surface = .finishing
        Sounds.play(.listenEnd, volume: 0.3)
        Task { await finish(cap) }
    }

    func cancel() {
        capture?.cancel()
        capture = nil
        isDictating = false
        isHandsFree = false
        partialText = ""
        level = 0
        NotchController.shared.dismissSurface()
    }

    // MARK: - Finish: transcript → clean → insert

    private func finish(_ cap: SpeechCapture) async {
        defer { finishing = false; level = 0 }
        let prefs = Prefs.shared
        let language = prefs.dictationAutoDetect ? nil : prefs.dictationLanguage
        let (text, file) = await cap.stop()
        var raw = text.isEmpty ? partialText : text
        if raw.isEmpty, let file, Date().timeIntervalSince(startedAt) > 0.4 {
            raw = (try? await DictationCleanup.transcribe(file: file, requestId: requestID, language: language, dictionary: prefs.dictionary)) ?? ""
        }
        Self.pruneRecordings()
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            partialText = ""
            NotchController.shared.dismissSurface()
            return
        }

        let appName = NSWorkspace.shared.frontmostApplication?.localizedName
        let cleaned = await DictationCleanup.clean(raw, requestId: requestID, appName: appName, dictionary: prefs.dictionary, language: language)
        partialText = cleaned.text
        let outcome = await TextInserter.insert(cleaned.text)
        lastOutcome = outcome
        Log.info("dictation: \(cleaned.source), \(outcome)")

        switch outcome {
        case .inserted, .pasted:
            lastInsertedText = cleaned.text
            if cleaned.limited && !shownLimitHint {
                shownLimitHint = true
                show(.limit, seconds: 6)
            } else {
                NotchController.shared.dismissSurface()
            }
            if let el = TextInserter.lastElement {
                DictionaryLearner.shared.watch(el, inserted: cleaned.text) { [weak self] word in
                    DictionaryLearner.learn(word)
                    self?.show(.learned(word), seconds: 3.5)
                }
            }
        case let .clipboard(reason):
            lastInsertedText = cleaned.text
            show(.clipboard(reason == "accessibility" ? "Copied. Paste with ⌘V (turn on Accessibility to type for you)" : "Copied. Paste with ⌘V"), seconds: 4)
        case .refusedSecure:
            show(.clipboard("That's a password field, so I didn't type there."), seconds: 4)
        case .empty:
            NotchController.shared.dismissSurface()
        }
    }

    private func show(_ state: SurfaceState, seconds: Double) {
        surface = state
        NotchController.shared.present(.dictation, for: seconds)
    }

    private func showProblem(_ text: String) {
        show(.problem(text), seconds: 4)
    }

    // MARK: - Recordings (last 10 kept for recovery)

    static func pruneRecordings() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.recordings, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let recordings = files.filter { $0.lastPathComponent.hasPrefix("dictation-") }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
        for old in recordings.dropFirst(keepRecordings) { try? fm.removeItem(at: old) }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    // MARK: - Snapshot / demo

    func installDemo(_ state: SurfaceState, partial: String, handsFree: Bool, level: Float = 0.6) {
        surface = state
        partialText = partial
        isHandsFree = handsFree
        isDictating = state == .live
        self.level = level
    }
}
