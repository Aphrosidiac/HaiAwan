import AppKit
import ApplicationServices
import SwiftUI

/// Integration suggestions (reference: IntegrationSuggestionMonitor + NotchIntegrationSuggestionSurface).
/// When the frontmost app — or the frontmost browser tab — is one of the catalogue's integrations and it
/// isn't connected, the notch offers to connect it. At most one card a day, never the same app twice in 7 days,
/// never during a call. Browser URLs come from Accessibility (Safari/Chrome/Arc/Edge/Brave); without that
/// permission only native apps (Notion, Linear, Slack, Figma…) are recognised.
@MainActor
final class IntegrationSuggester: ObservableObject {
    static let shared = IntegrationSuggester()

    @Published private(set) var active: ActiveIntegrationSuggestion?

    static let lastShownKey = "awan.integrationSuggest.lastShownAt"
    static let historyKey = "awan.integrationSuggest.history"   // [id: last shown (epoch seconds)]
    static let perAppCooldown: TimeInterval = 7 * 86_400

    private var timer: Timer?
    private var started = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func start() {
        guard !started, !SettingsEnv.isSnapshot else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))   // let the window settle so the tab URL is readable
                IntegrationSuggester.shared.check()
            }
        }
        // Tab switches don't post a notification: look again every 15 s while a browser is in front.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, IntegrationMatcher.browsers.contains(id) {
                    IntegrationSuggester.shared.check()
                }
            }
        }
    }

    func check(now: Date = Date()) {
        let state = AppState.shared
        guard state.signInState == .signedIn, state.prefs.onboardingCompleted, !state.isHomeOpen else { return }
        guard case .resting = NotchController.shared.mode else { return }         // never interrupt another card
        guard !CompanionEngine.shared.isQuiet else { return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let bundleID = app.bundleIdentifier ?? ""
        var host: String?, path: String?
        if IntegrationMatcher.browsers.contains(bundleID), let url = BrowserURLReader.currentURL(pid: app.processIdentifier) {
            host = url.host?.lowercased()
            path = url.path
        }
        guard let id = IntegrationMatcher.match(bundleID: bundleID, host: host, path: path) else { return }
        let store = ConnectorStore.shared
        guard let integration = store.catalog.first(where: { $0.id == id }) else { return }
        guard !store.connectors.contains(where: { $0.id == id }) else { return }   // connected, or already being set up
        guard Self.allowed(id: id, now: now, lastShown: lastShown, history: history) else { return }
        record(id, now: now)
        active = ActiveIntegrationSuggestion(integration: integration, sourceApplicationName: app.localizedName, sourceHost: host)
        Sounds.play(.connection)
        NotchController.shared.present(.integrationSuggestion(id), for: 14)
    }

    /// One card per calendar day, and the same integration at most once every 7 days.
    static func allowed(id: String, now: Date, lastShown: Date?, history: [String: Double]) -> Bool {
        if let lastShown, Calendar.current.isDate(lastShown, inSameDayAs: now) { return false }
        if let t = history[id], now.timeIntervalSince1970 - t < perAppCooldown { return false }
        return true
    }

    private var lastShown: Date? {
        let t = defaults.double(forKey: Self.lastShownKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private var history: [String: Double] { defaults.dictionary(forKey: Self.historyKey) as? [String: Double] ?? [:] }

    private func record(_ id: String, now: Date) {
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastShownKey)
        var h = history
        h[id] = now.timeIntervalSince1970
        defaults.set(h, forKey: Self.historyKey)
    }

    func connect() {
        active = nil
        NotchController.shared.dismissSurface()
        AppState.shared.openHome(.settings(.integrations))
    }

    func notNow() {
        active = nil
        NotchController.shared.dismissSurface()
    }

    /// "No": never suggest this integration again (its cooldown stamp is pushed out of reach).
    func never() {
        if let id = active?.integration.id {
            var h = history
            h[id] = Self.neverStamp
            defaults.set(h, forKey: Self.historyKey)
        }
        notNow()
    }

    static let neverStamp: Double = 32_503_680_000   // year 3000

    /// Snapshot/demo only.
    func debugInstall(_ s: ActiveIntegrationSuggestion?) { active = s }
}

struct ActiveIntegrationSuggestion: Equatable {
    let integration: IntegrationDTO
    let sourceApplicationName: String?
    let sourceHost: String?

    /// What to call it on the card: the site/app the user is in ("Notion", "linear.app" → Linear).
    var displayName: String { integration.name }
}

/// Bundle IDs and host suffixes → catalogue ids. Pure, so the self-test can pin it.
enum IntegrationMatcher {
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static let apps: [String: String] = [
        "notion.id": "notion",
        "com.linear": "linear",
        "com.tinyspeck.slackmacgap": "slack",
        "com.github.GitHubClient": "github",
        "com.figma.Desktop": "figma",
        "com.canva.CanvaDesktop": "canva",
        "com.electron.asana": "asana",
        "com.intercom.desktop": "intercom",
        "com.box.desktop": "box",
    ]

    /// Checked in order; the first suffix match wins. Paths split Google Workspace apart.
    static let hosts: [(suffix: String, pathPrefix: String?, id: String)] = [
        ("mail.google.com", nil, "gmail"),
        ("calendar.google.com", nil, "google-calendar"),
        ("docs.google.com", "/document", "google-docs"),
        ("docs.google.com", "/spreadsheets", "google-sheets"),
        ("sheets.google.com", nil, "google-sheets"),
        ("drive.google.com", nil, "google-drive"),
        ("notion.so", nil, "notion"),
        ("notion.site", nil, "notion"),
        ("linear.app", nil, "linear"),
        ("slack.com", nil, "slack"),
        ("github.com", nil, "github"),
        ("figma.com", nil, "figma"),
        ("asana.com", nil, "asana"),
        ("canva.com", nil, "canva"),
        ("linkedin.com", nil, "linkedin"),
        ("atlassian.net", nil, "atlassian"),
        ("monday.com", nil, "monday"),
        ("app.box.com", nil, "box"),
        ("webflow.com", nil, "webflow"),
        ("dashboard.stripe.com", nil, "stripe"),
        ("intercom.com", nil, "intercom"),
        ("sentry.io", nil, "sentry"),
        ("vercel.com", nil, "vercel"),
        ("supabase.com", nil, "supabase"),
    ]

    static func match(bundleID: String, host: String?, path: String?) -> String? {
        if let id = apps[bundleID] { return id }
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        for h in hosts where host == h.suffix || host.hasSuffix("." + h.suffix) {
            if let prefix = h.pathPrefix, !(path ?? "").hasPrefix(prefix) { continue }
            return h.id
        }
        return nil
    }
}

/// Reads the frontmost browser tab's URL through Accessibility: the web area's AXURL (Safari, Chrome, Arc…),
/// else the address field's value. Returns nil without permission or when nothing URL-like is found.
enum BrowserURLReader {
    static func currentURL(pid: pid_t) -> URL? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        var win: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success, let window = win else { return nil }
        let root = window as! AXUIElement
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        var fieldGuess: URL?
        while !queue.isEmpty, visited < 600 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            let role = string(el, kAXRoleAttribute)
            if role == "AXWebArea" {
                var u: AnyObject?
                if AXUIElementCopyAttributeValue(el, "AXURL" as CFString, &u) == .success {
                    if let url = u as? URL, url.scheme?.hasPrefix("http") == true { return url }
                    if let s = u as? String, let url = URL(string: s), url.scheme?.hasPrefix("http") == true { return url }
                }
            }
            if fieldGuess == nil, role == kAXTextFieldRole as String, let v = string(el, kAXValueAttribute), let url = urlLike(v) {
                fieldGuess = url
            }
            guard depth < 14 else { continue }
            var kids: AnyObject?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let arr = kids as? [AXUIElement] {
                queue.append(contentsOf: arr.map { ($0, depth + 1) })
            }
        }
        return fieldGuess
    }

    /// "linear.app/ff/issue/FF-12" or "https://…" → URL; plain words → nil.
    static func urlLike(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" "), s.contains(".") else { return nil }
        let withScheme = s.hasPrefix("http://") || s.hasPrefix("https://") ? s : "https://" + s
        guard let url = URL(string: withScheme), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }
}

