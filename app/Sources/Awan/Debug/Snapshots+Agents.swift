import SwiftUI

/// Snapshot registrations for the agents area. Add cases here; keep names prefixed "agents-".
extension Snapshots {
    static var agentNames: [String] { [] }
    static func agents(_ name: String) -> AnyView? {
        switch name {
        default: return nil
        }
    }
}

/// `Awan --agent-selftest "<prompt>" [--keep]` — runs ONE real agent turn end to end, headless:
/// server lease → codex app-server (vendored runtime) → thread/start → turn/start → mapped progress
/// streamed to stdout → the parsed final turn (summary, next actions, done title, artifacts).
///
/// Token: `AWAN_TOKEN` env var, else the Keychain session. Uses a temp CodexHome and a temp agents
/// root (nothing touches the real roster, threads, routines or CodexHome). Exit 0 = completed.
@MainActor
enum AgentSelfTest {
    static func runIfRequested(_ args: [String]) {
        if args.contains("--agent-checks") {
            var ok = AgentChecks.run()
            if args.contains("--runtime") { ok = AgentChecks.runtimeHandshake() && ok }
            exit(ok ? 0 : 1)
        }
        guard let i = args.firstIndex(of: "--agent-selftest") else { return }
        let prompt = args.count > i + 1 ? args[i + 1] : "Make a one-page HTML file called hello.html in your output folder that says hi, then finish with the protocol blocks."
        let keep = args.contains("--keep")
        AgentStore.persistenceEnabled = false
        Sounds.muted = true
        _ = NSApplication.shared

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("awan-selftest-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        let agentsRoot = Paths.ensure(root.appendingPathComponent("agents", isDirectory: true))
        let home = Paths.ensure(root.appendingPathComponent("CodexHome", isDirectory: true))
        // Volatile (never written to disk) override of the agents folder.
        var argDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)   // keeps `-awan.api.baseURL …`
        argDomain[Prefs.Key.agentFolder] = agentsRoot.path
        UserDefaults.standard.setVolatileDomain(argDomain, forName: UserDefaults.argumentDomain)
        if let t = ProcessInfo.processInfo.environment["AWAN_TOKEN"], !t.isEmpty { AgentAPI.tokenOverride = t.trimmingCharacters(in: .whitespacesAndNewlines) }
        CodexAppServer.shared.homeOverride = home

        func out(_ s: String) { print(s); fflush(stdout) }
        out("── Awan agent self-test")
        out("server   \(APIClient.shared.baseURL.absoluteString)")
        out("runtime  \(Paths.codexBinary?.path ?? "MISSING")")
        out("home     \(home.path)")
        out("agents   \(agentsRoot.path)")
        guard AgentAPI.token != nil else { out("no token: set AWAN_TOKEN or sign in"); exit(3) }

        let store = AgentStore.shared
        let agent = store.create(from: AwanSpecDTO(
            slug: "selftest-scout", name: "Test Scout", roleText: "Web builder",
            oneLiner: "Builds small web pages and reports back tidily.",
            introMessages: [], suggestedAsks: [], baseHue: 0.3, routine: nil, suggestion: nil))
        // AgentStore skips AGENTS.md while persistence is off — write it for the temp Awan.
        let agentsMD = """
        # \(agent.name) — \(agent.roleText)

        You are \(agent.name), one of the user's Awans. \(agent.oneLiner)

        ## Standing preferences

        - (none yet)

        ## Notes

        - created for a self-test.
        """
        try? agentsMD.write(to: agent.workspace.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let runner = store.runner
        runner.headless = true
        let started = Date()
        runner.trace = { line in out(String(format: "%6.1fs  ", Date().timeIntervalSince(started)) + line) }
        out("prompt   \(prompt)\n")

        // Optional second turn after a runtime restart: proves thread/resume + thread memory.
        let followUp = args.firstIndex(of: "--followup").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
        var prompts = [prompt]
        if let followUp { prompts.append(followUp) }
        var allOK = true
        for (n, p) in prompts.enumerated() {
            if n > 0 {
                out("\n── restarting the runtime, then follow-up turn (expects thread/resume)")
                CodexAppServer.shared.stop()
                out("prompt   \(p)\n")
            }
            guard let turnID = store.send(p, to: agent.slug, display: p, source: "home") else { out("send failed"); exit(4) }
            if n == 0, let s = args.firstIndex(of: "--interrupt-after").flatMap({ args.count > $0 + 1 ? Double(args[$0 + 1]) : nil }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + s) {
                    out(String(format: "%6.1fs  ", Date().timeIntervalSince(started)) + "── user presses Stop")
                    store.interrupt(agent.slug)
                }
            }
            guard let t = wait(for: turnID, slug: agent.slug, started: started, out) else {
                out("timed out")
                CodexAppServer.shared.stop()
                exit(5)
            }
            report(t, out)
            allOK = allOK && (t.status == .completed || t.status == .awaitingApproval)
            if t.status != .completed { break }   // a follow-up needs a finished turn
        }
        let routines = RoutineScheduler.shared.routines(for: agent.slug)
        if !routines.isEmpty {
            out("\n── Routines registered")
            for r in routines { out("  - \(r.title) · \(r.cadenceText) · next \(r.nextRunAt) · paused=\(r.isPaused)\n    task: \(r.task)") }
        }
        CodexAppServer.shared.stop()
        if !keep { try? FileManager.default.removeItem(at: home) }
        out("\n(workspace kept at \(agent.workspace.path))")
        exit(allOK ? 0 : 1)
    }

