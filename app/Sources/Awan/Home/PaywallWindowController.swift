import AppKit
import Combine
import SwiftUI

/// The paywall is its own window centred on the screen, like the reference (a 560×541 window; the Home
/// closes when it opens). It follows `AppState.paywall`: set → show, nil → hide.
@MainActor
final class PaywallWindowController {
    static let shared = PaywallWindowController()

    /// Transparent room around the card for its shadow.
    private static let margin: CGFloat = 48
    private var panel: HomePanel?
    private var cancellables = Set<AnyCancellable>()

    func install() {
        AppState.shared.$paywall
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] source in
                if let source { self?.show(source) } else { self?.hide() }
            }
            .store(in: &cancellables)
    }

    private func show(_ source: PaywallSource) {
        if AppState.shared.isHomeOpen && !Prefs.shared.homeDetached { AppState.shared.closeHome() }
        let root = PaywallView(source: source)
            .environmentObject(AppState.shared)
            .padding(Self.margin)
            .fixedSize()
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        let size = host.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        let p = panel ?? HomePanel(contentRect: frame)
        p.level = .statusBar + 1
        p.contentView = host
        p.setFrame(frame, display: true)
        panel = p
        p.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        SpaceFollower.bringToActiveSpace(p)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                if AppState.shared.paywall == nil { p.orderOut(nil) }
            }
        })
    }
}
