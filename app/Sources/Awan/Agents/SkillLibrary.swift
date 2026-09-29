import Foundation

/// OWNER: computer-use/skills builder. Awan's bundled Codex skills (our own SKILL.md files in
/// app/Resources/Skills/<name>/SKILL.md). The runtime builder calls install() before starting Codex.
///
/// Runtime contract: `install(into: Paths.codexSkills)` before launching Codex (cheap when nothing changed),
/// then append `configTOML(skillsDirectory:obsidianEnabled:)` to config.toml so the obsidian skill is only
/// enabled when a vault is configured (`ConnectorStore.shared.obsidianVaultPath != nil`).
enum SkillLibrary {
    /// Where the bundled skills live (Contents/Resources/Skills, or app/Resources/Skills when unbundled).
    static var sourceDirectory: URL { Paths.resources.appendingPathComponent("Skills", isDirectory: true) }

    /// Skills that only make sense with local configuration; disabled in the config until it exists.
    static let obsidianSkill = "obsidian"

    /// Folder names of every bundled skill (each holds a SKILL.md), sorted.
    static var bundledNames: [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: sourceDirectory.path)) ?? []
        return names.filter { fm.fileExists(atPath: sourceDirectory.appendingPathComponent($0).appendingPathComponent("SKILL.md").path) }.sorted()
    }

    /// Files copied by the most recent install (0 when everything was already current).
    private(set) static var lastCopiedCount = 0

    /// Copies bundled skills into `dir` (CodexHome/skills) and returns the installed skill folders.
    /// Only files whose bytes differ are written; files we used to ship but no longer do are removed from
    /// our own skill folders. Skills the user added themselves are never touched.
    @discardableResult
    static func install(into dir: URL) -> [URL] {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var installed: [URL] = []
        var copied = 0
        for name in bundledNames {
            let src = sourceDirectory.appendingPathComponent(name, isDirectory: true)
            let dst = dir.appendingPathComponent(name, isDirectory: true)
            copied += sync(src, dst)
            installed.append(dst)
        }
        lastCopiedCount = copied
        if copied > 0 { Log.info("skills: installed \(installed.count) skills into \(dir.path) (\(copied) files updated)") }
        return installed
    }

    /// `[[skills.config]]` entries for Codex's config.toml. Codex 0.158 matches `path` against the SKILL.md
    /// file itself — a folder path is silently ignored (verified with `skills/list`), so we point at the file.
    static func configTOML(skillsDirectory dir: URL, obsidianEnabled: Bool) -> String {
        bundledNames.map { name in
            let path = dir.appendingPathComponent(name).appendingPathComponent("SKILL.md").path
            let enabled = name == obsidianSkill ? obsidianEnabled : true
            return "[[skills.config]]\npath = \(ConnectorStore.tomlString(path))\nenabled = \(enabled)\n"
        }.joined(separator: "\n")
    }

    /// Parsed front matter (`name`, `description`) of a SKILL.md, or nil when it's missing/malformed.
    static func frontMatter(of skillFile: URL) -> [String: String]? {
        guard let text = try? String(contentsOf: skillFile, encoding: .utf8), text.hasPrefix("---\n") else { return nil }
        let body = text.dropFirst(4)
        guard let end = body.range(of: "\n---") else { return nil }
        var out: [String: String] = [:]
        for line in body[..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" { value = String(value.dropFirst().dropLast()) }
            out[key] = value
        }
        return out
    }

    // MARK: Private

    /// Mirrors `src` into `dst`; returns how many files were written or removed.
    private static func sync(_ src: URL, _ dst: URL) -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        var changed = 0
        var shipped = Set<String>()
        let srcPath = src.resolvingSymlinksInPath().path
        if let walker = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) {
            for case let file as URL in walker {
                let rel = String(file.resolvingSymlinksInPath().path.dropFirst(srcPath.count + 1))
                guard !rel.isEmpty, !rel.hasPrefix("."), !rel.contains("/.") else { continue }
                let target = dst.appendingPathComponent(rel)
                if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                    continue
                }
                shipped.insert(rel)
                guard let data = try? Data(contentsOf: file) else { continue }
                if let existing = try? Data(contentsOf: target), existing == data { continue }
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? data.write(to: target, options: .atomic)) != nil {
                    changed += 1
                    if let perms = (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] {
                        try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: target.path)
                    }
                }
            }
        }
        // Remove files from an older bundle that this version no longer ships.
        let dstPath = dst.resolvingSymlinksInPath().path
        if let walker = fm.enumerator(at: dst, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in walker {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let rel = String(file.resolvingSymlinksInPath().path.dropFirst(dstPath.count + 1))
                if !rel.hasPrefix("."), !shipped.contains(rel) {
                    try? fm.removeItem(at: file)
                    changed += 1
                }
            }
        }
        return changed
    }
}
