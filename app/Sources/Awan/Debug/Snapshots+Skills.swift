import SwiftUI

/// Snapshot registrations for Skills + Teams ("skills-*"). Everything is in memory; nothing is persisted.
///   skills-page, skills-full-slot, skills-detail, skills-create, skills-create-writing, skills-create-done,
///   skills-onboarding (the "What should Awan be good at?" picker), skills-account-team, skills-paywall-team
extension Snapshots {
    static var skillsNames: [String] {
        ["skills-page", "skills-full-slot", "skills-detail", "skills-create", "skills-create-writing", "skills-create-done",
         "skills-onboarding", "skills-account-team", "skills-paywall-team"]
    }

    static func skills(_ name: String) -> AnyView? {
        guard skillsNames.contains(name) else { return nil }
        let s = AppState.shared
        let store = SkillsStore.shared
        SkillsDemo.install()
        func home(_ page: HomePage) -> AnyView {
            s.homePage = page
            return AnyView(HomeRootView().environmentObject(s).environmentObject(s.agents).environmentObject(s.companion).environmentObject(RoutineScheduler.shared).environmentObject(Prefs.shared))
        }
        switch name {
        case "skills-page":
            return home(.skills)
        case "skills-full-slot":
            store.swapCandidate = store.library.first { $0.slug == "caption-coach" }
            return home(.skills)
        case "skills-detail":
            store.detail = SkillsDemo.detail
            return home(.skills)
        case "skills-create":
            CreateSkillSheet.debugDump = "Quotes for my web design studio's clients in KL. Short and friendly, three packages (basic, standard, premium) in ringgit, a timeline, and always a list of what's NOT included. Clients are F&B and retail owners who hate jargon."
            store.showCreate = true
            return home(.skills)
        case "skills-create-writing":
            store.creating = .writing
            store.showCreate = true
            return home(.skills)
        case "skills-create-done":
            store.creating = .done(SkillsDemo.created)
            store.showCreate = true
            return home(.skills)
        case "skills-onboarding":
            let m = OnboardingModel()
            m.stage = .skills
            m.skillPicks = ["reply-drafter", "ui-critic"]
            return AnyView(ZStack { Color(hex: 0x3A3F4A); OnboardingRootView(model: m).shadow(color: .black.opacity(0.5), radius: 30, y: 12) })
        case "skills-account-team":
            SettingsDemo.install()
            s.plan = SkillsDemo.teamPlan(seat: "pro")
            return home(.settings(.account))
        case "skills-paywall-team":
            s.plan = SkillsDemo.teamPlan(seat: "pro")
            s.homePage = .home
            s.paywall = nil
            return AnyView(
                ZStack {
                    HomeRootView()
                    Color.black.opacity(0.45)
                    PaywallView(source: .settingsUpgradeButton)
                }
                .environmentObject(s).environmentObject(s.agents).environmentObject(s.companion).environmentObject(RoutineScheduler.shared).environmentObject(Prefs.shared)
            )
        default:
            return nil
        }
    }
}

/// In-memory Skills + Teams content for snapshots.
@MainActor
enum SkillsDemo {
    static let created = SkillItem(
        slug: "client-quote-writer", title: "Client Quote Writer",
        oneLiner: "Turns your project notes into short, friendly quotes with three ringgit packages and clear scope.",
        whatsInside: ["Plain-language, jargon-free wording", "Basic, Standard, Premium in RM", "Clear scope and timeline per package", "A firm 'not included' list", "Quick next-step line to close"],
        category: "writing", categoryName: "Writing", symbol: "pencil.line", color: "#F5C451", author: "Fakhrul",
        isOfficial: false, isMine: true, teamShared: false, published: false, origin: "created", usersCount: 0,
        content: "You are a quote-writing partner for a small web design studio in Kuala Lumpur…")

    static var detail: SkillItem {
        var d = SkillsCatalog.onboarding.first { $0.slug == "ui-critic" }!
        d.usersCount = 214
        d.content = """
        You are a senior product designer giving a friendly, direct crit.

        ## When to apply
        - The user shows a design, website, app screen or slide and asks what you think.

        ## Method
        - Squint test first: what does the eye land on? Is that the right thing?
        - Check hierarchy (one primary action), spacing rhythm, alignment, contrast (4.5:1 for text), and copy.
        - Give exactly three fixes, most important first. Each: what, where, why.
        - Say one thing that already works.

        ## How to help
        - If they just ask, answer in a few spoken sentences, then offer the next step.
        - If the thing is on screen, point at it before you talk about it.
        """
        return d
    }

    static func install() {
        let store = SkillsStore.shared
        let counts = ["plain-speaker": 1840, "reply-drafter": 1312, "bm-santai": 966, "source-checker": 402, "market-snapshot": 611, "ui-critic": 214,
                      "bug-whisperer": 1105, "caption-coach": 887, "daily-planner": 1523, "meeting-minutes": 745, "explain-like-new": 530, "recipe-rescue": 97]
        var lib = SkillsCatalog.onboarding.map { item -> SkillItem in
            var i = item
            i.usersCount = counts[i.slug] ?? 0
            return i
        }
        var team = SkillItem(slug: "proposal-house-style", title: "Proposal House Style", oneLiner: "Our proposal voice: warm, specific, never salesy. Scope first, price second.",
                             whatsInside: ["Scope before price", "Kopi Senja tone of voice"], category: "writing", categoryName: "Writing", symbol: "doc.richtext.fill",
                             color: "#F5C451", author: "Aina", teamShared: true, published: false, origin: "created", usersCount: 4)
        team.isMine = false
        lib.insert(team, at: 3)
        lib.insert(created, at: 6)
        store.library = lib
        store.activeSlugs = ["plain-speaker", "ui-critic", "daily-planner"]
        store.active = lib.filter { store.activeSlugs.contains($0.slug) }
        store.teamName = "Kopi Senja"
        store.filter = .all
        store.query = ""
        store.swapCandidate = nil
        store.detail = nil
        store.showCreate = false
        store.creating = .idle
        CreateSkillSheet.debugDump = nil

        TeamStore.shared.detail = TeamStore.Detail(
            team: .init(id: "t1", name: "Kopi Senja", status: "active"),
            me: .init(role: "member", seat: "pro", canManage: false),
            members: [
                .init(userId: "u1", name: "Aina", role: "owner", seat: "max"),
                .init(userId: "demo", name: "Fakhrul", role: "member", seat: "pro"),
                .init(userId: "u3", name: "Hafiz", role: "admin", seat: "pro"),
            ])
    }

    static func teamPlan(seat: String) -> PlanSnapshot {
        var p = SettingsDemo.plan(tier: seat)
        p.plan_source = "team"
        p.team = PlanTeam(id: "t1", name: "Kopi Senja", seat: seat, role: "member")
        return p
    }
}
