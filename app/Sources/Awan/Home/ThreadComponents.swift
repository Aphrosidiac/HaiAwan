import SwiftUI
import AppKit

// Building blocks of an Awan's conversation (AgentThreadPage).

// MARK: - Bubbles

/// iMessage-style bubble with an optional tail at the bottom corner.
struct BubbleShape: Shape {
    var radius: CGFloat = Theme.Radius.bubble
    var tail: Bool
    var trailing: Bool   // user bubbles sit on the right with the tail on the right

    func path(in r: CGRect) -> Path {
        let p = Path(roundedRect: r, cornerRadius: min(radius, r.height / 2), style: .continuous)
        guard tail else { return p }
        // a hooked tail curling off the bottom corner, iMessage-style
        let d: CGFloat = trailing ? -1 : 1
        let x0 = trailing ? r.maxX : r.minX
        var t = Path()
        t.move(to: CGPoint(x: x0 + d * 1, y: r.maxY - 16))
        t.addCurve(to: CGPoint(x: x0 - d * 6, y: r.maxY + 0.5),
                   control1: CGPoint(x: x0 + d * 1, y: r.maxY - 6), control2: CGPoint(x: x0 - d * 2, y: r.maxY - 1))
        t.addCurve(to: CGPoint(x: x0 + d * 15, y: r.maxY - 3),
                   control1: CGPoint(x: x0 + d * 3, y: r.maxY + 1.5), control2: CGPoint(x: x0 + d * 10, y: r.maxY - 0.5))
        t.addLine(to: CGPoint(x: x0 + d * 15, y: r.maxY - 16))
        t.closeSubpath()
        return p.union(t)
    }
}

/// Grey bubble on the left — the Awan talking (intro lines and progress commentary).
/// Reference: fill #3B3B3D, 15 pt text, 12.5 × 6 padding (30 tall for one line, 18 per extra line),
/// radius 15, 2 pt between bubbles of a group, tail on the last.
struct AgentBubble: View {
    let text: String
    var tail = false
    var dimmed = false

    var body: some View {
        Text(MarkdownText.attributed(text))
            .font(.awan(13))
            .foregroundStyle(dimmed ? HomeColor.secondary : HomeColor.title)
            .lineSpacing(2)
            .textSelection(.enabled)
            .padding(.horizontal, 12.5)
            .padding(.vertical, 6)
            .frame(minHeight: 30)
            .background(BubbleShape(radius: 15, tail: tail, trailing: false).fill(HomeColor.bubble))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bone gradient bubble on the right — what the user asked.
struct UserBubble: View {
    let text: String
    var attachments: [String] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(attachments, id: \.self) { path in
                        AttachmentChip(path: path, dark: false)
                    }
                }
            }
            if !text.isEmpty {
                // Reference: blue gel bubble with a 1 pt dark rim, 12.5 × 6.5 padding, radius 17 → bone gel.
                Text(text)
                    .font(.awan(13))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12.5)
                    .padding(.vertical, 6.5)
                    .frame(minHeight: 31)
                    .background(
                        BubbleShape(radius: 17, tail: true, trailing: true)
                            .fill(LinearGradient(colors: [Color.white, Theme.userBubbleTop, Theme.userBubbleBottom], startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Theme.ink.opacity(0.5), lineWidth: 1)
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 482, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The Awan is typing: a bubble of three dots and the live status line under it.
struct TypingBubble: View {
    let turn: AgentTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TypingDots(color: Theme.textSecondary, dot: 7)
                .padding(.horizontal, 15)
                .frame(height: 34)
                .background(BubbleShape(tail: true, trailing: false).fill(Theme.agentBubble))
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text("\(turn.statusLine ?? statusFallback) · \(HomeUI.elapsed(Int(ctx.date.timeIntervalSince(turn.startedAt))))")
                    .font(.awan(12, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 6)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusFallback: String {
        switch turn.status {
        case .queued: return "Sending…"
        case .starting: return "Getting ready"
        default: return "Working on it"
        }
    }
}

/// Centred "Today 2:13 AM".
struct DateSeparator: View {
    let date: Date
    var body: some View {
        Text(HomeUI.separator(date))
            .font(.awan(11.5, .medium))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}

// MARK: - Progress

/// "› 4 progress messages" — what the Awan said and did along the way.
struct ProgressDisclosure: View {
    let items: [ProgressItem]
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(Theme.snappy) { expanded.toggle() } } label: {
                // Reference: chevron at x+4, label at x+20.5, 15 pt #A4A4A4, 16 tall.
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 7)
                    Text(items.count == 1 ? "1 progress message" : "\(items.count) progress messages")
                        .font(.awan(13))
                }
                .padding(.leading, 4)
                .frame(height: 16)
                .foregroundStyle(HomeColor.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                ProgressList(items: items)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Commentary as grey bubbles, commands and file changes as quiet mono rows.
struct ProgressList: View {
    let items: [ProgressItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                switch item.kind {
                case .commentary, .thinking:
                    let nextIsBubble = i + 1 < items.count && [.commentary, .thinking].contains(items[i + 1].kind)
                    AgentBubble(text: item.text, tail: !nextIsBubble, dimmed: item.kind == .thinking)
                        .padding(.bottom, nextIsBubble ? 0 : 4)
                default:
                    ProgressRow(item: item)
                }
            }
        }
    }
}

struct ProgressRow: View {
    let item: ProgressItem
    @Local private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { if item.detail != nil { withAnimation(Theme.snappy) { open.toggle() } } } label: {
                HStack(spacing: 7) {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold)).frame(width: 14)
                    Text(item.text).font(.awanMono(11.5, .regular)).lineLimit(1).truncationMode(.middle)
                    if item.detail != nil {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .foregroundStyle(item.kind == .error ? Theme.danger.opacity(0.85) : Theme.textTertiary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.035)))
            }
            .buttonStyle(.plain)
            .help(item.detail == nil ? item.text : "Show or hide the command and output")
            if open, let detail = item.detail {
                Text(detail).font(.awanMono(11, .regular)).foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: 440, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
            }
        }
        .padding(.leading, 4)
    }

    private var icon: String {
        switch item.kind {
        case .command: return "terminal"
        case .fileChange: return "doc.badge.plus"
        case .toolCall: return "wrench.and.screwdriver"
        case .error: return "exclamationmark.triangle"
        default: return "circle"
        }
    }
}

