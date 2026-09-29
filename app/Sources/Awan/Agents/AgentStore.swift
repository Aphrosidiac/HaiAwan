import Foundation
import SwiftUI

/// The roster of Awans and their conversations. Source of truth on this Mac (like the reference's
/// roster + thread cache). The runtime that actually executes turns is `AgentRunner`.
@MainActor
final class AgentStore: ObservableObject {
    static let shared = AgentStore()

    @Published private(set) var roster: [AwanAgent] = []
    @Published private(set) var threads: [String: AgentThread] = [:]

    lazy var runner = AgentRunner(store: self)

    private let rosterURL = Paths.homeCache.appendingPathComponent("roster.json")
    private var threadsDir: URL { Paths.ensure(Paths.homeCache.appendingPathComponent("threads", isDirectory: true)) }
    private var saveTask: Task<Void, Never>?
    /// Off in snapshot/demo mode so nothing touches the user's real files.
    static var persistenceEnabled = !CommandLine.arguments.contains("--snapshot")

    private init() {
        if Self.persistenceEnabled { load() }
    }

    /// Demo/snapshot data only (never persisted).
    func installDemo(roster: [AwanAgent], threads: [String: AgentThread]) {
        self.roster = roster
        self.threads = threads
    }

    // MARK: - Queries

