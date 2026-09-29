import AppKit
import CoreGraphics

// MARK: - Voice activity (always-on voice)

/// Energy-based voice activity detection over the smoothed mic level (0…1, ~50 updates/s).
/// Tracks a noise floor; speech = level well above it for ≥ `minSpeech`, ends after `hangover` of quiet.
struct VoiceActivityDetector {
    enum Event: Equatable { case speechStarted, speechEnded }

    var minSpeech: TimeInterval = 0.22
    var hangover: TimeInterval = 0.75
    var minimumMargin: Float = 0.16
    private(set) var noiseFloor: Float = 0.2
    private(set) var inSpeech = false
    private var aboveSince: TimeInterval?
    private var belowSince: TimeInterval?

    var threshold: Float { min(0.92, noiseFloor + minimumMargin) }

    mutating func feed(level: Float, at t: TimeInterval) -> Event? {
        // Floor follows quiet stretches quickly, loud ones very slowly.
        if !inSpeech { noiseFloor = level < noiseFloor ? noiseFloor * 0.9 + level * 0.1 : noiseFloor * 0.995 + level * 0.005 }
        let loud = level > threshold
        if !inSpeech {
            if loud {
                if aboveSince == nil { aboveSince = t }
                if let s = aboveSince, t - s >= minSpeech { inSpeech = true; belowSince = nil; return .speechStarted }
            } else { aboveSince = nil }
        } else {
            if loud { belowSince = nil } else {
                if belowSince == nil { belowSince = t }
                if let b = belowSince, t - b >= hangover { inSpeech = false; aboveSince = nil; return .speechEnded }
            }
        }
        return nil
    }

    mutating func reset() { inSpeech = false; aboveSince = nil; belowSince = nil }
}

// MARK: - Quiet context (calls / screen sharing)

/// "User looks busy on a call": hold back unprompted speech (morning hello, agent announcements).
enum QuietContext {
    private static var cached: (at: Date, reason: String?)?

    /// Why Awan should stay quiet right now, or nil. Cached for 4 s (window lists are not free).
    @MainActor
    static func reason(companionMicActive: Bool) -> String? {
        if let c = cached, Date().timeIntervalSince(c.at) < 4 { return c.reason }
        let r = detect(companionMicActive: companionMicActive)
        cached = (Date(), r)
        return r
    }

    static func detect(companionMicActive: Bool) -> String? {
        if let w = callWindow() { return "call window: \(w)" }
        if !companionMicActive, AudioCapture.isDefaultInputBusyElsewhere { return "microphone in use by another app" }
        return nil
    }

    /// Owner/title heuristics for meeting apps (titles need Screen Recording; owners don't).
    static func callWindow() -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (w[kCGWindowName as String] as? String) ?? ""
            if isCallWindow(owner: owner, title: title) { return "\(owner) — \(title)" }
        }
        return nil
    }

    static func isCallWindow(owner: String, title: String) -> Bool {
        let o = owner.lowercased(), t = title.lowercased()
        if o == "cpthost" { return true }                                     // Zoom's screen-share host
        if o.contains("zoom"), t.contains("zoom meeting") || t.contains("zoom webinar") || t == "meeting" { return true }
        if o == "facetime", !t.isEmpty, t != "facetime" { return true }       // an active FaceTime call window
        if t.contains("meet.google.com") || t.hasPrefix("meet - ") || t.hasPrefix("meet – ") { return true }
        if o.contains("teams"), t.contains("meeting") || t.contains("call") { return true }
        if o.contains("webex"), t.contains("meeting") { return true }
        if o == "slack", t.contains("huddle") { return true }
        if o == "discord", t.contains("voice connected") { return true }
        return false
    }
}

// MARK: - Routing a task to the best Awan

enum AgentRouter {
    private static let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "your", "you", "from", "into", "about", "what", "make", "please", "can", "me", "my", "a", "an", "to", "of", "on", "in", "it", "is", "be", "do", "i", "or", "as", "at", "by", "all", "any", "some", "our", "their", "them", "then", "than", "will", "would", "could", "should", "just", "get", "have"]
    static let researchWords: Set<String> = ["research", "find", "compare", "competitor", "competitors", "report", "sources", "market", "analyse", "analyze", "study", "investigate", "summarize", "summarise", "look", "brief", "news"]
    static let buildWords: Set<String> = ["build", "site", "website", "page", "landing", "app", "code", "prototype", "deploy", "html", "web", "ship", "portfolio", "design"]

    static func tokens(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 && !stop.contains($0) }
    }

    /// Word-overlap score between a task and an Awan's name, role and one-liner (5-letter stems count too).
    static func score(task: String, agent: AwanAgent) -> Double {
        let t = tokens(task)
        let a = tokens("\(agent.name) \(agent.roleText) \(agent.oneLiner)")
        guard !t.isEmpty, !a.isEmpty else { return 0 }
        let exact = Set(a)
        let stems = Set(a.map { String($0.prefix(5)) })
        var s = 0.0
        for w in Set(t) {
            if exact.contains(w) { s += 1 } else if w.count >= 5, stems.contains(String(w.prefix(5))) { s += 0.6 }
        }
        return s
    }

    /// The best Awan for a task: highest overlap, else research-scout for research, ship-lab for build/site, else the first.
    static func bestSlug(for task: String, among agents: [AwanAgent]) -> String? {
        let pool = agents.filter { !$0.archived }
        guard !pool.isEmpty else { return nil }
        let scored = pool.map { ($0.slug, score(task: task, agent: $0)) }.sorted { $0.1 > $1.1 }
        if let top = scored.first, top.1 >= 1 { return top.0 }
        let words = Set(tokens(task))
        if !words.isDisjoint(with: buildWords), pool.contains(where: { $0.slug == "ship-lab" }) { return "ship-lab" }
        if !words.isDisjoint(with: researchWords), pool.contains(where: { $0.slug == "research-scout" }) { return "research-scout" }
        if let top = scored.first, top.1 > 0 { return top.0 }
        return pool.first { $0.slug == "research-scout" }?.slug ?? pool.first?.slug
    }
}
