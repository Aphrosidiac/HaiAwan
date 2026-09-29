import AppKit
import SwiftUI
import Combine

/// Onboarding: pre-sign-in intro → sign in → permissions → tutorial (with the interview folded in)
/// → plan chooser → squad → hatch → Home tour. A centred floating panel that is 720×480 for the setup steps,
/// the reference-sized 500×571 tutorial panel for the tutorial and 800×543 for the plan chooser.
/// Keep: shared, begin(), replay().
@MainActor final class OnboardingController {
    static let shared = OnboardingController()

    private(set) var model = OnboardingModel()
    private var panel: OnboardingPanel?
    private var stageSink: AnyCancellable?

    var isShowing: Bool { panel?.isVisible == true }

    /// Show the right step for the current state.
    func begin() {
        let state = AppState.shared
        let fresh = OnboardingModel()
        model = fresh
        wire(fresh)
        show()
        if state.signInState == .signedIn {
            fresh.stage = .intro   // intro → (already signed in) → permissions or tutorial
            if Prefs.shared.onboardingCompleted { fresh.advance() }
        } else {
            fresh.stage = .intro
        }
    }

    /// Settings → "Replay the welcome tour": intro → tutorial → interview → squad, keeping existing Awans.
    func replay() {
        let fresh = OnboardingModel()
        fresh.isReplay = true
        model = fresh
        wire(fresh)
        fresh.stage = .intro
        show()
    }

    private func wire(_ m: OnboardingModel) {
        m.onClose = { [weak self] in self?.hide() }
        m.onFinish = { [weak self] squad in self?.finish(with: squad) }
        stageSink = m.$stage
            .map { OnboardingLayout.size(for: $0) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] size in self?.resize(to: size) }
    }

    /// Resize around the panel's centre when the stage changes window size (card ↔ tutorial ↔ plans).
    private func resize(to size: CGSize) {
        guard let panel, panel.isVisible, panel.frame.size != size else { return }
        let f = panel.frame
        let target = NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: - Panel

    private func show() {
        if panel == nil { panel = OnboardingPanel() }
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: OnboardingRootView(model: model) { [weak self] in self?.hide() })
        let size = OnboardingLayout.size(for: model.stage)
        panel.setContentSize(size)
        panel.center()
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + 20))
        }
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        SpaceFollower.bringToActiveSpace(panel)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 1
        }
        if model.stage == .intro { Sounds.play(.reveal) }
        Log.info("onboarding shown visible=\(panel.isVisible) activeSpace=\(panel.isOnActiveSpace) occlusion=\(panel.occlusionState.contains(.visible)) frame=\(NSStringFromRect(panel.frame)) appActive=\(NSApp.isActive)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Log.info("onboarding +2s visible=\(panel.isVisible) activeSpace=\(panel.isOnActiveSpace) occlusion=\(panel.occlusionState.contains(.visible)) alpha=\(panel.alphaValue)")
        }
    }

    private var homeFrame: NSRect?

    /// While the user is in System Settings: slide to the left edge and drop behind it, so nothing is covered.
    func stepAside() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        homeFrame = panel.frame
        let f = screen.visibleFrame
        let target = NSRect(x: f.minX + 16, y: f.midY - panel.frame.height / 2, width: panel.frame.width, height: panel.frame.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            panel.animator().setFrame(target, display: true)
        }
        panel.orderBack(nil)
    }

    /// Permission granted: come back to the centre and to the front.
    func comeBack() {
        guard let panel else { return }
        if let homeFrame {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                panel.animator().setFrame(homeFrame, display: true)
            }
        }
        homeFrame = nil
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard let panel else { return }
        PermissionGuidePanel.shared.hide()
        TourMusic.shared.stop()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    // MARK: - Finish: create the squad, hatch, Home tour, paywall

    private func finish(with squad: [AwanSpecDTO]) {
        let store = AgentStore.shared
        var hatched: [AwanAgent] = []
        for spec in squad { hatched.append(store.create(from: spec)) }
        store.seedStarterCastIfNeeded()
        if hatched.isEmpty { hatched = store.visibleAgents.filter(\.isStarter) }

        let from = panel.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
        let sawPlans = model.plansShown
        hide()
        HatchOverlay.shared.play(agents: Array(hatched.prefix(3)), from: from) {
            Prefs.shared.onboardingCompleted = true
            Task { await AppState.shared.loadSuggestions() }
            AppState.shared.openHome(.home)
            Sounds.play(.homeReveal)
            HomeTour.shared.start {
                // The plan chooser already ran inside onboarding; only fall back to the paywall if it didn't.
                if !sawPlans { AppState.shared.presentPaywall(.onboardingCompleted) }
            }
        }
    }
}

