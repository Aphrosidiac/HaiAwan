import SwiftUI
import AppKit

/// Right-hand column for one Awan: portrait + Edit character, who it is, its routines, its files,
/// and Pin / Reveal workspace / Archive. Reference: a 319 pt overlay over the thread's right side
/// (x 572→891 of the 907 window), full panel height, 1 pt #3B3B3B left hairline, body #1C1C1B.
struct AgentInspector: View {
    static let width: CGFloat = 319
    /// Measured: critically damped, ≈0.32 s, both directions.
    static let spring = Animation.spring(response: 0.32, dampingFraction: 1.0)
    static let transition = AnyTransition.move(edge: .trailing).combined(with: .opacity)

    let agent: AwanAgent
    let openArtifact: (Artifact) -> Void
    @EnvironmentObject var state: AppState
    @ObservedObject private var scheduler = RoutineScheduler.shared
    @Local private var confirmArchive = false
    @Local private var showAllFiles = false
    @Local private var react = ReactionTrigger()
    @ObservedObject private var hero = CharacterHero.shared

    private var thread: AgentThread { state.agents.thread(agent.slug) }

    var body: some View {
        // Reference (inspector-local): ✕ 30×30 at (9, 8); portrait 118 at y=45; Edit character 137×31
        // 9 below it; name 18 semibold 12 below; role 14; description 13 (16 side inset); ROUTINES at
        // x=29; routines card x 15→303, radius 14.
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                portrait
                    .padding(.top, 45)
                Button { CharacterHero.open(agent.slug) } label: {
                    Label("Edit character", systemImage: "paintbrush.pointed.fill").font(.awan(13.5, .semibold)).lineLimit(1).fixedSize()
                }
                .buttonStyle(.gel(.bone, height: 31, padding: 9.5, fontSize: 13.5))
                .padding(.top, 9)
                Text(agent.name).font(.awan(17.5, .semibold)).foregroundStyle(HomeColor.title)
                    .frame(height: 20)
                    .padding(.top, 12)
                Text(agent.roleText).font(.awan(13)).foregroundStyle(HomeColor.secondary)
                    .frame(height: 16)
                    .padding(.top, 8)
                Text(agent.oneLiner).font(.awan(12.5)).foregroundStyle(HomeColor.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                section("Routines") { routines }
                    .padding(.top, 22)
                section("Artifacts") { artifacts }
                    .padding(.top, 22)
                actions.padding(.top, 22)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
        }
        .overlay(alignment: .topLeading) {
            BareIconButton(systemName: "xmark", size: 14, weight: .regular, color: HomeColor.icon, help: "Close") { state.inspectorOpen = false }
                .padding(.leading, 9)
                .padding(.top, 8)
        }
        .background(HomeColor.body)
        .overlay(alignment: .leading) { Rectangle().fill(HomeColor.divider).frame(width: 1) }
        .confirmationDialog("Archive \(agent.name)?", isPresented: $confirmArchive) {
            Button("Archive", role: .destructive) {
                state.inspectorOpen = false
                state.agents.archive(agent.slug)
                state.homePage = .home
            }
        } message: {
            Text("\(agent.name) leaves Home. Its files stay.")
        }
    }

