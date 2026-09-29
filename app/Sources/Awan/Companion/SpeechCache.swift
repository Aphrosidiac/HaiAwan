import Foundation
import CryptoKit

/// Rendered speech clips (24 kHz mono PCM16), keyed by voice + speed + exact text.
/// Lookup order: clips bundled in Resources/SpeechCache (voice previews, onboarding lines — they play
/// instantly, even signed out or offline), then the local cache in Application Support, then the server.
/// Anything fetched from the server is saved for next time.
enum SpeechCache {
    static func key(voice: String, speed: Double, text: String) -> String {
        let s = "\(voice)|\(String(format: "%.2f", speed))|\(text)"
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static var localDir: URL { Paths.ensure(Paths.support.appendingPathComponent("SpeechCache", isDirectory: true)) }
    static var bundledDir: URL { Paths.resources.appendingPathComponent("SpeechCache", isDirectory: true) }

    static func lookup(_ key: String) -> Data? {
        for dir in [bundledDir, localDir] {
            let f = dir.appendingPathComponent("\(key).pcm")
            if let d = try? Data(contentsOf: f), !d.isEmpty { return d }
        }
        return nil
    }

    static func store(_ key: String, _ pcm: Data) {
        guard pcm.count > 4800 else { return }           // < 0.1 s is a failed render, don't keep it
        try? pcm.write(to: localDir.appendingPathComponent("\(key).pcm"), options: .atomic)
    }

    /// Cached-or-streamed PCM for a /v1/speech body.
    static func stream(_ body: [String: JSON]) -> AsyncThrowingStream<Data, Error> {
        let text = body["text"]?.string ?? ""
        let voice = body["voice"]?.string ?? "cedar"
        let speed = body["speed"]?.double ?? 1
        let k = key(voice: voice, speed: speed, text: text)
        if let hit = lookup(k) {
            return AsyncThrowingStream { c in
                var i = 0
                while i < hit.count { c.yield(hit.subdata(in: i ..< min(hit.count, i + 9600))); i += 9600 }
                c.finish()
            }
        }
        let upstream = APIClient.shared.byteStream("v1/speech", body: body)
        return AsyncThrowingStream { c in
            let task = Task {
                var all = Data()
                do {
                    for try await chunk in upstream { all.append(chunk); c.yield(chunk) }
                    store(k, all)
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}
