import SwiftUI
import AppKit

/// One Awan's conversation: intro bubbles, every turn (ask → progress → answer → files → next steps),
/// the talk/type composer, and the inspector / file preview on the right.
struct AgentThreadPage: View {
    let slug: String
    @EnvironmentObject var state: AppState
    @StateObject private var composer = ComposerModel()
    @Local private var preview: Artifact? = AgentThreadPage.debugPreview

    /// Snapshot hook: open with this file in the preview column.
    static var debugPreview: Artifact? = nil
    /// Snapshot hook: render the thread scrolled to the top (reference home-thread-top).
    static var debugScrollToTop = false

    var body: some View {
        if let agent = state.agents.agent(slug) {
            GeometryReader { geo in
                // Inspector: 319 wide over the thread's right side (reference x 572→891 of the 907 window).
                let sideWidth: CGFloat = state.inspectorOpen ? AgentInspector.width : min(440, geo.size.width * 0.52)
                let hasSide = state.inspectorOpen || preview != nil
                let pushes = !state.inspectorOpen && geo.size.width - sideWidth >= 440
                HStack(spacing: 0) {
                    ThreadColumn(agent: agent, composer: composer, openArtifact: open)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if hasSide && pushes {
                        side(agent).frame(width: sideWidth).transition(.move(edge: .trailing))
                    }
                }
                .overlay(alignment: .trailing) {
                    if hasSide && !pushes {
                        side(agent).frame(width: sideWidth)
                            .shadow(color: .black.opacity(state.inspectorOpen ? 0 : 0.5), radius: 24, x: -6)
                            .transition(state.inspectorOpen ? AgentInspector.transition : .move(edge: .trailing))
                    }
                }
            }
            .animation(AgentInspector.spring, value: state.inspectorOpen)
            .animation(Theme.spring, value: preview)
            .onAppear {
                composer.attach(slug: slug)
                state.agents.markRead(slug)
            }
            .onDisappear { composer.detach() }
            .onChange(of: state.agents.thread(slug).unread) { _, unread in
                if unread && state.isHomeOpen { state.agents.markRead(slug) }
            }
        } else {
            VStack(spacing: 12) {
                CloudCreature(appearance: .mascot, mood: .sad).frame(width: 90)
                Text("This Awan isn’t here anymore.").font(.awan(15, .semibold)).foregroundStyle(Theme.text)
                Button("Back to Home") { state.homePage = .home }.buttonStyle(.gel(.bone, height: 30, padding: 14, fontSize: 12.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func side(_ agent: AwanAgent) -> some View {
        if state.inspectorOpen {
            AgentInspector(agent: agent, openArtifact: open)
        } else if let preview {
            ArtifactPreviewPanel(artifact: preview) { self.preview = nil }
                .id(preview.path)
        }
    }

    /// Click on a file card: preview in the side panel when we can, otherwise hand it to its app.
    private func open(_ artifact: Artifact) {
        if ArtifactPreviewPanel.canPreview(artifact) && FileManager.default.fileExists(atPath: artifact.path) {
            state.inspectorOpen = false
            preview = artifact
        } else {
            NSWorkspace.shared.open(artifact.url)
        }
    }

    // MARK: - Sending

    static let attachmentsHeader = "Files the user attached to this request (treat them as the primary subject):"

    /// Sends typed/tapped work to an Awan; attached files are listed in front of the prompt.
    @MainActor
    static func send(_ text: String, attachments: [String] = [], to slug: String, provenance: String? = nil) {
        let body = text.isEmpty && !attachments.isEmpty ? "Take a look at these." : text
        var prompt = body
        if !attachments.isEmpty {
            prompt = attachmentsHeader + "\n" + attachments.map { "- \($0)" }.joined(separator: "\n") + "\n\n" + body
        }
        if let provenance { prompt = provenance + "\n\n" + prompt }
        Sounds.play(.agentLaunch, volume: 0.4)
        AgentStore.shared.send(prompt, to: slug, display: body, source: "home")
    }

    /// The paths listed by `send` (so the user's bubble can show them as chips).
    static func attachments(in prompt: String) -> [String] {
        guard let range = prompt.range(of: attachmentsHeader) else { return [] }
        var out: [String] = []
        for line in prompt[range.upperBound...].components(separatedBy: "\n").dropFirst() {
            guard line.hasPrefix("- ") else { break }
            out.append(String(line.dropFirst(2)))
        }
        return out
    }
}

// MARK: - Conversation column

private struct ThreadColumn: View {
    let agent: AwanAgent
    @ObservedObject var composer: ComposerModel
    let openArtifact: (Artifact) -> Void
    @EnvironmentObject var state: AppState
    @Local private var atBottom = true
    @Local private var dropTargeted = false

    private var thread: AgentThread { state.agents.thread(agent.slug) }

    // Reference (attached): messages x 52 → right−19.5 of the column, first bubble 140 below the top,
    // the scroll fades out from H−157 to H−97 behind the composer, content ends 168 above the bottom.
    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { outer in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: 140).id("top")
                            messages
                            Color.clear.frame(height: 1).id("bottom")
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: ThreadBottomKey.self, value: g.frame(in: .named("thread")).maxY)
                                })
                        }
                        .padding(.leading, 52)
                        .padding(.trailing, 19.5)
                        .padding(.bottom, 159)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.automatic)
                    .coordinateSpace(name: "thread")
                    .defaultScrollAnchor(AgentThreadPage.debugScrollToTop ? .top : .bottom)
                    .onPreferenceChange(ThreadBottomKey.self) { maxY in
                        let near = maxY <= outer.size.height - 167 + 40
                        if near != atBottom { atBottom = near }
                    }
                    .onChange(of: signature) { _, _ in
                        if atBottom { withAnimation(Theme.gentle) { proxy.scrollTo("bottom", anchor: .bottom) } }
                    }
                    .mask(
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 60)
                            Color.clear.frame(height: 97)
                        }
                    )
                    .overlay(alignment: .top) { HomeTopFade().frame(height: 145) }
                    // Round "jump to newest" button, right side, 97 above the talk pill (reference 34×34 at x 835).
                    .overlay(alignment: .bottomTrailing) {
                        if !atBottom {
                            Button { withAnimation(Theme.spring) { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                                Image(systemName: "arrow.down").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeColor.title)
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(HomeColor.chip))
                                    .overlay(Circle().strokeBorder(HomeColor.chipStroke, lineWidth: 1))
                                    .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                            }
                            .buttonStyle(.plain)
                            .help("Jump to the newest message")
                            .padding(.trailing, 22)
                            .padding(.bottom, 73 + 97)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                    }
                    .animation(Theme.snappy, value: atBottom)
                }
            }
            header
                .frame(maxHeight: .infinity, alignment: .top)
            ThreadComposer(agent: agent, model: composer, running: thread.activeTurn != nil) {
                state.agents.interrupt(agent.slug)
            }
        }
        .background(HomeColor.content)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.bone.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.45)))
                    .overlay(
                        Label("Drop files to send them to \(agent.name)", systemImage: "paperclip")
                            .font(.awan(14, .semibold)).foregroundStyle(Theme.text)
                    )
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL).map(\.path)
            guard !files.isEmpty else { return false }
            composer.add(files)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var signature: String {
        let last = thread.turns.last
        return "\(thread.turns.count)-\(last?.progress.count ?? 0)-\(last?.status.rawValue ?? "")-\(last?.finalText?.count ?? 0)"
    }

    // MARK: Header

    // Avatar 36 at y=11, name capsule 104×23 at y=48 (fill #292929, 14 semibold + chevron). The
    // reference centres it at 0.398 of the column width (x=518 of the 907 window), not the middle.
    private var header: some View {
        GeometryReader { g in
            VStack(spacing: 1) {
                AgentAvatar(appearance: agent.character, size: 36, mood: thread.activeTurn != nil ? .running : .idle)
                Button {
                    state.inspectorOpen.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Text(agent.name).font(.awan(12.5, .semibold)).foregroundStyle(HomeColor.title)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(HomeColor.secondary)
                    }
                    .padding(.horizontal, 9.5)
                    .frame(height: 23)
                    .background(Capsule().fill(HomeColor.chip))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(agent.name): routines, files and character")
            }
            .fixedSize()
            .position(x: g.size.width * 0.398, y: 11 + (36 + 1 + 23) / 2)
        }
        .frame(height: 72)
    }

    // MARK: Messages

    @ViewBuilder private var messages: some View {
        // Reference: intro bubbles 2 apart, 28 from the last tail to the user's bubble.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(agent.introMessages.enumerated()), id: \.offset) { i, line in
                AgentBubble(text: line, tail: i == agent.introMessages.count - 1)
            }
        }
        .padding(.bottom, 20)

        if thread.turns.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Suggested: send one and I'll get started")
                    .font(.awan(12, .medium)).foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 4)
                StickyNotes(asks: agent.suggestedAsks) { ask in
                    AgentThreadPage.send(ask, to: agent.slug)
                }
                .padding(.leading, 6)
            }
            .padding(.top, 14)
        }

        ForEach(Array(thread.turns.enumerated()), id: \.element.id) { i, turn in
            if i > 0 && turn.startedAt.timeIntervalSince(thread.turns[i - 1].completedAt ?? thread.turns[i - 1].startedAt) > 1800 {
                DateSeparator(date: turn.startedAt).padding(.top, 6)
            }
            TurnView(agent: agent, turn: turn, isLast: i == thread.turns.count - 1, openArtifact: openArtifact)
                .padding(.vertical, 8)
        }
    }
}

