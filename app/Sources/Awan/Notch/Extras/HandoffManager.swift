import AppKit
import SwiftUI
import ScreenCaptureKit

/// Handoff (reference: HandoffManager + HandoffRegionSelectOverlayManager + NotchHandoffSurface).
/// Hold ⌃⌥⇧ (or "Send a screen region…" in the notch) → a translucent full-screen overlay with a crosshair;
/// drag a box, Esc / right-click cancels. The region is captured at native resolution, then an action bar
/// offers: Ask Awan (region + note go to the companion), Send to an Awan (PNG saved into that Awan's tmp/,
/// referenced by path), Paste into a running app (Terminal, iTerm, Claude, Cursor, Codex, VS Code…), or Queue.
@MainActor
final class HandoffManager: ObservableObject {
    static let shared = HandoffManager()

    /// Regions set aside with "Queue" — they ride along with the next send.
    @Published private(set) var queued: [HandoffRegion] = []
    /// The region just drawn (the action bar is showing for it).
    @Published private(set) var current: HandoffRegion?
    @Published private(set) var isSelecting = false
    /// Voice note in progress ("Listening… click to stop").
    @Published private(set) var listening = false
    @Published var comment = ""
    /// "Paste into…" also presses Return in the target app.
    @Published var pressReturn = false
    /// What the notch handoff surface shows.
    @Published var status: Status?

    enum Status: Equatable {
        case queued(Int)
        case sent(String)       // an Awan's name
        case pasted(String)     // an app's name
        case asked
        case failed(String)
    }

    private let overlay = RegionSelectOverlay()

    /// Everything that goes out with the next action: the queue, then the region just drawn.
    var payload: [HandoffRegion] { queued + (current.map { [$0] } ?? []) }

    // MARK: - Region select

    func beginRegionSelect() {
        guard !isSelecting else { return }
        guard ScreenCapture.hasPermission else {
            NotchController.shared.present(.message("Awan needs Screen Recording to grab part of your screen. Turn it on in Settings → Permissions."), for: 6)
            return
        }
        if NotchController.shared.mode == .peek { NotchController.shared.closePeek() }
        isSelecting = true
        current = nil
        comment = ""
        overlay.show(
            onSelected: { [weak self] rect in Task { await self?.captured(rect) } },
            onCancel: { [weak self] in self?.cancel() }
        )
    }

    private func captured(_ rect: CGRect) async {
        do {
            let image = try await RegionCapture.capture(rect)
            guard let png = RegionCapture.png(image) else { throw RegionCapture.Failure.encode }
            current = HandoffRegion(rect: rect, image: image, png: png)
            overlay.showActionBar(for: rect)
        } catch {
            overlay.hide()
            isSelecting = false
            Log.error("handoff: capture failed — \(error.localizedDescription)")
            NotchController.shared.present(.message((error as? LocalizedError)?.errorDescription ?? "Couldn't capture that part of the screen."), for: 5)
        }
    }

    func cancel() {
        if listening { CompanionEngine.shared.abortListening(); listening = false }
        finishSelection()
    }

    private func finishSelection() {
        overlay.hide()
        isSelecting = false
        current = nil
        HandoffFocus.release()
    }

    private func takeComment() -> String {
        let c = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        comment = ""
        return c
    }

    // MARK: - Actions

    /// "Queue" (the reference's "Don't send yet").
    func queueOnly() {
        guard let c = current else { return }
        queued.append(c)
        finishSelection()
        show(.queued(queued.count), for: 6)
    }

    func clearQueue() {
        queued = []
        NotchController.shared.dismissSurface()
    }

    /// "Ask Awan": the region(s) and the note go to the companion instead of full-screen screenshots.
    func askAwan() {
        let regions = payload
        guard !regions.isEmpty else { return }
        let note = takeComment()
        finishSelection()
        queued = []
        let engine = CompanionEngine.shared
        engine.pendingRegions = regions.map(\.frame)
        engine.sendText(note.isEmpty ? "What's this?" : note)
    }

    /// "Ask by voice": talk now, click to stop; the spoken words become the note.
    func askByVoice() {
        guard current != nil, !listening else { return }
        let engine = CompanionEngine.shared
        engine.beginListening()
        guard engine.voiceState == .listening else { return }
        engine.pendingRegions = payload.map(\.frame)
        listening = true
    }

    func stopVoice() {
        guard listening else { return }
        listening = false
        queued = []
        finishSelection()
        CompanionEngine.shared.endListening()
    }

