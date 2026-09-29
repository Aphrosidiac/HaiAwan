import Foundation

/// Every on-disk location Awan uses. Mirrors the reference's layout under Application Support.
enum Paths {
    static let fm = FileManager.default

    /// ~/Library/Application Support/Awan
    static var support: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Awan", isDirectory: true))
    }

    /// Codex runtime home (config.toml, sessions, sqlite, skills).
    static var codexHome: URL { ensure(support.appendingPathComponent("CodexHome", isDirectory: true)) }
    static var codexSkills: URL { ensure(codexHome.appendingPathComponent("skills", isDirectory: true)) }

    /// Agent workspaces: projects/agents/<slug>/ (AGENTS.md, output/, tmp/).
    static var agentsRoot: URL {
        if let custom = UserDefaults.standard.string(forKey: Prefs.Key.agentFolder), !custom.isEmpty {
            return ensure(URL(fileURLWithPath: custom, isDirectory: true))
        }
        return ensure(support.appendingPathComponent("projects/agents", isDirectory: true))
    }

    static func workspace(for slug: String) -> URL {
        let url = ensure(agentsRoot.appendingPathComponent(slug, isDirectory: true))
        ensure(url.appendingPathComponent("output", isDirectory: true))
        ensure(url.appendingPathComponent("tmp", isDirectory: true))
        return url
    }

    /// Local cache of threads, transcripts, suggestions, roster.
    static var homeCache: URL { ensure(support.appendingPathComponent("HomeSpaceCache", isDirectory: true)) }

    /// Memory files injected into the companion and agents (PROFILE.md / VOLATILE.md).
    static var memory: URL { ensure(support.appendingPathComponent("Memory", isDirectory: true)) }

    static var logs: URL { ensure(support.appendingPathComponent("Logs", isDirectory: true)) }

    /// Dictation recordings kept briefly for recovery.
    static var recordings: URL { ensure(support.appendingPathComponent("Recordings", isDirectory: true)) }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Bundled resource directory (Contents/Resources) — falls back to the repo when run unbundled.
    static var resources: URL {
        if let r = Bundle.main.resourceURL, fm.fileExists(atPath: r.appendingPathComponent("Fonts").path) { return r }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Resources")
    }

    /// The vendored codex binary inside the bundle (Contents/Resources/CodexRuntime/bin/codex).
    static var codexBinary: URL? {
        let candidates = [
            resources.appendingPathComponent("CodexRuntime/bin/codex"),
            resources.deletingLastPathComponent().appendingPathComponent("Vendor/codex/bin/codex"),
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }
}
