import AppKit
import CryptoKit
import Sparkle

/// `Awan --update-selftest [--feed <url>] [--current <x.y.z>]` — end-to-end check of the update path
/// without installing anything:
///   1. fetch the appcast and pick the newest item,
///   2. download its DMG, check the length and verify the Ed25519 signature against the embedded key,
///   3. flip one byte and prove the signature now fails (a tampered DMG is rejected),
///   4. inside Awan.app, ask Sparkle itself (information-only check, no download, no install) what it finds.
/// Prints each step and exits 0 when everything passed.
@MainActor
enum UpdateSelfTest {
    static func run(_ args: [String]) -> Never {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "  ok   " : "  FAIL ") + what)
            if !ok { failures += 1 }
        }
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        func finish() -> Never {
            print(failures == 0 ? "update-selftest: all passed" : "update-selftest: \(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }

        let feed = value("--feed").flatMap(URL.init(string:)) ?? Updater.feedURL()
        let current = value("--current") ?? Bundle.main.shortVersion
        print("update-selftest: feed \(feed.absoluteString), running \(current)")

        guard let key = UpdateSignature.publicKey() else { check(false, "public key embedded (AwanUpdatePublicKey)"); finish() }
        check(Data(base64Encoded: key)?.count == 32, "public key is a 32-byte Ed25519 key")

        guard let xml = try? Data(contentsOf: feed) else { check(false, "appcast reachable"); finish() }
        let items = Appcast.parse(xml)
        check(!items.isEmpty, "appcast parsed (\(items.count) release(s))")
        guard let newest = items.first else { finish() }
        check(items.allSatisfy { !$0.edSignature.isEmpty && $0.length > 0 && $0.url != nil }, "every item has url, length and edSignature")
        check(newest.minimumSystemVersion == "14.0", "minimumSystemVersion 14.0")
        if newest.isNewer(than: current) {
            print("update available \(newest.shortVersion) (build \(newest.version))")
        } else {
            print("no update: newest is \(newest.shortVersion)")
        }
        check(newest.isNewer(than: current), "newer version offered")

        guard let url = newest.url, let dmg = try? Data(contentsOf: url) else { check(false, "DMG downloads"); finish() }
        check(dmg.count == newest.length, "DMG length matches the appcast (\(dmg.count) bytes)")
        check(UpdateSignature.verify(dmg, signature: newest.edSignature, publicKey: key), "signature verifies against the embedded key")

        var tampered = dmg
        let i = tampered.count / 2
        tampered[i] ^= 0x01
        let rejected = !UpdateSignature.verify(tampered, signature: newest.edSignature, publicKey: key)
        check(rejected, "tampered DMG (1 byte flipped) is rejected")
        if rejected { print("tampered DMG rejected") }
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        check(!UpdateSignature.verify(dmg, signature: newest.edSignature, publicKey: otherKey), "a different key does not verify it")

        if Bundle.main.bundleURL.pathExtension == "app" {
            let probe = SparkleProbe(feed: feed)
            let found = probe.run(timeout: 30)
            switch found {
            case let .some(.found(v)): check(v == newest.shortVersion, "Sparkle finds a valid update: \(v)")
            case .some(.none): check(false, "Sparkle finds a valid update (it found none)")
            case let .some(.failed(e)): check(false, "Sparkle check: \(e)")
            case nil: check(false, "Sparkle answered within 30 s")
            }
        } else {
            print("  skip Sparkle probe (not running inside Awan.app)")
        }
        finish()
    }
}

/// Runs one information-only Sparkle check (never downloads or installs; background checks are refused).
@MainActor
private final class SparkleProbe: NSObject, SPUUpdaterDelegate {
    enum Result: Equatable { case found(String), none, failed(String) }
    let feed: URL
    var result: Result?
    init(feed: URL) { self.feed = feed }

    func run(timeout: TimeInterval) -> Result? {
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do { try updater.start() } catch { return .failed(error.localizedDescription) }
        updater.checkForUpdateInformation()
        let until = Date().addingTimeInterval(timeout)
        while result == nil && Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
        return result
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? { MainActor.assumeIsolated { feed.absoluteString } }
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck != .updateInformation { throw NSError(domain: "awan.selftest", code: 1, userInfo: [NSLocalizedDescriptionKey: "self-test only probes"]) }
    }
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        MainActor.assumeIsolated { result = .found(v) }
    }
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) { MainActor.assumeIsolated { if result == nil { result = Result.none } } }
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let m = error.localizedDescription
        MainActor.assumeIsolated { if result == nil { result = .failed(m) } }
    }
}
