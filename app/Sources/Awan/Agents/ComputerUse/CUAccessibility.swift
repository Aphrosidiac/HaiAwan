import AppKit
import ApplicationServices

/// Maps an AX window element to its CGWindowID. Private but long-stable HIServices symbol, used by every
/// macOS window manager; we fall back to frame matching when it is unavailable.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin, thread-safe wrappers over the Accessibility C API.
enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 2.0)
        return el
    }

    static func raw(_ el: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, name as CFString, &v)
        return (err, v)
    }

    static func value(_ el: AXUIElement, _ name: String) -> CFTypeRef? { raw(el, name).1 }
    static func string(_ el: AXUIElement, _ name: String) -> String? { stringify(value(el, name)) }
    static func bool(_ el: AXUIElement, _ name: String) -> Bool? { value(el, name) as? Bool }
    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] { (value(el, name) as? [AXUIElement]) ?? [] }
    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = value(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(value(el, kAXPositionAttribute)), let s = size(value(el, kAXSizeAttribute)) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func point(_ v: CFTypeRef?) -> CGPoint? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ v: CFTypeRef?) -> CGSize? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    /// Stringifies an attribute value for display (strings, numbers, bools, URLs). Structured values return nil.
    static func stringify(_ v: CFTypeRef?) -> String? {
        guard let v else { return nil }
        if let s = v as? String { return s }
        if CFGetTypeID(v) == CFBooleanGetTypeID() { return (v as! Bool) ? "true" : "false" }
        if let n = v as? NSNumber { return n.stringValue }
        if let u = v as? URL { return u.absoluteString }
        if let a = v as? NSAttributedString { return a.string }
        return nil
    }

    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let list = names as? [String] else { return [] }
        return list
    }

    /// Fetches several attributes in one IPC round trip. Missing attributes come back nil.
    static func multi(_ el: AXUIElement, _ names: [String]) -> [String: CFTypeRef] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let arr = values as? [CFTypeRef], arr.count == names.count else {
            var out: [String: CFTypeRef] = [:]
            for n in names { if let v = value(el, n) { out[n] = v } }
            return out
        }
        var out: [String: CFTypeRef] = [:]
        for (i, n) in names.enumerated() {
            let v = arr[i]
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { continue }
            out[n] = v
        }
        return out
    }

    static func windowID(of window: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(window, &wid) == .success && wid != 0 ? wid : nil
    }

    /// The AX window element for a CGWindowID of `pid` — by id, then by frame.
    static func window(pid: pid_t, windowID: CGWindowID, cgBounds: CGRect?) -> AXUIElement? {
        let wins = elements(app(pid), kAXWindowsAttribute)
        if let hit = wins.first(where: { self.windowID(of: $0) == windowID }) { return hit }
        if let b = cgBounds {
            return wins.first { w in
                guard let f = frame(w) else { return false }
                return abs(f.minX - b.minX) < 2 && abs(f.minY - b.minY) < 2 && abs(f.width - b.width) < 2 && abs(f.height - b.height) < 2
            }
        }
        return nil
    }

    static func describe(_ err: AXError) -> String {
        switch err {
        case .apiDisabled: return "Accessibility permission isn't granted to Awan (System Settings → Privacy & Security → Accessibility)"
        case .actionUnsupported: return "the element doesn't support that action"
        case .attributeUnsupported: return "the element doesn't support that attribute"
        case .cannotComplete: return "the app didn't answer in time (busy or hung)"
        case .invalidUIElement: return "the element no longer exists"
        case .illegalArgument: return "illegal argument"
        case .notImplemented: return "the app doesn't implement that"
        default: return "AX error \(err.rawValue)"
        }
    }
}

// MARK: - Snapshots and element tokens

/// One `get_window_state` result: the actionable elements, in order, plus what pixel clicks need
/// (the window frame in screen points and the screenshot's pixels-per-point).
struct CUSnapshot {
    let id: Int
    let pid: pid_t
    let windowID: CGWindowID
    let windowFrame: CGRect
    let elements: [AXUIElement]
    var imageScale: CGFloat?
}

