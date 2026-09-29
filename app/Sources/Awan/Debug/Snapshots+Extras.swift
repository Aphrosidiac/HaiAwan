import AppKit
import SwiftUI

/// Snapshot registrations for the wave-2 notch extras (handoff, meeting countdown, integration suggestion,
/// file drop, peek pile, app updated, referral claim). Names are prefixed "extras-".
/// `extras-selftest` runs the pure checks and exits (0 = all passed).
extension Snapshots {
    static var extrasNames: [String] {
        ["extras-handoff-selecting", "extras-handoff-bar", "extras-handoff-queued", "extras-handoff-sent", "extras-handoff-voice",
         "extras-meeting", "extras-meeting-home", "extras-integration", "extras-drop", "extras-drop-composer",
         "extras-peek-pile", "extras-app-updated", "extras-referral-claim", "extras-referral-claimed", "extras-selftest"]
    }

    static func extras(_ name: String) -> AnyView? {
        guard name.hasPrefix("extras-") else { return nil }
        if name == "extras-selftest" { ExtrasSelfTest.run() }
        let s = AppState.shared
        let notch = NotchController.shared
        ExtrasDemo.install()

        func surface(_ kind: NotchSurfaceKind) -> AnyView {
            notch.mode = .surface(kind)
            let size = notch.sizeFor(.surface(kind))
            return AnyView(
                ZStack(alignment: .top) {
                    ExtrasDemo.wallpaper
                    NotchRootView().environmentObject(s).environmentObject(notch)
                        .frame(width: size.width, height: size.height)
                }
            )
        }

        switch name {
        case "extras-handoff-selecting":
            return ExtrasDemo.overlay(frozen: false)
        case "extras-handoff-bar":
            return ExtrasDemo.overlay(frozen: true)
        case "extras-handoff-voice":
            return ExtrasDemo.overlay(frozen: true, voice: true)
        case "extras-handoff-queued":
            HandoffManager.shared.debugInstall(queued: ExtrasDemo.regions(3), current: nil, status: .queued(3))
            return surface(.handoff)
        case "extras-handoff-sent":
            HandoffManager.shared.debugInstall(queued: [], current: nil, status: .sent("Ship Lab"))
            return surface(.handoff)
        case "extras-meeting":
            return surface(.meetingCountdown)
        case "extras-meeting-home":
            s.homePage = .home
            return AnyView(HomeRootView().environmentObject(s).environmentObject(s.agents).environmentObject(s.companion)
                .environmentObject(RoutineScheduler.shared).environmentObject(Prefs.shared))
        case "extras-integration":
            return surface(.integrationSuggestion("notion"))
        case "extras-drop":
            NotchDropController.shared.debugInstall(dragging: true, hover: 2, files: [])
            return surface(.fileDrop)
        case "extras-drop-composer":
            NotchDropController.shared.debugInstall(dragging: false, hover: nil, files: ExtrasDemo.files, draft: "turn these into a one-page brief")
            return surface(.dropComposer)
        case "extras-peek-pile":
            notch.mode = .peek
            let size = notch.sizeFor(.peek)
            return AnyView(ZStack(alignment: .top) {
                ExtrasDemo.wallpaper
                NotchRootView().environmentObject(s).environmentObject(notch).frame(width: size.width, height: size.height)
            })
        case "extras-app-updated":
            return surface(.appUpdated("1.1.0"))
        case "extras-referral-claim", "extras-referral-claimed":
            var info = SettingsDemo.referral(withFriends: false)
            if name == "extras-referral-claim" {
                info.canClaim = true
                ReferralModel.shared.claimError = nil
            } else {
                info.invitedBy = .init(handle: "sam", name: "Sam Tan")
                info.canClaim = false
            }
            ReferralModel.shared.info = info
            return AnyView(
                ScrollView { ReferralPage().padding(28) }
                    .background(Theme.window)
                    .environmentObject(s)
            )
        default:
            return nil
        }
    }
}

