import AppKit
import ApplicationServices

/// The computer-use tools: schemas for `tools/list` and handlers for `tools/call`. Runs on one serial queue.
final class CUToolbox: @unchecked Sendable {
    struct Result {
        var content: [[String: Any]]
        var structured: [String: Any]?
        var isError = false

        static func json(_ obj: [String: Any]) -> Result {
            let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return Result(content: [["type": "text", "text": String(decoding: data, as: UTF8.self)]], structured: obj)
        }
        static func error(_ s: String) -> Result { Result(content: [["type": "text", "text": s]], structured: nil, isError: true) }

        var mcp: [String: Any] {
            var r: [String: Any] = ["content": content, "isError": isError]
            if let structured { r["structuredContent"] = structured }
            return r
        }
    }

    let gate: CUGate
    let snapshots = CUSnapshotStore()
    let startedAt = Date()
    private(set) var callCount = 0
    private(set) var refusedCount = 0
    private(set) var lastError: String?
    private(set) var lastMetaKeys: [String] = []
    static let version = "1.0.0"

    init(gate: CUGate) { self.gate = gate }

    // MARK: Schemas

    static let toolNames = ["check_permissions", "list_apps", "launch_app", "list_windows", "get_window_state", "click", "right_click",
                            "type_text", "set_value", "press_key", "hotkey", "scroll", "page", "get_screen_size", "get_config", "health_report"]

    private static func obj(_ props: [String: Any], required: [String] = []) -> [String: Any] {
        var o: [String: Any] = ["type": "object", "properties": props, "additionalProperties": true]
        if !required.isEmpty { o["required"] = required }
        return o
    }
    private static let int: [String: Any] = ["type": "integer"]
    private static let num: [String: Any] = ["type": "number"]
    private static let str: [String: Any] = ["type": "string"]
    private static let bool: [String: Any] = ["type": "boolean"]
    private static let strs: [String: Any] = ["type": "array", "items": ["type": "string"]]
    private static func d(_ base: [String: Any], _ description: String) -> [String: Any] { base.merging(["description": description]) { $1 } }
    private static let delivery = d(["type": "string", "enum": ["background"]], "Always \"background\". Foreground delivery is refused.")
    private static let target: [String: Any] = [
        "pid": d(int, "Target process id (from launch_app / list_apps / list_windows)."),
        "window_id": d(int, "Target window id (from launch_app's windows or list_windows)."),
    ]
    private static let elementProp = d(str, "Element token like \"s12e4\" from the latest get_window_state of that window.")

