// Adapted from farzaa/clicky (MIT) — BuddyPCM16AudioConverter + BuddyWAVFileBuilder.
//
// AudioCapture — the microphone, shared by the companion (talk, always-on) and dictation.
//
//   let mic = AudioCapture(deviceUID: Prefs.shared.microphoneUID)   // "" or nil = the system default input
//   mic.onLevel  = { level in … }   // MAIN thread, 0…1, smoothed (fast attack, slow release) — waveforms, VAD
//   mic.onBuffer = { buf in … }     // AUDIO thread, native-format AVAudioPCMBuffer — feed SFSpeechAudioBufferRecognitionRequest
//   mic.onPCM16  = { data in … }    // AUDIO thread, 16 kHz mono Int16 little-endian chunks — feed a streaming STT socket
//   try mic.start()                 // throws AudioCaptureError (no permission / no input device / engine failure)
//   mic.recordedPCM16               // everything captured so far (16 kHz mono PCM16), thread-safe copy
//   mic.resetRecording(keepingLast: 0.3)   // drop the buffer but keep a pre-roll (always-on turns)
//   let pcm = mic.stop()            // stops and returns the full 16 kHz mono PCM16 recording
//   let wav = WAVWriter.data(pcm16: pcm)                 // → RIFF/WAVE bytes (16 kHz mono by default)
//   try WAVWriter.write(pcm16: pcm, to: url)
//   AudioCapture.duration(ofPCM16: pcm)                  // seconds
//   AudioCapture.inputDevices()     // [AudioInputDevice(uid:name:)] for Settings → Microphone
//   AudioCapture.microphoneStatus / requestMicrophoneAccess()   // permission (never prompts from an unbundled binary)
//   AudioCapture.isDefaultInputBusyElsewhere           // mic in use by some process (call detection)
//   AudioCapture.defaultOutputIsBuiltInSpeaker         // for the always-on headphones warning
import AVFoundation
import CoreAudio
import AudioToolbox

struct AudioInputDevice: Hashable, Identifiable {
    var uid: String
    var name: String
    var id: String { uid }
}

enum AudioCaptureError: LocalizedError {
    case permissionDenied, noInputDevice, engine(String)
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Awan can't hear you yet — turn on Microphone for Awan in System Settings → Privacy & Security."
        case .noInputDevice: return "No microphone found."
        case let .engine(m): return "The microphone didn't start: \(m)"
        }
    }
}

