import AppKit
import AVFoundation
import PDFKit

/// `--selftest` checks for the companion extras: TYPE / IMAGES tags, typing prep, document reading,
/// the morning greeting, Cat Mode frames, and the realtime wire format + session flow (fake transport).
@MainActor
enum CompanionExtrasSelfTest {
    static func run(_ c: CompanionSelfTest.Checker) {
        print("type + images tags")
        tagChecks(c)
        print("typing + documents")
        typingChecks(c)
        documentChecks(c)
        print("morning greeting + cat mode")
        greetingChecks(c)
        catChecks(c)
        print("realtime voice (codec + fake transport)")
        realtimeCodecChecks(c)
        realtimeSessionChecks(c)
    }

    // MARK: - Tags

    static func tagChecks(_ c: CompanionSelfTest.Checker) {
        var r = CompanionTagParser.parse("here you go, typing it in. [TYPE:640,812:reply box]sounds good: see you at 8 [ok]![/TYPE] [POINT:none]")
        c.check("TYPE block text (brackets + colons survive)", r.typeRequest?.text == "sounds good: see you at 8 [ok]!", "\(String(describing: r.typeRequest))")
        c.check("TYPE block spot", r.typeRequest?.x == 640 && r.typeRequest?.y == 812 && r.typeRequest?.label == "reply box")
        c.check("TYPE never spoken", r.spokenText == "here you go, typing it in." && r.saidPointNone, r.spokenText)
        r = CompanionTagParser.parse("typing it. [TYPE]\nline one\nline two\n[/TYPE]")
        c.check("TYPE plain, multi-line", r.typeRequest?.text == "line one\nline two" && r.typeRequest?.x == nil && r.spokenText == "typing it.")
        r = CompanionTagParser.parse("typing it. [TYPE]half a mess")
        c.check("TYPE unterminated runs to the end", r.typeRequest?.text == "half a mess" && r.spokenText == "typing it.")
        c.check("TYPE with screen suffix", CompanionTagParser.parse("[TYPE:10,20:box:screen2]hi[/TYPE]").typeRequest?.screen == 2)
        c.check("stripTags hides an open TYPE block", CompanionTagParser.stripTags("sure. [TYPE]dear sam, tha") == "sure. ")
        c.check("stripTags drops a closed TYPE block", CompanionTagParser.stripTags("a [TYPE]x[/TYPE] b") == "a  b")
        r = CompanionTagParser.parse("a small wallaby with a big grin. [IMAGES:quokka on rottnest] [POINT:none]")
        c.check("IMAGES query", r.imagesQuery == "quokka on rottnest" && r.spokenText == "a small wallaby with a big grin.", "\(r)")
        c.check("no tags → no type / images", CompanionTagParser.parse("hello there.").typeRequest == nil && CompanionTagParser.parse("hello there.").imagesQuery == nil)
    }

    // MARK: - Typing + documents

    static func typingChecks(_ c: CompanionSelfTest.Checker) {
        c.check("typing never presses Return", CompanionTyper.prepared("hi there\r\n\n", singleLine: false) == "hi there")
        c.check("single-line fields get one line", CompanionTyper.prepared("one\ntwo", singleLine: true) == "one two")
        c.check("multi-line kept for text areas", CompanionTyper.prepared("one\ntwo", singleLine: false) == "one\ntwo")
        c.check("password managers refused", CompanionTyper.isPrivateApp("com.1password.1password") && CompanionTyper.isPrivateApp("com.apple.Passwords") && !CompanionTyper.isPrivateApp("com.apple.TextEdit"))
    }

