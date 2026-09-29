import SwiftUI

/// Snapshot registrations for the overlay area. Names are prefixed "overlay-".
extension Snapshots {
    static var overlayNames: [String] { ["overlay-buddy-states", "overlay-annotations", "overlay-dock-card", "overlay-live", "overlay-live-dock",
                                         "overlay-measure-idle", "overlay-measure-label", "overlay-measure-point", "overlay-measure-voice", "overlay-measure-dock",
                                         "overlay-measure-dockcard", "overlay-selftest"] }

    static func overlay(_ name: String) -> AnyView? {
        switch name {
        case "overlay-buddy-states": return AnyView(OverlaySnapshotBuddyStates())
        case "overlay-annotations": return AnyView(OverlaySnapshotAnnotations())
        case "overlay-dock-card": return AnyView(OverlaySnapshotDockCard())
        case "overlay-measure-dock": return AnyView(OverlaySnapshotDockCard(card: false, wallpaper: false))
        case "overlay-measure-dockcard": return AnyView(OverlaySnapshotDockCard(card: true, wallpaper: false))
        case "overlay-live": return AnyView(OverlayLiveCapture.run())
        case "overlay-live-dock": return AnyView(OverlayLiveCapture.dock())
        // Geometry instruments: transparent 1408×881 canvases matching the reference captures
        //. Render at 1408 881.
        case "overlay-measure-idle": return AnyView(OverlayMeasure.canvas(pointer: CGPoint(x: 700, y: 436)))
        case "overlay-measure-label":
            return AnyView(OverlayMeasure.canvas(pointer: CGPoint(x: 456, y: 639), bubble: "(^_^)v hold control + option and i'll help you with anything"))
        case "overlay-measure-point": return AnyView(OverlayMeasure.pointLabels())
        case "overlay-measure-voice": return AnyView(OverlayMeasure.voice())
        case "overlay-selftest": return AnyView(OverlayMeasure.selfTest())
        default: return nil
        }
    }
}

// MARK: - Live capture (the real panels, mid-demo)

/// Installs the real overlay, runs `--overlay-demo`'s script, and captures the main display's
/// overlay panel at several moments — proof the windows, display-link tick and flights work,
/// even with the screen locked (offscreen caching doesn't need the window server to composite).
@MainActor
private enum OverlayLiveCapture {
    static func run() -> some View {
        let overlay = CursorOverlayController.shared
        OverlayDemo.run()
        let start = Date()
        var frames: [(String, NSImage)] = []
        for (label, t) in [("flying out · marks drawing in", 0.35), ("landed · label typing", 1.7), ("label fading · off to point 2", 6.0), ("back beside the cursor · reply bubble", 17.0)] {
            // Pumping the run loop before NSApp.run: nudge the main queue so main-actor
            // continuations (the demo's Task.sleep steps) keep draining between captures.
            DispatchQueue.main.async {}
            while Date().timeIntervalSince(start) < t {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            if let panel = overlay.panels.first, let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let image = NSImage(size: view.bounds.size)
                image.addRepresentation(rep)
                frames.append((label, image))
            }
        }
        let size = overlay.panels.first?.frame.size ?? CGSize(width: 1440, height: 900)
        return LiveGrid(frames: frames, aspect: size.width / max(size.height, 1))
    }