private struct ThreadBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - One turn

private struct TurnView: View {
    let agent: AwanAgent
    let turn: AgentTurn
    let isLast: Bool
    let openArtifact: (Artifact) -> Void
    @Local private var expanded = false

    // Reference rhythm: user bubble → 22 → "N progress messages" → 12 → answer → 13 → meta → 7 → chip.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UserBubble(text: turn.displayPrompt, attachments: AgentThreadPage.attachments(in: turn.prompt))
                .padding(.bottom, 13)

            if !turn.progress.isEmpty {
                if turn.status.isActive {
                    ProgressList(items: turn.progress)
                } else {
                    ProgressDisclosure(items: turn.progress, expanded: $expanded)
                }
            }

            switch turn.status {
            case .queued, .starting, .running:
                TypingBubble(turn: turn)
            case .awaitingApproval:
                if let ask = turn.computerUseRequest {
                    AllowCard(agent: agent, request: ask)
                } else {
                    TypingBubble(turn: turn)
                }
            case .completed:
                FinalAnswer(turn: turn)
                artifacts
                if isLast && !turn.nextActions.isEmpty {
                    NextStepsView(steps: turn.nextActions) { step in
                        AgentThreadPage.send(step, to: agent.slug, provenance: "The user tapped a suggested next step under your last reply.")
                    }
                    .padding(.top, -5)
                }
            case .failed:
                TurnErrorView(turn: turn) {
                    let why = turn.progress.isEmpty
                        ? "The user tapped Retry. The last attempt failed before it could start, so do the task now."
                        : "The user tapped Retry. The last attempt failed partway through: check what already exists, then finish only what is missing."
                    AgentStore.shared.send(why + "\n\n" + turn.prompt, to: agent.slug, display: turn.displayPrompt, source: "home")
                }
            case .interrupted:
                if let text = turn.finalText, !text.isEmpty { FinalAnswer(turn: turn) }
                Text("Stopped. Send another message to keep going.")
                    .font(.awan(12.5, .medium)).foregroundStyle(Theme.textTertiary)
                artifacts
            }
        }
    }

    @ViewBuilder private var artifacts: some View {
        if !turn.artifacts.isEmpty {
            FlowLayout(spacing: 12) {
                ForEach(turn.artifacts) { a in ArtifactCard(artifact: a, open: openArtifact) }
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - Composer

/// Draft, attachments and keyboard handling for the composer (a class so the AppKit key monitor
/// always sees the live values).
@MainActor
final class ComposerModel: ObservableObject {
    @Published var draft = ""
    @Published var attachments: [String] = []
    var isFocused = false
    private(set) var slug = ""
    private var monitor: Any?

    func attach(slug: String) {
        self.slug = slug
        draft = AgentStore.shared.thread(slug).draft
        guard monitor == nil, !HomeUI.isSnapshot else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.isFocused else { return e }
            if e.keyCode == 36 || e.keyCode == 76 {   // return / enter
                if e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.option) {
                    self.draft += "\n"
                } else {
                    self.submit()
                }
                return nil
            }
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "v", self.pasteFiles() { return nil }
            return e
        }
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard !slug.isEmpty, AgentStore.shared.agent(slug) != nil, AgentStore.shared.thread(slug).draft != draft else { return }
        let d = draft
        AgentStore.shared.updateThread(slug) { $0.draft = d }
    }

    func add(_ paths: [String]) {
        for p in paths where !attachments.contains(p) { attachments.append(p) }
    }

    func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        AgentThreadPage.send(text, attachments: attachments, to: slug)
        draft = ""
        attachments = []
    }

    /// ⌘V with files (or a copied image) on the pasteboard attaches them instead of pasting text.
    func pasteFiles() -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls.map(\.path))
            return true
        }
        let hasText = pb.string(forType: .string) != nil
        if !hasText, let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
           let agent = AgentStore.shared.agent(slug) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let url = agent.workspace.appendingPathComponent("tmp/Pasted image \(f.string(from: Date())).png")
            if (try? png.write(to: url)) != nil {
                add([url.path])
                return true
            }
        }
        return false
    }
}


