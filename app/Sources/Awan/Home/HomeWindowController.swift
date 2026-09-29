import AppKit
import SwiftUI
import Combine

/// Home either hangs from the notch (borderless panel with a neck into the menu bar) or pops out
/// into a normal resizable window ("Open as a window", reference v1.0.51).
@MainActor
final class HomeWindowController: NSObject, NSWindowDelegate {
    static let shared = HomeWindowController()

    private var attached: HomePanel?
    private var detached: NSWindow?
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    /// The attached panel (reference 875×557). The window adds a 16 pt shadow margin left/right and 40 below.
    static let attachedSize = CGSize(width: 875, height: 557)
    static let shadowMargin = NSEdgeInsets(top: 0, left: 16, bottom: 40, right: 16)
    static let neckHeight: CGFloat = 30

    var isDetached: Bool { Prefs.shared.homeDetached }

    func show() {
        if isDetached { showDetached() } else { showAttached() }
        NotchController.shared.syncActivity(force: true)
    }

    func hide() {
        if let attached, attached.isVisible, !Prefs.shared.homeDetached {
            // Reference: the Home shrinks back into the notch (ease-in, ≈180 ms), then disappears.
            HomeReveal.shared.collapse { [weak attached] in
                if !AppState.shared.isHomeOpen { attached?.orderOut(nil) }
            }
        } else {
            attached?.orderOut(nil)
        }
        detached?.orderOut(nil)
        removeMonitors()
        AppState.shared.isHomeOpen = false
        NotchController.shared.syncActivity(force: true)
    }

    func toggle() {
        if AppState.shared.isHomeOpen { AppState.shared.closeHome() } else { AppState.shared.openHome() }
    }

    func setDetached(_ value: Bool) {
        Prefs.shared.homeDetached = value
        attached?.orderOut(nil)
        detached?.orderOut(nil)
        show()
    }

    private func root() -> some View {
        HomeRootView()
            .environmentObject(AppState.shared)
            .environmentObject(AppState.shared.agents)
            .environmentObject(AppState.shared.companion)
            .environmentObject(RoutineScheduler.shared)
            .environmentObject(Prefs.shared)
    }

    private func attachedFrame() -> NSRect {
        let g = NotchGeometry.current()
        let saved = UserDefaults.standard.string(forKey: Prefs.Key.homeSize).map(NSSizeFromString)
        let size = saved.flatMap { $0.width > 600 ? $0 : nil } ?? Self.attachedSize
        let m = Self.shadowMargin
        return NSRect(x: g.screenFrame.midX - size.width / 2 - m.left,
                      y: g.screenFrame.maxY - g.menuBarHeight - size.height - m.bottom,
                      width: size.width + m.left + m.right, height: size.height + g.menuBarHeight + m.bottom)
    }

    private func makeAttachedIfNeeded(_ frame: NSRect) {
        guard attached == nil else { return }
        let p = HomePanel(contentRect: frame)
        p.animationBehavior = .none   // no window-server fade; the chrome morphs in and out of the notch itself
        let host = NSHostingView(rootView: AttachedHomeChrome(neckHeight: NotchGeometry.current().menuBarHeight) { self.root() })
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        attached = p
    }

