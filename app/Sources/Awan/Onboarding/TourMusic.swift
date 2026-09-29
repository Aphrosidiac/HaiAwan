import AppKit

/// Quiet background loop for the tutorial (the ♫ toggle). Awan's own track, synthesized by
/// app/scripts/make-tour-music.py into Resources/Sounds/tour-music.m4a. Never plays in snapshot mode.
@MainActor
final class TourMusic {
    static let shared = TourMusic()
    private var sound: NSSound?

    func play() {
        guard !CommandLine.arguments.contains("--snapshot"), !Sounds.muted else { return }
        if sound == nil {
            let url = Paths.resources.appendingPathComponent("Sounds/tour-music.m4a")
            sound = NSSound(contentsOf: url, byReference: true)
            sound?.loops = true
            sound?.volume = 0.16
        }
        guard let sound, !sound.isPlaying else { return }
        sound.play()
    }

    func stop() {
        sound?.stop()
    }
}
