import AppKit
import Combine
import SwiftUI

/// A point on screen in global AppKit coordinates (origin bottom-left of the main display).
struct ScreenPoint: Hashable {
    var point: CGPoint
    var label: String?
}

enum AnnotationShapeKind: String, Codable { case line, arrow, circle, curve, polygon }

/// Things the companion can draw on screen (reference tags [HIGHLIGHT] [SHAPE] [TARGET] [HOVER]).
enum Annotation: Hashable {
    case highlight(rect: CGRect, label: String?)
    case shape(kind: AnnotationShapeKind, points: [CGPoint], label: String?, filled: Bool)
    case target(center: CGPoint, radius: CGFloat, label: String?, isHover: Bool)
}

/// OWNER: overlay builder. Full-screen click-through overlay windows (one per display) that host the
/// cursor buddy, pointing flights, annotations, the spatial paint trail, the docked-agent stack and
/// the "updates beside the cursor" bubble. The companion builder calls this API; keep it stable.
///
/// Implementation lives in `Overlay/` (models, canvas, motion engine, dock). All coordinates are
/// global AppKit points.
@MainActor final class CursorOverlayController {
    static let shared = CursorOverlayController()
    /// Called when the user clicks inside an armed [TARGET] (guided walkthroughs). Arg: label.
    var onTargetHit: ((String?) -> Void)?

    // MARK: State (read by the canvases, the dock and the snapshots)

    let buddy = BuddyModel()
    let marks = AnnotationModel()
    let trail = TrailModel()
    let dock = DockController()

    var panels: [OverlayPanel] = []
    var installed = false
    var docked = false
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    lazy var ticker = DisplayTicker { [weak self] now in self?.tick(now) }

    // Motion engine (Overlay/BuddyMotion.swift)
    var motion: BuddyMotion = .following
    var velocity = CGVector.zero
    var lastTick: CFTimeInterval = 0
    var busyUntil: CFTimeInterval = 0
    var flightQueue: [ScreenPoint] = []
    var flightGeneration = 0
    var trailRecording = false
    var hoverDwell: [UUID: CFTimeInterval] = [:]

    var bubbleHideTask: Task<Void, Never>?
    var trailFadeTask: Task<Void, Never>?
    var expiryTasks: [UUID: Task<Void, Never>] = [:]
    var monitors: [Any] = []
    var cancellables = Set<AnyCancellable>()

    func install() {
        guard !installed else { return }
        installed = true
        buddy.position = homePoint(mouse: NSEvent.mouseLocation)
        rebuildPanels()
        dock.onLayout = { [weak self] in self?.ensureTicking() }
        installMonitors()
        observeSystem()
        refreshAppearance()
        ensureTicking()
        if CommandLine.arguments.contains("--overlay-demo") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                OverlayDemo.run()
            }
        }
    }

    /// Listening → waveform beside the cursor; processing → spinner; responding/idle → triangle.
    func setVoiceState(_ state: VoiceState) {
        guard buddy.voiceState != state else { return }
        buddy.voiceState = state
        if state != .listening { buddy.audioLevel = 0 }
        ensureTicking()
    }

    /// Fly the buddy to each point in turn (bezier arc, label bubble, hold, then return).
    func fly(to points: [ScreenPoint]) {
        guard !points.isEmpty else { return }
        install()
        beginFlights(points)
    }

    func annotate(_ items: [Annotation]) {
        guard !items.isEmpty else { return }
        install()
        for item in items { addAnnotation(item) }
        ensureTicking()
    }

    func clearAnnotations() {
        for task in expiryTasks.values { task.cancel() }
        expiryTasks.removeAll()
        hoverDwell.removeAll()
        let ids = marks.items.map(\.id)
        for id in ids { fadeOutAnnotation(id) }
    }

    /// Text streamed next to the cursor (agent replies / companion text). nil hides it.
    func showCursorBubble(_ text: String?, streaming: Bool = false) {
        bubbleHideTask?.cancel()
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            withAnimation(.easeOut(duration: 0.25)) { buddy.bubbleText = nil }
            return
        }
        install()
        if buddy.bubbleText == nil { buddy.bubbleAnchor = bubbleAnchorPoint(mouse: NSEvent.mouseLocation) }
        if buddy.bubbleText == nil {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { buddy.bubbleText = text }
        } else {
            buddy.bubbleText = text
        }
        buddy.bubbleStreaming = streaming
        ensureTicking()
        // Streaming text stays until the final (non-streaming) call; a stalled stream still clears.
        let seconds = streaming ? 20 : Self.readingTime(text)
        bubbleHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: 0.35)) { self.buddy.bubbleText = nil }
        }
    }

    /// While the talk key is held the pointer leaves a paint trail; returns the stroke (global coords).
    func beginSpatialTrail() {
        install()
        trailFadeTask?.cancel()
        trailRecording = true
        trail.opacity = 1
        trail.points = [NSEvent.mouseLocation]
        ensureTicking()
    }

    func endSpatialTrail() -> [CGPoint] {
        guard trailRecording else { return [] }
        trailRecording = false
        let points = trail.points
        withAnimation(.easeOut(duration: 0.9)) { trail.opacity = 0 }
        trailFadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.95))
            guard !Task.isCancelled, let self, !self.trailRecording else { return }
            self.trail.points = []
        }
        return points.count > 1 ? points : []
    }

    /// Re-read Prefs (colour, docked) — called when Settings change.
    func refreshAppearance() {
        let prefs = Prefs.shared
        applyColor(prefs.cursorColor)
        if buddy.catMode != prefs.catMode { buddy.catMode = prefs.catMode }
        applyDocked(prefs.cursorDocked)
        applySharing(prefs.showInScreenRecordings)
    }
}

// MARK: - Additive helpers (safe for other builders to call)

extension CursorOverlayController {
    /// An Awan's progress/reply beside the cursor, honouring Settings → Agents →
    /// "Show updates beside cursor". Prefixed with the Awan's name so you know who's talking.
    func showAgentUpdate(_ text: String, from slug: String, streaming: Bool = false) {
        guard Prefs.shared.showUpdatesBesideCursor else { return }
        let name = AgentStore.shared.agent(slug)?.name
        showCursorBubble(name.map { "\($0): \(text)" } ?? text, streaming: streaming)
    }

    /// True while a pointing walk (flights, labels, return) is in progress.
    var isPointing: Bool {
        if case .following = motion { return false }
        return true
    }
}
