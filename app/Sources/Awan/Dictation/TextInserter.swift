import AppKit
import ApplicationServices
import Carbon

/// Puts dictated text at the cursor of whatever app is in front.
/// Order (reference: DictationInsertion): Accessibility first (set the focused element's selected
/// text, verified by reading the value back), then pasteboard + a synthetic ⌘V (the user's clipboard is
/// restored afterwards), then clipboard only. Password fields are refused. Terminals get one line.
@MainActor
enum TextInserter {
    enum Outcome: Equatable {
        case inserted(app: String)           // typed via Accessibility (or into Awan's own field)
        case pasted(app: String)             // ⌘V into the app
        case clipboard(reason: String)       // left on the clipboard for the user
        case refusedSecure                   // a password field
        case empty
    }

    /// The element we typed into (for the auto-dictionary watcher). Only set for AX/paste outcomes.
    private(set) static var lastElement: AXUIElement?

    static let terminalBundles: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp", "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty", "io.alacritty", "org.alacritty", "co.zeit.hyper", "com.github.wez.wezterm", "org.tabby",
    ]

    static func insert(_ raw: String) async -> Outcome {
        lastElement = nil
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }

        // 1. Awan's own text fields (the tutorial's practice box, the Home composer).
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable {
            tv.insertText(raw, replacementRange: tv.selectedRange())
            return .inserted(app: "Awan")
        }

        let front = NSWorkspace.shared.frontmostApplication
        let appName = front?.localizedName ?? "the app"
        var text = raw
        if let id = front?.bundleIdentifier, terminalBundles.contains(id) {
            text = collapseNewlines(text)
        }

        guard AXIsProcessTrusted() else {
            copy(text)
            return .clipboard(reason: "accessibility")
        }

        let focused = focusedElement()
        if let el = focused, isSecure(el) { return .refusedSecure }

        if let el = focused, setSelectedText(el, text) {
            lastElement = el
            return .inserted(app: appName)
        }

        if await paste(text) {
            lastElement = focused
            return .pasted(app: appName)
        }
        copy(text)
        return .clipboard(reason: "paste-failed")
    }

    static func collapseNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s*\\n+\\s*", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    // MARK: - Accessibility

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success, let v = value else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func isSecure(_ el: AXUIElement) -> Bool {
        let role = string(el, kAXRoleAttribute) ?? ""
        let subrole = string(el, kAXSubroleAttribute) ?? ""
        return role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String)
    }

    /// Replace the selection with `text`; true only if the field's value visibly changed.
    static func setSelectedText(_ el: AXUIElement, _ text: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
        guard let before = string(el, kAXValueAttribute) else { return false }   // can't verify → paste instead
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { return false }
        let after = string(el, kAXValueAttribute) ?? before
        return after != before
    }

    // MARK: - Paste

    private static func paste(_ text: String) async -> Bool {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
        pb.clearContents()
        guard pb.setString(text, forType: .string) else { return false }
        let ours = pb.changeCount

        guard let src = CGEventSource(stateID: .combinedSessionState) else { return false }
        let v = keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        guard let down, let up else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        // give the target time to read the pasteboard, then put the user's clipboard back
        try? await Task.sleep(for: .milliseconds(450))
        if pb.changeCount == ours, !saved.isEmpty {
            pb.clearContents()
            let items = saved.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (t, data) in dict { item.setData(data, forType: t) }
                return item
            }
            pb.writeObjects(items)
        }
        return true
    }

    /// The key code that types `character` in the current keyboard layout (Dvorak, Colemak, AZERTY…).
    static func keyCode(for character: String) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0 ..< 128 {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var len = 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                if status == noErr, len > 0, String(utf16CodeUnits: chars, count: len) == character { return CGKeyCode(code) }
            }
            return nil
        }
    }
}