    static var toolSchemas: [[String: Any]] {
        func tool(_ name: String, _ desc: String, _ schema: [String: Any], readOnly: Bool) -> [String: Any] {
            ["name": name, "description": desc, "inputSchema": schema,
             "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false]]
        }
        return [
            tool("check_permissions", "Report whether Awan has Accessibility and Screen Recording access. Never prompts.", obj([:]), readOnly: true),
            tool("list_apps", "List running apps (name, bundle_id, pid, active, hidden). Pass include_installed to also list installed apps.",
                 obj(["include_installed": bool]), readOnly: true),
            tool("launch_app", "Start or reuse an app in the background without bringing it forward; optionally hand it URLs/files. Returns pid and windows. For browser work open your OWN window: {bundle_id, creates_new_application_instance: true, additional_arguments: [\"--new-window\", url]} (Chromium) — plain urls on a running Chromium browser land in the user's active window.",
                 obj(["bundle_id": str, "name": d(str, "App name when the bundle id isn't known."), "urls": d(strs, "URLs or file paths to open with the app."),
                      "creates_new_application_instance": bool, "additional_arguments": d(strs, "argv passed to the app, e.g. [\"--new-window\", url].")]), readOnly: false),
            tool("list_windows", "List normal windows (window_id, pid, app, title, bounds, is_on_screen, z_index). Filter by pid or bundle_id.",
                 obj(target.merging(["bundle_id": str, "on_screen_only": bool]) { $1 }), readOnly: true),
            tool("get_window_state", "Snapshot one window: a compact accessibility tree where every actionable element carries a token like [s12e4], plus a screenshot (pixel clicks use its coordinates). Each new snapshot of a window invalidates its older tokens. Pass query to filter the tree.",
                 obj(target.merging(["query": d(str, "Case-insensitive filter on role/label/value."), "max_elements": d(int, "Default 300."),
                                     "max_depth": d(int, "Default 40."), "include_screenshot": d(bool, "Default true.")]) { $1 }), readOnly: true),
            tool("click", "Click an element by token (AX press — background, no cursor move), or window-scoped x,y read off the latest screenshot. action: press (default) | open | show_menu | confirm | cancel | pick | increment | decrement. count: 2 for double-click.",
                 obj(target.merging(["element_token": elementProp, "element": d(str, "Alias of element_token."), "x": num, "y": num,
                                     "action": str, "count": int, "delivery_mode": delivery]) { $1 }), readOnly: false),
            tool("right_click", "Open an element's context menu (AXShowMenu), or right-click window-scoped x,y.",
                 obj(target.merging(["element_token": elementProp, "element": str, "x": num, "y": num, "delivery_mode": delivery]) { $1 }), readOnly: false),
            tool("type_text", "Type text into an element (focus + insert, falling back to per-app key events) or into the app's current focus.",
                 obj(target.merging(["text": str, "element_token": elementProp, "element": str, "delivery_mode": delivery]) { $1 }, required: ["text"]), readOnly: false),
            tool("set_value", "Set an element's whole value (text fields, sliders, steppers, checkboxes). Verified by reading it back.",
                 obj(["element_token": elementProp, "element": str, "value": ["description": "String, number or boolean."]], required: ["value"]), readOnly: false),
            tool("press_key", "Send one key (return, tab, escape, arrows, a-z, f1…) with optional modifiers to an app; with an element token it focuses that element first.",
                 obj(target.merging(["key": str, "modifiers": strs, "element_token": elementProp, "element": str, "delivery_mode": delivery]) { $1 }, required: ["key"]), readOnly: false),
            tool("hotkey", "Send a key combination to an app, modifiers first, e.g. [\"cmd\",\"c\"]. Address-bar, Go-to-Folder, tab- and app-switching shortcuts are refused.",
                 obj(target.merging(["keys": strs, "delivery_mode": delivery]) { $1 }, required: ["keys"]), readOnly: false),
            tool("scroll", "Scroll an element (moves its scroll bar through AX when possible) or window-scoped x,y. Use direction+amount or dy/dx (lines; positive dy = further down).",
                 obj(target.merging(["element_token": elementProp, "element": str, "x": num, "y": num, "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                                     "amount": int, "dy": int, "dx": int, "delivery_mode": delivery]) { $1 }), readOnly: false),
            tool("page", "Window content. action \"screenshot\" (default): a PNG of one window. \"get_text\": the visible text via accessibility (works for web pages). \"execute_javascript\" (Safari/Chrome-family, needs approval and the browser's Allow JavaScript from Apple Events): run JS in that window's active tab.",
                 obj(target.merging(["action": ["type": "string", "enum": ["screenshot", "get_text", "execute_javascript"]], "javascript": str,
                                     "max_width": d(int, "Screenshot longest edge in px, default 1600.")]) { $1 }), readOnly: true),
            tool("get_screen_size", "Displays with logical size and scale.", obj([:]), readOnly: true),
            tool("get_config", "This server's settings and policy.", obj([:]), readOnly: true),
            tool("health_report", "Permissions, uptime, counters and the last error — call once when something systemic looks wrong.", obj([:]), readOnly: true),
        ]
    }

    // MARK: Dispatch

    func call(_ name: String, _ args: [String: Any], threadID: String?, meta: [String: Any]?) -> Result {
        callCount += 1
        if let meta { lastMetaKeys = Array(meta.keys).sorted() }
        guard Self.toolNames.contains(name) else { return .error("unknown tool \(name)") }
        if CUPolicy.isInput(name, args) {
            if !gate.allows(threadID: threadID) { refusedCount += 1; return .error(CUPolicy.consentRefusal) }
            if let denial = CUPolicy.argumentDenial(name, args) { refusedCount += 1; return .error(denial) }
        }
        let r: Result
        do {
            switch name {
            case "check_permissions": r = checkPermissions()
            case "list_apps": r = listApps(args)
            case "launch_app": r = try launchApp(args)
            case "list_windows": r = listWindows(args)
            case "get_window_state": r = try getWindowState(args)
            case "click": r = try click(args, right: false)
            case "right_click": r = try click(args, right: true)
            case "type_text": r = try typeText(args)
            case "set_value": r = try setValue(args)
            case "press_key": r = try pressKey(args)
            case "hotkey": r = try hotkey(args)
            case "scroll": r = try scroll(args)
            case "page": r = try page(args)
            case "get_screen_size": r = screenSize()
            case "get_config": r = config()
            case "health_report": r = health()
            default: r = .error("unknown tool \(name)")
            }
        } catch {
            r = .error("\(error)")
        }
        if r.isError, case let .some(t) = r.content.first?["text"] as? String { lastError = "\(name): \(t)" }
        return r
    }

    // MARK: Observation

    private func checkPermissions() -> Result {
        let ax = AX.trusted
        let screen = CGPreflightScreenCaptureAccess()
        var j: [String: Any] = ["accessibility": ax, "screen_recording": screen, "post_events": CGPreflightPostEventAccess(), "attribution": "host",
                                "host_bundle_id": Bundle.main.bundleIdentifier ?? "studio.ffdev.awan"]
        if !ax || !screen {
            j["next_step"] = "Ask the user to allow Awan under System Settings → Privacy & Security → " +
                [ax ? nil : "Accessibility", screen ? nil : "Screen Recording"].compactMap { $0 }.joined(separator: " and ") +
                ". Awan never opens those prompts on its own."
        }
        return .json(j)
    }

    private func listApps(_ args: [String: Any]) -> Result {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var j: [String: Any] = ["running": CUApps.runningApps().map { CUApps.appJSON($0, frontPID: front) }]
        if (args["include_installed"] as? Bool) == true { j["installed"] = CUApps.installedApps() }
        return .json(j)
    }

    private func listWindows(_ args: [String: Any]) -> Result {
        var pid = intArg(args["pid"]).map { pid_t($0) }
        if pid == nil, let b = args["bundle_id"] as? String {
            pid = NSRunningApplication.runningApplications(withBundleIdentifier: b).first?.processIdentifier
            if pid == nil { return .json(["windows": [], "note": "\(b) isn't running"]) }
        }
        let wins = CUApps.windows(pid: pid, onScreenOnly: (args["on_screen_only"] as? Bool) ?? false)
        return .json(["windows": wins.map(\.json)])
    }

    private func screenSize() -> Result {
        let ds = CUCapture.displays().map { d -> [String: Any] in
            ["display_id": Int(d.id), "width": Int(d.bounds.width), "height": Int(d.bounds.height),
             "x": Int(d.bounds.minX), "y": Int(d.bounds.minY), "scale": d.scale, "main": d.main]
        }
        let main = ds.first { ($0["main"] as? Bool) == true } ?? ds.first ?? [:]
        return .json(["width": main["width"] ?? 0, "height": main["height"] ?? 0, "scale": main["scale"] ?? 1, "displays": ds])
    }

    private func config() -> Result {
        .json([
            "server": "awan-computer-use", "version": Self.version, "delivery_mode": "background", "tools": Self.toolNames,
            "observation_tools": CUPolicy.observationTools.sorted(),
            "policy": [
                "consent": "input tools need the user's approval for the current turn (or Always allow in Settings)",
                "always_allow": gate.alwaysAllow,
                "desktop_scope": "refused", "foreground_delivery": "refused",
                "refused_shortcuts": ["cmd/ctrl+L", "cmd+shift+G", "cmd+1…9", "cmd+[ / cmd+]", "cmd+option+←/→", "ctrl+tab",
                                      "cmd+tab", "cmd+`", "cmd+space", "ctrl+arrows"],
            ],
            "defaults": ["max_elements": 300, "max_depth": 40, "snapshot_screenshot_long_edge": 1280, "page_screenshot_long_edge": 1600],
        ])
    }

    private func health() -> Result {
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        var j: [String: Any] = [
            "ok": true, "version": Self.version, "uptime_s": Int(Date().timeIntervalSince(startedAt)),
            "accessibility": AX.trusted, "screen_recording": CGPreflightScreenCaptureAccess(), "post_events": CGPreflightPostEventAccess(),
            "screen_locked": locked,
            "calls": callCount, "refused": refusedCount, "live_snapshots": snapshots.count,
            "approved_threads": gate.approvedCount, "always_allow": gate.alwaysAllow,
            "frontmost_app": NSWorkspace.shared.frontmostApplication?.localizedName ?? "", "displays": CUCapture.displays().count,
        ]
        if let e = lastError { j["last_error"] = e }
        if !lastMetaKeys.isEmpty { j["last_call_meta_keys"] = lastMetaKeys }
        return .json(j)
    }

    // MARK: Targets

    private func intArg(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private func dbl(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private func token(_ args: [String: Any]) -> String? {
        (args["element_token"] as? String) ?? (args["element"] as? String) ?? (args["element_index"] as? String)
    }

    /// Resolves (pid, window) from window_id and/or pid. With pid alone, picks the pid's frontmost window.
    private func resolveWindow(_ args: [String: Any]) throws -> CUApps.WindowInfo {
        if let wid = intArg(args["window_id"]) {
            guard let w = CUApps.window(CGWindowID(wid)) else { throw CUError.message("window \(wid) doesn't exist (closed?). Call list_windows.") }
            if let pid = intArg(args["pid"]), pid_t(pid) != w.pid {
                throw CUError.message("window \(wid) belongs to pid \(w.pid), not \(pid). Use list_windows({pid: \(pid)}).")
            }
            return w
        }
        guard let pid = intArg(args["pid"]) else { throw CUError.message("pass window_id (preferred) or pid.") }
        let wins = CUApps.windows(pid: pid_t(pid))
        guard let w = wins.filter(\.onScreen).min(by: { ($0.z ?? .max) < ($1.z ?? .max) }) ?? wins.first else {
            throw CUError.message("pid \(pid) has no windows. launch_app it (with urls if it needs a document) first.")
        }
        return w
    }

    private func guardSelf(_ pid: pid_t) throws {
        if pid == getpid() && !gate.allowSelfTargeting {
            throw CUError.message("Awan's own windows are off-limits to computer use. Ask the user to change Awan's settings themselves.")
        }
    }

    private func pidFor(_ args: [String: Any]) throws -> pid_t {
        if let t = token(args) { return try snapshots.resolve(t).0.pid }
        if intArg(args["window_id"]) != nil { return try resolveWindow(args).pid }
        if let p = intArg(args["pid"]) { return pid_t(p) }
        throw CUError.message("pass pid, window_id or element_token so the input reaches one app.")
    }

    // MARK: get_window_state

    private func getWindowState(_ args: [String: Any]) throws -> Result {
        let w = try resolveWindow(args)
        let sid = snapshots.reserveID()
        var walker = CUTreeWalker()
        walker.maxElements = max(20, min(intArg(args["max_elements"]) ?? 300, 2000))
        walker.maxDepth = max(4, min(intArg(args["max_depth"]) ?? 40, 80))
        walker.query = args["query"] as? String
        var axNote: String?
        if AX.trusted {
            if let axw = AX.window(pid: w.pid, windowID: w.id, cgBounds: w.bounds) {
                walker.walk(axw)
            } else {
                let (err, list) = AX.raw(AX.app(w.pid), kAXWindowsAttribute)
                let n = (list as? [AXUIElement])?.count ?? 0
                axNote = err == .success ? "no accessibility window matched window \(w.id) of \(n) (it may be on another Space or minimized)" : AX.describe(err)
            }
        } else {
            axNote = AX.describe(.apiDisabled) + ". The screenshot still works; element tokens don't until access is granted."
        }
        var snap = CUSnapshot(id: sid, pid: w.pid, windowID: w.id, windowFrame: w.bounds, elements: walker.elements, imageScale: nil)

        var content: [[String: Any]] = []
        var structured: [String: Any] = ["pid": Int(w.pid), "window_id": Int(w.id), "app": w.app, "title": w.title,
                                         "snapshot_id": "s\(sid)", "element_count": walker.records.count, "truncated": walker.truncated,
                                         "is_on_screen": w.onScreen]
        var shotLine = ""
        if (args["include_screenshot"] as? Bool) ?? true {
            switch CUCapture.window(w.id, maxLongEdge: 1280) {
            case let .success(shot):
                snap.imageScale = shot.scale
                if let data = CUCapture.encode(shot.image, jpeg: true) {
                    content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
                    structured["screenshot_width"] = shot.image.width
                    structured["screenshot_height"] = shot.image.height
                    structured["screenshot_scale"] = Double(shot.scale)
                    shotLine = "\nscreenshot: \(shot.image.width)×\(shot.image.height) px — window-scoped x,y for click/scroll are pixels in this image."
                }
            case let .failure(e):
                shotLine = "\nscreenshot unavailable: \(e)"
                structured["has_screenshot"] = false
            }
        }
        snapshots.store(snap)
        let b = w.bounds
        var text = "window \(w.id) \"\(w.title)\" — \(w.app) (pid \(w.pid)), frame \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))×\(Int(b.height))\(w.onScreen ? "" : ", not on screen")\n"
        text += "snapshot s\(sid): \(walker.records.count) elements\(walker.truncated ? " (truncated — narrow with query or max_depth)" : "")"
        if let axNote { text += "\naccessibility tree unavailable: \(axNote)"; structured["ax_error"] = axNote }
        text += shotLine
        if !walker.records.isEmpty { text += "\n\n" + walker.markdown(snapshotID: sid, windowFrame: b) }
        content.insert(["type": "text", "text": text], at: 0)
        return Result(content: content, structured: structured, isError: walker.records.isEmpty && structured["screenshot_width"] == nil)
    }

    // MARK: Actions

    private static let actionMap: [String: String] = [
        "press": kAXPressAction, "show_menu": kAXShowMenuAction, "open": "AXOpen", "confirm": kAXConfirmAction,
        "cancel": kAXCancelAction, "pick": kAXPickAction, "increment": kAXIncrementAction, "decrement": kAXDecrementAction,
        "raise": kAXRaiseAction,
    ]

    private func center(_ el: AXUIElement) -> CGPoint? {
        guard let f = AX.frame(el), f.width > 0, f.height > 0 else { return nil }
        return CGPoint(x: f.midX, y: f.midY)
    }

    /// Window-scoped screenshot pixels → screen points (via the latest snapshot's scale), bounds-checked.
    private func screenPoint(_ args: [String: Any]) throws -> (CGPoint, CUApps.WindowInfo) {
        guard let x = dbl(args["x"]), let y = dbl(args["y"]) else { throw CUError.message("pass element_token, or x and y.") }
        let w = try resolveWindow(args)
        let scale = snapshots.latest(pid: w.pid, windowID: w.id)?.imageScale ?? 1
        let p = CGPoint(x: w.bounds.minX + CGFloat(x) / scale, y: w.bounds.minY + CGFloat(y) / scale)
        guard w.bounds.insetBy(dx: -1, dy: -1).contains(p) else {
            throw CUError.message("(\(Int(x)), \(Int(y))) falls outside window \(w.id). Coordinates are pixels in that window's latest screenshot.")
        }
        return (p, w)
    }

    private func settle() { usleep(180_000) }

    private func click(_ args: [String: Any], right: Bool) throws -> Result {
        let count = max(1, intArg(args["count"]) ?? 1)
        if let t = token(args) {
            let (snap, el) = try snapshots.resolve(t)
            try guardSelf(snap.pid)
            var actionName = right ? "show_menu" : ((args["action"] as? String)?.lowercased() ?? "press")
            if !right && count >= 2 && actionName == "press" { actionName = "open" }
            guard let ax = Self.actionMap[actionName] else { throw CUError.message("unknown action \(actionName). Use one of \(Self.actionMap.keys.sorted()).") }
            let beforeValue = AX.string(el, kAXValueAttribute)
            let role = AX.string(el, kAXRoleAttribute) ?? ""
            let err = AXUIElementPerformAction(el, ax as CFString)
            if err == .success {
                settle()
                let (vErr, after) = AX.raw(el, kAXValueAttribute)
                let afterValue = AX.stringify(after)
                var j: [String: Any] = ["ok": true, "path": "ax", "action": ax, "element_token": t, "role": role]
                if vErr == .invalidUIElement {
                    j["effect"] = "element_gone"; j["verified"] = false
                    j["note"] = "the element disappeared after the action (a menu closed, a sheet dismissed, or the view changed) — re-snapshot to confirm"
                } else if beforeValue != afterValue, afterValue != nil {
                    j["effect"] = "confirmed"; j["verified"] = true; j["value"] = afterValue
                } else {
                    j["effect"] = "unverifiable"; j["verified"] = false
                    j["note"] = "call get_window_state again and diff the tree to confirm"
                }
                return .json(j)
            }
            // AX refused: fall back to a background pixel click on the element's centre.
            guard (err == .actionUnsupported || err == .cannotComplete), actionName == "press" || actionName == "open" || right,
                  let p = center(el) else {
                throw CUError.message("AX action \(ax) failed: \(AX.describe(err)). Try another action (show_menu, confirm, pick) or window-scoped x,y.")
            }
            CUInput.postClick(pid: snap.pid, at: p, button: right ? .right : .left, count: count, windowID: snap.windowID)
            settle()
            return .json(["ok": true, "path": "cgevent", "element_token": t, "effect": "unverifiable", "verified": false,
                          "note": "AX \(ax) wasn't supported (\(AX.describe(err))); sent a background click at the element's centre. Re-snapshot to confirm.",
                          "escalation": ["recommended": "px", "reason": "ax_action_unsupported"]])
        }
        let (p, w) = try screenPoint(args)
        try guardSelf(w.pid)
        CUInput.postClick(pid: w.pid, at: p, button: right ? .right : .left, count: count, windowID: w.id)
        settle()
        return .json(["ok": true, "path": "pixel", "window_id": Int(w.id), "screen_point": ["x": Int(p.x), "y": Int(p.y)],
                      "effect": "unverifiable", "verified": false, "note": "pixel clicks can't be read back — re-snapshot to confirm"])
    }

    private func typeText(_ args: [String: Any]) throws -> Result {
        guard let text = args["text"] as? String, !text.isEmpty else { throw CUError.message("text is required.") }
        if let t = token(args) {
            let (snap, el) = try snapshots.resolve(t)
            try guardSelf(snap.pid)
            let before = AX.string(el, kAXValueAttribute) ?? ""
            AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let insErr = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString)
            settle()
            var after = AX.string(el, kAXValueAttribute) ?? ""
            if insErr == .success, after != before, after.contains(text) {
                return .json(["ok": true, "path": "ax", "effect": "confirmed", "verified": true, "value": String(after.suffix(200))])
            }
            CUInput.postText(pid: snap.pid, text: text)
            settle()
            after = AX.string(el, kAXValueAttribute) ?? ""
            let ok = after != before && after.contains(text)
            return .json(["ok": true, "path": "cgevent", "effect": ok ? "confirmed" : "unverifiable", "verified": ok,
                          "value": String(after.suffix(200)),
                          "note": ok ? "typed with per-app key events" : "typed with per-app key events; the field didn't echo it — re-snapshot, or use set_value / page"])
        }
        let pid = try pidFor(args)
        try guardSelf(pid)
        CUInput.postText(pid: pid, text: text)
        return .json(["ok": true, "path": "cgevent", "pid": Int(pid), "effect": "unverifiable", "verified": false,
                      "note": "sent to the app's current focus — re-snapshot to confirm"])
    }

    private func setValue(_ args: [String: Any]) throws -> Result {
        guard let t = token(args) else { throw CUError.message("element_token is required.") }
        guard let raw = args["value"] else { throw CUError.message("value is required.") }
        let (snap, el) = try snapshots.resolve(t)
        try guardSelf(snap.pid)
        let current = AX.value(el, kAXValueAttribute)
        let newValue: CFTypeRef
        if let n = current as? NSNumber, !(current is String) {
            if let b = raw as? Bool { newValue = NSNumber(value: b ? 1 : 0) }
            else if let d = dbl(raw) { newValue = NSNumber(value: d) }
            else if let s = raw as? String, ["true", "on", "yes"].contains(s.lowercased()) { newValue = NSNumber(value: 1) }
            else if let s = raw as? String, ["false", "off", "no"].contains(s.lowercased()) { newValue = NSNumber(value: 0) }
            else { throw CUError.message("this element holds a number (now \(n)); pass a number.") }
        } else {
            newValue = ("\(raw)" as NSString)
        }
        let err = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, newValue)
        guard err == .success else { throw CUError.message("couldn't set the value: \(AX.describe(err)). For text, try type_text.") }
        settle()
        let after = AX.stringify(AX.value(el, kAXValueAttribute))
        let wanted = AX.stringify(newValue)
        let ok = after == wanted || (Double(after ?? "") != nil && Double(after ?? "") == Double(wanted ?? ""))
        return .json(["ok": true, "path": "ax", "effect": ok ? "confirmed" : "unverifiable", "verified": ok, "value": after ?? NSNull(),
                      "note": ok ? "" : "the app reports a different value — web content often echoes writes it never applied; check with page get_text"])
    }

    private func pressKey(_ args: [String: Any]) throws -> Result {
        guard var key = (args["key"] as? String)?.lowercased(), !key.isEmpty else { throw CUError.message("key is required.") }
        var mods = (args["modifiers"] as? [String]) ?? []
        if key.count > 1, key.contains("+") {
            var parts = key.split(separator: "+").map(String.init)
            key = parts.removeLast()
            mods += parts
        }
        guard let code = CUInput.keyCode(key) else { throw CUError.message("unknown key \"\(key)\". Use names like return, tab, escape, space, left, pagedown, f5, a-z, 0-9.") }
        var pid: pid_t
        var path = "cgevent"
        if let t = token(args) {
            let (snap, el) = try snapshots.resolve(t)
            pid = snap.pid
            try guardSelf(pid)
            AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            path = "ax_focus+cgevent"
        } else {
            pid = try pidFor(args)
            try guardSelf(pid)
        }
        CUInput.postKey(pid: pid, code: code, flags: CUInput.flags(mods))
        settle()
        return .json(["ok": true, "path": path, "pid": Int(pid), "key": key, "modifiers": mods, "effect": "unverifiable", "verified": false,
                      "note": "re-snapshot to confirm the key landed"])
    }

    private func hotkey(_ args: [String: Any]) throws -> Result {
        let keys = ((args["keys"] as? [String]) ?? []).map { $0.lowercased() }
        let mods = keys.filter(CUInput.isModifier)
        let rest = keys.filter { !CUInput.isModifier($0) }
        guard rest.count == 1, let key = rest.first else { throw CUError.message("keys needs modifiers plus exactly one other key, e.g. [\"cmd\",\"c\"].") }
        guard let code = CUInput.keyCode(key) else { throw CUError.message("unknown key \"\(key)\".") }
        let pid = try pidFor(args)
        try guardSelf(pid)
        CUInput.postKey(pid: pid, code: code, flags: CUInput.flags(mods))
        settle()
        return .json(["ok": true, "path": "cgevent", "pid": Int(pid), "keys": keys, "effect": "unverifiable", "verified": false])
    }

    private func scroll(_ args: [String: Any]) throws -> Result {
        var dy = intArg(args["dy"]) ?? 0
        var dx = intArg(args["dx"]) ?? 0
        if let dir = (args["direction"] as? String)?.lowercased() {
            let amount = max(1, min(intArg(args["amount"]) ?? 3, 50))
            switch dir {
            case "down": dy = amount
            case "up": dy = -amount
            case "right": dx = amount
            case "left": dx = -amount
            default: throw CUError.message("direction must be up, down, left or right.")
            }
        }
        if dy == 0 && dx == 0 { dy = 3 }
        if let t = token(args) {
            let (snap, el) = try snapshots.resolve(t)
            try guardSelf(snap.pid)
            // Background path: move the enclosing scroll area's scroll bar through AX.
            var node: AXUIElement? = el
            for _ in 0 ..< 10 {
                guard let n = node else { break }
                if AX.string(n, kAXRoleAttribute) == kAXScrollAreaRole {
                    let barAttr = dy != 0 ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute
                    if let bar = AX.element(n, barAttr), let v = AX.value(bar, kAXValueAttribute) as? NSNumber {
                        let delta = Double(dy != 0 ? dy : dx) * 0.04
                        let target = max(0, min(1, v.doubleValue + delta))
                        if AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: target)) == .success {
                            settle()
                            let now = (AX.value(bar, kAXValueAttribute) as? NSNumber)?.doubleValue ?? v.doubleValue
                            return .json(["ok": true, "path": "ax_scrollbar", "position": now, "moved": abs(now - v.doubleValue) > 0.0001,
                                          "effect": abs(now - v.doubleValue) > 0.0001 ? "confirmed" : "suspected_noop",
                                          "verified": true, "note": now >= 1 || now <= 0 ? "reached the end of the scroll range" : ""])
                        }
                    }
                    break
                }
                node = AX.element(n, kAXParentAttribute)
            }
            guard let p = center(el) else { throw CUError.message("the element has no on-screen frame to scroll at.") }
            CUInput.postScroll(pid: snap.pid, at: p, dy: dy, dx: dx, windowID: snap.windowID)
            settle()
            return .json(["ok": true, "path": "cgevent", "effect": "unverifiable", "verified": false, "note": "re-snapshot to confirm"])
        }
        let w = try resolveWindow(args)
        try guardSelf(w.pid)
        let p = (dbl(args["x"]) != nil) ? try screenPoint(args).0 : CGPoint(x: w.bounds.midX, y: w.bounds.midY)
        CUInput.postScroll(pid: w.pid, at: p, dy: dy, dx: dx, windowID: w.id)
        settle()
        return .json(["ok": true, "path": "cgevent", "window_id": Int(w.id), "effect": "unverifiable", "verified": false, "note": "re-snapshot to confirm"])
    }

    private func launchApp(_ args: [String: Any]) throws -> Result {
        let bundle = args["bundle_id"] as? String
        if bundle == Bundle.main.bundleIdentifier || bundle == "studio.ffdev.awan" { throw CUError.message("Awan can't launch itself.") }
        switch CUApps.launch(bundleID: bundle, name: args["name"] as? String, urls: (args["urls"] as? [String]) ?? [],
                             newInstance: (args["creates_new_application_instance"] as? Bool) ?? false,
                             arguments: (args["additional_arguments"] as? [String]) ?? []) {
        case let .success(j): return .json(j)
        case let .failure(e): throw e
        }
    }

    // MARK: page

    private func page(_ args: [String: Any]) throws -> Result {
        let w = try resolveWindow(args)
        switch (args["action"] as? String ?? "screenshot").lowercased() {
        case "screenshot":
            let maxW = max(320, min(intArg(args["max_width"]) ?? 1600, 3000))
            switch CUCapture.window(w.id, maxLongEdge: maxW) {
            case let .success(shot):
                guard let png = CUCapture.encode(shot.image, jpeg: false) else { throw CUError.message("couldn't encode the screenshot") }
                return Result(content: [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                                        ["type": "text", "text": "window \(w.id) \"\(w.title)\" — \(shot.image.width)×\(shot.image.height) px PNG"]],
                              structured: ["window_id": Int(w.id), "width": shot.image.width, "height": shot.image.height, "bytes": png.count])
            case let .failure(e): throw e
            }
        case "get_text":
            guard AX.trusted else { throw CUError.message(AX.describe(.apiDisabled)) }
            guard let axw = AX.window(pid: w.pid, windowID: w.id, cgBounds: w.bounds) else { throw CUError.message("no accessibility window for \(w.id)") }
            var out: [String] = []
            var total = 0
            collectText(axw, depth: 0, into: &out, total: &total)
            return .json(["window_id": Int(w.id), "title": w.title, "text": out.joined(separator: "\n"), "truncated": total >= 40_000])
        case "execute_javascript":
            guard let js = args["javascript"] as? String, !js.isEmpty else { throw CUError.message("javascript is required.") }
            try guardSelf(w.pid)
            return try runJavaScript(js, in: w)
        default:
            throw CUError.message("action must be screenshot, get_text or execute_javascript.")
        }
    }

    private func collectText(_ el: AXUIElement, depth: Int, into out: inout [String], total: inout Int) {
        guard depth < 60, total < 40_000 else { return }
        let v = AX.multi(el, [kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute])
        let role = AX.stringify(v[kAXRoleAttribute]) ?? ""
        var s: String?
        if role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField" || role == "AXHeading" {
            s = AX.stringify(v[kAXValueAttribute]) ?? AX.stringify(v[kAXTitleAttribute])
        } else if role == "AXButton" || role == "AXLink" || role == "AXImage" {
            s = AX.stringify(v[kAXTitleAttribute]) ?? AX.stringify(v[kAXDescriptionAttribute])
        }
        if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, out.last != s {
            out.append(s)
            total += s.count
        }
        for k in (v[kAXChildrenAttribute] as? [AXUIElement]) ?? [] { collectText(k, depth: depth + 1, into: &out, total: &total) }
    }

    private static let chromium: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
                                                "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "company.thebrowser.dia", "org.chromium.Chromium"]

    private func runJavaScript(_ js: String, in w: CUApps.WindowInfo) throws -> Result {
        guard let bid = NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier else { throw CUError.message("unknown app for pid \(w.pid)") }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let script: String
        if bid == "com.apple.Safari" || bid == "com.apple.SafariTechnologyPreview" {
            script = """
            tell application id \(q(bid))
              repeat with w in windows
                if name of w is \(q(w.title)) then return do JavaScript \(q(js)) in current tab of w
              end repeat
              error "no Safari window titled " & \(q(w.title))
            end tell
            """
        } else if Self.chromium.contains(bid) {
            script = """
            tell application id \(q(bid))
              repeat with w in windows
                if \(q(w.title)) contains (title of active tab of w) then return execute active tab of w javascript \(q(js))
              end repeat
              error "no window whose active tab matches " & \(q(w.title))
            end tell
            """
        } else {
            throw CUError.message("execute_javascript works in Safari and Chrome-family browsers only; \(bid) isn't one. Use get_window_state / page get_text.")
        }
        var result: String?
        var failure: String?
        let runScript = {
            var err: NSDictionary?
            let out = NSAppleScript(source: script)?.executeAndReturnError(&err)
            if let err { failure = (err[NSAppleScript.errorMessage] as? String) ?? "\(err)" } else { result = out?.stringValue ?? "" }
        }
        if Thread.isMainThread { runScript() } else { DispatchQueue.main.sync(execute: runScript) }
        if let failure {
            throw CUError.message("JavaScript didn't run: \(failure). The browser may need View → Developer → Allow JavaScript from Apple Events, and Awan needs Automation access to it.")
        }
        return .json(["ok": true, "path": "apple_events", "result": String((result ?? "").prefix(40_000))])
    }
}
