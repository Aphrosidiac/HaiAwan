import AppKit
import SwiftUI
import Combine

/// What the notch is showing. (Reference: NotchActivityPhase + the notch surfaces.)
enum NotchMode: Equatable {
    case resting                    // tiny handle (no hardware notch) or the bare notch
    case activity                   // compact live activity: avatar left, status right
    case peek                       // hover quick-peek: suggestions + roster + footer
    case surface(NotchSurfaceKind)  // a transient card (text reply, dictation, morning hello…)
}

enum NotchSurfaceKind: Equatable {
    case textResponse
    case textInput
    case dictation
    case morningSuggestions
    case agentFinished(String)      // slug
    case unmuteFallback
    case message(String)
    // Wave 2 notch extras (Notch/Extras/)
    case handoff                        // "Region queued" / "Sent to <App>"
    case meetingCountdown               // "Meeting starting soon: …" · Join
    case integrationSuggestion(String)  // catalogue id: "<App> is open — connect it…"
    case appUpdated(String)             // version: "Awan updated to X"
    case fileDrop                       // files dragged over the notch: roster avatars as drop targets
    case dropComposer                   // dropped on the mascot: "What should I do with these?"
    case homeDetached                   // Home is popped out as a window: "Your Awan window is in view" · Attach to notch
}

/// Owns the notch panel. Like the reference, the panel itself never moves or resizes: it is a fixed, transparent
/// 820×620 window pinned to the top centre of the notch screen, and the black shape animates *inside* it (SwiftUI,
/// NotchRootView). The panel ignores the mouse everywhere except over the current shape and the handle's hot zone,
/// so its empty parts never block the apps underneath.
@MainActor
final class NotchController: ObservableObject {
    static let shared = NotchController()

    @Published var mode: NotchMode = .resting
    @Published private(set) var geometry = NotchGeometry.current()
    /// True while a close runs: the shape springs back into the handle (fading to ~0.27) before it is removed
    /// and the handle fades back in. Only used on Macs without a hardware notch.
    @Published private(set) var isCollapsing = false

    /// The fixed panel (the reference's notch window is a fixed 820×801).
    static let panelSize = CGSize(width: 820, height: 620)
    /// The resting handle on Macs without a hardware notch (measured: capsule 60×8 at y=4).
    static let handleSize = CGSize(width: 60, height: 8)
    static let handleTop: CGFloat = 4

    /// Measured on the reference (the measurementsand §4).
    enum Motion {
        /// Growing (rest → peek/card, or a card growing into a bigger one).
        static let open = Animation.spring(response: 0.40, dampingFraction: 0.84)
        /// Shrinking back to rest (or into a smaller card).
        static let close = Animation.spring(response: 0.46, dampingFraction: 1.0)
        /// Peek → attached Home in the same container. Awan's attached Home is still its own panel
        /// (HomeWindowController), so this is not used yet.
        static let expandHome = Animation.spring(response: 0.22, dampingFraction: 1.0)
        static let shapeFadeIn = Animation.easeOut(duration: 0.2)
        static let shapeFadeOut = Animation.linear(duration: 0.3)
        static let handleFade = Animation.easeOut(duration: 0.2)
        static let contentFadeOut = Animation.easeOut(duration: 0.1)
        /// The close spring (0.46, 1.0) is within half a point of rest after ~370 ms.
        static let closeSettle: Duration = .milliseconds(380)
        static let collapsedOpacity = 0.27
    }

    /// Pointer dwell on the hot zone before the peek opens (measured ≈600 ms).
    static let hoverIntent: Duration = .milliseconds(600)

    private var panel: NotchPanel?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var hoverTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var surfaceTimer: Task<Void, Never>?

