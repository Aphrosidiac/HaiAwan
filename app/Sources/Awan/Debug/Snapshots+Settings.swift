import SwiftUI

/// Snapshot registrations for the settings area. Add cases here; keep names prefixed "settings-".
///   settings-<section>            each Settings section inside Home (e.g. settings-account)
///   settings-<section>@<points>   the same page scrolled down (e.g. settings-referral@400)
///   settings-paywall-window[-yearly]  the paywall alone at the reference's 560×541 window size
///   settings-paywall-monthly/-yearly, settings-paywall-pro, settings-paywall-max
///   settings-referral, settings-referral-empty
///   settings-modal-delete, settings-modal-bug, settings-integrations-form
///   settings-integrations-composio (fake Composio catalogue, Awan-hosted Google on),
///   settings-integrations-composio-google (Composio also brokers Google), settings-account-team-incomplete
extension Snapshots {
    static var settingsNames: [String] {
        SettingsSection.allCases.map { "settings-\($0.rawValue)" } + [
            "settings-account-pro", "settings-paywall-window", "settings-paywall-window-yearly", "settings-paywall-window-info", "settings-paywall-monthly", "settings-paywall-yearly", "settings-paywall-pro", "settings-paywall-max",
            "settings-referral", "settings-referral-examples", "settings-referral-empty", "settings-modal-delete", "settings-modal-bug", "settings-integrations-form",
            "settings-integrations-composio", "settings-integrations-composio-google", "settings-account-team-incomplete",
        ]
    }

    static func settings(_ name: String) -> AnyView? {
        guard name.hasPrefix("settings-") else { return nil }
        let s = AppState.shared
        SettingsDemo.install()
        var key = String(name.dropFirst("settings-".count))
        // "settings-<page>@<offset>" renders the page scrolled down by <offset> points.
        if let at = key.firstIndex(of: "@"), let off = Double(key[key.index(after: at)...]) {
            SettingsPage.debugScrollOffset = off
            key = String(key[..<at])
        }

        switch key {
        case "account-pro":
            s.plan = SettingsDemo.plan(tier: "pro")
            return settingsHome(.account)
        case "paywall-window", "paywall-window-yearly", "paywall-window-info":
            if key == "paywall-window-info" { PaywallView.debugTip = "pro-talk" }
            return AnyView(ZStack { Color(hex: 0x808080); PaywallView(source: .limitHit, yearly: key != "paywall-window") }
                .environmentObject(s).environmentObject(s.agents).environmentObject(s.companion).environmentObject(Prefs.shared))
        case "paywall-monthly": return paywall(.limitHit, yearly: false)
        case "paywall-yearly": return paywall(.settingsUpgradeButton, yearly: true)
        case "paywall-pro":
            s.plan = SettingsDemo.plan(tier: "pro")
            return paywall(.settingsUpgradeButton, yearly: false)
        case "paywall-max":
            s.plan = SettingsDemo.plan(tier: "max")
            return paywall(.settingsUpgradeButton, yearly: false)
        case "referral":
            ReferralModel.shared.info = SettingsDemo.referral(withFriends: true)
            return settingsHome(.referral)
        case "referral-examples":
            ReferralModel.shared.info = SettingsDemo.referral(withFriends: false)
            return settingsHome(.referral)
        case "referral-empty":
            ReferralModel.shared.info = SettingsDemo.referral(withFriends: false)
            s.homePage = .referral
            return home()
        case "modal-delete":
            SettingsUI.shared.modal = .deleteAccount
            return settingsHome(.account)
        case "modal-bug":
            SettingsUI.shared.modal = .feedback(.bug)
            return settingsHome(.general)
        case "integrations-composio", "integrations-composio-google":
            SettingsDemo.installComposio(awanGoogle: key == "integrations-composio")
            return settingsHome(.integrations)
        case "account-team-incomplete":
            TeamStore.shared.detail = TeamStore.Detail(
                team: .init(id: "t1", name: "Kopi Senja", status: "incomplete"),
                me: .init(role: "owner", seat: "pro", canManage: true),
                members: [.init(userId: "u1", name: "Fakhrul", role: "owner", seat: "pro")]
            )
            return settingsHome(.account)
        case "integrations-form":
            return AnyView(
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        CustomConnectorForm(draft: CustomConnectorDraft(name: "Gmail", urlPlaceholder: "Paste this app's MCP server URL", auth: .apiKey), onCancel: {}, onAdd: { _ in })
                    }
                    .padding(28)
                }
                .background(Theme.window)
                .environmentObject(s)
            )
        default:
            guard let section = SettingsSection(rawValue: key) else { return nil }
            return settingsHome(section)
        }
    }

    private static func settingsHome(_ section: SettingsSection) -> AnyView {
        AppState.shared.homePage = .settings(section)
        return home()
    }

    private static func home() -> AnyView {
        let s = AppState.shared
        return AnyView(HomeRootView().environmentObject(s).environmentObject(s.agents).environmentObject(s.companion).environmentObject(RoutineScheduler.shared).environmentObject(Prefs.shared))
    }

    private static func paywall(_ source: PaywallSource, yearly: Bool) -> AnyView {
        let s = AppState.shared
        s.homePage = .home
        s.paywall = nil
        return AnyView(
            ZStack {
                HomeRootView()
                Color.black.opacity(0.45)
                PaywallView(source: source, yearly: yearly)
            }
            .environmentObject(s).environmentObject(s.agents).environmentObject(s.companion).environmentObject(RoutineScheduler.shared).environmentObject(Prefs.shared)
        )
    }
}

