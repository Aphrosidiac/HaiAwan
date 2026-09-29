import Foundation
import CoreAudio
import AudioToolbox

/// Output-device mute state (for the muted-Mac fallback).
enum SystemAudio {
    private static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    static var isMuted: Bool {
        guard let dev = defaultOutput() else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &muted) == noErr, muted == 1 { return true }
        var vol: Float32 = 1
        size = UInt32(MemoryLayout<Float32>.size)
        addr.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr, vol < 0.01 { return true }
        return false
    }

    static func unmute() {
        guard let dev = defaultOutput() else { return }
        var zero: UInt32 = 0
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &zero)
        var vol: Float32 = 0.5
        addr.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        var cur: Float32 = 1
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &cur) == noErr, cur < 0.05 {
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
        }
    }
}