    private var portrait: some View {
        // While the editor is open (or the copy is flying) the portrait lives in the editor: hide the original.
        let away = state.characterEditorSlug == agent.slug || hero.flying(agent.slug)
        return ReactiveCharacter(appearance: agent.character, mood: thread.activeTurn != nil ? .running : .happy, avatarSize: 118, trigger: react)
            .opacity(away ? 0 : 1)
            .modifier(HeroFrameReporter(keyPath: \.portraitFrame))
            .frame(width: 118, height: 118)
            .contentShape(Circle())
            .onTapGesture { react.fire(.boop) }
            .contextMenu { ForEach(CharacterReaction.allCases) { r in Button(r.title) { react.fire(r) } } }
            .help("Tap to boop")
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.awan(11))
                .tracking(0.5)
                .foregroundStyle(HomeColor.tertiary)
                .frame(height: 14)
                .padding(.leading, 14)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
    }

    // MARK: Routines

    @ViewBuilder private var routines: some View {
        let list = scheduler.routines(for: agent.slug)
        if list.isEmpty {
            Text("Nothing on repeat yet. Tell \(agent.name) to do something “every morning”, “every few hours” or “every Monday” and the routine lands here.")
                .font(.awan(12.5)).foregroundStyle(HomeColor.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14.5)
                .padding(.top, 9)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HomeColor.card))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HomeColor.divider, lineWidth: 1))
        } else {
            VStack(spacing: 8) {
                ForEach(list) { r in RoutineRow(routine: r) }
            }
        }
    }

    // MARK: Artifacts

    @ViewBuilder private var artifacts: some View {
        let files = thread.artifacts
        if files.isEmpty {
            Text("Files this Awan makes will show up here.")
                .font(.awan(12.5)).foregroundStyle(HomeColor.tertiary)
                .padding(.leading, 14)
        } else {
            let shown = showAllFiles ? files : Array(files.prefix(4))
            LazyVGrid(columns: [GridItem(.fixed(124), spacing: 12), GridItem(.fixed(124), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(shown) { a in ArtifactCard(artifact: a, width: 124, open: openArtifact) }
            }
            if files.count > 4 {
                Button(showAllFiles ? "Show less" : "\(files.count - 4) more") { withAnimation(Theme.snappy) { showAllFiles.toggle() } }
                    .buttonStyle(.plain)
                    .font(.awan(12, .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 0) {
            InspectorAction(title: agent.pinned ? "Unpin" : "Pin", symbol: agent.pinned ? "pin.slash" : "pin") {
                state.agents.togglePin(agent.slug)
            }
            InspectorAction(title: "Reveal workspace", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([agent.workspace])
            }
            InspectorAction(title: "Archive", symbol: "archivebox", destructive: true, divider: false) {
                confirmArchive = true
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.card.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.stroke, lineWidth: 1))
        .padding(.horizontal, 15)
    }
}

private struct InspectorAction: View {
    let title: String
    let symbol: String
    var destructive = false
    var divider = true
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 16)
                Text(title).font(.awan(13, .medium))
                Spacer()
            }
            .foregroundStyle(destructive ? Theme.danger : Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(hovering ? Color.white.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 40) }
        }
    }
}

/// Title, cadence, next run, and pause / run now / delete.
struct RoutineRow: View {
    let routine: Routine
    @ObservedObject private var scheduler = RoutineScheduler.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: routine.isPaused ? "pause.circle.fill" : "repeat.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(routine.isPaused ? Theme.textTertiary : Theme.bone)
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.title).font(.awan(13, .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                    Text(status).font(.awan(11.5)).foregroundStyle(routine.lastRunFailed ? Theme.danger.opacity(0.9) : Theme.textTertiary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Button { routine.isPaused ? scheduler.resume(routine.id) : scheduler.pause(routine.id) } label: {
                    Label(routine.isPaused ? "Resume" : "Pause", systemImage: routine.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.gel(.dark, height: 24, padding: 10, fontSize: 11.5))
                Button { scheduler.runNow(routine.id) } label: {
                    Label("Run now", systemImage: "bolt.fill")
                }
                .buttonStyle(.gel(.dark, height: 24, padding: 10, fontSize: 11.5))
                .disabled(isRunning)
                Spacer(minLength: 0)
                Button { scheduler.delete(routine.id) } label: {
                    Image(systemName: "trash").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete routine")
            }
            .labelStyle(.titleAndIcon)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    private var isRunning: Bool {
        if let s = routine.lastRunStartedAt { return routine.lastRunFinishedAt.map { $0 < s } ?? true }
        return false
    }

    private var status: String {
        if isRunning { return "\(routine.cadenceText) · Running now" }
        if routine.isPaused {
            return routine.consecutiveFailures > 0 ? "Paused after \(routine.consecutiveFailures) failed runs" : "\(routine.cadenceText) · Paused"
        }
        if routine.lastRunFailed { return "\(routine.cadenceText) · Last run failed" }
        return "\(routine.cadenceText) · Next \(Self.next(routine.nextRunAt))"
    }

    static func next(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return HomeUI.clock(d) }
        if cal.isDateInTomorrow(d) { return "tomorrow \(HomeUI.clock(d))" }
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return f.string(from: d)
    }
}