// MARK: - Surface

/// Measured on the reference's notch card (617×104 incl. shoulders, pure black): two app tiles, "Connect <App>
/// to Awan" / "Use Awan to:", No · Not now · Yes gels on the right, and a marquee of example asks along the bottom
/// with a soft glow blooming behind Yes. Coordinates below are from the card's outer left edge.
enum IntegrationCardLayout {
    static let size = CGSize(width: 617, height: 104)
    static let rowCenterY: CGFloat = 40
    static let tile: CGFloat = 34
    static let tileX: CGFloat = 22.5
    static let tileGap: CGFloat = 10
    static let textX: CGFloat = 111
    static let buttonsRight: CGFloat = 584
    static let buttonHeight: CGFloat = 29
    static let marqueeY: CGFloat = 70
    static let marqueeHeight: CGFloat = 20
    /// Cards sit below the physical notch on Macs that have one.
    @MainActor static var topInset: CGFloat {
        let g = NotchController.shared.geometry
        return g.hasHardwareNotch ? g.menuBarHeight : 0
    }
}

struct IntegrationSuggestionSurface: View {
    let integrationID: String
    @ObservedObject private var suggester = IntegrationSuggester.shared

    var body: some View {
        let L = IntegrationCardLayout.self
        let s = suggester.active
        let name = s?.displayName ?? integrationID.capitalized
        ZStack(alignment: .topLeading) {
            // Soft glow blooming bottom-right, behind Yes (lime for Awan).
            RadialGradient(colors: [Theme.lime.opacity(0.22), Theme.lime.opacity(0.07), .clear], center: .center, startRadius: 0, endRadius: 120)
                .frame(width: 260, height: 200)
                .position(x: 560, y: L.size.height + 6)
                .allowsHitTesting(false)

            HStack(spacing: L.tileGap) {
                IntegrationAppTile { CloudCreature(appearance: .mascot, mood: .happy, glow: false).frame(width: 24) }
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink))
                IntegrationAppTile {
                    Image(systemName: s?.integration.icon ?? "puzzlepiece.extension.fill")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white))
            }
            .frame(height: L.tile)
            .offset(x: L.tileX, y: L.rowCenterY - L.tile / 2)

            VStack(alignment: .leading, spacing: -1) {
                Text("Connect \(name) to Awan").font(.awan(15, .semibold)).foregroundStyle(Color.white).lineLimit(1).truncationMode(.tail)
                Text("Use Awan to:").font(.awan(13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .frame(width: 326 - 12 - L.textX, alignment: .leading)
            .frame(height: 40)
            .offset(x: L.textX, y: L.rowCenterY - 18)

            HStack(spacing: 8) {
                Button { suggester.never() } label: {
                    Label("No", systemImage: "xmark").labelStyle(GelIconLabelStyle()).frame(minWidth: 73 - 24)
                }
                .buttonStyle(.gel(.bone, height: L.buttonHeight, padding: 12, fontSize: 13))
                Button { suggester.notNow() } label: {
                    Label("Not now", systemImage: "clock").labelStyle(GelIconLabelStyle()).frame(minWidth: 96.5 - 24)
                }
                .buttonStyle(.gel(.bone, height: L.buttonHeight, padding: 12, fontSize: 13))
                Button { suggester.connect() } label: {
                    Label("Yes", systemImage: "link").labelStyle(GelIconLabelStyle()).frame(minWidth: 71.5 - 24)
                }
                .buttonStyle(.gel(.lime, height: L.buttonHeight, padding: 12, fontSize: 13))
            }
            .fixedSize()
            .frame(width: L.buttonsRight, height: L.buttonHeight, alignment: .trailing)
            .offset(y: L.rowCenterY - L.buttonHeight / 2)

            IntegrationExampleMarquee(examples: IntegrationExamples.forIntegration(s?.integration.id ?? integrationID, name: name))
                .frame(width: L.size.width - 2 * 30, height: L.marqueeHeight)
                .offset(x: 30, y: L.marqueeY)
        }
        .padding(.top, IntegrationCardLayout.topInset)
        .frame(width: L.size.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, -10)   // NotchModeContent insets cards by 10; this one is laid out edge to edge
    }
}

