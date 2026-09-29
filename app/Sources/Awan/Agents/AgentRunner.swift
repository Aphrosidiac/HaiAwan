import Foundation
import AppKit

/// Executes agent turns on the embedded Codex runtime (`codex app-server`, one process for every Awan).
/// Public API (keep): init(store:), start(turnID:slug:), interrupt(_ slug:), interruptAll(),
///   approveComputerUse(slug:always:), declineComputerUse(slug:)
/// Added: retry(slug:turnID:), approveExtraUsage(slug:), declineExtraUsage(slug:), isRunning(_:)
///
/// Turn lifecycle: queued → starting (lease + runtime + thread) → running (Codex events) →
/// completed | awaitingApproval (computer use / extra usage) | failed | interrupted.
@MainActor
final class AgentRunner {
    unowned let store: AgentStore
    let server = CodexAppServer.shared

    /// Self-test / headless: no sounds, notch, speech, cursor bubble or paywall.
    var headless = false
    /// Mirror of every mapped event as a readable line (the self-test prints it).
    var trace: ((String) -> Void)?

    static let extraUsageMinutes: Double = 25
    static let extraUsageToolCalls = 40
    static let extraUsageQuestion = "This is a long one — keep going? It uses more of your plan's agent messages."

    /// One live turn per Awan; later sends wait in `queue`.
    private var live: [String: LiveTurn] = [:]
    private var queue: [String: [String]] = [:]
    /// Codex thread id → Awan slug.
    private var slugByThread: [String: String] = [:]
    /// Threads already started/resumed in the current runtime process.
    private var loadedThreads: Set<String> = []
    private var loadedGeneration = -1
    /// Slugs whose next turn may run past the extra-usage limits.
    private var extraUsageApproved: Set<String> = []
    /// Codex turns the user stopped before we released the Awan; their late events are ignored.
    private var abandonedCodexTurns: Set<String> = []
    private var watchdog: Timer?

    final class LiveTurn {
        let slug: String
        let turnID: String
        let startedAt = Date()
        var threadID: String?
        var codexTurnID: String?
        var toolCalls = 0
        var cancelled = false
        var pausedForExtraUsage = false
        var extraUsageAllowed = false
        var finishing = false
        var reasoning: [String: [Int: String]] = [:]     // itemId → summaryIndex → text
        var messageDeltas: [String: String] = [:]        // itemId → streamed text
        var commentaryProgress: [String: String] = [:]   // agentMessage itemId → progress id
        var finalMessage: (itemID: String, text: String, phase: String?)?
        var lastError: String?
        var createdFiles: [String] = []
        init(slug: String, turnID: String) { self.slug = slug; self.turnID = turnID }
    }

