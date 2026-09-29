import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The silent context notes Awan adds to the voice conversation. Each is a fact about the moment (not the user
/// speaking), starts with a bracketed label the voice instructions explain, and is only re-sent when it changed.
@MainActor
enum CompanionNotes {
    // MARK: - Time

    static func time(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy, h:mm a"
        return "[time] \(f.string(from: now)) (\(TimeZone.current.identifier)). this is when the user's next message was sent; treat it as now."
    }

    // MARK: - Front app

    /// "[app] the user is in Safari — window "Pricing · Stripe" (on stripe.com)." nil for Awan itself.
    static func app(_ app: NSRunningApplication?, documentHost: String? = nil) -> String? {
        guard let app, let name = app.localizedName else { return nil }
        var s = "[app] the user is in \(name)"
        if !CompanionTyper.isPrivateApp(app.bundleIdentifier), let title = windowTitle(pid: app.processIdentifier), !title.isEmpty, title != name {
            s += " — window \"\(title.prefix(120))\""
        }
        if let documentHost { s += " (on \(documentHost))" }
        return s + "."
    }

    static func windowTitle(pid: pid_t) -> String? {
        let el = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return (title as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Open document

    /// Routing note: the full text is with the deeper pass, so questions about it go there.
    static func document(_ doc: ActiveDocument) -> String {
        "[open document] the user has the \(doc.kind) \"\(doc.name.prefix(120))\" open (\(doc.text.count) characters). awan read its full text, and ask_deeper gets all of it; the screenshot only shows the visible part. for any question about this document's content, call ask_deeper."
    }

    // MARK: - Drawing (circled / scribbled while talking)

    /// Describes the user's marks in words, like the reference ("the user circled the top-left area of screen 1…"),
    /// plus what's under them from Accessibility. Strokes are AppKit global points.
    static func drawing(_ strokes: [[CGPoint]], frames: [ScreenCaptureFrame]) -> String? {
        let marks = strokes.filter(ScreenCapture.isMeaningfulTrail)
        guard !marks.isEmpty else { return nil }
        var parts: [String] = []
        for (n, stroke) in marks.prefix(4).enumerated() {
            let center = CGPoint(x: stroke.map(\.x).reduce(0, +) / CGFloat(stroke.count), y: stroke.map(\.y).reduce(0, +) / CGFloat(stroke.count))
            let frame = frames.first { $0.geometry.displayFrame.contains(center) } ?? frames.first
            var line = marks.count > 1 ? "\(n + 1)) " : ""
            let shape = classify(stroke)
            if let frame {
                let px = stroke.map { frame.geometry.pixelPoint(fromGlobal: $0) }
                let size = frame.geometry.pixelSize
                let minX = Int(px.map(\.x).min() ?? 0), maxX = Int(px.map(\.x).max() ?? 0)
                let minY = Int(px.map(\.y).min() ?? 0), maxY = Int(px.map(\.y).max() ?? 0)
                let a = region(px.first ?? .zero, in: size), b = region(px.last ?? .zero, in: size)
                let mid = region(CGPoint(x: CGFloat(minX + maxX) / 2, y: CGFloat(minY + maxY) / 2), in: size)
                switch shape {
                case .circle: line += "circled something in the \(mid) of screen \(frame.index)"
                case .line: line += a == b ? "drew a line across the \(a) of screen \(frame.index)" : "drew a line from the \(a) toward the \(b) of screen \(frame.index)"
                case .scribble: line += "scribbled over the \(mid) of screen \(frame.index)"
                }
                line += " (screenshot pixels \(minX),\(minY) to \(maxX),\(maxY); it's the lime mark on the screenshot)"
            } else {
                line += shape == .circle ? "circled something" : shape == .line ? "drew a line" : "scribbled over something"
            }
            if let under = accessibilityDescription(at: center) { line += "; under it: \(under)" }
            parts.append(line)
        }
        let lead = marks.count == 1 ? "while talking, the user " : "while talking, the user drew \(marks.count) marks, in order: "
        return "[drawing] " + lead + parts.joined(separator: "; ") + ". that is exactly what \"this\", \"that\" and \"here\" mean."
    }

    enum StrokeShape { case circle, line, scribble }

    static func classify(_ s: [CGPoint]) -> StrokeShape {
        guard s.count >= 2 else { return .scribble }
        var length: CGFloat = 0
        for i in 1 ..< s.count { length += hypot(s[i].x - s[i - 1].x, s[i].y - s[i - 1].y) }
        let xs = s.map(\.x), ys = s.map(\.y)
        let diag = hypot((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
        let ends = hypot(s[0].x - s[s.count - 1].x, s[0].y - s[s.count - 1].y)
        if length < ends * 1.35 { return .line }
        if ends < diag * 0.35, length > diag * 1.8, length < diag * 5 { return .circle }
        return .scribble
    }

    /// "top-left area", "middle", "bottom-right area" of a screenshot.
    static func region(_ p: CGPoint, in size: CGSize) -> String {
        let col = p.x < size.width / 3 ? "left" : p.x > size.width * 2 / 3 ? "right" : ""
        let row = p.y < size.height / 3 ? "top" : p.y > size.height * 2 / 3 ? "bottom" : ""
        switch (row, col) {
        case ("", ""): return "middle"
        case (_, ""): return "\(row) middle"
        case ("", _): return "\(col) side"
        default: return "\(row)-\(col) area"
        }
    }

    /// The element under a global (AppKit) point: its role, text and link, when Accessibility knows them.
    static func accessibilityDescription(at global: CGPoint) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(global.x), Float(primaryHeight - global.y), &el) == .success, let el else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }
        if let app = NSRunningApplication(processIdentifier: pid), CompanionTyper.isPrivateApp(app.bundleIdentifier) { return nil }
        func attr(_ name: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
        }
        if (attr(kAXSubroleAttribute) as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        let role = (attr(kAXRoleDescriptionAttribute) as? String) ?? (attr(kAXRoleAttribute) as? String)?.replacingOccurrences(of: "AX", with: "").lowercased()
        let text = [(attr(kAXTitleAttribute) as? String), (attr(kAXDescriptionAttribute) as? String), (attr(kAXValueAttribute) as? String)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let url = (attr(kAXURLAttribute) as? URL)?.absoluteString
        guard text != nil || url != nil else { return nil }
        var s = role.map { "a \($0)" } ?? "an element"
        if let text { s += " \"\(text.prefix(160))\"" }
        if let url { s += " (\(url.prefix(200)))" }
        return s
    }

    // MARK: - Awans

    /// The roster note: who the Awans are, what each is doing, what's waiting on the user, and which one a
    /// follow-up without a name most likely means.
    static func awans(store: AgentStore? = nil, lastViewed: (slug: String, until: Date)? = nil, now: Date = Date()) -> String {
        let store = store ?? .shared
        let agents = store.visibleAgents
        guard !agents.isEmpty else {
            return "[awans] the user has no awans yet. real work founds one with start_awan_task and new_awan."
        }
        var lines = ["[awans] the user's awans, persistent agents with their own memory and workspace. address each one by its awan_slug:"]
        var pending: [String] = []
        var latest: (AwanAgent, AgentTurn)?
        for a in agents.prefix(12) {
            let t = store.thread(a.slug)
            var line = "- \(a.name) (awan_slug: \(a.slug)) — \(a.roleText.lowercased()): \(a.oneLiner)"
            if let active = t.activeTurn {
                if active.status == .awaitingApproval {
                    let ask = active.computerUseRequest ?? active.extraUsageRequest ?? "a yes to continue"
                    line += " — WAITING ON THE USER: \(ask.prefix(200))"
                    pending.append(a.name)
                } else {
                    line += " — working on \"\(active.displayPrompt.prefix(140))\" (started \(ago(active.startedAt, now)))"
                    if let p = active.progress.last(where: { $0.kind == .commentary }) { line += ", last update: \"\(p.text.prefix(140))\"" }
                }
            } else if let last = t.turns.last {
                let what = last.summary ?? last.errorText ?? last.displayPrompt
                line += " — \(last.status == .failed ? "last task failed" : last.status == .interrupted ? "last task was stopped" : "idle; last finished") \(ago(last.completedAt ?? last.startedAt, now)): \"\(what.prefix(160))\""
                if last.status == .completed, latest == nil || (last.completedAt ?? .distantPast) > (latest!.1.completedAt ?? .distantPast) { latest = (a, last) }
            } else {
                line += " — hasn't worked yet"
            }
            lines.append(line)
        }
        if pending.count == 1 { lines.append("PENDING REQUEST: \(pending[0]) is waiting on the user. a yes, go ahead or allow answers it with answer_awan_request; no or not now declines.") }
        if pending.count > 1 { lines.append("PENDING REQUESTS: \(pending.joined(separator: ", ")) are waiting; ask which one if the user doesn't say.") }
        if let (a, turn) = latest, let at = turn.completedAt, now.timeIntervalSince(at) < 3 * 3600 {
            lines.append("MOST RECENT REPORT: \(a.name) (awan_slug: \(a.slug)) finished \"\(turn.doneTitle ?? turn.summary ?? turn.displayPrompt)\" \(ago(at, now)). a reply, steer or follow-up that names no awan is most likely for this one: message_awan with its awan_slug.")
        }
        if let v = lastViewed, now.timeIntervalSince(v.until) < 15 * 60, let a = store.agent(v.slug) {
            lines.append("JUST LOOKED AT: the user had \(a.name)'s chat (awan_slug: \(a.slug)) open in Home until \(ago(v.until, now)). a follow-up that names no awan is likely about it. when both this and the most recent report could apply, the more recent one is the likelier.")
        }
        return lines.joined(separator: "\n")
    }

    /// What running Awans said since the last turn (silent; answers "how's it going" without a tool call).
    static func progress(store: AgentStore? = nil, since: Date) -> String? {
        let store = store ?? .shared
        var lines: [String] = []
        for a in store.visibleAgents {
            guard let active = store.thread(a.slug).activeTurn,
                  let p = active.progress.last(where: { $0.kind == .commentary && $0.at > since }) else { continue }
            lines.append("- \(a.name) (awan_slug: \(a.slug)): \"\(p.text.prefix(200))\"")
        }
        guard !lines.isEmpty else { return nil }
        return "[awan progress] what the working awans just said they're doing. context only, not a message to answer:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Home and suggestions

    static func home(state: AppState? = nil, store: AgentStore? = nil) -> String? {
        let state = state ?? .shared, store = store ?? .shared
        guard state.isHomeOpen else { return nil }
        switch state.homePage {
        case let .agent(slug):
            guard let a = store.agent(slug) else { return nil }
            let busy = store.thread(slug).activeTurn != nil
            return "[home] the user has Home open and is looking at \(a.name)'s chat (awan_slug: \(a.slug), \(busy ? "working" : "idle")). they are talking to \(a.name): unless it's clearly small talk or clearly about a different awan, send their words (lightly cleaned) with message_awan to \(a.slug) and then say nothing at all, because the chat on screen shows the message landing."
        case .suggestions:
            return "[home] the user has Home open on their suggestions."
        case .newAwan:
            return "[home] the user has Home open on the page for making a new awan."
        default:
            let names = store.visibleAgents.prefix(8).map(\.name).joined(separator: ", ")
            return "[home] the user has Home open, the dashboard of all their awans (\(names.isEmpty ? "none yet" : names)). treat what they say as direction for the awans by default: work for one of them goes to it (message_awan, or start_awan_task for new work), and new work nobody is doing starts with start_awan_task. answer directly only when it's clearly conversation."
        }
    }

    static func suggestions(state: AppState? = nil) -> String? {
        let state = state ?? .shared
        let open = state.suggestions.filter { $0.status == "pending" || $0.status == "presented" }
        guard state.isHomeOpen, state.homePage == .suggestions, !open.isEmpty else { return nil }
        let lines = open.prefix(6).map { "- suggestion_id \($0.id) for \($0.awanSlug): \"\($0.title)\"" }
        return "[suggestions] task suggestions on screen (the first is the one shown). \"yes, do it\" approves with decide_suggestion; \"no\" or \"next\" skips. never start a different one than the user meant:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Screens

    /// A tiny grayscale thumbnail per screen: two captures that match closely mean the screen didn't change.
    static func fingerprint(_ image: CGImage) -> [UInt8] {
        let w = 48, h = 30
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }

    static func sameScreens(_ a: [[UInt8]], _ b: [[UInt8]]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        for (x, y) in zip(a, b) {
            guard x.count == y.count, !x.isEmpty else { return false }
            var diff = 0
            for i in x.indices { diff += abs(Int(x[i]) - Int(y[i])) }
            if Double(diff) / Double(x.count) > 1.6 { return false }
        }
        return true
    }

    // MARK: - Helpers

    static func ago(_ date: Date, _ now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 45 { return "just now" }
        if s < 3600 { return "\(max(1, s / 60)) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        return "\(s / 86400) days ago"
    }
}
