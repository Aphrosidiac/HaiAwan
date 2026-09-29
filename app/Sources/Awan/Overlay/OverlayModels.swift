import SwiftUI
import AppKit

/// State of the cursor buddy, in global AppKit coordinates (origin bottom-left of the main display).
/// Split from the annotation/trail models so a 60 fps position update re-renders only the buddy.
@MainActor
final class BuddyModel: ObservableObject {
    /// The triangle's tip is up at 0°; −36° puts a tip to the right, 6° above horizontal (reference).
    /// Kept in this frame (not normalised) so the post-landing spring turns the way the reference does.
    static let restRotation: Double = -36

    @Published var position: CGPoint = .zero
    @Published var rotation: Double = BuddyModel.restRotation
    @Published var scale: CGFloat = 1
    @Published var opacity: Double = 1
    @Published var visible = true
    @Published var voiceState: VoiceState = .idle
    @Published var audioLevel: CGFloat = 0
    @Published var color: Color = Theme.lime

    /// The label typed out beside a pointed-at target.
    @Published var pointLabel = ""
    @Published var pointLabelVisible = false
    @Published var pointLabelScale: CGFloat = 1

    /// "Updates beside the cursor" bubble.
    @Published var bubbleText: String?
    @Published var bubbleStreaming = false
    @Published var bubbleAnchor: CGPoint = .zero

    /// Cat Mode (Settings → General): the buddy is a pixel cat.
    @Published var catMode = false
    @Published var catPose: CatPose = .idle
    @Published var catFacingLeft = false
    @Published var catMeow = false
}

/// A mark on screen plus its lifecycle flags.
struct LiveAnnotation: Identifiable, Equatable {
    let id: UUID
    let item: Annotation
    let seed: UInt64
    var fading = false
    var hit = false

    init(_ item: Annotation, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        id = UUID()
        self.item = item
        self.seed = seed
    }

    var isTarget: Bool { if case .target = item { return true } else { return false } }
}

@MainActor
final class AnnotationModel: ObservableObject {
    @Published var items: [LiveAnnotation] = []
    @Published var color: Color = Theme.lime
    @Published var reduceMotion = false
    /// Off for snapshots: marks render fully drawn with no draw-in.
    var animated = true
}

@MainActor
final class TrailModel: ObservableObject {
    /// One stroke per click-drag made while the talk keys are held (global points).
    @Published var strokes: [[CGPoint]] = []
    @Published var opacity: Double = 1
    @Published var color: Color = Theme.lime
}

/// Converts global AppKit points to one screen's top-left-origin canvas.
struct OverlayMapper {
    let frame: CGRect

    func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y) }
    func local(_ r: CGRect) -> CGRect { CGRect(x: r.minX - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height) }
    /// Cheap cull: draw only what could touch this screen.
    func isNear(_ p: CGPoint, margin: CGFloat = 420) -> Bool { frame.insetBy(dx: -margin, dy: -margin).contains(p) }
}

extension View {
    /// Places the view's `alignment` corner exactly at `point` (canvas coordinates) at its ideal size.
    func pinned(at point: CGPoint, _ alignment: Alignment = .topLeading) -> some View {
        Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: alignment) { self.fixedSize() }
            .position(point)
    }
}
