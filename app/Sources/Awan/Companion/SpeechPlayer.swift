import AVFoundation

/// Splits streamed reply text into speakable sentences so TTS can start on the first one
/// while the rest is still arriving. Deterministic on content (delta boundaries don't matter).
struct SentenceChunker {
    private var buffer = ""
    /// Shorter pieces are held and merged with the next sentence ("ok." "sure.").
    var minimumLength = 14
    /// Very long runs without punctuation are split at a comma or space.
    var maximumLength = 240

    mutating func push(_ text: String) -> [String] {
        buffer += text
        var out: [String] = []
        while let cut = nextCut() {
            let piece = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[cut...])
            if !piece.isEmpty { out.append(piece) }
        }
        return out
    }

    mutating func flush() -> String? {
        let piece = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return piece.isEmpty ? nil : piece
    }

    /// Index just after a sentence end (terminator followed by whitespace, or a newline) past the minimum length.
    private func nextCut() -> String.Index? {
        var i = buffer.startIndex
        var count = 0
        while i < buffer.endIndex {
            let ch = buffer[i]
            let next = buffer.index(after: i)
            count += 1
            if ch.isNewline, count >= 2 {
                if count >= minimumLength || buffer[..<i].trimmingCharacters(in: .whitespaces).count >= minimumLength { return next }
            }
            if ".!?…".contains(ch), next < buffer.endIndex, buffer[next].isWhitespace, count >= minimumLength {
                return next
            }
            if count >= maximumLength {
                // Split at the last comma, else the last space.
                let head = buffer[..<next]
                if let c = head.lastIndex(of: ",") { return buffer.index(after: c) }
                if let s = head.lastIndex(of: " ") { return s }
                return next
            }
            i = next
        }
        return nil
    }
}

/// Decides what to do with each streamed speech chunk: skip leading silence, hold short pauses,
/// stop once the silence after the words runs long.
struct SpeechSilenceGate {
    enum Decision: Equatable { case skip, hold, play, stop }
    var threshold: Float = 0.004          // ≈ -48 dBFS
    var maxTrailingSilence: Double = 2.0  // seconds — longer than a pause between sentences (some voices pause ~1.5 s)
    var sampleRate: Double = 24_000
    private(set) var heardSpeech = false
    var markerScheduled = false
    private var heldFrames = 0

    init(sampleRate: Double = 24_000) { self.sampleRate = sampleRate }

    mutating func feed(peak: Float, frames: Int) -> Decision {
        if peak >= threshold {
            heardSpeech = true
            heldFrames = 0
            return .play
        }
        guard heardSpeech else { return .skip }
        heldFrames += frames
        return Double(heldFrames) / sampleRate > maxTrailingSilence ? .stop : .hold
    }
}

/// Plays Awan's voice: streams 24 kHz mono PCM16 from POST /v1/speech into an AVAudioPlayerNode as chunks arrive,
/// one request per sentence (so the first sentence starts while the reply is still streaming).
/// Falls back to AVSpeechSynthesizer when the server has no speech.
@MainActor
final class SpeechPlayer: NSObject, AVSpeechSynthesizerDelegate {
    /// First audible sound of this utterance.
    var onStart: (() -> Void)?
    /// Sentence `i` (in enqueue order) begins playing.
    var onSentenceStart: ((Int) -> Void)?
    /// Everything enqueued has played (not called after `stop()`).
    var onFinish: (() -> Void)?

    private(set) var isActive = false
    /// Where speech PCM comes from (default: POST /v1/speech through APIClient). The self-test injects its own.
    var speechSource: (_ body: [String: JSON]) -> AsyncThrowingStream<Data, Error> = { SpeechCache.stream($0) }
    /// 0…1 on the output mixer (the self-test runs silent).
    var outputVolume: Float = 1
    private(set) var sentences: [String] = []

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var graphReady = false

    private var generation = 0
    private var worker: Task<Void, Never>?
    private var nextToFetch = 0
    private var inputFinished = false
    private var pendingBuffers = 0
    private var started = false
    private var useSynth = false
    private let synth = AVSpeechSynthesizer()
    private var synthDone: CheckedContinuation<Void, Never>?
    private var idleStopTask: Task<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Starts a new utterance (stops whatever was playing).
    func begin(serverSpeech: Bool = true) {
        stop()
        generation += 1
        sentences = []
        nextToFetch = 0
        inputFinished = false
        pendingBuffers = 0
        started = false
        rawCarry = Data()
        useSynth = !serverSpeech
        isActive = true
    }

    func enqueue(_ sentence: String) {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActive, !s.isEmpty else { return }
        sentences.append(s)
        pump()
    }

    /// Realtime voice: raw 24 kHz mono PCM16 as it arrives (no sentence pipeline, no silence gate).
    /// Call `begin()` first and `finishInput()` when the response is done.
    func playPCM16(_ chunk: Data) {
        guard isActive else { return }
        var data = rawCarry
        data.append(chunk)
        let usable = data.count & ~1
        rawCarry = usable < data.count ? Data(data.suffix(1)) : Data()
        guard usable > 0, let buffer = makeBuffer(Data(data.prefix(usable))), ensureEngine() else { return }
        if !started { started = true; onStart?() }
        schedule(buffer, gen: generation)
    }
    private var rawCarry = Data()

    func finishInput() {
        guard isActive else { return }
        inputFinished = true
        pump()
        checkDone()
    }

    func stop() {
        generation += 1
        worker?.cancel()
        worker = nil
        if player.isPlaying || graphReady { player.stop() }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        synthDone?.resume(); synthDone = nil
        pendingBuffers = 0
        isActive = false
        scheduleEngineIdleStop()
    }

    // MARK: - Pipeline

