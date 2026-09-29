import SwiftUI
import AppKit

/// Teams v0 in the app: what team you're in (GET /v1/teams/me), create, join by code, and the one-time link
/// that opens the web dashboard (members, seats, invites, team skills).
@MainActor
final class TeamStore: ObservableObject {
    static let shared = TeamStore()

    struct Team: Codable, Equatable { var id: String; var name: String; var status: String }
    struct Me: Codable, Equatable { var role: String; var seat: String; var canManage: Bool }
    struct Member: Codable, Equatable, Identifiable { var userId: String; var name: String; var role: String; var seat: String; var id: String { userId } }
    struct Detail: Codable, Equatable {
        var team: Team?
        var me: Me?
        var members: [Member]?
    }

    @Published var detail: Detail?
    @Published var busy = false

    var team: Team? { detail?.team }
    var seatName: String { detail?.me?.seat == "max" ? "Max" : "Pro" }

    func load() async {
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        if let d: Detail = try? await APIClient.shared.send("v1/teams/me") { detail = d }
    }

    func create(name: String) async -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { AppState.shared.show("Give your team a name first."); return false }
        return await run { try await APIClient.shared.send("v1/teams", method: "POST", body: ["name": n]) } done: { d in
            AppState.shared.show("\(d.team?.name ?? "Your team") is ready. Invite people from Manage team.")
        }
    }

    func join(code: String) async -> Bool {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { AppState.shared.show("Paste the invite code first."); return false }
        return await run { try await APIClient.shared.send("v1/teams/join", method: "POST", body: ["code": c]) } done: { d in
            AppState.shared.show("You're in \(d.team?.name ?? "the team"). Your seat is live.")
        }
    }

    /// Opens the web dashboard through a one-time link (10 minutes, single use).
    func openDashboard() async {
        struct R: Decodable { var url: String }
        busy = true
        defer { busy = false }
        do {
            let r: R = try await APIClient.shared.send("v1/teams/dashboard-link", method: "POST", body: [String: String]())
            if let url = URL(string: r.url) { NSWorkspace.shared.open(url) }
        } catch { AppState.shared.show(error) }
    }

    private func run(_ call: () async throws -> Detail, done: (Detail) -> Void) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let d = try await call()
            detail = d
            done(d)
            await AppState.shared.refreshPlan()
            await SkillsStore.shared.load()
            return true
        } catch let APIError.server(_, message) {
            AppState.shared.show(Self.friendly(message))
        } catch {
            AppState.shared.show(error)
        }
        return false
    }

    static func friendly(_ code: String) -> String {
        switch code {
        case "invalid_code": return "That code doesn't match any invite."
        case "code_already_used": return "That invite has already been used. Ask for a fresh one."
        case "code_expired": return "That invite has expired. Ask for a fresh one."
        case "invite_is_for_another_email": return "That invite is for a different email address."
        case "already_in_a_team": return "You're already in a team."
        case "team_name_required": return "Give your team a name first."
        default: return code.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// Settings → Account → Team rows.
struct TeamSettingsRows: View {
    @ObservedObject private var store = TeamStore.shared
    @Local private var newName = ""
    @Local private var code = ""

    var body: some View {
        Group {
            if let team = store.team {
                SettingsRow(title: "Team: \(team.name) · \(store.seatName) seat", subtitle: subtitle) {
                    Button(store.busy ? "Opening…" : "Manage team") { Task { await store.openDashboard() } }
                        .buttonStyle(.gel(.bone, height: 30, padding: 14, fontSize: 12.5))
                        .disabled(store.busy)
                }
                if team.status == "incomplete" || team.status == "past_due" {
                    // Seats only apply once the team's subscription is paid; checkout lives on the web dashboard.
                    let owner = store.detail?.me?.role == "owner"
                    SettingsRow(title: team.status == "past_due" ? "Team payment needs attention" : "Finish team checkout",
                                subtitle: owner
                                    ? (team.status == "past_due" ? "The last payment didn't go through. Update the card on the dashboard to keep everyone's seats."
                                                                 : "Pick how many Pro and Max seats you need. Seats switch on for everyone once it's paid.")
                                    : "Your team owner still needs to finish checkout. Your seat switches on after that.") {
                        if owner {
                            Button(store.busy ? "Opening…" : (team.status == "past_due" ? "Fix payment" : "Finish team checkout")) { Task { await store.openDashboard() } }
                                .buttonStyle(.gel(.bone, height: 30, padding: 14, fontSize: 12.5))
                                .disabled(store.busy)
                        }
                    }
                }
                SettingsRow(title: "Team skills", subtitle: "Share a skill from its page in Skills and everyone on \(team.name) can switch it on.", showDivider: false) {
                    Button("Open Skills") {
                        SkillsStore.shared.filter = .team
                        AppState.shared.homePage = .skills
                    }
                    .buttonStyle(.gel(.dark, height: 30, padding: 14, fontSize: 12.5))
                }
            } else {
                SettingsRow(title: "Create a team", subtitle: "Give everyone a Pro or Max seat, share skills, one bill.") {
                    HStack(spacing: 8) {
                        SettingsTextField(placeholder: "Team name", text: $newName, height: 30) { Task { if await store.create(name: newName) { newName = "" } } }
                            .frame(width: 170)
                        Button("Create") { Task { if await store.create(name: newName) { newName = "" } } }
                            .buttonStyle(.gel(.dark, height: 30, padding: 14, fontSize: 12.5))
                            .disabled(store.busy || newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                SettingsRow(title: "Join a team", subtitle: "Paste the invite code your team sent you.", showDivider: false) {
                    HStack(spacing: 8) {
                        SettingsTextField(placeholder: "AWN-XXXX-XXXX", text: $code, mono: true, height: 30) { Task { if await store.join(code: code) { code = "" } } }
                            .frame(width: 170)
                        Button("Join") { Task { if await store.join(code: code) { code = "" } } }
                            .buttonStyle(.gel(.dark, height: 30, padding: 14, fontSize: 12.5))
                            .disabled(store.busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .task { await store.load() }
    }

    private var subtitle: String {
        let role = store.detail?.me?.role ?? "member"
        let n = store.detail?.members?.count ?? 1
        let people = n == 1 ? "just you so far" : "\(n) people"
        switch role {
        case "owner": return "You own this team · \(people). Invite people and set seats on the dashboard."
        case "admin": return "You're an admin · \(people)."
        default: return "Your seat is included with your team plan · \(people)."
        }
    }
}