    func install() {
        let panel = NotchPanel()
        let host = NSHostingView(rootView: NotchRootView().environmentObject(AppState.shared).environmentObject(self))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        placePanel()
        panel.orderFrontRegardless()

        // Global: the pointer is over another app (or over our panel while it ignores the mouse).
        // leftMouseDragged matters: a file dragged over the hot zone must un-ignore the panel so the drop lands.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.trackMouse() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
            Task { @MainActor in self?.trackMouse() }
            return e
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.geometry = NotchGeometry.current()
                self?.placePanel()
            }
        }
        // Activity mode follows the companion and the agents.
        AppState.shared.objectWillChange
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] in self?.syncActivity() }
            .store(in: &cancellables)
        Prefs.shared.$showInScreenRecordings.sink { [weak self] show in
            self?.panel?.sharingType = show ? .readOnly : .none
        }.store(in: &cancellables)
    }

    // MARK: - Mode changes

    func set(_ newMode: NotchMode) {
        guard newMode != mode else { return }
        collapseTask?.cancel(); collapseTask = nil
        let from = sizeFor(mode), to = sizeFor(newMode)
        if newMode == .resting && !geometry.hasHardwareNotch {
            // Close: content fades at once; the shape springs back into the handle while its opacity eases to
            // ~0.27; then it is removed and the handle fades back in (NotchRootView reads isCollapsing).
            isCollapsing = true
            withAnimation(Motion.close) { mode = newMode }
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: Motion.closeSettle)
                guard !Task.isCancelled, let self, self.mode == .resting else { return }
                self.isCollapsing = false
                self.collapseTask = nil
            }
        } else {
            isCollapsing = false
            let grows = to.width * to.height >= from.width * from.height
            withAnimation(grows ? Motion.open : Motion.close) { mode = newMode }
        }
        updateMouseIgnoring()
    }

    func openPeek() {
        guard !AppState.shared.isHomeOpen else { return }
        AppState.shared.isPeekOpen = true
        set(.peek)
    }

    func closePeek() {
        AppState.shared.isPeekOpen = false
        syncActivity(force: true)
    }

    /// Expand Home from the peek: the Home grows out of the peek's shape (reference: one container morphing,
    /// spring 0.22 / 1.0), so the peek itself disappears at once instead of playing its close animation over it.
    /// Returns the peek's shape size, or nil when the peek wasn't open.
    func handOffToHome() -> CGSize? {
        guard mode == .peek else { return nil }
        let size = sizeFor(.peek)
        collapseTask?.cancel(); collapseTask = nil
        isCollapsing = false
        AppState.shared.isPeekOpen = false
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { mode = .resting }
        updateMouseIgnoring()
        return size
    }

    /// Show a transient card, then fall back to activity/resting.
    func present(_ kind: NotchSurfaceKind, for seconds: Double? = 6) {
        surfaceTimer?.cancel()
        set(.surface(kind))
        guard let seconds else { return }
        surfaceTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismissSurface()
        }
    }

    func dismissSurface() {
        surfaceTimer?.cancel()
        if case .surface = mode { syncActivity(force: true) }
    }

    /// Resting ↔ activity based on what's happening (never overrides peek or a surface).
    func syncActivity(force: Bool = false) {
        if !force {
            if case .surface = mode { return }
            if mode == .peek { return }
        }
        let state = AppState.shared
        let busy = state.companion.voiceState != .idle || !state.agents.runningAgents.isEmpty || state.dictation.isDictating || state.agents.unreadCount > 0
        set(busy && !state.isHomeOpen ? .activity : .resting)
    }

    // MARK: - Hover (quick peek) and mouse pass-through

    private func trackMouse() {
        let p = NSEvent.mouseLocation
        updateMouseIgnoring(p)
        let hot = geometry.hotZone
        // Hover-opened things close again once the pointer leaves them.
        if mode == .peek || mode == .surface(.homeDetached) {
            if shapeRect(for: mode).insetBy(dx: -8, dy: -8).contains(p) || hot.contains(p) {
                leaveTask?.cancel(); leaveTask = nil
            } else if leaveTask == nil {
                leaveTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(260))
                    guard !Task.isCancelled, let self else { return }
                    self.leaveTask = nil
                    if self.mode == .peek { self.closePeek() } else { self.dismissSurface() }
                }
            }
            return
        }
        // With Home popped out as a window, hovering the notch offers to attach it instead of peeking.
        let detachedHome = AppState.shared.isHomeOpen && Prefs.shared.homeDetached
        // A drag over the notch is a file drop, not a hover.
        guard hot.contains(p), NSEvent.pressedMouseButtons == 0, !AppState.shared.isHomeOpen || detachedHome,
              AppState.shared.signInState == .signedIn else {
            hoverTask?.cancel(); hoverTask = nil
            return
        }
        guard hoverTask == nil else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverIntent)   // hover intent, so passing the cursor through doesn't pop it
            guard !Task.isCancelled, let self else { return }
            self.hoverTask = nil
            guard self.geometry.hotZone.contains(NSEvent.mouseLocation) else { return }
            if AppState.shared.isHomeOpen && Prefs.shared.homeDetached {
                if case .surface = self.mode { return }   // never cover a live card
                self.present(.homeDetached, for: nil)
            } else if Prefs.shared.quickPeekOnHover {
                self.openPeek()
            }
        }
    }

    /// The panel takes the mouse only over the visible shape and the handle's hot zone; everywhere else clicks,
    /// scrolls and drags go straight through to whatever is underneath.
    func updateMouseIgnoring(_ p: CGPoint = NSEvent.mouseLocation) {
        guard let panel else { return }
        let ignore = !interactiveRect.contains(p)
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    /// Screen rect that receives the mouse right now: the current shape plus the handle's hot zone.
    var interactiveRect: CGRect {
        shapeRect(for: mode).union(geometry.hotZone)
    }

    /// Where the shape for `mode` sits on screen: centred, hanging from the top of the notch screen.
    func shapeRect(for mode: NotchMode) -> CGRect {
        let s = sizeFor(mode), g = geometry
        return CGRect(x: g.screenFrame.midX - s.width / 2, y: g.screenFrame.maxY - s.height, width: s.width, height: s.height)
    }

    /// Click on the notch: peek if quick peek is off, otherwise expand Home.
    func notchClicked() {
        if mode == .peek || !Prefs.shared.quickPeekOnHover {
            AppState.shared.openHome()
            closePeek()
        } else {
            openPeek()
        }
    }

    // MARK: - Layout

    /// Pins the fixed panel to the top centre of the notch screen. It never resizes; the shape animates inside it.
    private func placePanel() {
        guard let panel else { return }
        let g = geometry, s = Self.panelSize
        panel.setFrame(NSRect(x: g.screenFrame.midX - s.width / 2, y: g.screenFrame.maxY - s.height, width: s.width, height: s.height), display: true)
        updateMouseIgnoring()
    }

    /// Kept for older callers: the panel is fixed now, so this only re-pins it.
    func layout(animated: Bool) { placePanel() }

    /// The size of the black shape for a mode (the panel itself is fixed at `panelSize`).
    func sizeFor(_ mode: NotchMode) -> CGSize {
        let g = geometry
        switch mode {
        case .resting:
            return g.hasHardwareNotch ? CGSize(width: g.notchWidth, height: g.menuBarHeight) : Self.handleSize
        case .activity: return CGSize(width: g.hasHardwareNotch ? g.notchWidth + 150 : 233, height: g.menuBarHeight + 2)
        case .peek: return NotchPeekLayout.size(for: AppState.shared)
        case let .surface(kind):
            switch kind {
            case .textInput: return CGSize(width: 460, height: 96)
            case .textResponse: return CGSize(width: 460, height: 260)
            case .dictation: return CGSize(width: g.notchWidth + 190, height: g.menuBarHeight + 34)
            case .morningSuggestions: return CGSize(width: 440, height: 250)
            case .agentFinished: return CGSize(width: 420, height: 150)
            case .unmuteFallback: return CGSize(width: 420, height: 120)
            case .message: return CGSize(width: 400, height: 84)
            case .handoff: return CGSize(width: 470, height: 112)
            case .meetingCountdown: return CGSize(width: 500, height: 118)
            case .integrationSuggestion: return CGSize(width: IntegrationCardLayout.size.width, height: IntegrationCardLayout.size.height + (g.hasHardwareNotch ? g.menuBarHeight : 0))
            case .appUpdated: return CGSize(width: 480, height: 112)
            case .fileDrop: return NotchDropLayout.size(count: NotchDropLayout.targets(AgentStore.shared.visibleAgents).count)
            case .dropComposer: return CGSize(width: 460, height: 132)
            case .homeDetached: return CGSize(width: 460, height: 115 + (g.hasHardwareNotch ? g.menuBarHeight : 0))
            }
        }
    }
}

/// Where the (real or drawn) notch is.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var hasHardwareNotch: Bool
    var notchWidth: CGFloat
    var menuBarHeight: CGFloat

    /// The strip at the top centre that opens the quick peek.
    var hotZone: CGRect {
        CGRect(x: screenFrame.midX - max(notchWidth, 160) / 2, y: screenFrame.maxY - menuBarHeight, width: max(notchWidth, 160), height: menuBarHeight + 1)
    }

    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return NotchGeometry(screenFrame: screen.frame, hasHardwareNotch: true, notchWidth: r.minX - l.maxX, menuBarHeight: screen.safeAreaInsets.top)
        }
        return NotchGeometry(screenFrame: screen.frame, hasHardwareNotch: false, notchWidth: 190, menuBarHeight: menuBar)
    }
}

/// Fixed-size transparent panel above the menu bar that never steals focus unless it needs text input.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(origin: .zero, size: NotchController.panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 2
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true   // NotchController un-ignores it while the pointer is over the shape or hot zone
    }

    override var canBecomeKey: Bool { true }   // needed for the text-input surface
    override var canBecomeMain: Bool { false }
}
