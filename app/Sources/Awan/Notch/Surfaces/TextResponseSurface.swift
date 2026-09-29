import SwiftUI
import AppKit

/// OWNER: companion builder — streamed text reply card: what you asked, the reply (selectable, streaming),
/// a copy button and an auto-dismiss ring (hover pauses it, click dismisses now).
struct NotchTextResponseSurface: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var companion = CompanionEngine.shared
    @Local private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if companion.responseText.isEmpty {
                            TypingDots(color: Theme.textSecondary, dot: 6).padding(.top, 6)
                        } else {
                            Text(companion.responseText)
                                .font(.awan(14.5))
                                .lineSpacing(3)
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .onChange(of: companion.responseText) { _, _ in
                    if companion.isStreaming { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 36)
        .padding(.bottom, 16)
        .contentShape(Rectangle())
        .onHover { companion.pauseTextDismiss($0) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            CloudCreature(appearance: .mascot, mood: mood, glow: false).frame(width: 26, height: 22)
            Text(companion.lastUserText.isEmpty ? "Awan" : companion.lastUserText)
                .font(.awan(12.5, .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if !companion.responseText.isEmpty && !companion.isStreaming {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(companion.responseText, forType: .string)
                    withAnimation(Theme.snappy) { copied = true }
                    Task { try? await Task.sleep(for: .seconds(1.6)); withAnimation(Theme.snappy) { copied = false } }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5, weight: .semibold))
                        Text(copied ? "Copied" : "Copy").font(.awan(11.5, .semibold))
                    }
                    .foregroundStyle(copied ? Theme.textOnLime : Theme.text)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(copied ? Theme.lime : Theme.cardRaised))
                }
                .buttonStyle(.plain)
                .help("Copy response")
            }
            DismissRing(deadline: companion.textDismissAt, duration: companion.textDismissDuration, paused: companion.isTextDismissPaused) { companion.dismissTextResponse() }
        }
    }

    private var mood: CharacterMood {
        switch companion.voiceState {
        case .processing: return .thinking
        case .responding: return .speaking
        case .listening: return .listening
        case .idle: return companion.isStreaming ? .speaking : .happy
        }
    }
}

/// Auto-dismiss countdown: a ring that empties; click to dismiss now. No deadline = full ring (streaming, or paused on hover).
struct DismissRing: View {
    var deadline: Date?
    var duration: Double
    var paused = false
    var action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: deadline == nil)) { ctx in
                let left = deadline.map { max(0, $0.timeIntervalSince(ctx.date)) } ?? duration
                let progress = duration > 0 ? left / duration : 1
                ZStack {
                    Circle().stroke(Theme.strokeStrong, lineWidth: 2)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Theme.textSecondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: paused && !hovering ? "pause.fill" : "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(hovering ? Theme.text : Theme.textSecondary)
                }
                .frame(width: 20, height: 20)
                .padding(2)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Dismiss now")
    }
}
