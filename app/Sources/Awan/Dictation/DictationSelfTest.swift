import Foundation
import Speech

/// `Awan --dictation-selftest <file.wav>` — transcribe a recording and run it through the same
/// clean-up path the live dictation uses, then print the result. `--dictation-selftest --text "…"`
/// skips speech-to-text. Server: $AWAN_API or Settings; token: $AWAN_TOKEN, /tmp/awan_token, or the Keychain.
@MainActor
enum DictationSelfTest {
    static func run(_ args: [String]) -> Bool {
        guard let i = args.firstIndex(of: "--dictation-selftest") else { return false }
        let rest = Array(args.dropFirst(i + 1))
        var done = false
        var code: Int32 = 0
        Task {
            code = await perform(rest)
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        exit(code)
    }

    private static func out(_ s: String) { print(s); fflush(stdout) }

    private static func perform(_ rest: [String]) async -> Int32 {
        let env = ProcessInfo.processInfo.environment
        let base = env["AWAN_API"].flatMap(URL.init(string:)) ?? APIClient.shared.baseURL
        let token = env["AWAN_TOKEN"]
            ?? (try? String(contentsOfFile: "/tmp/awan_token", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? APIClient.shared.token
        let dictionary = Prefs.shared.dictionary
        let requestID = "selftest-\(UUID().uuidString)"
        out("server: \(base.absoluteString)   token: \(token == nil ? "none" : "yes")   dictionary: \(dictionary.joined(separator: ", "))")

        var raw = ""
        if rest.first == "--unit" { return unitChecks() }
        if rest.first == "--text" {
            raw = rest.dropFirst().joined(separator: " ")
        } else if let path = rest.first {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { out("no such file: \(path)"); return 2 }
            let t0 = Date()
            if SFSpeechRecognizer.authorizationStatus() == .authorized, let r = SFSpeechRecognizer(), r.isAvailable {
                raw = await appleSpeech(url, recognizer: r)
                out(String(format: "apple speech (%.2fs): %@", Date().timeIntervalSince(t0), raw))
            }
            if raw.isEmpty {
                do {
                    raw = try await DictationCleanup.transcribe(file: url, requestId: requestID, language: nil, dictionary: dictionary, baseURL: base, token: token)
                    out(String(format: "server speech-to-text (%.2fs): %@", Date().timeIntervalSince(t0), raw))
                } catch {
                    out("speech-to-text failed: \(error.localizedDescription)")
                    return 1
                }
            }
        } else {
            out("usage: Awan --dictation-selftest <file.wav> | --dictation-selftest --text \"words\"")
            return 2
        }
        guard !raw.isEmpty else { out("(nothing was said)"); return 1 }

        let t1 = Date()
        let r = await DictationCleanup.clean(raw, requestId: requestID, appName: "Selftest", dictionary: dictionary, language: nil, baseURL: base, token: token)
        out(String(format: "cleanup [%@%@] (%.2fs):", r.source, r.limited ? ", free limit reached" : "", Date().timeIntervalSince(t1)))
        out(r.text)
        out("local tidy: \(DictationCleanup.localTidy(raw, dictionary: dictionary))")
        if r.text.contains("—") || r.text.contains("–") { out("FAIL: em dash in output"); return 1 }
        return 0
    }

    /// The same checks as Tests/AwanTests/DictationTests.swift, runnable without XCTest (CLT toolchain).
    private static func unitChecks() -> Int32 {
        var failed = 0
        func check(_ name: String, _ got: String?, _ want: String?) {
            let ok = got == want
            if !ok { failed += 1 }
            out("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : "  got: \(got ?? "nil")  want: \(want ?? "nil")")")
        }
        check("tidy fillers/stutter", DictationCleanup.localTidy("um so i think the the meeting is at 3", dictionary: []), "So I think the meeting is at 3.")
        check("tidy dictionary", DictationCleanup.localTidy("ask ff dev studio about awan", dictionary: ["FF Dev Studio", "Awan"]), "Ask FF Dev Studio about Awan.")
        check("tidy em dashes", DictationCleanup.localTidy("wait — no — yes", dictionary: []), "Wait, no, yes.")
        check("tidy hyphens kept", DictationCleanup.localTidy("a well-known fact", dictionary: []), "A well-known fact.")
        check("tidy empty", DictationCleanup.localTidy("   ", dictionary: []), "")
        check("strip dashes", DictationCleanup.stripDashes("ship it — today"), "ship it, today")
        check("terminal newlines", TextInserter.collapseNewlines("git status\n\nthen push"), "git status then push")
        check("learn fix", DictionaryLearner.correction(before: "say hi to Cowan today", after: "say hi to Kawan today", typed: ["say", "hi", "to", "cowan", "today"]), "Kawan")
        check("ignore half-typed", DictionaryLearner.correction(before: "say hi to Cowan", after: "say hi to Cowa", typed: ["cowan"]), nil)
        check("ignore additions", DictionaryLearner.correction(before: "hello there", after: "hello there friend", typed: ["hello", "there"]), nil)
        check("learn case fix", DictionaryLearner.correction(before: "my iphone", after: "my iPhone", typed: ["my", "iphone"]), "iPhone")
        out(failed == 0 ? "all passed" : "\(failed) failed")
        return failed == 0 ? 0 : 1
    }

    private static func appleSpeech(_ url: URL, recognizer: SFSpeechRecognizer) async -> String {
        await withCheckedContinuation { cont in
            let req = SFSpeechURLRecognitionRequest(url: url)
            req.addsPunctuation = true
            var resumed = false
            recognizer.recognitionTask(with: req) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal { resumed = true; cont.resume(returning: result.bestTranscription.formattedString) }
                else if error != nil { resumed = true; cont.resume(returning: "") }
            }
        }
    }
}
