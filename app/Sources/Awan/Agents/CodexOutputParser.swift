import Foundation

/// A `<ROUTINE>{…}</ROUTINE>` command from an agent's final message.
struct RoutineCommand: Equatable {
    enum Action: String { case create, update, pause, resume, delete }
    var action: Action
    var everyMinutes: Int?
    var title: String?
    var task: String?
    var newTitle: String?
}

/// Awan's agent output protocol, parsed out of the final message of a turn:
/// the answer, then `<SUMMARY>`, `<NEXT_ACTIONS>`, `<DONE_TITLE>`, `<ARTIFACTS>`, `<ROUTINE>`,
/// `<COMPUTER_USE_REQUEST>` (see server/src/prompts.ts AGENT_MODEL_INSTRUCTIONS).
struct AgentOutput: Equatable {
    /// The answer with every protocol block removed (markdown).
    var body: String = ""
    var summary: String?
    var nextActions: [String] = []
    var doneTitle: String?
    /// Raw entries (paths or URLs), unverified.
    var artifacts: [String] = []
    var routines: [RoutineCommand] = []
    var computerUseRequest: String?

    static let tags = ["SUMMARY", "NEXT_ACTIONS", "DONE_TITLE", "ARTIFACTS", "ROUTINE", "COMPUTER_USE_REQUEST"]

    static func parse(_ text: String) -> AgentOutput {
        var out = AgentOutput()
        var body = text
        var blocks: [(tag: String, content: String)] = []

        for tag in tags {
            // Closed blocks (any number), case-insensitive.
            let closed = try! NSRegularExpression(pattern: "<\(tag)>(.*?)</\(tag)>", options: [.caseInsensitive, .dotMatchesLineSeparators])
            while let m = closed.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                  let whole = Range(m.range, in: body), let inner = Range(m.range(at: 1), in: body) {
                blocks.append((tag, String(body[inner])))
                body.removeSubrange(whole)
            }
            // An unclosed block the model forgot to close runs to the next tag or the end.
            let open = try! NSRegularExpression(pattern: "<\(tag)>(.*?)(?=<[A-Z_]{5,}>|\\z)", options: [.caseInsensitive, .dotMatchesLineSeparators])
            while let m = open.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                  let whole = Range(m.range, in: body), let inner = Range(m.range(at: 1), in: body) {
                blocks.append((tag, String(body[inner])))
                body.removeSubrange(whole)
            }
        }

        for (tag, raw) in blocks {
            let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch tag {
            case "SUMMARY":
                if !content.isEmpty { out.summary = plain(oneLine(content)) }
            case "NEXT_ACTIONS":
                out.nextActions += listItems(content).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".;")) }.filter { !$0.isEmpty }
            case "DONE_TITLE":
                let t = oneLine(content).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.").union(.whitespaces))
                if !t.isEmpty { out.doneTitle = t }
            case "ARTIFACTS":
                out.artifacts += listItems(content).map(cleanArtifact).filter { !$0.isEmpty }
            case "ROUTINE":
                out.routines += routineCommands(content)
            case "COMPUTER_USE_REQUEST":
                if !content.isEmpty { out.computerUseRequest = content }
            default: break
            }
        }
        out.nextActions = Array(out.nextActions.uniqued().prefix(4))
        out.artifacts = Array(out.artifacts.uniqued().prefix(8))
        out.body = cleanBody(body)
        return out
    }

    // MARK: - Pieces

    private static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Spoken text: no markdown emphasis, code ticks or link syntax.
    static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// "- a", "* b", "• c", "1. d" → items; bare lines count too.
    static func listItems(_ s: String) -> [String] {
        s.components(separatedBy: .newlines).compactMap { line in
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("```") { return nil }
            if let r = l.range(of: #"^([-*•]|\d+[.)])\s*"#, options: .regularExpression) { l.removeSubrange(r) }
            l = l.trimmingCharacters(in: .whitespaces)
            return l.isEmpty ? nil : l
        }
    }

    private static func cleanArtifact(_ s: String) -> String {
        var v = s.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'<>").union(.whitespaces))
        // "[name](path)" markdown links → the target
        if let m = v.range(of: #"\]\(([^)]+)\)"#, options: .regularExpression) {
            v = String(v[m]).dropFirst(2).dropLast().description
        }
        if v.hasPrefix("file://"), let u = URL(string: v) { v = u.path }
        return v
    }

    private static func routineCommands(_ s: String) -> [RoutineCommand] {
        // One JSON object per block, but tolerate several objects or a JSON array.
        var objects: [[String: Any]] = []
        let trimmed = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data) {
            if let o = any as? [String: Any] { objects = [o] } else if let a = any as? [[String: Any]] { objects = a }
        } else {
            for line in trimmed.components(separatedBy: .newlines) {
                if let data = line.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { objects.append(o) }
            }
        }
        return objects.compactMap { o in
            guard let a = (o["action"] as? String)?.lowercased(), let action = RoutineCommand.Action(rawValue: a) else { return nil }
            func int(_ k: String) -> Int? {
                if let n = o[k] as? NSNumber { return n.intValue }
                if let s = o[k] as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
                return nil
            }
            func str(_ k: String) -> String? {
                (o[k] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            return RoutineCommand(
                action: action,
                everyMinutes: int("every_minutes") ?? int("everyMinutes"),
                title: str("title"),
                task: str("task"),
                newTitle: str("new_title") ?? str("newTitle")
            )
        }
    }

    /// Drops old-style "File: /path" lines, empty code fences left behind by stripped blocks, and trailing blank lines.
    private static func cleanBody(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"(?m)^\s*```[a-z]*\s*\n\s*```\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix("```"), t.components(separatedBy: "```").count % 2 == 0 { t = String(t.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return t
    }

    /// The headline of a reasoning summary part: its leading `**Bold title**`, else its first line (≤ 60 chars).
    static func headline(fromReasoning text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let r = t.range(of: #"\*\*([^*\n]{2,80})\*\*"#, options: .regularExpression) {
            return String(t[r]).trimmingCharacters(in: CharacterSet(charactersIn: "*")).trimmingCharacters(in: .whitespaces)
        }
        let first = t.components(separatedBy: .newlines).first ?? t
        return first.count > 60 ? String(first.prefix(57)) + "…" : first
    }
}
