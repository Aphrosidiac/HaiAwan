import AppKit
import SwiftUI

/// One translucent, key-capable panel per display. Drag draws the box (crosshair), Esc or right-click
/// cancels; once a box is drawn the other displays stop taking drags and the action bar appears beside it.
@MainActor
final class RegionSelectOverlay {
    private var panels: [RegionSelectPanel] = []
    private var onSelected: ((CGRect) -> Void)?
    private var onCancel: (() -> Void)?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var cursorPushed = false

    func show(onSelected: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        hide()
        self.onSelected = onSelected
        self.onCancel = onCancel
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let panel = RegionSelectPanel(screen: screen)
            panel.canvas.onFinished = { [weak self] rect in self?.finished(rect) }
            panel.canvas.onCancelled = { [weak self] in self?.cancelled() }
            panel.orderFrontRegardless()
            panels.append(panel)
            if screen.frame.contains(mouse) { panel.makeKey() }
            panel.makeFirstResponder(panel.canvas)
        }
        if !panels.contains(where: \.isKeyWindow) { panels.first?.makeKey() }
        NSCursor.crosshair.push()
        cursorPushed = true
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53 else { return e }
            MainActor.assumeIsolated { self?.cancelled() }
            return nil
        }
        // Esc even when a panel isn't key (non-activating panels can lose key to the app underneath).
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.cancelled() } }
        }
    }

    func showActionBar(for rect: CGRect) {
        for p in panels {
            if p.screenFrame.intersects(rect) {
                p.canvas.showActionBar()
                p.makeKey()
            } else {
                p.canvas.model.locked = true
            }
        }
        popCursor()
    }

    func hide() {
        popCursor()
        panels.forEach { $0.orderOut(nil) }
        panels = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        keyMonitor = nil
        localKeyMonitor = nil
    }

    private func popCursor() {
        guard cursorPushed else { return }
        cursorPushed = false
        NSCursor.pop()
    }

    private func finished(_ rect: CGRect) {
        for p in panels where !p.screenFrame.intersects(rect) { p.canvas.model.locked = true }
        onSelected?(rect)
    }

    private func cancelled() {
        let cb = onCancel
        onCancel = nil
        cb?()
    }
}

final class RegionSelectPanel: NSPanel {
    let canvas: RegionCanvasView
    let screenFrame: CGRect

    init(screen: NSScreen) {
        screenFrame = screen.frame
        canvas = RegionCanvasView(screenFrame: screen.frame)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)   // above the notch and the buddy
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        sharingType = .none
        contentView = canvas
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// State the SwiftUI shade draws (flipped view coordinates: top-left origin, points).
@MainActor
final class RegionSelectModel: ObservableObject {
    @Published var start: CGPoint?
    @Published var end: CGPoint?
    @Published var frozen: CGRect?
    /// Another display owns the selection; this one only dims.
    @Published var locked = false

    var liveRect: CGRect? {
        if let frozen { return frozen }
        guard let start, let end else { return nil }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

/// Mouse handling + two hosted SwiftUI layers: the shade (never hit-tested) and the action bar.
final class RegionCanvasView: NSView {
    let screenFrame: CGRect
    let model: RegionSelectModel
    var onFinished: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?
    private let shade: PassThroughHostingView<RegionShadeView>
    private var bar: NSHostingView<AnyView>?

    init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
        let model = MainActor.assumeIsolated { RegionSelectModel() }
        self.model = model
        shade = PassThroughHostingView(rootView: RegionShadeView(model: model))
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
        shade.frame = bounds
        shade.autoresizingMask = [.width, .height]
        addSubview(shade)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let bar, !bar.isHidden {
            let p = convert(point, from: superview)
            if bar.frame.contains(p) { return bar.hitTest(p) ?? bar }
        }
        return frame.contains(point) ? self : nil
    }

    override func cursorUpdate(with event: NSEvent) {
        (selecting ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    private var selecting: Bool { MainActor.assumeIsolated { model.frozen == nil && !model.locked } }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard model.frozen == nil, !model.locked else { return }
            let p = convert(event.locationInWindow, from: nil)
            model.start = p
            model.end = p
        }
    }

    override func mouseDragged(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard model.frozen == nil, !model.locked, model.start != nil else { return }
            model.end = convert(event.locationInWindow, from: nil)
        }
    }

    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard model.frozen == nil, !model.locked, let r = model.liveRect else { return }
            guard r.width >= 8, r.height >= 8 else { model.start = nil; model.end = nil; return }   // a click, not a box
            model.frozen = r
            onFinished?(globalRect(r))
        }
    }

    override func rightMouseDown(with event: NSEvent) { onCancelled?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancelled?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancelled?() }

    /// Flipped view rect → AppKit global rect.
    func globalRect(_ r: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + r.minX, y: screenFrame.maxY - r.maxY, width: r.width, height: r.height)
    }

    func showActionBar() {
        MainActor.assumeIsolated {
            guard let r = model.frozen else { return }
            let host = FirstMouseHostingView(rootView: AnyView(HandoffActionBar().environmentObject(HandoffManager.shared).environmentObject(AgentStore.shared)))
            let size = HandoffActionBar.size
            host.frame = CGRect(origin: HandoffActionBar.origin(for: r, in: bounds.size), size: size)
            addSubview(host)
            bar = host
            window?.makeFirstResponder(self)
        }
    }
}

/// A hosting view that never takes clicks (the shade is drawing only).
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Dim everything except the box; lime border, size readout and the hint pill.
struct RegionShadeView: View {
    @ObservedObject var model: RegionSelectModel

    var body: some View {
        GeometryReader { geo in
            let r = model.liveRect
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    if let r { p.addRoundedRect(in: r, cornerSize: CGSize(width: 4, height: 4)) }
                }
                .fill(Color.black.opacity(model.locked ? 0.28 : 0.34), style: FillStyle(eoFill: true))

                if let r {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.lime, lineWidth: 2)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                    if model.frozen == nil {
                        Text("\(Int(r.width)) × \(Int(r.height))")
                            .font(.awanMono(11, .semibold)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 7).frame(height: 20)
                            .background(Capsule().fill(Theme.lime))
                            .offset(x: r.minX, y: max(4, r.minY - 26))
                    }
                }
                if !model.locked {
                    hint
                        .frame(width: geo.size.width)
                        .offset(y: 64)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var hint: some View {
        HStack(spacing: 8) {
            Image(systemName: model.frozen == nil ? "viewfinder" : "hand.point.down.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.lime)
            Text(model.frozen == nil ? "Drag a box around anything" : "Pick what to do with it").font(.awan(13, .semibold)).foregroundStyle(Theme.text)
            Text("·").foregroundStyle(Theme.textTertiary)
            Text("Esc or right-click to cancel").font(.awan(12.5)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16).frame(height: 36)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
    }
}
