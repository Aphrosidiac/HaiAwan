import SwiftUI
import AppKit

/// The quick peek's measured layout (the measurements; x from the panel's outer left edge, in points).
enum NotchPeekLayout {
    static let width: CGFloat = 452
    static let shoulder: CGFloat = 6            // concave shoulders: body is 440 wide
    static let bottomRadius: CGFloat = 16
    static let maxHeight: CGFloat = 533         // beyond this the list scrolls
    static let headerHeight: CGFloat = 44       // the list starts here
    static let headerCenterY: CGFloat = 19
    static let rowHeight: CGFloat = 62          // + 1 pt divider = pitch 63
    static let pitch: CGFloat = 63
    static let avatar: CGFloat = 46
    static let avatarTop: CGFloat = 7           // first avatar top at y=51
    static let leftInset: CGFloat = 34          // glyph, avatars, chips
    static let textX: CGFloat = 94.5            // avatar + 14.5
    static let textRight: CGFloat = 415         // time's right edge (31 inside the body edge)
    static let textRightWithFile: CGFloat = 375 // the text column stops short of the file card
    static let dividerRight: CGFloat = 414
    static let hoverInset: CGFloat = 16         // row hover: 10 inside the body edges
    static let footerTop: CGFloat = 14          // list → chips
    static let chipHeight: CGFloat = 32
    static let bottomPadding: CGFloat = 20
    static let listFade: CGFloat = 28
    static var footerHeight: CGFloat { footerTop + chipHeight + bottomPadding }
    static let emptyListHeight: CGFloat = 230

    @MainActor static func rowCount(_ s: AppState) -> Int {
        (s.suggestions.isEmpty ? 0 : 1) + s.agents.visibleAgents.count
    }

    /// Rows are 62 + a 1 pt divider; the last row has no divider.
    static func contentListHeight(rows: Int) -> CGFloat {
        rows == 0 ? emptyListHeight : CGFloat(rows) * pitch - 1
    }

    static func listHeight(rows: Int) -> CGFloat {
        min(contentListHeight(rows: rows), maxHeight - headerHeight - footerHeight)
    }

    static func size(rows: Int) -> CGSize {
        CGSize(width: width, height: headerHeight + listHeight(rows: rows) + footerHeight)
    }

    @MainActor static func size(for s: AppState) -> CGSize { size(rows: rowCount(s)) }
}

