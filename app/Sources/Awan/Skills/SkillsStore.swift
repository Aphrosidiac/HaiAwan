import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// A skill from the library (GET /v1/skills/library; `content` only on detail/active/create responses).
struct SkillItem: Codable, Identifiable, Hashable {
    var slug: String
    var title: String
    var oneLiner: String
    var whatsInside: [String] = []
    var category: String
    var categoryName: String?
    var symbol: String
    var color: String
    var author: String
    var isOfficial: Bool = false
    var isMine: Bool = false
    var teamShared: Bool = false
    var published: Bool = true
    var origin: String?
    var usersCount: Int = 0
    var activeUsersCount: Int?
    var active: Bool?
    var content: String?

    var id: String { slug }
    var tint: Color { Color(skillHex: color) }
    /// "FF Dev Studio", "You", or the author's name.
    var byline: String { isMine ? "You" : author }
    var usersLabel: String {
        switch usersCount {
        case 0: return "New"
        case 1: return "1 user"
        default: return "\(usersCount.formatted()) users"
        }
    }
}

enum SkillFilter: String, CaseIterable, Identifiable {
    case all, team, mine
    var id: String { rawValue }
    var title: String { self == .all ? "All" : self == .team ? "Team" : "My skills" }
}

extension Color {
    /// "#RRGGBB" → Color (Field Grey when malformed).
    init(skillHex: String) {
        let hex = skillHex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        self.init(hex: UInt32(hex, radix: 16) ?? 0x8B8981)
    }
}

/// The Skills library: what's in it, which three are active, creating/importing. Active skills reach
/// the companion (`activeSkills` on every turn) and the agents (SKILL.md files in CodexHome via SkillLibrary).
@MainActor
final class SkillsStore: ObservableObject {
    static let shared = SkillsStore()
    static let maxActive = 3

    @Published var library: [SkillItem] = []
    @Published var activeSlugs: [String] = []
    /// Full active skills (with content) — what the agents get.
    @Published var active: [SkillItem] = []
    @Published var filter: SkillFilter = .all
    @Published var query = ""
    @Published var loading = false
    @Published var loadError: String?
    @Published var teamName: String?
    /// Set once the library has been fetched at least once (until then the server uses the account's set).
    @Published private(set) var loaded = false

    /// Full-slot state: the skill waiting for a slot ("tap one to swap it out").
    @Published var swapCandidate: SkillItem?
    @Published var detail: SkillItem?
    @Published var showCreate = false

    enum CreateState: Equatable { case idle, writing, done(SkillItem), failed(String) }
    @Published var creating: CreateState = .idle
    @Published var importError: String?

    private var searchTask: Task<Void, Never>?
    /// What the agent runtime was last given (nil until the first fetch, which only records it: the
    /// runtime installs the current set itself on launch).
    private var lastAgentSkills: [SkillLibrary.UserSkill]?
    private var cancellables = Set<AnyCancellable>()
    private var isSnapshot: Bool { CommandLine.arguments.contains("--snapshot") }