    /// Docked mode with the real panels: pill, expanded stack, Ship Lab's card, and the buddy
    /// flying out of the pill. Composited at their true frames (top-right of the main display).
    /// Docked is applied directly (not through Prefs) so nothing is persisted.
    static func dock() -> some View {
        let overlay = CursorOverlayController.shared
        overlay.install()
        overlay.applyDocked(true)
        overlay.dock.toggleExpanded()
        pump(0.4)
        overlay.dock.showCard("ship-lab")
        pump(1.0)
        let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let region = CGRect(x: screen.maxX - 460, y: screen.maxY - 520, width: 460, height: 520)
        let still = composite(overlay, region: region)
        overlay.dock.hideCard()
        overlay.fly(to: [ScreenPoint(point: CGPoint(x: screen.maxX - 300, y: screen.maxY - 380), label: "from the dock")])
        pump(0.45)
        let flying = composite(overlay, region: region)
        pump(2.2)
        let landed = composite(overlay, region: region)
        return HStack(alignment: .top, spacing: 14) {
            ForEach(Array([("docked · card open", still), ("flying out of the pill", flying), ("pointing", landed)].enumerated()), id: \.offset) { _, f in
                VStack(alignment: .leading, spacing: 6) {
                    Image(nsImage: f.1)
                        .background(LinearGradient(colors: [Color(hex: 0x3B2A6B), Color(hex: 0x8E7BD0)], startPoint: .top, endPoint: .bottom))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(f.0).font(.awan(12, .semibold)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.window)
    }

    private static func pump(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        DispatchQueue.main.async {}
        while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    /// Draws the overlay panel and the dock panels that intersect `region` into one image.
    private static func composite(_ overlay: CursorOverlayController, region: CGRect) -> NSImage {
        let image = NSImage(size: region.size)
        image.lockFocus()
        for panel in overlay.panels + overlay.dock.visiblePanels {
            guard let view = panel.contentView, panel.frame.intersects(region),
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let origin = CGPoint(x: panel.frame.minX - region.minX, y: panel.frame.minY - region.minY)
            rep.draw(in: CGRect(origin: origin, size: panel.frame.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        image.unlockFocus()
        return image
    }

    struct LiveGrid: View {
        let frames: [(String, NSImage)]
        let aspect: CGFloat

        var body: some View {
            let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                    VStack(alignment: .leading, spacing: 6) {
                        Image(nsImage: frame.1)
                            .resizable()
                            .aspectRatio(aspect, contentMode: .fit)
                            .background(LinearGradient(colors: [Color(hex: 0x3A3F52), Color(hex: 0x8E8AA8)], startPoint: .top, endPoint: .bottom))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(frame.0).font(.awan(12, .semibold)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.window)
        }
    }
}

// MARK: - Buddy states strip

/// The macOS arrow pointer, drawn so the buddy has something to sit beside.
private struct SystemPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let pts: [CGPoint] = [(0, 0), (0, 16.5), (4.2, 12.6), (7.1, 19.2), (9.7, 18.1), (6.9, 11.7), (12.3, 11.7)].map { CGPoint(x: $0.0, y: $0.1) }
        var p = Path()
        p.addLines(pts.map { CGPoint(x: rect.minX + $0.x, y: rect.minY + $0.y) })
        p.closeSubpath()
        return p
    }
}

private struct SystemPointer: View {
    var body: some View {
        ZStack {
            SystemPointerShape().fill(Color.black)
            SystemPointerShape().stroke(Color.white, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
        }
        .frame(width: 13, height: 20, alignment: .topLeading)
        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
    }
}

private struct OverlaySnapshotBuddyStates: View {
    private let lime = CursorColor.lime.color
    private let off = CGPoint(x: CursorOverlayController.followOffset.dx, y: -CursorOverlayController.followOffset.dy)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Cursor buddy").font(.awan(15, .semibold)).foregroundStyle(Theme.text)
                Text("follows the pointer · Signal Lime · equilateral, solid fill + soft glow").font(.awan(12)).foregroundStyle(Theme.textTertiary)
            }
            row(dark: false)
            row(dark: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.window)
    }

    private func row(dark: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            cell("Idle", dark: dark) { following(.idle) }
            cell("Listening", dark: dark) { following(.listening, level: 0.22) }
            cell("Processing", dark: dark) { following(.processing) }
            cell("Flying", dark: dark) { flying }
            cell("Pointing", dark: dark) { pointing(dark: dark) }
            cell("Responding", width: 400, dark: dark) { responding }
        }
    }

    private func cell<C: View>(_ title: String, width: CGFloat = 150, dark: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) { content() }
                .frame(width: width, height: 132, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dark ? Theme.graphite : Theme.bone))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(title).font(.awan(12, .semibold)).foregroundStyle(Theme.textSecondary)
        }
    }

    private func following(_ state: VoiceState, level: CGFloat = 0) -> some View {
        let pointer = CGPoint(x: 52, y: 44)
        return ZStack(alignment: .topLeading) {
            SystemPointer().position(x: pointer.x + 6.5, y: pointer.y + 10)
            BuddyGlyph(state: state, color: lime, audioLevel: level, animated: false)
                .position(x: pointer.x + off.x, y: pointer.y + off.y)
        }
    }

    private var flying: some View {
        ZStack(alignment: .topLeading) {
            // The arc it's travelling along, for reading the frame.
            Path { p in
                p.move(to: CGPoint(x: 18, y: 112))
                p.addQuadCurve(to: CGPoint(x: 134, y: 80), control: CGPoint(x: 70, y: 20))
            }
            .stroke(lime.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5]))
            BuddyGlyph(state: .idle, color: lime, audioLevel: 0, rotation: 72, scale: 1.3, animated: false)
                .position(x: 76, y: 52)
        }
    }

    private func pointing(dark: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Text("Export")
                .font(.awan(12, .semibold))
                .foregroundStyle(dark ? Theme.text : Theme.ink)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(dark ? Color.white.opacity(0.1) : Color.black.opacity(0.07)))
                .position(x: 46, y: 40)
            BuddyGlyph(state: .idle, color: lime, audioLevel: 0, animated: false)
                .position(x: 54 + 8, y: 40 + 12)
            PointLabelBubble(text: "this one!", color: lime)
                .pinned(at: CGPoint(x: 62 + PointLabelBubble.offset.dx, y: 52 + PointLabelBubble.offset.dy))
        }
    }

    private var responding: some View {
        let pointer = CGPoint(x: 30, y: 22)
        return ZStack(alignment: .topLeading) {
            SystemPointer().position(x: pointer.x + 6.5, y: pointer.y + 10)
            BuddyGlyph(state: .responding, color: lime, audioLevel: 0, animated: false)
                .position(x: pointer.x + off.x, y: pointer.y + off.y)
            CursorTextBubble(text: "Export lives top right — click it, then pick PDF. I'll wait right here while you do it, then we can export the rest.", streaming: true, accent: lime)
                .pinned(at: CGPoint(x: pointer.x + off.x + CursorTextBubble.offset.dx, y: pointer.y + off.y + CursorTextBubble.offset.dy))
        }
    }
}

