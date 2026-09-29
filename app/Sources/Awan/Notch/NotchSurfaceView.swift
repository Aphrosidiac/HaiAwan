import SwiftUI

/// Transient notch cards. Companion/dictation builders extend the text and dictation cards.
struct NotchSurfaceView: View {
    let kind: NotchSurfaceKind
    @EnvironmentObject var state: AppState
    @EnvironmentObject var notch: NotchController

    var body: some View {
        Group {
            switch kind {
            case .textInput:
                NotchTextInputSurface()
            case .textResponse:
                NotchTextResponseSurface()
            case .dictation:
                NotchDictationSurface()
            case .morningSuggestions:
                MorningSuggestionsSurface()
            case let .agentFinished(slug):
                AgentFinishedSurface(slug: slug)
            case .unmuteFallback:
                UnmuteSurface()
            case .handoff:
                HandoffSurface()
            case .meetingCountdown:
                MeetingCountdownSurface()
            case let .integrationSuggestion(id):
                IntegrationSuggestionSurface(integrationID: id)
            case let .appUpdated(version):
                AppUpdatedSurface(version: version)
            case .fileDrop:
                FileDropSurface()
            case .dropComposer:
                DropComposerSurface()
            case .homeDetached:
                HomeDetachedSurface()
            case let .message(text):
                HStack(spacing: 12) {
                    CloudCreature(appearance: .mascot, mood: .happy, glow: false).frame(width: 34)
                    Text(text).font(.awan(13.5, .medium)).foregroundStyle(Theme.text).lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 22).padding(.top, 34)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A finished Awan pops out of the notch: face, summary, open.
struct AgentFinishedSurface: View {
    let slug: String
    @EnvironmentObject var state: AppState
    @EnvironmentObject var notch: NotchController
    var body: some View {
        let agent = state.agents.agent(slug)
        let turn = state.agents.thread(slug).turns.last
        HStack(alignment: .top, spacing: 12) {
            if let agent { AgentAvatar(appearance: agent.character, size: 42, mood: turn?.status == .failed ? .sad : .happy) }
            VStack(alignment: .leading, spacing: 4) {
                Text(agent?.name ?? "Awan").font(.awan(13.5, .semibold)).foregroundStyle(Theme.text)
                Text(turn?.summary ?? turn?.errorText ?? "Done.").font(.awan(12.5)).foregroundStyle(Theme.textSecondary).lineLimit(3)
                HStack {
                    Button("Open") { state.openAgent(slug); notch.dismissSurface() }.buttonStyle(.gel(.lime, height: 26, padding: 14, fontSize: 12))
                    if let a = turn?.artifacts.first {
                        Button("Show file") { NSWorkspace.shared.open(a.url) }.buttonStyle(.gel(.dark, height: 26, padding: 12, fontSize: 12))
                    }
                }.padding(.top, 4)
            }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.top, 36)
    }
}

struct UnmuteSurface: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.slash.fill").font(.system(size: 18)).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text("Your Mac is muted").font(.awan(13.5, .semibold)).foregroundStyle(Theme.text)
                Text("I copied my answer to your clipboard.").font(.awan(12.5)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Unmute") { SystemAudio.unmute() }.buttonStyle(.gel(.bone, height: 26, padding: 12, fontSize: 12))
        }
        .padding(.horizontal, 22).padding(.top, 38)
    }
}


/// Home is popped out as its own window, so hovering the notch offers to put it back (reference: notch card
/// ≈460×115, pure black — title 15 semibold centred at y≈19, subtitle 13 grey at y≈38, small gel button at y≈73).
struct HomeDetachedSurface: View {
    @EnvironmentObject var notch: NotchController
    var body: some View {
        VStack(spacing: 0) {
            Text("Your Awan window is in view").font(.awan(15, .semibold)).foregroundStyle(Color.white)
                .frame(height: 20).padding(.top, 9 + IntegrationCardLayout.topInset)
            Text("Move your window back to the notch.").font(.awan(13)).foregroundStyle(Theme.textSecondary)
                .frame(height: 16).padding(.top, 1)
            Button {
                notch.dismissSurface()
                HomeWindowController.shared.setDetached(false)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up").font(.system(size: 8.5, weight: .bold))
                    Text("Attach to notch").lineLimit(1).fixedSize()
                }
            }
            .buttonStyle(.gel(.bone, height: 22, padding: 7, fontSize: 10))
            .padding(.top, 73 - 11 - 46)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}