    private init() {
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        NotificationCenter.default.publisher(for: .awanDidSignIn)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.applyPendingPicks(); await self?.refreshActive() } }
            .store(in: &cancellables)
    }

    var activeItems: [SkillItem] {
        activeSlugs.compactMap { slug in library.first { $0.slug == slug } ?? active.first { $0.slug == slug } }
    }

    /// Slugs for the companion request (nil until we know, so the server falls back to the account's set).
    var companionSlugs: [String]? { loaded ? activeSlugs : nil }

    // MARK: - Loading

    func load() async {
        guard !isSnapshot, AppState.shared.signInState == .signedIn else { return }
        struct R: Decodable { var skills: [SkillItem]; var activeSlugs: [String]; var team: Team? }
        struct Team: Decodable { var id: String; var name: String }
        loading = true
        defer { loading = false }
        var path = "v1/skills/library?filter=\(filter.rawValue)"
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { path += "&q=\(q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
        do {
            let r: R = try await AppState.shared.api.send(path)
            library = r.skills
            activeSlugs = r.activeSlugs
            teamName = r.team?.name
            loaded = true
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Debounced search.
    func queryChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    func refreshActive() async {
        guard !isSnapshot else { return }
        struct R: Decodable { var skills: [SkillItem] }
        guard let r: R = try? await AppState.shared.api.send("v1/skills/active") else { return }
        active = r.skills
        activeSlugs = r.skills.map(\.slug)
        loaded = true
        Self.writeAgentCache(r.skills)
        syncAgents()
    }

    // MARK: - Activation

    func isActive(_ s: SkillItem) -> Bool { activeSlugs.contains(s.slug) }

    func toggle(_ s: SkillItem) async {
        if isActive(s) {
            await deactivate(s)
        } else if activeSlugs.count >= Self.maxActive {
            // Full: close any sheet so the slot bar (the swap targets) is in view.
            detail = nil
            showCreate = false
            withAnimation(Theme.spring) { swapCandidate = s }
        } else {
            await activate(s, replacing: nil)
        }
    }

    /// Full-slot state: swap `outSlug` for the waiting skill.
    func swap(out outSlug: String) async {
        guard let incoming = swapCandidate else { return }
        await activate(incoming, replacing: outSlug)
        withAnimation(Theme.spring) { swapCandidate = nil }
    }

    func activate(_ s: SkillItem, replacing: String?) async {
        struct R: Decodable { var activeSlugs: [String] }
        var body = ["slug": s.slug]
        if let replacing { body["replace"] = replacing }
        do {
            let r: R = try await AppState.shared.api.send("v1/skills/activate", method: "POST", body: body)
            withAnimation(Theme.spring) { activeSlugs = r.activeSlugs }
            Sounds.play(.skillUp, volume: 0.5)
            bumpUsers(s.slug)
            await refreshActive()
        } catch APIError.server(409, _) {
            withAnimation(Theme.spring) { swapCandidate = s }
        } catch {
            AppState.shared.show(error)
        }
    }

    func deactivate(_ s: SkillItem) async {
        struct R: Decodable { var activeSlugs: [String] }
        do {
            let r: R = try await AppState.shared.api.send("v1/skills/deactivate", method: "POST", body: ["slug": s.slug])
            withAnimation(Theme.spring) { activeSlugs = r.activeSlugs }
            Sounds.play(.skillDown, volume: 0.5)
            await refreshActive()
        } catch {
            AppState.shared.show(error)
        }
    }

    private func bumpUsers(_ slug: String) {
        if let i = library.firstIndex(where: { $0.slug == slug }), library[i].usersCount == 0 { library[i].usersCount = 1 }
    }

    // MARK: - Detail

    func open(_ s: SkillItem) {
        detail = s
        guard s.content == nil, !isSnapshot else { return }
        Task {
            struct R: Decodable { var skill: SkillItem }
            if let r: R = try? await AppState.shared.api.send("v1/skills/\(s.slug)"), detail?.slug == s.slug { detail = r.skill }
        }
    }

    func lifecycle(_ s: SkillItem, _ action: String) async {
        struct R: Decodable { var skill: SkillItem }
        do {
            let r: R = try await AppState.shared.api.send("v1/skills/\(s.slug)/\(action)", method: "POST", body: [String: String]())
            if detail?.slug == s.slug { detail = r.skill }
            if let i = library.firstIndex(where: { $0.slug == s.slug }) { library[i] = r.skill }
            let msg = ["publish": "Published. Everyone can find it in the library now.", "unpublish": "Unpublished. Only you can see it.",
                       "share-to-team": "Shared with \(teamName ?? "your team").", "unshare-from-team": "No longer shared with your team."][action]
            if let msg { AppState.shared.show(msg) }
        } catch APIError.server(409, _) where action == "share-to-team" {
            AppState.shared.show("Join or create a team first (Settings → Account).")
        } catch {
            AppState.shared.show(error)
        }
    }

    // MARK: - Create

    /// Brain dump → a finished skill. Owned by the store, so closing the sheet doesn't cancel it.
    func create(brainDump: String) {
        let text = brainDump.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 12 else { AppState.shared.show("Tell Awan a little more about the skill first."); return }
        creating = .writing
        Task {
            struct R: Decodable { var skill: SkillItem }
            do {
                let r: R = try await AppState.shared.api.send("v1/skills/create", method: "POST", body: ["brainDump": text])
                creating = .done(r.skill)
                library.insert(r.skill, at: 0)
                if !showCreate { AppState.shared.show("Your skill “\(r.skill.title)” is ready in My skills.") }
                Sounds.play(.skillUp, volume: 0.4)
            } catch {
                creating = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Import

    /// Front matter check before upload: `name` and `description` are required, and there must be a body.
    nonisolated static func validateSkillMarkdown(_ text: String) -> String? {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .init(charactersIn: "\u{FEFF}"))
        guard t.hasPrefix("---\n"), let end = t.dropFirst(4).range(of: "\n---") else {
            return "That file has no front matter. A skill starts with ---, a name: and a description: line, then ---."
        }
        let header = t.dropFirst(4)[..<end.lowerBound]
        let keys = Set(header.split(separator: "\n").compactMap { $0.split(separator: ":", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() })
        if !keys.contains("name") { return "The front matter needs a name: line." }
        if !keys.contains("description") { return "The front matter needs a description: line." }
        let body = t.dropFirst(4)[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return "That skill is empty. Add the instructions below the front matter." }
        return nil
    }

    func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = "Import a skill"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importFile(url) }
    }

    func importFile(_ url: URL) async {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importError = "Awan couldn't read that file. Is it a text .md file?"
            AppState.shared.show(importError!)
            return
        }
        if let problem = Self.validateSkillMarkdown(text) {
            importError = problem
            AppState.shared.show(problem)
            return
        }
        struct R: Decodable { var skill: SkillItem }
        do {
            let r: R = try await AppState.shared.api.send("v1/skills/import", method: "POST", body: ["markdown": text])
            importError = nil
            filter = .mine
            await load()
            open(r.skill)
            AppState.shared.show("Imported “\(r.skill.title)”.")
        } catch {
            AppState.shared.show(error)
        }
    }

    // MARK: - Onboarding picks ("What should Awan be good at?")

    static let pendingPicksKey = "awan.skills.onboardingPicks"

    var pendingPicks: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.pendingPicksKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.pendingPicksKey); objectWillChange.send() }
    }

    /// After sign-in: switch on what the user picked before they had an account.
    func applyPendingPicks() async {
        let picks = Array(pendingPicks.prefix(Self.maxActive))
        guard !picks.isEmpty, AppState.shared.signInState == .signedIn else { return }
        struct R: Decodable { var activeSlugs: [String] }
        do {
            let r: R = try await AppState.shared.api.send("v1/skills/activations/sync", method: "POST", body: ["activeSlugs": picks])
            activeSlugs = r.activeSlugs
            pendingPicks = []
            Log.info("skills: switched on onboarding picks \(picks)")
        } catch {
            Log.error("skills: onboarding picks failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Agents

    static var agentCacheURL: URL { Paths.codexHome.appendingPathComponent("awan-active-skills.json") }

    nonisolated static func userSkills(_ items: [SkillItem]) -> [SkillLibrary.UserSkill] {
        items.compactMap { s in s.content.map { SkillLibrary.UserSkill(slug: s.slug, title: s.title, oneLiner: s.oneLiner, content: $0) } }
    }

    static func writeAgentCache(_ items: [SkillItem]) {
        if let data = try? JSONEncoder().encode(userSkills(items)) { try? data.write(to: agentCacheURL, options: .atomic) }
    }

    /// Active skills for the agent runtime: fresh from the server, else the last copy we saw (offline start).
    static func activeForAgents() async -> [SkillLibrary.UserSkill] {
        struct R: Decodable { var skills: [SkillItem] }
        if let r: R = try? await AgentAPI.send("v1/skills/active", method: "GET", timeout: 6) {
            writeAgentCache(r.skills)
            return userSkills(r.skills)
        }
        guard let data = try? Data(contentsOf: agentCacheURL) else { return [] }
        return (try? JSONDecoder().decode([SkillLibrary.UserSkill].self, from: data)) ?? []
    }

    /// Writes the SKILL.md files now and, if no Awan is mid-turn, restarts the runtime so config.toml picks them up.
    private func syncAgents() {
        let skills = Self.userSkills(active)
        defer { lastAgentSkills = skills }
        guard lastAgentSkills != nil, skills != lastAgentSkills else { return }
        SkillLibrary.installUserSkills(skills, into: Paths.codexSkills)
        let busy = AgentStore.shared.threads.values.contains { $0.activeTurn != nil }
        if !busy, CodexAppServer.shared.state == .ready {
            Log.info("skills: active set changed — restarting the agent runtime to load it")
            CodexAppServer.shared.stop()
        }
    }
}
