// Flight numbers adapted from farzaa/clicky (MIT): quadratic bezier arc raised by min(d·0.2, 80),
// duration clamp(d/800, 0.6…1.4 s), smoothstep easing, tangent rotation, 1.3× mid-flight swell,
// typed label (30–60 ms/char), ~3 s hold, return flight cancelled by a 100 pt mouse move.
import AppKit
import Combine
import QuartzCore
import SwiftUI

/// What the buddy is doing right now.
enum BuddyMotion {
    case following
    case flight(BuddyFlight)
    case pointing
}

struct BuddyFlight {
    var start: CGPoint
    var end: CGPoint
    var began: CFTimeInterval
    var duration: Double
    var label: String?
    var returning: Bool
    /// Reduce Motion: fade out here, fade in there, no arc.
    var fade: Bool
    /// Docked mode: the buddy materialises out of the dock pill and dissolves back into it.
    var fadeIn: Bool
    var fadeOut: Bool
    var mouseAtStart: CGPoint

    var arcControl: CGPoint {
        let d = hypot(end.x - start.x, end.y - start.y)
        // AppKit y is up, so "raised" is +y.
        return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + min(d * 0.2, 80))
    }
}

extension CursorOverlayController {
    /// Where the buddy's centroid rests relative to the pointer tip (AppKit, y up): the reference's
    /// (+34.8, +24.8) pt in screen coordinates, i.e. below and to the right.
    static let followOffset = CGVector(dx: 34.8, dy: -24.8)
    /// Follow spring, fitted on the reference (SwiftUI response 0.20 s, dampingFraction 0.62):
    /// k = (2π / response)², c = 2·ζ·√k → ≈8.4% overshoot, peak ≈128 ms, settled ≈300 ms.
    static let followStiffness = pow(2 * Double.pi / 0.20, 2)
    static let followDamping = 2 * 0.62 * sqrt(followStiffness)

    /// One step of the follow spring, solved exactly (closed-form under-damped oscillator toward a
    /// fixed target), so the overshoot and timing are the same at 60 or 120 Hz — an Euler step at
    /// 60 Hz with ω·dt ≈ 0.5 damps the 8% overshoot down to ≈2%. Shared by the tick and the self-test.
    static func springStep(position p: inout CGPoint, velocity v: inout CGVector, target: CGPoint, dt: Double) {
        let k = followStiffness, c = followDamping
        let wn = sqrt(k), zeta = c / (2 * wn), wd = wn * sqrt(1 - zeta * zeta)
        let decay = exp(-zeta * wn * dt), cw = cos(wd * dt), sw = sin(wd * dt)
        func axis(_ x0: Double, _ v0: Double) -> (Double, Double) {
            let b = (v0 + zeta * wn * x0) / wd
            let x = decay * (x0 * cw + b * sw)
            let vel = decay * ((b * wd - zeta * wn * x0) * cw - (x0 * wd + zeta * wn * b) * sw)
            return (x, vel)
        }
        let (x, vx) = axis(Double(p.x - target.x), Double(v.dx))
        let (y, vy) = axis(Double(p.y - target.y), Double(v.dy))
        p = CGPoint(x: target.x + CGFloat(x), y: target.y + CGFloat(y))
        v = CGVector(dx: vx, dy: vy)
    }

    /// Simulates a `distance` pt step at `fps`: (overshoot fraction, time to peak s, time to settle within 1 pt s).
    static func simulateFollowStep(distance: Double = 500, fps: Double = 60) -> (overshoot: Double, peak: Double, settle: Double) {
        var p = CGPoint.zero, v = CGVector.zero
        let target = CGPoint(x: distance, y: 0)
        var peak = 0.0, peakT = 0.0, settleT = 0.0
        let dt = 1 / fps
        for i in 1...Int(fps * 2) {
            springStep(position: &p, velocity: &v, target: target, dt: dt)
            let t = Double(i) * dt
            if Double(p.x) > peak { peak = Double(p.x); peakT = t }
            if abs(Double(p.x) - distance) > 1 { settleT = t + dt }
        }
        return ((peak - distance) / distance, peakT, settleT)
    }
    /// Awan's own pointing phrases (used when a [POINT] has no label).
    static let pointerPhrases = ["this one!", "look here", "right about here", "this bit ^_^", "ta-da, here", "spotted it"]

