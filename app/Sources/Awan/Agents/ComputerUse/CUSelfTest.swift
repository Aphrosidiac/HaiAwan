import AppKit

/// Command-line self-tests for the computer-use server and the connector store. Wired from `Main`:
///   Awan --computer-use-selftest [--open-finder]   real HTTP MCP calls against the in-process server
///   Awan --computer-use-serve [--approve] [--probe-window]
///                                                  run the server and print {"url","token"} (for curl / codex)
///   Awan --connector-selftest                      mcpServersTOML / mcpEnvironment shape checks (no network)
///   Awan --skills-selftest [<dir>]                 install bundled skills into <dir> (default: a temp dir) and check them
@MainActor
enum AgentSelfTests {
    static let flags = ["--computer-use-selftest", "--computer-use-serve", "--connector-selftest", "--skills-selftest"]

    static func handles(_ args: [String]) -> Bool { args.contains { flags.contains($0) } }

    /// Runs the requested test on a live AppKit run loop (AX on our own windows needs it) and exits.
    static func run(_ args: [String]) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let code: Int32
            if args.contains("--connector-selftest") { code = await connectorSelfTest() }
            else if args.contains("--skills-selftest") { code = skillsSelfTest(args) }
            else if args.contains("--computer-use-serve") { await serve(args); code = 0 }
            else { code = await computerUseSelfTest(args) }
            exit(code)
        }
        app.run()
        exit(0)
    }

    // MARK: Reporting

    private static var failures = 0
    private static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail().isEmpty ? "" : " — " + detail())")
    }
    private static func info(_ s: String) { print("INFO  \(s)") }
    private static func skip(_ name: String, _ why: String) { print("SKIP  \(name) — \(why)") }

    // MARK: MCP client

    private struct Reply {
        var status: Int
        var json: [String: Any]?
        var headers: [AnyHashable: Any]
        var result: [String: Any]? { json?["result"] as? [String: Any] }
        var text: String { ((result?["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String) ?? "" }
        var isError: Bool { (result?["isError"] as? Bool) ?? false }
        var structured: [String: Any]? { result?["structuredContent"] as? [String: Any] }
        var images: [[String: Any]] { ((result?["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "image" } }
    }

    private static var nextID = 1

    private static func post(_ url: URL, token: String?, _ body: [String: Any]) async -> Reply {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else {
            return Reply(status: -1, json: nil, headers: [:])
        }
        return Reply(status: http.statusCode, json: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], headers: http.allHeaderFields)
    }

    private static func rpc(_ url: URL, _ token: String, _ method: String, _ params: [String: Any] = [:]) async -> Reply {
        nextID += 1
        return await post(url, token: token, ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params])
    }

    private static func tool(_ url: URL, _ token: String, _ name: String, _ args: [String: Any] = [:]) async -> Reply {
        await rpc(url, token, "tools/call", ["name": name, "arguments": args])
    }

    // MARK: Probe window (our own process, so AX works even without Accessibility permission)

    @MainActor final class Probe: NSObject {
        var presses = 0
        let window: NSWindow
        let button: NSButton
        let field: NSTextField
        let checkbox: NSButton
        let scroll: NSScrollView

        override init() {
            window = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 460, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Awan Probe"
            window.isReleasedWhenClosed = false
            button = NSButton(title: "Increment", target: nil, action: nil)
            field = NSTextField(string: "")
            field.placeholderString = "Probe field"
            checkbox = NSButton(checkboxWithTitle: "Probe option", target: nil, action: nil)
            scroll = NSTextView.scrollableTextView()
            super.init()
            button.target = self
            button.action = #selector(pressed(_:))
            button.frame = NSRect(x: 20, y: 290, width: 140, height: 32)
            field.frame = NSRect(x: 180, y: 294, width: 250, height: 24)
            checkbox.frame = NSRect(x: 20, y: 256, width: 200, height: 22)
            scroll.frame = NSRect(x: 20, y: 20, width: 420, height: 220)
            if let tv = scroll.documentView as? NSTextView {
                tv.string = (1 ... 400).map { "Line \($0) of the probe document." }.joined(separator: "\n")
                tv.setAccessibilityLabel("Probe document")
            }
            for v in [button, field, checkbox, scroll] as [NSView] { window.contentView?.addSubview(v) }
            window.orderFrontRegardless()
        }

        @objc func pressed(_ sender: Any?) { presses += 1 }
    }

    private static func token(in text: String, containing label: String) -> String? {
        for line in text.split(separator: "\n") where line.contains(label) {
            if let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]"), open < close {
                return String(line[line.index(after: open) ..< close])
            }
        }
        return nil
    }

    // MARK: --computer-use-selftest

    static func computerUseSelfTest(_ args: [String]) async -> Int32 {
        let server = ComputerUseServer.shared
        let up = await server.ensureRunning()
        check(up, "server starts", server.endpoint?.absoluteString ?? "no endpoint")
        guard up, let url = server.endpoint else { return 1 }
        let tok = server.token

        // Transport and auth
        let unauth = await post(url, token: nil, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        check(unauth.status == 401, "no bearer token → 401", "got \(unauth.status)")
        let wrong = await post(url, token: "nope", ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        check(wrong.status == 401, "wrong bearer token → 401", "got \(wrong.status)")
        let initR = await rpc(url, tok, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
                                                     "clientInfo": ["name": "selftest", "version": "1"]])
        let serverName = (initR.result?["serverInfo"] as? [String: Any])?["name"] as? String
        check(initR.status == 200 && serverName == "awan-computer-use", "initialize", "status \(initR.status), server \(serverName ?? "?"), protocol \(initR.result?["protocolVersion"] ?? "?"), session \(initR.headers["Mcp-Session-Id"] != nil)")
        let note = await post(url, token: tok, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        check(note.status == 202, "notifications/initialized → 202", "got \(note.status)")
        let list = await rpc(url, tok, "tools/list")
        let names = ((list.result?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        check(Set(names) == Set(server.enabledTools), "tools/list", "\(names.count) tools: \(names.joined(separator: ", "))")

        // Observation on real apps
        let perms = await tool(url, tok, "check_permissions")
        info("check_permissions → \(perms.text)")
        let apps = await tool(url, tok, "list_apps")
        let running = (apps.structured?["running"] as? [[String: Any]]) ?? []
        let finder = running.first { $0["bundle_id"] as? String == "com.apple.finder" }
        check(!running.isEmpty && finder != nil, "list_apps", "\(running.count) running apps, Finder pid \(finder?["pid"] ?? "?")")
        if let fpid = finder?["pid"] as? Int {
            if args.contains("--open-finder") {
                server.setApproval(threadID: "selftest-finder", approved: true)
                let l = await tool(url, tok, "launch_app", ["bundle_id": "com.apple.finder", "urls": [NSTemporaryDirectory()]])
                check(!l.isError, "launch_app Finder (background)", String(l.text.prefix(240)))
                server.setApproval(threadID: "selftest-finder", approved: false)
            }
            let fw = await tool(url, tok, "list_windows", ["pid": fpid])
            let fwins = (fw.structured?["windows"] as? [[String: Any]]) ?? []
            check(!fw.isError, "list_windows Finder", "\(fwins.count) windows \(fwins.map { "\($0["window_id"] ?? "?") \"\($0["title"] ?? "")\"" }.joined(separator: ", "))")
            let fs = await tool(url, tok, "get_window_state", ["pid": fpid, "max_elements": 60])
            let head = fs.text.split(separator: "\n").prefix(14).joined(separator: "\n      ")
            check(fs.status == 200 && !fs.text.isEmpty, "get_window_state Finder (answers; tree needs Accessibility)", "\n      \(head)")
            info("Finder snapshot: \(fs.structured?["element_count"] ?? 0) elements, screenshot \(fs.structured?["screenshot_width"] ?? "none")×\(fs.structured?["screenshot_height"] ?? "")")
            if args.contains("--open-finder"), let wid = fwins.first?["window_id"] as? Int {
                server.setApproval(threadID: "selftest-finder", approved: true)
                _ = await tool(url, tok, "hotkey", ["window_id": wid, "keys": ["cmd", "w"], "delivery_mode": "background"])
                server.setApproval(threadID: "selftest-finder", approved: false)
            }
        }

        // Full loop on our own probe window
        server.gate.allowSelfTargeting = true
        let probe = Probe()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let own = await tool(url, tok, "list_windows", ["pid": Int(getpid())])
        let wid = ((own.structured?["windows"] as? [[String: Any]]) ?? []).first { $0["title"] as? String == "Awan Probe" }?["window_id"] as? Int
        check(wid != nil, "list_windows finds the probe window", "window \(wid.map(String.init) ?? "missing")")
        guard let wid else { return 1 }
        var snap = await tool(url, tok, "get_window_state", ["window_id": wid])
        let firstSnapshot = snap.structured?["snapshot_id"] as? String ?? "s0"
        let bTok = token(in: snap.text, containing: "\"Increment\"")
        let fTok = token(in: snap.text, containing: "AXTextField")
        let cTok = token(in: snap.text, containing: "\"Probe option\"")
        let sTok = token(in: snap.text, containing: "AXScrollArea")
        let axLive = bTok != nil && fTok != nil && cTok != nil
        info("probe tree:\n      " + snap.text.split(separator: "\n").prefix(16).joined(separator: "\n      "))
        check(!snap.images.isEmpty, "get_window_state screenshot", "\(snap.structured?["screenshot_width"] ?? 0)×\(snap.structured?["screenshot_height"] ?? 0) JPEG, scale \(snap.structured?["screenshot_scale"] ?? "?")")
        if axLive {
            check(true, "get_window_state tree has element tokens", "button \(bTok!), field \(fTok!), checkbox \(cTok!), scroll \(sTok ?? "-")")
        } else {
            skip("AX element tests", "Accessibility isn't granted to this process (macOS answers even our own AX tree with a stub then)")
        }
        let f = probe.button.frame
        let scale = snap.structured?["screenshot_scale"] as? Double ?? 1
        let buttonPx: [String: Any] = ["window_id": wid, "x": Double(f.midX) * scale, "y": Double(probe.window.frame.height - f.midY) * scale,
                                       "delivery_mode": "background"]

        // Consent gate
        let refused = await tool(url, tok, "click", buttonPx)
        check(refused.isError && refused.text.contains("isn't approved") && probe.presses == 0, "input refused before approval", String(refused.text.prefix(90)))
        server.setApproval(threadID: "selftest", approved: true)
        let other = await rpc(url, tok, "tools/call", ["name": "scroll", "arguments": ["window_id": wid, "delivery_mode": "background"],
                                                       "_meta": ["threadId": "some-other-thread"]])
        check(other.isError && other.text.contains("isn't approved"), "approval is per thread (_meta.threadId from Codex)")
        let mine = await rpc(url, tok, "tools/call", ["name": "scroll", "arguments": ["window_id": wid, "delivery_mode": "background"],
                                                      "_meta": ["threadId": "selftest", "x-codex-turn-metadata": "{}"]])
        check(!mine.isError, "the approved thread's call goes through", String(mine.text.prefix(60)))

        // Background CGEvent paths (posting needs the event-posting grant, which comes with Accessibility)
        let canPost = CGPreflightPostEventAccess()
        if !canPost { skip("CGEvent effect checks", "this process may not post events (CGPreflightPostEventAccess = false); the calls still run and must not error") }
        func expect(_ ok: Bool, _ r: Reply, _ name: String, _ detail: String) {
            if canPost { check(!r.isError && ok, name, detail) } else { check(!r.isError, name + " (call accepted)", String(r.text.prefix(90))) }
        }
        let pc = await tool(url, tok, "click", buttonPx)
        try? await Task.sleep(nanoseconds: 300_000_000)
        expect(probe.presses == 1, pc, "pixel click → posted to pid, button fired", "presses=\(probe.presses) \(pc.text)")
        probe.window.makeFirstResponder(probe.field)
        let typedPid = await tool(url, tok, "type_text", ["window_id": wid, "text": "héllo 👋", "delivery_mode": "background"])
        try? await Task.sleep(nanoseconds: 300_000_000)
        let fieldNow = probe.field.currentEditor()?.string ?? probe.field.stringValue
        expect(fieldNow.contains("héllo 👋"), typedPid, "type_text to pid (unicode key events)", "field=\"\(fieldNow)\"")
        let bs = await tool(url, tok, "press_key", ["window_id": wid, "key": "backspace", "delivery_mode": "background"])
        try? await Task.sleep(nanoseconds: 200_000_000)
        let afterBS = probe.field.currentEditor()?.string ?? probe.field.stringValue
        expect(afterBS.count == fieldNow.count - 1, bs, "press_key backspace to pid", "field=\"\(afterBS)\"")
        let selAll = await tool(url, tok, "hotkey", ["window_id": wid, "keys": ["cmd", "a"], "delivery_mode": "background"])
        try? await Task.sleep(nanoseconds: 200_000_000)
        let selLen = probe.field.currentEditor()?.selectedRange.length ?? 0
        expect(selLen == afterBS.utf16.count && selLen > 0, selAll, "hotkey cmd+A to pid selects the field", "selected \(selLen) of \(afterBS.utf16.count)")
        let sf = probe.scroll.frame
        let sc = await tool(url, tok, "scroll", ["window_id": wid, "x": Double(sf.midX) * scale, "y": Double(probe.window.frame.height - sf.midY) * scale,
                                                 "direction": "down", "amount": 8, "delivery_mode": "background"])
        try? await Task.sleep(nanoseconds: 400_000_000)
        let y0 = probe.scroll.contentView.bounds.origin.y
        expect(y0 > 0, sc, "scroll wheel to pid at window x,y", "offset.y=\(Int(y0))")
        let pressesAfterEvents = probe.presses

        // AX element paths
        if axLive, let bTok, let fTok, let cTok {
            let clicked = await tool(url, tok, "click", ["element_token": bTok, "delivery_mode": "background"])
            check(!clicked.isError && probe.presses == pressesAfterEvents + 1, "click by element token (AXPress)", "presses=\(probe.presses) \(clicked.text)")
            let setV = await tool(url, tok, "set_value", ["element_token": fTok, "value": "hello"])
            check(!setV.isError && probe.field.stringValue == "hello", "set_value text field", "field=\"\(probe.field.stringValue)\" \(setV.text)")
            let typed = await tool(url, tok, "type_text", ["element_token": fTok, "text": " world", "delivery_mode": "background"])
            check(!typed.isError && probe.field.stringValue.contains("world"), "type_text into element", "field=\"\(probe.field.stringValue)\" \(typed.text)")
            let cb = await tool(url, tok, "set_value", ["element_token": cTok, "value": true])
            check(!cb.isError && probe.checkbox.state == .on, "set_value checkbox", "state=\(probe.checkbox.state.rawValue) \(cb.text)")
            let cbClick = await tool(url, tok, "click", ["element_token": cTok, "delivery_mode": "background"])
            check(!cbClick.isError && probe.checkbox.state == .off && cbClick.text.contains("confirmed"), "click checkbox (verified effect)", cbClick.text)
            if let sTok {
                let before = probe.scroll.contentView.bounds.origin.y
                let s = await tool(url, tok, "scroll", ["element_token": sTok, "direction": "down", "amount": 5, "delivery_mode": "background"])
                check(!s.isError && probe.scroll.contentView.bounds.origin.y > before, "scroll via AX scroll bar", s.text)
            }
            let q = await tool(url, tok, "get_window_state", ["window_id": wid, "query": "increment", "include_screenshot": false])
            check((q.structured?["element_count"] as? Int) == 1, "get_window_state query filter", q.text.split(separator: "\n").last.map(String.init) ?? "")
            let text = await tool(url, tok, "page", ["window_id": wid, "action": "get_text"])
            check(!text.isError && ((text.structured?["text"] as? String) ?? "").contains("Line 1 of the probe"), "page get_text (AX)")
        }

        // Policy
        for (label, name, a) in [
            ("hotkey cmd+L refused", "hotkey", ["window_id": wid, "keys": ["cmd", "l"], "delivery_mode": "background"] as [String: Any]),
            ("hotkey ctrl+L refused", "hotkey", ["window_id": wid, "keys": ["ctrl", "L"], "delivery_mode": "background"]),
            ("hotkey cmd+shift+G refused", "hotkey", ["window_id": wid, "keys": ["cmd", "shift", "g"], "delivery_mode": "background"]),
            ("hotkey cmd+2 refused", "hotkey", ["window_id": wid, "keys": ["cmd", "2"], "delivery_mode": "background"]),
            ("hotkey cmd+] refused", "hotkey", ["window_id": wid, "keys": ["cmd", "shift", "]"], "delivery_mode": "background"]),
            ("hotkey cmd+option+right refused", "hotkey", ["window_id": wid, "keys": ["cmd", "option", "right"], "delivery_mode": "background"]),
            ("hotkey ctrl+tab refused", "hotkey", ["window_id": wid, "keys": ["ctrl", "tab"], "delivery_mode": "background"]),
            ("hotkey cmd+tab refused", "hotkey", ["window_id": wid, "keys": ["cmd", "tab"], "delivery_mode": "background"]),
            ("press_key cmd+l refused", "press_key", ["window_id": wid, "key": "cmd+l", "delivery_mode": "background"]),
            ("press_key l + modifiers [cmd] refused", "press_key", ["window_id": wid, "key": "l", "modifiers": ["cmd"], "delivery_mode": "background"]),
            ("foreground delivery refused", "click", buttonPx.merging(["delivery_mode": "foreground"]) { $1 }),
            ("desktop scope refused", "click", ["x": 10, "y": 10, "scope": "desktop", "delivery_mode": "background"]),
        ] {
            let r = await tool(url, tok, name, a)
            check(r.isError && r.text.contains("refused"), label, String(r.text.prefix(70)))
        }
        let outside = await tool(url, tok, "click", ["window_id": wid, "x": 99_999, "y": 5, "delivery_mode": "background"])
        check(outside.isError && outside.text.contains("outside"), "pixel outside the window refused", String(outside.text.prefix(70)))

        // Stale tokens fail closed after a re-snapshot
        snap = await tool(url, tok, "get_window_state", ["window_id": wid, "include_screenshot": false])
        let stale = await tool(url, tok, "click", ["element_token": (bTok ?? "\(firstSnapshot)e0"), "delivery_mode": "background"])
        check(stale.isError && stale.text.contains("stale"), "old token is stale after re-snapshot", String(stale.text.prefix(100)))
        let bogus = await tool(url, tok, "click", ["element_token": "banana", "delivery_mode": "background"])
        check(bogus.isError && bogus.text.contains("isn't an element token"), "malformed token rejected")

        let page = await tool(url, tok, "page", ["window_id": wid])
        let pngData = (page.images.first?["data"] as? String).flatMap { Data(base64Encoded: $0) }
        check(!page.isError && (pngData?.starts(with: [0x89, 0x50, 0x4E, 0x47]) ?? false), "page screenshot (ScreenCaptureKit PNG)",
              page.isError ? page.text : "\(pngData?.count ?? 0) bytes, \(page.structured?["width"] ?? 0)×\(page.structured?["height"] ?? 0)")
        if let pngData { try? pngData.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "awan-probe-page.png")); info("wrote \(NSTemporaryDirectory())awan-probe-page.png") }
        let js = await tool(url, tok, "page", ["window_id": wid, "action": "execute_javascript", "javascript": "1"])
        check(js.isError, "page execute_javascript refuses non-browsers", String(js.text.prefix(80)))

        let size = await tool(url, tok, "get_screen_size")
        info("get_screen_size → \(size.text)")
        let cfg = await tool(url, tok, "get_config")
        check(!cfg.isError, "get_config", String(cfg.text.prefix(100)) + "…")
        let health = await tool(url, tok, "health_report")
        check(!health.isError, "health_report", health.text)

        server.setApproval(threadID: "selftest", approved: false)
        let pressesBefore = probe.presses
        let after = await tool(url, tok, "click", buttonPx)
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(after.isError && after.text.contains("isn't approved") && probe.presses == pressesBefore, "approval revoked → refused again")
        server.gate.allowSelfTargeting = false
        server.setApproval(threadID: "selftest", approved: true)
        let selfBlocked = await tool(url, tok, "click", buttonPx)
        check(selfBlocked.isError && selfBlocked.text.contains("off-limits"), "Awan's own windows are off-limits in production", String(selfBlocked.text.prefix(70)))
        server.setApproval(threadID: "selftest", approved: false)

        let unknown = await rpc(url, tok, "bogus/method")
        check((unknown.json?["error"] as? [String: Any])?["code"] as? Int == -32601, "unknown method → -32601")
        probe.window.close()
        print("\n\(failures == 0 ? "ALL PASS" : "\(failures) FAILED")")
        return failures == 0 ? 0 : 1
    }

    // MARK: --computer-use-serve

    private static var keptProbe: Probe?

    static func serve(_ args: [String]) async {
        let server = ComputerUseServer.shared
        guard await server.ensureRunning(), let url = server.endpoint else { print("{\"error\":\"server failed\"}"); exit(1) }
        if args.contains("--approve") { server.setApproval(threadID: "serve", approved: true) }
        if args.contains("--probe-window") { server.gate.allowSelfTargeting = true; keptProbe = Probe() }
        print("{\"url\":\"\(url.absoluteString)\",\"token\":\"\(server.token)\",\"pid\":\(getpid())}")
        fflush(stdout)
        while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }

    // MARK: --skills-selftest

    static func skillsSelfTest(_ args: [String]) -> Int32 {
        let expected = ["awan-artifacts", "awan-build-preview", "awan-creative-studio", "awan-dev-setup-doctor", "awan-email-assistant",
                        "awan-google-workspace", "awan-repo-operator", "awan-research-report", "computer-use", "doc", "frontend-design",
                        "obsidian", "pdf", "spreadsheet", "web-deploy"]
        check(SkillLibrary.bundledNames == expected, "15 bundled skills", SkillLibrary.bundledNames.joined(separator: ", "))
        let i = args.firstIndex(of: "--skills-selftest")!
        let dir = args.count > i + 1 && !args[i + 1].hasPrefix("--")
            ? URL(fileURLWithPath: args[i + 1], isDirectory: true)
            : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("awan-skills-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("my-own-skill"), withIntermediateDirectories: true)
        try? "---\nname: my-own-skill\ndescription: user skill\n---\n".write(to: dir.appendingPathComponent("my-own-skill/SKILL.md"), atomically: true, encoding: .utf8)

        let folders = SkillLibrary.install(into: dir)
        let firstCopy = SkillLibrary.lastCopiedCount
        check(folders.count == 15 && firstCopy >= 15, "install copies every skill", "\(folders.count) folders, \(firstCopy) files → \(dir.path)")
        for f in folders {
            let fm = SkillLibrary.frontMatter(of: f.appendingPathComponent("SKILL.md"))
            let desc = fm?["description"] ?? ""
            check(fm?["name"] == f.lastPathComponent && !desc.isEmpty && desc.count <= 1024,
                  "front matter \(f.lastPathComponent)", "\(desc.count) chars")
        }
        SkillLibrary.install(into: dir)
        check(SkillLibrary.lastCopiedCount == 0, "second install copies nothing", "\(SkillLibrary.lastCopiedCount) files")
        let stale = dir.appendingPathComponent("pdf/old-helper.py")
        try? "print(1)".write(to: stale, atomically: true, encoding: .utf8)
        try? "tampered".write(to: dir.appendingPathComponent("doc/SKILL.md"), atomically: true, encoding: .utf8)
        SkillLibrary.install(into: dir)
        check(SkillLibrary.lastCopiedCount == 2 && !FileManager.default.fileExists(atPath: stale.path), "changed files restored, stale files removed",
              "\(SkillLibrary.lastCopiedCount) files")
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("my-own-skill/SKILL.md").path), "user-added skills untouched")
        check(FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("doc/scripts/render_docx.sh").path), "script keeps its exec bit")
        let toml = SkillLibrary.configTOML(skillsDirectory: dir, obsidianEnabled: false)
        check(toml.components(separatedBy: "[[skills.config]]").count == 16 && toml.contains("obsidian/SKILL.md\"\nenabled = false") && toml.contains("pdf/SKILL.md\"\nenabled = true"),
              "configTOML: 15 entries, obsidian off without a vault")
        print(toml.split(separator: "\n").prefix(6).joined(separator: "\n"))

        // Active library skills (Skills page) → CodexHome/skills/awan-user/<slug>/SKILL.md
        let userSkills = [
            SkillLibrary.UserSkill(slug: "ui-critic", title: "UI Critic", oneLiner: "Names the \"three\" fixes that matter.", content: "You are a designer.\n\n## When to apply\n- Screens."),
            SkillLibrary.UserSkill(slug: "../escape", title: "Escape", oneLiner: "x", content: "y"),
        ]
        let userFiles = SkillLibrary.installUserSkills(userSkills, into: dir)
        let critic = SkillLibrary.frontMatter(of: userFiles[0])
        check(userFiles.count == 2 && critic?["name"] == "ui-critic" && (critic?["description"] ?? "").hasPrefix("UI Critic:"),
              "user skills written with front matter", userFiles.map(\.path).joined(separator: ", "))
        check(userFiles.allSatisfy { $0.path.hasPrefix(dir.appendingPathComponent(SkillLibrary.userFolder).path + "/") }, "user skill slugs can't escape awan-user/")
        let userToml = SkillLibrary.userSkillsConfigTOML(userFiles)
        check(userToml.components(separatedBy: "[[skills.config]]").count == 3 && userToml.contains("awan-user/ui-critic/SKILL.md\"\nenabled = true"), "user skills configTOML")
        SkillLibrary.installUserSkills([userSkills[0]], into: dir)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(SkillLibrary.userFolder).path)) ?? []
        check(left == ["ui-critic"], "switched-off skills are removed", left.joined(separator: ", "))
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("pdf/SKILL.md").path), "bundled skills untouched by user-skill sync")
        check(SkillsStore.validateSkillMarkdown("---\nname: a\ndescription: b\n---\nbody") == nil
              && SkillsStore.validateSkillMarkdown("no front matter") != nil
              && SkillsStore.validateSkillMarkdown("---\nname: a\n---\nbody") != nil
              && SkillsStore.validateSkillMarkdown("---\nname: a\ndescription: b\n---\n  ") != nil, "import front-matter validation")

        print("\n\(failures == 0 ? "ALL PASS" : "\(failures) FAILED")")
        return failures == 0 ? 0 : 1
    }

    // MARK: --connector-selftest

    static func connectorSelfTest() async -> Int32 {
        var secrets: [String: String] = [:]
        let suite = "awan.selftest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConnectorStore(directory: .some(nil), defaults: defaults)
        store.secretGet = { secrets[$0] }
        store.secretSet = { v, k in secrets[k] = v }

        // Seed connectors directly (no network): one remote OAuth, one remote with a key, one custom-header key,
        // one local stdio command with quoting, one that needs sign-in, one rejected, and Obsidian.
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        store.connectors = [
            Connector(id: "notion", name: "Notion", url: "https://mcp.notion.com/mcp", command: nil, auth: "oauth", status: "connected", addedAt: t0),
            Connector(id: "my-crm", name: "My CRM", url: "https://crm.example.com/mcp", command: nil, auth: "api_key", status: "connected", addedAt: t0 + 1),
            Connector(id: "acme", name: "Acme", url: "https://acme.example.com/mcp", command: nil, auth: "header:X-API-Key", status: "connected", addedAt: t0 + 2),
            Connector(id: "files", name: "Files", url: nil, command: "npx -y \"@scope/files server\" --root '/Users/me/My Docs'", auth: "api_key", status: "connected", addedAt: t0 + 3),
            Connector(id: "linear", name: "Linear", url: "https://mcp.linear.app/mcp", command: nil, auth: "oauth", status: "needsSignIn", addedAt: t0 + 4),
            Connector(id: "broken", name: "Broken", url: "https://broken.example.com/mcp", command: nil, auth: "api_key", status: "rejected", addedAt: t0 + 5),
        ]
        secrets["connector.my-crm"] = "sk-crm-secret"
        secrets["connector.acme"] = "acme-secret"
        secrets["connector.files"] = "files-secret"
        secrets["connector.broken"] = "broken-secret"
        let vault = NSTemporaryDirectory() + "awan-vault-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true)
        check(store.configureObsidian(vaultPath: vault), "configureObsidian accepts a folder")
        check(!store.configureObsidian(vaultPath: "/definitely/not/here"), "configureObsidian rejects a missing folder")

        let toml = store.mcpServersTOML()
        print("---- mcpServersTOML ----\n\(toml)------------------------")
        let expected = """
        [mcp_servers.notion]
        url = "https://mcp.notion.com/mcp"
        startup_timeout_sec = 20.0
        tool_timeout_sec = 120.0

        [mcp_servers.my-crm]
        url = "https://crm.example.com/mcp"
        bearer_token_env_var = "AWAN_MCP_MY_CRM_TOKEN"
        startup_timeout_sec = 20.0
        tool_timeout_sec = 120.0

        [mcp_servers.acme]
        url = "https://acme.example.com/mcp"
        env_http_headers = { "X-API-Key" = "AWAN_MCP_ACME_TOKEN" }
        startup_timeout_sec = 20.0
        tool_timeout_sec = 120.0

        [mcp_servers.files]
        command = "npx"
        args = ["-y", "@scope/files server", "--root", "/Users/me/My Docs"]
        env_vars = ["AWAN_MCP_FILES_TOKEN"]
        startup_timeout_sec = 20.0
        tool_timeout_sec = 120.0

        [mcp_servers.linear]
        url = "https://mcp.linear.app/mcp"
        startup_timeout_sec = 20.0
        tool_timeout_sec = 120.0


        """
        check(toml == expected, "mcpServersTOML exact shape")
        check(!toml.contains("secret"), "no secrets in the TOML")
        check(!toml.contains("broken"), "rejected connectors are left out")
        check(!toml.contains("obsidian"), "Obsidian is a skill, not an MCP server block")

        let env = store.mcpEnvironment()
        check(env["AWAN_MCP_MY_CRM_TOKEN"] == "sk-crm-secret" && env["AWAN_MCP_ACME_TOKEN"] == "acme-secret" && env["AWAN_MCP_FILES_TOKEN"] == "files-secret",
              "mcpEnvironment carries the keys", env.keys.sorted().joined(separator: ", "))
        check(env["AWAN_MCP_BROKEN_TOKEN"] == nil, "mcpEnvironment skips rejected connectors")
        check(env["OBSIDIAN_VAULT_PATH"] == vault, "mcpEnvironment sets OBSIDIAN_VAULT_PATH")
        check(env[ComputerUseServer.tokenEnvVar] == ComputerUseServer.shared.token, "mcpEnvironment carries the computer-use token")

        check(ConnectorStore.splitCommand("a 'b c' \"d\\\"e\" f\\ g") == ["a", "b c", "d\"e", "f g"], "splitCommand quoting")
        check(ConnectorStore.tomlString("a\"b\\c\nd") == "\"a\\\"b\\\\c\\nd\"", "tomlString escaping")
        check(ConnectorStore.envVar(for: "google-drive") == "AWAN_MCP_GOOGLE_DRIVE_TOKEN", "envVar naming")

        let instructions = store.integrationInstructions()
        check(instructions.contains("`notion`") && instructions.contains("Linear") && instructions.contains(vault), "integrationInstructions reflects state")
        print(instructions)

        // Live probe paths against local servers only (no third-party traffic).
        let cu = ComputerUseServer.shared
        if await cu.ensureRunning(), let ep = cu.endpoint {
            let noKey = await MCPProbe.http(url: ep)
            check(noKey == .needsAuth(challenge: "Bearer realm=\"awan-computer-use\""), "probe: 401 + WWW-Authenticate → needsAuth", "\(noKey)")
            let good = await MCPProbe.http(url: ep, headers: ["Authorization": "Bearer \(cu.token)"])
            check(good == .ok(server: "awan-computer-use"), "probe: valid bearer → ok", "\(good)")
            await store.addCustom(name: "Local CU", url: ep.absoluteString, command: nil, auth: "api_key", apiKey: "wrong-key")
            check(store.connectors.first { $0.id == "local-cu" }?.status == "rejected" && store.details["local-cu"] == "Token rejected",
                  "addCustom with a bad key → Token rejected", store.details["local-cu"] ?? "")
            await store.addCustom(name: "Local CU", url: ep.absoluteString, command: nil, auth: "api_key", apiKey: cu.token)
            check(store.isConnected("local-cu"), "addCustom with the right key → connected", store.details["local-cu"] ?? "")
            await store.addCustom(name: "Local CU", url: ep.absoluteString, command: nil, auth: "oauth", apiKey: nil)
            check(store.connectors.first { $0.id == "local-cu" }?.status == "needsSignIn", "addCustom oauth without token → needsSignIn")
        }
        let dead = await MCPProbe.http(url: URL(string: "http://127.0.0.1:9/mcp")!, timeout: 3)
        if case .unreachable = dead { check(true, "probe: closed port → unreachable") } else { check(false, "probe: closed port → unreachable", "\(dead)") }
        await store.addCustom(name: "Echo", url: nil, command: "/bin/cat", auth: "none", apiKey: nil)
        info("stdio probe with /bin/cat (echoes the request, no result) → \(store.connectors.first { $0.id == "echo" }?.status ?? "?") — \(store.details["echo"] ?? "")")
        await store.disconnect("my-crm")
        check(secrets["connector.my-crm"] == nil && !store.connectors.contains { $0.id == "my-crm" }, "disconnect removes the connector and its key")

        try? FileManager.default.removeItem(atPath: vault)

        // Awan-hosted Google toolkits (auth "awan-google"): no network — the consent round trip is simulated
        // through the awan://connectors URL the server's callback page opens.
        let g = ConnectorStore(directory: .some(nil), defaults: defaults)
        g.secretGet = { secrets[$0] }
        g.secretSet = { v, k in secrets[k] = v }
        g.awanAPIBase = { "https://api.awan.test/" }
        var opened: [URL] = []
        g.openURL = { opened.append($0) }
        let toast = g.handleConnectorsURL(URL(string: "awan://connectors?connected=gmail%2Cgoogle-sheets&missing=google-docs&email=fakhrul%40example.com")!)
        check(g.isConnected("gmail") && g.isConnected("google-sheets"), "awan://connectors marks granted toolkits connected")
        check(g.connectors.first { $0.id == "google-docs" }?.status == "needsSignIn", "a toolkit Google didn't grant waits for Connect")
        check(g.details["gmail"] == "Connected as fakhrul@example.com", "connected detail names the Google account", g.details["gmail"] ?? "")
        check(toast.hasPrefix("Gmail, Google Sheets connected"), "toast names what connected", toast)
        let gToml = g.mcpServersTOML()
        print("---- awan-google mcpServersTOML ----\n\(gToml)------------------------")
        let gExpected = """
        [mcp_servers.gmail]
        url = "https://api.awan.test/mcp/gmail"
        bearer_token_env_var = "AWAN_AGENT_TOKEN"
        startup_timeout_sec = 20.0
        tool_timeout_sec = 120.0

        [mcp_servers.google-sheets]
        url = "https://api.awan.test/mcp/google-sheets"
        bearer_token_env_var = "AWAN_AGENT_TOKEN"
        startup_timeout_sec = 20.0
        tool_timeout_sec = 120.0


        """
        check(gToml == gExpected, "awan-google TOML: hosted URL + the Awan token env var, only when connected")
        check(g.mcpEnvironment().keys.allSatisfy { !$0.hasPrefix("AWAN_MCP_GMAIL") }, "no per-connector key for Awan-hosted toolkits")
        check(g.integrationInstructions().contains("`gmail` (Gmail)"), "instructions list the hosted Gmail server")
        g.applyAwanStatus(["gmail": (false, nil), "google-sheets": (true, "fakhrul@example.com"), "google-docs": (true, "fakhrul@example.com")])
        check(g.connectors.first { $0.id == "gmail" }?.status == "needsSignIn", "server status: a revoked grant turns the row back to Connect")
        check(g.isConnected("google-docs"), "server status: a toolkit granted elsewhere shows connected")
        _ = g.handleConnectorsURL(URL(string: "awan://connectors?error=access_denied")!)
        check(g.details["gmail"] == "Google sign-in was cancelled", "a cancelled consent is explained", g.details["gmail"] ?? "")
        _ = g.handleConnectorsURL(URL(string: "awan://connectors?connected=slack%2Cnotion")!)
        check(!g.connectors.contains { $0.id == "slack" || $0.id == "notion" }, "only Awan's Google toolkits can be marked connected by URL")
        await g.disconnect("gmail")
        check(!g.connectors.contains { $0.id == "gmail" } && g.isConnected("google-sheets"), "disconnecting one Google toolkit keeps the others")
        check(opened.isEmpty, "no browser opened in the self-test")

        await composioSelfTest(defaults: defaults)

        print("\n\(failures == 0 ? "ALL PASS" : "\(failures) FAILED")")
        return failures == 0 ? 0 : 1
    }
}