/// A 34 pt rounded app tile.
struct IntegrationAppTile<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(width: IntegrationCardLayout.tile, height: IntegrationCardLayout.tile)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }
}

/// Icon + title with a tighter gap than the default Label.
struct GelIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.font(.system(size: 12, weight: .semibold))
            configuration.title
        }
    }
}

/// Example asks drifting right-to-left forever, faded at both ends.
struct IntegrationExampleMarquee: View {
    let examples: [String]
    var speed: Double = 22   // pt per second
    @Local private var contentWidth: CGFloat = 0

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let cycle = max(contentWidth, 1)
            let x = -CGFloat((t * speed).truncatingRemainder(dividingBy: Double(cycle)))
            HStack(spacing: 8) {
                row.background(GeometryReader { g in
                    Color.clear.onAppear { contentWidth = g.size.width + 8 }
                })
                row
            }
            .fixedSize()
            .offset(x: x)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                     .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .allowsHitTesting(false)
    }

    private var row: some View {
        HStack(spacing: 8) {
            ForEach(Array(examples.enumerated()), id: \.offset) { _, e in
                Text(e).font(.awan(13)).foregroundStyle(Theme.text.opacity(0.85)).lineLimit(1).fixedSize()
                    .padding(.horizontal, 9)
                    .frame(height: IntegrationCardLayout.marqueeHeight)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            }
        }
    }
}

/// What an Awan could do once the app is connected (our own copy, per catalogue id).
enum IntegrationExamples {
    static let byID: [String: [String]] = [
        "gmail": ["Draft a reply for approval", "Summarize a long thread", "Pull attachments from a sender", "Find urgent emails"],
        "google-calendar": ["Find a free hour this week", "Prep notes for my next meeting", "Move a clash to Friday"],
        "notion": ["Turn notes into a brief", "Find last week's meeting notes", "Update a project page", "Tidy a messy database"],
        "linear": ["Triage new issues", "Write a sprint summary", "File a bug from this page", "Find stale tickets"],
        "slack": ["Catch me up on a channel", "Draft an update for the team", "Find that link someone shared"],
        "github": ["Review an open PR", "Summarize recent commits", "Open an issue from a bug report"],
        "figma": ["List the frames in a file", "Pull copy out of a design", "Check a spec against the build"],
        "stripe": ["Find failed payments", "Summarize this month's revenue", "Look up a customer"],
    ]

    static func forIntegration(_ id: String, name: String) -> [String] {
        byID[id] ?? ["Search \(name) for you", "Summarize what's new in \(name)", "Draft something in \(name)", "Keep \(name) tidy"]
    }
}
