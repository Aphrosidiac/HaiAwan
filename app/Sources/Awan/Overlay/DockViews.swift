import AppKit
import SwiftUI

// MARK: - Status

/// What an Awan is doing, as the dock shows it.
enum DockAgentStatus: Equatable {
    case working, done, needsYou, stopped, ready

    static func of(_ thread: AgentThread) -> DockAgentStatus {
        if let active = thread.activeTurn {
            return active.status == .awaitingApproval || active.computerUseRequest != nil ? .needsYou : .working
        }
        guard let last = thread.turns.last else { return .ready }
        switch last.status {
        case .completed: return .done
        case .failed: return .needsYou
        case .interrupted: return .stopped
        default: return .ready
        }
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .done: return "Done"
        case .needsYou: return "Needs you"
        case .stopped: return "Stopped"
        case .ready: return "Ready"
        }
    }

    func color(hue: Double) -> Color {
        switch self {
        case .working: return Theme.lime
        case .done: return Color.pastel(hue: hue, saturation: 0.42, brightness: 0.98)
        case .needsYou: return Theme.warning
        case .stopped, .ready: return Theme.textTertiary
        }
    }
}

// MARK: - Pill

/// Reference: a 40×18 dark capsule holding only a small chevron in the buddy colour (7×4 pt), with
/// a soft glow of that colour. Awan keeps "Open Home" on the pill's context menu.
struct DockPillView: View {
    @ObservedObject var dock: DockController
    @ObservedObject private var store = AgentStore.shared
    @ObservedObject private var prefs = Prefs.shared
    @Local private var hovering = false

