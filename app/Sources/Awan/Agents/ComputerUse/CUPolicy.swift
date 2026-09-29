import Foundation

/// Computer-use policy: which tools observe and which act, the per-turn consent gate, and the argument rules
/// (background delivery only, no desktop-scope input, no focus-stealing or tab/app-switching shortcuts).
/// The rules mirror the reference's managed policy, rewritten as plain Swift.
enum CUPolicy {
    static let observationTools: Set<String> = [
        "check_permissions", "list_apps", "list_windows", "get_window_state", "get_screen_size", "get_config", "health_report",
    ]

    /// True when the call changes something on screen (and so needs the user's approval for this turn).
    static func isInput(_ tool: String, _ args: [String: Any]) -> Bool {
        if tool == "page" { return (args["action"] as? String ?? "screenshot") == "execute_javascript" }
        return !observationTools.contains(tool)
    }

    /// A refusal message when the arguments break a rule, else nil.
    static func argumentDenial(_ tool: String, _ args: [String: Any]) -> String? {
        if let mode = args["delivery_mode"] as? String, mode.lowercased() != "background" {
            return "delivery_mode \"\(mode)\" is refused: Awan only acts in the background. Re-issue with delivery_mode \"background\"; if only foreground input would work, stop and say so."
        }
        if (args["scope"] as? String)?.lowercased() == "desktop" {
            return "scope \"desktop\" is refused: screen-absolute input would move the user's real pointer. Use an element token, or window-scoped x/y read off this window's screenshot."
        }
        switch tool {
        case "hotkey":
            let keys = (args["keys"] as? [String]) ?? []
            return shortcutDenial(keys)
        case "press_key":
            var keys = (args["modifiers"] as? [String]) ?? []
            if let k = args["key"] as? String {
                // "cmd+l" style strings are accepted by press_key too.
                keys += k.contains("+") && k.count > 1 ? k.split(separator: "+").map(String.init) : [k]
            }
            return shortcutDenial(keys)
        default:
            return nil
        }
    }

    /// Shortcuts that steal focus or visibly flip the user's tabs/apps even when posted to a background pid.
    static func shortcutDenial(_ rawKeys: [String]) -> String? {
        let keys = Set(rawKeys.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        let cmd = !keys.isDisjoint(with: ["cmd", "command", "meta", "super"])
        let ctrl = !keys.isDisjoint(with: ["ctrl", "control"])
        let opt = !keys.isDisjoint(with: ["alt", "option", "opt"])
        let shift = keys.contains("shift")
        if (cmd || ctrl) && keys.contains("l") {
            return "shortcut refused: cmd/ctrl+L focuses a browser's address bar and raises its window. To visit a URL, open your own window with launch_app({bundle_id, creates_new_application_instance: true, additional_arguments: [\"--new-window\", url]})."
        }
        if cmd && shift && keys.contains("g") {
            return "shortcut refused: cmd+shift+G (Go to Folder) brings Finder to the front. Open the folder with launch_app({bundle_id: \"com.apple.finder\", urls: [path]})."
        }
        let tabKeys: Set<String> = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "[", "]", "bracketleft", "bracketright"]
        if cmd && !keys.isDisjoint(with: tabKeys) {
            return "shortcut refused: cmd+number / cmd+[ ] switch the user's tabs. Work in your own window instead."
        }
        if cmd && opt && !keys.isDisjoint(with: ["left", "right", "arrowleft", "arrowright"]) {
            return "shortcut refused: cmd+option+arrow switches browser tabs. Work in your own window instead."
        }
        if ctrl && keys.contains("tab") {
            return "shortcut refused: ctrl+tab switches tabs. Work in your own window instead."
        }
        if cmd && !keys.isDisjoint(with: ["tab", "`", "grave", "backtick", "space"]) {
            return "shortcut refused: cmd+tab / cmd+` / cmd+space switch apps or windows (or open Spotlight) for the user."
        }
        if ctrl && !keys.isDisjoint(with: ["up", "down", "left", "right", "arrowup", "arrowdown", "arrowleft", "arrowright"]) && keys.count == 2 {
            return "shortcut refused: ctrl+arrow switches Spaces / Mission Control."
        }
        return nil
    }

    static let consentRefusal = """
    Computer use isn't approved for this turn yet, so input tools are off. Don't retry and don't work around it \
    (no AppleScript, `open`, or other GUI shortcuts). Finish whatever doesn't need the screen, then end your reply with \
    <COMPUTER_USE_REQUEST>what you'd do on screen, in which app, and why</COMPUTER_USE_REQUEST> so Awan can ask the user. \
    Observation tools (list_apps, list_windows, get_window_state, page screenshots) still work.
    """
}

/// Per-thread consent. Thread-safe; read on the MCP work queue, written from the main actor.
final class CUGate: @unchecked Sendable {
    private let lock = NSLock()
    private var approved: Set<String> = []
    private(set) var lastSeenThreadID: String?
    /// Test hook: lets the self-test drive Awan's own probe window.
    var allowSelfTargeting = false

    static let alwaysAllowKey = "awan.agents.alwaysAllowComputerUse" // == Prefs.Key.alwaysAllowComputerUse

    var alwaysAllow: Bool { UserDefaults.standard.bool(forKey: Self.alwaysAllowKey) }

    func set(threadID: String, approved on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if on { approved.insert(threadID) } else { approved.remove(threadID) }
    }

    var approvedCount: Int { lock.lock(); defer { lock.unlock() }; return approved.count }

    /// When the call names its thread we check that thread; when it doesn't (Codex doesn't always say),
    /// any approved thread opens the gate — the runtime clears approval when the approved turn ends.
    func allows(threadID: String?) -> Bool {
        if alwaysAllow { return true }
        lock.lock(); defer { lock.unlock() }
        if let t = threadID {
            lastSeenThreadID = t
            if approved.contains(t) { return true }
        }
        return threadID == nil && !approved.isEmpty
    }
}