    static func documentChecks(_ c: CompanionSelfTest.Checker) {
        for q in ["summarize this pdf", "what does this document say about pricing?", "tl;dr", "what's the key takeaways of the article", "explain this page to me", "what does it say"] {
            c.check("refers to doc: \(q)", ActiveDocumentReader.refersToDocument(q))
        }
        for q in ["what time is it in tokyo", "where's the export button", "make me a landing page", "how do i crop this"] {
            c.check("not a doc question: \(q)", !ActiveDocumentReader.refersToDocument(q))
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("awan-doc-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let md = dir.appendingPathComponent("notes.md")
        try? "# Launch plan\nship on thursday".write(to: md, atomically: true, encoding: .utf8)
        let mdOut = ActiveDocumentReader.extractText(url: md)
        c.check("markdown read directly", mdOut?.0.contains("ship on thursday") == true && mdOut?.1 == "document")
        let code = dir.appendingPathComponent("main.swift")
        try? "print(\"hi\")".write(to: code, atomically: true, encoding: .utf8)
        c.check("code file read", ActiveDocumentReader.extractText(url: code)?.1 == "code file")

        let rtf = dir.appendingPathComponent("letter.rtf")
        let attr = NSAttributedString(string: "Dear Sam, the quarterly numbers are in.")
        if let data = try? attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            try? data.write(to: rtf)
        }
        c.check("rtf via textutil", ActiveDocumentReader.extractText(url: rtf)?.0.contains("quarterly numbers") == true)
        let docx = dir.appendingPathComponent("brief.docx")
        if let data = try? attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]) {
            try? data.write(to: docx)
        }
        c.check("docx via textutil", ActiveDocumentReader.extractText(url: docx)?.0.contains("quarterly numbers") == true)

        let pdfURL = dir.appendingPathComponent("paper.pdf")
        writePDF(pages: ["Abstract: clouds are made of water.", "Results: they float."], to: pdfURL)
        let pdf = ActiveDocumentReader.extractText(url: pdfURL)
        c.check("pdf via PDFKit, pages labelled", pdf?.1 == "PDF" && pdf?.0.contains("[page 2]") == true && pdf?.0.contains("they float") == true, "\(String(describing: pdf))")
        c.check("unknown binary refused", ActiveDocumentReader.extractText(url: dir.appendingPathComponent("x.psd")) == nil)

