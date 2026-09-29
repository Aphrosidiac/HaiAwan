import AppKit
import CryptoKit
import Sparkle

/// Updates. Inside Awan.app, Sparkle 2 does the work: hourly background checks against the appcast,
/// EdDSA (Ed25519) verification of every download against the key in Info.plist, and install on quit
/// with relaunch. The "App updated" notch card (AppUpdateNotice) greets the new version on next launch.
///
/// Feed: `AWAN_APPCAST` env → `awan.update.feedURL` default → Info.plist `AwanAppcastURL`/`SUFeedURL`
/// → https://awan.ffdev.studio/appcast.xml. Outside a bundle (swift run), checks fall back to reading the
/// appcast directly so Settings still reports something true.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()
    @Published var status: String?
    @Published var checking = false

    nonisolated static let feedDefaultsKey = "awan.update.feedURL"
    nonisolated static let defaultFeed = "https://awan.ffdev.studio/appcast.xml"

    private var controller: SPUStandardUpdaterController?

    var feedURL: URL { Self.feedURL() }

    nonisolated static func feedURL(bundle: Bundle = .main) -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["AWAN_APPCAST"],
            UserDefaults.standard.string(forKey: feedDefaultsKey),
            bundle.object(forInfoDictionaryKey: "AwanAppcastURL") as? String,
            bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
        ]
        for c in candidates { if let c, !c.isEmpty, let u = URL(string: c) { return u } }
        return URL(string: defaultFeed)!
    }

    /// Sparkle needs a real app bundle with a public key; dev binaries and snapshot runs skip it.
    var sparkleAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && UpdateSignature.publicKey() != nil && !SettingsEnv.isSnapshot
    }

    /// Call once at launch.
    func start() {
        guard controller == nil, sparkleAvailable else { return }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        c.updater.automaticallyChecksForUpdates = true
        c.updater.automaticallyDownloadsUpdates = true      // downloaded quietly, installed when Awan quits
        c.updater.updateCheckInterval = 3600
        do {
            try c.updater.start()
            controller = c
            Log.info("updates: Sparkle started, feed \(feedURL.absoluteString)")
        } catch {
            Log.error("updates: Sparkle could not start: \(error.localizedDescription)")
        }
    }

    /// `userInitiated` shows Sparkle's window either way; a background check only speaks up when there's an update.
    func checkNow(userInitiated: Bool) {
        if controller == nil { start() }
        if let controller {
            checking = true
            if userInitiated { controller.checkForUpdates(nil) } else { controller.updater.checkForUpdatesInBackground() }
            return
        }
        checking = true
        Task {
            defer { checking = false }
            let current = Bundle.main.shortVersion
            do {
                let (data, resp) = try await URLSession.shared.data(from: feedURL)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                if let newest = Appcast.parse(data).first, newest.isNewer(than: current) {
                    status = "Awan \(newest.shortVersion) is available."
                    if userInitiated, let page = URL(string: feedURL.deletingLastPathComponent().absoluteString + "download/") {
                        NSWorkspace.shared.open(page)
                    }
                } else {
                    status = "You're on the latest version (\(current))."
                }
            } catch {
                status = "Couldn't reach the update server. You're on \(current)."
            }
        }
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? { Self.feedURL().absoluteString }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        MainActor.assumeIsolated {
            status = "Awan \(v) is ready. It installs when you quit Awan."
            checking = false
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            status = "You're on the latest version (\(Bundle.main.shortVersion))."
            checking = false
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let message = error.map { ($0 as NSError).localizedDescription }
        MainActor.assumeIsolated {
            checking = false
            if let message, status == nil { status = message }
        }
    }
}

// MARK: - Appcast + signatures (shared by the fallback check, the self-test and release tooling)

struct AppcastItem: Equatable {
    var title = ""
    var version = ""              // sparkle:version (CFBundleVersion)
    var shortVersion = ""         // sparkle:shortVersionString
    var minimumSystemVersion = ""
    var url: URL?
    var length: Int = 0
    var edSignature = ""

    func isNewer(than current: String) -> Bool { shortVersion.compare(current, options: .numeric) == .orderedDescending }
}

/// Minimal Sparkle appcast reader (items sorted newest first).
enum Appcast {
    static func parse(_ data: Data) -> [AppcastItem] {
        let d = Reader()
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = false
        p.delegate = d
        p.parse()
        return d.items.sorted { $0.shortVersion.compare($1.shortVersion, options: .numeric) == .orderedDescending }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        var current: AppcastItem?
        var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "item" { current = AppcastItem() }
            if name == "enclosure", current != nil {
                current?.url = attributes["url"].flatMap(URL.init(string:))
                current?.length = Int(attributes["length"] ?? "") ?? 0
                current?.edSignature = attributes["sparkle:edSignature"] ?? ""
                if let v = attributes["sparkle:version"] { current?.version = v }
                if let v = attributes["sparkle:shortVersionString"] { current?.shortVersion = v }
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "title": current?.title = t
            case "sparkle:version": current?.version = t
            case "sparkle:shortVersionString": current?.shortVersion = t
            case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = t
            case "item":
                if var c = current {
                    if c.shortVersion.isEmpty { c.shortVersion = c.version }
                    items.append(c)
                }
                current = nil
            default: break
            }
        }
    }
}

/// Ed25519 over the whole archive, base64 — the same scheme Sparkle's `sparkle:edSignature` uses.
enum UpdateSignature {
    /// `AWAN_UPDATE_PUBLIC_KEY` env, else Info.plist `AwanUpdatePublicKey` / `SUPublicEDKey`.
    static func publicKey(bundle: Bundle = .main) -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["AWAN_UPDATE_PUBLIC_KEY"],
            bundle.object(forInfoDictionaryKey: "AwanUpdatePublicKey") as? String,
            bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
        ]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    static func verify(_ data: Data, signature: String, publicKey: String) -> Bool {
        guard let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let sig = Data(base64Encoded: signature) else { return false }
        return key.isValidSignature(sig, for: data)
    }
}