    private func pump() {
        guard worker == nil, nextToFetch < sentences.count else { return }
        let gen = generation
        worker = Task { [weak self] in
            while let self, gen == self.generation, self.nextToFetch < self.sentences.count {
                let index = self.nextToFetch
                self.nextToFetch += 1
                await self.speak(self.sentences[index], index: index, gen: gen)
            }
            guard let self, gen == self.generation else { return }
            self.worker = nil
            self.checkDone()
        }
    }

    private func speak(_ text: String, index: Int, gen: Int) async {
        if !useSynth {
            let ok = await streamFromServer(text, index: index, gen: gen)
            if ok || gen != generation { return }
            Log.info("speech: server speech unavailable, using the system voice")
            useSynth = true
        }
        // System voice: wait for queued server audio to drain so voices don't overlap.
        while pendingBuffers > 0, gen == generation { try? await Task.sleep(for: .milliseconds(40)) }
        guard gen == generation else { return }
        markStarted(index)
        await speakWithSynth(text)
    }

    /// Returns false when the server produced no audio at all.
    /// Leading silence is skipped (lower latency) and a long trailing silence ends the sentence early —
    /// the speech model can keep streaming digital silence long after the words are done.
    private func streamFromServer(_ text: String, index: Int, gen: Int) async -> Bool {
        let speed = Prefs.shared.speechSpeed
        let body: [String: JSON] = ["text": .string(text), "voice": .string(Prefs.shared.voiceID), "speed": .number(speed)]
        var carry = Data()
        var got = 0
        var gate = SpeechSilenceGate(sampleRate: format.sampleRate)
        var held: [AVAudioPCMBuffer] = []
        do {
            stream: for try await chunk in speechSource(body) {
                guard gen == generation else { return true }
                var data = carry
                data.append(chunk)
                let usable = data.count & ~1
                carry = usable < data.count ? Data(data.suffix(1)) : Data()
                guard usable > 0, let buffer = makeBuffer(Data(data.prefix(usable))) else { continue }
                got += usable
                switch gate.feed(peak: Self.peak(buffer), frames: Int(buffer.frameLength)) {
                case .skip:
                    continue
                case .hold:
                    held.append(buffer)
                case .stop:
                    break stream
                case .play:
                    guard ensureEngine() else { return false }
                    if !gate.markerScheduled { gate.markerScheduled = true; scheduleMarker(for: index, gen: gen) }
                    held.forEach { schedule($0, gen: gen) }
                    held = []
                    schedule(buffer, gen: gen)
                }
            }
        } catch {
            Log.error("speech stream failed: \(error.localizedDescription)")
        }
        guard gen == generation else { return true }
        if gate.heardSpeech, let gap = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * 0.14)) {
            gap.frameLength = gap.frameCapacity   // a short breath between sentences (zero-filled)
            memset(gap.floatChannelData![0], 0, Int(gap.frameLength) * MemoryLayout<Float>.size)
            schedule(gap, gen: gen)
        }
        return got > 0 && gate.heardSpeech
    }

    static func peak(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData?[0] else { return 0 }
        var m: Float = 0
        for i in 0 ..< Int(b.frameLength) { m = max(m, abs(ch[i])) }
        return m
    }

    private func makeBuffer(_ pcm: Data) -> AVAudioPCMBuffer? {
        let frames = pcm.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        let out = buf.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0 ..< frames {
                let v = Int16(bitPattern: UInt16(bytes[2 * i]) | (UInt16(bytes[2 * i + 1]) << 8))
                out[i] = Float(v) / 32768
            }
        }
        return buf
    }

    private func ensureEngine() -> Bool {
        idleStopTask?.cancel()
        if !graphReady {
            engine.attach(player)
            engine.attach(timePitch)
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            graphReady = true
        }
        timePitch.rate = Float(max(0.5, min(1.5, Prefs.shared.speechSpeed)))
        engine.mainMixerNode.outputVolume = outputVolume
        if !engine.isRunning {
            do { try engine.start() } catch {
                Log.error("speech engine: \(error.localizedDescription)")
                return false
            }
        }
        if !player.isPlaying { player.play() }
        return true
    }

    /// A one-frame silent buffer whose playback marks the moment sentence `index` becomes audible.
    private func scheduleMarker(for index: Int, gen: Int) {
        guard let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else { return }
        marker.frameLength = 1
        marker.floatChannelData![0][0] = 0
        pendingBuffers += 1
        player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.pendingBuffers -= 1
                self.markStarted(index)
            }
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, gen: Int) {
        pendingBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.pendingBuffers -= 1
                self.checkDone()
            }
        }
    }

    private func markStarted(_ index: Int) {
        if !started { started = true; onStart?() }
        onSentenceStart?(index)
    }

    private func checkDone() {
        guard isActive, inputFinished, worker == nil, nextToFetch >= sentences.count, pendingBuffers <= 0, !synth.isSpeaking else { return }
        isActive = false
        scheduleEngineIdleStop()
        onFinish?()
    }

    private func scheduleEngineIdleStop() {
        idleStopTask?.cancel()
        idleStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, !self.isActive else { return }
            self.player.stop()
            self.engine.stop()
        }
    }

    // MARK: - System voice fallback

    private func speakWithSynth(_ text: String) async {
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.bestSystemVoice
        u.volume = outputVolume
        u.rate = AVSpeechUtteranceDefaultSpeechRate * Float(max(0.5, min(1.5, Prefs.shared.speechSpeed)))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            synthDone = c
            synth.speak(u)
        }
    }

    private static var bestSystemVoice: AVSpeechSynthesisVoice? {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.synthDone?.resume(); self.synthDone = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.synthDone?.resume(); self.synthDone = nil }
    }
}
