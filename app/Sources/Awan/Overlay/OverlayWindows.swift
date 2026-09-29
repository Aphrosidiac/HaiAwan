// Adapted from farzaa/clicky (MIT) — one transparent click-through overlay window per display.
import AppKit
import QuartzCore
import SwiftUI

extension NSWindow.Level {
    /// Above normal and floating windows, below the notch panel (`.statusBar + 2`).
    static let awanOverlay = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
}

/// Full-screen, borderless, transparent, click-through, all-Spaces panel for one display.
final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .awanOverlay
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Small interactive panel for the docked pill, the agent bubble stack and the hover card.
/// Only these accept mouse events — and only where they draw.
final class DockPanel: NSPanel {
    private let allowsKey: Bool

    init(allowsKey: Bool) {
        self.allowsKey = allowsKey
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .awanOverlay
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Clicks land on the hosted SwiftUI even when the panel isn't key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Display-synced 60 fps tick (CADisplayLink from the main screen; a timer as fallback).
/// Pauses itself when nothing moves; any mouse movement restarts it.
@MainActor
final class DisplayTicker: NSObject {
    private var link: CADisplayLink?
    private var timer: Timer?
    private let onTick: (CFTimeInterval) -> Void

    init(onTick: @escaping (CFTimeInterval) -> Void) {
        self.onTick = onTick
    }

    var isRunning: Bool { link != nil || timer != nil }

    func start() {
        guard !isRunning else { return }
        if let screen = NSScreen.main {
            let l = screen.displayLink(target: self, selector: #selector(fire(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.onTick(CACurrentMediaTime()) }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }

    @objc private func fire(_ link: CADisplayLink) {
        onTick(CACurrentMediaTime())
    }
}
