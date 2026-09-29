import AppKit
import Foundation

/// Debug entry points for the companion (the CLT toolchain has no XCTest, so the checks live in the app):
///   Awan --selftest                                   pure checks: tag parser, coordinate mapping, chunker, hotkeys, VAD, router, WAV
///   Awan --companion-selftest "<question>" [--api URL] [--out DIR] [--no-speech] [--guided]
///        captures every screen, calls POST /v1/companion/respond with the dev token (AWAN_TOKEN or /tmp/awan_token),
///        prints the streamed + spoken text, the parsed tags and the mapped global points, and fetches speech for the first sentence.
@MainActor
enum CompanionSelfTest {
    static func runIfRequested(_ args: [String]) -> Bool {
        if args.contains("--selftest") {
            exit(runUnitChecks() ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--companion-selftest") {
            let question = args.count > i + 1 ? args[i + 1] : "what am I looking at? point at the most important thing."
            var done = false
            var ok = false
            Task { @MainActor in
                ok = await live(question: question, args: args)
                done = true
            }
            while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            exit(ok ? 0 : 1)
        }
        return false
    }

    // MARK: - Pure checks

    final class Checker {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
            if cond { passed += 1; print("  ✓ \(name)") } else { failed += 1; print("  ✗ \(name) \(detail())") }
        }
    }

    @discardableResult
    static func runUnitChecks() -> Bool {
        let c = Checker()
        print("tag parser")
        parserChecks(c)
        print("coordinate mapping")
        mappingChecks(c)
        print("sentence chunker")
        chunkerChecks(c)
        print("hotkeys")
        hotkeyChecks(c)
        print("voice activity + router + wav + labels + quiet")
        miscChecks(c)
        CompanionExtrasSelfTest.run(c)
        print("\n\(c.passed) passed, \(c.failed) failed")
        return c.failed == 0
    }

    static func parserChecks(_ c: Checker) {
        var r = CompanionTagParser.parse("open the colour inspector, top right of the toolbar. [POINT:1100,42:color inspector]")
        c.check("POINT trailing", r.spokenText == "open the colour inspector, top right of the toolbar." && r.points.count == 1, "\(r)")
        if case let .point(x, y, l)? = r.points.first?.visual { c.check("POINT values", x == 1100 && y == 42 && l == "color inspector") }
        c.check("POINT anchors inside its sentence", r.points.first.map { $0.anchorOffset < r.spokenText.count } ?? false)

        r = CompanionTagParser.parse("that's on your other monitor. [POINT:400,300:terminal:screen2]")
        c.check("POINT screen suffix", r.points.first?.screen == 2 && r.points.first?.visual.label == "terminal", "\(r.tags)")

        r = CompanionTagParser.parse("html is the skeleton of a page. [POINT:none]")
        c.check("POINT:none", r.saidPointNone && r.tags.isEmpty && r.spokenText == "html is the skeleton of a page.")

        r = CompanionTagParser.parse("[TARGET:120,210,40:add modifier] Click Add Modifier to open the list.")
        if case let .target(x, y, rad, l, hover)? = r.target?.visual {
            c.check("TARGET tag-first", x == 120 && y == 210 && rad == 40 && l == "add modifier" && !hover && r.target?.spokenOffset == 0)
        } else { c.check("TARGET parsed", false, "\(r)") }
        c.check("TARGET stripped", r.spokenText == "Click Add Modifier to open the list.", r.spokenText)

        r = CompanionTagParser.parse("[HOVER:10,20,30:menu] rest on the menu.")
        if case let .target(_, _, _, _, hover)? = r.target?.visual { c.check("HOVER is a hover target", hover) } else { c.check("HOVER parsed", false) }

        r = CompanionTagParser.parse("[HIGHLIGHT:10.5,20,300,40:search bar] type here. [SHAPE:circle:50,60;80,60:tool:screen2] this one.")
        if case let .highlight(x, y, w, h, l)? = r.tags.first?.visual {
            c.check("HIGHLIGHT decimals", x == 10.5 && y == 20 && w == 300 && h == 40 && l == "search bar")
        } else { c.check("HIGHLIGHT parsed", false, "\(r.tags)") }
        if r.tags.count == 2, case let .shape(kind, pts, l) = r.tags[1].visual {
            c.check("SHAPE circle + screen", kind == .circle && pts.count == 2 && l == "tool" && r.tags[1].screen == 2)
        } else { c.check("SHAPE parsed", false, "\(r.tags)") }
        c.check("drawing tags stripped", r.spokenText == "type here. this one.", r.spokenText)
        c.check("tag-first anchor points at its sentence", r.tags.count == 2 && r.tags[1].anchorOffset >= "type here.".count)

        r = CompanionTagParser.parse("[SHAPE:polygon:1,2;3,4:bad] two corners is not a polygon.")
        c.check("invalid polygon dropped", r.tags.isEmpty)
        r = CompanionTagParser.parse("[SHAPE:arrow:10,10;200,40:drag here] drag it across.")
        if case let .shape(kind, pts, _)? = r.tags.first?.visual { c.check("SHAPE arrow", kind == .arrow && pts == [CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 40)]) } else { c.check("arrow parsed", false) }