// MARK: --connector-selftest: Composio

extension AgentSelfTests {
    /// Composio side of ConnectorStore, no network: the Awan API is an injected fake.
    static func composioSelfTest(defaults: UserDefaults) async {
        print("---- composio ----")
        let c = ConnectorStore(directory: .some(nil), defaults: defaults)
        var secrets: [String: String] = [:]
        c.secretGet = { secrets[$0] }
        c.secretSet = { v, k in secrets[k] = v }
        var opened: [URL] = []
        c.openURL = { opened.append($0) }
        var calls: [(String, String)] = []
        c.apiCall = { path, method, _ in
            calls.append((path, method))
            let json: String
            switch path {
            case "v1/composio/toolkits":
                json = #"{"toolkits":[{"slug":"gmail","name":"Gmail","description":"Mail","logo":"https://logos.test/gmail","categories":["Email"],"toolsCount":40},{"slug":"slack","name":"Slack","description":"Chat","logo":null,"categories":["Communication"],"toolsCount":90},{"slug":"googlesheets","name":"Google Sheets","description":"Cells","categories":["Productivity"]},{"slug":"hubspot","name":"HubSpot","description":"CRM","categories":["CRM"]},{"slug":"obsidian","name":"Obsidian","description":"x","categories":[]}],"total":5}"#
            case "v1/composio/connect": json = #"{"redirectUrl":"https://connect.composio.test/link/lk_1","toolkit":"slack","expiresAt":"2026-09-29T12:00:00Z"}"#
            case "v1/composio/connections": json = #"{"connections":[],"toolkits":{"slack":{"connected":true,"status":"ACTIVE"},"hubspot":{"connected":false,"status":"INITIATED"}}}"#
            case "v1/composio/session": json = #"{"mcpUrl":"https://api.awan.test/mcp/composio","bearerTokenEnvVar":"AWAN_AGENT_TOKEN","headers":{"x-awan-region":"sg-secret-value"},"toolkits":["slack"],"sessionId":"trs_1"}"#
            case "v1/composio/disconnect": json = #"{"disconnected":true}"#
            default: throw APIError.server(404, "no fake for \(path)")
            }
            return Data(json.utf8)
        }
        c.catalog = [
            IntegrationDTO(id: "notion", name: "Notion", description: "", url: "https://mcp.notion.com/mcp", auth: "oauth", icon: "doc", category: "productivity"),
            IntegrationDTO(id: "slack", name: "Slack", description: "", url: nil, auth: "oauth", icon: "number", category: "productivity"),
            IntegrationDTO(id: "gmail", name: "Gmail", description: "", url: nil, auth: "awan-google", icon: "envelope", category: "google"),
            IntegrationDTO(id: "google-sheets", name: "Google Sheets", description: "", url: nil, auth: "awan-google", icon: "tablecells", category: "google"),
            IntegrationDTO(id: "google-drive", name: "Google Drive", description: "", url: nil, auth: "awan-google", icon: "externaldrive", category: "google"),
            IntegrationDTO(id: "obsidian", name: "Obsidian", description: "", url: nil, auth: "local", icon: "diamond", category: "local"),
        ]

        // Off: nothing is fetched and the catalogue is Awan's own.
        await c.loadComposioCatalog()
        check(calls.isEmpty && c.mergedCatalog.map(\.id) == c.catalog.map(\.id), "Composio off → no calls, catalogue unchanged")
        check(c.composioServerConfig == nil, "Composio off → no [mcp_servers.composio]")

        c.applyServerFeatures(composio: true, awanGoogle: true)
        await c.loadComposioCatalog()
        check(c.composioCatalog.count == 5 && c.composioCatalog.allSatisfy { $0.auth == "composio" }, "catalogue → composio items")
        check(c.composioCatalog.first?.logo == "https://logos.test/gmail", "logo carried through")
        let withGoogle = c.mergedCatalog.map { "\($0.id):\($0.auth)" }
        check(withGoogle == ["notion:oauth", "gmail:awan-google", "google-sheets:awan-google", "google-drive:awan-google", "obsidian:local", "slack:composio", "hubspot:composio"],
              "merge with Awan-hosted Google: ours for Google + Obsidian, Composio replaces Slack", withGoogle.joined(separator: ", "))
        c.applyServerFeatures(composio: true, awanGoogle: false)
        await c.loadComposioCatalog()
        let noGoogle = c.mergedCatalog.map { "\($0.id):\($0.auth)" }
        check(noGoogle == ["notion:oauth", "google-drive:awan-google", "obsidian:local", "gmail:composio", "slack:composio", "googlesheets:composio", "hubspot:composio"],
              "merge without Awan Google: Composio's Gmail/Sheets win, Drive (no Composio row) stays", noGoogle.joined(separator: ", "))

        // Connect → the hosted page opens; the row waits for the browser.
        await c.connect(c.composioCatalog.first { $0.id == "slack" }!)
        check(opened.map(\.absoluteString) == ["https://connect.composio.test/link/lk_1"], "Connect opens Composio's page", opened.map(\.absoluteString).joined())
        check(c.connectors.first { $0.id == "slack" }?.status == "needsSignIn", "row waits in needsSignIn")
        check(c.composioServerConfig == nil && c.mcpServersTOML().isEmpty, "no runtime server before a connection completes")

        // Return URL: only Composio toolkits, only with source=composio.
        _ = c.handleConnectorsURL(URL(string: "awan://connectors?connected=slack")!)
        check(c.connectors.first { $0.id == "slack" }?.status == "needsSignIn", "without source=composio the Google path ignores it")
        let toast = c.handleConnectorsURL(URL(string: "awan://connectors?source=composio&connected=slack%2Cnotreal")!)
        check(c.isConnected("slack") && !c.connectors.contains { $0.id == "notreal" }, "source=composio marks a known toolkit connected, ignores unknown ones")
        check(toast.hasPrefix("Slack connected"), "toast names it", toast)
        _ = c.handleConnectorsURL(URL(string: "awan://connectors?source=composio&error=not_active&toolkit=hubspot")!)
        check(c.connectors.first { $0.id == "hubspot" }?.status == "needsSignIn" && c.details["hubspot"]?.contains("Connect") == true, "an unfinished connect is explained", c.details["hubspot"] ?? "")

        // Runtime: one [mcp_servers.composio], header values only in the env.
        await c.prepareComposioSession()
        check(c.composioSession?.mcpUrl == "https://api.awan.test/mcp/composio", "session fetched")
        check(!c.mcpServersTOML().contains("composio") && !c.mcpServersTOML().contains("slack"), "Composio toolkits never get their own server block")
        let home = URL(fileURLWithPath: "/tmp/Awan Home")
        let toml = CodexConfig.render(.init(home: home, apiBaseURL: "https://api.awan.test", model: "awan-agent", effort: "medium", agentsRoot: home,
                                             computerUse: nil, skills: [], connectorsTOML: c.mcpServersTOML(), composio: c.composioServerConfig))
        let expected = """
        [mcp_servers.composio]
        url = "https://api.awan.test/mcp/composio"
        bearer_token_env_var = "AWAN_AGENT_TOKEN"
        env_http_headers = { "x-awan-region" = "AWAN_COMPOSIO_HEADER_X_AWAN_REGION" }
        startup_timeout_sec = 30.0
        tool_timeout_sec = 180.0
        """
        print(toml.components(separatedBy: "\n").filter { !$0.isEmpty }.drop { !$0.hasPrefix("[mcp_servers.composio]") }.prefix(6).joined(separator: "\n"))
        check(toml.contains(expected), "CodexConfig writes [mcp_servers.composio] with env-var auth")
        check(!toml.contains("sg-secret-value"), "no header value in config.toml")
        check(c.mcpEnvironment()["AWAN_COMPOSIO_HEADER_X_AWAN_REGION"] == "sg-secret-value", "header value travels in the env")
        check(c.integrationInstructions().contains("`composio` MCP server") && c.integrationInstructions().contains("`slack` (Slack)"), "instructions name the Composio toolkits")

        // Server status mirrors: a revoke elsewhere turns it back to Connect and drops the server block.
        c.applyComposioStatus(["slack": false])
        check(c.connectors.first { $0.id == "slack" }?.status == "needsSignIn" && c.composioServerConfig == nil, "revoked elsewhere → needsSignIn, no server block")
        await c.refreshComposioStatus()
        check(c.isConnected("slack") && c.connectors.first { $0.id == "hubspot" }?.status == "needsSignIn", "refresh from /v1/composio/connections")
        check(ConnectorStore.reservedIDs.contains("composio"), "'composio' is reserved for custom connectors")

        await c.disconnect("slack")
        check(calls.contains { $0.0 == "v1/composio/disconnect" } && !c.connectors.contains { $0.id == "slack" } && c.composioSession == nil,
              "disconnect calls the server and drops the session")
    }
}