/// Borderless, movable, key-capable panel (it needs text input for email and answers).
final class OnboardingPanel: NSPanel {
    init() {
        // Floats only while Awan is the active app (so it shows on whatever Space the user is on, even over a
        // full-screen app); the moment the user goes to System Settings or any other app it drops to a normal
        // window and never covers what it asked them to do. Only the notch and the drag card always float.
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480), styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSApp.isActive ? .floating : .normal
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.level = .normal
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.level = .floating
        }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Hatch: the squad pops out and flies up into the notch

@MainActor
final class HatchOverlay {
    static let shared = HatchOverlay()
    private var panel: NSPanel?

    func play(agents: [AwanAgent], from: CGPoint, done: @escaping () -> Void) {
        guard let screen = NSScreen.main, !agents.isEmpty else { done(); return }
        let frame = screen.frame
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar + 3
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // global (bottom-left origin) → view (top-left origin)
        let start = CGPoint(x: from.x - frame.minX, y: frame.maxY - from.y)
        let notch = CGPoint(x: frame.width / 2, y: 14)
        p.contentView = NSHostingView(rootView: HatchFlightView(agents: agents, start: start, end: notch))
        p.orderFrontRegardless()
        panel = p
        Sounds.play(.hatch)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.1))
            self?.panel?.orderOut(nil)
            self?.panel = nil
            done()
        }
    }
}

struct HatchFlightView: View {
    let agents: [AwanAgent]
    let start: CGPoint
    let end: CGPoint
    @Local private var popped = false
    @Local private var flown = false

    var body: some View {
        ZStack {
            ForEach(Array(agents.enumerated()), id: \.element.slug) { i, a in
                let spread = CGFloat(i - (agents.count - 1) / 2) * 110 + (agents.count % 2 == 0 ? 55 : 0)
                VStack(spacing: 6) {
                    AgentAvatar(appearance: a.character, size: 76, mood: .happy)
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
                    Text(a.name).font(.awan(13, .semibold)).foregroundStyle(Theme.bone)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .opacity(flown ? 0 : 1)
                }
                .scaleEffect(flown ? 0.18 : popped ? 1 : 0.05)
                .opacity(flown ? 0.2 : 1)
                .position(flown ? end : CGPoint(x: start.x + (popped ? spread : 0), y: start.y + (popped ? -20 : 40)))
                .animation(.spring(response: 0.5, dampingFraction: 0.55).delay(Double(i) * 0.14), value: popped)
                .animation(.easeIn(duration: 0.55).delay(Double(i) * 0.12), value: flown)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            popped = true
            Task {
                try? await Task.sleep(for: .seconds(1.7))
                flown = true
            }
        }
    }
}

// MARK: - Home tour: three coach marks over Home, then the paywall

@MainActor
final class HomeTour {
    static let shared = HomeTour()
    private var panel: NSPanel?
    private var done: (() -> Void)?

    struct Mark: Equatable {
        let title: String
        let body: String
        /// The region to light up, in Home's coordinates (top-left origin), from Home's size.
        /// Home's sidebar is 256 pt wide; the talk pill sits in the middle of the content column.
        let spot: (CGSize) -> CGRect
        static func == (a: Mark, b: Mark) -> Bool { a.title == b.title }
    }

