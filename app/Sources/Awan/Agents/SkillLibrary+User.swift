import Foundation

/// Additive API: the user's ACTIVE library skills (Skills page, max 3) written as Codex skills so every Awan
/// loads them. They live in `CodexHome/skills/awan-user/<slug>/SKILL.md` and are listed in config.toml as
/// `[[skills.config]]` entries by SKILL.md path (Codex ignores folder paths). Skills switched off are removed.
extension SkillLibrary {
    static let userFolder = "awan-user"

    struct UserSkill: Codable, Equatable {
        var slug: String
        var title: String
        var oneLiner: String
        var content: String
    }

    /// SKILL.md with the front matter Codex needs (`name`, `description`), then the body.
    static func userSkillMarkdown(_ s: UserSkill) -> String {
        let name = safeFolder(s.slug)
        let description = "\(s.title): \(s.oneLiner) The user switched this skill on in Awan; follow it whenever a task fits."
        return "---\nname: \(name)\ndescription: \(yamlString(String(description.prefix(1000))))\n---\n\n# \(s.title)\n\n\(s.content.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    /// Writes `skills` under `<dir>/awan-user/` (only files whose bytes changed), removes folders of skills that
    /// are no longer active, and returns the SKILL.md files in the given order.
    @discardableResult
    static func installUserSkills(_ skills: [UserSkill], into dir: URL) -> [URL] {
        let fm = FileManager.default
        let root = dir.appendingPathComponent(userFolder, isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        var files: [URL] = []
        var keep = Set<String>()
        for s in skills {
            let folder = safeFolder(s.slug)
            guard !folder.isEmpty, !keep.contains(folder) else { continue }
            keep.insert(folder)
            let file = root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("SKILL.md")
            let data = Data(userSkillMarkdown(s).utf8)
            if (try? Data(contentsOf: file)) != data {
                try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            files.append(file)
        }
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !name.hasPrefix(".") && !keep.contains(name) {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        return files
    }

    /// `[[skills.config]]` entries for the user's active skills (always enabled).
    static func userSkillsConfigTOML(_ files: [URL]) -> String {
        files.map { "[[skills.config]]\npath = \(ConnectorStore.tomlString($0.path))\nenabled = true\n" }.joined(separator: "\n")
    }

    /// Slugs come from our server, but never let one escape the folder.
    static func safeFolder(_ slug: String) -> String {
        String(slug.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }.prefix(60))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func yamlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") + "\""
    }
}