    /// Build and render the attached Home once, invisibly, shortly after launch: the first real open is then
    /// cheap enough for the grow-out-of-the-notch morph to play (a cold first render took ≈160 ms and the
    /// morph finished before the first frame reached the screen).
    func prewarm() {
        guard attached == nil, !Prefs.shared.homeDetached, !AppState.shared.isHomeOpen else { return }
        let frame = attachedFrame()
        makeAttachedIfNeeded(frame)
        guard let p = attached else { return }
        p.alphaValue = 0
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()
        p.contentView?.layoutSubtreeIfNeeded()
        p.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if !AppState.shared.isHomeOpen { p.orderOut(nil) }
            p.alphaValue = 1
        }
    }

    private func showAttached() {
        let frame = attachedFrame()
        makeAttachedIfNeeded(frame)
        attached?.alphaValue = 1
        attached?.setFrame(frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        attached?.makeKeyAndOrderFront(nil)
        HomeReveal.shared.play()
        clearInitialFocus(attached)
        if let attached { SpaceFollower.bringToActiveSpace(attached) }
        installMonitors()
    }

    private func showDetached() {
        if detached == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1197, height: 809), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(hex: 0x141413)
            w.minSize = NSSize(width: 760, height: 520)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("AwanHomeWindow")
            w.contentView = NSHostingView(rootView: root().environment(\.homeIsDetached, true))
            w.center()
            detached = w
        }
        NSApp.activate(ignoringOtherApps: true)
        detached?.makeKeyAndOrderFront(nil)
        clearInitialFocus(detached)
        if let detached { SpaceFollower.bringToActiveSpace(detached) }
    }

    /// AppKit hands first responder to the first text field (the sidebar search) when the window becomes key,
    /// which shows a blinking caret the reference never has. Start with nothing focused.
    private func clearInitialFocus(_ window: NSWindow?) {
        DispatchQueue.main.async { window?.makeFirstResponder(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === detached { AppState.shared.isHomeOpen = false }
    }

    /// Esc closes the attached Home; a click outside it closes it too (like the reference).
    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53, AppState.shared.isHomeOpen, !Prefs.shared.homeDetached, AppState.shared.paywall == nil, AppState.shared.characterEditorSlug == nil {
                Task { @MainActor in AppState.shared.closeHome() }
                return nil
            }
            return e
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in
                guard let p = self.attached, p.isVisible else { return }
                let m = Self.shadowMargin
                let body = NSRect(x: p.frame.minX + m.left, y: p.frame.minY + m.bottom,
                                  width: p.frame.width - m.left - m.right, height: p.frame.height - m.bottom)
                if !body.contains(NSEvent.mouseLocation), !NotchGeometry.current().hotZone.contains(NSEvent.mouseLocation), AppState.shared.paywall == nil {
                    AppState.shared.closeHome()
                }
            }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
    }

    func rememberSize(_ size: CGSize) {
        UserDefaults.standard.set(NSStringFromSize(size), forKey: Prefs.Key.homeSize)
    }
}

final class HomePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // the chrome draws its own soft shadow inside the margin
        level = .statusBar + 1
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct HomeDetachedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var homeIsDetached: Bool {
        get { self[HomeDetachedKey.self] }
        set { self[HomeDetachedKey.self] = newValue }
    }
}

/// The notch-attached chrome (reference §4): a black neck from the screen top — 240 wide, flaring
/// with an 8 pt fillet into the menu bar and a 12.5 pt fillet into the panel — over an 875×557 panel
/// with 22 pt corners and a soft ~16 pt shadow. The panel sits 16 pt inside the window's left/right
/// edges and 40 above its bottom (the shadow margin).
struct AttachedHomeChrome<Content: View>: View {
    let neckHeight: CGFloat
    @ViewBuilder var content: () -> Content

    static var neckWidth: CGFloat { 240 }
    static var neckFillet: CGFloat { 12.5 }

    var body: some View {
        let m = HomeWindowController.shadowMargin
        VStack(spacing: 0) {
            Color.clear.frame(height: neckHeight)
            content()
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.window, style: .circular))
        }
        .background(
            AttachedHomeShape(neckHeight: neckHeight, neckWidth: Self.neckWidth)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        )
        .overlay(alignment: .top) {
            // Drawn over the panel's top edge so the neck and the panel read as one surface.
            NeckShape(fillet: Self.neckFillet)
                .fill(Color.black)
                .frame(width: Self.neckWidth + 2 * Self.neckFillet, height: neckHeight)
                .allowsHitTesting(false)
        }
        .modifier(HomeRevealMask(neckHeight: neckHeight))   // silhouette, neck and content grow together
        .padding(.leading, m.left)
        .padding(.trailing, m.right)
        .padding(.bottom, m.bottom)
    }
}