    static let marks: [Mark] = [
        Mark(title: "These are your Awans", body: "Each one has its own job, memory and folder. Click one to send it work.") { s in
            CGRect(x: 10, y: 168, width: 236, height: min(290, s.height - 290))
        },
        Mark(title: "Suggestions land here every morning", body: "Your Awans suggest things they could do for you. Say yes and they get going.") { _ in
            CGRect(x: 10, y: 106, width: 236, height: 58)
        },
        Mark(title: "Hold to talk, or type", body: "Hold Control + Option anywhere, or double-tap Control to type to me.") { s in
            CGRect(x: 256 + (s.width - 256) / 2 - 118, y: s.height * 0.33, width: 236, height: 50)
        },
    ]

    func start(done: @escaping () -> Void) {
        self.done = done
        Task {
            try? await Task.sleep(for: .seconds(0.7))
            show()
        }
    }

    private func homeWindow() -> NSWindow? {
        NSApp.windows.filter { $0.isVisible && !($0 is NotchPanel) && !($0 is OnboardingPanel) && $0 !== panel && $0.frame.width > 600 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private func show() {
        guard let home = homeWindow() else { finish(); return }
        var frame = home.frame
        if home is HomePanel { frame.size.height -= NotchGeometry.current().menuBarHeight }   // content below the neck
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = home.level + 1
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: HomeTourView(size: frame.size) { [weak self] in self?.finish() })
        p.orderFrontRegardless()
        panel = p
    }

    private func finish() {
        panel?.orderOut(nil)
        panel = nil
        let d = done
        done = nil
        d?()
    }
}

struct HomeTourView: View {
    let size: CGSize
    var finish: () -> Void
    @Local private var index = 0

    var body: some View {
        let mark = HomeTour.marks[index]
        let spot = mark.spot(size)
        ZStack(alignment: .topLeading) {
            // dim everything except the spotlit region
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRoundedRect(in: spot.insetBy(dx: -4, dy: -4), cornerSize: CGSize(width: 16, height: 16))
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .contentShape(Rectangle())
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.lime, lineWidth: 2)
                .frame(width: spot.width + 8, height: spot.height + 8)
                .position(x: spot.midX, y: spot.midY)
            CoachMarkCard(mark: mark, step: index, count: HomeTour.marks.count) {
                if index + 1 < HomeTour.marks.count { withAnimation(Theme.spring) { index += 1 } } else { finish() }
            } skip: { finish() }
                .position(cardPosition(spot))
                .id(index)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
        .frame(width: size.width, height: size.height)
        .animation(Theme.spring, value: index)
        .preferredColorScheme(.dark)
    }

    /// Beside the spot when there is room on the right, otherwise below it.
    private func cardPosition(_ r: CGRect) -> CGPoint {
        let w: CGFloat = 290, h: CGFloat = 150
        var p = CGPoint(x: r.maxX + 22 + w / 2, y: r.minY + h / 2)
        if r.minX > 200 { p = CGPoint(x: r.midX, y: r.maxY + 22 + h / 2) }
        p.x = min(max(p.x, w / 2 + 16), size.width - w / 2 - 16)
        p.y = min(max(p.y, h / 2 + 16), size.height - h / 2 - 16)
        return p
    }
}

struct CoachMarkCard: View {
    let mark: HomeTour.Mark
    let step: Int
    let count: Int
    var next: () -> Void
    var skip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(step + 1) OF \(count)").font(.awan(10, .semibold)).tracking(0.9).foregroundStyle(Theme.ink.opacity(0.5))
            Text(mark.title).font(.awan(15, .semibold)).foregroundStyle(Theme.ink)
            Text(mark.body).font(.awan(12.5)).foregroundStyle(Theme.ink.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
            HStack {
                if step + 1 < count {
                    Button("Skip tour", action: skip).buttonStyle(.plain).font(.awan(12, .medium)).foregroundStyle(Theme.ink.opacity(0.55))
                }
                Spacer()
                Button(step + 1 < count ? "Next" : "Got it", action: next)
                    .buttonStyle(.gel(.dark, height: 28, padding: 14, fontSize: 12.5))
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 290)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.bone))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }
}