        let doc = ActiveDocument(name: "paper.pdf", kind: "PDF", text: "hello", source: "file")
        let body = CompanionEngine.requestBody(transcript: "summarize this", frames: [], history: [], requestId: "r", document: doc)
        c.check("request carries document {name,text,kind}", body.document == ["name": "paper.pdf", "text": "hello", "kind": "PDF"])
        c.check("no document → field omitted", CompanionEngine.requestBody(transcript: "hi", frames: [], history: [], requestId: "r").document == nil)
    }

    private static func writePDF(pages: [String], to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for text in pages {
            ctx.beginPDFPage(nil)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            (text as NSString).draw(at: CGPoint(x: 20, y: 200), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    // MARK: - Greeting + cat

    static func greetingChecks(_ c: CompanionSelfTest.Checker) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        func at(_ h: Int, _ day: Int = 29) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: 10))! }
        c.check("greets at 5am", MorningGreeting.isEligible(now: at(5), lastGreetedDay: nil, calendar: cal))
        c.check("greets at 11am", MorningGreeting.isEligible(now: at(11), lastGreetedDay: "2026-09-28", calendar: cal))
        c.check("not at 4am", !MorningGreeting.isEligible(now: at(4), lastGreetedDay: nil, calendar: cal))
        c.check("not at noon", !MorningGreeting.isEligible(now: at(12), lastGreetedDay: nil, calendar: cal))
        c.check("once per day", !MorningGreeting.isEligible(now: at(9), lastGreetedDay: "2026-09-29", calendar: cal))
        c.check("next day again", MorningGreeting.isEligible(now: at(9, 30), lastGreetedDay: "2026-09-29", calendar: cal))
        c.check("blocked by always-on / mute / call", MorningGreeting.blockers(alwaysOnVoice: true, muted: true, quiet: true, busy: false, onboarding: false).count == 3)
        c.check("clear when nothing blocks", MorningGreeting.blockers(alwaysOnVoice: false, muted: false, quiet: false, busy: false, onboarding: false).isEmpty)
        c.check("8 lowercase lines", MorningGreeting.lines.count == 8 && MorningGreeting.lines.allSatisfy { $0 == $0.lowercased() && $0.count < 80 })
        c.check("line stable within a day", MorningGreeting.line(for: at(6), calendar: cal) == MorningGreeting.line(for: at(11), calendar: cal))
        c.check("line changes day to day", MorningGreeting.line(for: at(6), calendar: cal) != MorningGreeting.line(for: at(6, 30), calendar: cal))
    }

    static func catChecks(_ c: CompanionSelfTest.Checker) {
        let frames = [PixelCat.frame(pose: .idle), PixelCat.frame(pose: .sit)] + (0..<4).map { PixelCat.frame(pose: .walk, step: $0) }
        c.check("cat frames are 16×12", frames.allSatisfy { $0.count == 12 && $0.allSatisfy { $0.count == 16 } })
        c.check("idle has lime eyes, blink closes them", PixelCat.frame(pose: .idle).joined().contains("e") && !PixelCat.frame(pose: .idle, blink: true).joined().contains("e"))
        c.check("walk cycle moves the legs", Set((0..<4).map { PixelCat.frame(pose: .walk, step: $0).suffix(2).joined() }).count >= 2)
        c.check("tail swish differs", PixelCat.frame(pose: .idle, tailUp: true) != PixelCat.frame(pose: .idle, tailUp: false))
    }

    // MARK: - Realtime

    nonisolated static func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    static func realtimeCodecChecks(_ c: CompanionSelfTest.Checker) {
        let upd = json(RealtimeCodec.sessionUpdate(voice: "cedar"))
        let session = upd["session"] as? [String: Any]
        let audio = session?["audio"] as? [String: Any]
        let input = audio?["input"] as? [String: Any]
        let output = audio?["output"] as? [String: Any]
        c.check("session.update type", upd["type"] as? String == "session.update" && session?["type"] as? String == "realtime")
        c.check("push-to-talk: server VAD off", input?.keys.contains("turn_detection") == true && input?["turn_detection"] is NSNull)
        c.check("PCM16 24 kHz both ways", (input?["format"] as? [String: Any])?["rate"] as? Int == 24000 && (output?["format"] as? [String: Any])?["type"] as? String == "audio/pcm")
        c.check("voice set", output?["voice"] as? String == "cedar")
        let tool = (session?["tools"] as? [[String: Any]])?.first
        c.check("show_on_screen tool offered", tool?["name"] as? String == "show_on_screen" && tool?["type"] as? String == "function")

        let pcm = Data((0..<480).map { UInt8($0 % 256) })
        let app = json(RealtimeCodec.appendAudio(pcm))
        c.check("append audio base64 round-trips", app["type"] as? String == "input_audio_buffer.append" && Data(base64Encoded: app["audio"] as? String ?? "") == pcm)
        c.check("commit / response.create / cancel", json(RealtimeCodec.commit())["type"] as? String == "input_audio_buffer.commit"
            && json(RealtimeCodec.responseCreate())["type"] as? String == "response.create" && json(RealtimeCodec.responseCancel())["type"] as? String == "response.cancel")

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let turn = json(RealtimeCodec.userTurn(images: [(label: "screen 1 of 1", jpeg: jpeg)], texts: ["<document name=\"a\">x</document>"]))
        let content = ((turn["item"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        c.check("turn = user message", turn["type"] as? String == "conversation.item.create" && (turn["item"] as? [String: Any])?["role"] as? String == "user")
        c.check("document text first, then label + image", content.count == 3 && content[0]["type"] as? String == "input_text" && content[1]["text"] as? String == "screen 1 of 1")
        c.check("screenshot as input_image data URL", content.last?["type"] as? String == "input_image" && content.last?["image_url"] as? String == "data:image/jpeg;base64,\(jpeg.base64EncodedString())")
        let fo = json(RealtimeCodec.functionOutput(callId: "call_1", output: "shown"))
        c.check("function output item", (fo["item"] as? [String: Any])?["call_id"] as? String == "call_1")

        c.check("decode GA audio delta", RealtimeCodec.decode(#"{"type":"response.output_audio.delta","delta":"\#(pcm.base64EncodedString())"}"#) == .audioDelta(pcm))
        c.check("decode beta audio delta", RealtimeCodec.decode(#"{"type":"response.audio.delta","delta":"AAA="}"#) == .audioDelta(Data([0, 0])))
        c.check("decode transcript delta (GA + beta)", RealtimeCodec.decode(#"{"type":"response.output_audio_transcript.delta","delta":"hi "}"#) == .transcriptDelta("hi ")
            && RealtimeCodec.decode(#"{"type":"response.audio_transcript.delta","delta":"yo"}"#) == .transcriptDelta("yo"))
        c.check("decode transcript done", RealtimeCodec.decode(#"{"type":"response.output_audio_transcript.done","transcript":"all of it"}"#) == .transcriptDone("all of it"))
        c.check("decode function call", RealtimeCodec.decode(#"{"type":"response.function_call_arguments.done","name":"show_on_screen","call_id":"c9","arguments":"{\"tags\":\"[POINT:1,2:x]\"}"}"#)
            == .functionCall(name: "show_on_screen", callId: "c9", arguments: #"{"tags":"[POINT:1,2:x]"}"#))
        c.check("tags argument", RealtimeCodec.tagsArgument(#"{"tags":"[POINT:1,2:x]"}"#) == "[POINT:1,2:x]" && RealtimeCodec.tagsArgument("nope") == nil)
        c.check("decode input transcription", RealtimeCodec.decode(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"where is export"}"#) == .inputTranscript("where is export"))
        c.check("decode response.done / error / other", RealtimeCodec.decode(#"{"type":"response.done","response":{}}"#) == .responseDone
            && RealtimeCodec.decode(#"{"type":"error","error":{"message":"bad"}}"#) == .error("bad")
            && RealtimeCodec.decode(#"{"type":"rate_limits.updated"}"#) == .other("rate_limits.updated"))
        c.check("secret: GA shape", RealtimeCodec.decodeSecret(Data(#"{"value":"ek_1","expires_at":1,"session":{"model":"gpt-realtime-2"}}"#.utf8)) == RealtimeSecret(value: "ek_1", model: "gpt-realtime-2"))
        c.check("secret: beta shape", RealtimeCodec.decodeSecret(Data(#"{"client_secret":{"value":"ek_2"}}"#.utf8)) == RealtimeSecret(value: "ek_2", model: RealtimeCodec.defaultModel))
        c.check("secret: 501 body → nil", RealtimeCodec.decodeSecret(Data(#"{"error":"realtime_unavailable","fallback":"pipeline"}"#.utf8)) == nil)
        c.check("wss URL", RealtimeCodec.url(model: "gpt-realtime").absoluteString == "wss://api.openai.com/v1/realtime?model=gpt-realtime")

        // Mic conversion: 48 kHz float → 24 kHz PCM16 (half the frames, 2 bytes each).
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800)!
        buf.frameLength = 4800
        for i in 0 ..< 4800 { buf.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.5 }
        let feeder = RealtimeAudioFeeder()
        var sent: [String] = []
        feeder.append(buf)                          // before the socket is up → buffered
        feeder.attach { sent.append($0) }           // flushed on attach
        feeder.append(buf)                          // live
        let bytes = sent.compactMap { Data(base64Encoded: json($0)["audio"] as? String ?? "") }.reduce(0) { $0 + $1.count }
        c.check("feeder buffers until attached, then streams", sent.count >= 2 && sent.allSatisfy { json($0)["type"] as? String == "input_audio_buffer.append" }, "\(sent.count)")
        c.check("48 kHz → 24 kHz PCM16 (~2 × 2400 frames × 2 bytes, less resampler latency)", bytes > 8400 && bytes <= 9700 && bytes % 2 == 0, "\(bytes)")
    }

    final class FakeTransport: RealtimeTransport {
        var onMessage: ((String) -> Void)?
        var onClose: ((Error?) -> Void)?
        var sent: [String] = []
        var connectedURL: URL?
        var headers: [String: String] = [:]
        func connect(url: URL, headers: [String: String]) { connectedURL = url; self.headers = headers }
        func send(_ text: String) { sent.append(text) }
        func close() {}
        var types: [String] { sent.compactMap { CompanionExtrasSelfTest.json($0)["type"] as? String } }
    }

    static func realtimeSessionChecks(_ c: CompanionSelfTest.Checker) {
        let session = RealtimeVoiceSession()
        let fake = FakeTransport()
        session.transportFactory = { fake }
        session.minter = { RealtimeSecret(value: "ek_test", model: "gpt-realtime") }

        var events: [RealtimeServerEvent] = []
        var finished = false
        Task { @MainActor in
            session.beginTurn()
            try? await Task.sleep(for: .milliseconds(30))
            session.feeder.append(pcm16: Data(repeating: 1, count: 960))
            let stream = session.finishTurn(images: [(label: "screen 1 of 1", jpeg: Data([0xFF, 0xD8]))], texts: [], context: "[current local time: now]")
            try? await Task.sleep(for: .milliseconds(30))
            // The server answers: audio, words, a tool call with tags, done.
            session.handle(#"{"type":"response.output_audio.delta","delta":"AAECAw=="}"#)
            session.handle(#"{"type":"response.output_audio_transcript.delta","delta":"open the file menu. "}"#)
            session.handle(#"{"type":"response.function_call_arguments.done","name":"show_on_screen","call_id":"c1","arguments":"{\"tags\":\"[POINT:40,12:file menu] [IMAGES:file menu icons]\"}"}"#)
            session.handle(#"{"type":"response.output_audio_transcript.done","transcript":"open the file menu."}"#)
            session.handle(#"{"type":"response.done"}"#)
            do { for try await e in stream { events.append(e) } } catch {}
            finished = true
        }
        let deadline = Date().addingTimeInterval(3)
        while !finished, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }

        c.check("session connects with the ephemeral secret", fake.connectedURL?.absoluteString.contains("model=gpt-realtime") == true && fake.headers["Authorization"] == "Bearer ek_test")
        let t = fake.types
        c.check("configures the session first", t.first == "session.update", "\(t)")
        c.check("streams the mic between clear and commit", (t.firstIndex(of: "input_audio_buffer.clear") ?? 99) < (t.firstIndex(of: "input_audio_buffer.append") ?? -1)
            && (t.firstIndex(of: "input_audio_buffer.append") ?? 99) < (t.firstIndex(of: "input_audio_buffer.commit") ?? -1), "\(t)")
        c.check("commit → screenshots item → response.create", (t.firstIndex(of: "input_audio_buffer.commit") ?? 99) < (t.lastIndex(of: "conversation.item.create") ?? -1)
            && t.contains("response.create"), "\(t)")
        c.check("context sent once, with the first turn", fake.sent.contains { $0.contains("context about the user") })
        c.check("tool call acknowledged", fake.sent.contains { $0.contains("function_call_output") && $0.contains("c1") })
        c.check("turn ends on response.done", finished && events.last == .responseDone, "\(events)")
        c.check("audio + transcript + tool call delivered", events.contains(.audioDelta(Data([0, 1, 2, 3]))) && events.contains(.transcriptDelta("open the file menu. "))
            && events.contains { if case .functionCall = $0 { return true } else { return false } })

        let reply = CompanionEngine.realtimeReply(transcript: "open the file menu.", toolTags: ["[POINT:40,12:file menu] [IMAGES:file menu icons]"])
        c.check("realtime reply = transcript + tool tags", reply.spokenText == "open the file menu." && reply.points.count == 1 && reply.imagesQuery == "file menu icons", "\(reply)")
        c.check("tool tags anchor at the end of the speech", reply.points.first?.spokenOffset == reply.spokenText.count)

        // A dropped socket mid-turn fails the turn (the engine then says so and the pipeline stays available).
        let fake2 = FakeTransport()
        let s2 = RealtimeVoiceSession()
        s2.transportFactory = { fake2 }
        s2.minter = { RealtimeSecret(value: "ek", model: "gpt-realtime") }
        var failed = false
        var done2 = false
        Task { @MainActor in
            let stream = s2.finishTurn(images: [], texts: [], context: nil)
            try? await Task.sleep(for: .milliseconds(30))
            fake2.onClose?(URLError(.networkConnectionLost))
            do { for try await _ in stream {} } catch { failed = true }
            done2 = true
        }
        let d2 = Date().addingTimeInterval(3)
        while !done2, Date() < d2 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        c.check("dropped connection fails the turn", failed && !s2.isConnected)

        // A server without realtime (501) marks the path failed for this launch.
        let s3 = RealtimeVoiceSession()
        s3.minter = { throw APIError.server(501, "realtime_unavailable") }
        var threw = false
        var done3 = false
        Task { @MainActor in
            do { try await s3.prepare() } catch { threw = true }
            done3 = true
        }
        let d3 = Date().addingTimeInterval(3)
        while !done3, Date() < d3 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        c.check("501 from the server → pipeline for this launch", threw && s3.failedThisLaunch)
    }
}
