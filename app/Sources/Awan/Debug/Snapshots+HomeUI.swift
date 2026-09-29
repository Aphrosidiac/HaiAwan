import SwiftUI

/// Snapshot registrations for the Home UI area (thread, inspector, suggestions, new Awan,
/// character editor, morning notch card). Names are prefixed "homeui-".
extension Snapshots {
    static var homeUINames: [String] {
        ["homeui-thread", "homeui-thread-preview", "homeui-thread-typing", "homeui-thread-running", "homeui-thread-new", "homeui-thread-failed", "homeui-thread-approval",
         "homeui-inspector", "homeui-suggestions", "homeui-suggestions-adjust", "homeui-suggestions-empty",
         "homeui-new-awan", "homeui-new-awan-answer", "homeui-editor-clouds", "homeui-editor-kawan", "homeui-editor-kawan-parts", "homeui-morning", "homeui-selftest",
         // Like-for-like with the reference captures: render at 907×627 (attached, on #808080) / 1197×809 (pop-out).
         "homeui-attached", "homeui-attached-thread", "homeui-attached-thread-top", "homeui-attached-inspector",
         "homeui-attached-collapsed", "homeui-attached-hover", "homeui-popout",
         "homeui-attached-listening", "homeui-attached-thinking", "homeui-attached-speaking"]
    }

    /// The attached Home exactly as the window draws it: neck + panel + shadow on the capture grey.
    static func attachedHome(detached: Bool = false) -> AnyView {
        let s = AppState.shared
        let root = HomeRootView()
            .environmentObject(s)
            .environmentObject(s.agents)
            .environmentObject(s.companion)
            .environmentObject(RoutineScheduler.shared)
            .environmentObject(Prefs.shared)
        if detached {
            return AnyView(root.environment(\.homeIsDetached, true))
        }
        return AnyView(
            AttachedHomeChrome(neckHeight: 30) { root }
                .background(Color(hex: 0x808080))
        )
    }

    static func homeUI(_ name: String) -> AnyView? {
        guard name.hasPrefix("homeui-") else { return nil }
        if name == "homeui-selftest" { HomeUISelfTest.run() }
        let s = AppState.shared
        HomeUIDemo.enrich()
        switch name {
        case "homeui-attached":
            s.homePage = .home
            return attachedHome()
        case "homeui-attached-listening", "homeui-attached-thinking", "homeui-attached-speaking":
            s.homePage = .home
            s.companion.voiceState = name.hasSuffix("listening") ? .listening : name.hasSuffix("thinking") ? .processing : .responding
            return attachedHome()
        case "homeui-attached-thread", "homeui-attached-thread-top", "homeui-attached-inspector":
            HomeUIDemo.referenceThread()
            s.homePage = .agent("caption-desk")
            AgentThreadPage.debugScrollToTop = name != "homeui-attached-thread"
            s.inspectorOpen = name == "homeui-attached-inspector"
            return attachedHome()
        case "homeui-attached-collapsed":
            s.homePage = .home
            s.sidebarCollapsed = true
            return attachedHome()
        case "homeui-attached-hover":
            HomeUIDemo.referenceThread()
            s.homePage = .suggestions
            SidebarRow.debugHoverTitle = "Research Scout"
            return attachedHome()
        case "homeui-popout":
            HomeUIDemo.referenceThread()
            s.homePage = .home
            return attachedHome(detached: true)
        case "homeui-thread":
            s.homePage = .agent("ship-lab")
        case "homeui-thread-preview":
            s.homePage = .agent("ship-lab")
            AgentThreadPage.debugPreview = Artifact(path: "/tmp/awan-demo/launch-notes.md")
        case "homeui-thread-typing":
            s.homePage = .agent("ship-lab")
            AgentStore.shared.updateThread("ship-lab") { $0.draft = "Make the hero bigger and use my logo from the Desktop.\nKeep the bone background." }
        case "homeui-thread-running":
            s.homePage = .agent("caption-desk")
        case "homeui-thread-new":
            s.homePage = .agent("research-scout")
        case "homeui-thread-failed":
            s.homePage = .agent("market-radar")
        case "homeui-thread-approval":
            s.homePage = .agent("customer-radar")
        case "homeui-inspector":
            s.homePage = .agent("ship-lab")
            s.inspectorOpen = true
        case "homeui-suggestions":
            s.homePage = .suggestions
        case "homeui-suggestions-adjust":
            s.homePage = .suggestions
            SuggestionsPage.debugPhase = .answering
        case "homeui-suggestions-empty":
            s.homePage = .suggestions
            s.suggestions = []
        case "homeui-new-awan":
            s.homePage = .newAwan
            NewAwanPage.debugScript = ["What would you like this new Awan to do?"]
        case "homeui-new-awan-answer":
            // New Awan interview: two lines asked, waiting for the answer.
            s.homePage = .newAwan
            NewAwanPage.debugScript = ["What would you like this new Awan to do?", "Not sure yet? We can brainstorm it together."]
            NewAwanPage.debugPhase = .answering
        case "homeui-editor-clouds":
            s.homePage = .agent("caption-desk")
            s.characterEditorSlug = "caption-desk"
        case "homeui-editor-kawan":
            s.homePage = .agent("customer-radar")
            s.characterEditorSlug = "customer-radar"
        case "homeui-editor-kawan-parts":
            // The editor's own scroll column, unclipped, to check the custom Kawan parts.
            s.characterEditorSlug = "customer-radar"
            CharacterEditorView.debugMaxHeight = 2000
            s.homePage = .agent("customer-radar")
        case "homeui-morning":
            NotchController.shared.mode = .surface(.morningSuggestions)
            return AnyView(
                NotchRootView()
                    .environmentObject(s)
                    .environmentObject(NotchController.shared)
                    .environmentObject(s.companion)
                    .background(LinearGradient(colors: [Color(hex: 0x7B5BE0), Color(hex: 0xC59BEF)], startPoint: .top, endPoint: .bottom))
            )
        default:
            return nil
        }
        return AnyView(
            HomeRootView()
                .environmentObject(s)
                .environmentObject(s.agents)
                .environmentObject(s.companion)
                .environmentObject(RoutineScheduler.shared)
                .environmentObject(Prefs.shared)
        )
    }
}

