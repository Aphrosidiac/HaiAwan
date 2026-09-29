import Foundation

// Shared data contracts. Every subsystem (companion, agents, Home UI, notch, onboarding)
// reads and writes these; keep them Codable and additive.

// MARK: - Account & plan

struct AwanUser: Codable, Equatable {
    var id: String
    var email: String
    var displayName: String
    var avatarUrl: String?
    var referralHandle: String
    var createdAt: String
    var discoveryChannel: String?

    var firstName: String { displayName.split(separator: " ").first.map(String.init) ?? displayName }
}

struct UsageBucket: Codable, Equatable {
    var cap: Int?
    var used: Int
    var fraction: Double { cap.map { $0 == 0 ? 1 : min(1, Double(used) / Double($0)) } ?? 0 }
    var isUnlimited: Bool { cap == nil }
    var remaining: Int? { cap.map { max(0, $0 - used) } }
}

struct PlanUsage: Codable, Equatable {
    var window_resets_at: String
    var messages: UsageBucket
    var agents: UsageBucket
    var dictation: UsageBucket?
    var realtime_minutes: UsageBucket?
}

struct PlanTeam: Codable, Equatable {
    var id: String
    var name: String
    var seat: String      // pro | max
    var role: String      // owner | admin | member
    var seatName: String { seat == "max" ? "Max" : "Pro" }
}

struct PlanSnapshot: Codable, Equatable {
    var tier: String          // free | pro | max
    var plan: String
    var interval: String?
    var status: String?
    var billing_enforcement: String
    var usage: PlanUsage
    var pro_yearly_available: Bool?
    var max_yearly_available: Bool?
    var pro_agents_cap: Int?
    var max_agents_cap: Int?
    /// "team" when the caps come from a team seat (Teams v0), else "personal".
    var plan_source: String? = nil
    /// The user's team seat, when they're in an active team.
    var team: PlanTeam? = nil

    var tierName: String { tier == "pro" ? "Pro" : tier == "max" ? "Max" : "Free" }
    var isFree: Bool { tier == "free" }
    /// The paid plan comes from a team seat (paywall: "Included with your team plan").
    var isTeamSeat: Bool { plan_source == "team" && team != nil }
    var resetsAt: Date? { ISO8601DateFormatter.awan.date(from: usage.window_resets_at) }

    static let placeholder = PlanSnapshot(
        tier: "free", plan: "free", interval: nil, status: "active", billing_enforcement: "on",
        usage: .init(window_resets_at: ISO8601DateFormatter.awan.string(from: Date().addingTimeInterval(30 * 86400)),
                     messages: .init(cap: 25, used: 0), agents: .init(cap: 25, used: 0), dictation: nil, realtime_minutes: nil),
        pro_yearly_available: true, max_yearly_available: true, pro_agents_cap: 150, max_agents_cap: 1000)
}

extension ISO8601DateFormatter {
    static let awan: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Characters

enum CharacterPack: String, Codable, CaseIterable, Identifiable {
    case awanClouds   // soft cloud faces (our take on the reference's "Dreamy Cloud")
    case kawan        // big-eyed kid faces (our take on "Puff Pals")
    case pahlawan     // little martial-arts heroes, headbands and brows
    case arked        // arcade heroes: pixel eyes, caps, helmets
    case gebu         // soft round blob buddies
    case hikayat      // storybook spirits: leaves, moons, lanterns
    var id: String { rawValue }
    var title: String {
        switch self {
        case .awanClouds: return "Awan Clouds"
        case .kawan: return "Kawan"
        case .pahlawan: return "Pahlawan"
        case .arked: return "Arked"
        case .gebu: return "Gebu"
        case .hikayat: return "Hikayat"
        }
    }
    var tagline: String {
        switch self {
        case .awanClouds: return "The original little daydreamers."
        case .kawan: return "Tiny heroes, big feelings."
        case .pahlawan: return "Headband on. Heart on sleeve."
        case .arked: return "Press start. Save the day."
        case .gebu: return "Squishy, soft and always around."
        case .hikayat: return "Little spirits from the old stories."
        }
    }
    /// Every pack except Awan Clouds is drawn with the figure rig (head, hair, face, outfit).
    var isFigure: Bool { self != .awanClouds }

    /// Unknown packs (written by a newer build) fall back to Kawan instead of failing the whole roster.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CharacterPack(rawValue: raw) ?? .kawan
    }
}