// MARK: - Annotations

private struct OverlaySnapshotAnnotations: View {
    private static let size = CGSize(width: 880, height: 560)
    private var size: CGSize { Self.size }
    private let marks = Self.makeMarks()
    private let trail = Self.makeTrail()
    private let buddy = Self.makeBuddy()

    var body: some View {
        let frame = CGRect(origin: .zero, size: size)
        let map = OverlayMapper(frame: frame)
        ZStack(alignment: .topLeading) {
            Theme.window
            mockWindow
            AnnotationLayer(map: map, model: marks)
            TrailLayer(map: map, model: trail)
            BuddyLayer(map: map, model: buddy)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Canvas point (top-left origin) → global AppKit point for this frame.
    private static func g(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: size.height - y) }

    private static func makeMarks() -> AnnotationModel {
        let m = AnnotationModel()
        m.animated = false
        m.color = CursorColor.lime.color
        m.items = [
            LiveAnnotation(.highlight(rect: CGRect(x: 78, y: size.height - 64 - 44, width: 318, height: 44), label: "Formatting toolbar"), seed: 11),
            LiveAnnotation(.shape(kind: .circle, points: [g(718, 86), g(752, 86)], label: nil, filled: false), seed: 23),
            LiveAnnotation(.shape(kind: .arrow, points: [g(300, 390), g(450, 380), g(530, 280)], label: "drag the file here", filled: false), seed: 37),
            LiveAnnotation(.target(center: g(610, 468), radius: 30, label: "Click Save to finish", isHover: false), seed: 41),
            LiveAnnotation(.shape(kind: .polygon, points: [g(560, 200), g(700, 190), g(716, 300), g(574, 318)], label: "preview area", filled: true), seed: 53),
        ]
        return m
    }

    private static func makeTrail() -> TrailModel {
        let t = TrailModel()
        t.color = CursorColor.lime.color
        // A quick scribble around the sidebar's second item, as a user would while talking.
        t.points = stride(from: 0.0, through: 5.6, by: 0.18).map { a in
            let r = 34 + 5 * sin(a * 2.3)
            return g(170 + CGFloat(cos(a) * r * 1.6), 250 + CGFloat(sin(a) * r * 0.8))
        }
        return t
    }

    private static func makeBuddy() -> BuddyModel {
        let b = BuddyModel()
        b.color = CursorColor.lime.color
        b.position = g(760 + 8, 86 + 14)
        b.pointLabel = "this one!"
        b.pointLabelVisible = true
        return b
    }

    private var mockWindow: some View {
        let bar = Color.white.opacity(0.08)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.graphite)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .frame(width: 780, height: 480)
                .position(x: 60 + 390, y: 40 + 240)
            HStack(spacing: 7) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 11, height: 11) }
            }
            .position(x: 110, y: 58)
            HStack(spacing: 8) {
                ForEach(["B", "I", "U", "H1", "H2", "•", "1.", "❝"], id: \.self) { t in
                    Text(t).font(.awan(12, .semibold)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 26).background(RoundedRectangle(cornerRadius: 6).fill(bar))
                }
            }
            .position(x: 237, y: 86)
            Text("Export").font(.awan(12.5, .semibold)).foregroundStyle(Theme.text)
                .padding(.horizontal, 12).frame(height: 28).background(Capsule().fill(Color.white.opacity(0.12)))
                .position(x: 718, y: 86)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<6, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4).fill(i == 2 ? Color.white.opacity(0.18) : bar).frame(width: 150, height: 14)
                }
            }
            .position(x: 160, y: 250)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<9, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4).fill(bar).frame(width: [300, 260, 320, 280, 180, 300, 240, 310, 200][i], height: 11)
                }
            }
            .position(x: 420, y: 250)
            Text("Save").font(.awan(12.5, .semibold)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 16).frame(height: 28).background(Capsule().fill(Theme.bone))
                .position(x: 610, y: 468)
        }
    }
}