    private static func wait(for turnID: String, slug: String, started: Date, _ out: (String) -> Void) -> AgentTurn? {
        let store = AgentStore.shared
        var lastStatus = ""
        var lastLine = ""
        let deadline = Date().addingTimeInterval(15 * 60)
        func stamp() -> String { String(format: "%6.1fs  ", Date().timeIntervalSince(started)) }
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
            guard let t = store.thread(slug).turns.first(where: { $0.id == turnID }) else { continue }
            if t.status.rawValue != lastStatus { lastStatus = t.status.rawValue; out(stamp() + "status → \(lastStatus)") }
            if let l = t.statusLine, l != lastLine { lastLine = l; out(stamp() + "statusLine: \(l)") }
            if !t.status.isActive || t.status == .awaitingApproval {
                // let trailing writes land
                let settle = Date().addingTimeInterval(0.6)
                while Date() < settle { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
                return store.thread(slug).turns.first(where: { $0.id == turnID }) ?? t
            }
        }
        return nil
    }

    private static func report(_ t: AgentTurn, _ out: (String) -> Void) {
        out("\n── Final turn")
        out("status        \(t.status.rawValue)\(t.durationText.map { " in \($0)" } ?? "")")
        if let e = t.errorText { out("error         \(e)") }
        out("codexTurnID   \(t.codexTurnID ?? "-")")
        out("toolCalls     \(t.toolCallCount ?? 0)   tokens \(t.tokensUsed.map(String.init) ?? "-")")
        out("summary       \(t.summary ?? "-")")
        out("spoken        \(t.spokenSummary ?? "-")")
        out("doneTitle     \(t.doneTitle ?? "-")")
        out("nextActions   \(t.nextActions.isEmpty ? "-" : t.nextActions.map { "“\($0)”" }.joined(separator: ", "))")
        out("artifacts     \(t.artifacts.isEmpty ? "-" : "")")
        for a in t.artifacts {
            let exists = a.path.hasPrefix("http") || FileManager.default.fileExists(atPath: a.path)
            out("  - [\(a.kind.label)] \(a.path) \(exists ? "(exists)" : "(MISSING)")")
        }
        if let c = t.computerUseRequest { out("computerUse   \(c)") }
        if let x = t.extraUsageRequest { out("extraUsage    \(x)") }
        out("progress      \(t.progress.count) items")
        for p in t.progress { out("  · [\(p.kind.rawValue)] \(p.text.replacingOccurrences(of: "\n", with: " ").prefix(120))") }
        out("finalText ↓\n\(t.finalText ?? "-")")
    }
}