@MainActor
enum ExtrasDemo {
    static func install() {
        let now = Date()
        // Files for the peek pile and drop chips (in /tmp, never the user's folders).
        let dir = "/tmp/awan-demo"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let notes = "\(dir)/launch-notes.md", sheet = "\(dir)/competitors.csv", page = "\(dir)/welcome.html"
        try? "# Launch notes\n\n- hero\n- pricing".write(toFile: notes, atomically: true, encoding: .utf8)
        try? "name,price\nA,10\nB,20".write(toFile: sheet, atomically: true, encoding: .utf8)
        if !FileManager.default.fileExists(atPath: page) {
            try? "<html><body style='background:#F3EFE4'><h1>hello</h1></body></html>".write(toFile: page, atomically: true, encoding: .utf8)
        }
        let store = AgentStore.shared
        store.updateTurn("ship-lab", "t1") { t in
            t.artifacts = [Artifact(path: page, createdAt: now.addingTimeInterval(-1500)), Artifact(path: notes), Artifact(path: sheet)]
        }
        let start = now.addingTimeInterval(4 * 60 + 12)
        let meeting = UpcomingMeeting(id: "demo", title: "Standup with Sunlight", start: start, end: start.addingTimeInterval(1800),
                                      joinURL: URL(string: "https://meet.google.com/abc-defg-hij")!)
        MeetingMonitor.shared.debugInstall(next: meeting, countdown: meeting)
        let notion = IntegrationDTO(id: "notion", name: "Notion", description: "Search pages and databases…", url: "https://mcp.notion.com/mcp",
                                    auth: "oauth", icon: "doc.richtext", category: "productivity")
        IntegrationSuggester.shared.debugInstall(ActiveIntegrationSuggestion(integration: notion, sourceApplicationName: "Safari", sourceHost: "www.notion.so"))
        HandoffTargetApp.debugRunning = HandoffTargetApp.known.filter { ["Terminal", "Claude", "Cursor"].contains($0.name) }
    }

    static var files: [URL] {
        ["/tmp/awan-demo/launch-notes.md", "/tmp/awan-demo/competitors.csv", "/tmp/awan-demo/welcome.html", "/tmp/awan-demo/logo.png"].map { URL(fileURLWithPath: $0) }
    }

    static var wallpaper: some View {
        LinearGradient(colors: [Color(hex: 0x3B5B8C), Color(hex: 0x6B4FD8), Color(hex: 0xC77DA8)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// A plausible desktop behind the overlays.
    static var desktop: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x3B5B8C), Color(hex: 0x6B4FD8), Color(hex: 0xC77DA8)], startPoint: .topLeading, endPoint: .bottomTrailing)
            FakeEditor().frame(width: 620, height: 380).offset(x: -60, y: 40)
        }
    }

    struct FakeEditor: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 11, height: 11) }
                    Spacer()
                    Text("checkout.tsx — shop").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).frame(height: 30).background(Color(hex: 0x2B2B2B))
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(Self.lines.enumerated()), id: \.offset) { i, l in
                        HStack(spacing: 14) {
                            Text("\(i + 12)").foregroundStyle(Color.white.opacity(0.3)).frame(width: 22, alignment: .trailing)
                            Text(l.0).foregroundStyle(l.1)
                        }
                    }
                }
                .font(.system(size: 12.5, design: .monospaced))
                .padding(14)
                Spacer()
            }
            .background(Color(hex: 0x1E1E1E))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
        }

        static let lines: [(String, Color)] = [
            ("export function Checkout({ cart }: Props) {", Color(hex: 0x9CDCFE)),
            ("  const total = cart.items.reduce(sum, 0)", .white),
            ("  if (total > LIMIT) {", Color(hex: 0xC586C0)),
            ("    throw new Error('Cart over limit')", Color(hex: 0xF44747)),
            ("  }", .white),
            ("  return <Pay amount={total} currency=\"MYR\" />", Color(hex: 0x4EC9B0)),
            ("}", .white),
            ("", .white),
            ("// TypeError: cannot read 'reduce' of undefined", Color(hex: 0x6A9955)),
        ]
    }

    /// A rendered crop of the fake editor, standing in for a real capture.
    static func regionImage() -> CGImage {
        let r = ImageRenderer(content: FakeEditor().frame(width: 420, height: 180))
        r.scale = 2
        return r.cgImage ?? CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(count: 4) as CFData)!,
                                    decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func regions(_ n: Int) -> [HandoffRegion] {
        let img = regionImage()
        let png = RegionCapture.png(img) ?? Data()
        return (0 ..< n).map { i in HandoffRegion(rect: CGRect(x: 200 + i * 20, y: 300, width: 420, height: 180), image: img, png: png) }
    }

    /// The region-select overlay as it looks on screen (the real one is the same SwiftUI views in panels).
    static func overlay(frozen: Bool, voice: Bool = false) -> AnyView {
        let model = RegionSelectModel()
        let rect = CGRect(x: 180, y: 250, width: 440, height: 170)
        if frozen { model.frozen = rect } else { model.start = rect.origin; model.end = CGPoint(x: rect.maxX, y: rect.maxY) }
        let handoff = HandoffManager.shared
        let img = regionImage()
        handoff.debugInstall(queued: frozen ? regions(1) : [], current: frozen ? HandoffRegion(rect: rect, image: img, png: Data()) : nil,
                             status: nil, comment: voice ? "" : "why does this throw?", listening: voice)
        CompanionEngine.shared.liveTranscript = voice ? "why does this throw when the cart is empty" : ""
        CompanionEngine.shared.audioLevel = voice ? 0.5 : 0
        return AnyView(GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                desktop
                RegionShadeView(model: model)
                if frozen {
                    let o = HandoffActionBar.origin(for: rect, in: geo.size)
                    HandoffActionBar()
                        .environmentObject(handoff).environmentObject(AgentStore.shared)
                        .offset(x: o.x, y: o.y)
                }
            }
        })
    }

}