enum CUError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case let .message(m) = self { return m }; return "error" }
}

/// Holds snapshots; tokens look like `s12e4` (snapshot 12, element 4). A newer snapshot of the same
/// window supersedes older tokens, which then fail closed.
final class CUSnapshotStore: @unchecked Sendable {
    private var byID: [Int: CUSnapshot] = [:]
    private var latestForWindow: [String: Int] = [:]
    private var nextID = 1
    private let lock = NSLock()

    var count: Int { lock.lock(); defer { lock.unlock() }; return byID.count }

    private func key(_ pid: pid_t, _ wid: CGWindowID) -> String { "\(pid)/\(wid)" }

    func reserveID() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    func store(_ snap: CUSnapshot) {
        lock.lock(); defer { lock.unlock() }
        byID[snap.id] = snap
        latestForWindow[key(snap.pid, snap.windowID)] = snap.id
        // Keep memory bounded: only the latest snapshot per window, and at most 24 windows.
        let live = Set(latestForWindow.values)
        byID = byID.filter { live.contains($0.key) }
        if byID.count > 24, let oldest = byID.keys.min() {
            byID.removeValue(forKey: oldest)
            latestForWindow = latestForWindow.filter { $0.value != oldest }
        }
    }

    func setImageScale(_ scale: CGFloat, for id: Int) {
        lock.lock(); defer { lock.unlock() }
        byID[id]?.imageScale = scale
    }

    func latest(pid: pid_t, windowID: CGWindowID) -> CUSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let id = latestForWindow[key(pid, windowID)] else { return nil }
        return byID[id]
    }

    func resolve(_ token: String) throws -> (CUSnapshot, AXUIElement) {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.hasPrefix("s"), let e = t.firstIndex(of: "e"),
              let sid = Int(t[t.index(after: t.startIndex) ..< e]), let idx = Int(t[t.index(after: e)...]) else {
            throw CUError.message("'\(token)' isn't an element token. Tokens look like s12e4 and come from the latest get_window_state.")
        }
        lock.lock(); defer { lock.unlock() }
        guard let snap = byID[sid] else {
            throw CUError.message("stale element token \(token): that snapshot is gone. Call get_window_state again and use a fresh token.")
        }
        if let latest = latestForWindow[key(snap.pid, snap.windowID)], latest != sid {
            throw CUError.message("stale element token \(token): window \(snap.windowID) was re-snapshotted as s\(latest). Use a token from the latest get_window_state.")
        }
        guard idx >= 0, idx < snap.elements.count else {
            throw CUError.message("element \(idx) isn't in snapshot s\(sid) (it has \(snap.elements.count) elements).")
        }
        return (snap, snap.elements[idx])
    }
}

// MARK: - Tree walking

/// Walks a window's AX tree into a compact, indented list of actionable or labelled elements.
struct CUTreeWalker {
    struct Record {
        var index: Int
        var depth: Int
        var role: String
        var subrole: String?
        var label: String?
        var value: String?
        var frame: CGRect?
        var enabled: Bool
        var focused: Bool
        var selected: Bool
    }

    var maxElements = 300
    var maxDepth = 40
    var maxVisited = 6000
    var query: String?

