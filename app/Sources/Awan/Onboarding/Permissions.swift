import AppKit
import SwiftUI
import AVFoundation
import Speech
import ApplicationServices
import CoreGraphics

/// The four macOS permissions Awan asks for during onboarding. Awan only ever *asks*: it shows the
/// system prompt or opens the right System Settings pane. It never changes a setting itself.
enum PermissionKind: String, CaseIterable, Identifiable {
    case microphone, speech, accessibility, screenRecording
    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speech: return "Speech recognition"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: return "mic.fill"
        case .speech: return "waveform"
        case .accessibility: return "hand.point.up.left.fill"
        case .screenRecording: return "rectangle.dashed.badge.record"
        }
    }

    var headline: String {
        switch self {
        case .microphone: return "Let me hear you"
        case .speech: return "Let me turn your voice into words"
        case .accessibility: return "Let me type and point for you"
        case .screenRecording: return "Let me see what you see"
        }
    }

    var explanation: String {
        switch self {
        case .microphone: return "You talk to me by holding Control + Option. I need the mic for that, and for dictation."
        case .speech: return "Your words show up live while you talk, straight from your Mac's own speech engine."
        case .accessibility: return "This lets dictation type into any app and lets your shortcuts work everywhere."
        case .screenRecording: return "When you ask about something on screen, I take one look so I can point at the right thing."
        }
    }

    var privacyLine: String {
        switch self {
        case .microphone: return "I only listen while you hold your shortcut."
        case .speech: return "Nothing is kept after your words are typed."
        case .accessibility: return "I never click or type unless you asked me to."
        case .screenRecording: return "I only look when you hold your shortcut. Screenshots aren't stored."
        }
    }

    var settingsURL: URL {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .speech: pane = "Privacy_SpeechRecognition"
        case .accessibility: pane = "Privacy_Accessibility"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    /// Accessibility and Screen Recording are switched on in System Settings (no in-app yes/no).
    var usesSettingsList: Bool { self == .accessibility || self == .screenRecording }
}

enum PermissionStatus: Equatable {
    case notDetermined, waiting, granted, denied

    var label: String {
        switch self {
        case .notDetermined: return "Not set up yet"
        case .waiting: return "Waiting for System Settings…"
        case .granted: return "Allowed"
        case .denied: return "Turned off"
        }
    }

    var shortLabel: String { self == .waiting ? "Waiting…" : label }
}

enum PermissionProbe {
    /// Read-only status checks (none of these show a prompt).
    static func status(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        }
    }

    /// Show the system's own prompt (and, for list-style permissions, the Settings pane).
    @MainActor static func request(_ kind: PermissionKind, done: @escaping @MainActor () -> Void) {
        switch kind {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in done() } }
        case .speech:
            SFSpeechRecognizer.requestAuthorization { _ in Task { @MainActor in done() } }
        case .accessibility:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            done()
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
            done()
        }
    }

    @MainActor static func openSettings(_ kind: PermissionKind) {
        OnboardingController.shared.stepAside()
        NSWorkspace.shared.open(kind.settingsURL)
    }
}

// MARK: - Floating "drag me in" guide beside System Settings

/// A small card pinned near the top-right of the screen while System Settings is open: the Awan icon
/// can be dragged straight into the Accessibility / Screen Recording list.
@MainActor
final class PermissionGuidePanel {
    static let shared = PermissionGuidePanel()
    private var panel: NSPanel?

    func show(for kind: PermissionKind) {
        hide()
        guard let screen = NSScreen.main else { return }
        let size = CGSize(width: 300, height: 92)
        let origin = Self.originBesideSystemSettings(size: size, screen: screen)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = false   // a background drag would move the card instead of dragging the icon
        p.hidesOnDeactivate = false
        p.contentView = NSHostingView(rootView: PermissionGuideCard(kind: kind) { [weak self] in self?.hide() })
        p.orderFrontRegardless()
        panel = p
        follow(kind: kind, size: size)
    }

    /// System Settings takes a moment to open and may move: keep the card glued to its left edge.
    private func follow(kind: PermissionKind, size: CGSize) {
        Task { @MainActor [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let panel = self.panel, let screen = NSScreen.main else { return }
                let o = Self.originBesideSystemSettings(size: size, screen: screen)
                if abs(panel.frame.origin.x - o.x) > 2 || abs(panel.frame.origin.y - o.y) > 2 { panel.setFrameOrigin(o) }
            }
        }
    }

    /// Just left of the System Settings window, level with its list; top-right of the screen if it isn't open.
    static func originBesideSystemSettings(size: CGSize, screen: NSScreen) -> CGPoint {
        let fallback = CGPoint(x: screen.visibleFrame.maxX - size.width - 24, y: screen.visibleFrame.maxY - size.height - 24)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return fallback }
        let settings = list.first {
            ($0[kCGWindowOwnerName as String] as? String).map { $0 == "System Settings" || $0 == "System Preferences" } == true
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        guard let b = settings?[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return fallback }
        // CG window bounds are top-left based; convert to AppKit's bottom-left.
        let top = screen.frame.maxY - y
        var ox = x - size.width - 12
        if ox < screen.visibleFrame.minX + 8 { ox = min(x + w - size.width - 16, screen.visibleFrame.maxX - size.width - 8) }  // no room on the left: sit inside the right edge
        let oy = max(screen.visibleFrame.minY + 8, top - 120 - size.height)
        _ = h
        return CGPoint(x: ox, y: oy)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct PermissionGuideCard: View {
    let kind: PermissionKind
    var close: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            AppBundleDragSource()
                .frame(width: 50, height: 50)
                .help("Drag Awan into the list")
            VStack(alignment: .leading, spacing: 3) {
                Text("Drag me into the list").font(.awan(13, .semibold)).foregroundStyle(Theme.text)
                Text("Drop the icon into \(kind.title), then switch Awan on.").font(.awan(11.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            CircleIconButton(systemName: "xmark", size: 20, action: close)
        }
        .padding(14)
        .frame(width: 300, height: 92)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.lime.opacity(0.5), lineWidth: 1))
        .preferredColorScheme(.dark)
    }
}


// MARK: - Dragging Awan.app into a privacy list

/// The app icon as a real AppKit drag source: the pasteboard carries Awan.app's file URL, which is exactly
/// what System Settings' Accessibility / Screen Recording lists accept (same as dragging from Finder).
struct AppBundleDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> DragIconView { DragIconView() }
    func updateNSView(_ nsView: DragIconView, context: Context) {}
}

final class DragIconView: NSView, NSDraggingSource {
    private let icon = NSApp.applicationIconImage ?? NSImage()
    private var downEvent: NSEvent?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds.insetBy(dx: 2, dy: 2))
    }

    override func mouseDown(with event: NSEvent) { downEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        downEvent = nil
        let url = Bundle.main.bundleURL as NSURL
        let item = NSDraggingItem(pasteboardWriter: url)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: down, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}
