import AppKit

/// UI sounds (Awan's own, synthesized by app/scripts/make-sounds.py — never the reference's files).
/// OWNER: companion builder. Unprompted chimes (agent done / needs you) stay silent during calls (QuietContext).
enum SoundCue: String, CaseIterable {
    case listenStart = "listen-start", listenEnd = "listen-end", textOpen = "text-open", textSend = "text-send", textClose = "text-close"
    case agentLaunch = "agent-launch", agentDone = "agent-done", agentNeedsYou = "agent-needs-you", agentClose = "agent-close"
    case question, reveal, hatch, homeReveal = "home-reveal", thumbsUp = "thumbs-up", skillUp = "skill-up", skillDown = "skill-down", connection
}

@MainActor
enum Sounds {
    private static var cache: [SoundCue: NSSound] = [:]
    static var muted = false

    /// Cues that arrive unprompted, so they respect quiet context (calls, screen shares).
    static let unprompted: Set<SoundCue> = [.agentDone, .agentNeedsYou]

    static func play(_ cue: SoundCue, volume: Float = 0.6) {
        guard !muted else { return }
        if unprompted.contains(cue), QuietContext.reason(companionMicActive: false) != nil { return }
        if cache[cue] == nil {
            let url = Paths.resources.appendingPathComponent("Sounds/\(cue.rawValue).wav")
            cache[cue] = NSSound(contentsOf: url, byReference: true)
        }
        guard let s = cache[cue] else { return }
        s.stop()
        s.volume = volume
        s.play()
    }
}
