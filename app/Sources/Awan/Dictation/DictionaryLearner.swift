import AppKit
import ApplicationServices

/// Auto-dictionary: after Awan types dictated text, watch that field for ~20 s. If the user swaps a
/// word we typed for a different spelling of it ("Kawan" for "Cowan"), learn the new spelling.
@MainActor
final class DictionaryLearner {
    static let shared = DictionaryLearner()
    static let maxWords = 50
    static let watchSeconds = 20

    private var task: Task<Void, Never>?

    func watch(_ element: AXUIElement, inserted: String, onLearn: @escaping (String) -> Void) {
        task?.cancel()
        guard let baseline = TextInserter.string(element, kAXValueAttribute) else { return }
        let typed = Set(Self.words(inserted).map { $0.lowercased() })
        guard !typed.isEmpty else { return }
        task = Task { [weak self] in
            // A candidate must hold still for 1.5 s, so half-typed spellings are never learned.
            var candidate: String?
            var stable = 0
            for _ in 0 ..< Self.watchSeconds * 2 + 3 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, self != nil else { return }
                guard let now = TextInserter.string(element, kAXValueAttribute) else { return }
                let c = now == baseline ? nil : Self.correction(before: baseline, after: now, typed: typed)
                if c != nil, c == candidate { stable += 1 } else { candidate = c; stable = 0 }
                if let word = candidate, stable >= 3 {
                    onLearn(word)
                    return
                }
            }
        }
    }

    func cancel() { task?.cancel() }

    /// A word that replaced one of the words we typed with a close-but-different spelling.
    static func correction(before: String, after: String, typed: Set<String>) -> String? {
        let b = words(before), a = words(after)
        var removed = counts(b), added = counts(a)
        for (w, n) in counts(a) { removed[w, default: 0] -= n }
        for (w, n) in counts(b) { added[w, default: 0] -= n }
        let gone = removed.filter { $0.value > 0 && typed.contains($0.key.lowercased()) }.map(\.key)
        let new = added.filter { $0.value > 0 && $0.key.count >= 2 }.map(\.key)
        guard !gone.isEmpty, !new.isEmpty, new.count <= 3 else { return nil }   // a rewrite, not a fix
        for n in new {
            for g in gone {
                let nl = n.lowercased(), gl = g.lowercased()
                if nl != gl, nl.hasPrefix(gl) || gl.hasPrefix(nl) { continue }   // mid-typing, or a plural
                let close = nl == gl ? n != g : distance(nl, gl) <= max(1, min(3, gl.count / 2))
                if close, !Prefs.shared.dictionary.contains(n) { return n }
            }
        }
        return nil
    }

    static func learn(_ word: String) {
        var d = Prefs.shared.dictionary.filter { $0.caseInsensitiveCompare(word) != .orderedSame }
        d.append(word)
        if d.count > maxWords { d.removeFirst(d.count - maxWords) }
        Prefs.shared.dictionary = d
    }

    static func words(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'-")).inverted).filter { !$0.isEmpty }
    }

    private static func counts(_ w: [String]) -> [String: Int] { w.reduce(into: [:]) { $0[$1, default: 0] += 1 } }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0 ... b.count)
        for i in 1 ... a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1 ... b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