/// In-memory data for settings snapshots (never persisted).
@MainActor
enum SettingsDemo {
    static func install() {
        ConnectorStore.shared.catalog = [
            IntegrationDTO(id: "notion", name: "Notion", description: "Search pages and databases, then create, update or comment on pages and rows.", url: "https://mcp.notion.com/mcp", auth: "oauth", icon: "doc.richtext", category: "productivity"),
            IntegrationDTO(id: "linear", name: "Linear", description: "Search issues, projects and cycles, then create or update issues and comments.", url: "https://mcp.linear.app/mcp", auth: "oauth", icon: "line.3.diagonal", category: "dev"),
            IntegrationDTO(id: "github", name: "GitHub", description: "Inspect repos, issues, PRs and Actions, then create or update repo work with approval.", url: "https://api.githubcopilot.com/mcp/", auth: "oauth", icon: "chevron.left.forwardslash.chevron.right", category: "dev"),
            IntegrationDTO(id: "gmail", name: "Gmail", description: "Search and read mail with attachments listed, manage labels, draft new mail and replies, and send a draft once you approve it.", url: nil, auth: "awan-google", icon: "envelope", category: "google"),
            IntegrationDTO(id: "google-calendar", name: "Google Calendar", description: "List calendars and events, find free time, then create, move, update or delete events.", url: nil, auth: "awan-google", icon: "calendar", category: "google"),
            IntegrationDTO(id: "google-drive", name: "Google Drive", description: "Search files, read details, read Docs/Sheets/text files as text, upload, share and move files.", url: nil, auth: "awan-google", icon: "externaldrive", category: "google"),
            IntegrationDTO(id: "google-sheets", name: "Google Sheets", description: "Create spreadsheets and tabs, read ranges, append rows and write cells.", url: nil, auth: "awan-google", icon: "tablecells", category: "google"),
            IntegrationDTO(id: "slack", name: "Slack", description: "Search Slack, read channels and threads, and draft or send messages with approval.", url: nil, auth: "oauth", icon: "number", category: "productivity"),
            IntegrationDTO(id: "obsidian", name: "Obsidian", description: "Use a local Markdown vault through Awan's Obsidian skill. No account needed.", url: nil, auth: "local", icon: "diamond", category: "local"),
        ]
        ConnectorStore.shared.connectors = [
            Connector(id: "notion", name: "Notion", url: "https://mcp.notion.com/mcp", command: nil, auth: "oauth", status: "connected"),
            Connector(id: "custom-ffops", name: "FF Ops", url: "https://ops.ffdev.studio/mcp", command: nil, auth: "api_key", status: "checking"),
            Connector(id: "custom-figma", name: "Figma", url: "https://mcp.figma.com/mcp", command: nil, auth: "oauth", status: "needsSignIn"),
        ]
        // Awan-hosted Google: Gmail granted, Sheets waiting (as if Google's consent left it unticked).
        ConnectorStore.shared.handleConnectorsURL(URL(string: "awan://connectors?connected=gmail&missing=google-sheets&email=fakhrul%40ffdev.studio")!)
        // One archived Awan so "See archived Awans" has something to restore.
        let agents = AppState.shared.agents
        if let first = agents.roster.first(where: { $0.slug == "market-radar" }) {
            agents.update(first.slug) { $0.archived = true }
        }
    }