    var body: some View {
        let accent = prefs.cursorColor.color
        Button { dock.toggleExpanded() } label: {
            DockChevron(up: dock.expanded)
                .stroke(accent, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 5.5, height: 2.75)
                .frame(width: DockController.pillSize.width, height: DockController.pillSize.height)
                .background(Capsule().fill(hovering ? Color(hex: 0x202532) : Color(hex: 0x171B24)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(hovering ? 0.14 : 0.07), lineWidth: 0.5))
                .overlay(alignment: .topTrailing) {
                    if !dock.expanded && (store.unreadCount > 0 || !store.runningAgents.isEmpty) {
                        Circle().fill(accent).frame(width: 6, height: 6).offset(x: 1, y: -1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .shadow(color: accent.opacity(0.35), radius: 6)
        .onHover { hovering = $0 }
        .help(dock.expanded ? "Hide Awans" : "Show Awans")
        .contextMenu {
            Button("Open Home") { AppState.shared.openHome() }
        }
    }
}

/// The pill's chevron (^ while the stack is open, v while closed).
private struct DockChevron: Shape {
    var up: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let (a, b) = up ? (rect.maxY, rect.minY) : (rect.minY, rect.maxY)
        p.move(to: CGPoint(x: rect.minX, y: a))
        p.addLine(to: CGPoint(x: rect.midX, y: b))
        p.addLine(to: CGPoint(x: rect.maxX, y: a))
        return p
    }
}

// MARK: - Bubble stack

struct DockStackView: View {
    @ObservedObject var dock: DockController
    @ObservedObject private var store = AgentStore.shared

    var body: some View {
        VStack(alignment: .center, spacing: DockController.bubbleGap) {
            if dock.stackSlugs.isEmpty {
                Text("No Awans busy")
                    .font(.awan(11.5, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(Color(hex: 0x161615).opacity(0.97)))
                    .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
            }
            ForEach(dock.stackSlugs, id: \.self) { slug in
                if dock.cardSlug == slug, dock.cardContentHeight > DockController.bubbleSize {
                    // The hover card grew out of this portrait and covers its slot (it lives in its own panel).
                    Color.clear.frame(width: DockController.bubbleSize, height: dock.cardContentHeight)
                } else if let agent = store.agent(slug) {
                    DockBubble(agent: agent, thread: store.thread(slug), highlighted: dock.cardSlug == slug)
                        .onHover { dock.bubbleHover(slug, $0) }
                        .onTapGesture { AppState.shared.openAgent(slug) }
                }
            }
        }
        .padding(DockController.stackPadding)
        .animation(Theme.spring, value: dock.stackSlugs)
        .animation(Theme.spring, value: dock.cardSlug)
    }
}

/// One round agent portrait (reference: 40 pt, thin light ring, soft glow in the character's colour,
/// an 8 pt accent dot over the top-right edge when unread). Running: a lime arc orbits it.
struct DockBubble: View {
    let agent: AwanAgent
    let thread: AgentThread
    var highlighted = false
    var animated = true
    @Local private var spin = false
    @Local private var hovering = false

    var body: some View {
        let status = DockAgentStatus.of(thread)
        let size = DockController.bubbleSize
        ZStack {
            AgentAvatar(appearance: agent.character, size: size, mood: status == .working ? .running : (thread.unread ? .happy : .idle))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .shadow(color: Color.pastel(hue: agent.baseHue, saturation: 0.45, brightness: 0.95).opacity(0.55), radius: 7)
            if status == .working {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Theme.lime, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: size + 7, height: size + 7)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .shadow(color: Theme.lime.opacity(0.7), radius: 4)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if thread.unread || status == .needsYou {
                Circle()
                    .fill(status == .needsYou ? Theme.warning : Prefs.shared.cursorColor.color)
                    .frame(width: 8, height: 8)
                    .offset(x: 1, y: 1)
            }
        }
        .scaleEffect(highlighted || hovering ? 1.08 : 1)
        .animation(Theme.snappy, value: hovering)
        .animation(Theme.snappy, value: highlighted)
        .onHover { hovering = $0 }
        .contentShape(Circle())
        .onAppear {
            guard animated else { return }
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

// MARK: - Hover card

struct DockCardRoot: View {
    @ObservedObject var dock: DockController

    var body: some View {
        Group {
            if let slug = dock.cardSlug {
                AgentHoverCard(slug: slug,
                               onOpen: { AppState.shared.openAgent(slug); dock.closeCard() },
                               onClose: { dock.closeCard() },
                               onEngage: { dock.setEngaged($0) },
                               onLayoutChange: { dock.relayoutSoon() })
                    .id(slug)
                    .onHover { dock.cardHover($0) }
            }
        }
        .padding(DockController.margin)
        .fixedSize()
    }
}

/// The agent card shown when hovering a docked bubble: who, status, summary, files, suggested
/// next steps, hold-to-talk follow-up, a type field and earlier turns.
struct AgentHoverCard: View {
    let slug: String
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}
    var onEngage: (Bool) -> Void = { _ in }
    /// The card changed height (history opened/closed) — its panel re-fits.
    var onLayoutChange: () -> Void = {}
    @ObservedObject private var store = AgentStore.shared
    @Local private var historyOpen = false
    @Local private var draft = ""
    @Local private var holding = false
    @FocusState private var typing: Bool

    // Reference card (dock-hovercard-win.png): 272 wide, radius ≈20, opaque #262525, padding
    // 12 / 11 / 10 / 11; header 40 pt portrait; summary 13 semibold on a 15 pt pitch; file pile
    // ≈52×61 tilted; "Suggested next:" 12 + 21 pt chips; Follow up 122×37 + Type 121×36; History.
    static let width: CGFloat = 272

    var body: some View {
        if let agent = store.agent(slug) {
            let thread = store.thread(slug)
            let status = DockAgentStatus.of(thread)
            let latest = thread.activeTurn ?? thread.turns.last
            VStack(alignment: .leading, spacing: 0) {
                header(agent, status)
                Text(summary(thread, status))
                    .font(.awan(13, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                let files = latest?.artifacts ?? []
                if !files.isEmpty { filePile(files).padding(.top, 14) }
                let next = (status == .working ? [] : (thread.lastCompleted?.nextActions ?? []))
                if !next.isEmpty { suggested(next).padding(.top, 14) }
                actions.padding(.top, 12)
                history(thread).padding(.top, 9)
            }
            .padding(.leading, 12)
            .padding(.trailing, 11)
            .padding(.top, 10)
            .padding(.bottom, 11)
            .frame(width: Self.width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0x262525)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
            .onChange(of: draft.isEmpty) { _, empty in onEngage(!empty || holding) }
        }
    }

    // Header: portrait, name, status; Open and × on the right.
    private func header(_ agent: AwanAgent, _ status: DockAgentStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(appearance: agent.character, size: 40, mood: status == .working ? .running : .happy)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name)
                    .font(.awan(15, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    StatusDot(color: status.color(hue: agent.baseHue), pulsing: status == .working)
                    Text(status.label)
                        .font(.awan(12.5, .semibold))
                        .foregroundStyle(status.color(hue: agent.baseHue))
                }
            }
            .frame(height: 40)
            Spacer(minLength: 6)
            Button("Open", action: onOpen)
                .buttonStyle(.gel(.dark, height: 24, padding: 10, fontSize: 12.5))
            CircleIconButton(systemName: "xmark", size: 26, filled: true, help: "Close", action: onClose)
                .padding(.top, -1)
        }
    }

    private func summary(_ thread: AgentThread, _ status: DockAgentStatus) -> String {
        switch status {
        case .working:
            let active = thread.activeTurn
            if let line = active?.progress.last(where: { $0.kind == .commentary })?.text { return line }
            return active?.statusLine ?? "On it — I'll ping you when it's ready."
        case .needsYou:
            let t = thread.activeTurn ?? thread.turns.last
            return t?.computerUseRequest ?? t?.errorText ?? "I need a quick go-ahead from you."
        case .done:
            let t = thread.lastCompleted
            return t?.summary ?? t?.finalText.map(Self.firstSentence) ?? "All done."
        case .stopped:
            return "Stopped before finishing. Send a follow-up and I'll pick it back up."
        case .ready:
            return store.agent(slug)?.oneLiner ?? ""
        }
    }

    private static func firstSentence(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = trimmed.range(of: ". ") { return String(trimmed[..<r.lowerBound]) + "." }
        return trimmed
    }

    // "1 file · Click to open" with a small tilted pile of thumbnails.
    private func filePile(_ files: [Artifact]) -> some View {
        Button {
            if let first = files.first { NSWorkspace.shared.open(first.url) }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    ForEach(Array(files.prefix(3).enumerated().reversed()), id: \.element.id) { i, file in
                        ArtifactThumb(artifact: file, size: 50)
                            .rotationEffect(.degrees([-5, 6, -11][i]))
                            .offset(x: CGFloat(i) * 4, y: CGFloat(i) * -2)
                            .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
                    }
                }
                .frame(width: 58, height: 62)
                VStack(alignment: .leading, spacing: 2) {
                    Text(files.count == 1 ? "1 file" : "\(files.count) files")
                        .font(.awan(14, .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Click to open")
                        .font(.awan(12.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(files.first?.name ?? "")
    }

    private func suggested(_ next: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Suggested next:")
                .font(.awan(12, .semibold))
                .foregroundStyle(Theme.textTertiary)
            ForEach(next.prefix(4), id: \.self) { chip in
                SuggestionChip(title: chip) {
                    AgentStore.shared.send(chip, to: slug, source: "dock")
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 5.5) {
            HoldToTalkButton(holding: $holding) { down in
                if down {
                    CompanionEngine.shared.beginListening(target: slug)
                } else {
                    CompanionEngine.shared.endListening()
                }
                onEngage(down || !draft.isEmpty)
            }
            HStack(spacing: 7) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                TextField("", text: $draft, prompt: Text("Type…").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(.awan(13.5, .medium))
                    .foregroundStyle(Theme.text)
                    .focused($typing)
                    .onSubmit(send)
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Capsule().fill(Color.white.opacity(draft.isEmpty ? 0.04 : 0.08)))
            .overlay(Capsule().strokeBorder(!draft.isEmpty ? Theme.lime.opacity(0.6) : Theme.strokeStrong, lineWidth: 1))
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        AgentStore.shared.send(text, to: slug, source: "dock")
        draft = ""
        typing = false
    }

    @ViewBuilder private func history(_ thread: AgentThread) -> some View {
        let earlier = Array(thread.turns.dropLast().reversed().prefix(6))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button {
                    historyOpen.toggle()
                    onLayoutChange()
                } label: {
                    HStack(spacing: 3) {
                        Text("History")
                        Image(systemName: historyOpen ? "chevron.up" : "chevron.down").font(.system(size: 8.5, weight: .bold))
                    }
                    .font(.awan(11.5, .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if historyOpen {
                if earlier.isEmpty {
                    Text("Nothing earlier yet.")
                        .font(.awan(12))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(earlier) { turn in
                        Button(action: onOpen) {
                            HStack(spacing: 7) {
                                Circle().fill(turn.status == .completed ? Theme.success : turn.status.isActive ? Theme.lime : Theme.textTertiary)
                                    .frame(width: 5, height: 5)
                                Text(turn.doneTitle ?? turn.displayPrompt)
                                    .font(.awan(12.5, .medium))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(Self.ago(turn.completedAt ?? turn.startedAt))
                                    .font(.awan(11))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private static func ago(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct StatusDot: View {
    var color: Color
    var pulsing: Bool
    @Local private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(pulsing && on ? 0.35 : 1)
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever()) { on = true }
            }
    }
}

/// Compact chip for a suggested next step.
struct SuggestionChip: View {
    let title: String
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.awan(12, .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .padding(.horizontal, 8.5)
                .frame(height: 21)
                .background(Capsule().fill(hovering ? Theme.cardRaised : Color(hex: 0x2B2A27)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// "Follow up": hold to talk to this Awan (a lime gel pill that reacts to the press).
struct HoldToTalkButton: View {
    @Binding var holding: Bool
    var onChange: (Bool) -> Void
    @Local private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: holding ? "waveform" : "mic.fill")
                .font(.system(size: 13, weight: .semibold))
            Text(holding ? "Listening…" : "Follow up")
                .font(.awan(14.5, .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity)
        .frame(height: 37)
        .background(Capsule().fill(LinearGradient(colors: [Color(hex: 0xEAFF8C), Theme.lime, Theme.limeDeep], startPoint: .top, endPoint: .bottom)))
        .overlay(Capsule().strokeBorder(Color(hex: 0x8FB000).opacity(0.6), lineWidth: 1))
        .overlay(alignment: .top) {
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(height: 17)
                .padding(.horizontal, 8)
                .padding(.top, 1.5)
                .allowsHitTesting(false)
        }
        .shadow(color: Theme.lime.opacity(holding ? 0.55 : 0.28), radius: holding ? 12 : 6, y: 3)
        .scaleEffect(holding ? 0.97 : (hovering ? 1.015 : 1))
        .animation(Theme.snappy, value: holding)
        .animation(Theme.snappy, value: hovering)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !holding else { return }
                    holding = true
                    onChange(true)
                }
                .onEnded { _ in
                    holding = false
                    onChange(false)
                }
        )
        .help("Hold to talk to this Awan")
    }
}