    /// "Send to an Awan": PNGs into `<workspace>/tmp/`, referenced by absolute path in the ask.
    func send(to slug: String) {
        let store = AgentStore.shared
        guard let agent = store.agent(slug) else { return }
        let regions = payload
        guard !regions.isEmpty else { return }
        let note = takeComment()
        finishSelection()
        queued = []
        let tmp = Paths.ensure(agent.workspace.appendingPathComponent("tmp", isDirectory: true))
        let paths = HandoffFiles.write(regions, into: tmp)
        guard !paths.isEmpty else { show(.failed("Couldn't save the screenshot into \(agent.name)'s workspace."), for: 5); return }
        let ask = note.isEmpty ? "Take a look at this part of my screen." : note
        store.send(Self.agentPrompt(ask: ask, paths: paths), to: slug, display: ask, source: "handoff")
        Sounds.play(.agentLaunch)
        show(.sent(agent.name), for: 4)
    }

    static func agentPrompt(ask: String, paths: [String]) -> String {
        let label = paths.count == 1 ? "A screenshot of part of my screen (PNG):" : "Screenshots of parts of my screen (PNG):"
        return ask + "\n\n" + label + "\n" + paths.map { "- \($0)" }.joined(separator: "\n")
    }

    /// "Paste into…": activate the app, ⌘V the image(s) and the note (terminals get the file paths as text),
    /// then Return only when the user ticked "Send right away".
    func paste(into app: HandoffTargetApp) {
        let regions = payload
        guard !regions.isEmpty else { return }
        let note = takeComment()
        let submit = pressReturn
        finishSelection()
        queued = []
        Task { await deliver(regions, note: note, to: app, submit: submit) }
    }

    private func deliver(_ regions: [HandoffRegion], note: String, to app: HandoffTargetApp, submit: Bool) async {
        let dir = Paths.ensure(Paths.support.appendingPathComponent("Handoff", isDirectory: true))
        HandoffFiles.prune(dir, olderThan: 3 * 86_400)
        let paths = HandoffFiles.write(regions, into: dir)
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first else {
            show(.failed("\(app.name) isn't open any more."), for: 5)
            return
        }
        let canType = CGPreflightPostEventAccess()
        let pb = NSPasteboard.general
        running.activate()
        for _ in 0 ..< 30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != running.processIdentifier {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(120))

        if app.isTerminal {
            pb.clearContents()
            pb.setString(HandoffFiles.terminalLine(note: note, paths: paths), forType: .string)
            if canType { Keystrokes.commandV() }
        } else {
            for (i, r) in regions.enumerated() {
                pb.clearContents()
                pb.setData(r.png, forType: .png)
                if let tiff = NSImage(cgImage: r.image, size: .zero).tiffRepresentation { pb.setData(tiff, forType: .tiff) }
                guard canType else { break }
                Keystrokes.commandV()
                try? await Task.sleep(for: .milliseconds(i == regions.count - 1 ? 350 : 250))
            }
            if canType, !note.isEmpty {
                pb.clearContents()
                pb.setString(note, forType: .string)
                Keystrokes.commandV()
            }
        }
        if canType, submit {
            try? await Task.sleep(for: .milliseconds(220))
            Keystrokes.returnKey()
        }
        Log.info("handoff → \(app.name): \(regions.count) region(s), submit=\(submit), typed=\(canType)")
        show(canType ? .pasted(app.name) : .failed("It's on your clipboard. Press ⌘V in \(app.name) (Awan needs Accessibility to paste for you)."), for: 5)
    }

    private func show(_ s: Status, for seconds: Double) {
        status = s
        NotchController.shared.present(.handoff, for: seconds)
    }

    /// Snapshot/demo only.
    func debugInstall(queued: [HandoffRegion], current: HandoffRegion?, status: Status?, comment: String = "", listening: Bool = false) {
        self.listening = listening
        self.queued = queued
        self.current = current
        self.status = status
        self.comment = comment
    }
}

/// One captured region.
struct HandoffRegion: Identifiable, Equatable {
    let id = UUID()
    /// AppKit global coordinates (bottom-left origin, points).
    let rect: CGRect
    let image: CGImage
    let png: Data

    static func == (a: HandoffRegion, b: HandoffRegion) -> Bool { a.id == b.id }

    /// As a companion screenshot: the geometry maps pixels back onto the region, so pointing still lands right.
    var frame: ScreenCaptureFrame {
        let (img, jpeg) = RegionCapture.forModel(image)
        return ScreenCaptureFrame(
            index: 1, count: 1, isCursorScreen: false, displayID: CGMainDisplayID(),
            geometry: CaptureGeometry(displayFrame: rect, pixelSize: CGSize(width: img.width, height: img.height)),
            image: img, jpeg: jpeg,
            label: "the region of the screen the user boxed (image dimensions: \(img.width)x\(img.height) pixels)"
        )
    }
}