/// Quick peek on notch hover (reference v1.0.52): header, Suggestions + every Awan with their
/// newest file, and a footer with Apps, Invite & Earn and Expand Home.
struct NotchPeekView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var notch: NotchController
    @Local private var infoHover = false
    @Local private var popoverHover = false
    @Local private var showShortcuts = false
    @Local private var closeShortcuts: Task<Void, Never>? = nil

    /// Snapshot hooks (headless renders can't hover).
    static var debugHoverRow: Int? = nil
    static var debugShowShortcuts = false

    var body: some View {
        let L = NotchPeekLayout.self
        let rows = L.rowCount(state)
        let overflows = L.contentListHeight(rows: rows) > L.listHeight(rows: rows)
        VStack(spacing: 0) {
            header
                .frame(height: L.headerHeight, alignment: .top)
            ScrollView(showsIndicators: false) {
                list
            }
            .frame(height: L.listHeight(rows: rows))
            .mask {
                // The last visible row fades out above the footer when the list overflows.
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: overflows ? L.listFade : 0)
                }
            }
            footer
                .padding(.top, L.footerTop)
                .padding(.bottom, L.bottomPadding)
        }
        .frame(width: L.width, alignment: .top)
        .background(alignment: .top) { PeekBackground() }
        .overlay(alignment: .topLeading) {
            if showShortcuts || Self.debugShowShortcuts {
                ShortcutsPopover()
                    .onHover { h in popoverHover = h; syncShortcuts() }
                    .offset(x: ShortcutsPopover.x, y: ShortcutsPopover.top)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
            }
        }
    }

    @ViewBuilder private var list: some View {
        // Unread Awans sort to the top, under Suggestions (stable otherwise).
        let all = state.agents.visibleAgents
        let agents = all.filter { state.agents.thread($0.slug).unread } + all.filter { !state.agents.thread($0.slug).unread }
        let hasSuggestions = !state.suggestions.isEmpty
        let total = (hasSuggestions ? 1 : 0) + agents.count
        VStack(spacing: 0) {
            if hasSuggestions {
                PeekRow(
                    leading: AnyView(SuggestionsBadge(size: NotchPeekLayout.avatar)),
                    title: "Suggestions", count: state.suggestions.count,
                    time: state.suggestionsCheckedAt.map(Self.time),
                    subtitle: state.suggestions.first?.title ?? "",
                    files: [], unread: false,
                    showDivider: total > 1, debugHover: Self.debugHoverRow == 0
                ) { state.openHome(.suggestions); notch.closePeek() }
            }
            if total == 0 {
                VStack(spacing: 10) {
                    CloudCreature(appearance: .mascot, mood: .happy, glow: false).frame(width: 64)
                    Text("No Awans yet").font(.awan(14, .semibold)).foregroundStyle(Theme.text)
                    Text("Make one and it'll show up here with its latest files.").font(.awan(12.5)).foregroundStyle(Theme.textSecondary)
                    Button("New Awan") { state.openHome(.newAwan); notch.closePeek() }
                        .buttonStyle(.gel(.lime, height: 30, padding: 16, fontSize: 12.5))
                }
                .frame(maxWidth: .infinity)
                .frame(height: NotchPeekLayout.emptyListHeight)
            }
            ForEach(Array(agents.enumerated()), id: \.element.id) { i, agent in
                let t = state.agents.thread(agent.slug)
                let index = i + (hasSuggestions ? 1 : 0)
                let pile = state.agents.recentArtifacts(for: agent.slug)
                PeekRow(
                    leading: AnyView(AgentAvatar(appearance: agent.character, size: NotchPeekLayout.avatar, mood: t.activeTurn != nil ? .running : .idle)),
                    title: agent.name, count: nil,
                    time: t.lastActivityAt.flatMap { t.turns.isEmpty ? nil : Self.time($0) },
                    subtitle: subtitle(agent, t),
                    files: pile.isEmpty ? (t.artifacts.first.map { [$0] } ?? []) : pile,
                    unread: t.unread,
                    showDivider: index < total - 1, debugHover: Self.debugHoverRow == index
                ) { state.openAgent(agent.slug); notch.closePeek() }
            }
        }
    }

    // Header: glyph at x=34, Upgrade gel 72×25 at x=60.5, then only ⓘ and ⚙ (14 pt glyphs, centres x≈374 / 410).
    private var header: some View {
        HStack(spacing: 0) {
            AwanGlyph(color: Theme.bone).frame(width: 20)
            if state.plan.isFree {
                Button { state.presentPaywall(.notchPeekUpgradeButton); notch.closePeek() } label: {
                    Text("Upgrade").lineLimit(1).fixedSize().frame(width: 72 - 12)
                }
                .buttonStyle(.gel(.lime, height: 25, padding: 6, fontSize: 13))
                .padding(.leading, 6.5)
            }
            Spacer(minLength: 0)
            PeekHeaderIcon(systemName: "info.circle", size: 14.5, help: "Shortcuts", forceHover: Self.debugShowShortcuts) {
                infoHover = true; showShortcutsNow()
            } onHover: { h in infoHover = h; syncShortcuts() }
            PeekHeaderIcon(systemName: "gearshape.fill", size: 13.5, help: "Settings") {
                state.openHome(.settings(.general)); notch.closePeek()
            }
            .padding(.leading, 6)
        }
        .padding(.leading, NotchPeekLayout.leftInset)
        .padding(.trailing, NotchPeekLayout.width - 425.25)
        .frame(height: NotchPeekLayout.headerCenterY * 2)
    }

    /// Footer: chips 32 tall at x=34 (gap 8); Expand Home 115×33, right edge 416.5; 20 below.
    private var footer: some View {
        HStack(spacing: 8) {
            ChipButton(title: "Apps", systemImage: "square.grid.2x2", trailingImage: "plus") { state.openHome(.settings(.integrations)); notch.closePeek() }
                .fixedSize()
            ChipButton(title: "Invite & Earn", systemImage: "gift") { state.openHome(.referral); notch.closePeek() }
                .fixedSize()
            Spacer(minLength: 0)
            Button { state.openHome(); notch.closePeek() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                    Text("Expand Home").font(.awan(13, .semibold)).lineLimit(1).fixedSize()
                }
                .frame(width: 115 - 2 * 6)
            }
            .buttonStyle(.gel(.bone, height: 33, padding: 6, fontSize: 13))
        }
        .padding(.leading, NotchPeekLayout.leftInset)
        .padding(.trailing, NotchPeekLayout.width - 416.5)
        .frame(height: NotchPeekLayout.chipHeight)
    }

    // The shortcuts card opens on hover of ⓘ and closes once the pointer has left both the icon and the card.
    private func showShortcutsNow() {
        closeShortcuts?.cancel(); closeShortcuts = nil
        if !showShortcuts { withAnimation(.easeOut(duration: 0.14)) { showShortcuts = true } }
    }

    private func syncShortcuts() {
        if infoHover || popoverHover { showShortcutsNow(); return }
        closeShortcuts?.cancel()
        closeShortcuts = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))   // lets the pointer cross the 9 pt gap
            guard !Task.isCancelled, !infoHover, !popoverHover else { return }
            withAnimation(.easeOut(duration: 0.12)) { showShortcuts = false }
        }
    }

    private func subtitle(_ a: AwanAgent, _ t: AgentThread) -> String {
        if let active = t.activeTurn { return active.statusLine ?? "Working on it…" }
        if let last = t.turns.last { return last.summary ?? last.finalText?.components(separatedBy: "\n").first ?? last.displayPrompt }
        return a.oneLiner
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "d MMM"
        return f.string(from: d)
    }
}

