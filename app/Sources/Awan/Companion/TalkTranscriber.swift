// Adapted from farzaa/clicky (MIT) — AppleSpeechTranscriptionProvider (partials, on-device, final-result fallback delay).
import AVFoundation
import Speech

/// Live speech-to-text for one talk turn: Apple Speech with partial results (on-device when supported),
/// falling back to the server's POST /v1/transcribe when Apple Speech is unavailable, denied, or hears nothing.
///
///   let stt = TalkTranscriber()
///   stt.onPartial = { text in … }    // main thread
///   stt.start()
///   mic.onBuffer = { stt.append($0) } // any thread
///   let text = await stt.finish(pcm16: mic.stop())
final class TalkTranscriber: @unchecked Sendable {
    var onPartial: ((String) -> Void)?

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var finalText: String?
    private var finalWaiters: [CheckedContinuation<Void, Never>] = []
    private var ended = false
    private var waitClosed = false
    private(set) var usingAppleSpeech = false

    /// Apple Speech is usable right now (authorized + a recognizer for the locale).
    static var appleSpeechAvailable: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && (recognizer()?.isAvailable ?? false)
    }

    /// Ask once, only from a real bundle (an unbundled binary without the usage string would crash).
    static func requestAuthorizationIfNeeded() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined,
              Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else { return }
        SFSpeechRecognizer.requestAuthorization { status in Log.info("speech recognition authorization: \(status.rawValue)") }
    }

    private static func recognizer() -> SFSpeechRecognizer? {
        for locale in [Locale.autoupdatingCurrent, Locale(identifier: "en-US")] {
            if let r = SFSpeechRecognizer(locale: locale) { return r }
        }
        return SFSpeechRecognizer()
    }

    func start(contextualStrings: [String] = []) {
        guard Self.appleSpeechAvailable, let recognizer = Self.recognizer() else {
            usingAppleSpeech = false
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        req.contextualStrings = contextualStrings
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        lock.lock(); request = req; usingAppleSpeech = true; lock.unlock()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let req = ended ? nil : request; lock.unlock()
        req?.append(buffer)
    }

    /// Ends the audio and returns the best transcript. Waits ≤1.8 s for Apple's final result,
    /// then uses the server when Apple produced nothing (or wasn't used).
    func finish(pcm16: Data) async -> String {
        let req: SFSpeechAudioBufferRecognitionRequest? = lock.withLock { ended = true; return request }
        var text = ""
        if let req {
            req.endAudio()
            await waitForFinal(timeout: 1.8)
            text = lock.withLock { finalText ?? latest }
            task?.finish()
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, AudioCapture.duration(ofPCM16: pcm16) >= 0.35 {
            do { text = try await Self.transcribeOnServer(pcm16: pcm16) } catch { Log.error("server transcribe failed: \(error.localizedDescription)") }
        }
        return text
    }

    func cancel() {
        lock.lock(); ended = true; waitClosed = true; let waiters = finalWaiters; finalWaiters = []; lock.unlock()
        task?.cancel()
        task = nil
        waiters.forEach { $0.resume() }
    }

    /// POST /v1/transcribe with a 16 kHz mono WAV.
    static func transcribeOnServer(pcm16: Data, kind: String = "talk") async throws -> String {
        struct R: Decodable { var text: String }
        let body: [String: JSON] = [
            "audio": .string(WAVWriter.data(pcm16: pcm16).base64EncodedString()),
            "format": "wav",
            "kind": .string(kind),
            "dictionary": .array(await MainActor.run { Prefs.shared.dictionary }.prefix(50).map { .string($0) }),
        ]
        let r: R = try await APIClient.shared.send("v1/transcribe", method: "POST", body: body)
        return r.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Recognition callbacks

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            lock.lock(); latest = text; lock.unlock()
            if let onPartial { DispatchQueue.main.async { onPartial(text) } }
            if result.isFinal { deliverFinal(text) }
            return
        }
        if error != nil {
            lock.lock(); let t = latest; lock.unlock()
            deliverFinal(t)
        }
    }

    private func deliverFinal(_ text: String) {
        lock.lock()
        if finalText == nil { finalText = text }
        let waiters = finalWaiters
        finalWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    private func waitForFinal(timeout: Double) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    guard let self else { c.resume(); return }
                    self.lock.lock()
                    if self.finalText != nil || self.waitClosed { self.lock.unlock(); c.resume(); return }
                    self.finalWaiters.append(c)
                    self.lock.unlock()
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)) }
            await group.next()
            group.cancelAll()
            // Release a still-pending waiter so the first child can finish.
            let w: [CheckedContinuation<Void, Never>] = self.lock.withLock {
                self.waitClosed = true
                defer { self.finalWaiters = [] }
                return self.finalWaiters
            }
            w.forEach { $0.resume() }
        }
    }
}