/// `Awan --agent-checks` — offline checks of the agent runtime's pure parts (the SwiftPM test target
/// can't load XCTest or swift-testing macros under the Command Line Tools, so this is the instrument).
@MainActor
enum AgentChecks {
    private static var failures = 0
    private static func check(_ ok: Bool, _ what: String, _ got: Any? = nil) {
        if ok { print("  ✓ \(what)") } else { failures += 1; print("  ✗ \(what)" + (got.map { " — got \($0)" } ?? "")) }
    }

    static func run() -> Bool {
        failures = 0
        print("── output protocol")
        let full = AgentOutput.parse("""
        Your page is ready: a single **hello** page.

        <SUMMARY>Your `hello.html` page is ready in the output folder.</SUMMARY>
        <NEXT_ACTIONS>
        - Add a dark mode
        - Make it responsive.
        1. Deploy it somewhere
        </NEXT_ACTIONS>
        <DONE_TITLE>Hello Page</DONE_TITLE>
        <ARTIFACTS>
        - /tmp/x/output/hello.html
        - `https://example.com/made`
        - file:///tmp/x/output/b.pdf
        </ARTIFACTS>
        <ROUTINE>{"action":"create","every_minutes":"60","title":"Hourly Check","task":"Check the page"}</ROUTINE>
        <ROUTINE>{"action":"pause","title":"Old One"}</ROUTINE>
        """)
        check(full.body == "Your page is ready: a single **hello** page.", "body keeps the answer, drops every block", full.body)
        check(full.summary == "Your hello.html page is ready in the output folder.", "summary is plain text", full.summary as Any)
        check(full.nextActions == ["Add a dark mode", "Make it responsive", "Deploy it somewhere"], "next actions (bullets, numbers, trailing dot)", full.nextActions)
        check(full.doneTitle == "Hello Page", "done title", full.doneTitle as Any)
        check(full.artifacts == ["/tmp/x/output/hello.html", "https://example.com/made", "/tmp/x/output/b.pdf"], "artifacts (ticks, file:// URLs)", full.artifacts)
        check(full.routines == [
            RoutineCommand(action: .create, everyMinutes: 60, title: "Hourly Check", task: "Check the page", newTitle: nil),
            RoutineCommand(action: .pause, everyMinutes: nil, title: "Old One", task: nil, newTitle: nil),
        ], "routine commands (string minutes, several blocks)", full.routines)

        let cu = AgentOutput.parse("I need your screen.\n<COMPUTER_USE_REQUEST>Can I open Notes and type this?</COMPUTER_USE_REQUEST>\n<SUMMARY>Can I use your screen to open Notes?")
        check(cu.body == "I need your screen." && cu.computerUseRequest == "Can I open Notes and type this?", "computer-use request", cu)
        check(cu.summary == "Can I use your screen to open Notes?", "unclosed trailing SUMMARY still parses", cu.summary as Any)
        let bare = AgentOutput.parse("Just an answer.\n\n| a | b |\n|---|---|")
        check(bare.body == "Just an answer.\n\n| a | b |\n|---|---|" && bare.summary == nil && bare.nextActions.isEmpty, "no blocks → body untouched, summary nil (server fallback)")
        check(AgentOutput.headline(fromReasoning: "**Considering documentation style**\n\nI need to…") == "Considering documentation style", "reasoning headline from **bold**")

        print("── progress wording")
        let heredoc = "/bin/zsh -lc \"cat AGENTS.md && mkdir -p output && cat > output/hello.html <<'EOF'\n<p>echo > nope.txt</p>\nEOF\nls -l output\""
        let unwrapped = AgentRunner.unwrapShell(heredoc)
        check(unwrapped.hasPrefix("cat AGENTS.md"), "unwraps zsh -lc", unwrapped)
        check(AgentRunner.writtenFile(in: unwrapped) == "hello.html", "heredoc write → Writing hello.html", AgentRunner.writtenFile(in: unwrapped) as Any)
        check(AgentRunner.writtenFile(in: "ls -la output") == nil, "no false write")
        check(AgentRunner.commandHeadline("curl -sL https://example.com/x | head") == "Fetching example.com", "curl → Fetching host")
        check(AgentRunner.commandHeadline("python3 make.py") == "Running a script", "python → Running a script")

        print("── config.toml")
        let home = URL(fileURLWithPath: "/tmp/Awan Home")
        let toml = CodexConfig.render(.init(
            home: home, apiBaseURL: "http://127.0.0.1:8787/", model: "awan-agent", effort: "medium",
            agentsRoot: URL(fileURLWithPath: "/tmp/agents \"q\""), computerUse: (URL(string: "http://127.0.0.1:61829/mcp")!, ["click", "list_apps"]),
            skills: [home.appendingPathComponent("skills/awan-artifacts")], connectorsTOML: "[mcp_servers.notion]\nurl = \"https://mcp.notion.com/mcp\""))
        let firstTable = toml.range(of: "\n[")?.lowerBound
        let instr = toml.range(of: "model_instructions_file = \"/tmp/Awan Home/awan-model-instructions.md\"")?.lowerBound
        check(instr != nil && firstTable != nil && instr! < firstTable!, "model_instructions_file is a top-level key")
        check(toml.contains("base_url = \"http://127.0.0.1:8787/agent/openai/v1\""), "provider base_url")
        check(toml.contains("env_key = \"AWAN_AGENT_TOKEN\"") && toml.contains("wire_api = \"responses\""), "provider env_key + responses wire")
        check(toml.contains("[projects.\"/tmp/agents \\\"q\\\"\"]"), "trusted project path is TOML-escaped")
        check(toml.contains("[mcp_servers.computer-use]") && toml.contains("enabled_tools = [\"click\", \"list_apps\"]"), "computer-use MCP server")
        check(toml.contains("[[skills.config]]\npath = \"/tmp/Awan Home/skills/awan-artifacts/SKILL.md\""), "skills config entries point at SKILL.md")
        check(toml.contains("[mcp_servers.notion]"), "connector TOML appended")
        check(CodexConfig.codexEffort("Extra High") == "xhigh" && CodexConfig.codexEffort("max") == "xhigh" && CodexConfig.codexEffort("") == "medium", "effort mapping")

        print(failures == 0 ? "all agent checks passed" : "\(failures) agent check(s) FAILED")
        return failures == 0
    }