// MARK: - Final answer

/// Plain markdown answer, then "2m 21s · 2:15 AM" and a copy button.
struct FinalAnswer: View {
    let turn: AgentTurn
    @Local private var copied = false

    var body: some View {
        // Reference: 16 pt answer, 23 pt line pitch, 12 between paragraphs, meta 15 #A4A4A4 13 below,
        // copy button 22×22 10 after the meta.
        VStack(alignment: .leading, spacing: 10) {
            if let text = turn.finalText, !text.isEmpty {
                MarkdownText(source: text, fontSize: 14, color: HomeColor.title, lineSpacing: 5.5, paragraphSpacing: 12)
            }
            HStack(spacing: 10) {
                Text(meta).font(.awan(13)).foregroundStyle(HomeColor.tertiary)
                if let text = turn.finalText, !text.isEmpty {
                    Button {
                        HomeUI.copy(text)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(HomeColor.tertiary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meta: String {
        [turn.durationText, turn.completedAt.map(HomeUI.clock)].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Artifacts

/// A white card with a QuickLook thumbnail — click opens, right-click reveals or copies the path.
struct ArtifactCard: View {
    let artifact: Artifact
    var width: CGFloat = 124
    var open: (Artifact) -> Void
    @Local private var image: NSImage? = nil
    @Local private var hovering = false

    var body: some View {
        Button { open(artifact) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Color(hex: 0xECE8DD)
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: width, height: width * 0.8, alignment: .top)
                            .clipped()
                    } else {
                        Image(systemName: icon).font(.system(size: 24, weight: .regular)).foregroundStyle(Theme.ink.opacity(0.45))
                    }
                }
                .frame(width: width, height: width * 0.8)
                .clipped()
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.name).font(.awan(12, .semibold)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                    Text("\(artifact.kind.label) · Open").font(.awan(11)).foregroundStyle(Theme.ink.opacity(0.5)).lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: width)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(hovering ? 0.45 : 0.3), radius: hovering ? 12 : 6, y: hovering ? 5 : 3)
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(Theme.snappy, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(artifact.path)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(artifact.url) }
            if !artifact.path.hasPrefix("http") {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([artifact.url]) }
            }
            Button(artifact.path.hasPrefix("http") ? "Copy link" : "Copy path") { HomeUI.copy(artifact.path) }
        }
        .task(id: artifact.path) { image = await Thumbnails.shared.thumbnail(for: artifact, side: width * 2) }
    }

    private var icon: String {
        switch artifact.kind {
        case .webPage: return "globe"
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .spreadsheet: return "tablecells"
        case .markdown, .document: return "doc.text"
        case .presentation: return "rectangle.on.rectangle"
        case .folder: return "folder"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        case .other: return "doc"
        }
    }
}

/// A file attached to a message (in the user's bubble or the composer).
struct AttachmentChip: View {
    let path: String
    var dark = true
    var remove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip").font(.system(size: 10, weight: .semibold))
            Text((path as NSString).lastPathComponent).font(.awan(11.5, .medium)).lineLimit(1).truncationMode(.middle)
            if let remove {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)) }
                    .buttonStyle(.plain)
            }
        }
        .foregroundStyle(dark ? Theme.text : Theme.ink)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .frame(maxWidth: 200)
        .background(Capsule().fill(dark ? Theme.cardRaised : Theme.userBubbleBottom))
        .overlay(Capsule().strokeBorder(dark ? Theme.stroke : Color.black.opacity(0.08), lineWidth: 1))
        .help(path)
    }
}

// MARK: - Next steps

struct NextStepsView: View {
    let steps: [String]
    let send: (String) -> Void