/// Resting face of a character (and what a mood resolves to on the figure rig).
enum CharacterExpression: String, Codable, CaseIterable, Identifiable {
    case idle, curious, listening, thinking, happy, sleepy, surprised, skeptical, shy, excited, laughing, determined, loving, sad
    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Appearance of an agent's portrait. Indices point into the palettes in Characters/.
/// Every field decodes with a default, so looks saved by older builds still load.
struct CharacterAppearance: Codable, Hashable {
    var pack: CharacterPack = .awanClouds
    var preset: String? = "langit"
    var cloudHue: Double = 0.58          // awanClouds colour
    var hairstyle: Int = 0               // figure packs: index into CharacterCatalog.hairstyleNames (0–9 are the original Kawan styles)
    var hairColor: Int = 0
    var skinTone: Int = 1                // Gebu reads this as a body colour
    var eyeColor: Int = 0
    var background: Int = 0
    var outfitStyle: Int = 0             // index into CharacterCatalog.outfitNames
    var outfitColor: Int = 0
    var accentColor: Int = 0
    var expression: CharacterExpression? = nil   // resting face; nil = the pack's default

    static let `default` = CharacterAppearance()

    private enum CodingKeys: String, CodingKey {
        case pack, preset, cloudHue, hairstyle, hairColor, skinTone, eyeColor, background, outfitStyle, outfitColor, accentColor, expression
    }
}

extension CharacterAppearance {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        pack = try c.decodeIfPresent(CharacterPack.self, forKey: .pack) ?? .awanClouds
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        cloudHue = try c.decodeIfPresent(Double.self, forKey: .cloudHue) ?? 0.58
        hairstyle = try c.decodeIfPresent(Int.self, forKey: .hairstyle) ?? 0
        hairColor = try c.decodeIfPresent(Int.self, forKey: .hairColor) ?? 0
        skinTone = try c.decodeIfPresent(Int.self, forKey: .skinTone) ?? 1
        eyeColor = try c.decodeIfPresent(Int.self, forKey: .eyeColor) ?? 0
        background = try c.decodeIfPresent(Int.self, forKey: .background) ?? 0
        outfitStyle = try c.decodeIfPresent(Int.self, forKey: .outfitStyle) ?? 0
        // Looks saved before outfits existed get a top that matches their hair.
        outfitColor = try c.decodeIfPresent(Int.self, forKey: .outfitColor) ?? hairColor
        accentColor = try c.decodeIfPresent(Int.self, forKey: .accentColor) ?? 0
        expression = try? c.decodeIfPresent(CharacterExpression.self, forKey: .expression)
    }
}

// MARK: - Agents ("Awans")

struct RoutineSpec: Codable, Hashable {
    var everyMinutes: Int
    var title: String?
}

struct AwanAgent: Codable, Identifiable, Hashable {
    var slug: String
    var name: String
    var roleText: String
    var oneLiner: String
    var introMessages: [String]
    var suggestedAsks: [String]
    var baseHue: Double
    var character: CharacterAppearance
    var createdAt: Date
    var isStarter: Bool = false
    var pinned: Bool = false
    var archived: Bool = false
    /// Codex thread bound to this agent (one long-lived thread per Awan).
    var threadID: String?

    var id: String { slug }
    var workspace: URL { Paths.workspace(for: slug) }
}

/// What the server returns for generated agents (onboarding cast, new-Awan interview).
struct AwanSpecDTO: Codable {
    var slug: String
    var name: String
    var roleText: String
    var oneLiner: String
    var introMessages: [String]
    var suggestedAsks: [String]
    var baseHue: Double
    var routine: RoutineSpec?
    var suggestion: SuggestionSpecDTO?
}

struct SuggestionSpecDTO: Codable, Hashable {
    var title: String
    var description: String
    var agentPrompt: String
    var appHint: String?
    var routine: RoutineSpec?
}

// MARK: - Threads & turns

enum TurnStatus: String, Codable {
    case queued, starting, running, awaitingApproval, completed, failed, interrupted
    var isActive: Bool { self == .queued || self == .starting || self == .running || self == .awaitingApproval }
}

enum ProgressKind: String, Codable { case commentary, thinking, command, fileChange, toolCall, error }

struct ProgressItem: Codable, Identifiable, Hashable {
    var id: String
    var kind: ProgressKind
    var text: String
    var detail: String?
    var at: Date
}

enum ArtifactKind: String, Codable {
    case webPage, pdf, image, document, spreadsheet, markdown, presentation, folder, code, link, other

    static func infer(_ path: String) -> ArtifactKind {
        if path.hasPrefix("http") { return .link }
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return .webPage
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return .image
        case "doc", "docx", "rtf", "pages", "txt": return .document
        case "xlsx", "xls", "csv", "numbers": return .spreadsheet
        case "md", "markdown": return .markdown
        case "ppt", "pptx", "key": return .presentation
        case "swift", "js", "ts", "py", "json", "css", "sh": return .code
        case "": return .folder
        default: return .other
        }
    }

    var label: String {
        switch self {
        case .webPage: return "Web page"
        case .pdf: return "PDF"
        case .image: return "Image"
        case .document: return "Document"
        case .spreadsheet: return "Spreadsheet"
        case .markdown: return "Markdown"
        case .presentation: return "Slides"
        case .folder: return "Folder"
        case .code: return "Code"
        case .link: return "Link"
        case .other: return "File"
        }
    }
}

