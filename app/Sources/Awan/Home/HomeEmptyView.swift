import SwiftUI

/// Home with nothing selected: Awan sits on its talk pill and says hello.
/// Reference (attached, panel points): pill ring 226×49 centred at y≈324 (0.582 of the column
/// height), mascot ≈112 wide sitting on it, greeting 22 semibold at y≈368, hint 14 at y≈398.
/// Everything is centred 7.5 pt left of the column centre (the reference reserves a scroller gutter).
struct HomeEmptyView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var companion: CompanionEngine
    @Environment(\.homeLayout) private var layout

    var body: some View {
        GeometryReader { geo in
            let s = layout.heroScale
            let pillCentre = geo.size.height * 0.582
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    HoldToTalkPill(idleTitle: "Hai! Need a hand? ^_^", height: 49 * min(s, 1.05))
                        .sittingMascot(width: 112 * s, visible: 80 * s, mood: companion.voiceState.mood)
                    Text(state.greeting)
                        .font(.awan(18.5 * s, .semibold))
                        .foregroundStyle(HomeColor.title)
                        .padding(.top, 19.5 * s)
                    Text("Hold \(HomeUI.talkKeys) and tell me what you need done.")
                        .font(.awan(13 * min(s, 1.05)))
                        .foregroundStyle(HomeColor.hint)
                        .padding(.top, 6.5 * s)
                    NextMeetingRow()
                        .padding(.top, 14)
                    // The reference keeps the empty Home to the greeting: a voice turn only changes the pill
                    // (Listening / Thinking / Speaking) and is answered out loud and with the cursor.
                }
                .frame(maxWidth: .infinity)
                .padding(.top, pillCentre - 49 * min(s, 1.05) / 2)
            }
            .padding(.trailing, 15)
            .animation(Theme.spring, value: companion.responseText.isEmpty)
        }
    }
}

/// The key action: press and hold (mouse) or hold the talk shortcut. Shows the voice state:
/// idle (mic + title) → "Listening" + bars → "Thinking" + dots → "Speaking" + bars.
/// Drawn as the reference does: a lime gel inset 2.5 pt inside a thin graphite ring. With no fixed
/// `width` the pill hugs its label (27.5 pt side padding) and springs between states.
struct HoldToTalkPill: View {
    @EnvironmentObject var companion: CompanionEngine
    @EnvironmentObject var state: AppState
    var idleTitle: String
    var width: CGFloat? = nil
    var height: CGFloat = 49
    /// When set, speech goes to this Awan instead of the companion.
    var agentSlug: String? = nil
    @Local private var pressing = false

    var body: some View {
        HStack(spacing: 9) {
            switch companion.voiceState {
            case .listening:
                Text("Listening").lineLimit(1)
                WaveformBars(level: CGFloat(companion.audioLevel), color: TalkPillStyle.stateInk, bars: 4).frame(width: 16, height: 14)
            case .processing:
                Text("Thinking").lineLimit(1)
                TypingDots(color: TalkPillStyle.stateInk)
            case .responding:
                Text("Speaking").lineLimit(1)
                WaveformBars(level: 0.5, color: TalkPillStyle.stateInk, bars: 4).frame(width: 16, height: 14)
            case .idle:
                Image(systemName: "mic.fill").font(.system(size: 13, weight: .semibold))
                Text(idleTitle).lineLimit(1)
            }
        }
        .font(.awan(13.5, .semibold))
        .foregroundStyle(companion.voiceState == .idle ? Theme.ink : TalkPillStyle.stateInk)
        .padding(.horizontal, width == nil ? 27.5 + 2.5 : 0)
        .frame(width: width, height: height)
        .fixedSize(horizontal: width == nil, vertical: false)
        .background(TalkPillBackground())
        .scaleEffect(pressing ? 0.97 : 1)
        .animation(Theme.snappy, value: pressing)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: companion.voiceState)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    companion.beginListening(target: agentSlug)
                }
                .onEnded { _ in
                    pressing = false
                    companion.endListening()
                }
        )
        .accessibilityLabel(agentSlug == nil ? "Talk to Awan" : "Talk")
    }
}

enum TalkPillStyle {
    /// Label colour while listening / thinking / speaking (the reference greys the label out).
    static let stateInk = Color(hex: 0x4E5A1C)
}

/// Lime gel inset 2.5 pt inside a 1 pt graphite ring (reference: blue gel, #6B6B6B ring).
struct TalkPillBackground: View {
    var body: some View {
        ZStack {
            Capsule().inset(by: 0.5).stroke(Color(hex: 0x6B6B69), lineWidth: 1)
            LimeGel().padding(3)
        }
    }
}

extension View {
    /// The Home mascot sitting on top of this view (centred), `visible` points of it above the top edge.
    func sittingMascot(width: CGFloat, visible: CGFloat, mood: CharacterMood) -> some View {
        self
            .background(alignment: .top) {
                CloudCreature(appearance: .mascot, mood: mood, showPaws: true)
                    .frame(width: width, height: width / 1.35)
                    .offset(y: -visible)
                    .allowsHitTesting(false)
            }
    }
}