/// Apps the "Paste into…" menu offers (only the ones that are running show).
struct HandoffTargetApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    /// Command-line agents take image paths as text; GUI apps take the image itself.
    let isTerminal: Bool
    var id: String { bundleID }

    static let known: [HandoffTargetApp] = [
        .init(bundleID: "com.apple.Terminal", name: "Terminal", isTerminal: true),
        .init(bundleID: "com.googlecode.iterm2", name: "iTerm", isTerminal: true),
        .init(bundleID: "dev.warp.Warp-Stable", name: "Warp", isTerminal: true),
        .init(bundleID: "com.mitchellh.ghostty", name: "Ghostty", isTerminal: true),
        .init(bundleID: "com.anthropic.claudefordesktop", name: "Claude", isTerminal: false),
        .init(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor", isTerminal: false),
        .init(bundleID: "com.openai.codex", name: "Codex", isTerminal: false),
        .init(bundleID: "com.microsoft.VSCode", name: "VS Code", isTerminal: false),
        .init(bundleID: "com.openai.chat", name: "ChatGPT", isTerminal: false),
    ]

    static func running() -> [HandoffTargetApp] {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return known.filter { ids.contains($0.bundleID) }
    }

    static var debugRunning: [HandoffTargetApp]?
    static var available: [HandoffTargetApp] { debugRunning ?? running() }
}

// MARK: - Files

enum HandoffFiles {
    static func write(_ regions: [HandoffRegion], into dir: URL) -> [String] {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        var out: [String] = []
        for (i, r) in regions.enumerated() {
            let name = regions.count == 1 ? "screen-region-\(stamp).png" : "screen-region-\(stamp)-\(i + 1).png"
            let url = dir.appendingPathComponent(name)
            if (try? r.png.write(to: url, options: .atomic)) != nil { out.append(url.path) }
        }
        return out
    }

    /// What a terminal agent receives: the note, then each path (quoted when it has spaces).
    static func terminalLine(note: String, paths: [String]) -> String {
        let quoted = paths.map { $0.contains(" ") ? "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" : $0 }
        return ([note] + quoted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func prune(_ dir: URL, olderThan seconds: TimeInterval) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for u in items {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if Date().timeIntervalSince(d) > seconds { try? fm.removeItem(at: u) }
        }
    }
}

@MainActor
enum Keystrokes {
    static func commandV() {
        let v = TextInserter.keyCode(for: "v") ?? 9
        post(v, flags: .maskCommand)
    }

    static func returnKey() { post(36, flags: []) }

    private static func post(_ key: CGKeyCode, flags: CGEventFlags) {
        guard let src = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

// MARK: - Capture

enum RegionCapture {
    enum Failure: LocalizedError {
        case noScreen, noDisplay, encode
        var errorDescription: String? {
            switch self {
            case .noScreen: return "That box isn't on any screen."
            case .noDisplay: return "Couldn't find the display to capture."
            case .encode: return "Couldn't save that capture."
            }
        }
    }

    /// Captures a global AppKit rect at the display's native resolution, excluding Awan's own windows.
    static func capture(_ rect: CGRect) async throws -> CGImage {
        let screens = NSScreen.screens.filter { $0.frame.intersects(rect) }
        guard let screen = screens.max(by: { area($0.frame.intersection(rect)) < area($1.frame.intersection(rect)) }) else { throw Failure.noScreen }
        let clipped = rect.intersection(screen.frame)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { throw Failure.noDisplay }
        let pid = ProcessInfo.processInfo.processIdentifier
        let own = content.windows.filter { $0.owningApplication?.processID == pid }
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect(for: clipped, in: screen.frame)
        let scale = screen.backingScaleFactor
        config.width = max(1, Int((clipped.width * scale).rounded()))
        config.height = max(1, Int((clipped.height * scale).rounded()))
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: own)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Global (bottom-left) rect → the display-local, top-left rect ScreenCaptureKit wants.
    static func sourceRect(for global: CGRect, in screen: CGRect) -> CGRect {
        CGRect(x: global.minX - screen.minX, y: screen.maxY - global.maxY, width: global.width, height: global.height)
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Longest side ≤ 1600 px as JPEG for the companion model.
    static func forModel(_ image: CGImage, maxSide: Int = 1600) -> (CGImage, Data) {
        var img = image
        let longest = max(image.width, image.height)
        if longest > maxSide {
            let s = CGFloat(maxSide) / CGFloat(longest)
            let w = Int(CGFloat(image.width) * s), h = Int(CGFloat(image.height) * s)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                img = ctx.makeImage() ?? image
            }
        }
        return (img, ScreenCapture.jpegData(img) ?? Data())
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}

/// Gives keyboard focus back to the app the user was in once the overlay closes.
@MainActor
enum HandoffFocus {
    private static var releaser: NSPanel?
    static func release() {
        guard NSApp.keyWindow is RegionSelectPanel || NSApp.keyWindow == nil else { return }
        let p = releaser ?? {
            let p = NSPanel(contentRect: NSRect(x: -10, y: -10, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.alphaValue = 0
            p.ignoresMouseEvents = true
            releaser = p
            return p
        }()
        p.makeKeyAndOrderFront(nil)
        p.orderOut(nil)
    }
}