    /// A fake Composio catalogue (most used first, as the server sends it) plus two Composio rows.
    static func installComposio(awanGoogle: Bool) {
        let store = ConnectorStore.shared
        store.applyServerFeatures(composio: true, awanGoogle: awanGoogle)
        store.setComposioCatalog([
            (slug: "gmail", name: "Gmail", description: "Read, search, label and draft email.", logo: nil, category: "Email"),
            (slug: "slack", name: "Slack", description: "Search channels and threads, post messages and manage reminders.", logo: nil, category: "Communication"),
            (slug: "notion", name: "Notion", description: "Search, create and update pages, databases and comments.", logo: nil, category: "Documents & Notes"),
            (slug: "googlecalendar", name: "Google Calendar", description: "List, create and move events; find free time.", logo: nil, category: "Scheduling"),
            (slug: "googlesheets", name: "Google Sheets", description: "Read ranges, append rows and update cells.", logo: nil, category: "Documents & Notes"),
            (slug: "linkedin", name: "LinkedIn", description: "Publish posts, comment, and look up profiles and companies.", logo: nil, category: "Social Media"),
            (slug: "hubspot", name: "HubSpot", description: "Contacts, companies, deals and tickets in your CRM.", logo: nil, category: "CRM"),
            (slug: "airtable", name: "Airtable", description: "List bases and tables, then create, update or find records.", logo: nil, category: "Productivity"),
            (slug: "trello", name: "Trello", description: "Boards, lists and cards: create, move and comment.", logo: nil, category: "Productivity"),
            (slug: "discord", name: "Discord", description: "Read channels and send messages through your bot.", logo: nil, category: "Communication"),
            (slug: "shopify", name: "Shopify", description: "Orders, products, customers and inventory.", logo: nil, category: "E-commerce"),
            (slug: "xero", name: "Xero", description: "Invoices, contacts, payments and reports.", logo: nil, category: "Finance & Accounting"),
        ])
        // Slack connected through Composio; HubSpot's connect page wasn't finished yet.
        store.applyComposioStatus(["slack": true])
        _ = store.handleConnectorsURL(URL(string: "awan://connectors?source=composio&error=not_active&toolkit=hubspot")!)
    }

    static func plan(tier: String) -> PlanSnapshot {
        var p = PlanSnapshot.placeholder
        p.tier = tier
        p.plan = tier
        p.interval = "month"
        p.usage.messages = UsageBucket(cap: nil, used: 212)
        p.usage.agents = UsageBucket(cap: tier == "max" ? 1000 : 150, used: tier == "max" ? 318 : 47)
        return p
    }

    static func referral(withFriends: Bool) -> ReferralInfo {
        ReferralInfo(
            handle: "fakhrul", link: "awan.ffdev.studio/@fakhrul", url: "https://awan.ffdev.studio/@fakhrul",
            terms: .init(share: 0.25, friendDiscount: 0.25, months: 12),
            totalEarnedCents: withFriends ? 8500 : 0,
            referrals: withFriends ? [
                .init(name: "Hafiz Rahman", avatarUrl: nil, plan: "max", months: 3, earnedCents: 7500, joinedAt: nil),
                .init(name: "Nurul Aina", avatarUrl: nil, plan: "pro", months: 1, earnedCents: 500, joinedAt: nil),
                .init(name: "Jia Wen", avatarUrl: nil, plan: "pro", months: 1, earnedCents: 500, joinedAt: nil),
                .init(name: "Arif", avatarUrl: nil, plan: "free", months: 0, earnedCents: 0, joinedAt: nil),
            ] : []
        )
    }
}
