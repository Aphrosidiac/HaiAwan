import Foundation

/// Realistic in-memory content for snapshots (the reference is always shown full).
@MainActor
enum DemoData {
    static func install() {
        let s = AppState.shared
        s.user = AwanUser(id: "demo", email: "fakhrul@ffdev.studio", displayName: "Fakhrul", avatarUrl: nil, referralHandle: "fakhrul", createdAt: "2026-09-28T18:10:47.199Z", discoveryChannel: "instagram")
        s.signInState = .signedIn
        var plan = PlanSnapshot.placeholder
        plan.usage.messages.used = 6
        s.plan = plan
        let now = Date()
        s.suggestions = [
            Suggestion(id: 1, awanSlug: "idea-forge", title: "I'll comb Indie Hackers and Product Hunt for ideas heading toward your first 100 customers",
                       description: "You told Awan you want a real app with a hundred paying customers. I'll go through recent launches and build you a sheet of 20 ideas with market size, competition, and how fast each could reach 100 paying users.",
                       agentPrompt: "…", appHint: "Safari", routine: nil, checkReason: "onboarding", status: "pending", createdAt: "2026-09-29T02:17:00.000Z"),
            Suggestion(id: 2, awanSlug: "customer-radar", title: "I'll read the launch stories of 10 breakout apps and give you a pricing verdict",
                       description: "Pricing decides how fast you get to a hundred customers.", agentPrompt: "…", appHint: "Safari", routine: nil, checkReason: "onboarding", status: "pending", createdAt: "2026-09-29T02:17:00.000Z"),
            Suggestion(id: 3, awanSlug: "market-radar", title: "I'll track the app market every morning and tell you what's moving",
                       description: "The market shifts daily.", agentPrompt: "…", appHint: "Safari", routine: RoutineSpec(everyMinutes: 1440, title: "Daily app market watch"), checkReason: "onboarding", status: "pending", createdAt: "2026-09-29T02:17:00.000Z"),
        ]
        s.suggestionsCheckedAt = now.addingTimeInterval(-1300)

        func agent(_ slug: String, _ name: String, _ role: String, _ one: String, _ preset: String, hue: Double, starter: Bool = false, pack: CharacterPack = .awanClouds) -> AwanAgent {
            var c = CharacterAppearance(pack: pack, preset: preset, cloudHue: hue)
            if pack.isFigure, let p = CharacterCatalog.figurePreset(pack, preset) { c = CharacterCatalog.apply(p) }
            return AwanAgent(slug: slug, name: name, roleText: role, oneLiner: one,
                             introMessages: ["Hey, I'm \(name), your \(role.lowercased()).", "\(one) That's what I'm here for.", "Text me below whenever you're ready, or hold control and option to just talk to me."],
                             suggestedAsks: ["Write Instagram captions for my web design studio in a bold, minimal Malaysian voice", "Go through 20 top studio Instagram pages and tell me our best caption style", "Read our last 30 posts and write 10 new captions in our voice"],
                             baseHue: hue, character: c, createdAt: now, isStarter: starter)
        }
        let roster = [
            agent("caption-desk", "Caption Desk", "Content writer", "Writes Instagram captions for a web design studio in a bold, minimal Malaysian voice.", "senja", hue: 0.74),
            agent("market-radar", "Market Radar", "Competitive analyst", "Tracks the app market daily so you always know what's winning and why.", "padi", hue: 0.36),
            agent("customer-radar", "Customer Radar", "Growth researcher", "Hunts down where your first hundred paying customers will come from.", "mawar", hue: 0.04, pack: .kawan),
            agent("idea-forge", "Idea Forge", "Product strategist", "Finds and stress tests app ideas worth building toward your first hundred customers.", "langit", hue: 0.57),
            agent("ship-lab", "Ship Lab", "Web builder", "Builds and ships websites and small web projects right on your Mac.", "pic", hue: 0.07, starter: true),
            agent("research-scout", "Research Scout", "Researcher", "Digs into companies, markets and competitors and hands you a tidy report.", "bunga", hue: 0.93, starter: true),
        ]
        let welcome = "/tmp/awan-demo/welcome.html"
        try? FileManager.default.createDirectory(atPath: "/tmp/awan-demo", withIntermediateDirectories: true)
        try? "<html><body style='font-family:sans-serif;background:#F3EFE4'><h1>hello <b>Fakhrul</b></h1></body></html>".write(toFile: welcome, atomically: true, encoding: .utf8)
        var threads: [String: AgentThread] = [:]
        threads["ship-lab"] = AgentThread(slug: "ship-lab", turns: [
            AgentTurn(id: "t1", codexTurnID: "x", prompt: "…", displayPrompt: "Build me a one-page welcome site with my name on it, then open it in my browser.",
                      startedAt: now.addingTimeInterval(-1600), completedAt: now.addingTimeInterval(-1460), status: .completed, statusLine: nil,
                      progress: [
                        ProgressItem(id: "p1", kind: .commentary, text: "Hey, I'm Ship Lab, your web builder, and I'm making you a playful one-screen welcome page.", detail: nil, at: now.addingTimeInterval(-1590)),
                        ProgressItem(id: "p2", kind: .commentary, text: "Found a likely name and five installed apps; now I'm checking their icons.", detail: nil, at: now.addingTimeInterval(-1540)),
                        ProgressItem(id: "p3", kind: .command, text: "ls /Applications", detail: nil, at: now.addingTimeInterval(-1530)),
                        ProgressItem(id: "p4", kind: .fileChange, text: "Created welcome.html", detail: nil, at: now.addingTimeInterval(-1500)),
                      ],
                      finalText: "Your personalized, single-screen welcome page is ready. I used “Fakhrul” from this Mac's account name, and included five installed apps with their real icons.",
                      summary: "A one-screen welcome page for Fakhrul is saved in the Ship Lab workspace with five real app icons.", spokenSummary: nil, doneTitle: "Welcome Page",
                      nextActions: ["Create a dark-mode version"], artifacts: [Artifact(path: welcome)], errorText: nil, computerUseRequest: nil, source: "home"),
        ], unread: false, lastActivityAt: now.addingTimeInterval(-1460))
        threads["caption-desk"] = AgentThread(slug: "caption-desk", turns: [
            AgentTurn(id: "t2", codexTurnID: nil, prompt: "…", displayPrompt: "Go through 20 top web design studio Instagram pages and tell me our best caption style",
                      startedAt: now.addingTimeInterval(-64), completedAt: nil, status: .running, statusLine: "Exploring research options",
                      progress: [
                        ProgressItem(id: "c1", kind: .commentary, text: "This will take a while; I'll review 20 studio pages and distill the strongest fit.", detail: nil, at: now.addingTimeInterval(-60)),
                        ProgressItem(id: "c2", kind: .commentary, text: "The shortlist is set; Instagram blocks direct fetching, so I'm checking indexed posts and studio-linked references.", detail: nil, at: now.addingTimeInterval(-30)),
                      ],
                      finalText: nil, summary: nil, spokenSummary: nil, doneTitle: nil, nextActions: [], artifacts: [], errorText: nil, computerUseRequest: nil, source: "home"),
        ], unread: false, lastActivityAt: now)
        threads["research-scout"] = AgentThread(slug: "research-scout", turns: [], unread: true, lastActivityAt: now.addingTimeInterval(-1300))
        s.agents.installDemo(roster: roster, threads: threads)
    }
}
