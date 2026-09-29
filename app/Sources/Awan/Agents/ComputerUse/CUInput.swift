import AppKit
import CoreGraphics

/// Synthetic input posted straight to one process (`CGEvent.postToPid`). Nothing goes through the HID tap,
/// so the user's real cursor never moves and their keystrokes stay with their own frontmost app.
enum CUInput {
    /// A private event source so the user's physically held modifiers never leak into our events.
    private static var source: CGEventSource? { CGEventSource(stateID: .privateState) }

    static let modifierNames: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "meta": .maskCommand, "super": .maskCommand,
        "shift": .maskShift,
        "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl,
        "fn": .maskSecondaryFn,
    ]

    static func isModifier(_ name: String) -> Bool { modifierNames[name.lowercased()] != nil }

    static func flags(_ names: [String]) -> CGEventFlags {
        names.reduce(into: CGEventFlags()) { acc, n in if let f = modifierNames[n.lowercased()] { acc.insert(f) } }
    }

    static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "equal": 24, "9": 25, "7": 26, "-": 27, "minus": 27, "8": 28, "0": 29, "]": 30, "bracketright": 30,
            "o": 31, "u": 32, "[": 33, "bracketleft": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "quote": 39,
            "k": 40, ";": 41, "semicolon": 41, "\\": 42, "backslash": 42, ",": 43, "comma": 43, "/": 44, "slash": 44,
            "n": 45, "m": 46, ".": 47, "period": 47, "`": 50, "grave": 50, "backtick": 50,
            "return": 36, "enter": 76, "tab": 48, "space": 49, " ": 49, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53, "forwarddelete": 117, "del": 117, "home": 115, "end": 119,
            "pageup": 116, "page_up": 116, "pagedown": 121, "page_down": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "arrowleft": 123, "arrowright": 124, "arrowdown": 125, "arrowup": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
            "f10": 109, "f11": 103, "f12": 111, "help": 114,
        ]
        m["ret"] = 36
        return m
    }()

    static func keyCode(_ name: String) -> CGKeyCode? { keyCodes[name.lowercased()] }

    static func postKey(pid: pid_t, code: CGKeyCode, flags: CGEventFlags) {
        let src = source
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.postToPid(pid)
            usleep(8_000)
        }
    }

    /// Types arbitrary Unicode (emoji, accents) in small chunks via keyboardSetUnicodeString.
    static func postText(pid: pid_t, text: String) {
        let src = source
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i ..< min(i + 16, units.count)])
            i += chunk.count
            if chunk == [10] || chunk == [13] { postKey(pid: pid, code: 36, flags: []); continue }
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e.postToPid(pid)
            }
            usleep(10_000)
        }
    }

    enum Button { case left, right }

    /// A click at a screen point (top-left origin, points), routed to `pid` and tagged with the target window
    /// so AppKit can dispatch it to a background window without moving the cursor.
    static func postClick(pid: pid_t, at p: CGPoint, button: Button, count: Int, windowID: CGWindowID?) {
        let src = source
        let (downT, upT, btn): (CGEventType, CGEventType, CGMouseButton) =
            button == .left ? (.leftMouseDown, .leftMouseUp, .left) : (.rightMouseDown, .rightMouseUp, .right)
        for n in 1 ... max(1, min(count, 3)) {
            for t in [downT, upT] {
                guard let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: btn) else { continue }
                e.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                if let windowID {
                    // kCGMouseEventWindowUnderMousePointer / …ThatCanHandleThisEvent
                    if let f = CGEventField(rawValue: 91) { e.setIntegerValueField(f, value: Int64(windowID)) }
                    if let f = CGEventField(rawValue: 92) { e.setIntegerValueField(f, value: Int64(windowID)) }
                }
                e.postToPid(pid)
                usleep(12_000)
            }
        }
    }

    /// Line-based scroll wheel event at a screen point. Positive dy scrolls content down (toward the end).
    static func postScroll(pid: pid_t, at p: CGPoint, dy: Int, dx: Int, windowID: CGWindowID?) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                              wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return }
        e.location = p
        if let windowID, let f = CGEventField(rawValue: 91) { e.setIntegerValueField(f, value: Int64(windowID)) }
        e.postToPid(pid)
    }
}