/// Bottom of the thread (reference, column-local): the Awan sitting on the 300×43 talk pill at x=13,
/// 30 above the bottom; the 148×43 outlined "Type…" capsule 12 to its right (grows on focus);
/// "Release to send" 12 semibold at x=29 under the pill; a stop button while it works.
private struct ThreadComposer: View {
    let agent: AwanAgent
    @ObservedObject var model: ComposerModel
    let running: Bool
    let stop: () -> Void
    @EnvironmentObject var companion: CompanionEngine
    @FocusState private var focused: Bool

    private var expanded: Bool { focused || !model.draft.isEmpty || !model.attachments.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !model.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.attachments, id: \.self) { path in
                        AttachmentChip(path: path) { model.attachments.removeAll { $0 == path } }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 325)
                .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HoldToTalkPill(idleTitle: "Hold \(HomeUI.talkKeys) to talk", width: 300, height: 43, agentSlug: agent.slug)
                        .peeking(agent.character, mood: companion.voiceState.mood, width: 96, x: -20, sink: -3)
                    Text("Release to send")
                        .font(.awan(10, .semibold)).foregroundStyle(HomeColor.tertiary)
                        .frame(height: 13)
                        .padding(.leading, 16)
                }
                typeField
                    .padding(.bottom, 20)
                Spacer(minLength: 0)
                if running {
                    Button(action: stop) {
                        RoundedRectangle(cornerRadius: 2.5).fill(Theme.ink).frame(width: 10, height: 10)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(LinearGradient(colors: [.white, Theme.bone], startPoint: .top, endPoint: .bottom)))
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 1))
                            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                    .padding(.bottom, 25.5)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 22)
        .padding(.bottom, 10)
        .animation(Theme.snappy, value: expanded)
        .animation(Theme.snappy, value: running)
        .onChange(of: focused) { _, f in model.isFocused = f }
    }

    private var typeField: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Image(systemName: "keyboard").font(.system(size: 14, weight: .regular)).foregroundStyle(HomeColor.tertiary)
                .padding(.bottom, 14)
            TextField(expanded ? "Message \(agent.name)…" : "Type…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.awan(13.5))
                .foregroundStyle(Theme.text)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.vertical, 12)
                .onSubmit { model.submit() }
            if expanded && (!model.draft.isEmpty || !model.attachments.isEmpty) {
                Button { model.submit() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 11.5, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 29, height: 29)
                        .background(Circle().fill(Theme.bone))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 7)
                .help("Send")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 7)
        .frame(minHeight: 43)
        .frame(width: expanded ? nil : 148)
        .frame(maxWidth: expanded ? 420 : 148)
        .background(Capsule().fill(Color.white.opacity(0.004)))
        .overlay(Capsule().strokeBorder(focused ? HomeColor.secondary : HomeColor.outline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 21.5))
        .onTapGesture { focused = true }
        .accessibilityLabel("Type a message to \(agent.name)")
    }
}