    var body: some View {
        // Reference: chips straight under the meta line, no heading.
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 8) {
                ForEach(steps, id: \.self) { step in
                    NextStepChip(title: step) { send(step) }
                }
            }
        }
    }
}

struct NextStepChip: View {
    let title: String
    let action: () -> Void
    @Local private var hovering = false
    var body: some View {
        Button(action: action) {
            // Reference: 26 tall capsule, #333435 fill, 1 pt #4B4B4B rim, 14 semibold, 11 side padding.
            Text(title).font(.awan(11.5, .semibold)).lineLimit(1)
            .foregroundStyle(HomeColor.title)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(hovering ? Theme.cardRaised : HomeColor.chipFill))
            .overlay(Capsule().strokeBorder(HomeColor.chipStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Send to this Awan")
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.init(width: maxW, height: nil))
            if x > 0 && x + size.width > maxW { y += lineH + spacing; x = 0; lineH = 0 }
            x += size.width + spacing
            lineH = max(lineH, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.init(width: bounds.width, height: nil))
            if x > bounds.minX && x + size.width > bounds.maxX { y += lineH + spacing; x = bounds.minX; lineH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .init(size))
            x += size.width + spacing
            lineH = max(lineH, size.height)
        }
    }
}

// MARK: - Failed / stopped

struct TurnErrorView: View {
    let turn: AgentTurn
    let retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.danger)
                Text(turn.errorText ?? "This attempt couldn’t finish. Try again.")
                    .font(.awan(13.5)).foregroundStyle(Theme.text.opacity(0.9))
                    .textSelection(.enabled)
            }
            ChipButton(title: "Retry", systemImage: "arrow.clockwise", action: retry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Computer use approval

/// "<Name> wants to use your Mac" — Allow once / Always allow / Not now.
struct AllowCard: View {
    let agent: AwanAgent
    let request: String
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgentAvatar(appearance: agent.character, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(agent.name) wants to use your Mac").font(.awan(14, .semibold)).foregroundStyle(Theme.text)
                    Text("Needs a yes").font(.awan(11.5)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Image(systemName: "cursorarrow.rays").font(.system(size: 16)).foregroundStyle(Theme.textSecondary)
            }
            Text(MarkdownText.attributed(request))
                .font(.awan(13.5)).foregroundStyle(Theme.text.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Allow once") { state.agents.runner.approveComputerUse(slug: agent.slug, always: false) }
                    .buttonStyle(.gel(.lime, height: 30, padding: 14, fontSize: 12.5))
                Button("Always allow") { state.agents.runner.approveComputerUse(slug: agent.slug, always: true) }
                    .buttonStyle(.gel(.bone, height: 30, padding: 14, fontSize: 12.5))
                Button("Not now") { state.agents.runner.declineComputerUse(slug: agent.slug) }
                    .buttonStyle(.gel(.dark, height: 30, padding: 14, fontSize: 12.5))
            }
            Text("Always allow can be turned off in Settings → Agents.")
                .font(.awan(11)).foregroundStyle(Theme.textTertiary)
        }
        .padding(16)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Suggested asks (a brand-new Awan)

/// Three tilted sticky notes; tapping one sends it.
struct StickyNotes: View {
    let asks: [String]
    let send: (String) -> Void

    static let paper: [(Color, Color)] = [
        (Color(hex: 0xFAD3DE), Color(hex: 0xF4BCCB)),   // pink
        (Color(hex: 0xCFE7F7), Color(hex: 0xB9DBF1)),   // light blue
        (Color(hex: 0xF8EDC8), Color(hex: 0xF0E0AE)),   // cream
    ]
    static let tilt: [Double] = [-2.2, 1.6, -1.2]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(asks.prefix(3).enumerated()), id: \.offset) { i, ask in
                StickyNote(text: ask, paper: Self.paper[i % 3], tilt: Self.tilt[i % 3]) { send(ask) }
            }
        }
    }
}

struct StickyNote: View {
    let text: String
    let paper: (Color, Color)
    let tilt: Double
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Text(text)
                    .font(.awan(13, .medium))
                    .foregroundStyle(Theme.ink.opacity(0.88))
                    .lineSpacing(1.5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.trailing, 6)
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.bone)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.ink))
                    .scaleEffect(hovering ? 1.08 : 1)
            }
            .padding(13)
            .frame(width: 150, height: 138)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(LinearGradient(colors: [paper.0, paper.1], startPoint: .top, endPoint: .bottom))
            )
            .overlay(alignment: .top) {
                // a strip of tape
                Rectangle().fill(Color.white.opacity(0.42)).frame(width: 40, height: 11).offset(y: -5).rotationEffect(.degrees(-tilt * 1.5)).blendMode(.screen)
            }
            .shadow(color: .black.opacity(0.35), radius: hovering ? 10 : 5, x: 0, y: hovering ? 7 : 4)
            .rotationEffect(.degrees(hovering ? 0 : tilt))
            .offset(y: hovering ? -3 : 0)
            .animation(Theme.snappy, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Send task: \(text)")
    }
}