    /// `--agent-checks --runtime`: real `codex app-server` handshake + thread/start in a temp CodexHome
    /// (no model call, no quota), then scans the runtime's stderr for config keys it ignored.
    static func runtimeHandshake() -> Bool {
        failures = 0
        print("── runtime handshake")
        if let t = ProcessInfo.processInfo.environment["AWAN_TOKEN"], !t.isEmpty { AgentAPI.tokenOverride = t.trimmingCharacters(in: .whitespacesAndNewlines) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("awan-checks-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        let home = Paths.ensure(root.appendingPathComponent("CodexHome", isDirectory: true))
        let ws = Paths.ensure(root.appendingPathComponent("ws", isDirectory: true))
        CodexAppServer.shared.homeOverride = home
        var threadID: String?
        var failure: String?
        var done = false
        Task { @MainActor in
            do {
                let r = try await CodexAppServer.shared.call("thread/start", ["cwd": .string(ws.path), "developerInstructions": "You are a check.", "ephemeral": true], timeout: 30)
                threadID = r["thread"]?["id"]?.string
            } catch { failure = error.localizedDescription }
            done = true
        }
        let deadline = Date().addingTimeInterval(40)
        while !done && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
        CodexAppServer.shared.stop()
        check(failure == nil && threadID != nil, "initialize + thread/start", failure ?? threadID as Any)
        let instructions = (try? String(contentsOf: home.appendingPathComponent(CodexConfig.instructionsFileName), encoding: .utf8)) ?? ""
        check(instructions.contains("<SUMMARY>"), "model instructions file written (\(instructions.count) chars)")
        let stderr = (try? String(contentsOf: home.appendingPathComponent("log/app-server.stderr.log"), encoding: .utf8)) ?? ""
        let ignored = stderr.components(separatedBy: .newlines).filter { $0.contains("is ignored") }
        check(ignored.isEmpty, "Codex accepted every config key", ignored.joined(separator: " | "))
        try? FileManager.default.removeItem(at: root)
        print(failures == 0 ? "runtime handshake passed" : "runtime handshake FAILED")
        return failures == 0
    }
}