final class AudioCapture: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    var onLevel: ((Float) -> Void)?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onPCM16: ((Data) -> Void)?

    private let deviceUID: String?
    private let engine = AVAudioEngine()
    private let converter = PCM16Converter(targetSampleRate: AudioCapture.sampleRate)
    private let lock = NSLock()
    private var pcm = Data()
    private var smoothed: Float = 0
    private(set) var isRunning = false

    init(deviceUID: String? = nil) {
        self.deviceUID = (deviceUID?.isEmpty ?? true) ? nil : deviceUID
    }

    deinit { if isRunning { _ = stop() } }

    func start() throws {
        guard !isRunning else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted {
            throw AudioCaptureError.permissionDenied
        }
        let input = engine.inputNode
        if let uid = deviceUID, let dev = Self.deviceID(forUID: uid), let unit = input.audioUnit {
            var id = dev
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.error("mic: couldn't select device \(uid) (\(status)), using default") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.noInputDevice }
        lock.lock(); pcm.removeAll(keepingCapacity: true); smoothed = 0; lock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engine(error.localizedDescription)
        }
        isRunning = true
    }

    @discardableResult
    func stop() -> Data {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        DispatchQueue.main.async { [onLevel] in onLevel?(0) }
        return recordedPCM16
    }

    var recordedPCM16: Data {
        lock.lock(); defer { lock.unlock() }
        return pcm
    }

    func resetRecording(keepingLast seconds: Double = 0) {
        lock.lock(); defer { lock.unlock() }
        let keep = min(pcm.count, Int(seconds * Self.sampleRate) * 2)
        pcm = keep > 0 ? Data(pcm.suffix(keep)) : Data()
    }

    static func duration(ofPCM16 data: Data, sampleRate: Double = sampleRate) -> TimeInterval {
        Double(data.count / 2) / sampleRate
    }

    // MARK: Audio thread

    private func handle(_ buffer: AVAudioPCMBuffer) {
        onBuffer?(buffer)
        let level = Self.normalizedLevel(Self.rms(buffer))
        if let chunk = converter.convert(buffer) {
            lock.lock(); pcm.append(chunk); lock.unlock()
            onPCM16?(chunk)
        }
        lock.lock()
        smoothed = level > smoothed ? smoothed + (level - smoothed) * 0.6 : smoothed * 0.85 + level * 0.15
        let out = smoothed
        lock.unlock()
        if let onLevel { DispatchQueue.main.async { onLevel(out) } }
    }

    /// `Awan --mic-selftest`: record 2 s from the talk mic and log what actually arrived. All-zero samples mean
    /// macOS is blanking the input (privacy), no buffers mean the engine never ran; real rooms are never exactly 0.
    static func selfTest() {
        let mic = AudioCapture(deviceUID: nil)
        var buffers = 0, peakRMS: Float = 0, nonZero = 0
        let lock = NSLock()
        mic.onBuffer = { b in
            let r = rms(b)
            lock.withLock { buffers += 1; peakRMS = max(peakRMS, r); if r > 0 { nonZero += 1 } }
        }
        let fmt = mic.engine.inputNode.outputFormat(forBus: 0)
        do { try mic.start() } catch { Log.error("mic selftest: start failed: \(error.localizedDescription)"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let pcm = mic.stop()
            let (b, p, nz) = lock.withLock { (buffers, peakRMS, nonZero) }
            let db = p > 0 ? String(format: "%.1f dB", 20 * log10(p)) : "digital silence"
            Log.info("mic selftest: \(b) buffers (\(nz) non-silent), peak \(db), \(Int(fmt.sampleRate)) Hz × \(fmt.channelCount), \(String(format: "%.2f", duration(ofPCM16: pcm))) s recorded, permission \(microphoneStatus.rawValue)")
        }
    }

    /// Root-mean-square amplitude of the first channel (0…1).
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        if let ch = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0 ..< n { sum += ch[i] * ch[i] }
            return (sum / Float(n)).squareRoot()
        }
        if let ch = buffer.int16ChannelData?[0] {
            var sum: Float = 0
            for i in 0 ..< n { let v = Float(ch[i]) / 32768; sum += v * v }
            return (sum / Float(n)).squareRoot()
        }
        return 0
    }

    /// RMS → 0…1 on a -55…-10 dBFS scale (speech sits roughly in the middle).
    static func normalizedLevel(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 55) / 45))
    }

    // MARK: Devices & permission

    static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Asks for microphone access when the bundle can (an unbundled binary without the usage string would crash).
    static func requestMicrophoneAccess() async -> Bool {
        switch microphoneStatus {
        case .authorized: return true
        case .notDetermined:
            guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else { return false }
            return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard channelCount(id, scope: kAudioDevicePropertyScopeInput) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// True when some process (possibly us) is using the default input — used for call detection.
    static var isDefaultInputBusyElsewhere: Bool {
        guard let dev = defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &running) == noErr && running != 0
    }

    /// The default output is the Mac's own speakers (not headphones / AirPods / a display).
    static var defaultOutputIsBuiltInSpeaker: Bool {
        guard let dev = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return false }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &transport) == noErr, transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        // Built-in transport covers the headphone jack too; the data source tells them apart.
        var source: UInt32 = 0
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &source) == noErr {
            return source != 0x6864706E // 'hdpn'
        }
        return true
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Converts any input buffer to mono Int16 at a target rate. Not thread-safe; use from one thread.
final class PCM16Converter {
    let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(targetSampleRate: Double = 16_000) {
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate, channels: 1, interleaved: true)!
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            inputFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let ptr = out.audioBufferList.pointee.mBuffers.mData else { return nil }
        let bytes = Int(out.frameLength) * Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        return bytes > 0 ? Data(bytes: ptr, count: bytes) : nil
    }
}

/// RIFF/WAVE wrapper for raw PCM16.
enum WAVWriter {
    static func data(pcm16: Data, sampleRate: Int = 16_000, channels: Int = 1) -> Data {
        let bits = 16
        let byteRate = sampleRate * channels * bits / 8
        let blockAlign = channels * bits / 8
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8)); d.append(le(UInt32(36 + pcm16.count)))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); d.append(le(UInt32(16))); d.append(le(UInt16(1))); d.append(le(UInt16(channels)))
        d.append(le(UInt32(sampleRate))); d.append(le(UInt32(byteRate))); d.append(le(UInt16(blockAlign))); d.append(le(UInt16(bits)))
        d.append(contentsOf: Array("data".utf8)); d.append(le(UInt32(pcm16.count)))
        d.append(pcm16)
        return d
    }

    static func write(pcm16: Data, sampleRate: Int = 16_000, to url: URL) throws {
        try data(pcm16: pcm16, sampleRate: sampleRate).write(to: url, options: .atomic)
    }

    private static func le<T: FixedWidthInteger>(_ v: T) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: MemoryLayout<T>.size)
    }
}