    /// Sidebar order: pinned first, then most recent activity, then creation.
    var visibleAgents: [AwanAgent] {
        roster.filter { !$0.archived }.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let ta = threads[a.slug]?.lastActivityAt ?? .distantPast
            let tb = threads[b.slug]?.lastActivityAt ?? .distantPast
            if ta != tb { return ta > tb }
            return a.createdAt > b.createdAt
        }
    }

    func agent(_ slug: String) -> AwanAgent? { roster.first { $0.slug == slug } }
    func thread(_ slug: String) -> AgentThread { threads[slug] ?? AgentThread(slug: slug) }

    var runningAgents: [AwanAgent] { roster.filter { threads[$0.slug]?.activeTurn != nil } }
    var unreadCount: Int { roster.filter { threads[$0.slug]?.unread == true && !$0.archived }.count }

    /// The latest files across all Awans (for the notch peek pile).
    func recentArtifacts(for slug: String, limit: Int = 3) -> [Artifact] {
        Array(thread(slug).artifacts.prefix(limit))
    }

    // MARK: - Mutations

    @discardableResult
    func create(from spec: AwanSpecDTO, character: CharacterAppearance? = nil, isStarter: Bool = false) -> AwanAgent {
        var slug = spec.slug
        var n = 2
        while roster.contains(where: { $0.slug == slug && !$0.archived }) { slug = "\(spec.slug)-\(n)"; n += 1 }
        let appearance = character ?? CharacterCatalog.appearance(forHue: spec.baseHue, seed: slug)
        let agent = AwanAgent(
            slug: slug, name: spec.name, roleText: spec.roleText, oneLiner: spec.oneLiner,
            introMessages: spec.introMessages, suggestedAsks: spec.suggestedAsks, baseHue: spec.baseHue,
            character: appearance, createdAt: Date(), isStarter: isStarter
        )
        roster.removeAll { $0.slug == slug }
        roster.append(agent)
        threads[slug] = AgentThread(slug: slug, turns: [], unread: false, lastActivityAt: Date())
        writeAgentsFile(for: agent)
        if let routine = spec.routine {
            RoutineScheduler.shared.create(slug: slug, title: routine.title ?? spec.name, task: spec.suggestedAsks.first ?? spec.oneLiner, everyMinutes: routine.everyMinutes, runNow: false)
        }
        scheduleSave()
        return agent
    }

    func update(_ slug: String, _ change: (inout AwanAgent) -> Void) {
        guard let i = roster.firstIndex(where: { $0.slug == slug }) else { return }
        change(&roster[i])
        scheduleSave()
    }

    func updateThread(_ slug: String, _ change: (inout AgentThread) -> Void) {
        var t = threads[slug] ?? AgentThread(slug: slug)
        change(&t)
        threads[slug] = t
        scheduleSave()
    }

    func updateTurn(_ slug: String, _ turnID: String, _ change: (inout AgentTurn) -> Void) {
        updateThread(slug) { t in
            if let i = t.turns.firstIndex(where: { $0.id == turnID }) { change(&t.turns[i]) }
        }
    }

    func archive(_ slug: String) {
        runner.interrupt(slug)
        update(slug) { $0.archived = true }
    }

    func togglePin(_ slug: String) { update(slug) { $0.pinned.toggle() } }

    func markRead(_ slug: String) {
        guard threads[slug]?.unread == true else { return }
        updateThread(slug) { $0.unread = false }
    }

    /// Send work to an Awan. Creates the turn immediately (the user sees their bubble) and hands it to the runner.
    @discardableResult
    func send(_ prompt: String, to slug: String, display: String? = nil, source: String = "home") -> String? {
        guard agent(slug) != nil else { return nil }
        let turn = AgentTurn(
            id: UUID().uuidString, codexTurnID: nil, prompt: prompt, displayPrompt: display ?? prompt,
            startedAt: Date(), completedAt: nil, status: .queued, source: source
        )
        updateThread(slug) { t in
            t.turns.append(turn)
            t.lastActivityAt = Date()
            t.draft = ""
        }
        runner.start(turnID: turn.id, slug: slug)
        return turn.id
    }

    func interrupt(_ slug: String) { runner.interrupt(slug) }

    func wipeAll() {
        runner.interruptAll()
        roster = []
        threads = [:]
        try? FileManager.default.removeItem(at: rosterURL)
        try? FileManager.default.removeItem(at: threadsDir)
    }

    // MARK: - Starter cast (built in)

    func seedStarterCastIfNeeded() {
        guard !roster.contains(where: { $0.isStarter }) else { return }
        for spec in StarterCast.all {
            create(from: spec.dto, character: spec.character, isStarter: true)
        }
    }

    // MARK: - AGENTS.md (identity + memory file the agent maintains)

    func writeAgentsFile(for agent: AwanAgent) {
        guard Self.persistenceEnabled else { return }
        let url = agent.workspace.appendingPathComponent("AGENTS.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let body = """
        # \(agent.name) — \(agent.roleText)

        You are \(agent.name), one of the user's Awans (persistent agents in Awan by FF Dev Studio).
        \(agent.oneLiner)

        Workspace: this folder. Put everything you make in `output/`, scratch files in `tmp/`.

        ## Standing preferences

        - (none yet)

        ## Notes

        - \(ISO8601DateFormatter().string(from: Date()).prefix(10)): created.
        """
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Persistence

    private struct RosterFile: Codable { var agents: [AwanAgent] }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: rosterURL), let r = try? dec.decode(RosterFile.self, from: data) {
            roster = r.agents
        }
        for agent in roster {
            let url = threadsDir.appendingPathComponent("\(agent.slug).json")
            if let data = try? Data(contentsOf: url), var t = try? dec.decode(AgentThread.self, from: data) {
                // A turn that was running when the app quit is interrupted, not silently "running" forever.
                for i in t.turns.indices where t.turns[i].status.isActive {
                    t.turns[i].status = .interrupted
                    t.turns[i].completedAt = t.turns[i].completedAt ?? Date()
                }
                threads[agent.slug] = t
            }
        }
    }

    func scheduleSave() {
        guard Self.persistenceEnabled else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard Self.persistenceEnabled else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(RosterFile(agents: roster)) { try? data.write(to: rosterURL, options: .atomic) }
        for (slug, t) in threads {
            if let data = try? enc.encode(t) { try? data.write(to: threadsDir.appendingPathComponent("\(slug).json"), options: .atomic) }
        }
    }
}

/// Built-in Awans every account starts with (ours, not the reference's).
enum StarterCast {
    struct Entry { let dto: AwanSpecDTO; let character: CharacterAppearance }

    static let all: [Entry] = [
        Entry(
            dto: AwanSpecDTO(
                slug: "research-scout", name: "Research Scout", roleText: "Researcher",
                oneLiner: "Digs into companies, markets and competitors and hands you a tidy report.",
                introMessages: [
                    "Hey, I'm Research Scout, your researcher.",
                    "Point me at a company, a market or a competitor and I'll come back with a tidy report. That's what I'm here for.",
                    "Text me below whenever you're ready, or hold control and option to just talk to me.",
                ],
                suggestedAsks: [
                    "Research my top three competitors and what they charge",
                    "Find out who is winning in my space and why",
                    "Put together a one-page brief on this company",
                ],
                baseHue: 0.93, routine: nil, suggestion: nil
            ),
            character: CharacterAppearance(pack: .awanClouds, preset: "bunga", cloudHue: 0.93)
        ),
        Entry(
            dto: AwanSpecDTO(
                slug: "ship-lab", name: "Ship Lab", roleText: "Web builder",
                oneLiner: "Builds and ships websites and small web projects right on your Mac.",
                introMessages: [
                    "Hey, I'm Ship Lab, your web builder.",
                    "Builds and ships websites and small web projects right on your Mac. That's what I'm here for.",
                    "Text me below whenever you're ready, or hold control and option to just talk to me.",
                ],
                suggestedAsks: [
                    "Build me a simple landing page for my idea",
                    "Make a one-page site with a waitlist form",
                    "Ship a little web app that does one thing well",
                ],
                baseHue: 0.07, routine: nil, suggestion: nil
            ),
            character: CharacterAppearance(pack: .awanClouds, preset: "pic", cloudHue: 0.07)
        ),
    ]
}
