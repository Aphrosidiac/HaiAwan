import SwiftUI

/// OWNER: onboarding+dictation builder — the dictation pill under the notch.
/// Live: waveform + the words so far (+ a hands-free badge). Afterwards, briefly: the clipboard
/// fallback, a word learned into the dictionary, or the free-limit hint.
struct NotchDictationSurface: View {
    @ObservedObject var dictation = DictationManager.shared
    @EnvironmentObject var notch: NotchController

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .padding(.top, notch.geometry.menuBarHeight - 2)
        .animation(Theme.snappy, value: dictation.surface)
    }

    @ViewBuilder private var content: some View {
        switch dictation.surface {
        case .live, .finishing:
            WaveformBars(level: CGFloat(dictation.surface == .finishing ? 0.15 : max(0.12, dictation.level)), color: Theme.lime)
                .frame(width: 26, height: 14)
            Text(liveText)
                .font(.awan(12.5, .medium))
                .foregroundStyle(dictation.partialText.isEmpty ? Theme.textTertiary : Theme.text)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            if dictation.surface == .finishing {
                TypingDots(color: Theme.bone, dot: 4)
            } else if dictation.isHandsFree {
                Text("HANDS-FREE")
                    .font(.awan(9.5, .bold)).tracking(0.6)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 7).frame(height: 17)
                    .background(Capsule().fill(Theme.lime))
            }
        case let .clipboard(text):
            icon("doc.on.clipboard.fill", Theme.bone)
            line(text)
        case let .learned(word):
            icon("text.book.closed.fill", Theme.lime)
            (Text("Added ") + Text("“\(word)”").foregroundColor(Theme.text).bold() + Text(" to your dictionary"))
                .font(.awan(12.5, .medium)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        case .limit:
            icon("sparkles", Theme.lime)
            line("Free dictation is used up this month.")
            Button("Upgrade") {
                AppState.shared.presentPaywall(.limitHit)
                AppState.shared.openHome()
                notch.dismissSurface()
            }
            .buttonStyle(.gel(.lime, height: 22, padding: 10, fontSize: 11))
        case let .problem(text):
            icon("mic.slash.fill", Theme.warning)
            line(text)
        }
    }

    private var liveText: String {
        if dictation.surface == .finishing { return dictation.partialText.isEmpty ? "Tidying up…" : dictation.partialText }
        return dictation.partialText.isEmpty ? "Listening…" : dictation.partialText
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).frame(width: 18)
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.awan(12.5, .medium)).foregroundStyle(Theme.text)
            .lineLimit(1).minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