/// Body #1C1C1B; black from the top to y=30, easing into the body colour by y≈88 (measured curve).
struct PeekBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            Theme.panel
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 30.0 / 88),
                .init(color: .black.opacity(0.96), location: 40.0 / 88),
                .init(color: .black.opacity(0.91), location: 50.0 / 88),
                .init(color: .black.opacity(0.79), location: 60.0 / 88),
                .init(color: .black.opacity(0.50), location: 70.0 / 88),
                .init(color: .black.opacity(0.18), location: 80.0 / 88),
                .init(color: .black.opacity(0), location: 87.0 / 88),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 88)
        }
    }
}

/// ⓘ / ⚙ in the peek header: bare glyphs (bone at 0.88), a faint circle only under the pointer.
struct PeekHeaderIcon: View {
    let systemName: String
    var size: CGFloat = 14
    var help: String = ""
    var forceHover = false
    let action: () -> Void
    var onHover: ((Bool) -> Void)? = nil
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(Theme.bone.opacity(0.88))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(hovering || forceHover ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.1)) { hovering = h }
            onHover?(h)
        }
    }
}

/// One row: 62 tall + a 1 pt divider (pitch 63). Avatar 46 at x=34, text at x=94.5, time right edge at x=415
/// (x=375 when the row has a file card at x≈387→418).
struct PeekRow: View {
    let leading: AnyView
    let title: String
    let count: Int?
    let time: String?
    let subtitle: String
    /// The Awan's newest files: a draggable pile (the newest card on top).
    let files: [Artifact]
    let unread: Bool
    var showDivider = true
    var debugHover = false
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        let L = NotchPeekLayout.self
        let lit = hovering || debugHover
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(lit ? 0.045 : 0))
                    .padding(.horizontal, L.hoverInset)
                Button(action: action) {
                    HStack(alignment: .top, spacing: L.textX - L.leftInset - L.avatar) {
                        leading
                            .frame(width: L.avatar, height: L.avatar)
                            .padding(.top, L.avatarTop)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(title).font(.awan(14, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                if let count { CountBadge(count: count) }
                                Spacer(minLength: 8)
                                if let time { Text(time).font(.awan(13)).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize() }
                            }
                            Text(subtitle).font(.awan(13)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                                .padding(.top, PeekRow.subtitleGap)
                        }
                        .padding(.top, PeekRow.titleTop)
                    }
                    .padding(.leading, L.leftInset)
                    .padding(.trailing, L.width - (files.isEmpty ? L.textRight : L.textRightWithFile) - 1)   // −1: the glyphs' side bearing
                    .frame(width: L.width, height: L.rowHeight, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if unread {
                    // Solid dot ≈8.5 pt, centred at x=24 (10 left of the avatar) on the row's middle.
                    Circle().fill(Theme.lime).frame(width: 8.5, height: 8.5)
                        .position(x: 24, y: L.rowHeight / 2)
                        .allowsHitTesting(false)
                }
                if !files.isEmpty {
                    // Outside the button so each file can be dragged out of the notch.
                    PeekFilePile(files: files)
                        .frame(width: L.width - PeekFilePile.rightInset, height: L.rowHeight, alignment: .trailing)
                }
            }
            .frame(width: L.width, height: L.rowHeight)
            .onHover { h in
                withAnimation(.easeOut(duration: 0.08)) { hovering = h }
                (h ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
            if showDivider {
                Rectangle().fill(Color(hex: 0x3B3B3B))
                    .frame(width: L.dividerRight - 94, height: 1)
                    .padding(.leading, 94)
                    .frame(width: L.width, alignment: .leading)
            }
        }
    }

    /// Instrument Sans metrics tuned so the title's cap top lands at +16.75 and the subtitle's at +35.5.
    static let titleTop: CGFloat = 13
    static let subtitleGap: CGFloat = 1.5
}

/// "3" after "Suggestions": ~19 pt circle, white α0.08, 12 pt bold digit.
struct CountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.awan(12, .bold)).foregroundStyle(Color.white)
            .padding(.horizontal, count > 9 ? 5 : 0)
            .frame(minWidth: 19, minHeight: 19)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

