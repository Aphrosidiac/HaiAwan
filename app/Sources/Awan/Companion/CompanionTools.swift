import AppKit
import Foundation

/// The voice model's tools, run on the Mac. Each returns a short JSON result for the model (what happened, in
/// words it can say) and, for screenshots, extra conversation items that go in after the tool results.
@MainActor
enum CompanionTools {
    /// Tool names this build implements (the server offers only these).
    static let capabilities = [
        "ask_deeper", "look_at_screen", "start_awan_task", "message_awan", "stop_awan", "awans_status", "awan_memory",
        "answer_awan_request", "open_file", "open_home", "web_search", "remember", "type_text", "copy_to_clipboard",
        "open_link", "read_file", "list_files", "account_status", "decide_suggestion",
    ]

    struct Outcome {
        var result: String
        var attachments: [ConversationItem] = []
    }

    static func statusLabel(_ call: ToolCallItem) -> String {
        let a = call.args
        func awanName() -> String? { a["awan_slug"]?.string.flatMap { AgentStore.shared.agent($0)?.name } }
        switch call.name {
        case "ask_deeper": return "Looking closer…"
        case "look_at_screen": return "Looking at your screen…"
        case "start_awan_task": return a["new_awan"]?["name"]?.string.map { "Starting \($0)…" } ?? awanName().map { "Starting \($0)…" } ?? "Starting an Awan…"
        case "message_awan": return awanName().map { "Sending to \($0)…" } ?? "Sending to your Awan…"
        case "stop_awan": return awanName().map { "Stopping \($0)…" } ?? "Stopping…"
        case "awans_status": return "Checking your Awans…"
        case "awan_memory": return awanName().map { "Checking \($0)'s notes…" } ?? "Checking notes…"
        case "answer_awan_request": return "Answering…"
        case "open_file": return "Opening…"
        case "open_home": return "Opening Home…"
        case "web_search": return "Searching the web…"
        case "remember": return "Saving to memory…"
        case "type_text": return "Typing it in…"
        case "copy_to_clipboard": return "Copying…"
        case "open_link": return "Opening link…"
        case "read_file": return "Reading file…"
        case "list_files": return "Listing files…"
        case "account_status": return "Checking…"
        case "decide_suggestion": return "On it…"
        default: return "Working…"
        }
    }

    /// Self-tests: tools that change anything (start/message/stop Awans, open, type, copy, remember, decide) report
    /// what they would have done instead of doing it.
    static var dryRun = false
    static let sideEffects: Set<String> = ["start_awan_task", "message_awan", "stop_awan", "answer_awan_request", "open_file", "open_home",
                                           "remember", "type_text", "copy_to_clipboard", "open_link", "decide_suggestion"]
    /// Calls made in dry-run mode (self-tests read them).
    static var dryRunLog: [ToolCallItem] = []

    static func run(_ call: ToolCallItem, turn: CompanionTurn, engine: CompanionEngine) async -> Outcome {
        let a = call.args
        if dryRun, sideEffects.contains(call.name) {
            dryRunLog.append(call)
            let who = a["new_awan"]?["name"]?.string ?? a["awan_slug"]?.string.flatMap { AgentStore.shared.agent($0)?.name } ?? a["awan_slug"]?.string ?? ""
            return Outcome(result: result(["status": "ok", "dry_run": true, "awan": .string(who), "note": "done (say so briefly)."]))
        }
        switch call.name {
        case "ask_deeper": return Outcome(result: await askDeeper(question: a["question"]?.string ?? turn.display, focus: a["focus"]?.string, turn: turn, engine: engine))
        case "look_at_screen": return await lookAtScreen(turn: turn)
        case "start_awan_task": return Outcome(result: startTask(a, turn: turn, engine: engine))
        case "message_awan": return Outcome(result: messageAwan(a, engine: engine))
        case "stop_awan": return Outcome(result: stopAwan(a))
        case "awans_status": return Outcome(result: awansStatus())
        case "awan_memory": return Outcome(result: awanMemory(a))
        case "answer_awan_request": return Outcome(result: answerRequest(a))
        case "open_file": return Outcome(result: openFile(a))
        case "open_home": return Outcome(result: openHome(a))
        case "web_search": return Outcome(result: await webSearch(a["query"]?.string ?? ""))
        case "remember": return Outcome(result: remember(a["fact"]?.string ?? ""))
        case "type_text": return Outcome(result: await typeText(a["text"]?.string ?? "", turn: turn))
        case "copy_to_clipboard": return Outcome(result: copy(a["text"]?.string ?? ""))
        case "open_link": return Outcome(result: openLink(a["url"]?.string ?? ""))
        case "read_file": return Outcome(result: readFile(a["path"]?.string ?? ""))
        case "list_files": return Outcome(result: listFiles(a["path"]?.string ?? ""))
        case "account_status": return Outcome(result: accountStatus())
        case "decide_suggestion": return Outcome(result: await decideSuggestion(a))
        default: return Outcome(result: result(["status": "error", "message": "unknown tool \(call.name)"]))
        }
    }

