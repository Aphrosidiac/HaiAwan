import AppKit
import ApplicationServices

/// `[TYPE]…[/TYPE]`: types the companion's text into the app the user was in when they asked.
/// Re-activates that app, optionally focuses the field at the tagged spot, then hands the text to the
/// dictation insertion engine (`TextInserter.insert` — Accessibility, then ⌘V with the clipboard restored,
/// then clipboard only). Refuses password fields, password managers and browser address bars, and never
/// presses Return: the user sends it.
@MainActor
enum CompanionTyper {
    enum Result: Equatable {
        case typed(app: String)
        case clipboard
        case refusedSecure
        case refusedApp(String)
        case refusedAddressBar
        case nothingToType
    }

    /// Password managers: never typed into, never read.
    static let privateBundles: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.dashlane.dashlanephonefinal", "com.lastpass.LastPass",
        "in.sinew.Enpass-Desktop", "com.enpass.Enpass", "org.keepassxc.keepassxc", "com.keepersecurity.keeper", "com.nordpass.NordPass",
    ]

    static func isPrivateApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return privateBundles.contains(id) || id.lowercased().contains("password")
    }

    /// The text as it should go in: no carriage returns, no trailing newline (nothing is ever "sent").
    static func prepared(_ raw: String, singleLine: Bool) -> String {
        var t = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        while t.hasSuffix("\n") { t.removeLast() }
        while t.hasPrefix("\n") { t.removeFirst() }
        if singleLine { t = TextInserter.collapseNewlines(t) }
        return t
    }

    /// - Parameters:
    ///   - app: the app that was frontmost when the user started talking (nil = leave focus alone).
    ///   - point: global AppKit point of the field to focus first (from `[TYPE:x,y]`).
    static func type(_ request: CompanionTypeRequest, into app: NSRunningApplication?, at point: CGPoint?) async -> Result {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothingToType }
        if isPrivateApp(app?.bundleIdentifier) { return .refusedApp(app?.localizedName ?? "that app") }

        // Give focus back to the user's app (the notch composer or Home may hold it).
        NotchFocus.release()
        if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !app.isActive {
            app.activate()
            for _ in 0 ..< 25 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                try? await Task.sleep(for: .milliseconds(40))
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        // TextInserter types into Awan's own key field first; only allow that when Awan was the target.
        if NSApp.isActive, app?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            NSApp.deactivate()
            try? await Task.sleep(for: .milliseconds(80))
        }

        if let point, AXIsProcessTrusted() { await focusField(at: point) }

        var singleLine = false
        if AXIsProcessTrusted(), let el = TextInserter.focusedElement() {
            if TextInserter.isSecure(el) { return .refusedSecure }
            if isAddressBar(el, app: app) { return .refusedAddressBar }
            singleLine = (TextInserter.string(el, kAXRoleAttribute) ?? "") == (kAXTextFieldRole as String)
        }
        let text = prepared(request.text, singleLine: singleLine)
        switch await TextInserter.insert(text) {
        case let .inserted(name), let .pasted(name): return .typed(app: name)
        case .refusedSecure: return .refusedSecure
        case .empty: return .nothingToType
        case .clipboard: return .clipboard
        }
    }

    /// Focus the text field under a global AppKit point: AX focus first, a real click only as a fallback.
    private static func focusField(at point: CGPoint) async {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let axPoint = CGPoint(x: point.x, y: primaryHeight - point.y)   // AX is top-left based
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(axPoint.x), Float(axPoint.y), &hit) == .success, let el = hit else { return }
        if TextInserter.isSecure(el) { return }
        if AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            try? await Task.sleep(for: .milliseconds(80))
            if let f = TextInserter.focusedElement(), CFEqual(f, el) { return }
        }
        guard let src = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: axPoint, mouseButton: .left),
              let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: axPoint, mouseButton: .left) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(150))
    }

    static let browserBundles: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.beta", "org.mozilla.firefox", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen",
    ]

    /// A browser's URL/search field (typing a reply there would navigate away).
    static func isAddressBar(_ el: AXUIElement, app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier, browserBundles.contains(id) else { return false }
        let role = TextInserter.string(el, kAXRoleAttribute) ?? ""
        guard role == (kAXTextFieldRole as String) || role == "AXComboBox" else { return false }
        let hints = [kAXIdentifierAttribute as String, kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute as String]
            .compactMap { TextInserter.string(el, $0)?.lowercased() }
            .joined(separator: " ")
        if ["address", "url", "location", "omnibox", "search or enter", "search or type", "smart search"].contains(where: hints.contains) { return true }
        // Chrome/Safari's field sits in the toolbar, not inside the web area.
        var parent: CFTypeRef?
        var node = el
        for _ in 0 ..< 6 {
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success, let p = parent else { break }
            let pe = p as! AXUIElement
            let r = TextInserter.string(pe, kAXRoleAttribute) ?? ""
            if r == "AXWebArea" { return false }
            if r == (kAXToolbarRole as String) { return true }
            node = pe
        }
        return false
    }
}
