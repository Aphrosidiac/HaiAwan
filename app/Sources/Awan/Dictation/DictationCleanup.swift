import Foundation

/// Transcript → clean text. Server clean-up first (`POST /v1/dictation/cleanup`), local tidy when
/// offline. A 402 means the free dictation allowance is used up: the caller inserts the local tidy.
enum DictationCleanup {
    struct Result {
        var text: String
        var source: String      // model | local | offline
        var limited = false     // 402 from the server
    }

    struct Body: Encodable {
        var text: String
        var dictionary: [String]
        var appName: String?
        var language: String?
        var requestId: String
    }

    private struct Reply: Decodable { var text: String; var source: String? }

    static func clean(_ raw: String, requestId: String, appName: String?, dictionary: [String], language: String?,
                      baseURL: URL? = nil, token: String? = nil) async -> Result {
        let body = Body(text: raw, dictionary: Array(dictionary.prefix(50)), appName: appName, language: language, requestId: requestId)
        let api = APIClient.shared
        do {
            var req = try api.request("v1/dictation/cleanup", method: "POST", body: body, auth: token == nil)
            if let baseURL { req.url = baseURL.appendingPathComponent("v1/dictation/cleanup") }
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            req.timeoutInterval = 12
            let (data, resp) = try await URLSession.shared.data(for: req)
            try api.check(resp, data)
            let r = try JSONDecoder().decode(Reply.self, from: data)
            let text = stripDashes(r.text).trimmingCharacters(in: .whitespacesAndNewlines)   // belt and braces
            return Result(text: text.isEmpty ? localTidy(raw, dictionary: dictionary) : text, source: r.source ?? "model")
        } catch APIError.quotaExceeded {
            return Result(text: localTidy(raw, dictionary: dictionary), source: "local", limited: true)
        } catch {
            Log.info("dictation cleanup offline: \(error.localizedDescription)")
            return Result(text: localTidy(raw, dictionary: dictionary), source: "offline")
        }
    }

    /// Server-side speech-to-text of a recording (used when Apple Speech isn't available).
    static func transcribe(file: URL, requestId: String, language: String?, dictionary: [String],
                           baseURL: URL? = nil, token: String? = nil, countAsDictation: Bool = true) async throws -> String {
        struct T: Encodable { var audio: String; var format = "wav"; var language: String?; var dictionary: [String]; var kind: String?; var requestId: String }
        struct R: Decodable { var text: String }
        let data = try Data(contentsOf: file)
        let api = APIClient.shared
        var req = try api.request("v1/transcribe", method: "POST", body: T(audio: data.base64EncodedString(), language: language, dictionary: Array(dictionary.prefix(50)), kind: countAsDictation ? "dictation" : nil, requestId: requestId), auth: token == nil)
        if let baseURL { req.url = baseURL.appendingPathComponent("v1/transcribe") }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 60
        let (d, resp) = try await URLSession.shared.data(for: req)
        try api.check(resp, d)
        return try JSONDecoder().decode(R.self, from: d).text
    }

    // MARK: - Local tidy (mirror of server/src/dictation.ts localTidy)

    /// Em/en dashes used as punctuation become commas; hyphenated words are untouched.
    static func stripDashes(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\\s*[—–]\\s*", with: ", ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s*--+\\s*", with: ", ", options: .regularExpression)
        s = s.replacingOccurrences(of: ",\\s*,", with: ",", options: .regularExpression)
        s = s.replacingOccurrences(of: ",\\s*([.!?])", with: "$1", options: .regularExpression)
        return s.replacingOccurrences(of: "^[,\\s]+", with: "", options: .regularExpression)
    }

    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "hm", "mm", "mhm"]

    static func localTidy(_ text: String, dictionary: [String]) -> String {
        var s = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "" }
        // fillers (with a trailing comma)
        let tokens = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var kept: [String] = []
        for t in tokens {
            let bare = t.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)
            if fillers.contains(bare) {
                // keep sentence-ending punctuation that was attached to a filler
                if let last = t.last, ".!?".contains(last), var prev = kept.popLast() {
                    prev = prev.trimmingCharacters(in: CharacterSet(charactersIn: ","))
                    kept.append(prev + String(last))
                }
                continue
            }
            kept.append(t)
        }
        s = kept.joined(separator: " ")
        s = stripDashes(s)
        // stutters: "the the" → "the"
        s = s.replacingOccurrences(of: "\\b(\\w+)(\\s+\\1\\b)+", with: "$1", options: [.regularExpression, .caseInsensitive])
        // dictionary spellings win
        for term in dictionary where !term.trimmingCharacters(in: .whitespaces).isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            s = s.replacingOccurrences(of: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])", with: NSRegularExpression.escapedTemplate(for: term), options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "\\bi\\b", with: "I", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\bi'(m|ll|d|ve)\\b", with: "I'$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        // capitalise sentence starts
        var out = ""
        var capitalizeNext = true
        for ch in s {
            if capitalizeNext, ch.isLetter {
                out.append(contentsOf: String(ch).uppercased())
                capitalizeNext = false
            } else {
                out.append(ch)
                if ".!?".contains(ch) { capitalizeNext = true } else if !ch.isWhitespace { capitalizeNext = false }
            }
        }
        s = out.trimmingCharacters(in: .whitespaces)
        if let last = s.last, !".!?…\"')]".contains(last) { s += "." }
        return s
    }
}
