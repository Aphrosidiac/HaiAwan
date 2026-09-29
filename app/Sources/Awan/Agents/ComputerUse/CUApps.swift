import AppKit

/// App and window discovery, and background-safe launching.
enum CUApps {
    struct WindowInfo {
        let id: CGWindowID
        let pid: pid_t
        let app: String
        var title: String
        let bounds: CGRect
        let onScreen: Bool
        let z: Int?

        var json: [String: Any] {
            var j: [String: Any] = [
                "window_id": Int(id), "pid": Int(pid), "app": app, "title": title,
                "bounds": ["x": Int(bounds.minX), "y": Int(bounds.minY), "width": Int(bounds.width), "height": Int(bounds.height)],
                "is_on_screen": onScreen,
            ]
            if let z { j["z_index"] = z }
            return j
        }
    }

    /// Normal (layer 0) windows, front to back for the on-screen ones. Tiny helper surfaces are skipped.
    static func windows(pid: pid_t? = nil, onScreenOnly: Bool = false) -> [WindowInfo] {
        let opts: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [WindowInfo] = []
        var z = 0
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let owner = w[kCGWindowOwnerPID as String] as? Int32,
                  let num = w[kCGWindowNumber as String] as? Int,
                  let bd = w[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
            let on = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let zi: Int? = on ? z : nil
            if on { z += 1 }
            if let pid, owner != pid { continue }
            guard bounds.width >= 60, bounds.height >= 40, ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0 else { continue }
            out.append(WindowInfo(id: CGWindowID(num), pid: owner, app: (w[kCGWindowOwnerName as String] as? String) ?? "",
                                  title: (w[kCGWindowName as String] as? String) ?? "", bounds: bounds, onScreen: on, z: zi))
        }
        // Fill blank titles from AX where we can read it.
        let pids = Set(out.filter { $0.title.isEmpty }.map(\.pid))
        for p in pids where AX.trusted {
            for axw in AX.elements(AX.app(p), kAXWindowsAttribute) {
                guard let wid = AX.windowID(of: axw), let t = AX.string(axw, kAXTitleAttribute), !t.isEmpty,
                      let i = out.firstIndex(where: { $0.id == wid }) else { continue }
                if out[i].title.isEmpty { out[i].title = t }
            }
        }
        return out
    }

    static func window(_ id: CGWindowID) -> WindowInfo? { windows().first { $0.id == id } }

    static func appJSON(_ a: NSRunningApplication, frontPID: pid_t?) -> [String: Any] {
        var j: [String: Any] = ["name": a.localizedName ?? "", "pid": Int(a.processIdentifier), "active": a.processIdentifier == frontPID,
                                "hidden": a.isHidden]
        if let b = a.bundleIdentifier { j["bundle_id"] = b }
        return j
    }

    static func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
    }

    static let appFolders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                             NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]

    static func installedApps() -> [[String: Any]] {
        var out: [[String: Any]] = []
        var seen = Set<String>()
        for folder in appFolders {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for item in items where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(item)
                guard let b = Bundle(url: url)?.bundleIdentifier, !seen.contains(b) else { continue }
                if folder == "/System/Library/CoreServices", b != "com.apple.finder" { continue }
                seen.insert(b)
                out.append(["name": String(item.dropLast(4)), "bundle_id": b])
            }
        }
        return out.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    /// Resolves an app bundle by id or display name.
    static func appURL(bundleID: String?, name: String?) -> URL? {
        if let b = bundleID, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) { return u }
        guard let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return nil }
        if let running = runningApps().first(where: { $0.localizedName?.caseInsensitiveCompare(n) == .orderedSame }), let u = running.bundleURL { return u }
        for folder in appFolders {
            let u = URL(fileURLWithPath: folder).appendingPathComponent(n.hasSuffix(".app") ? n : n + ".app")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static func url(from s: String) -> URL? {
        if s.hasPrefix("~") { return URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        if let u = URL(string: s), u.scheme != nil { return u }
        return URL(string: "https://" + s)
    }

    /// Launches (or reuses) an app without activating it, and undoes the app's own attempt to come forward.
    static func launch(bundleID: String?, name: String?, urls: [String], newInstance: Bool, arguments: [String]) -> Result<[String: Any], CUError> {
        guard let appURL = appURL(bundleID: bundleID, name: name) else {
            return .failure(.message("couldn't find an app for \(bundleID ?? name ?? "(nothing given)"). Use list_apps (include_installed: true) to see what's installed."))
        }
        let before = NSWorkspace.shared.frontmostApplication
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        cfg.hides = false
        cfg.createsNewApplicationInstance = newInstance
        cfg.arguments = arguments
        cfg.promptsUserIfNeeded = false

        final class Box: @unchecked Sendable { var app: NSRunningApplication?; var error: String? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let handler: (NSRunningApplication?, Error?) -> Void = { app, err in
            box.app = app
            box.error = err?.localizedDescription
            sem.signal()
        }
        let fileURLs = urls.compactMap(url(from:))
        if fileURLs.isEmpty {
            NSWorkspace.shared.openApplication(at: appURL, configuration: cfg, completionHandler: handler)
        } else {
            NSWorkspace.shared.open(fileURLs, withApplicationAt: appURL, configuration: cfg, completionHandler: handler)
        }
        if sem.wait(timeout: .now() + 20) == .timedOut { return .failure(.message("the app didn't finish launching within 20 s")) }
        guard let app = box.app else { return .failure(.message("launch failed: \(box.error ?? "unknown error")")) }

        // Focus-restore guard: if the target pulled itself forward, hand the front back to the user's app.
        var suppressed = false
        let deadline = Date().addingTimeInterval(1.5)
        var windows: [WindowInfo] = []
        while Date() < deadline {
            if let before, before.processIdentifier != app.processIdentifier,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                before.activate(options: [])
                suppressed = true
            }
            windows = CUApps.windows(pid: app.processIdentifier)
            if !windows.isEmpty && Date() > deadline.addingTimeInterval(-1.0) { break }
            usleep(150_000)
        }
        if windows.isEmpty {
            // Slow starters: give windows a little longer to appear.
            for _ in 0 ..< 12 { usleep(250_000); windows = CUApps.windows(pid: app.processIdentifier); if !windows.isEmpty { break } }
        }
        var j = appJSON(app, frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        j["windows"] = windows.map(\.json)
        j["self_activation_suppressed"] = suppressed
        return .success(j)
    }
}