/// Extra in-memory content for the Home UI snapshots (never persisted).
@MainActor
enum HomeUIDemo {
    /// Caption Desk shaped like the reference capture: intro bubbles, a two-line ask, 5 progress
    /// messages, a multi-paragraph answer with inline links, "4m 9s · <time>", one next action.
    static func referenceThread() {
        let store = AgentStore.shared
        let now = Date()
        let start = now.addingTimeInterval(-260)
        let progress = (1...5).map { i in
            ProgressItem(id: "r\(i)", kind: .commentary, text: "Checking studio page \(i * 4) of 20.", detail: nil, at: start.addingTimeInterval(Double(i) * 40))
        }
        let answer = """
        **My pick:** keep it **bold, minimal and proof-first**. Write every caption like a tiny case study: **sharp hook → one design decision → why it matters → soft CTA**. Plain Malaysian English, no agency jargon and no forced slang.

        Lead with what changed for the client, not with the studio. The strongest studios in the set open with a number or a before/after, then name the one decision that made it work, then end on a quiet ask. Say “we” and give concrete details, never “we craft digital experiences that elevate brands.”

        One caveat: Instagram hides most captions from logged-out visitors, so I couldn’t read all 20 feeds line by line. The public roundup I could check covers five of them and matches this pattern. ([juxtapozemedia.com](https://juxtapozemedia.com))

        It also lines up with Meta’s current caption advice: add context or a story, keep the hook clear, pick one goal and use a relevant CTA. ([ai.meta.com](https://ai.meta.com))
        """
        store.updateThread("caption-desk") { t in
            t.turns = [AgentTurn(id: "ref1", codexTurnID: nil, prompt: "…",
                                 displayPrompt: "Go through 20 top web design studio Instagram pages and tell me our best caption style",
                                 startedAt: start, completedAt: start.addingTimeInterval(249), status: .completed, statusLine: nil,
                                 progress: progress, finalText: answer,
                                 summary: "The best fit is punchy, proof-led captions with one design decision each.", spokenSummary: nil, doneTitle: nil,
                                 nextActions: ["Draft 5 captions in this style"], artifacts: [], errorText: nil, computerUseRequest: nil, source: "home")]
            t.lastActivityAt = start.addingTimeInterval(249)
            t.unread = false
        }
    }