    static func readingTime(_ text: String) -> Double {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return min(14, max(3.5, 1.8 + Double(words) * 0.28))
    }

    // MARK: - Windows, monitors, observers

    func rebuildPanels() {
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        let show = Prefs.shared.showInScreenRecordings
        panels = NSScreen.screens.map { screen in
            let panel = OverlayPanel(screen: screen)
            let host = NSHostingView(rootView: OverlayCanvas(frame: screen.frame, buddy: buddy, marks: marks, trail: trail))
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: screen.frame.size)
            panel.contentView = host
            panel.sharingType = show ? .readOnly : .none
            panel.orderFrontRegardless()
            return panel
        }
        dock.screensChanged()
        // The display link belongs to a screen; re-create it against the current main screen.
        ticker.stop()
        lastTick = 0
        ensureTicking()
    }

    func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.ensureTicking() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.ensureTicking() }
            return event
        }) { monitors.append(m) }
        // [TARGET] click detection: clicks go to whatever app is underneath (the overlay is
        // click-through), so watch them globally, and locally for clicks on Awan's own windows.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseDown() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseDown() }
            return event
        }) { monitors.append(m) }
    }

    func observeSystem() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildPanels() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self?.reduceMotion = reduce
                self?.marks.reduceMotion = reduce
            }
            .store(in: &cancellables)
        marks.reduceMotion = reduceMotion

        let prefs = Prefs.shared
        prefs.$cursorColor.removeDuplicates().sink { [weak self] in self?.applyColor($0) }.store(in: &cancellables)
        prefs.$cursorDocked.removeDuplicates().sink { [weak self] in self?.applyDocked($0) }.store(in: &cancellables)
        prefs.$showInScreenRecordings.removeDuplicates().sink { [weak self] in self?.applySharing($0) }.store(in: &cancellables)
        prefs.$catMode.removeDuplicates().sink { [weak self] on in self?.buddy.catMode = on; self?.ensureTicking() }.store(in: &cancellables)

        let companion = CompanionEngine.shared
        companion.$voiceState.removeDuplicates().sink { [weak self] in self?.setVoiceState($0) }.store(in: &cancellables)
        companion.$audioLevel.sink { [weak self] level in
            guard let self, self.buddy.voiceState == .listening else { return }
            self.buddy.audioLevel = CGFloat(level)
        }.store(in: &cancellables)
    }

    func applyColor(_ choice: CursorColor) {
        buddy.color = choice.color
        marks.color = choice.color
        trail.color = choice.color
    }

    func applyDocked(_ on: Bool) {
        docked = on
        guard installed else { return }
        dock.setDocked(on)
        if case .following = motion {
            if on {
                buddy.visible = false
            } else {
                buddy.position = homePoint(mouse: NSEvent.mouseLocation)
                buddy.opacity = 1
                buddy.visible = true
                velocity = .zero
            }
        }
        ensureTicking()
    }

    func applySharing(_ show: Bool) {
        for panel in panels { panel.sharingType = show ? .readOnly : .none }
        dock.setSharing(show)
    }

    func ensureTicking() {
        guard installed else { return }
        busyUntil = max(busyUntil, CACurrentMediaTime() + 0.35)
        ticker.start()
    }

    func homePoint(mouse: CGPoint) -> CGPoint {
        if docked { return dock.anchor }
        return CGPoint(x: mouse.x + Self.followOffset.dx, y: mouse.y + Self.followOffset.dy)
    }

    func bubbleAnchorPoint(mouse: CGPoint) -> CGPoint {
        if buddy.visible && buddy.opacity > 0.5 { return buddy.position }
        return CGPoint(x: mouse.x + Self.followOffset.dx, y: mouse.y + Self.followOffset.dy)
    }

    // MARK: - Tick

    func tick(_ now: CFTimeInterval) {
        let dt = lastTick == 0 ? 1.0 / 60.0 : min(max(now - lastTick, 1.0 / 240.0), 1.0 / 20.0)
        lastTick = now
        let mouse = NSEvent.mouseLocation
        var busy = false

        switch motion {
        case .following:
            if docked {
                if buddy.visible { buddy.visible = false }
            } else {
                busy = stepSpring(toward: homePoint(mouse: mouse), dt: dt)
            }
        case .flight(var f):
            busy = true
            if f.returning {
                f.end = homePoint(mouse: mouse)
                if !docked, hypot(mouse.x - f.mouseAtStart.x, mouse.y - f.mouseAtStart.y) > 100 {
                    // The user moved on mid-return: the follow spring takes over from here.
                    finishReturn()
                    break
                }
            }
            let raw = min(1, (now - f.began) / f.duration)
            applyFlightFrame(f, raw: raw)
            if raw >= 1 { completeFlight(f) } else { motion = .flight(f) }
        case .pointing:
            break
        }
        if buddy.catMode { updateCatPose() }

        if trailRecording && penDown {
            appendTrail(mouse)
            busy = true
        }
        if marks.items.contains(where: { isHoverTarget($0) }) {
            checkHover(mouse, now)
            busy = true
        }
        if buddy.bubbleText != nil {
            let a = bubbleAnchorPoint(mouse: mouse)
            if a != buddy.bubbleAnchor { buddy.bubbleAnchor = a }
            busy = true
        }
        if !busy && now > busyUntil {
            ticker.stop()
            lastTick = 0
        }
    }

    /// Cat Mode: walk while following fast or flying (facing the way it goes), sit once it has landed.
    private func updateCatPose() {
        var pose: CatPose = .idle
        var left = buddy.catFacingLeft
        switch motion {
        case .following:
            let speed = hypot(velocity.dx, velocity.dy)
            if speed > 28 { pose = .walk }
            if abs(velocity.dx) > 18 { left = velocity.dx < 0 }
        case .flight(let f):
            pose = .walk
            if abs(f.end.x - f.start.x) > 4 { left = f.end.x < f.start.x }
        case .pointing:
            pose = .sit
        }
        if buddy.catPose != pose { buddy.catPose = pose }
        if buddy.catFacingLeft != left { buddy.catFacingLeft = left }
    }

    /// Springy follow (slightly under-damped) toward the pointer offset. Returns true while moving.
    private func stepSpring(toward target: CGPoint, dt: Double) -> Bool {
        var p = buddy.position
        let dx = Double(target.x - p.x), dy = Double(target.y - p.y)
        Self.springStep(position: &p, velocity: &velocity, target: target, dt: dt)
        let settled = hypot(dx, dy) < 0.3 && hypot(velocity.dx, velocity.dy) < 3
        if settled {
            p = target
            velocity = .zero
        }
        if p != buddy.position { buddy.position = p }
        // The reference keeps its orientation while following (no lean).
        if buddy.rotation != BuddyModel.restRotation { buddy.rotation = BuddyModel.restRotation }
        if buddy.scale != 1 { buddy.scale = 1 }
        if buddy.opacity != 1 { buddy.opacity = 1 }
        if !buddy.visible { buddy.visible = true }
        return !settled
    }

    private func applyFlightFrame(_ f: BuddyFlight, raw: Double) {
        if f.fade {
            buddy.position = raw < 0.5 ? f.start : f.end
            buddy.opacity = raw < 0.5 ? 1 - raw * 2 : (raw - 0.5) * 2
            buddy.rotation = BuddyModel.restRotation
            buddy.scale = 1
            if f.fadeOut && raw >= 0.5 { buddy.opacity = 0 }
            return
        }
        let t = raw * raw * (3 - 2 * raw)
        let u = 1 - t
        let c = f.arcControl
        buddy.position = CGPoint(
            x: CGFloat(u * u) * f.start.x + CGFloat(2 * u * t) * c.x + CGFloat(t * t) * f.end.x,
            y: CGFloat(u * u) * f.start.y + CGFloat(2 * u * t) * c.y + CGFloat(t * t) * f.end.y
        )
        let tx = CGFloat(2 * u) * (c.x - f.start.x) + CGFloat(2 * t) * (f.end.x - c.x)
        let ty = CGFloat(2 * u) * (c.y - f.start.y) + CGFloat(2 * t) * (f.end.y - c.y)
        if hypot(tx, ty) > 0.5 {
            // The canvas is y-down, so flip y; +90° because the triangle's tip points up at 0°.
            buddy.rotation = Double(atan2(-ty, tx)) * 180 / .pi + 90
        }
        buddy.scale = 1 + 0.3 * CGFloat(sin(raw * .pi))
        var opacity = 1.0
        if f.fadeIn { opacity = min(opacity, raw * 5) }
        if f.fadeOut { opacity = min(opacity, (1 - raw) * 5) }
        buddy.opacity = opacity
    }

    private func completeFlight(_ f: BuddyFlight) {
        buddy.position = f.end
        if f.returning {
            finishReturn()
        } else {
            buddy.opacity = 1
            land(label: f.label)
        }
    }

    // MARK: - Pointing flights

    func beginFlights(_ points: [ScreenPoint]) {
        flightGeneration += 1
        flightQueue = points
        buddy.pointLabelVisible = false
        buddy.pointLabel = ""
        if docked, !buddy.visible || buddy.opacity < 0.5 {
            buddy.position = dock.anchor
            buddy.opacity = 0
            buddy.visible = true
        }
        flyToNext()
    }

    private func flyToNext() {
        guard !flightQueue.isEmpty else {
            startFlight(to: homePoint(mouse: NSEvent.mouseLocation), label: nil, returning: true)
            return
        }
        let target = flightQueue.removeFirst()
        // Sit just below-right of the element so the tip points at it (not on top of it).
        var dest = CGPoint(x: target.point.x + 8, y: target.point.y - 12)
        let screen = NSScreen.screens.first { $0.frame.contains(target.point) } ?? NSScreen.main
        if let bounds = screen?.frame.insetBy(dx: 20, dy: 20) {
            dest.x = min(max(dest.x, bounds.minX), bounds.maxX)
            dest.y = min(max(dest.y, bounds.minY), bounds.maxY)
        }
        startFlight(to: dest, label: target.label, returning: false)
    }

    private func startFlight(to end: CGPoint, label: String?, returning: Bool) {
        let start = buddy.position
        let distance = hypot(end.x - start.x, end.y - start.y)
        let fade = reduceMotion
        let duration = fade ? 0.4 : min(max(Double(distance) / 800, 0.6), 1.4)
        motion = .flight(BuddyFlight(
            start: start, end: end, began: CACurrentMediaTime(), duration: duration, label: label,
            returning: returning, fade: fade,
            fadeIn: !returning && buddy.opacity < 0.5, fadeOut: returning && docked,
            mouseAtStart: NSEvent.mouseLocation
        ))
        ensureTicking()
    }

    private func land(label: String?) {
        motion = .pointing
        // Reference (ptt f0766–f0777): it lands tip-first along its travel direction, holds ≈100 ms,
        // then turns back to rest over ≈250 ms — the short way in this angle frame, which for an
        // up-right flight is ≈100° anticlockwise, exactly as the reference turns.
        withAnimation(.easeInOut(duration: 0.25).delay(0.09)) {
            buddy.rotation = BuddyModel.restRotation
            buddy.scale = 1
        }
        let generation = flightGeneration
        if buddy.catMode {
            buddy.catPose = .sit
            buddy.catMeow = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.6))
                self?.buddy.catMeow = false
            }
        }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let phrase = trimmed.isEmpty ? (Self.pointerPhrases.randomElement() ?? "this one!") : trimmed
        Task { [weak self] in
            guard let self else { return }
            // Reference: the label fades in at full size ≈65 ms after landing with its first
            // character, then types ≈46 ms per character on average ("menu bar c" at +417 ms).
            self.buddy.pointLabel = ""
            self.buddy.pointLabelScale = 1
            try? await Task.sleep(for: .milliseconds(65))
            guard generation == self.flightGeneration else { return }
            withAnimation(.easeOut(duration: 0.08)) { self.buddy.pointLabelVisible = true }
            for ch in phrase {
                guard generation == self.flightGeneration else { return }
                self.buddy.pointLabel.append(ch)
                try? await Task.sleep(for: .milliseconds(Int.random(in: 30...60)))
            }
            let hold = self.flightQueue.isEmpty ? 3.0 : 2.2
            try? await Task.sleep(for: .seconds(hold))
            guard generation == self.flightGeneration else { return }
            withAnimation(.easeOut(duration: 0.4)) { self.buddy.pointLabelVisible = false }
            try? await Task.sleep(for: .seconds(0.4))
            guard generation == self.flightGeneration else { return }
            self.buddy.pointLabel = ""
            self.flyToNext()
        }
    }

    private func finishReturn() {
        motion = .following
        velocity = .zero
        buddy.scale = 1
        buddy.rotation = BuddyModel.restRotation
        if docked {
            buddy.visible = false
            buddy.opacity = 1
        }
        ensureTicking()
    }

    // MARK: - Annotations

    func addAnnotation(_ item: Annotation) {
        let live = LiveAnnotation(item)
        marks.items.append(live)
        let lifetime: Double
        switch item {
        case .highlight: lifetime = 2.0          // highlights clear fast
        case .shape: lifetime = 12               // shapes stay while Awan talks
        case .target: lifetime = 120             // targets wait for the user (safety cap)
        }
        let id = live.id
        expiryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard !Task.isCancelled else { return }
            self?.fadeOutAnnotation(id)
        }
    }

    func fadeOutAnnotation(_ id: UUID) {
        expiryTasks[id]?.cancel()
        expiryTasks[id] = nil
        hoverDwell[id] = nil
        guard let i = marks.items.firstIndex(where: { $0.id == id }), !marks.items[i].fading else { return }
        marks.items[i].fading = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.4))
            self?.marks.items.removeAll { $0.id == id }
        }
    }

    private func isHoverTarget(_ live: LiveAnnotation) -> Bool {
        if case .target(_, _, _, true) = live.item { return !live.hit && !live.fading }
        return false
    }

    private func contains(_ live: LiveAnnotation, _ p: CGPoint) -> Bool {
        guard case .target(let c, let r, _, _) = live.item else { return false }
        return hypot(p.x - c.x, p.y - c.y) <= max(r, 12) + 6
    }

    func handleMouseDown() {
        let p = NSEvent.mouseLocation
        guard let live = marks.items.last(where: { live in
            if case .target(_, _, _, false) = live.item { return !live.hit && !live.fading && contains(live, p) }
            return false
        }) else { return }
        hitTarget(live)
    }

    private func checkHover(_ mouse: CGPoint, _ now: CFTimeInterval) {
        for live in marks.items where isHoverTarget(live) {
            if contains(live, mouse) {
                if let since = hoverDwell[live.id] {
                    if now - since >= 0.6 { hitTarget(live) }
                } else {
                    hoverDwell[live.id] = now
                }
            } else {
                hoverDwell[live.id] = nil
            }
        }
    }

    private func hitTarget(_ live: LiveAnnotation) {
        guard let i = marks.items.firstIndex(where: { $0.id == live.id }) else { return }
        expiryTasks[live.id]?.cancel()
        expiryTasks[live.id] = nil
        hoverDwell[live.id] = nil
        withAnimation(.easeOut(duration: 0.45)) { marks.items[i].hit = true }
        let id = live.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.45))
            self?.fadeOutAnnotation(id)
        }
        if case .target(_, _, let label, _) = live.item { onTargetHit?(label) }
    }

    // MARK: - Spatial trail

    private func appendTrail(_ mouse: CGPoint) {
        guard let last = trail.strokes.last?.last else {
            trail.strokes.append([mouse])
            return
        }
        guard hypot(mouse.x - last.x, mouse.y - last.y) >= 2, trail.strokes[trail.strokes.count - 1].count < 4000 else { return }
        trail.strokes[trail.strokes.count - 1].append(mouse)
    }
}