/// Peek → Home morph. The reference grows one container from the peek's size to the Home's in ≈270 ms
/// (spring response 0.22, damping 1.0) with the content laid out at full size and revealed by the growing
/// clip, centred and pinned to the top. Opening any other way grows from the resting handle.
@MainActor
final class HomeReveal: ObservableObject {
    static let shared = HomeReveal()
    static let spring = Animation.spring(response: 0.22, dampingFraction: 1.0)
    /// The mask stays attached for the whole morph (a structural change mid-animation would jump to the end).
    @Published private(set) var active = false
    @Published private(set) var progress: CGFloat = 1
    @Published private(set) var from = CGSize(width: 60, height: 8)
    private var endTask: Task<Void, Never>?

    func prepare(from peek: CGSize?) {
        guard !Prefs.shared.homeDetached, !AppState.shared.isHomeOpen else { return }
        endTask?.cancel()
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            from = peek ?? CGSize(width: 60, height: 8)
            progress = 0
            active = true
        }
    }

    static let closeCurve = Animation.timingCurve(0.42, 0, 1, 1, duration: 0.19)

    /// Shrink back into the notch handle, then run `done` (order the window out).
    func collapse(_ done: @escaping () -> Void) {
        endTask?.cancel()
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            from = CGSize(width: 60, height: 8)
            progress = 1
            active = true
        }
        DispatchQueue.main.async {
            withAnimation(Self.closeCurve) { self.progress = 0 }
            self.endTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self else { return }
                done()
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { self.active = false; self.progress = 1 }
            }
        }
    }

    func play() {
        guard active else { return }
        // Let one frame render at the peek's size first; otherwise both states commit together and nothing animates.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.034) {
            withAnimation(Self.spring) { self.progress = 1 }
            self.endTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(480))
                guard !Task.isCancelled, let self else { return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { self.active = false }
            }
        }
    }
}

/// Clips the attached Home to the growing silhouette while `HomeReveal` runs (no clip once it has settled,
/// so the soft shadow isn't cut).
struct HomeRevealMask: ViewModifier {
    let neckHeight: CGFloat
    @ObservedObject private var reveal = HomeReveal.shared

    func body(content: Content) -> some View {
        if reveal.active {
            content.mask(alignment: .top) { RevealShape(progress: reveal.progress, from: reveal.from) }
        } else {
            content
        }
    }
}

/// The growing silhouette: from the peek's size to the full chrome, top-centred.
private struct RevealShape: Shape {
    var progress: CGFloat
    var from: CGSize
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func path(in r: CGRect) -> Path {
        let p = max(0, progress)
        let w = from.width + (r.width - from.width) * p
        let h = from.height + (r.height - from.height) * p
        let radius = 16 + (Theme.Radius.window - 16) * min(p, 1)
        return Path(roundedRect: CGRect(x: r.midX - w / 2, y: r.minY, width: w, height: h), cornerRadius: radius, style: .continuous)
    }
}

/// Panel + neck silhouette (casts the shadow).
struct AttachedHomeShape: Shape {
    var neckHeight: CGFloat
    var neckWidth: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path(roundedRect: CGRect(x: r.minX, y: r.minY + neckHeight, width: r.width, height: r.height - neckHeight),
                     cornerRadius: Theme.Radius.window, style: .circular)
        p.addRect(CGRect(x: r.midX - neckWidth / 2, y: r.minY, width: neckWidth, height: neckHeight + 1))
        return p
    }
}

/// Neck: the stem with 8 pt concave flares into the menu bar at the top and `fillet` concave flares
/// into the panel at the bottom (measured: x 325→333.5 over y 0→6, 333.5→321 over y 18→30).
struct NeckShape: Shape {
    var fillet: CGFloat = 12.5
    func path(in r: CGRect) -> Path {
        let f = fillet, t: CGFloat = 8
        let l = r.minX + f, rr = r.maxX - f
        var p = Path()
        p.move(to: CGPoint(x: l - t, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: l, y: r.minY + t), control: CGPoint(x: l, y: r.minY))
        p.addLine(to: CGPoint(x: l, y: r.maxY - f))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY), control: CGPoint(x: l, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY + 1))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY + 1))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: rr, y: r.maxY - f), control: CGPoint(x: rr, y: r.maxY))
        p.addLine(to: CGPoint(x: rr, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: rr + t, y: r.minY), control: CGPoint(x: rr, y: r.minY))
        p.closeSubpath()
        return p
    }
}

