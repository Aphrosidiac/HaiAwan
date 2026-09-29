import SwiftUI
import AVFoundation
import CoreAudio

/// Settings → Microphone: input device + a level-meter test.
struct MicrophoneSettings: View {
    @ObservedObject private var prefs = Prefs.shared
    @StateObject private var tester = MicLevelTester()
    @Local private var devices: [MicDevice] = []

    var body: some View {
        SettingsPageHeader(title: "Microphone", subtitle: "Which microphone Awan listens through.")

        SettingsGroup(label: "Input device") {
            let rows = [MicDevice(uid: "", name: "System Default")] + devices
            ForEach(Array(rows.enumerated()), id: \.element.uid) { i, d in
                radioRow(d, last: i == rows.count - 1)
            }
        }
        .onAppear { devices = SettingsEnv.isSnapshot ? [MicDevice(uid: "builtin", name: "MacBook Pro Microphone")] : MicDevice.all() }

        SettingsGroup(label: "Test", footer: "Speak normally — the bars should move as Awan hears you.") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 13.5) {
                    Button(tester.running ? "Stop" : "Test microphone") {
                        tester.running ? tester.stop() : tester.start(uid: prefs.microphoneUID)
                    }
                    .buttonStyle(.gel(.bone, height: 32, padding: 15.5, fontSize: 14.5))
                    LevelMeter(level: tester.level, active: tester.running)
                    Spacer(minLength: 0)
                }
                Text(tester.running ? "Listening through the selected input…" : "Tap to test selected input")
                    .font(.awan(12.5)).foregroundStyle(SettingsStyle.dim)
                    .padding(.top, 9.5)
                    .padding(.leading, 1)
            }
            .padding(.leading, 13.5).padding(.trailing, 14)
            .padding(.top, 12.5).padding(.bottom, 14.5)
            if let err = tester.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).font(.system(size: 11))
                    Text(err).font(.awan(12)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if tester.permissionDenied {
                        SmallPillButton(title: "Open Settings") { SystemSettingsPane.open(SystemSettingsPane.microphone) }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .onDisappear { tester.stop() }
        .onChange(of: prefs.microphoneUID) { _, uid in
            if tester.running { tester.stop(); tester.start(uid: uid) }
        }
    }

    /// Reference: 38 pt rows, 18 pt radio at the leading edge, title 30 pt in; selected = filled check.
    private func radioRow(_ d: MicDevice, last: Bool) -> some View {
        let on = prefs.microphoneUID == d.uid
        return Button { prefs.microphoneUID = d.uid } label: {
            HStack(spacing: 12) {
                ZStack {
                    if on {
                        Circle().fill(LinearGradient(colors: [Color(hex: 0xF0FFB0), Theme.lime], startPoint: .top, endPoint: .bottom))
                        Circle().strokeBorder(Color(hex: 0x6F8A00).opacity(0.9), lineWidth: 1)
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink)
                    } else {
                        Circle().strokeBorder(SettingsStyle.dim, lineWidth: 1.2)
                    }
                }
                .frame(width: 18, height: 18)
                Text(d.name).font(SettingsStyle.rowTitle).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 14).padding(.trailing, SettingsStyle.rowTrailing)
            .frame(height: 38)
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(SettingsStyle.stroke).frame(height: 1).padding(.leading, SettingsStyle.rowLeading + 0.5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MicDevice: Hashable {
    let uid: String
    let name: String
    var detail: String? = nil

    static func all() -> [MicDevice] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        var seen = Set<String>()
        return session.devices.compactMap { d in
            guard seen.insert(d.uniqueID).inserted else { return nil }
            return MicDevice(uid: d.uniqueID, name: d.localizedName, detail: d.deviceType == .external ? "External" : nil)
        }
    }
}

/// 16-segment level meter (reference: 16 bars, 7×16, 141 pt wide, unlit white 10 %).
struct LevelMeter: View {
    var level: Float
    var active: Bool
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 16, id: \.self) { i in
                let lit = active && Float(i) < level * 16
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(lit ? (i > 12 ? Theme.warning : Theme.lime) : Color.white.opacity(0.10))
                    .frame(width: 6.94, height: 16)
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.06), value: level)
    }
}

/// A tiny AVAudioEngine tap just for the Settings meter. Stops itself after 8 s.
@MainActor
final class MicLevelTester: ObservableObject {
    @Published var level: Float = 0
    @Published var running = false
    @Published var error: String?
    @Published var permissionDenied = false

    private var engine: AVAudioEngine?
    private var stopTask: Task<Void, Never>?

    func start(uid: String) {
        error = nil
        permissionDenied = false
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin(uid: uid)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                Task { @MainActor in ok ? self.begin(uid: uid) : self.denied() }
            }
        default:
            denied()
        }
    }

    private func denied() {
        permissionDenied = true
        error = "Microphone permission is off for Awan."
    }

    private func begin(uid: String) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !uid.isEmpty, let id = Self.deviceID(forUID: uid), let unit = input.audioUnit {
            var dev = id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            error = "Awan can't hear that microphone. Try a different one."
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0 ..< n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(1, n)))
            // map roughly -50 dB…-5 dB onto 0…1
            let db = 20 * log10(max(rms, 0.000_01))
            let v = max(0, min(1, (db + 50) / 45))
            Task { @MainActor in
                guard let self else { return }
                self.level = self.level * 0.4 + v * 0.6
            }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.error = "Couldn't start the microphone test."
            return
        }
        self.engine = engine
        running = true
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        running = false
        level = 0
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: CFString = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), ptr, &size, &id)
        }
        return status == noErr && id != 0 ? id : nil
    }
}