    static let attrs = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                        kAXPlaceholderValueAttribute, kAXHelpAttribute, kAXPositionAttribute, kAXSizeAttribute,
                        kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute, kAXChildrenAttribute, "AXIdentifier"]

    static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
        "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXSlider", "AXIncrementor",
        "AXDisclosureTriangle", "AXColorWell", "AXCell", "AXRow", "AXTab", "AXSegmentedControl", "AXDateField",
        "AXStepper", "AXSwitch", "AXToggle", "AXOutlineRow", "AXDockItem",
    ]
    static let landmarkRoles: Set<String> = ["AXWindow", "AXSheet", "AXDialog", "AXToolbar", "AXTable", "AXOutline",
                                             "AXList", "AXWebArea", "AXTabGroup", "AXBrowser", "AXPopover", "AXMenu"]

    private(set) var records: [Record] = []
    private(set) var elements: [AXUIElement] = []
    private(set) var truncated = false
    private var visited = 0

    mutating func walk(_ root: AXUIElement) {
        visit(root, depth: 0)
    }

    private mutating func visit(_ el: AXUIElement, depth: Int) {
        guard visited < maxVisited else { truncated = true; return }
        visited += 1
        let v = AX.multi(el, Self.attrs)
        let role = AX.stringify(v[kAXRoleAttribute]) ?? "AXUnknown"
        let title = clean(AX.stringify(v[kAXTitleAttribute]))
        let desc = clean(AX.stringify(v[kAXDescriptionAttribute]))
        let rawValue = AX.stringify(v[kAXValueAttribute])
        let placeholder = clean(AX.stringify(v[kAXPlaceholderValueAttribute]))
        let help = clean(AX.stringify(v[kAXHelpAttribute]))
        let label = title ?? desc ?? (role == "AXStaticText" ? nil : placeholder) ?? help ?? clean(AX.stringify(v["AXIdentifier"]))
        let value = clean(rawValue, limit: 160)
        let hasText = label != nil || (value != nil && role != "AXScrollBar")
        var include = Self.interactiveRoles.contains(role) || Self.landmarkRoles.contains(role) || hasText
        if role == "AXGroup" || role == "AXUnknown" || role == "AXSplitter" || role == "AXLayoutArea" || role == "AXScrollBar" || role == "AXValueIndicator" {
            include = hasText && role != "AXScrollBar" && role != "AXValueIndicator"
        }
        if let q = query?.lowercased(), !q.isEmpty {
            include = include && [role, label ?? "", value ?? ""].contains { $0.lowercased().contains(q) }
        }
        var childDepth = depth
        if include {
            if records.count >= maxElements { truncated = true; return }
            let frame: CGRect? = {
                guard let p = AX.point(v[kAXPositionAttribute]), let s = AX.size(v[kAXSizeAttribute]) else { return nil }
                return CGRect(origin: p, size: s)
            }()
            records.append(Record(index: records.count, depth: depth, role: role, subrole: AX.stringify(v[kAXSubroleAttribute]),
                                  label: label, value: value, frame: frame,
                                  enabled: (v[kAXEnabledAttribute] as? Bool) ?? true,
                                  focused: (v[kAXFocusedAttribute] as? Bool) ?? false,
                                  selected: (v[kAXSelectedAttribute] as? Bool) ?? false))
            elements.append(el)
            childDepth = depth + 1
        }
        guard depth < maxDepth, let kids = v[kAXChildrenAttribute] as? [AXUIElement] else { return }
        for k in kids {
            if records.count >= maxElements { truncated = true; return }
            visit(k, depth: childDepth)
        }
    }

    private func clean(_ s: String?, limit: Int = 90) -> String? {
        guard var s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        if s.count > limit { s = String(s.prefix(limit)) + "…" }
        return s
    }

    /// `[s3e12] AXButton "Save" = "value" (disabled, focused)` lines, indented by depth.
    func markdown(snapshotID: Int, windowFrame: CGRect) -> String {
        records.map { r in
            var line = String(repeating: "  ", count: min(r.depth, 20)) + "[s\(snapshotID)e\(r.index)] \(r.role)"
            if let sr = r.subrole, sr != "AXStandardWindow", !sr.isEmpty { line += "/\(sr.replacingOccurrences(of: "AX", with: ""))" }
            if let l = r.label { line += " \"\(l)\"" }
            if let v = r.value, v != r.label { line += " = \"\(v)\"" }
            var flags: [String] = []
            if !r.enabled { flags.append("disabled") }
            if r.focused { flags.append("focused") }
            if r.selected { flags.append("selected") }
            if !flags.isEmpty { line += " (\(flags.joined(separator: ", ")))" }
            return line
        }.joined(separator: "\n")
    }
}
