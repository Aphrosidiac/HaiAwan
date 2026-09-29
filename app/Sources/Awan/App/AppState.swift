import SwiftUI
import AppKit
import Combine

/// Pages of Home: home | suggestions | settings | skills | new Awan | referral.
enum HomePage: Hashable {
    case home
    case suggestions
    case agent(String)          // slug
    case newAwan
    case settings(SettingsSection)
    case referral
    case skills
}

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case account, general, referral, voice, microphone, dictation, shortcuts, cursor, agents, integrations, developer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .account: return "Account"
        case .general: return "General"
        case .referral: return "Invite & Earn"
        case .voice: return "Voice"
        case .microphone: return "Microphone"
        case .dictation: return "Dictation"
        case .shortcuts: return "Shortcuts"
        case .cursor: return "Cursor"
        case .agents: return "Agents"
        case .integrations: return "Integrations"
        case .developer: return "Developer"
        }
    }
    var symbol: String {
        switch self {
        case .account: return "person.crop.circle"
        case .general: return "gearshape.fill"
        case .referral: return "gift.fill"
        case .voice: return "waveform"
        case .microphone: return "mic.fill"
        case .dictation: return "character.cursor.ibeam"
        case .shortcuts: return "command"
        case .cursor: return "cursorarrow"
        case .agents: return "circle.hexagongrid.fill"
        case .integrations: return "puzzlepiece.extension.fill"
        case .developer: return "hammer.fill"
        }
    }
    var group: String {
        switch self {
        case .account, .general, .referral: return ""
        case .voice, .microphone, .dictation, .shortcuts, .cursor: return "AWAN"
        case .agents, .integrations: return "WORK"
        case .developer: return "INTERNAL"
        }
    }
}

enum PaywallSource: String { case limitHit, notchUpgradeButton, notchPeekUpgradeButton, homeUpgradeButton, settingsUpgradeButton, onboardingCompleted, referralPage }

