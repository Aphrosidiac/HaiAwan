import AppKit
import Foundation

/// Checks for the voice conversation (v2):
///   Awan --voice-selftest            pure checks: conversation wire shape, notes, utterance gate, hand-off, file guard
///   Awan --voice-live [--api URL] [--fake-screen] "turn 1" "turn 2" …
///        runs a real multi-turn conversation through CompanionEngine against the server (dev token from AWAN_TOKEN or
///        /tmp/awan_token), headless and silent, with side-effect tools in dry-run. Prints each turn's context notes,
///        tool calls and results, the reply and the timings. Nothing is persisted, spoken, typed or started.
@MainActor
enum CompanionVoiceSelfTest {
    static func runIfRequested(_ args: [String]) -> Bool {
        if args.contains("--voice-selftest") {
            exit(runChecks() ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--voice-live") {
            var done = false, ok = false
            Task { @MainActor in
                ok = await live(Array(args[(i + 1)...]))
                done = true
            }
            while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            exit(ok ? 0 : 1)
        }
        return false
    }

    // MARK: - Pure checks

    static func runChecks() -> Bool {
        let c = CompanionSelfTest.Checker()
        print("conversation")
        let convo = CompanionConversation(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("awan-voice-selftest.json"), persist: false)
        c.check("first turn opens a session", convo.ensureSession())
        c.check("an active session is reused", !convo.ensureSession())
        convo.record("user", "my sister is aina")
        convo.record("awan", "nice.")
        c.check("idle session is rebuilt", convo.ensureSession(now: Date().addingTimeInterval(CompanionConversation.idleTeardown + 5)))
        c.check("rebuilt session carries the transcript", convo.items.first?.text?.contains("my sister is aina") == true && convo.priorMessageCount == 2)
        let frame = fakeFrame()
        for i in 0 ..< 3 { convo.append(.utterance("turn \(i)", images: [frame])) }
        let wire = convo.wireItems()
        let imageCount = wire.compactMap { $0["content"]?.array }.flatMap { $0 }.filter { $0["type"]?.string == "image_url" }.count
        c.check("only the newest screenshot submissions carry pixels", imageCount == CompanionConversation.liveImageSubmissions, "\(imageCount)")
        convo.append(ConversationItem(role: .assistant, kind: .reply, text: "one sec.", toolCalls: [ToolCallItem(id: "c1", name: "ask_deeper", arguments: "{}")]))
        convo.closeDanglingToolCalls()
        c.check("a cut-off tool call gets a result", convo.items.last?.toolCallID == "c1")
        let a = ToolCallItem(id: "x", name: "web_search", arguments: #"{"query":"kl weather","n":2}"#).args
        c.check("tool arguments decode", a["query"]?.string == "kl weather" && a["n"]?.double == 2)

        print("utterance gate")
        c.check("words pass", CompanionEngine.isUtterance("where is export"))
        c.check("empty fails", !CompanionEngine.isUtterance("  "))
        c.check("filler fails", !CompanionEngine.isUtterance("um, uh"))
        c.check("punctuation fails", !CompanionEngine.isUtterance("…"))

        print("notes")
        c.check("time note says now", CompanionNotes.time().hasPrefix("[time]") && CompanionNotes.time().contains("treat it as now"))
        let circle = (0 ..< 40).map { i -> CGPoint in let t = Double(i) / 39 * 2 * .pi; return CGPoint(x: 400 + 80 * cos(t), y: 400 + 60 * sin(t)) }
        let line = (0 ..< 20).map { CGPoint(x: 100 + CGFloat($0) * 30, y: 300) }
        c.check("circle classified", CompanionNotes.classify(circle) == .circle)
        c.check("line classified", CompanionNotes.classify(line) == .line)
        let d = CompanionNotes.drawing([circle], frames: [frame]) ?? ""
        c.check("drawing note describes the mark", d.hasPrefix("[drawing]") && d.contains("circled") && d.contains("screen 1"), d)
        c.check("tiny twitch is not a drawing", CompanionNotes.drawing([[CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)]], frames: [frame]) == nil)
        c.check("region words", CompanionNotes.region(CGPoint(x: 10, y: 10), in: CGSize(width: 900, height: 900)) == "top-left area"
            && CompanionNotes.region(CGPoint(x: 450, y: 450), in: CGSize(width: 900, height: 900)) == "middle")
        let p1 = [CompanionNotes.fingerprint(frame.image)]
        c.check("same screen → unchanged", CompanionNotes.sameScreens(p1, p1))
        let blank = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!.makeImage()!
        c.check("different screen → changed", !CompanionNotes.sameScreens(p1, [CompanionNotes.fingerprint(blank)]))
        let roster = CompanionNotes.awans()
        c.check("roster note has its label", roster.hasPrefix("[awans]"))

        print("hand-off and files")
        let h = Handoff.prompt(original: "research my competitors", task: "Research the top three competitors", conversation: [TranscriptLine(role: "user", text: "i sell bread in kl", at: Date())])
        c.check("hand-off carries the user's words and the conversation", h.contains("research my competitors") && h.contains("i sell bread in kl") && h.hasPrefix("Research the top three"))
        c.check("slug", Handoff.slug("Price Radar!") == "price-radar")
        c.check("keys are never read", CompanionTools.isSensitive("/Users/x/.ssh/id_ed25519") && CompanionTools.isSensitive("/p/.env.local") && CompanionTools.isSensitive("/Users/x/Library/Application Support/Awan/CodexHome/auth.json"))
        c.check("ordinary files are readable", !CompanionTools.isSensitive("/Users/x/Documents/notes.md"))
        c.check("~ paths resolve", CompanionTools.resolvePath("~/Desktop")?.hasPrefix("/") == true && CompanionTools.resolvePath("relative") == nil)
        c.check("every capability has a status label", CompanionTools.capabilities.allSatisfy { CompanionTools.statusLabel(ToolCallItem(id: "", name: $0, arguments: "{}")) != "Working…" })

        print("stop")
        CompanionConversation.shared = CompanionConversation(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("awan-voice-stop.json"), persist: false)
        CompanionEngine.headless = true
        let engine = CompanionEngine.shared
        engine.setVoice(.responding)
        engine.agentUpdate(slug: "x", name: "Research Scout", summary: "done", spoken: nil, files: [], needsYou: false, speak: true)
        c.check("an update while Awan talks is queued", engine.isBusy)
        engine.stop()
        c.check("stop ends talking and drops queued speech", !engine.isBusy && engine.voiceState == .idle)
        c.check("the update is still remembered", engine.conversation.transcript.contains { $0.text.contains("Research Scout finished") })
        c.check("a quick tap of the talk keys only stops", CompanionEngine.stopTapWindow >= 0.4 && CompanionEngine.stopTapWindow <= 0.8)

        print("\n\(c.passed) passed, \(c.failed) failed")
        return c.failed == 0
    }

    // MARK: - Fake screen

    /// A 1280×800 "app window" with a menu bar, a sidebar and an Export button at pixels (1090–1230, 44–84).
    static func fakeFrame(button: String = "Export") -> ScreenCaptureFrame {
        let w = 1280, h = 800
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        NSColor(white: 0.97, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSColor(white: 0.9, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: 28).fill()
        NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 28, width: 220, height: h - 28).fill()
        let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.black]
        ("Sketchbook   File   Edit   View   Help" as NSString).draw(at: NSPoint(x: 14, y: 5), withAttributes: big)
        for (i, item) in ["Pages", "Layers", "Assets", "Comments"].enumerated() { (item as NSString).draw(at: NSPoint(x: 20, y: 60 + i * 34), withAttributes: big) }
        ("Landing page — hero section" as NSString).draw(at: NSPoint(x: 260, y: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.black])
        NSColor.systemBlue.setFill(); NSBezierPath(roundedRect: NSRect(x: 1090, y: 44, width: 140, height: 40), xRadius: 8, yRadius: 8).fill()
        (button as NSString).draw(at: NSPoint(x: 1132, y: 54), withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.white])
        NSColor(white: 0.85, alpha: 1).setFill(); NSRect(x: 260, y: 110, width: 780, height: 420).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = ctx.makeImage()!
        let display = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return ScreenCaptureFrame(index: 1, count: 1, isCursorScreen: true, displayID: CGMainDisplayID(),
                                  geometry: CaptureGeometry(displayFrame: display, pixelSize: CGSize(width: w, height: h)),
                                  image: image, jpeg: ScreenCapture.jpegData(image) ?? Data(),
                                  label: ScreenCapture.label(index: 1, count: 1, isCursorScreen: true, width: w, height: h))
    }

    // MARK: - Live

    static func live(_ rest: [String]) async -> Bool {
        setvbuf(stdout, nil, _IONBF, 0)
        var turns: [String] = []
        var api = ProcessInfo.processInfo.environment["AWAN_API"] ?? "http://127.0.0.1:8787"
        var fake = false
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--api": api = rest[min(i + 1, rest.count - 1)]; i += 1
            case "--fake-screen": fake = true
            default: turns.append(rest[i])
            }
            i += 1
        }
        let token = ProcessInfo.processInfo.environment["AWAN_TOKEN"]
            ?? (try? String(contentsOfFile: "/tmp/awan_token", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else { print("no token (set AWAN_TOKEN or write /tmp/awan_token)"); return false }
        APIClient.shared.baseURLOverride = api
        APIClient.shared.tokenOverride = token
        CompanionConversation.shared = CompanionConversation(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("awan-voice-live.json"), persist: false)
        CompanionEngine.headless = true
        CompanionTools.dryRun = true
        let engine = CompanionEngine.shared
        var allOK = true

        for (n, text) in turns.enumerated() {
            print("\n━━ turn \(n + 1): \(text)")
            let before = engine.conversation.items.count
            let logBefore = CompanionTools.dryRunLog.count
            let visualsBefore = engine.firedVisuals.count
            // "@update <slug> <summary>": an Awan finished; "@home <slug>": the user has that Awan's chat open.
            if text.hasPrefix("@update ") {
                let parts = text.dropFirst(8).split(separator: " ", maxSplits: 1).map(String.init)
                let slug = parts.first ?? ""
                engine.agentUpdate(slug: slug, name: AgentStore.shared.agent(slug)?.name ?? slug, summary: parts.count > 1 ? parts[1] : "done", spoken: nil, files: [], needsYou: false, speak: true)
                await engine.responseTask?.value
                for item in engine.conversation.items[before...] where item.role == .assistant { print("  awan   \(item.text ?? "")") }
                print("  reply: \(engine.responseText)")
                continue
            }
            if text.hasPrefix("@home ") {
                AppState.shared.isHomeOpen = true
                AppState.shared.homePage = .agent(String(text.dropFirst(6)))
                print("  (home open on \(text.dropFirst(6)))")
                continue
            }
            if text == "@home-close" { AppState.shared.isHomeOpen = false; print("  (home closed)"); continue }
            let frames = fake ? [fakeFrame()] : await CompanionEngine.captureFrames()
            // "@attach <path>[,<path>] <words>": files dropped on the mascot with a message.
            var words = text
            var files: [URL] = []
            if text.hasPrefix("@attach ") {
                let parts = text.dropFirst(8).split(separator: " ", maxSplits: 1).map(String.init)
                files = (parts.first ?? "").split(separator: ",").map { URL(fileURLWithPath: String($0)) }
                words = parts.count > 1 ? parts[1] : ""
            }
            let turn = CompanionTurn(userText: words, display: words, frames: frames, document: nil, drawing: nil, app: nil, speak: false)
            turn.attachments = files
            turn.attachedImages = CompanionEngine.attachedImages(files)
            let t0 = Date()
            await engine.runUserTurn(turn)
            let secs = Date().timeIntervalSince(t0)
            for item in engine.conversation.items[before...] {
                switch (item.role, item.kind) {
                case (.user, .note): print("  note   \(item.text?.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(220) ?? "")")
                case (.user, _): print("  user   \(item.text ?? "")\(item.images.isEmpty ? "" : "  [+\(item.images.count) screenshot]")")
                case (.assistant, _):
                    if let t = item.text { print("  awan   \(t)") }
                    for call in item.toolCalls { print("  call   \(call.name) \(call.arguments.prefix(260))") }
                case (.tool, _): print("  result \(item.text?.prefix(320) ?? "")")
                }
            }
            for call in CompanionTools.dryRunLog[logBefore...] { print("  (dry run: \(call.name))") }
            for v in engine.firedVisuals[visualsBefore...] { print("  visual \(v)") }
            print(String(format: "  ⏱ %.1f s · reply: %@", secs, engine.responseText))
            if engine.responseText.isEmpty && CompanionTools.dryRunLog.count == logBefore { allOK = false; print("  ✗ no reply and no action") }
        }
        return allOK
    }
}
