import AppKit

/// `Awan --overlay-demo`: manual QA for the overlay on a live (unlocked) screen. Draws marks,
/// walks the buddy through three points with labels, streams a cursor bubble, then cycles the
/// voice states and records a short spatial trail.
@MainActor
enum OverlayDemo {
    static func run() {
        let overlay = CursorOverlayController.shared
        overlay.install()
        guard let screen = NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: f.minX + f.width * x, y: f.maxY - f.height * y) }

        let a = at(0.26, 0.30), b = at(0.70, 0.36), c = at(0.46, 0.70)
        Log.info("overlay demo: points \(a) \(b) \(c) on \(f)")

        overlay.onTargetHit = { label in
            Log.info("overlay demo: target hit \(label ?? "-")")
            overlay.showCursorBubble("nice, you found it ^_^")
        }
        overlay.annotate([
            .highlight(rect: CGRect(x: a.x - 120, y: a.y - 40, width: 240, height: 80), label: "the toolbar"),
            .shape(kind: .circle, points: [b, CGPoint(x: b.x + 46, y: b.y)], label: "this button", filled: false),
            .shape(kind: .arrow, points: [CGPoint(x: c.x - 230, y: c.y + 90), CGPoint(x: c.x - 120, y: c.y + 60), CGPoint(x: c.x - 20, y: c.y + 10)], label: "drag it here", filled: false),
            .target(center: at(0.84, 0.72), radius: 34, label: "click to finish", isHover: false),
        ])
        overlay.fly(to: [
            ScreenPoint(point: a, label: "start here"),
            ScreenPoint(point: b, label: "then press this"),
            ScreenPoint(point: c, label: nil),
        ])

        Task {
            try? await Task.sleep(for: .seconds(15))
            let reply = "Your welcome page is ready — I saved it in Ship Lab's workspace and opened it in Safari."
            var shown = ""
            for word in reply.split(separator: " ") {
                shown += (shown.isEmpty ? "" : " ") + word
                overlay.showCursorBubble(shown, streaming: true)
                try? await Task.sleep(for: .milliseconds(90))
            }
            overlay.showCursorBubble(reply, streaming: false)

            try? await Task.sleep(for: .seconds(4))
            overlay.setVoiceState(.listening)
            overlay.beginSpatialTrail()
            for i in 0..<60 {
                overlay.buddy.audioLevel = CGFloat(0.12 + 0.12 * sin(Double(i) / 3))
                try? await Task.sleep(for: .milliseconds(50))
            }
            let trail = overlay.endSpatialTrail()
            Log.info("overlay demo: trail \(trail.count) points")
            overlay.setVoiceState(.processing)
            try? await Task.sleep(for: .seconds(2))
            overlay.setVoiceState(.idle)
        }
    }
}