    static func result(_ o: [String: JSON]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: enc.encode(JSON.object(o)), encoding: .utf8)) ?? "{}"
    }

    // MARK: - Deeper pass

    private struct DeeperResponse: Decodable {
        var text: String
        var spokenText: String
        var ms: Int?
    }

    /// Frontier vision pass: full screenshots, the open document, the drawing and the recent conversation. Acts on
    /// its tags here (point, draw, arm a walkthrough target, type, show pictures, start an Awan) and reports back.
    static func askDeeper(question: String, focus: String?, turn: CompanionTurn, engine: CompanionEngine) async -> String {
        if turn.frames.isEmpty { turn.frames = await CompanionEngine.captureFrames() }
        if turn.frames.isEmpty, turn.document == nil, turn.attachedImages.isEmpty {
            return result(["status": "error", "message": "couldn't capture the screen (awan may be missing Screen Recording permission). answer without the screen or ask the user to allow it in System Settings → Privacy & Security."])
        }
        var body: [String: JSON] = [
            "question": .string(question),
            "images": .array((turn.frames + turn.attachedImages).map { ["data": .string($0.jpeg.base64EncodedString()), "label": .string($0.label), "mime": "image/jpeg"] }),
            "conversation": .array(engine.conversation.recentExchange(limit: 12).map { ["role": .string($0.role == "awan" ? "assistant" : "user"), "text": .string($0.text)] }),
        ]
        if let focus, !focus.isEmpty { body["focus"] = .string(focus) }
        if let doc = turn.document { body["document"] = .object(doc.requestBody.mapValues { .string($0) }) }
        if let d = turn.drawing { body["drawing"] = .string(d) }
        if let slugs = SkillsStore.shared.companionSlugs { body["activeSkills"] = .array(slugs.map { .string($0) }) }
        if let app = CompanionNotes.app(turn.app) { body["appContext"] = .string(app) }
        if turn.guidedGoal != nil { body["guided"] = true }
        let r: DeeperResponse
        do {
            r = try await APIClient.shared.send("v1/companion/deeper", method: "POST", body: JSON.object(body))
        } catch {
            Log.error("deeper pass: \(error.localizedDescription)")
            return result(["status": "error", "message": "the deeper look failed (\(error.localizedDescription)). say so in one short line and offer to try again."])
        }
        Log.info("deeper pass answered in \(r.ms ?? 0) ms: \(r.text.prefix(300))")
        return await applyDeeper(r.text, question: question, turn: turn, engine: engine)
    }

    /// Acts on a deeper-pass reply and describes what happened.
    static func applyDeeper(_ raw: String, question: String, turn: CompanionTurn, engine: CompanionEngine) async -> String {
        let reply = CompanionTagParser.parse(raw)
        var out: [String: JSON] = ["status": "ok", "answer": .string(reply.spokenText)]
        let geometries = turn.geometries
        let total = max(1, reply.spokenText.count)
        var shown = 0
        var pointed = false
        var target: CompanionTag?
        turn.deferredSentenceBase = engine.player.sentences.count
        for tag in reply.tags {
            if tag.visual.isTarget {
                if engine.guidedStepsLeft() <= 0 || target != nil { continue }
                target = tag
            }
            guard let resolved = CompanionVisualMapper.resolve(tag, in: geometries) else { continue }
            if tag.visual.isPoint { pointed = true }
            shown += 1
            let fraction = min(0.999, Double(tag.anchorOffset) / Double(total))
            if turn.voice {
                turn.deferredVisuals.append((fraction, resolved))
            } else {
                engine.pendingVisuals.append((-1, resolved))
            }
        }
        if !turn.voice { engine.fireVisuals(upTo: Int.max) }
        out["visual_guidance_shown"] = .bool(shown > 0)
        out["cursor_animated"] = .bool(pointed)
        if let target {
            engine.armGuided(goal: turn.guidedGoal ?? question, label: target.visual.label)
            out["target_armed"] = true
            out["note"] = "a click target is armed: tell the user the one step to do now, briefly. awan waits for their click and then continues the walkthrough by itself."
        } else if turn.guidedGoal != nil || engine.guided != nil {
            engine.endGuidedIfDone()
        }
        if let q = reply.imagesQuery {
            if !CompanionEngine.headless { ImageAnswerCard.shared.show(query: q) }
            out["widgets_shown"] = true
        }
        if let request = reply.typeRequest {
            var point: CGPoint?
            if let x = request.x, let y = request.y {
                let tag = CompanionTag(visual: .point(x: x, y: y, label: request.label), screen: request.screen, spokenOffset: 0)
                if case let .point(p)? = CompanionVisualMapper.resolve(tag, in: geometries) { point = p.point }
            }
            // Wait for the outcome so the voice model reports what really happened.
            if dryRun {
                dryRunLog.append(ToolCallItem(id: "deeper-type", name: "deeper:[TYPE]", arguments: request.text))
                out["text_typed"] = "(dry run)"
            } else {
                let r = await CompanionTyper.type(request, into: turn.app, at: point)
                Log.info("deeper pass typed: \(r)")
                switch r {
                case .typed: out["text_typed"] = true
                case .clipboard, .refusedAddressBar:
                    if case .refusedAddressBar = r { TextInserter.copy(request.text) }
                    out["text_typed"] = false; out["copied_to_clipboard"] = true
                case .refusedSecure: out["text_typed"] = false; out["delivery_refused"] = "the focused field is a password field"
                case let .refusedApp(name): out["text_typed"] = false; out["delivery_refused"] = .string("awan doesn't type into \(name)")
                case .nothingToType: out["text_typed"] = false
                }
            }
            out["note"] = "never read the drafted text aloud. report only what text_typed / copied_to_clipboard say happened, and keep any instruction from the answer (like where to click first)."
        }
        if let task = reply.agentTask {
            if dryRun {
                dryRunLog.append(ToolCallItem(id: "deeper-agent", name: "deeper:[AGENT]", arguments: task))
                out["routed_to_agent"] = "(dry run)"
            } else if let name = engine.sendToAwan(Handoff.prompt(original: turn.display, task: task, conversation: engine.conversation.recentExchange()), slug: nil, display: turn.display, announce: false) {
                out["routed_to_agent"] = .string(name)
                out["note"] = "the deeper pass judged this real work, so awan already started it in \(name). say the answer and, in one short sentence, that \(name) is on it. do NOT call start_awan_task for this same work."
            }
        }
        return result(out)
    }

    /// A walkthrough step after the user clicked the target: the deeper pass plans the next step from a fresh
    /// screenshot, and the returned note tells the voice model to say it.
    static func guidedNote(prompt: String, step: Int, turn: CompanionTurn, engine: CompanionEngine) async -> String {
        let r = await askDeeper(question: prompt, focus: nil, turn: turn, engine: engine)
        let answer = (try? JSONDecoder().decode(JSON.self, from: Data(r.utf8)))?["answer"]?.string ?? ""
        let armed = (try? JSONDecoder().decode(JSON.self, from: Data(r.utf8)))?["target_armed"]?.bool ?? false
        if answer.isEmpty { return "[walkthrough] step \(step) is done, but the next step couldn't be worked out. tell the user in one short line and suggest asking again." }
        return armed
            ? "[walkthrough] the user did step \(step). looking at the new screen, the next step is: \"\(answer)\". say that next step now in one short sentence, in your voice. the target is already on screen."
            : "[walkthrough] the user did step \(step), and that finishes it: \"\(answer)\". tell them in one short sentence."
    }

    // MARK: - Screen

    static func lookAtScreen(turn: CompanionTurn) async -> Outcome {
        let frames = await CompanionEngine.captureFrames()
        guard !frames.isEmpty else {
            return Outcome(result: result(["status": "error", "message": "screen capture failed (awan may be missing Screen Recording permission). answer without the screen or ask the user to allow it."]))
        }
        turn.frames = frames
        let convo = CompanionConversation.shared
        convo.lastScreenFingerprints = frames.map { CompanionNotes.fingerprint($0.image) }
        convo.lastScreenAt = Date()
        return Outcome(result: result(["status": "ok", "message": "fresh screenshots of \(frames.count) screen\(frames.count == 1 ? "" : "s") are attached right after this. answer from them."]),
                       attachments: [ConversationItem(role: .user, kind: .note, text: "[screen] the fresh screenshots you asked for.", images: frames)])
    }

    // MARK: - Awans

    static func startTask(_ a: [String: JSON], turn: CompanionTurn, engine: CompanionEngine) -> String {
        guard let task = a["task"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
            return result(["status": "error", "message": "missing task"])
        }
        let store = AgentStore.shared
        var slug = a["awan_slug"]?.string
        var founded = false
        var revived = false
        if let s = slug, let agent = store.agent(s) {
            if agent.archived { store.update(s) { $0.archived = false }; revived = true }
        } else if let spec = a["new_awan"], let name = spec["name"]?.string, !name.isEmpty {
            let role = spec["role"]?.string ?? "Agent"
            let desc = spec["description"]?.string ?? task
            let dto = AwanSpecDTO(
                slug: Handoff.slug(name), name: name, roleText: role, oneLiner: desc,
                introMessages: ["Hey, I'm \(name), your \(role.lowercased()).", "\(desc) That's what I'm here for.", "Text me below whenever you're ready, or hold control and option to just talk to me."],
                suggestedAsks: [], baseHue: Double.random(in: 0 ..< 1), routine: nil, suggestion: nil
            )
            slug = store.create(from: dto).slug
            founded = true
        } else if slug != nil {
            return result(["status": "error", "message": "unknown awan_slug. use one from the [awans] note, or found a new one with new_awan."])
        } else {
            slug = AgentRouter.bestSlug(for: task, among: store.visibleAgents)
        }
        guard let slug, let agent = store.agent(slug) else {
            return result(["status": "error", "message": "no awan to take it. found one with new_awan {name, role, description}."])
        }
        var prompt = Handoff.prompt(original: turn.display.isEmpty ? task : turn.display, task: task, conversation: engine.conversation.recentExchange())
        if !turn.attachments.isEmpty {
            let paths = dryRun ? turn.attachments.map(\.path) : NotchDropController.copy(turn.attachments, into: agent)
            if !paths.isEmpty { prompt += "\n\nFiles the user attached (copied into your tmp folder):\n" + paths.map { "- \($0)" }.joined(separator: "\n") }
            turn.attachments = []
        }
        guard store.send(prompt, to: slug, display: turn.display.isEmpty ? task : turn.display, source: "voice") != nil else {
            return result(["status": "error", "message": "couldn't start the awan. nothing was started; tell the user plainly instead of claiming it's underway."])
        }
        Sounds.play(.agentLaunch)
        engine.conversation.record("event", "\(agent.name) started: \(task.prefix(200))")
        var note = founded
            ? "awan founded a new awan named \(agent.name) for this and it's on it now. mention it by name in one short sentence (it lives in the user's Home and remembers)."
            : "\(agent.name) is on it now. say so by name in one short sentence."
        if revived { note += " it had been archived and was brought back for this." }
        return result(["status": "started", "awan": .string(agent.name), "awan_slug": .string(slug), "founded": .bool(founded), "note": .string(note)])
    }

    static func messageAwan(_ a: [String: JSON], engine: CompanionEngine) -> String {
        guard let slug = a["awan_slug"]?.string, let agent = AgentStore.shared.agent(slug) else {
            return result(["status": "error", "message": "unknown awan_slug. check the [awans] note."])
        }
        guard let message = a["message"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return result(["status": "error", "message": "missing message"])
        }
        let busy = AgentStore.shared.thread(slug).activeTurn != nil
        guard AgentStore.shared.send(message, to: slug, display: message, source: "voice") != nil else {
            return result(["status": "error", "message": "couldn't send it. tell the user plainly."])
        }
        Sounds.play(.agentLaunch)
        engine.conversation.record("event", "(sent to \(agent.name): \(message.prefix(160)))")
        return result(["status": "sent", "awan": .string(agent.name), "queued_behind_current_task": .bool(busy)])
    }

    static func stopAwan(_ a: [String: JSON]) -> String {
        guard let slug = a["awan_slug"]?.string, let agent = AgentStore.shared.agent(slug) else { return result(["status": "error", "message": "unknown awan_slug"]) }
        guard AgentStore.shared.thread(slug).activeTurn != nil else { return result(["status": "idle", "message": "\(agent.name) wasn't doing anything."]) }
        AgentStore.shared.interrupt(slug)
        return result(["status": "stopped", "awan": .string(agent.name)])
    }

    static func awansStatus(now: Date = Date()) -> String {
        let store = AgentStore.shared
        let agents = store.visibleAgents
        guard !agents.isEmpty else { return result(["status": "ok", "awans": [], "message": "the user has no awans yet."]) }
        let list: [JSON] = agents.prefix(12).map { a in
            let t = store.thread(a.slug)
            var o: [String: JSON] = ["name": .string(a.name), "awan_slug": .string(a.slug), "role": .string(a.roleText)]
            if let turn = t.activeTurn ?? t.turns.last {
                o["state"] = .string(turn.status == .awaitingApproval ? "waiting for the user" : turn.status.rawValue)
                o["task"] = .string(String(turn.displayPrompt.prefix(200)))
                o["when"] = .string(CompanionNotes.ago(turn.completedAt ?? turn.startedAt, now))
                if let s = turn.summary { o["summary"] = .string(s) }
                if let e = turn.errorText { o["error"] = .string(String(e.prefix(200))) }
                if let q = turn.computerUseRequest ?? turn.extraUsageRequest, turn.status == .awaitingApproval { o["waiting_on"] = .string(q) }
                if let p = turn.progress.last(where: { $0.kind == .commentary }), turn.status.isActive { o["last_update"] = .string(p.text) }
                if !turn.artifacts.isEmpty { o["files"] = .array(turn.artifacts.prefix(4).map { .string($0.path) }) }
            } else {
                o["state"] = "hasn't worked yet"
            }
            return .object(o)
        }
        return result(["status": "ok", "awans": .array(list), "note": "to open a file, call open_file with its path."])
    }

    static func awanMemory(_ a: [String: JSON]) -> String {
        guard let slug = a["awan_slug"]?.string, let agent = AgentStore.shared.agent(slug) else { return result(["status": "error", "message": "unknown awan_slug. use one from the [awans] note."]) }
        let notes = (try? String(contentsOf: agent.workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8)) ?? "(no notes file yet — this awan hasn't worked yet)"
        let turns = AgentStore.shared.thread(slug).turns.suffix(6)
        let chat: [JSON] = turns.flatMap { t -> [JSON] in
            var items: [JSON] = [["role": "user", "text": .string(String(t.displayPrompt.prefix(400)))]]
            if let reply = t.finalText ?? t.summary { items.append(["role": .string(agent.name), "text": .string(String(reply.prefix(1500)))]) }
            else if t.status.isActive, let p = t.progress.last(where: { $0.kind == .commentary }) { items.append(["role": "progress", "text": .string(p.text)]) }
            return items
        }
        return result([
            "status": "ok", "awan": .string(agent.name),
            "notes": .string(notes.count > 6000 ? String(notes.prefix(6000)) + "…(truncated)" : notes),
            "recent_chat": .array(chat),
            "files": .array(AgentStore.shared.thread(slug).artifacts.prefix(6).map { .string($0.path) }),
        ])
    }

    static func answerRequest(_ a: [String: JSON]) -> String {
        let store = AgentStore.shared
        let waiting = store.visibleAgents.filter { store.thread($0.slug).activeTurn?.status == .awaitingApproval }
        guard !waiting.isEmpty else { return result(["status": "none", "message": "no awan is waiting on an answer right now. tell the user so."]) }
        let agent: AwanAgent
        if let slug = a["awan_slug"]?.string, let found = waiting.first(where: { $0.slug == slug }) { agent = found }
        else if waiting.count == 1 { agent = waiting[0] }
        else { return result(["status": "ambiguous", "message": "several awans are waiting: \(waiting.map { "\($0.name) (\($0.slug))" }.joined(separator: ", ")). ask which one."]) }
        guard let turn = store.thread(agent.slug).activeTurn else { return result(["status": "none"]) }
        let decision = a["decision"]?.string ?? "approve"
        let runner = store.runner
        if turn.extraUsageRequest != nil {
            if decision == "decline" { runner.declineExtraUsage(slug: agent.slug); return result(["status": "declined", "message": "\(agent.name) stays paused. confirm in one short line."]) }
            runner.approveExtraUsage(slug: agent.slug)
            return result(["status": "approved", "message": "\(agent.name) is carrying on to the end. confirm in one short line."])
        }
        switch decision {
        case "decline":
            runner.declineComputerUse(slug: agent.slug)
            return result(["status": "declined", "message": "\(agent.name) will finish without controlling the mac. confirm in one short line."])
        case "always":
            runner.approveComputerUse(slug: agent.slug, always: true)
            return result(["status": "allowed", "message": "\(agent.name) may use the mac now and every later time (changeable in Settings → Agents). confirm in one short line."])
        default:
            runner.approveComputerUse(slug: agent.slug, always: false)
            return result(["status": "allowed", "message": "\(agent.name) may use the mac for this task. confirm in one short line."])
        }
    }

    static func openFile(_ a: [String: JSON]) -> String {
        var target = a["path_or_url"]?.string
        if target == nil, let slug = a["awan_slug"]?.string { target = AgentStore.shared.thread(slug).artifacts.first?.path }
        if target == nil { target = AgentStore.shared.visibleAgents.compactMap { AgentStore.shared.thread($0.slug).artifacts.first }.max { $0.createdAt < $1.createdAt }?.path }
        guard let t = target else { return result(["status": "error", "message": "no file matched. call awans_status to see what the awans made."]) }
        if t.hasPrefix("http://") || t.hasPrefix("https://"), let url = URL(string: t) {
            NSWorkspace.shared.open(url)
            return result(["status": "opened", "what": .string(url.host ?? t)])
        }
        let path = (t as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return result(["status": "error", "message": "that file isn't there any more."]) }
        let url = URL(fileURLWithPath: path)
        if a["action"]?.string == "reveal" { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
        return result(["status": a["action"]?.string == "reveal" ? "revealed" : "opened", "what": .string(url.lastPathComponent)])
    }

    static func openHome(_ a: [String: JSON]) -> String {
        let state = AppState.shared
        if a["action"]?.string == "close" { state.closeHome(); return result(["status": "closed"]) }
        if let slug = a["awan_slug"]?.string, AgentStore.shared.agent(slug) != nil { state.openHome(.agent(slug)) } else { state.openHome() }
        return result(["status": "opened"])
    }

    // MARK: - Lookups

    private struct SearchResponse: Decodable { var answer: String }

    static func webSearch(_ query: String) async -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return result(["status": "error", "message": "missing query"]) }
        do {
            let r: SearchResponse = try await APIClient.shared.send("v1/companion/search", method: "POST", body: ["query": .string(q), "locale": .string(Locale.current.identifier), "timeZone": .string(TimeZone.current.identifier)] as JSON)
            return result(["status": "ok", "answer": .string(r.answer), "note": "lead with the exact figure or fact asked for, one sentence of context, then stop. no opener about searching."])
        } catch {
            return result(["status": "error", "message": "the web lookup failed. say so in one short line."])
        }
    }

    static func accountStatus() -> String {
        let s = AppState.shared
        let p = s.plan
        var o: [String: JSON] = [
            "plan": .string(p.tier),
            "voice": .string(Prefs.shared.voiceID),
            "shortcuts": "talk: hold control + option · type: double-tap control · dictate: hold fn + control",
            "permissions": .object(Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0.rawValue, JSON.string("\(PermissionProbe.status($0))")) })),
            "signed_in": .bool(s.user != nil),
        ]
        func line(_ e: UsageBucket) -> JSON { .string("\(e.used) used of \(e.cap.map(String.init) ?? "unlimited")") }
        o["talks_this_month"] = line(p.usage.messages)
        o["agent_messages_this_month"] = line(p.usage.agents)
        if let r = p.resetsAt { o["resets_on"] = .string(DateFormatter.localizedString(from: r, dateStyle: .medium, timeStyle: .none)) }
        return result(o)
    }

    // MARK: - Memory

    /// Appends a dated line to Memory/PROFILE.md (read by the companion's deeper pass and every Awan turn).
    static func remember(_ fact: String) -> String {
        let f = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty else { return result(["status": "error", "message": "missing fact"]) }
        if f.range(of: #"(?i)password|passcode|\bpin\b|card number|cvv|api key|secret|token"#, options: .regularExpression) != nil {
            return result(["status": "refused", "message": "that looks like a secret, and awan never stores secrets. tell the user."])
        }
        let url = Paths.memory.appendingPathComponent("PROFILE.md")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? "# About the user\n\nWhat Awan has learned from conversations. The user can edit or delete anything here.\n"
        let line = String(f.prefix(300)).replacingOccurrences(of: "\n", with: " ")
        if text.localizedCaseInsensitiveContains(line) { return result(["status": "ok", "message": "already remembered."]) }
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        if !text.hasSuffix("\n") { text += "\n" }
        text += "- \(line) (\(day))\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { return result(["status": "error", "message": "couldn't save it."]) }
        Log.info("companion remembered: \(line)")
        return result(["status": "saved"])
    }

    // MARK: - Typing, clipboard, links

    static func typeText(_ text: String, turn: CompanionTurn) async -> String {
        guard !text.isEmpty else { return result(["status": "error", "message": "missing text"]) }
        let r = await CompanionTyper.type(CompanionTypeRequest(text: text), into: turn.app, at: nil)
        Log.info("companion typed: \(r)")
        switch r {
        case .typed: return result(["status": "typed", "note": "done; don't read the text aloud."])
        case .nothingToType: return result(["status": "error", "message": "nothing to type"])
        case .refusedSecure: return result(["status": "refused", "message": "the focused field is a password field. text is never typed there; tell the user to type it themselves."])
        case let .refusedApp(name): return result(["status": "refused", "message": "awan doesn't type into \(name). tell the user."])
        case .refusedAddressBar:
            TextInserter.copy(text)
            return result(["status": "clipboard", "copied_to_clipboard": true, "message": "the focus is in the browser's address bar, so the text went on the clipboard instead."])
        case .clipboard:
            return result(["status": "clipboard", "copied_to_clipboard": true, "message": "couldn't type straight into the field, so it's on the clipboard: tell the user to press command V."])
        }
    }

    static func copy(_ text: String) -> String {
        guard !text.isEmpty else { return result(["status": "error", "message": "missing text"]) }
        TextInserter.copy(text)
        return result(["status": "copied", "copied_to_clipboard": true, "note": "tell the user it's on their clipboard; never read it aloud."])
    }

    static func openLink(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "maps", "facetime", "tel", "sms", "spotify", "music"].contains(scheme) else {
            return result(["status": "error", "message": "that isn't a link awan opens."])
        }
        NSWorkspace.shared.open(url)
        return result(["status": "opened", "what": .string(url.host ?? scheme)])
    }

    // MARK: - Files (read-only)

    /// Paths the voice model never reads: keys, keychains, browser/app secrets, shell history.
    static func isSensitive(_ path: String) -> Bool {
        let p = path.lowercased()
        let name = (p as NSString).lastPathComponent
        if ["/.ssh/", "/.gnupg/", "/keychains/", "/.aws/", "/.config/gh/", "/cookies", "/login data", "/codexhome/auth.json", "/.netrc"].contains(where: { p.contains($0) }) { return true }
        if name.hasPrefix(".env") || name.hasSuffix(".pem") || name.hasSuffix(".key") || name.hasSuffix(".p12") || name.hasPrefix("id_") || name == "auth.json" || name.hasSuffix("_history") || name == ".npmrc" || name == ".pypirc" { return true }
        return false
    }

    static func resolvePath(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let expanded = (t as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return (expanded as NSString).standardizingPath
    }

    static func readFile(_ raw: String) -> String {
        guard let path = resolvePath(raw) else { return result(["status": "error", "message": "give an absolute path or one starting with ~/"]) }
        if isSensitive(path) { return result(["status": "refused", "message": "that file holds secrets or keys, so awan doesn't read it."]) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return result(["status": "error", "message": "no file at that path."]) }
        if isDir.boolValue { return listFiles(raw) }
        let url = URL(fileURLWithPath: path)
        let text: String
        if let (t, _) = ActiveDocumentReader.extractText(url: url) { text = t }
        else if let t = try? String(contentsOf: url, encoding: .utf8) { text = t }
        else { return result(["status": "error", "message": "that file isn't text awan can read."]) }
        let limit = 20_000
        return result(["status": "ok", "path": .string(path), "chars": .number(Double(text.count)),
                       "text": .string(text.count > limit ? String(text.prefix(limit)) + "\n…(truncated)" : text)])
    }

    static func listFiles(_ raw: String) -> String {
        guard let path = resolvePath(raw) else { return result(["status": "error", "message": "give an absolute folder path or one starting with ~/"]) }
        if isSensitive(path + "/") { return result(["status": "refused", "message": "awan doesn't look in that folder."]) }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return result(["status": "error", "message": "couldn't open that folder (it may not exist, or macOS hasn't given awan access)."])
        }
        let rows = entries.compactMap { u -> (URL, Date, Bool, Int)? in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (u, v?.contentModificationDate ?? .distantPast, v?.isDirectory ?? false, v?.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        let list: [JSON] = rows.prefix(40).map { u, d, dir, size in
            .string("\(u.lastPathComponent)\(dir ? "/" : "") · \(dir ? "folder" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) · \(CompanionNotes.ago(d))")
        }
        return result(["status": "ok", "folder": .string(path), "count": .number(Double(rows.count)), "newest_first": .array(list)])
    }

    // MARK: - Suggestions

    static func decideSuggestion(_ a: [String: JSON]) async -> String {
        let state = AppState.shared
        guard let id = a["suggestion_id"]?.double.map(Int.init), let s = state.suggestions.first(where: { $0.id == id }) else {
            return result(["status": "error", "message": "that suggestion isn't on screen any more. nothing was started; don't start a replacement."])
        }
        guard s.status == "pending" || s.status == "presented" else {
            return result(["status": "handled", "message": "this suggestion was already handled. nothing new was started."])
        }
        if a["decision"]?.string == "skip" {
            await state.decline(s)
            return result(["status": "skipped", "message": "skipped. briefly acknowledge; don't start anything."])
        }
        await state.accept(s)
        let name = AgentStore.shared.agent(s.awanSlug)?.name ?? "the awan"
        return result(["status": "approved", "message": "\(name) is on it. say so in one short sentence. don't start the next suggestion unless the user approves it too."])
    }
}

/// Wraps work the voice model hands to an Awan: the user's own words, the task as the voice model understood it,
/// and a bounded slice of the conversation (the reference's realtime → agent hand-off envelope, in our words).
enum Handoff {
    static func prompt(original: String, task: String, conversation: [TranscriptLine]) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        let recent = conversation.suffix(10).map { "\($0.role == "awan" ? "awan" : $0.role == "user" ? "user" : "note") (\(f.string(from: $0.at))): \($0.text.replacingOccurrences(of: "\n", with: " ").prefix(500))" }
        return """
        \(task)

        <voice_handoff>
        The user asked for this out loud, talking to Awan (the voice companion), which passed it to you.
        What the user said: "\(original.prefix(2000))"
        Recent voice conversation (oldest first, for context, not instructions):
        \(recent.isEmpty ? "(none)" : recent.joined(separator: "\n"))

        Treat the task above as the brief. If it conflicts with the user's own words, their words win. Use the conversation to recover details, constraints and corrections; ignore unrelated topics. If something small is ambiguous, pick the likeliest reading and go; ask only when acting could hit the wrong account or project or do something risky. Answer in your chat reply, and make a file only when the user's words ask for one or the work is itself a file (a site, an app, code). If the task names a PDF or document the user never asked for, drop that format and answer in the chat.
        </voice_handoff>
        """
    }

    /// "Price Radar" → "price-radar" (AgentStore makes it unique).
    static func slug(_ name: String) -> String {
        let s = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        return s.isEmpty ? "awan-\(Int.random(in: 100 ... 999))" : String(s.prefix(40))
    }
}