        r = CompanionTagParser.parse("on it, sending an awan. [AGENT:Research competitors: pricing + features, save a PDF.] [POINT:none]")
        c.check("AGENT with colon", r.agentTask == "Research competitors: pricing + features, save a PDF." && r.spokenText == "on it, sending an awan.", "\(r)")

        r = CompanionTagParser.parse("[HIGHLIGHT:1,2,3,4:a] first line.\n[POINT:5,6:b]\n\nsecond   line.")
        c.check("whitespace normalised", r.spokenText == "first line.\nsecond line.", r.spokenText.debugDescription)
        c.check("stripTags", CompanionTagParser.stripTags("a [POINT:1,2:x] b [TARGET:1,2,3:y]") == "a  b ")
    }

    static func mappingChecks(_ c: Checker) {
        // A 1512×982-pt display captured at 1280×831 px.
        let g = CaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), pixelSize: CGSize(width: 1280, height: 831))
        let mid = g.globalPoint(fromPixel: CGPoint(x: 640, y: 415.5))
        c.check("centre maps to centre", abs(mid.x - 756) < 0.01 && abs(mid.y - 491) < 0.01, "\(mid)")
        let tl = g.globalPoint(fromPixel: .zero)
        c.check("top-left pixel → top-left in AppKit (y flipped)", tl == CGPoint(x: 0, y: 982), "\(tl)")
        let clamped = g.globalPoint(fromPixel: CGPoint(x: 5000, y: -20))
        c.check("clamped to the image", clamped == CGPoint(x: 1512, y: 982), "\(clamped)")
        let back = g.pixelPoint(fromGlobal: g.globalPoint(fromPixel: CGPoint(x: 100, y: 700)))
        c.check("inverse round-trips", abs(back.x - 100) < 0.01 && abs(back.y - 700) < 0.01, "\(back)")
        // Secondary display to the right and lower: origin (1512, -300), 1920×1080 pt captured at 1280×720.
        let g2 = CaptureGeometry(displayFrame: CGRect(x: 1512, y: -300, width: 1920, height: 1080), pixelSize: CGSize(width: 1280, height: 720))
        let p2 = g2.globalPoint(fromPixel: CGPoint(x: 400, y: 300))
        c.check("secondary display offset", abs(p2.x - (1512 + 600)) < 0.01 && abs(p2.y - (-300 + 1080 - 450)) < 0.01, "\(p2)")
        let rect = g.globalRect(fromPixel: CGRect(x: 0, y: 0, width: 128, height: 83.1))
        c.check("rect flips to bottom-left origin", abs(rect.minY - (982 - 98.2)) < 0.05 && abs(rect.width - 151.2) < 0.05, "\(rect)")

        let tag = CompanionTag(visual: .point(x: 400, y: 300, label: "terminal"), screen: 2, spokenOffset: 0)
        if case let .point(sp)? = CompanionVisualMapper.resolve(tag, in: [g, g2]) {
            c.check("screen2 tag uses screen 2's geometry", sp.point == p2 && sp.label == "terminal")
        } else { c.check("resolve point", false) }
        let noScreen = CompanionTag(visual: .target(x: 640, y: 415.5, radius: 40, label: nil, isHover: false), screen: 9, spokenOffset: 0)
        if case let .annotation(.target(center, radius, _, _))? = CompanionVisualMapper.resolve(noScreen, in: [g, g2]) {
            c.check("unknown screen falls back to the cursor screen; radius scales", center == mid && abs(radius - 40 * (g.scaleX + g.scaleY) / 2) < 0.01)
        } else { c.check("resolve target", false) }
    }

    static func chunkerChecks(_ c: Checker) {
        let text = "sure. open the file menu up top and pick export as pdf. it'll ask where to save! then you're done?\nnext line here without end"
        var whole = SentenceChunker()
        var a = whole.push(text)
        if let r = whole.flush() { a.append(r) }
        var bits = SentenceChunker()
        var b: [String] = []
        for ch in text { b += bits.push(String(ch)) }
        if let r = bits.flush() { b.append(r) }
        c.check("delta boundaries don't change the chunks", a == b, "\(a) vs \(b)")
        c.check("short opener merges with the next sentence", a.first == "sure. open the file menu up top and pick export as pdf.", "\(a)")
        c.check("splits on ! ? and newline", a.count == 4 && a[1] == "it'll ask where to save!" && a[2] == "then you're done?", "\(a)")
        var n = SentenceChunker()
        c.check("no cut inside 3.5 or e.g. mid-token", n.push("version 3.5 is out and it is good").isEmpty)
        var gate = SpeechSilenceGate()
        let decisions = ([0.0, 0.0, 0.3, 0.001, 0.2] + Array(repeating: 0.0, count: 21)).map { gate.feed(peak: Float($0), frames: 2400) }
        c.check("speech gate: skip lead-in, hold pauses, stop after 2 s of silence",
                 decisions == [.skip, .skip, .play, .hold, .play] + Array(repeating: SpeechSilenceGate.Decision.hold, count: 20) + [.stop], "\(decisions)")
        var long = SentenceChunker()
        let run = String(repeating: "word ", count: 80)
        c.check("very long runs are split", !long.push(run).isEmpty)
    }

    static func hotkeyChecks(_ c: Checker) {
        typealias F = NSEvent.ModifierFlags
        func m() -> HotkeyStateMachine { HotkeyStateMachine(shortcuts: .defaults) }
        func o(_ a: HotkeyAction, _ p: HotkeyPhase) -> HotkeyStateMachine.Output { .init(action: a, phase: p) }

        var s = m()
        var out = s.flags([.control], at: 0) + s.flags([.control, .option], at: 0.05)
        c.check("hold ⌃⌥ → talk pressed", out == [o(.talk, .pressed)], "\(out)")
        out = s.flags([.control], at: 1.2) + s.flags([], at: 1.25)
        c.check("release → talk released, no tap", out == [o(.talk, .released)], "\(out)")

        s = m()
        out = s.flags([.control, .option], at: 0) + s.flags([], at: 0.12)
        c.check("⌃⌥ blip → talk cancelled", out == [o(.talk, .pressed), o(.talk, .cancelled)], "\(out)")

        s = m()
        out = s.flags([.control], at: 0) + s.flags([], at: 0.08) + s.flags([.control], at: 0.2) + s.flags([], at: 0.28)
        c.check("double-tap ⌃ waits for a possible third tap", out.isEmpty && s.pendingDeadline != nil, "\(out)")
        out = s.tick(at: 0.4)
        c.check("…not yet", out.isEmpty)
        out = s.tick(at: 0.7)
        c.check("…then opens the text composer", out == [o(.text, .fired)], "\(out)")

        s = m()
        out = s.flags([.control], at: 0) + s.flags([], at: 0.08) + s.flags([.control], at: 0.2) + s.flags([], at: 0.28)
            + s.flags([.control], at: 0.4) + s.flags([], at: 0.47)
        c.check("triple-tap ⌃ → always-on (no composer)", out == [o(.alwaysOn, .fired)] && s.pendingDeadline == nil, "\(out)")

        s = m()
        out = s.flags([.control], at: 0) + s.flags([], at: 0.08) + s.flags([.control], at: 0.2) + s.flags([], at: 0.28)
        out += s.keyDown(4, flags: [], isRepeat: false, at: 0.33)
        c.check("typing right after a double-tap opens the composer at once", out == [o(.text, .fired)], "\(out)")

        s = m()
        out = s.flags([.control], at: 0) + s.flags([], at: 0.08) + s.flags([.control], at: 0.9) + s.flags([], at: 0.98)
        c.check("slow taps are not a double-tap", out.isEmpty && s.pendingDeadline == nil, "\(out)")

        s = m()
        out = s.flags([.function], at: 0) + s.flags([.function, .control], at: 0.03)
        c.check("hold fn⌃ → dictate pressed", out == [o(.dictate, .pressed)], "\(out)")
        out = s.flags([.function, .control, .option], at: 0.5)
        c.check("adding ⌥ during dictation does not start talk", out.isEmpty, "\(out)")
        out = s.flags([.control], at: 2) + s.flags([], at: 2.05)
        c.check("release → dictate released", out == [o(.dictate, .released)], "\(out)")

        s = m()
        out = s.flags([.control, .option], at: 0)
        out += s.flags([.control, .option, .function], at: 0.4)
        c.check("adding fn during talk does not start dictation", out == [o(.talk, .pressed)], "\(out)")

        s = m()
        out = s.flags([.function, .control], at: 0) + s.flags([], at: 0.1) + s.flags([.function, .control], at: 0.25) + s.flags([], at: 0.33)
        c.check("double-tap fn⌃ → hands-free (first tap cancels the hold)", out == [o(.dictate, .pressed), o(.dictate, .cancelled), o(.handsFreeDictate, .fired)], "\(out)")

        s = m()
        out = s.flags([.control, .option], at: 0) + s.keyDown(124, flags: [.control, .option], isRepeat: false, at: 0.2)
        c.check("⌃⌥→ is a shortcut, not a talk", out == [o(.talk, .pressed), o(.talk, .cancelled)], "\(out)")
        out = s.flags([], at: 0.4)
        c.check("…and releasing it does nothing more", out.isEmpty, "\(out)")

        s = m()
        out = s.flags([.control], at: 0) + s.flags([.control, .command], at: 0.05) + s.keyDown(0, flags: [.control, .command], isRepeat: false, at: 0.1)
        c.check("⌃⌘A → open Home", out == [o(.openHome, .fired)], "\(out)")
        out = s.keyDown(0, flags: [.control, .command], isRepeat: true, at: 0.5)
        c.check("autorepeat ignored", out.isEmpty)

        s = m()
        out = s.keyDown(53, flags: [], isRepeat: false, at: 0)
        c.check("esc → escape", out == [o(.escape, .fired)], "\(out)")

        // Handoff (wave 2): hold ⌃⌥⇧.
        s = m()
        out = s.flags([.control, .option], at: 0) + s.flags([.control, .option, .shift], at: 0.06)
        c.check("⌃⌥ then ⇧ → talk gives way to handoff", out == [o(.talk, .pressed), o(.talk, .cancelled), o(.handoff, .pressed)], "\(out)")
        out = s.flags([], at: 0.5)
        c.check("…releasing ends the handoff hold", out == [o(.handoff, .released)], "\(out)")
        s = m()
        out = s.flags([.shift], at: 0) + s.flags([.shift, .control], at: 0.03) + s.flags([.shift, .control, .option], at: 0.05)
        c.check("⇧⌃⌥ in any order → handoff", out == [o(.handoff, .pressed)], "\(out)")
        s = m()
        out = s.flags([.control, .option], at: 0) + s.flags([.control, .option, .shift], at: 1.5)
        c.check("⇧ late in a long talk does not steal it", out == [o(.talk, .pressed)], "\(out)")
        let legacy = #"{"talk":{"trigger":"hold","modifiers":786432},"text":{"trigger":"doubleTap","modifiers":262144},"dictate":{"trigger":"hold","modifiers":8650752},"handsFreeDictate":{"trigger":"doubleTap","modifiers":8650752},"openHome":{"trigger":"hold","modifiers":1310720,"keyCode":0}}"#
        let decoded = try? JSONDecoder().decode(ShortcutSet.self, from: Data(legacy.utf8))
        c.check("a shortcut set saved before handoff existed still loads", decoded?.handoff == ShortcutSet.defaultHandoff && decoded?.talk == ShortcutSet.defaults.talk, "\(String(describing: decoded))")

        var custom = ShortcutSet.defaults
        custom.talk = HotkeyBinding(trigger: .hold, modifiers: F([.control, .option]).rawValue, keyCode: 49)
        s = HotkeyStateMachine(shortcuts: custom)
        out = s.flags([.control, .option], at: 0) + s.keyDown(49, flags: [.control, .option], isRepeat: false, at: 0.1)
        c.check("custom ⌃⌥space hold → talk pressed on the key", out == [o(.talk, .pressed)], "\(out)")
        out = s.keyUp(49, at: 1)
        c.check("…released on key up", out == [o(.talk, .released)], "\(out)")
    }

    static func miscChecks(_ c: Checker) {
        var vad = VoiceActivityDetector()
        var events: [(VoiceActivityDetector.Event, Double)] = []
        var t = 0.0
        func run(_ level: Float, for seconds: Double) {
            let end = t + seconds
            while t < end { if let e = vad.feed(level: level, at: t) { events.append((e, t)) }; t += 0.02 }
        }
        run(0.08, for: 1.5); run(0.62, for: 1.0); run(0.08, for: 1.5)
        c.check("VAD: one start, one end", events.map(\.0) == [.speechStarted, .speechEnded], "\(events)")
        if events.count == 2 {
            c.check("VAD: start ≈ onset + 0.22 s", abs(events[0].1 - 1.72) < 0.06, "\(events[0].1)")
            c.check("VAD: end ≈ offset + 0.75 s", abs(events[1].1 - 3.25) < 0.06, "\(events[1].1)")
        }
        vad.reset()
        events = []
        run(0.08, for: 1); run(0.7, for: 0.1); run(0.08, for: 1)
        c.check("VAD ignores a click", events.isEmpty, "\(events)")

        func agent(_ slug: String, _ name: String, _ role: String, _ line: String) -> AwanAgent {
            AwanAgent(slug: slug, name: name, roleText: role, oneLiner: line, introMessages: [], suggestedAsks: [], baseHue: 0.5,
                      character: CharacterCatalog.appearance(forHue: 0.5, seed: slug), createdAt: Date())
        }
        let cast = [agent("inbox-keeper", "Inbox Keeper", "Email assistant", "Triages your email inbox and drafts replies."),
                    agent("research-scout", "Research Scout", "Researcher", "Digs into companies, markets and competitors and hands you a tidy report."),
                    agent("ship-lab", "Ship Lab", "Web builder", "Builds and ships websites and small web projects right on your Mac.")]
        c.check("router: email → Inbox Keeper", AgentRouter.bestSlug(for: "draft replies to the emails in my inbox", among: cast) == "inbox-keeper")
        c.check("router: build a landing page → Ship Lab", AgentRouter.bestSlug(for: "build me a landing page for the bakery", among: cast) == "ship-lab")
        c.check("router: competitors → Research Scout", AgentRouter.bestSlug(for: "look into our three biggest competitors and their pricing", among: cast) == "research-scout")
        c.check("router: nothing matches → research-scout", AgentRouter.bestSlug(for: "zzz qqq", among: cast) == "research-scout")

        let wav = WAVWriter.data(pcm16: Data(count: 3200))
        let rate = wav.subdata(in: 24 ..< 28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        c.check("WAV header", wav.count == 44 + 3200 && String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF" && UInt32(littleEndian: rate) == 16000)
        c.check("PCM duration", abs(AudioCapture.duration(ofPCM16: Data(count: 32000)) - 1) < 0.001)

        c.check("screen label (primary)", ScreenCapture.label(index: 1, count: 2, isCursorScreen: true, width: 1280, height: 800)
            == "screen 1 of 2 — primary focus (cursor is here) (image dimensions: 1280x800 pixels)")
        c.check("screen label (secondary)", ScreenCapture.label(index: 2, count: 2, isCursorScreen: false, width: 1280, height: 720)
            == "screen 2 of 2 — secondary screen (image dimensions: 1280x720 pixels)")

        c.check("quiet: Zoom meeting", QuietContext.isCallWindow(owner: "zoom.us", title: "Zoom Meeting"))
        c.check("quiet: Meet tab", QuietContext.isCallWindow(owner: "Google Chrome", title: "Meet - abc-defg-hij"))
        c.check("quiet: plain Zoom window isn't a call", !QuietContext.isCallWindow(owner: "zoom.us", title: "Zoom Workplace"))
        c.check("quiet: Safari isn't a call", !QuietContext.isCallWindow(owner: "Safari", title: "Apple"))

        let trail = (0 ..< 20).map { i in CGPoint(x: 100 + 40 * cos(Double(i) / 3), y: 100 + 40 * sin(Double(i) / 3)) }
        c.check("a circle is a meaningful trail", ScreenCapture.isMeaningfulTrail(trail))
        c.check("a twitch is not", !ScreenCapture.isMeaningfulTrail([CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2), CGPoint(x: 3, y: 3)]))
    }

    // MARK: - Live end-to-end

    /// Runs the real SpeechPlayer (AVAudioEngine, silence gate, sentence markers) against the server; silent unless --audible.
    private static func playThroughSpeechPlayer(_ sentences: [String], api: URL, token: String, audible: Bool) async {
        let player = SpeechPlayer()
        player.outputVolume = audible ? 1 : 0
        player.speechSource = { body in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        var req = URLRequest(url: api.appendingPathComponent("v1/speech"))
                        req.httpMethod = "POST"
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        req.httpBody = try JSONEncoder().encode(body)
                        let (bytes, _) = try await URLSession.shared.bytes(for: req)
                        var buf = Data()
                        for try await b in bytes {
                            buf.append(b)
                            if buf.count >= 4800 { continuation.yield(buf); buf = Data() }
                        }
                        if !buf.isEmpty { continuation.yield(buf) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        let t0 = Date()
        var finished = false
        func stamp(_ s: String) { print(String(format: "  %6.2fs  %@", Date().timeIntervalSince(t0), s)) }
        player.onStart = { stamp("first audio") }
        player.onSentenceStart = { i in stamp("sentence \(i + 1) starts: \(sentences[i].prefix(50))…") }
        player.onFinish = { stamp("finished"); finished = true }
        print("\nplaying through SpeechPlayer (\(audible ? "audible" : "silent")):")
        player.begin(serverSpeech: true)
        for s in sentences { player.enqueue(s) }
        player.finishInput()
        let deadline = Date().addingTimeInterval(90)
        while !finished, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if !finished { stamp("TIMED OUT (never finished)"); player.stop() }
    }

    private static func live(question: String, args: [String]) async -> Bool {
        func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } }
        let api = URL(string: arg("--api") ?? ProcessInfo.processInfo.environment["AWAN_API"] ?? "http://127.0.0.1:8787")!
        let out = URL(fileURLWithPath: arg("--out") ?? NSTemporaryDirectory(), isDirectory: true)
        let token = ProcessInfo.processInfo.environment["AWAN_TOKEN"]
            ?? (try? String(contentsOfFile: "/tmp/awan_token", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else { print("no token (set AWAN_TOKEN or write /tmp/awan_token)"); return false }

        setvbuf(stdout, nil, _IONBF, 0)
        print("question: \(question)")
        print("screen recording permission: \(ScreenCapture.hasPermission ? "yes" : "no")")
        let t0 = Date()
        var frames: [ScreenCaptureFrame] = []
        do { frames = try await ScreenCapture.captureAll() } catch { print("capture failed: \(error.localizedDescription) — continuing without screenshots") }
        print(String(format: "captured %d screen(s) in %.2fs", frames.count, Date().timeIntervalSince(t0)))
        for f in frames {
            print("  [\(f.index)] \(f.label)  display=\(NSStringFromRect(f.geometry.displayFrame))  jpeg=\(f.jpeg.count / 1024) KB")
            try? f.jpeg.write(to: out.appendingPathComponent("awan-selftest-screen\(f.index).jpg"))
        }

        let requestId = "selftest-\(UUID().uuidString)"
        let body = CompanionEngine.requestBody(transcript: question, frames: frames, history: [], requestId: requestId)
        print("context block: \(body.context?.replacingOccurrences(of: "\n", with: " ⏎ ") ?? "none")")
        var req = URLRequest(url: api.appendingPathComponent("v1/companion/respond"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(body)
        req.timeoutInterval = 120

        var chunker = SentenceChunker()
        var sentences: [String] = []
        var raw = ""
        var firstDelta: Double?
        var deltaCount = 0
        print("\nstreaming:")
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                var d = Data(); for try await b in bytes { d.append(b) }
                print("HTTP \(http.statusCode): \(String(decoding: d, as: UTF8.self))")
                return false
            }
            var event = "message"
            for try await line in bytes.lines {
                if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces); continue }
                guard line.hasPrefix("data:") else { continue }
                let json = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8))) as? [String: Any] ?? [:]
                switch event {
                case "delta":
                    if firstDelta == nil { firstDelta = Date().timeIntervalSince(t0) }
                    deltaCount += 1
                    let d = json["text"] as? String ?? ""
                    FileHandle.standardOutput.write(Data(d.utf8))
                    sentences += chunker.push(d)
                case "done":
                    raw = json["text"] as? String ?? ""
                    if let r = chunker.flush() { sentences.append(r) }
                case "error":
                    print("\nserver error: \(json)")
                    return false
                default: break
                }
                event = "message"
            }
        } catch {
            print("request failed: \(error.localizedDescription)")
            return false
        }
        print(String(format: "\n\n%d deltas; first text after %.2fs, done after %.2fs (incl. capture)", deltaCount, firstDelta ?? -1, Date().timeIntervalSince(t0)))
        let reply = CompanionTagParser.parse(raw)
        print("raw reply: \(raw)")
        print("spoken text: \(reply.spokenText)")
        print("sentences for TTS: \(sentences.count)")
        for (i, s) in sentences.enumerated() { print("  \(i + 1). \(s)") }
        if let task = reply.agentTask { print("agent task: \(task) → \(AgentRouter.bestSlug(for: task, among: AgentStore.shared.visibleAgents) ?? "no Awans on this Mac")") }
        let geometries = frames.map(\.geometry)
        print("tags: \(reply.tags.count)\(reply.saidPointNone ? " (+ POINT:none)" : "")")
        for tag in reply.tags {
            let resolved = CompanionVisualMapper.resolve(tag, in: geometries)
            let where_: String
            switch resolved {
            case let .point(p)?: where_ = "fly to global (\(Int(p.point.x)), \(Int(p.point.y))) \"\(p.label ?? "")\""
            case let .annotation(a)?: where_ = "annotate \(a)"
            case nil: where_ = "unmapped (no screenshot)"
            }
            print("  \(tag.visual) screen=\(tag.screen.map(String.init) ?? "cursor") → \(where_)")
        }

        if !args.contains("--no-speech"), let first = sentences.first {
            let s0 = Date()
            var sreq = URLRequest(url: api.appendingPathComponent("v1/speech"))
            sreq.httpMethod = "POST"
            sreq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            sreq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            sreq.httpBody = try? JSONSerialization.data(withJSONObject: ["text": first, "voice": "cedar", "speed": 1.0])
            var pcm = Data()
            var firstByte: Double?
            var gate = SpeechSilenceGate()
            var kept = Data()
            var held = Data()
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: sreq)
                var chunk = Data()
                read: for try await b in bytes {
                    if firstByte == nil { firstByte = Date().timeIntervalSince(s0) }
                    chunk.append(b)
                    guard chunk.count >= 4800 else { continue }
                    pcm.append(chunk)
                    var peak: Float = 0
                    chunk.withUnsafeBytes { r in
                        let u = r.bindMemory(to: UInt8.self)
                        for i in stride(from: 0, to: u.count - 1, by: 2) { peak = max(peak, abs(Float(Int16(bitPattern: UInt16(u[i]) | UInt16(u[i + 1]) << 8)) / 32768)) }
                    }
                    switch gate.feed(peak: peak, frames: chunk.count / 2) {
                    case .skip: break
                    case .hold: held.append(chunk)
                    case .play: kept.append(held); held = Data(); kept.append(chunk)
                    case .stop: break read
                    }
                    chunk = Data()
                }
            } catch { print("speech failed: \(error.localizedDescription)") }
            print(String(format: "speech gate kept %.1fs of voice and stopped the stream after %.1fs received (%.1fs to stop)", Double(kept.count) / 48_000, Double(pcm.count) / 48_000, Date().timeIntervalSince(s0)))
            pcm = kept
            let wavURL = out.appendingPathComponent("awan-selftest-speech.wav")
            try? WAVWriter.write(pcm16: pcm, sampleRate: 24_000, to: wavURL)
            print(String(format: "speech: %d bytes (%.1fs of 24 kHz audio), first byte after %.2fs → %@", pcm.count, Double(pcm.count) / 48_000, firstByte ?? -1, wavURL.path))
        }
        if args.contains("--play"), !sentences.isEmpty {
            await playThroughSpeechPlayer(sentences, api: api, token: token, audible: args.contains("--audible"))
        }

        if args.contains("--guided"), let target = reply.target {
            // Simulate the user clicking the armed target: re-capture and ask for step 2 with the same requestId.
            let label = target.visual.label
            let prompt = CompanionEngine.guidedStepPrompt(step: 1, label: label, goal: question, completed: [label ?? "step 1"])
            print("\n— simulating a click on \"\(label ?? "")\" → guided step 2 —\n\(prompt)")
            let again = (try? await ScreenCapture.captureAll()) ?? frames
            let body2 = CompanionEngine.requestBody(transcript: prompt, frames: again, history: [CompanionExchange(user: question, assistant: reply.spokenText)], requestId: requestId)
            var r2 = req
            r2.httpBody = try? JSONEncoder().encode(body2)
            var raw2 = ""
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: r2)
                var event = ""
                for try await line in bytes.lines {
                    if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces); continue }
                    if line.hasPrefix("data:"), event == "done" || event == "error" {
                        let j = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8))) as? [String: Any] ?? [:]
                        raw2 = j["text"] as? String ?? "error: \(j)"
                    }
                }
            } catch { print("step 2 failed: \(error.localizedDescription)") }
            let step2 = CompanionTagParser.parse(raw2)
            print("step 2 raw: \(raw2)")
            print("step 2 target: \(step2.target.map { "\($0.visual)" } ?? "none (walkthrough finished)")")
        }
        return !reply.spokenText.isEmpty
    }
}
