import AppKit
import SwiftUI

/// Snapshot registrations for the notch container and quick peek, drawn on the #808080 backdrop the reference
/// captures use so the two can be measured like for like. Names are prefixed "notch-".
/// `notch-selftest` runs the pure layout checks and exits (0 = all passed).
extension Snapshots {
    static var notchNames: [String] {
        ["notch-rest", "notch-panel", "notch-peek-exact", "notch-peek-hover", "notch-peek-shortcuts", "notch-home-detached", "notch-peek-bare", "notch-selftest"]
    }

    static func notch(_ name: String) -> AnyView? {
        guard notchNames.contains(name) else { return nil }
        if name == "notch-selftest" { NotchSelfTest.run() }
        let s = AppState.shared
        let n = NotchController.shared
        ExtrasDemo.install()   // gives Ship Lab a file pile
        func root(_ mode: NotchMode) -> AnyView {
            n.mode = mode
            return AnyView(ZStack(alignment: .top) {
                Color(hex: 0x808080)
                NotchRootView().environmentObject(s).environmentObject(n)
            })
        }
        switch name {
        case "notch-rest":
            return root(.resting)
        case "notch-panel":
            // The whole fixed panel: the shape hangs top-centre inside it.
            return AnyView(root(.peek).frame(width: NotchController.panelSize.width, height: NotchController.panelSize.height))
        case "notch-home-detached":
            return root(.surface(.homeDetached))
        case "notch-peek-bare":
            n.mode = .peek
            return AnyView(NotchPeekView().environmentObject(s).environmentObject(n))
        case "notch-peek-exact":
            return root(.peek)
        case "notch-peek-hover":
            NotchPeekView.debugHoverRow = 1
            return root(.peek)
        case "notch-peek-shortcuts":
            NotchPeekView.debugShowShortcuts = true
            return root(.peek)
        default:
            return nil
        }
    }
}

@MainActor
enum NotchSelfTest {
    static func run() -> Never {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "  ok  " : "  FAIL ") + what)
            if !ok { failures += 1 }
        }
        let L = NotchPeekLayout.self
        check(L.size(rows: 7).height == 533, "peek: 7 rows overflow to the 533 cap (\(L.size(rows: 7).height))")
        check(L.size(rows: 20).height == 533, "peek: never taller than 533")
        check(L.size(rows: 3).height == 44 + 3 * 63 - 1 + 66, "peek: fits 3 rows (\(L.size(rows: 3).height))")
        check(L.size(rows: 3).width == 452, "peek: 452 wide")
        check(L.listHeight(rows: 7) == 423, "peek: list viewport 44→467 (\(L.listHeight(rows: 7)))")
        check(L.headerHeight + L.avatarTop == 51, "peek: first avatar top at y=51")
        check(L.leftInset + L.avatar + 14.5 == L.textX, "peek: text 14.5 after the avatar")
        check(L.width - L.shoulder - L.textRight == 31, "peek: time right edge 31 inside the body edge")
        check(ShortcutsPopover.x + ShortcutsPopover.size.width == L.width - L.shoulder - 16, "shortcuts: right edge 16 inside the body edge")
        check(L.width - PeekFilePile.rightInset == 417.5, "file card: right edge at 417.5")
        check(PeekFilePile.angle(index: 0, spread: false) == 4, "file card: newest tilted 4° clockwise")

        let n = NotchController.shared
        let g = n.geometry
        if !g.hasHardwareNotch {
            check(n.sizeFor(.resting) == CGSize(width: 60, height: 8), "rest: the shape collapses into the 60×8 handle")
        } else {
            check(n.sizeFor(.resting) == CGSize(width: g.notchWidth, height: g.menuBarHeight), "rest: hardware notch keeps the notch shape")
        }
        let r = n.shapeRect(for: .peek)
        check(abs(r.midX - g.screenFrame.midX) < 0.01 && r.maxY == g.screenFrame.maxY, "shape: centred and hanging from the top edge")
        n.mode = .resting
        check(n.interactiveRect.contains(CGPoint(x: g.hotZone.midX, y: g.hotZone.midY)), "mouse: the hot zone takes the mouse at rest")
        check(!n.interactiveRect.contains(CGPoint(x: g.screenFrame.midX + 300, y: g.screenFrame.maxY - 300)), "mouse: empty panel area passes through at rest")
        n.mode = .peek
        check(n.interactiveRect.contains(CGPoint(x: g.screenFrame.midX + 200, y: g.screenFrame.maxY - 100)), "mouse: the open peek takes the mouse")
        check(!n.interactiveRect.contains(CGPoint(x: g.screenFrame.midX + 300, y: g.screenFrame.maxY - 100)), "mouse: beside the peek passes through")
        check(n.sizeFor(.peek).width <= NotchController.panelSize.width && n.sizeFor(.peek).height <= NotchController.panelSize.height,
              "panel: the peek fits the fixed panel")
        let surfaces: [NotchSurfaceKind] = [.textResponse, .textInput, .dictation, .morningSuggestions, .agentFinished("x"), .unmuteFallback,
                                            .message("x"), .handoff, .meetingCountdown, .integrationSuggestion("x"), .appUpdated("1"), .fileDrop, .dropComposer, .homeDetached]
        check(surfaces.allSatisfy { let s = n.sizeFor(.surface($0)); return s.width <= NotchController.panelSize.width && s.height <= NotchController.panelSize.height },
              "panel: every surface fits the fixed panel")
        let keys = Set(([.resting, .activity, .peek] + surfaces.map { NotchMode.surface($0) }).map(NotchRootView.contentKey))
        check(keys.count == 3 + surfaces.count, "content: one identity per mode")
        let tiny = NotchShape(bottomRadius: 16, shoulder: 6).path(in: CGRect(x: 0, y: 0, width: 60, height: 8)).boundingRect
        check(tiny.width <= 60.01 && tiny.height <= 8.01 && tiny.height > 0, "shape: stays a simple path at the handle size")

        print(failures == 0 ? "notch-selftest: all passed" : "notch-selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