// MARK: - Pure checks

@MainActor
enum ExtrasSelfTest {
    static func run() -> Never {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "  ok   " : "  FAIL ") + what)
            if !ok { failures += 1 }
        }

        // Integration matching
        let m = IntegrationMatcher.self
        check(m.match(bundleID: "notion.id", host: nil, path: nil) == "notion", "suggest: Notion app")
        check(m.match(bundleID: "com.apple.Safari", host: "www.notion.so", path: "/x") == "notion", "suggest: notion.so in Safari")
        check(m.match(bundleID: "com.google.Chrome", host: "linear.app", path: "/ff") == "linear", "suggest: linear.app")
        check(m.match(bundleID: "com.google.Chrome", host: "mail.google.com", path: "/mail/u/0") == "gmail", "suggest: Gmail")
        check(m.match(bundleID: "com.google.Chrome", host: "docs.google.com", path: "/spreadsheets/d/1") == "google-sheets", "suggest: Sheets by path")
        check(m.match(bundleID: "com.google.Chrome", host: "docs.google.com", path: "/document/d/1") == "google-docs", "suggest: Docs by path")
        check(m.match(bundleID: "com.google.Chrome", host: "notgithub.com", path: "/") == nil, "suggest: suffix must be a whole label")
        check(m.match(bundleID: "com.tinyspeck.slackmacgap", host: nil, path: nil) == "slack", "suggest: Slack app")
        check(m.match(bundleID: "com.apple.Safari", host: nil, path: nil) == nil, "suggest: browser without a URL (no AX) → nothing")
        check(BrowserURLReader.urlLike("linear.app/ff/issue/FF-1")?.host == "linear.app", "suggest: address-bar text → URL")
        check(BrowserURLReader.urlLike("search for cats") == nil, "suggest: plain words are not a URL")

        let day = 86_400.0
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let a = IntegrationSuggester.self
        check(a.allowed(id: "notion", now: now, lastShown: nil, history: [:]), "suggest: first time allowed")
        check(!a.allowed(id: "linear", now: now, lastShown: now.addingTimeInterval(-60), history: [:]), "suggest: one card per day")
        check(!a.allowed(id: "notion", now: now, lastShown: now.addingTimeInterval(-2 * day), history: ["notion": now.timeIntervalSince1970 - 3 * day]), "suggest: same app not within 7 days")
        check(a.allowed(id: "notion", now: now, lastShown: now.addingTimeInterval(-2 * day), history: ["notion": now.timeIntervalSince1970 - 8 * day]), "suggest: same app again after 7 days")

        // Meetings
        let links = MeetingLinks.self
        check(links.find(in: [nil, "Room 3", "Join: https://us02web.zoom.us/j/81234567890?pwd=abc."])?.absoluteString == "https://us02web.zoom.us/j/81234567890?pwd=abc", "meeting: Zoom link in notes, trailing dot trimmed")
        check(links.find(in: ["https://meet.google.com/abc-defg-hij"])?.host == "meet.google.com", "meeting: Meet link")
        check(links.find(in: ["<https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0?context=y>"])?.host == "teams.microsoft.com", "meeting: Teams link in angle brackets")
        check(links.find(in: ["https://example.com/agenda"]) == nil, "meeting: ordinary links ignored")
        let start = now.addingTimeInterval(4 * 60)
        let meeting = UpcomingMeeting(id: "x", title: "Standup", start: start, end: start.addingTimeInterval(900), joinURL: URL(string: "https://meet.google.com/abc-defg-hij")!)
        check(MeetingMonitor.shouldAnnounce(meeting, now: now), "meeting: announce 4 min before")
        check(!MeetingMonitor.shouldAnnounce(meeting, now: now.addingTimeInterval(-120)), "meeting: not 6 min before")
        check(!MeetingMonitor.shouldAnnounce(meeting, now: start.addingTimeInterval(120)), "meeting: not once well started")
        check(UpcomingMeeting.countdownText(until: start, now: now) == "in 4 min", "meeting: 'in 4 min'")
        check(UpcomingMeeting.countdownText(until: start, now: start.addingTimeInterval(-30)) == "in 30 s", "meeting: seconds in the last 90 s")
        check(UpcomingMeeting.countdownText(until: start, now: start.addingTimeInterval(10)) == "starting now", "meeting: starting now")

        // App updated
        let u = AppUpdateNotice.self
        check(u.decide(lastSeen: nil, current: "1.0.0") == .firstInstall, "update: first install is quiet")
        check(u.decide(lastSeen: "1.0.0", current: "1.0.0") == .same, "update: same version is quiet")
        check(u.decide(lastSeen: "1.0.9", current: "1.0.10") == .updated("1.0.10"), "update: numeric compare (1.0.10 > 1.0.9)")
        check(u.decide(lastSeen: "1.2.0", current: "1.1.0") == .same, "update: a downgrade doesn't announce")

        // Drop layout
        let w = NotchDropLayout.size(count: 4).width
        let start0 = (w - NotchDropLayout.slotWidth * 5) / 2
        check(NotchDropLayout.slot(at: CGPoint(x: start0 + 10, y: 100), width: w, count: 4) == 0, "drop: leftmost slot is the mascot")
        check(NotchDropLayout.slot(at: CGPoint(x: start0 + NotchDropLayout.slotWidth * 2.5, y: 100), width: w, count: 4) == 2, "drop: middle slot")
        check(NotchDropLayout.slot(at: CGPoint(x: 2, y: 100), width: w, count: 4) == nil, "drop: outside the row")
        check(NotchDropLayout.slot(at: CGPoint(x: start0 + 10, y: 8), width: w, count: 4) == nil, "drop: above the row")
        check(NotchDropController.lookPrompt(["/a/x.pdf", "/a/y.png"]) == "Take a look at these files: /a/x.pdf, /a/y.png", "drop: the ask names every copied path")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("awan-drop-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let src = tmp.appendingPathComponent("src"), dst = tmp.appendingPathComponent("dst")
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let f = src.appendingPathComponent("brief.md")
        try? "hi".write(to: f, atomically: true, encoding: .utf8)
        let first = NotchDropController.copy([f], to: dst), second = NotchDropController.copy([f], to: dst)
        check(first.first?.hasSuffix("/brief.md") == true && second.first?.hasSuffix("/brief 2.md") == true, "drop: copies never overwrite")
        check(FileManager.default.fileExists(atPath: f.path), "drop: the original stays put")
        try? FileManager.default.removeItem(at: tmp)

        // Handoff
        check(HandoffFiles.terminalLine(note: "fix this", paths: ["/a/b.png", "/My Files/c.png"]) == "fix this /a/b.png '/My Files/c.png'", "handoff: terminal line quotes spaced paths")
        check(HandoffFiles.terminalLine(note: "", paths: ["/a/b.png"]) == "/a/b.png", "handoff: no note → just the path")
        check(RegionCapture.sourceRect(for: CGRect(x: 100, y: 700, width: 200, height: 100), in: CGRect(x: 0, y: 0, width: 1440, height: 900)) == CGRect(x: 100, y: 100, width: 200, height: 100),
              "handoff: global rect → display-local top-left source rect")
        check(RegionCapture.sourceRect(for: CGRect(x: 1540, y: 200, width: 100, height: 100), in: CGRect(x: 1440, y: -180, width: 1920, height: 1080)) == CGRect(x: 100, y: 600, width: 100, height: 100),
              "handoff: works on a secondary display")
        let bar = HandoffActionBar.origin(for: CGRect(x: 100, y: 800, width: 300, height: 60), in: CGSize(width: 1440, height: 900))
        check(bar.y + HandoffActionBar.size.height <= 900 - 12 && bar.y < 800, "handoff: bar flips above a box near the bottom")
        let bar2 = HandoffActionBar.origin(for: CGRect(x: 1400, y: 100, width: 30, height: 30), in: CGSize(width: 1440, height: 900))
        check(bar2.x + HandoffActionBar.size.width <= 1440 - 12, "handoff: bar stays on screen at the right edge")
        check(HandoffManager.agentPrompt(ask: "why?", paths: ["/w/tmp/a.png"]) == "why?\n\nA screenshot of part of my screen (PNG):\n- /w/tmp/a.png", "handoff: Awan ask references the file by path")
        let geo = CaptureGeometry(displayFrame: CGRect(x: 100, y: 200, width: 400, height: 100), pixelSize: CGSize(width: 800, height: 200))
        check(geo.globalPoint(fromPixel: CGPoint(x: 0, y: 0)) == CGPoint(x: 100, y: 300), "handoff: region pixels map back onto the region")

        // Shortcuts
        check(ShortcutSet.defaults.handoff.summary == "Hold control + option + shift", "shortcuts: handoff default is hold ⌃⌥⇧ (\(ShortcutSet.defaults.handoff.summary))")

        print(failures == 0 ? "extras selftest: all passed" : "extras selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