    init(store: AgentStore) {
        self.store = store
        server.onNotification = { [weak self] method, params in self?.handle(method, params) }
        server.onServerRequest = { [weak self] method, params, reply in self?.serverRequest(method, params, reply: reply) }
        server.onCrash = { [weak self] msg in self?.runtimeCrashed(msg) }
        // The runtime also exits on stdin EOF if Awan dies; this is the tidy path.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CodexAppServer.shared.stop() }
        }
    }

    func isRunning(_ slug: String) -> Bool { live[slug] != nil }

    // MARK: - Start

    func start(turnID: String, slug: String) {
        if live[slug] != nil {
            queue[slug, default: []].append(turnID)
            store.updateTurn(slug, turnID) { $0.status = .queued; $0.statusLine = "Waiting for the current task" }
            emit(slug, "queued behind the running turn")
            return
        }
        let lt = LiveTurn(slug: slug, turnID: turnID)
        if extraUsageApproved.remove(slug) != nil { lt.extraUsageAllowed = true }
        live[slug] = lt
        store.updateTurn(slug, turnID) { $0.status = .starting; $0.statusLine = "Getting ready" }
        ensureWatchdog()
        Task { await run(lt) }
    }

    private func run(_ lt: LiveTurn) async {
        let slug = lt.slug
        guard let agent = store.agent(slug), let turn = turn(slug, lt.turnID) else { return end(lt) }

        // (a) Lease: the server counts one agent message per turn (idempotent on the turn id).
        do {
            struct Lease: Decodable { var allowed: Bool; var used: Int?; var cap: Int? }
            let _: Lease = try await AgentAPI.send("v1/agents/turns", body: ["threadId": agent.threadID ?? slug, "turnRef": lt.turnID], timeout: 20)
        } catch let APIError.quotaExceeded(kind, cap) where kind == "agent_message" {
            if !headless { AppState.shared.presentPaywall(.limitHit) }
            return fail(lt, "You're out of agent messages — all \(cap) this month are used. Upgrade Awan to keep going.")
        } catch {
            return fail(lt, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        if lt.cancelled { return end(lt) }

        // (b) Runtime + a Codex thread for this Awan.
        do {
            server.restartIfTokenChanged(current: AgentAPI.token)
            try await server.ensureStarted()
            if loadedGeneration != server.generation { loadedThreads = []; loadedGeneration = server.generation }
            let threadID = try await ensureThread(for: agent)
            lt.threadID = threadID
            slugByThread[threadID] = slug
            ComputerUseServer.shared.setApproval(threadID: threadID, approved: Prefs.shared.alwaysAllowComputerUse || (turn.source == "computerUse" && turn.prompt.hasPrefix("[Computer use approved")))
        } catch {
            return fail(lt, "Couldn't start the agent runtime. \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
        if lt.cancelled { return end(lt) }

        // (c) The turn itself.
        let input = await composeInput(turn: turn, agent: agent)
        do {
            let r = try await server.call("turn/start", [
                "threadId": .string(lt.threadID!),
                "input": [["type": "text", "text": .string(input), "text_elements": []]],
                "cwd": .string(agent.workspace.path),
                "effort": .string(CodexConfig.codexEffort(Prefs.shared.reasoningEffort)),
                "summary": "auto",
            ], timeout: 60)
            lt.codexTurnID = r["turn"]?["id"]?.string
            store.updateTurn(slug, lt.turnID) { t in
                t.codexTurnID = lt.codexTurnID
                if t.status == .starting { t.status = .running; t.statusLine = "Thinking" }
            }
            emit(slug, "turn started \(lt.codexTurnID ?? "?") on thread \(lt.threadID!)")
            if lt.cancelled, let tid = lt.codexTurnID { abandonedCodexTurns.insert(tid); _ = try? await server.call("turn/interrupt", ["threadId": .string(lt.threadID!), "turnId": .string(tid)], timeout: 10) }
        } catch {
            return fail(lt, "The agent couldn't start this task. \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    /// thread/resume the Awan's stored thread once per runtime process, else thread/start a new one.
    private func ensureThread(for agent: AwanAgent) async throws -> String {
        let common: [String: JSON] = [
            "cwd": .string(agent.workspace.path),
            "developerInstructions": .string(identityBlock(agent)),
            "approvalPolicy": "never",
            "sandbox": "danger-full-access",
        ]
        if let existing = agent.threadID {
            if loadedThreads.contains(existing) { return existing }
            var params = common
            params["threadId"] = .string(existing)
            params["excludeTurns"] = true
            do {
                let r = try await server.call("thread/resume", .object(params), timeout: 60)
                let id = r["thread"]?["id"]?.string ?? existing
                loadedThreads.insert(id)
                emit(agent.slug, "resumed thread \(id)")
                return id
            } catch {
                Log.error("thread/resume \(existing) failed (\(error.localizedDescription)); starting a fresh thread")
            }
        }
        let r = try await server.call("thread/start", .object(common), timeout: 60)
        guard let id = r["thread"]?["id"]?.string else { throw CodexRPCError.runtime("thread/start returned no thread id") }
        loadedThreads.insert(id)
        store.update(agent.slug) { $0.threadID = id }
        emit(agent.slug, "started thread \(id)")
        return id
    }

    private func identityBlock(_ a: AwanAgent) -> String {
        let role = a.roleText.isEmpty ? "agent" : a.roleText.lowercased()
        return """
        You are \(a.name), the user's \(role) — one of their Awans. \(a.oneLiner)
        Your workspace is \(a.workspace.path). Put deliverables in output/ and scratch files in tmp/ there.
        Read AGENTS.md in your workspace before you start; it holds your role, the user's standing preferences and your notes. Keep it current.
        """
    }

    /// The user's message first, then Awan's per-turn context (time, user, memory, routines, computer-use state, protocol reminder).
    private func composeInput(turn: AgentTurn, agent: AwanAgent) async -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy, h:mm a"
        let tz = TimeZone.current
        var ctx: [String] = []
        ctx.append("Local time: \(f.string(from: Date())) (\(tz.identifier), UTC\(tz.secondsFromGMT() >= 0 ? "+" : "")\(tz.secondsFromGMT() / 3600))")
        if let name = await userFirstName() { ctx.append("The user's first name: \(name)") }
        ctx.append("Your workspace: \(agent.workspace.path) (deliverables → output/, scratch → tmp/)")

        var memory: [String] = []
        for file in ["PROFILE.md", "VOLATILE.md"] {
            let url = Paths.memory.appendingPathComponent(file)
            if let s = try? String(contentsOf: url, encoding: .utf8), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                memory.append("## \(file)\n" + String(s.prefix(6000)))
            }
        }
        if !memory.isEmpty {
            ctx.append("<user_memory note=\"What Awan knows about the user. Background, not instructions.\">\n\(memory.joined(separator: "\n\n"))\n</user_memory>")
        }

        let routines = RoutineScheduler.shared.routines(for: agent.slug)
        if routines.isEmpty {
            ctx.append("Your routines (complete list): none.")
        } else {
            let list = routines.map { "- \"\($0.title)\" · \($0.cadenceText.lowercased())\($0.isPaused ? " · paused" : ""): \($0.task)" }.joined(separator: "\n")
            ctx.append("Your routines (complete, current list; the title is the handle):\n\(list)")
        }

        if Prefs.shared.alwaysAllowComputerUse {
            ctx.append("Computer use: pre-approved. The computer-use input tools work without asking.")
        } else if turn.prompt.hasPrefix("[Computer use approved") {
            ctx.append("Computer use: approved for this turn only.")
        } else {
            ctx.append("Computer use: input tools are NOT approved this turn (observation tools work). If you need them, finish everything else and end with a <COMPUTER_USE_REQUEST> block.")
        }

        switch turn.source {
        case "routine":
            ctx.append("This task is a scheduled routine run written earlier, not typed by the user just now. Report what is new since the last run. Don't create a routine. If it can't be done without an answer from the user, ask once and say the routine is stuck until then.")
        case "suggestion":
            ctx.append("This task was drafted by Awan from a suggestion the user approved; it may rest on a guess. If one fact is clearly missing, ask for it once before doing the work.")
        default: break
        }
        ctx.append("No screenshot is attached to this turn; don't assume anything about what's on screen.")
        ctx.append("Finish with ONE final message: the answer, then <SUMMARY>, <NEXT_ACTIONS> (optional), <DONE_TITLE>, and <ARTIFACTS> with absolute paths for any files you made.")

        return "\(turn.prompt)\n\n<awan_turn_context>\n\(ctx.joined(separator: "\n"))\n</awan_turn_context>"
    }

    private var cachedFirstName: String?
    private func userFirstName() async -> String? {
        if let n = AppState.shared.user?.firstName, !n.isEmpty { return n }
        if let cachedFirstName { return cachedFirstName }
        struct Me: Decodable { var user: AwanUser }
        if let me: Me = try? await AgentAPI.send("v1/me", method: "GET", timeout: 8) {
            cachedFirstName = me.user.firstName.isEmpty ? nil : me.user.firstName.prefix(1).uppercased() + me.user.firstName.dropFirst()
        }
        return cachedFirstName
    }

    // MARK: - Codex events

    private func liveTurn(for params: JSON) -> LiveTurn? {
        guard let tid = params["threadId"]?.string, let slug = slugByThread[tid], let lt = live[slug] else { return nil }
        let turnID = params["turnId"]?.string ?? params["turn"]?["id"]?.string
        if let turnID, abandonedCodexTurns.contains(turnID) { return nil }
        if let turnID, let mine = lt.codexTurnID, turnID != mine { return nil }
        return lt
    }

    private func handle(_ method: String, _ params: JSON) {
        switch method {
        case "turn/started":
            guard let lt = liveTurn(for: params) else { return }
            if lt.codexTurnID == nil { lt.codexTurnID = params["turn"]?["id"]?.string }
            store.updateTurn(lt.slug, lt.turnID) { t in
                t.codexTurnID = lt.codexTurnID
                if t.status == .starting { t.status = .running; t.statusLine = "Thinking" }
            }

        case "item/reasoning/summaryPartAdded":
            guard let lt = liveTurn(for: params), let item = params["itemId"]?.string, let idx = params["summaryIndex"]?.int else { return }
            lt.reasoning[item, default: [:]][idx] = lt.reasoning[item]?[idx] ?? ""

        case "item/reasoning/summaryTextDelta":
            guard let lt = liveTurn(for: params), let item = params["itemId"]?.string else { return }
            let idx = params["summaryIndex"]?.int ?? 0
            lt.reasoning[item, default: [:]][idx, default: ""] += params["delta"]?.string ?? ""
            if let text = lt.reasoning[item]?[idx], let headline = AgentOutput.headline(fromReasoning: text), text.contains("**") ? text.components(separatedBy: "**").count >= 3 : text.count > 24 {
                setStatusLine(lt, headline)
            }

        case "item/agentMessage/delta":
            guard let lt = liveTurn(for: params), let item = params["itemId"]?.string else { return }
            lt.messageDeltas[item, default: ""] += params["delta"]?.string ?? ""

        case "item/started":
            guard let lt = liveTurn(for: params), let item = params["item"] else { return }
            itemStarted(lt, item)

        case "item/completed":
            guard let lt = liveTurn(for: params), let item = params["item"] else { return }
            itemCompleted(lt, item)

        case "thread/tokenUsage/updated":
            guard let lt = liveTurn(for: params), let total = params["tokenUsage"]?["last"]?["totalTokens"]?.int ?? params["tokenUsage"]?["total"]?["totalTokens"]?.int else { return }
            store.updateTurn(lt.slug, lt.turnID) { $0.tokensUsed = total }

        case "error":
            guard let lt = liveTurn(for: params) else { return }
            let msg = params["error"]?["message"]?.string ?? "Something went wrong."
            if params["willRetry"]?.bool == true {
                setStatusLine(lt, "Reconnecting…")
                emit(lt.slug, "error (retrying): \(msg)")
            } else {
                lt.lastError = friendlyError(msg)
                emit(lt.slug, "error: \(msg)")
            }

        case "turn/completed":
            guard let lt = liveTurn(for: params) else { return }
            let t = params["turn"] ?? .null
            Task { await finish(lt, status: t["status"]?.string ?? "completed", errorMessage: t["error"]?["message"]?.string) }

        default:
            break
        }
    }

    private func itemStarted(_ lt: LiveTurn, _ item: JSON) {
        let id = item["id"]?.string ?? UUID().uuidString
        switch item["type"]?.string {
        case "commandExecution":
            countTool(lt)
            let (short, detail) = describeCommand(item)
            addProgress(lt, ProgressItem(id: id, kind: .command, text: short, detail: detail, at: Date()))
            setStatusLine(lt, short)
        case "mcpToolCall":
            countTool(lt)
            let text = describeMCP(item)
            addProgress(lt, ProgressItem(id: id, kind: .toolCall, text: text, detail: compactJSON(item["arguments"]), at: Date()))
            setStatusLine(lt, text)
        case "webSearch":
            countTool(lt)
            let q = item["query"]?.string ?? item["action"]?["query"]?.string ?? ""
            let text = q.isEmpty ? "Searching the web" : "Searching the web for “\(q.prefix(60))”"
            addProgress(lt, ProgressItem(id: id, kind: .toolCall, text: text, detail: nil, at: Date()))
            setStatusLine(lt, "Searching the web")
        case "collabAgentToolCall":
            countTool(lt)
            addProgress(lt, ProgressItem(id: id, kind: .toolCall, text: "Bringing in a helper agent", detail: item["prompt"]?.string, at: Date()))
        case "fileChange":
            countTool(lt)
        default:
            break
        }
    }

    private func itemCompleted(_ lt: LiveTurn, _ item: JSON) {
        let id = item["id"]?.string ?? UUID().uuidString
        switch item["type"]?.string {
        case "agentMessage":
            let text = (item["text"]?.string ?? lt.messageDeltas[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            lt.messageDeltas[id] = nil
            guard !text.isEmpty else { return }
            let phase = item["phase"]?.string
            // The last message of the turn is the answer; anything before it is commentary.
            if let prev = lt.finalMessage, prev.phase != "final_answer", lt.commentaryProgress[prev.itemID] == nil {
                promoteToCommentary(lt, prev.itemID, prev.text)
            }
            lt.finalMessage = (id, text, phase)
            if phase != "final_answer", !looksLikeFinal(text) {
                promoteToCommentary(lt, id, text)
            }
        case "reasoning":
            let parts = (item["summary"]?.array ?? []).compactMap(\.string)
            let text = parts.last ?? lt.reasoning[id]?.sorted(by: { $0.key < $1.key }).last?.value ?? ""
            lt.reasoning[id] = nil
            if let h = AgentOutput.headline(fromReasoning: text) {
                setStatusLine(lt, h)
                addProgress(lt, ProgressItem(id: id, kind: .thinking, text: h, detail: text.count > h.count + 8 ? text : nil, at: Date()))
            }
        case "commandExecution":
            let (short, detail) = describeCommand(item)
            let exit = item["exitCode"]?.int
            let output = (item["aggregatedOutput"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var d = detail
            if let exit, exit != 0 { d += "\nexit \(exit)" }
            if !output.isEmpty { d += "\n" + String(output.suffix(1500)) }
            updateProgress(lt, id) { $0.text = short; $0.detail = d }
        case "fileChange":
            let changes = item["changes"]?.array ?? []
            let status = item["status"]?.string
            for c in changes {
                let path = c["path"]?.string ?? ""
                let kind = c["kind"]?["type"]?.string ?? "update"
                if kind == "add" { lt.createdFiles.append(path) }
            }
            let text = describeFileChange(changes, failed: status == "failed")
            let diff = changes.compactMap { $0["diff"]?.string }.joined(separator: "\n").prefix(4000)
            addProgress(lt, ProgressItem(id: id, kind: .fileChange, text: text, detail: diff.isEmpty ? nil : String(diff), at: Date()))
            setStatusLine(lt, text)
        case "webSearch":
            // The query is usually only known once the search finishes.
            let action = item["action"]
            let q = [item["query"]?.string, action?["query"]?.string, action?["queries"]?.array?.first?.string].compactMap { $0 }.first { !$0.isEmpty }
            let url = action?["url"]?.string
            if let q { updateProgress(lt, id) { $0.text = "Searched the web for “\(q.prefix(60))”" } }
            else if let url, let host = URL(string: url)?.host { updateProgress(lt, id) { $0.text = "Read \(host)" } }
        case "mcpToolCall":
            let text = describeMCP(item)
            let err = item["error"]?["message"]?.string
            updateProgress(lt, id) { p in
                p.text = err == nil ? text : "\(text) — failed"
                if let err { p.detail = [p.detail, err].compactMap { $0 }.joined(separator: "\n") }
            }
        default:
            break
        }
    }

    // MARK: - Finish

    private func finish(_ lt: LiveTurn, status: String, errorMessage: String?) async {
        guard !lt.finishing, live[lt.slug] === lt else { return }
        lt.finishing = true
        let slug = lt.slug
        emit(slug, "turn/completed status=\(status)")

        if lt.pausedForExtraUsage {
            // Stays .awaitingApproval with extraUsageRequest until the user answers.
            store.updateTurn(slug, lt.turnID) { t in
                if let f = lt.finalMessage, lt.commentaryProgress[f.itemID] == nil { t.finalText = AgentOutput.parse(f.text).body }
            }
            if !headless { Sounds.play(.agentNeedsYou) }
            RoutineScheduler.shared.turnFinished(turnID: lt.turnID, slug: slug, succeeded: true, summary: nil)
            return end(lt)
        }

        switch status {
        case "interrupted":
            store.updateTurn(slug, lt.turnID) { t in
                if t.status != .interrupted { t.status = .interrupted }
                t.completedAt = t.completedAt ?? Date()
                t.statusLine = nil
                if t.finalText == nil, let f = lt.finalMessage, lt.commentaryProgress[f.itemID] == nil { t.finalText = AgentOutput.parse(f.text).body }
            }
            RoutineScheduler.shared.turnFinished(turnID: lt.turnID, slug: slug, succeeded: false, summary: nil)
            return end(lt)
        case "failed":
            return fail(lt, friendlyError(errorMessage ?? lt.lastError ?? "The agent hit an error."))
        default:
            break
        }

        guard let turnSnapshot = turn(slug, lt.turnID), let agent = store.agent(slug) else { return end(lt) }
        setStatusLine(lt, "Wrapping up")

        // The answer = the final_answer message, else the last agent message (pulled back out of commentary).
        var raw = lt.finalMessage?.text ?? ""
        if let f = lt.finalMessage, let pid = lt.commentaryProgress[f.itemID] {
            store.updateTurn(slug, lt.turnID) { $0.progress.removeAll { $0.id == pid } }
        }
        if raw.isEmpty, let err = lt.lastError { return fail(lt, err) }
        if raw.isEmpty { raw = "I finished, but didn't write anything up. Ask me what I did and I'll walk you through it." }

        var out = AgentOutput.parse(raw)
        let artifacts = verifiedArtifacts(out.artifacts, agent: agent, since: lt.startedAt)
        var notes: [String] = []
        for cmd in out.routines {
            if let note = RoutineScheduler.shared.apply(cmd, slug: slug, sourceTurn: turnSnapshot) { notes.append(note) }
        }

        // The model forgot <SUMMARY>: ask the server for one (summary + spoken + next steps + title).
        var spoken = out.summary
        if out.summary == nil {
            struct S: Decodable { var summary: String; var spoken: String; var nextSteps: [String]; var title: String }
            if let s: S = try? await AgentAPI.send("v1/agents/summary", body: [
                "prompt": .string(turnSnapshot.displayPrompt), "finalText": .string(out.body), "awanName": .string(agent.name),
                "files": .array(artifacts.map { .string($0.path) }),
            ] as JSON, timeout: 30) {
                out.summary = s.summary
                spoken = s.spoken
                if out.nextActions.isEmpty { out.nextActions = Array(s.nextSteps.prefix(4)) }
                if out.doneTitle == nil { out.doneTitle = s.title }
            } else {
                let first = out.body.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).first?.trimmingCharacters(in: .whitespaces) ?? ""
                out.summary = first.isEmpty ? "\(agent.name) finished." : String(first.prefix(180))
                spoken = out.summary
            }
        }

        let needsComputer = out.computerUseRequest != nil
        let autoApprove = needsComputer && Prefs.shared.alwaysAllowComputerUse
        store.updateTurn(slug, lt.turnID) { t in
            t.finalText = out.body
            t.summary = out.summary
            t.spokenSummary = spoken
            t.nextActions = out.nextActions
            t.doneTitle = out.doneTitle
            t.artifacts = artifacts
            t.computerUseRequest = out.computerUseRequest
            t.statusLine = nil
            t.completedAt = Date()
            t.status = needsComputer && !autoApprove ? .awaitingApproval : .completed
            for note in notes { t.progress.append(ProgressItem(id: UUID().uuidString, kind: .toolCall, text: note, detail: nil, at: Date())) }
        }
        emit(slug, "final parsed: summary=\(out.summary ?? "-") artifacts=\(artifacts.count) next=\(out.nextActions.count) routines=\(out.routines.count) computerUse=\(needsComputer)")

        if turnSnapshot.source == "computerUse", !Prefs.shared.alwaysAllowComputerUse, let tid = lt.threadID {
            ComputerUseServer.shared.setApproval(threadID: tid, approved: false)   // consent is per turn
        }
        RoutineScheduler.shared.turnFinished(turnID: lt.turnID, slug: slug, succeeded: true, summary: out.summary)
        announce(slug: slug, agent: agent, summary: out.summary, spoken: spoken, needsYou: needsComputer && !autoApprove)
        end(lt)
        if autoApprove { approveComputerUse(slug: slug, always: true) }
    }

    private func fail(_ lt: LiveTurn, _ message: String) {
        store.updateTurn(lt.slug, lt.turnID) { t in
            t.status = .failed
            t.errorText = message
            t.statusLine = nil
            t.completedAt = Date()
            if t.finalText == nil, let f = lt.finalMessage, lt.commentaryProgress[f.itemID] == nil { t.finalText = AgentOutput.parse(f.text).body }
        }
        emit(lt.slug, "failed: \(message)")
        RoutineScheduler.shared.turnFinished(turnID: lt.turnID, slug: lt.slug, succeeded: false, summary: nil)
        if !headless {
            Sounds.play(.agentNeedsYou)
            store.updateThread(lt.slug) { $0.unread = !self.isShowing(lt.slug) }
        }
        end(lt)
    }

    /// Releases the Awan and starts its next queued turn.
    private func end(_ lt: LiveTurn) {
        guard live[lt.slug] === lt else { return }
        live[lt.slug] = nil
        store.updateThread(lt.slug) { $0.lastActivityAt = Date() }
        store.saveNow()
        if var q = queue[lt.slug], !q.isEmpty {
            let next = q.removeFirst()
            queue[lt.slug] = q
            if let t = turn(lt.slug, next), t.status == .queued { start(turnID: next, slug: lt.slug) }
        }
        if live.isEmpty { watchdog?.invalidate(); watchdog = nil }
    }

    private func announce(slug: String, agent: AwanAgent, summary: String?, spoken: String?, needsYou: Bool) {
        let showing = isShowing(slug)
        store.updateThread(slug) { $0.unread = !showing }
        guard !headless else { return }
        Sounds.play(needsYou ? .agentNeedsYou : .agentDone)
        let prefs = Prefs.shared
        // Into the voice conversation (so "what did it find?" works later); spoken by the voice model unless Awan
        // should stay quiet. Routine runs land silently.
        let lastTurn = store.thread(slug).turns.last
        let companion = CompanionEngine.shared
        companion.agentUpdate(slug: slug, name: agent.name, summary: summary, spoken: spoken,
                              files: lastTurn?.artifacts.map(\.path) ?? [], needsYou: needsYou,
                              speak: prefs.speakAgentUpdates && !companion.isQuiet && lastTurn?.source != "routine")
        NotchController.shared.present(.agentFinished(slug))
        if prefs.showUpdatesBesideCursor, let summary { CursorOverlayController.shared.showCursorBubble("\(agent.name): \(summary)") }
        // Like the reference, the first listed deliverable opens by itself (routine runs stay quiet in the chat).
        if !needsYou, let last = store.thread(slug).turns.last, last.status == .completed, last.source != "routine",
           let first = last.artifacts.first, first.kind != .folder,
           first.path.hasPrefix("http") || FileManager.default.fileExists(atPath: first.path) {
            NSWorkspace.shared.open(first.url)
        }
        Task { await AppState.shared.refreshPlan() }
    }

    private func isShowing(_ slug: String) -> Bool {
        let s = AppState.shared
        return s.isHomeOpen && s.homePage == .agent(slug)
    }

    // MARK: - Artifacts

    /// Declared artifacts that really exist (URLs pass), then anything new in output/ from this turn. Max 8.
    private func verifiedArtifacts(_ declared: [String], agent: AwanAgent, since: Date) -> [Artifact] {
        let fm = FileManager.default
        let ws = agent.workspace
        var paths: [String] = []
        for entry in declared {
            if entry.hasPrefix("http://") || entry.hasPrefix("https://") { paths.append(entry); continue }
            var p = (entry as NSString).expandingTildeInPath
            if !p.hasPrefix("/") { p = ws.appendingPathComponent(p).path }
            p = URL(fileURLWithPath: p).standardizedFileURL.path
            if fm.fileExists(atPath: p) { paths.append(p) } else { Log.info("artifact listed but missing: \(p)") }
        }
        let output = ws.appendingPathComponent("output", isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: output, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
            let fresh = items.filter { url in
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                let d = max(v?.contentModificationDate ?? .distantPast, v?.creationDate ?? .distantPast)
                return d >= since.addingTimeInterval(-2)
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for url in fresh {
                var p = url.standardizedFileURL.path
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let index = url.appendingPathComponent("index.html")
                    if fm.fileExists(atPath: index.path) { p = index.standardizedFileURL.path }
                }
                if !paths.contains(where: { $0 == p || p.hasPrefix($0 + "/") || $0.hasPrefix(p + "/") }) { paths.append(p) }
            }
        }
        return paths.prefix(8).map { Artifact(path: $0) }
    }

    // MARK: - Interrupt / retry

    func interrupt(_ slug: String) {
        if let q = queue.removeValue(forKey: slug) {
            for id in q { store.updateTurn(slug, id) { $0.status = .interrupted; $0.completedAt = Date(); $0.statusLine = nil } }
        }
        guard let lt = live[slug] else {
            // Nothing running: an approval card left open is simply dismissed.
            if let t = store.thread(slug).turns.last(where: { $0.status == .awaitingApproval }) {
                store.updateTurn(slug, t.id) { $0.status = .interrupted; $0.completedAt = $0.completedAt ?? Date() }
            }
            return
        }
        lt.cancelled = true
        store.updateTurn(slug, lt.turnID) { t in
            t.status = .interrupted
            t.statusLine = nil
            t.completedAt = Date()
        }
        emit(slug, "interrupt requested")
        if let thread = lt.threadID, let turn = lt.codexTurnID {
            Task { _ = try? await server.call("turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)], timeout: 10) }
            // turn/completed(interrupted) releases the Awan; don't wait forever for it.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if let self, self.live[slug] === lt { self.abandonedCodexTurns.insert(turn); self.end(lt) }
            }
        } else {
            end(lt)
        }
    }

    func interruptAll() {
        for slug in Array(live.keys) + Array(queue.keys) { interrupt(slug) }
    }

    /// Re-sends a failed or interrupted turn as a new turn.
    func retry(slug: String, turnID: String) {
        guard let t = turn(slug, turnID) else { return }
        store.send(t.prompt, to: slug, display: t.displayPrompt, source: t.source)
    }

    // MARK: - Computer use

    func approveComputerUse(slug: String, always: Bool) {
        if always { Prefs.shared.alwaysAllowComputerUse = true }
        if let t = store.thread(slug).turns.last(where: { $0.computerUseRequest != nil && $0.status == .awaitingApproval }) {
            store.updateTurn(slug, t.id) { $0.status = .completed }
        }
        if let thread = store.agent(slug)?.threadID { ComputerUseServer.shared.setApproval(threadID: thread, approved: true) }
        store.send("[Computer use approved for this turn] Continue.", to: slug, display: "Go ahead, use my computer", source: "computerUse")
    }

    func declineComputerUse(slug: String) {
        if let t = store.thread(slug).turns.last(where: { $0.computerUseRequest != nil && $0.status == .awaitingApproval }) {
            store.updateTurn(slug, t.id) { $0.status = .completed }
        }
        if let thread = store.agent(slug)?.threadID { ComputerUseServer.shared.setApproval(threadID: thread, approved: false) }
        store.send("The user declined computer use. Finish without it.", to: slug, display: "Not now", source: "computerUse")
    }

    // MARK: - Extra usage (long turns)

    func approveExtraUsage(slug: String) {
        guard let t = store.thread(slug).turns.last(where: { $0.extraUsageRequest != nil && $0.status == .awaitingApproval }) else { return }
        store.updateTurn(slug, t.id) { $0.status = .interrupted; $0.completedAt = $0.completedAt ?? Date() }
        extraUsageApproved.insert(slug)
        store.send("Keep going where you left off and finish the task.", to: slug, display: "Keep going", source: "extraUsage")
    }

    func declineExtraUsage(slug: String) {
        guard let t = store.thread(slug).turns.last(where: { $0.extraUsageRequest != nil && $0.status == .awaitingApproval }) else { return }
        store.updateTurn(slug, t.id) { t in
            t.status = .interrupted
            t.completedAt = t.completedAt ?? Date()
            t.progress.append(ProgressItem(id: UUID().uuidString, kind: .commentary, text: "Stopped here to save your agent messages.", detail: nil, at: Date()))
        }
    }

    private func countTool(_ lt: LiveTurn) {
        lt.toolCalls += 1
        store.updateTurn(lt.slug, lt.turnID) { $0.toolCallCount = lt.toolCalls }
        checkExtraUsage(lt)
    }

    private func ensureWatchdog() {
        guard watchdog == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.live.values.forEach { self?.checkExtraUsage($0) } }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private func checkExtraUsage(_ lt: LiveTurn) {
        guard !lt.pausedForExtraUsage, !lt.extraUsageAllowed, !lt.finishing, !Prefs.shared.autoApproveExtraUsage,
              let thread = lt.threadID, let codexTurn = lt.codexTurnID else { return }
        let long = Date().timeIntervalSince(lt.startedAt) > Self.extraUsageMinutes * 60
        guard long || lt.toolCalls > Self.extraUsageToolCalls else { return }
        lt.pausedForExtraUsage = true
        store.updateTurn(lt.slug, lt.turnID) { t in
            t.status = .awaitingApproval
            t.extraUsageRequest = Self.extraUsageQuestion
            t.statusLine = "Paused — waiting for you"
            t.progress.append(ProgressItem(id: UUID().uuidString, kind: .commentary, text: Self.extraUsageQuestion, detail: nil, at: Date()))
        }
        emit(lt.slug, "paused for extra usage (\(lt.toolCalls) tool calls)")
        Task { _ = try? await server.call("turn/interrupt", ["threadId": .string(thread), "turnId": .string(codexTurn)], timeout: 10) }
    }

    // MARK: - Server → client requests

    private func serverRequest(_ method: String, _ params: JSON, reply: @escaping (Result<JSON, CodexRPCError>) -> Void) {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            reply(.success(["decision": "accept"]))       // approval_policy = never; accept if one slips through
        case "execCommandApproval", "applyPatchApproval":
            reply(.success(["decision": "approved"]))
        case "item/permissions/requestApproval":
            reply(.success(["permissions": params["permissions"]?.object.map { o in .object(o.filter { $0.value != .null }) } ?? [:], "scope": "turn"]))
        case "item/tool/requestUserInput":
            // Surface the question in the thread; the agent carries on with its best judgement.
            var answers: [String: JSON] = [:]
            let questions = params["questions"]?.array ?? []
            for q in questions {
                guard let id = q["id"]?.string else { continue }
                answers[id] = ["answers": ["The user isn't available mid-task. Make the sensible choice and say which in your answer, or ask in your final message."]]
            }
            if let lt = liveTurn(for: params) {
                let text = questions.compactMap { $0["question"]?.string }.joined(separator: "\n")
                addProgress(lt, ProgressItem(id: UUID().uuidString, kind: .commentary, text: text.isEmpty ? "I had a question — I'll ask at the end." : text, detail: nil, at: Date()))
            }
            reply(.success(["answers": .object(answers)]))
        case "mcpServer/elicitation/request":
            if let lt = liveTurn(for: params), let server = params["serverName"]?.string {
                addProgress(lt, ProgressItem(id: UUID().uuidString, kind: .toolCall, text: "\(server) asked for extra input — skipped", detail: params["message"]?.string, at: Date()))
            }
            reply(.success(["action": "decline", "content": .null, "_meta": .null]))
        case "item/tool/call":
            reply(.success(["contentItems": [], "success": false]))
        default:
            reply(.failure(CodexRPCError(code: -32601, message: "Awan doesn't support \(method)")))
        }
    }

    private func runtimeCrashed(_ message: String) {
        loadedThreads = []
        for lt in Array(live.values) where lt.codexTurnID != nil || lt.threadID != nil {
            fail(lt, "The agent runtime stopped unexpectedly. Try again.")
        }
    }

    // MARK: - Helpers

    private func turn(_ slug: String, _ id: String) -> AgentTurn? { store.thread(slug).turns.first { $0.id == id } }

    private func addProgress(_ lt: LiveTurn, _ item: ProgressItem) {
        store.updateTurn(lt.slug, lt.turnID) { t in
            if let i = t.progress.firstIndex(where: { $0.id == item.id }) { t.progress[i] = item } else { t.progress.append(item) }
        }
        emit(lt.slug, "[\(item.kind.rawValue)] \(item.text)")
    }

    private func updateProgress(_ lt: LiveTurn, _ id: String, _ change: (inout ProgressItem) -> Void) {
        store.updateTurn(lt.slug, lt.turnID) { t in
            if let i = t.progress.firstIndex(where: { $0.id == id }) { change(&t.progress[i]) }
        }
    }

    private func promoteToCommentary(_ lt: LiveTurn, _ itemID: String, _ text: String) {
        let pid = "msg-" + itemID
        lt.commentaryProgress[itemID] = pid
        addProgress(lt, ProgressItem(id: pid, kind: .commentary, text: AgentOutput.parse(text).body, detail: nil, at: Date()))
    }

    private func looksLikeFinal(_ text: String) -> Bool {
        text.range(of: "<SUMMARY>", options: .caseInsensitive) != nil || text.range(of: "<DONE_TITLE>", options: .caseInsensitive) != nil
    }

    private func setStatusLine(_ lt: LiveTurn, _ line: String) {
        let l = line.count > 70 ? String(line.prefix(67)) + "…" : line
        store.updateTurn(lt.slug, lt.turnID) { t in
            guard t.status.isActive, t.status != .awaitingApproval else { return }
            if t.status == .starting { t.status = .running }
            t.statusLine = l
        }
    }

    private func emit(_ slug: String, _ line: String) {
        trace?("[\(slug)] \(line)")
    }

    private func describeCommand(_ item: JSON) -> (String, String) {
        let pretty = Self.unwrapShell(item["command"]?.string ?? "")
        let actions = (item["commandActions"]?.array ?? []).filter { $0["type"]?.string != "unknown" }
        // A command that writes a file says so, whatever else is chained with it.
        if let written = Self.writtenFile(in: pretty) { return ("Writing \(written)", pretty) }
        if actions.count == 1 || (actions.count > 1 && Set(actions.compactMap { $0["type"]?.string }).count == 1), let a = actions.first {
            let name = a["name"]?.string ?? (a["path"]?.string).map { ($0 as NSString).lastPathComponent }
            switch a["type"]?.string {
            case "read": return (actions.count > 1 ? "Reading \(actions.count) files" : "Reading \(name ?? "a file")", pretty)
            case "listFiles": return ("Looking through \(name ?? "files")", pretty)
            case "search": return (a["query"]?.string.map { "Searching for “\($0.prefix(40))”" } ?? "Searching files", pretty)
            default: break
            }
        }
        return (Self.commandHeadline(pretty), pretty)
    }

    /// `/bin/zsh -lc "cat x"` → `cat x`
    nonisolated static func unwrapShell(_ command: String) -> String {
        guard let r = command.range(of: #"^\S*(ba|z)?sh\s+-l?c\s+"#, options: .regularExpression) else { return command }
        var rest = String(command[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let q = rest.first, q == "'" || q == "\"" {
            rest.removeFirst()
            if rest.last == q { rest.removeLast() }
        }
        return rest.replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// `cat > output/a.html <<EOF`, `tee x`, `echo … > x` → "a.html"
    nonisolated static func writtenFile(in command: String) -> String? {
        // apply_patch run through the shell: `*** Add File: output/x.html` / `*** Update File: …`
        if let r = command.range(of: #"\*\*\* (Add|Update) File: ([^\n]+)"#, options: .regularExpression) {
            let path = String(command[r]).replacingOccurrences(of: #"^\*\*\* (Add|Update) File: "#, with: "", options: .regularExpression)
            return (path.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        }
        let firstLines = stripHeredocs(command).joined(separator: "\n")
        let patterns = [#"(?:cat|printf|echo)[^|&;>]*>\s*([^\s<>|&;'"]+)"#, #"\btee\s+(?:-a\s+)?([^\s<>|&;'"]+)"#]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p), let m = re.firstMatch(in: firstLines, range: NSRange(firstLines.startIndex..., in: firstLines)),
               let r = Range(m.range(at: 1), in: firstLines) {
                let path = String(firstLines[r])
                if path.hasPrefix("/dev/") { continue }
                return (path as NSString).lastPathComponent
            }
        }
        return nil
    }

    /// Command lines only — heredoc bodies (`<<'EOF' … EOF`) removed.
    nonisolated static func stripHeredocs(_ command: String) -> [String] {
        var out: [String] = []
        var delimiter: String?
        for line in command.components(separatedBy: .newlines) {
            if let d = delimiter {
                if line.trimmingCharacters(in: .whitespaces) == d { delimiter = nil }
                continue
            }
            out.append(line)
            if let r = line.range(of: #"<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?"#, options: .regularExpression) {
                delimiter = String(line[r]).replacingOccurrences(of: #"^<<-?\s*['"]?"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
        }
        return out
    }

    nonisolated static func commandHeadline(_ command: String) -> String {
        let segments = stripHeredocs(command).joined(separator: "\n").components(separatedBy: CharacterSet(charactersIn: "\n;|&")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let words = segments.compactMap { $0.split(separator: " ").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'()")) } }
        func has(_ w: String...) -> Bool { words.contains { w.contains(($0 as NSString).lastPathComponent) } }
        if has("curl", "wget") {
            if let host = command.range(of: #"https?://[^/\s'"]+"#, options: .regularExpression).map({ String(command[$0]) }).flatMap({ URL(string: $0)?.host }) {
                return "Fetching \(host)"
            }
            return "Fetching from the web"
        }
        if has("python3", "python", "node", "ruby", "swift", "osascript") { return "Running a script" }
        if has("npm", "npx", "pnpm", "yarn", "bun") { return "Running the build tools" }
        if has("git") { return "Working with git" }
        if has("open") { return "Opening it on your Mac" }
        if has("rg", "grep", "find") { return "Searching files" }
        if has("ls", "tree") { return "Looking through files" }
        if has("mkdir", "cp", "mv", "rm") { return "Organising files" }
        if has("cat", "head", "tail", "sed") { return "Reading files" }
        return "Running \(words.first.map { ($0 as NSString).lastPathComponent } ?? "a command")"
    }

    private func describeMCP(_ item: JSON) -> String {
        let server = item["server"]?.string ?? "tool"
        let tool = (item["tool"]?.string ?? "").replacingOccurrences(of: "_", with: " ")
        if server == "computer-use" { return "Using your Mac · \(tool)" }
        return "\(server.capitalized) · \(tool)"
    }

    private func describeFileChange(_ changes: [JSON], failed: Bool) -> String {
        let names = changes.compactMap { $0["path"]?.string }.map { ($0 as NSString).lastPathComponent }
        let kinds = Set(changes.compactMap { $0["kind"]?["type"]?.string })
        let verb = kinds == ["add"] ? "Created" : kinds == ["delete"] ? "Deleted" : "Edited"
        let list = names.count <= 2 ? names.joined(separator: " and ") : "\(names[0]) and \(names.count - 1) more"
        return failed ? "Couldn't edit \(list)" : "\(verb) \(list.isEmpty ? "files" : list)"
    }

    private func compactJSON(_ v: JSON?) -> String? {
        guard let v, v != .null, let d = try? JSONEncoder().encode(v), let s = String(data: d, encoding: .utf8) else { return nil }
        return s.count > 600 ? String(s.prefix(600)) + "…" : s
    }

    private func friendlyError(_ raw: String) -> String {
        let l = raw.lowercased()
        if l.contains("402") || l.contains("quota") || l.contains("limit reached") {
            if !headless { AppState.shared.presentPaywall(.limitHit) }
            return "You're out of agent messages this month. Upgrade Awan to keep going."
        }
        if l.contains("401") || l.contains("unauthorized") { return "You're signed out. Sign in to Awan and try again." }
        if l.contains("503") || l.contains("no model provider") { return "Awan's server has no model configured right now. Try again in a bit." }
        if l.contains("stream disconnected") || l.contains("error sending request") || l.contains("connection") {
            return "Lost the connection to Awan's server mid-task. Try again."
        }
        return raw.count > 300 ? String(raw.prefix(300)) + "…" : raw
    }
}

extension CompanionEngine {
    /// Whether spoken agent updates should wait (calls, Focus, the user talking to Awan).
    var agentUpdatesHeldBack: Bool { isQuiet || voiceState != .idle }
}