    static func enrich() {
        let store = AgentStore.shared
        let now = Date()

        // Ship Lab: a finished turn with rich markdown, files and next steps.
        let notes = "/tmp/awan-demo/launch-notes.md"
        try? """
        # Launch notes

        - **Hero:** one line, your name, five app icons
        - **Palette:** bone on ink, lime only on the button
        """.write(toFile: notes, atomically: true, encoding: .utf8)
        store.updateTurn("ship-lab", "t1") { t in
            t.finalText = """
            Your personalised **one-screen welcome page** is ready. I used “Fakhrul” from this Mac's account name and pulled five installed apps with their real icons.

            - Opens straight in your browser, no server needed
            - Works in light and dark mode
            - Everything lives in the Ship Lab workspace

            | Section | What's there |
            |---|---|
            | Hero | Your name, set in Instrument Sans |
            | Apps | Figma, Xcode, Arc, Notion, Spotify |

            Want it live? I can put it on [Cloudflare Pages](https://pages.cloudflare.com) next.
            """
            t.nextActions = ["Create a dark-mode version", "Add a contact form", "Deploy it for me"]
            t.artifacts = [Artifact(path: "/tmp/awan-demo/welcome.html"), Artifact(path: notes)]
        }

        // Caption Desk: a live turn with a typing bubble.
        store.updateTurn("caption-desk", "t2") { t in
            t.statusLine = "Exploring HTML captions"
            t.progress.append(ProgressItem(id: "c3", kind: .command, text: "curl -s https://www.instagram.com/…/?__a=1", detail: nil, at: now.addingTimeInterval(-20)))
            t.progress.append(ProgressItem(id: "c4", kind: .commentary, text: "I've narrowed the benchmark to real studios and I'm validating their public caption patterns.", detail: nil, at: now.addingTimeInterval(-10)))
        }

        // Research Scout: brand new, so its suggested asks show as sticky notes.
        store.update("research-scout") { a in
            a.introMessages = [
                "Hey, I'm Research Scout, your researcher.",
                "Point me at a company, a market or a competitor and I'll come back with a tidy report.",
                "Text me below whenever you're ready, or hold control and option to just talk to me.",
            ]
            a.suggestedAsks = [
                "Research my top three competitors and what they charge",
                "Find out who is winning in my space and why",
                "Put together a one-page brief on this company",
            ]
        }
        store.updateThread("research-scout") { $0.turns = [] }

        // Market Radar: a failed turn.
        store.updateThread("market-radar") { t in
            t.turns = [AgentTurn(id: "f1", codexTurnID: nil, prompt: "…", displayPrompt: "Check what's trending on the App Store today",
                                 startedAt: now.addingTimeInterval(-900), completedAt: now.addingTimeInterval(-840), status: .failed,
                                 progress: [ProgressItem(id: "f1p", kind: .commentary, text: "Opening the App Store charts now.", detail: nil, at: now.addingTimeInterval(-890))],
                                 errorText: "The agent couldn’t finish this task. You can try again.")]
            t.lastActivityAt = now.addingTimeInterval(-840)
        }

        // Customer Radar: waiting on a computer-use yes.
        store.updateThread("customer-radar") { t in
            t.turns = [AgentTurn(id: "a1", codexTurnID: nil, prompt: "…", displayPrompt: "Find the Reddit threads where people ask for a tool like mine",
                                 startedAt: now.addingTimeInterval(-120), completedAt: nil, status: .awaitingApproval, statusLine: "Waiting for you",
                                 progress: [ProgressItem(id: "a1p", kind: .commentary, text: "Reddit hides older threads from search, so I need to scroll them in Safari.", detail: nil, at: now.addingTimeInterval(-60))],
                                 computerUseRequest: "Open Safari, search r/SaaS and r/indiehackers for “tool for …”, and scroll the top 30 threads to copy the ones that match.")]
            t.lastActivityAt = now.addingTimeInterval(-60)
        }

        // A routine on Ship Lab for the inspector.
        if RoutineScheduler.shared.routines(for: "ship-lab").isEmpty {
            RoutineScheduler.shared.create(slug: "ship-lab", title: "Check the welcome page still loads", task: "…", everyMinutes: 1440, runNow: false)
        }
    }
}