// MARK: - Dock card

/// The docked stack laid out exactly as `DockController` places its panels, measured from the
/// canvas's top-right corner (a screen's top-right below the menu bar): chevron pill, portraits,
/// and optionally the hover card grown out of Ship Lab's portrait. `wallpaper: false` renders on
/// transparent for comparing with the reference captures / dock-hovercard-win.png
/// (render at 1408 851: the reference windows start at screen y = 30).
private struct OverlaySnapshotDockCard: View {
    var card = true
    var wallpaper = true
    private let dock = DockController()

    var body: some View {
        let slug = "ship-lab"
        let cardH = card ? Self.cardHeight(slug) : 0
        dock.expanded = true
        dock.refreshStack()
        dock.setPreviewCard(card ? slug : nil, contentHeight: cardH)
        let index = CGFloat(dock.stackSlugs.firstIndex(of: slug) ?? 0)
        return GeometryReader { g in
            let pill = CGRect(x: g.size.width - DockController.pillRightInset - DockController.pillSize.width,
                              y: DockController.pillTopInset, width: DockController.pillSize.width, height: DockController.pillSize.height)
            let stackTop = pill.maxY + DockController.stackTopGap
            ZStack(alignment: .topLeading) {
                if wallpaper { backdrop }
                DockPillView(dock: dock).pinned(at: CGPoint(x: pill.midX, y: pill.minY), .top)
                DockStackView(dock: dock).pinned(at: CGPoint(x: pill.midX, y: stackTop), .top)
                if card {
                    AgentHoverCard(slug: slug)
                        .pinned(at: CGPoint(x: pill.maxX, y: stackTop + index * (DockController.bubbleSize + DockController.bubbleGap)), .topTrailing)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
    }

    /// The card's laid-out height, as its panel would report it.
    static func cardHeight(_ slug: String) -> CGFloat {
        let host = NSHostingView(rootView: AgentHoverCard(slug: slug).fixedSize())
        return host.fittingSize.height
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x3B2A6B), Color(hex: 0x6E4FD0), Color(hex: 0xB79AE8)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Radial gradients rather than blur: offscreen caching doesn't render blur filters.
            RadialGradient(colors: [Color(hex: 0x9FE3C9).opacity(0.6), .clear], center: UnitPoint(x: 0.1, y: 0.85), startRadius: 0, endRadius: 260)
            RadialGradient(colors: [Color(hex: 0xF3A6D8).opacity(0.55), .clear], center: UnitPoint(x: 0.95, y: 0.15), startRadius: 0, endRadius: 240)
        }
    }
}

// MARK: - Measurement canvases + motion self-test

/// Draws the real `BuddyLayer` on a transparent, screen-sized canvas so the render can be compared
/// numerically with the reference's alpha captures (same 1408×881 pt screen, pointer at a known point).
@MainActor
enum OverlayMeasure {
    static let screen = CGRect(x: 0, y: 0, width: 1408, height: 881)
    nonisolated static let blue = Color(hex: 0x3380FF)

    /// `pointer` in screen coordinates (top-left origin, y down), as the reference numbers are.
    static func model(pointer: CGPoint, color: Color = blue) -> BuddyModel {
        let b = BuddyModel()
        b.color = color
        let appKit = CGPoint(x: pointer.x, y: screen.height - pointer.y)
        b.position = CGPoint(x: appKit.x + CursorOverlayController.followOffset.dx, y: appKit.y + CursorOverlayController.followOffset.dy)
        return b
    }

    static func canvas(pointer: CGPoint, bubble: String? = nil, color: Color = blue) -> some View {
        let b = model(pointer: pointer, color: color)
        if let bubble {
            b.bubbleText = bubble
            b.bubbleAnchor = b.position
        }
        return BuddyLayer(map: OverlayMapper(frame: screen), model: b)
            .frame(width: screen.width, height: screen.height, alignment: .topLeading)
    }