/// The hub. Owns auth, plan, navigation, suggestions and the subsystems.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let prefs = Prefs.shared
    let api = APIClient.shared

    // Account
    @Published var user: AwanUser?
    @Published var plan: PlanSnapshot = .placeholder
    @Published var signInState: SignInState = .signedOut
    @Published var serverFeatures: ServerFeatures = .init()

    // Navigation
    @Published var homePage: HomePage = .home
    @Published var isHomeOpen = false
    @Published var isPeekOpen = false
    @Published var paywall: PaywallSource?
    @Published var toast: String?
    @Published var sidebarCollapsed = false
    @Published var inspectorOpen = false
    @Published var characterEditorSlug: String?

    // Suggestions
    @Published var suggestions: [Suggestion] = []
    @Published var suggestionsCheckedAt: Date?
    @Published var suggestionIndex = 0

    // Subsystems (each lives in its own folder)
    let agents = AgentStore.shared
    let companion = CompanionEngine.shared
    let dictation = DictationManager.shared
    let routines = RoutineScheduler.shared

    enum SignInState: Equatable { case signedOut, waitingForLink(email: String, devLink: String?), signedIn }
    struct ServerFeatures: Codable {
        var realtime = false; var serverSpeech = true; var stripe = false
        /// First-party Google connectors (Gmail, Calendar, Drive, Docs, Sheets hosted by Awan's server).
        var googleConnectors = false
        /// Composio broker (the long tail of app integrations).
        var composio = false
        init() {}
        // Every key is optional so an older server's config still decodes.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            realtime = try c.decodeIfPresent(Bool.self, forKey: .realtime) ?? false
            serverSpeech = try c.decodeIfPresent(Bool.self, forKey: .serverSpeech) ?? true
            stripe = try c.decodeIfPresent(Bool.self, forKey: .stripe) ?? false
            googleConnectors = try c.decodeIfPresent(Bool.self, forKey: .googleConnectors) ?? false
            composio = try c.decodeIfPresent(Bool.self, forKey: .composio) ?? false
        }
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Re-render when nested stores change so views that read through AppState update.
        agents.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        companion.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        prefs.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        if api.token != nil {
            signInState = .signedIn
            await refreshAccount()
            await loadSuggestions()
        }
        await loadConfig()
    }

    func loadConfig() async {
        struct Config: Decodable { var features: ServerFeatures }
        if let c: Config = try? await api.send("v1/config", auth: false) {
            serverFeatures = c.features
            ConnectorStore.shared.applyServerFeatures(composio: c.features.composio, awanGoogle: c.features.googleConnectors)
        }
    }

    // MARK: - Auth

    func requestMagicLink(email: String, referral: String? = nil) async {
        struct R: Decodable { var sent: Bool; var devLink: String? }
        do {
            let r: R = try await api.send("v1/auth/magic", method: "POST", body: ["email": email, "redirect": "awan://auth", "referral": referral ?? ""], auth: false)
            signInState = .waitingForLink(email: email, devLink: r.devLink)
        } catch {
            show(error)
        }
    }

    /// awan://auth?token=… (from the magic link or Google callback page)
    func handle(url: URL) {
        guard url.scheme == "awan" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch url.host {
        case "auth":
            if let token = comps?.queryItems?.first(where: { $0.name == "token" })?.value {
                api.token = token
                signInState = .signedIn
                Task {
                    await refreshAccount()
                    await loadSuggestions()
                    NotificationCenter.default.post(name: .awanDidSignIn, object: nil)
                }
            }
        case "billing":
            Task {
                await refreshAccount()
                show("You're on \(plan.tierName). Your new limits are live.")
                companion.announce("you're on \(plan.tierName.lowercased()) now. go wild.")
            }
        case "connectors":
            // Back from Google consent (Awan-hosted Gmail/Calendar/Drive/Docs/Sheets) or a Composio connect page
            // (`source=composio`). Marking them connected
            // changes ConnectorStore.connectors, which reloads the agent runtime with the new MCP servers.
            let store = ConnectorStore.shared
            let message = store.handleConnectorsURL(url)
            openHome(.settings(.integrations))
            show(message)
            Task {
                await store.refreshAwanStatus()
                await store.refreshComposioStatus()
            }
        default:
            break
        }
    }

    func signOut() async {
        _ = try? await api.sendRaw("v1/auth/logout")
        api.token = nil
        user = nil
        signInState = .signedOut
        plan = .placeholder
    }

    func deleteAccount() async {
        do {
            _ = try await api.sendRaw("v1/me", method: "DELETE")
            api.token = nil
            user = nil
            signInState = .signedOut
            agents.wipeAll()
            prefs.onboardingCompleted = false
        } catch { show(error) }
    }

    func refreshAccount() async {
        struct Me: Decodable { var user: AwanUser; var plan: PlanSnapshot }
        do {
            let me: Me = try await api.send("v1/me")
            user = me.user
            plan = me.plan
        } catch APIError.unauthorized {
            api.token = nil
            signInState = .signedOut
        } catch {
            // offline: keep the last known plan (the reference's "last known plan snapshot")
        }
    }

    func refreshPlan() async {
        if let p: PlanSnapshot = try? await api.send("v1/billing/plan") { plan = p }
    }

    // MARK: - Billing

    func checkout(plan tier: String, yearly: Bool) async {
        struct R: Decodable { var url: String }
        do {
            let r: R = try await api.send("v1/billing/checkout", method: "POST", body: ["plan": tier, "interval": yearly ? "year" : "month"])
            if let url = URL(string: r.url) { NSWorkspace.shared.open(url) }
            paywall = nil
        } catch { show(error) }
    }

    func presentPaywall(_ source: PaywallSource) {
        paywall = source
    }

    // MARK: - Suggestions

    func loadSuggestions() async {
        struct R: Decodable { var suggestions: [Suggestion]; var lastCheckedAt: String? }
        guard let r: R = try? await api.send("v1/suggestions") else { return }
        suggestions = r.suggestions
        suggestionsCheckedAt = r.lastCheckedAt.flatMap { ISO8601DateFormatter.awan.date(from: $0) }
        suggestionIndex = min(suggestionIndex, max(0, suggestions.count - 1))
    }

    func refreshSuggestions() async {
        struct R: Decodable { var suggestions: [Suggestion] }
        do {
            let r: R = try await api.send("v1/suggestions/refresh", method: "POST", body: [String: String]())
            suggestions = r.suggestions
            suggestionsCheckedAt = Date()
        } catch { show(error) }
    }

    /// "Yes, do it" — hand the suggestion to its Awan (creating a routine if it has one).
    func accept(_ s: Suggestion) async {
        struct R: Decodable { var suggestion: Suggestion? }
        _ = try? await api.send("v1/suggestions/\(s.id)/decide", method: "POST", body: ["decision": "accepted"]) as R
        suggestions.removeAll { $0.id == s.id }
        if let routine = s.routine {
            routines.create(slug: s.awanSlug, title: routine.title ?? s.title, task: s.agentPrompt, everyMinutes: routine.everyMinutes, runNow: false)
        }
        agents.send(s.agentPrompt, to: s.awanSlug, display: s.title.replacingOccurrences(of: "I'll ", with: "Please "), source: "suggestion")
        homePage = .agent(s.awanSlug)
    }

    func decline(_ s: Suggestion) async {
        struct R: Decodable { var suggestion: Suggestion? }
        _ = try? await api.send("v1/suggestions/\(s.id)/decide", method: "POST", body: ["decision": "declined"]) as R
        withAnimation(Theme.spring) { suggestions.removeAll { $0.id == s.id } }
    }

    func adjust(_ s: Suggestion, change: String) async {
        struct R: Decodable { var suggestion: Suggestion? }
        do {
            let r: R = try await api.send("v1/suggestions/\(s.id)/adjust", method: "POST", body: ["change": change])
            if let updated = r.suggestion, let i = suggestions.firstIndex(where: { $0.id == s.id }) { suggestions[i] = updated }
        } catch { show(error) }
    }

    // MARK: - Navigation helpers

    func openHome(_ page: HomePage? = nil) {
        if let page { homePage = page }
        HomeReveal.shared.prepare(from: NotchController.shared.handOffToHome())
        isPeekOpen = false
        isHomeOpen = true
        HomeWindowController.shared.show()
    }

    func closeHome() {
        isHomeOpen = false
        HomeWindowController.shared.hide()
    }

    func openAgent(_ slug: String) {
        agents.markRead(slug)
        openHome(.agent(slug))
    }

    // MARK: - Feedback

    func show(_ message: String) {
        withAnimation(Theme.spring) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if toast == message { withAnimation(Theme.spring) { toast = nil } }
        }
    }

    func show(_ error: Error) {
        if case let APIError.quotaExceeded(kind, _) = error {
            presentPaywall(.limitHit)
            show(kind == "agent_message" ? "You're out of agent messages this month." : "You're out of talks this month.")
            return
        }
        show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "Morning" : h < 17 ? "Afternoon" : "Evening"
        if let name = user?.firstName, !name.isEmpty { return "\(part), \(name.prefix(1).uppercased() + name.dropFirst())." }
        return "\(part)."
    }
}

extension Notification.Name {
    static let awanDidSignIn = Notification.Name("awanDidSignIn")
    static let awanOpenSettings = Notification.Name("awanOpenSettings")
}