struct Artifact: Codable, Identifiable, Hashable {
    var path: String            // absolute path or https URL
    var kind: ArtifactKind
    var createdAt: Date
    var id: String { path }
    var name: String { path.hasPrefix("http") ? (URL(string: path)?.host ?? path) : (path as NSString).lastPathComponent }
    var url: URL { path.hasPrefix("http") ? (URL(string: path) ?? URL(fileURLWithPath: path)) : URL(fileURLWithPath: path) }

    init(path: String, kind: ArtifactKind? = nil, createdAt: Date = Date()) {
        self.path = path
        self.kind = kind ?? ArtifactKind.infer(path)
        self.createdAt = createdAt
    }
}

/// One user ask and everything the agent did for it.
struct AgentTurn: Codable, Identifiable, Hashable {
    var id: String                      // local id; codexTurnID filled once started
    var codexTurnID: String?
    var prompt: String                  // what was sent to the model (may include context)
    var displayPrompt: String           // what the user sees in their bubble
    var startedAt: Date
    var completedAt: Date?
    var status: TurnStatus
    var statusLine: String?             // live reasoning headline ("Considering documentation style")
    var progress: [ProgressItem] = []
    var finalText: String?
    var summary: String?
    var spokenSummary: String?
    var doneTitle: String?
    var nextActions: [String] = []
    var artifacts: [Artifact] = []
    var errorText: String?
    var computerUseRequest: String?
    var source: String = "home"         // home | voice | suggestion | routine | notch | computerUse | extraUsage
    /// Set (with the question to show) when a long turn was paused to ask before spending more agent
    /// messages; status is `.awaitingApproval`. Answer with `AgentRunner.approveExtraUsage/declineExtraUsage`.
    var extraUsageRequest: String? = nil
    /// Tool calls (commands, MCP, web, file edits) the turn made — drives the extra-usage check.
    var toolCallCount: Int? = nil
    /// Total tokens Codex reported for this turn (last `thread/tokenUsage/updated`).
    var tokensUsed: Int? = nil

    var durationText: String? {
        guard let end = completedAt else { return nil }
        let s = Int(end.timeIntervalSince(startedAt))
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }
}

/// Everything shown in an agent's conversation.
struct AgentThread: Codable, Hashable {
    var slug: String
    var turns: [AgentTurn] = []
    var unread: Bool = false
    var lastActivityAt: Date?
    var draft: String = ""

    var activeTurn: AgentTurn? { turns.last(where: { $0.status.isActive }) }
    var lastCompleted: AgentTurn? { turns.last(where: { $0.status == .completed }) }
    var artifacts: [Artifact] { turns.flatMap(\.artifacts).reversed().uniqued() }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Routines

struct Routine: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var slug: String
    var title: String
    var task: String
    var intervalMinutes: Int
    var createdAt: Date = Date()
    var isPaused: Bool = false
    var nextRunAt: Date
    var runCount: Int = 0
    var lastRunStartedAt: Date?
    var lastRunFinishedAt: Date?
    var lastRunSummary: String?
    var lastRunFailed: Bool = false
    var consecutiveFailures: Int = 0
    /// The AgentTurn id of the latest run (matches completion back to the routine).
    var lastRunTurnID: String? = nil
    /// Set while a due run is held back because the Mac is offline.
    var waitingForNetworkSince: Date? = nil
    /// True when the scheduler paused it after repeated failures (vs. the user pausing it).
    var autoPaused: Bool? = nil

    var cadenceText: String {
        switch intervalMinutes {
        case 1440: return "Every day"
        case 10080: return "Every week"
        case 60: return "Every hour"
        case let m where m % 1440 == 0: return "Every \(m / 1440) days"
        case let m where m % 60 == 0: return "Every \(m / 60) hours"
        default: return "Every \(intervalMinutes) min"
        }
    }
}

// MARK: - Suggestions

struct Suggestion: Codable, Identifiable, Hashable {
    var id: Int
    var awanSlug: String
    var title: String
    var description: String
    var agentPrompt: String
    var appHint: String?
    var routine: RoutineSpec?
    var checkReason: String
    var status: String
    var createdAt: String
}

// MARK: - Companion

enum VoiceState: String, Equatable { case idle, listening, processing, responding }

struct CompanionExchange: Codable, Hashable {
    var user: String
    var assistant: String
}

struct PointTarget: Codable, Hashable {
    var x: Double
    var y: Double
    var label: String?
    var screen: Int?
}

// MARK: - Integrations

struct IntegrationDTO: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var description: String
    var url: String?
    var auth: String
    var icon: String
    var category: String
    /// Remote logo (Composio toolkits); nil for Awan's own catalogue, which uses `icon`.
    var logo: String? = nil
}

/// A connector the user added (catalogue item or custom MCP).
struct Connector: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var url: String?
    var command: String?
    var auth: String            // oauth | api_key | header:<Name> | none | local | awan-google (hosted by Awan's server) | composio
    var status: String          // checking | connected | needsSignIn | rejected | disconnected
    var addedAt: Date = Date()
}