/// The sparkle avatar for the Suggestions row.
struct SuggestionsBadge: View {
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hex: 0xE9FF9A), Theme.lime, Color(hex: 0x9FD6A8)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "sparkles").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(Theme.ink)
        }
        .frame(width: size, height: size)
    }
}

/// Small file thumbnail (QuickLook where possible, kind icon otherwise).
struct ArtifactThumb: View {
    let artifact: Artifact
    var size: CGFloat = 34
    @Local private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2).fill(Color.white)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: Self.icon(for: artifact.kind)).font(.system(size: size * 0.42)).foregroundStyle(Theme.ink.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        .overlay(RoundedRectangle(cornerRadius: size * 0.2).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        .task(id: artifact.path) { image = await Thumbnails.shared.thumbnail(for: artifact, side: size * 3) }
    }

    static func icon(for kind: ArtifactKind) -> String {
        switch kind {
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

/// The ⓘ card: 210×145, warm grey, right edge 16 inside the body edge, top at y=43.
/// "⌨ Shortcuts" + a white Edit gel, a divider, then Talk / Text / Dictate with 17 pt keycaps.
struct ShortcutsPopover: View {
    @EnvironmentObject var state: AppState
    static let size = CGSize(width: 210, height: 145)
    static let top: CGFloat = 43
    static var x: CGFloat { NotchPeekLayout.width - NotchPeekLayout.shoulder - 16 - size.width }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "keyboard").font(.system(size: 11.5, weight: .regular)).foregroundStyle(Theme.text)
                Text("Shortcuts").font(.awan(13, .semibold)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                Button { state.openHome(.settings(.shortcuts)); NotchController.shared.closePeek() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape").font(.system(size: 11.5, weight: .medium))
                        Text("Edit")
                    }
                    .frame(width: 60 - 2 * 7)
                }
                .buttonStyle(.gel(.bone, height: 24, padding: 7, fontSize: 13))
            }
            .padding(.leading, 0)
            .frame(height: 24)
            .padding(.top, 10.5)
            .padding(.trailing, 11.5 - 12)
            Rectangle().fill(Color(hex: 0x52524F)).frame(height: 1)
                .padding(.top, 11.5)
            VStack(alignment: .leading, spacing: 12) {
                row("Talk", state.prefs.shortcuts.talk)
                row("Text", state.prefs.shortcuts.text)
                row("Dictate", state.prefs.shortcuts.dictate)
            }
            .padding(.top, 12)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x3A3A37)))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }

    private func row(_ title: String, _ b: HotkeyBinding) -> some View {
        HStack(spacing: 0) {
            Text(title).font(.awan(13, .semibold)).foregroundStyle(Theme.text)
            Spacer(minLength: 6)
            Text(b.trigger == .doubleTap ? "Double-tap" : "Hold").font(.awan(13)).foregroundStyle(Theme.textSecondary)
                .padding(.trailing, 5)
            HStack(spacing: 4) {
                ForEach(b.displayKeys, id: \.self) { Keycap(label: $0, height: 17, fontSize: 9.5, radius: 4).fixedSize() }
            }
        }
        .frame(height: 17)
    }
}