/// `Awan --snapshot homeui-selftest /dev/null` — logic checks for the Home UI. This toolchain has no
/// XCTest/Testing, so the same cases also live in Tests/AwanTests/HomeUITests.swift for Xcode.
/// Prints each check and exits 0 (all passed) or 1.
@MainActor
enum HomeUISelfTest {
    static func run() -> Never {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "  ok   " : "  FAIL ") + what)
            if !ok { failures += 1 }
        }
        func at(_ h: Int, day: Int = 29) -> Date {
            var c = DateComponents(); c.year = 2026; c.month = 9; c.day = day; c.hour = h; c.minute = 5
            return Calendar.current.date(from: c)!
        }
        let m = MorningSuggestions.self
        check(m.shouldPresent(now: at(8), lastShown: at(9, day: 28), dismissStreak: 0, enabled: true, pending: 3, quiet: false), "morning: shows at 8am, once a day")
        check(!m.shouldPresent(now: at(6), lastShown: nil, dismissStreak: 0, enabled: true, pending: 3, quiet: false), "morning: not before 7am")
        check(!m.shouldPresent(now: at(12), lastShown: nil, dismissStreak: 0, enabled: true, pending: 3, quiet: false), "morning: not from noon")
        check(!m.shouldPresent(now: at(10), lastShown: at(7), dismissStreak: 0, enabled: true, pending: 3, quiet: false), "morning: not twice the same day")
        check(!m.shouldPresent(now: at(8), lastShown: nil, dismissStreak: 0, enabled: false, pending: 3, quiet: false), "morning: respects Suggest tasks")
        check(!m.shouldPresent(now: at(8), lastShown: nil, dismissStreak: 0, enabled: true, pending: 0, quiet: false), "morning: needs pending suggestions")
        check(!m.shouldPresent(now: at(8), lastShown: nil, dismissStreak: 0, enabled: true, pending: 2, quiet: true), "morning: stays quiet while busy")
        check(!m.shouldPresent(now: at(8), lastShown: at(8, day: 28), dismissStreak: 3, enabled: true, pending: 3, quiet: false), "morning: backs off after 3 dismissals")
        check(m.shouldPresent(now: at(8), lastShown: at(8, day: 26), dismissStreak: 3, enabled: true, pending: 3, quiet: false), "morning: tries again after 3 days")
        check(m.greeting(name: "Fakhrul", count: 3, now: at(8)) == "Good morning, Fakhrul! I have 3 ideas for today.", "morning: greeting")

        let blocks = MarkdownBlock.parse("# Title\n\nHello **there**\n\n- one\n- two\n\n1. first\n2. second\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```\ncode\n```")
        check(blocks == [
            .heading(1, "Title"), .paragraph("Hello **there**"),
            .list([.init(text: "one", indent: 0), .init(text: "two", indent: 0)], ordered: false),
            .list([.init(text: "first", indent: 0), .init(text: "second", indent: 0)], ordered: true),
            .table(header: ["a", "b"], rows: [["1", "2"]]), .code("code"),
        ], "markdown: headings, paragraphs, lists, tables, code")

        let prompt = AgentThreadPage.attachmentsHeader + "\n- /tmp/a.pdf\n- /tmp/b c.png\n\nSummarise these"
        check(AgentThreadPage.attachments(in: prompt) == ["/tmp/a.pdf", "/tmp/b c.png"], "attachments: parsed back out of the prompt")
        check(AgentThreadPage.attachments(in: "no files").isEmpty, "attachments: none when absent")

        // Recorded from the dev server on 2026-09-29 (POST /v1/awans/interview).
        let asking = #"{"done":false,"say":["Love that, friendly replies make a big difference.","Should I watch your inbox and draft replies automatically, or only when you send me an email?"]}"#
        let finished = #"{"done":true,"say":["Alright, let me set this up for you."],"awan":{"slug":"friendly-email-drafter","name":"Reply Writer","roleText":"Email Drafter","oneLiner":"Draft friendly replies to customer emails you send me and save each one as a text file.","introMessages":["Hey, I'm Reply Writer, your email drafter.","I turn customer emails you send me into warm, friendly replies.","Text me below whenever you're ready."],"suggestedAsks":["Draft a friendly reply to this customer email"],"baseHue":0.08000000000000007,"routine":null,"suggestion":null}}"#
        let a = try? JSONDecoder().decode(NewAwanPage.Reply.self, from: Data(asking.utf8))
        check(a?.done == false && a?.say.count == 2 && a?.awan == nil, "interview: follow-up question decodes")
        let f = try? JSONDecoder().decode(NewAwanPage.Reply.self, from: Data(finished.utf8))
        check(f?.done == true && f?.awan?.name == "Reply Writer" && f?.awan?.routine == nil, "interview: finished spec decodes into AwanSpecDTO")

        var answered = ""
        VoiceAnswer.shared.expect { answered = $0 }
        check(VoiceAnswer.shared.deliver("  make it weekly "), "voice answer: consumed while waiting")
        check(answered == "make it weekly" && !VoiceAnswer.shared.isWaiting, "voice answer: trimmed, delivered once")
        check(!VoiceAnswer.shared.deliver("again"), "voice answer: ignored when nobody asked")

        print(failures == 0 ? "homeui-selftest: all passed" : "homeui-selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