    /// Point labels at three typing stages ("m", "menu", "menu bar") with the buddy at rest,
    /// stacked 100 pt apart from (700, 200) — compare with ptt/f0768, f0772, f0777.
    static func pointLabels() -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(["m", "menu", "menu bar", "menu bar clock"].enumerated()), id: \.offset) { i, text in
                let b = model(pointer: CGPoint(x: 700 - 34.8, y: 200 + CGFloat(i) * 100 - 24.8))
                let _ = { b.pointLabel = text; b.pointLabelVisible = true }()
                BuddyLayer(map: OverlayMapper(frame: screen), model: b)
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
    }

    /// Listening bars (mid level) and the thinking spinner at the resting point of pointers (700,436) / (900,436).
    static func voice() -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array([(VoiceState.listening, CGFloat(0.2)), (.processing, 0)].enumerated()), id: \.offset) { i, s in
                let b = model(pointer: CGPoint(x: 700 + CGFloat(i) * 200, y: 436))
                BuddyGlyph(state: s.0, color: blue, audioLevel: s.1, animated: false)
                    .position(OverlayMapper(frame: screen).local(b.position))
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
    }

    /// Follow spring against the reference fit (response 0.20 s, damping 0.62): a simulated 500 pt
    /// step must overshoot 6–10 % and peak in 100–140 ms. Prints PASS/FAIL lines; renders the curve.
    static func selfTest() -> some View {
        var lines: [String] = []
        var ok = true
        func check(_ cond: Bool, _ msg: String) { ok = ok && cond; lines.append("\(cond ? "PASS" : "FAIL")  \(msg)") }
        for fps in [60.0, 120.0] {
            let r = CursorOverlayController.simulateFollowStep(distance: 500, fps: fps)
            check((0.06...0.10).contains(r.overshoot), String(format: "%.0f fps: overshoot %.1f%% (ref ≈8%%)", fps, r.overshoot * 100))
            check((0.100...0.140).contains(r.peak), String(format: "%.0f fps: time to peak %.0f ms (ref 100–130)", fps, r.peak * 1000))
            check(r.settle < 0.42, String(format: "%.0f fps: settled within 1 pt at %.0f ms (ref ≈300)", fps, r.settle * 1000))
        }
        let off = CursorOverlayController.followOffset
        check(abs(off.dx - 34.8) < 0.01 && abs(off.dy + 24.8) < 0.01, "follow offset (+34.8, +24.8) screen / (34.8, −24.8) AppKit")
        let tri = BuddyTriangleShape().path(in: CGRect(x: -10, y: -10, width: 20, height: 20)).boundingRect
        // Tip up: top tip 7.7 pt above the centroid, flat edge 4.65 pt below → 12.35 pt tall.
        check(abs(tri.minY + 7.7) < 0.15 && abs(tri.maxY - 4.65) < 0.15,
              String(format: "triangle tip %.2f pt / edge %.2f pt from centroid (ref 7.7 / 4.6), bbox %.2f × %.2f", -tri.minY, tri.maxY, tri.width, tri.height))
        check(BuddyModel.restRotation == -36, "rest rotation −36° (tip right, 6° up)")
        lines.append(ok ? "ALL PASS" : "SOME CHECKS FAILED")
        for l in lines { print("overlay-selftest: \(l)") }

        // The curve, for eyeballing the overshoot.
        var p = CGPoint.zero, v = CGVector.zero
        var pts: [CGPoint] = [.zero]
        for i in 1...36 {
            CursorOverlayController.springStep(position: &p, velocity: &v, target: CGPoint(x: 500, y: 0), dt: 1 / 60)
            pts.append(CGPoint(x: Double(i) / 60, y: Double(p.x)))
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Follow spring — 500 pt step, 60 fps").font(.awan(14, .semibold)).foregroundStyle(Theme.text)
            Canvas { ctx, size in
                func map(_ q: CGPoint) -> CGPoint { CGPoint(x: 20 + q.x / 0.6 * (size.width - 40), y: size.height - 20 - q.y / 560 * (size.height - 40)) }
                var target = Path(); target.move(to: map(CGPoint(x: 0, y: 500))); target.addLine(to: map(CGPoint(x: 0.6, y: 500)))
                ctx.stroke(target, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                var curve = Path(); curve.addLines(pts.map(map))
                ctx.stroke(curve, with: .color(blue), lineWidth: 2)
            }
            .frame(height: 220)
            ForEach(lines, id: \.self) { Text($0).font(.awanMono(11)).foregroundStyle($0.hasPrefix("FAIL") ? Color(hex: 0xFF6B5E) : Theme.textSecondary) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.window)
    }
}
