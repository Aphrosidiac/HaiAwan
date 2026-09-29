import AVFoundation
import Speech

/// Microphone capture for dictation (and the onboarding interview / mic check):
/// one AVAudioEngine tap feeding Apple Speech for live partials, a level meter, and an optional
/// 16 kHz mono WAV on disk (kept for recovery, and sent to the server if Apple Speech is unavailable).
/// Callbacks arrive on the main queue.
final class SpeechCapture: @unchecked Sendable {
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private(set) var fileURL: URL?
    private var latest = ""
    private var finished = false
    private var finalWaiter: ((String) -> Void)?
    private var lastLevelAt = Date.distantPast

    static var micStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var speechStatus: SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }

    /// - Parameters:
    ///   - locale: nil = the Mac's current language.
    ///   - recordTo: write a WAV here (nil = don't record).
    ///   - recognize: run Apple Speech (needs Speech Recognition permission).
    func start(locale: Locale?, contextualStrings: [String] = [], recordTo: URL? = nil, recognize: Bool = true) throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Awan.Dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }

        if recognize, Self.speechStatus == .authorized {
            let r = locale.flatMap { SFSpeechRecognizer(locale: $0) } ?? SFSpeechRecognizer()
            if let r, r.isAvailable {
                let req = SFSpeechAudioBufferRecognitionRequest()
                req.shouldReportPartialResults = true
                req.contextualStrings = Array(contextualStrings.prefix(100))
                req.addsPunctuation = true
                req.taskHint = .dictation
                recognizer = r
                request = req
                task = r.recognitionTask(with: req) { [weak self] result, error in
                    guard let self else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        self.lock.lock(); self.latest = text; self.lock.unlock()
                        DispatchQueue.main.async { self.onPartial?(text) }
                        if result.isFinal { self.resolve(text) }
                    } else if error != nil {
                        self.lock.lock(); let t = self.latest; self.lock.unlock()
                        self.resolve(t)
                    }
                }
            }
        }

        if let recordTo {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ]
            file = try AVAudioFile(forWriting: recordTo, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            converter = AVAudioConverter(from: inFormat, to: fileFormat)
            fileURL = recordTo
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)

        // level: RMS of the first channel → 0…1 on a -50…0 dB scale
        if let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in 0 ..< n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(n))
            let db = 20 * log10(max(rms, 0.000_01))
            let level = max(0, min(1, (db + 50) / 50))
            let now = Date()
            if now.timeIntervalSince(lastLevelAt) > 0.04 {
                lastLevelAt = now
                DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
            }
        }

        if let file, let converter {
            let ratio = fileFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if out.frameLength > 0 { try? file.write(from: out) }
        }
    }

    private func resolve(_ text: String) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        if !text.isEmpty { latest = text }
        let result = latest
        let waiter = finalWaiter
        finalWaiter = nil
        lock.unlock()
        waiter?(result)
    }

    /// Stop the mic and wait (briefly) for Apple Speech's final transcript.
    func stop(timeout: Double = 1.6) async -> (text: String, file: URL?) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil   // closes the WAV
        guard let request else { return ("", fileURL) }
        request.endAudio()
        let text: String = await withCheckedContinuation { cont in
            lock.lock()
            let alreadyDone = finished
            let current = latest
            if !alreadyDone {
                finalWaiter = { cont.resume(returning: $0) }
            }
            lock.unlock()
            if alreadyDone { cont.resume(returning: current); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let t = self.latest; self.lock.unlock()
                self.resolve(t)
            }
        }
        task?.cancel()
        task = nil
        self.request = nil
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), fileURL)
    }

    /// Drop everything (Escape / cancel): no transcript, recording deleted.
    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        task?.cancel()
        task = nil
        request = nil
        file = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }
}
