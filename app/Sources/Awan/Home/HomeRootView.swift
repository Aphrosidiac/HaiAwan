import SwiftUI

/// Home: sidebar (roster / settings nav) + the page. Overlays: paywall, character editor, toast.
/// Geometry follows the reference AX frames: sidebar 255 wide in the attached
/// panel (327 popped out), page column on #1E1E1D under a black top fade.
struct HomeRootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.homeIsDetached) private var detached
    @Environment(\.homeLayout) private var layout

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if !state.sidebarCollapsed && !state.homePage.hidesSidebar {
                    Group {
                        if case .settings = state.homePage {
                            SettingsSidebar()
                        } else {
                            HomeSidebar()
                        }
                    }
                    .frame(width: state.homePage.isSettings ? SettingsStyle.sidebarWidth : layout.sidebarWidth)
                    .background(HomeColor.body)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    CollapsedRail()
                        .frame(width: CollapsedRail.width)
                        .background(HomeColor.body)
                        .transition(.opacity)
                }
                ZStack(alignment: .topTrailing) {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !inspectorCoversButtons {
                        WindowButtons()
                            .padding(.top, layout.headerTop)
                            .padding(.trailing, 28)
                    }
                    // With the rail, Upgrade moves into the page header (reference x=9 of the column).
                    if state.sidebarCollapsed && state.plan.isFree && state.homePage == .home {
                        UpgradePill { state.presentPaywall(.homeUpgradeButton) }
                            .padding(.top, layout.headerTop)
                            .padding(.leading, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(alignment: .top) {
                    ZStack(alignment: .top) {
                        HomeColor.content
                        HomeTopFade().frame(height: 145)
                    }
                }
            }

            if let slug = state.characterEditorSlug {
                // Explicit z-order so the removal animates too (ZStack drops unordered removals at once).
                Color.black.opacity(0.35).ignoresSafeArea().onTapGesture {}
                    .transition(.opacity).zIndex(10)
                CharacterEditorView(slug: slug)
                    .padding(detached ? 24 : 12)
                    .transition(.opacity)
                    .zIndex(11)
            }

            // The paywall is its own centred window (PaywallWindowController), like the reference.

            if let toast = state.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.awan(13, .medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(Color(hex: 0x2C2C29)))
                        .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                        .padding(.bottom, 22)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .background(HomeColor.body)
        .overlay { CharacterHeroLayer().zIndex(20) }
        .coordinateSpace(name: "homeRoot")
        .preferredColorScheme(.dark)
        .animation(Theme.spring, value: state.sidebarCollapsed)
        .animation(CharacterHero.spring, value: state.characterEditorSlug)
    }

    /// The inspector slides over the page's top-right corner, window buttons included (reference).
    private var inspectorCoversButtons: Bool {
        if case .agent = state.homePage { return state.inspectorOpen }
        return false
    }

    @ViewBuilder private var detail: some View {
        switch state.homePage {
        case .home:
            HomeEmptyView()
        case .suggestions:
            SuggestionsPage()
        case let .agent(slug):
            AgentThreadPage(slug: slug)
                .id(slug)
        case .newAwan:
            NewAwanPage()
        case let .settings(section):
            SettingsPage(section: section)
        case .referral:
            ScrollView { ReferralPage().padding(28) }
        case .skills:
            SkillsPage()
        }
    }
}

/// Black at the top of the page column fading to the body colour by y≈145 (measured alpha ramp,
/// the same in the attached panel and the pop-out). Content scrolls under it.
struct HomeTopFade: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 30 / 145),
            .init(color: .black.opacity(0.80), location: 40 / 145),
            .init(color: .black.opacity(0.67), location: 50 / 145),
            .init(color: .black.opacity(0.57), location: 60 / 145),
            .init(color: .black.opacity(0.50), location: 70 / 145),
            .init(color: .black.opacity(0.30), location: 90 / 145),
            .init(color: .black.opacity(0.17), location: 110 / 145),
            .init(color: .black.opacity(0.03), location: 130 / 145),
            .init(color: .black.opacity(0), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
    }
}

/// Top-right: pop out to a window (picture-in-picture icon) and close. Two bare 30×30 icons, no
/// circles (reference #78787A).
struct WindowButtons: View {
    @EnvironmentObject var state: AppState
    @Environment(\.homeIsDetached) private var detached
    var body: some View {
        HStack(spacing: 0) {
            BareIconButton(systemName: detached ? "pip.enter" : "pip.exit", size: 15, weight: .regular, color: HomeColor.windowIcon,
                           help: detached ? "Move back to the notch" : "Open as a window") {
                HomeWindowController.shared.setDetached(!detached)
            }
            BareIconButton(systemName: "xmark", size: 15, weight: .regular, color: HomeColor.windowIcon, help: "Close") {
                state.closeHome()
            }
        }
    }
}

/// A 30×30 hit area with a plain SF Symbol (brightens on hover).
struct BareIconButton: View {
    let systemName: String
    var size: CGFloat = 14
    var weight: Font.Weight = .regular
    var color: Color = HomeColor.icon
    var box: CGSize = CGSize(width: 30, height: 30)
    var iconOffset: CGFloat = 0
    var help: String = ""
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(hovering ? Theme.text : color)
                .offset(x: iconOffset)
                .frame(width: box.width, height: box.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Sidebar

struct HomeSidebar: View {
    @EnvironmentObject var state: AppState
    @Environment(\.homeLayout) private var layout
    @Local private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: 31)
                .padding(.top, layout.headerTop)

            searchRow
                .padding(.top, layout.searchTop - layout.headerTop - 31)

            list
                .padding(.top, layout.listTop - layout.searchTop - 30)

            footer
        }
    }

    // Glyph button 44×30 at x=18; Upgrade gel right-aligned 18 from the sidebar edge (empty Home only).
    private var header: some View {
        HStack(spacing: 0) {
            Button { state.homePage = .home } label: {
                AwanGlyph(color: Theme.bone).frame(width: 28)
                    .frame(width: 44, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Awan Home")
            Spacer(minLength: 0)
            if state.plan.isFree && state.homePage == .home {
                UpgradePill { state.presentPaywall(.homeUpgradeButton) }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 18)
    }

    // Collapse 32×30 at x=18 · field 140×31 at x=58 · + 30×30 at x=207 (attached); the field stretches in the pop-out.
    private var searchRow: some View {
        HStack(spacing: 0) {
            BareIconButton(systemName: "sidebar.left", size: 17, weight: .regular, color: HomeColor.secondary,
                           box: CGSize(width: 32, height: 30), iconOffset: 4, help: "Collapse sidebar") { state.sidebarCollapsed = true }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(HomeColor.secondary)
                TextField("", text: $search)
                    .textFieldStyle(.plain)
                    .font(.awan(13))
                    .background(alignment: .leading) {
                        if search.isEmpty {
                            Text("Search").font(.awan(13)).foregroundStyle(HomeColor.placeholder).offset(x: -1).allowsHitTesting(false)
                        }
                    }
                    .foregroundStyle(Theme.text)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(HomeColor.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: 31)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HomeColor.field))
            .padding(.leading, 8)
            .accessibilityLabel("Search Awans")
            Button { state.homePage = .newAwan } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeColor.title)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HomeColor.field))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Awan")
            .padding(.leading, 8)
        }
        .frame(height: 30)
        .padding(.leading, 18)
        .padding(.trailing, 18)
    }

    private var list: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: layout.rowSpacing) {
                if search.isEmpty && !state.suggestions.isEmpty {
                    SidebarRow(
                        selected: state.homePage == .suggestions,
                        leading: AnyView(SuggestionsBadge(size: layout.avatar)),
                        title: "Suggestions", badge: state.suggestions.count,
                        time: state.suggestionsCheckedAt.map(NotchPeekView.time),
                        subtitle: state.suggestions.first?.title ?? "", unread: false, running: false,
                        height: layout.rowHeight + (layout.detached ? 0 : 2), divider: false
                    ) { state.homePage = .suggestions }
                    .padding(.bottom, 14 - layout.rowSpacing)
                }
                let agents = filteredAgents
                ForEach(Array(agents.enumerated()), id: \.element.slug) { i, agent in
                    let t = state.agents.thread(agent.slug)
                    let selected = state.homePage == .agent(agent.slug)
                    let nextSelected = i + 1 < agents.count && state.homePage == .agent(agents[i + 1].slug)
                    SidebarRow(
                        selected: selected,
                        leading: AnyView(AgentAvatar(appearance: agent.character, size: layout.avatar, mood: t.activeTurn != nil ? .running : .idle)),
                        title: agent.name, badge: nil,
                        time: t.turns.isEmpty ? nil : t.lastActivityAt.map { t.activeTurn != nil ? "Now" : NotchPeekView.time($0) },
                        subtitle: subtitle(agent, t), unread: t.unread, running: t.activeTurn != nil,
                        height: layout.rowHeight, divider: !selected && !nextSelected
                    ) { state.openAgent(agent.slug) }
                    .contextMenu {
                        Button(agent.pinned ? "Unpin" : "Pin") { state.agents.togglePin(agent.slug) }
                        Button("Edit character…") { CharacterHero.open(agent.slug) }
                        Button("Reveal workspace in Finder") { NSWorkspace.shared.activateFileViewerSelecting([agent.workspace]) }
                        Divider()
                        Button("Archive", role: .destructive) { state.agents.archive(agent.slug); if state.homePage == .agent(agent.slug) { state.homePage = .home } }
                    }
                }
                if agents.isEmpty && !search.isEmpty {
                    Text("No Awans match “\(search)”").font(.awan(12.5)).foregroundStyle(HomeColor.secondary).padding(.top, 20)
                }
                if search.isEmpty {
                    SkillsSidebarEntry()
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 22)
        }
        // The last visible row fades out above the chips (reference: ~34 pt ramp).
        .mask(
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 33)
            }
        )
        .padding(.bottom, 4)
    }

    // Chips 32 tall at x=26 · 10 · divider · 16 · profile (avatar 30) · 20 to the bottom.
    private var footer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ChipButton(title: "Apps", systemImage: "square.grid.2x2", trailingImage: "plus") { state.homePage = .settings(.integrations) }
                    .fixedSize()
                ChipButton(title: "Invite & Earn", systemImage: "gift") { state.homePage = .referral }
                    .fixedSize()
            }
            .fixedSize()
            .frame(width: layout.sidebarWidth - layout.sidebarInset - 18, alignment: .leading)
            .frame(height: 32)
            .padding(.leading, layout.sidebarInset)
            .padding(.trailing, 18)

            Rectangle().fill(HomeColor.footerDivider).frame(height: 1)
                .padding(.leading, layout.sidebarInset)
                .padding(.trailing, layout.detached ? 19 : 18)
                .padding(.top, 10)

            ProfileRow()
                .padding(.leading, layout.sidebarInset)
                .padding(.trailing, 18)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
    }

    private var filteredAgents: [AwanAgent] {
        let all = state.agents.visibleAgents
        guard !search.isEmpty else { return all }
        let q = search.lowercased()
        return all.filter {
            $0.name.lowercased().contains(q) || $0.roleText.lowercased().contains(q) ||
            state.agents.thread($0.slug).turns.contains { $0.displayPrompt.lowercased().contains(q) || ($0.finalText ?? "").lowercased().contains(q) }
        }
    }

    private func subtitle(_ a: AwanAgent, _ t: AgentThread) -> String {
        if let active = t.activeTurn { return active.statusLine ?? "Sending your message…" }
        if let last = t.turns.last { return last.summary ?? last.finalText?.components(separatedBy: "\n").first ?? last.displayPrompt }
        return a.oneLiner
    }
}

/// Collapsed sidebar: a 91 pt icon rail (reference home-collapsed): glyph, expand, then 50×50 buttons
/// for search, new, Suggestions and each Awan's avatar at a 56 pt pitch, and apps / invite / settings
/// pinned to the bottom (14 above the panel edge).
struct CollapsedRail: View {
    static let width: CGFloat = 91
    @EnvironmentObject var state: AppState
    @Environment(\.homeLayout) private var layout

    var body: some View {
        VStack(spacing: 0) {
            Button { state.homePage = .home } label: {
                AwanGlyph(color: Theme.bone).frame(width: 26).frame(width: 44, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Awan Home")
            .padding(.top, layout.headerTop)
            BareIconButton(systemName: "sidebar.left", size: 17, color: HomeColor.secondary, help: "Expand sidebar") { state.sidebarCollapsed = false }
                .padding(.top, 22)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    RailButton(help: "Search Awans") { state.sidebarCollapsed = false } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .regular)).foregroundStyle(HomeColor.secondary)
                    }
                    RailButton(help: "New Awan") { state.homePage = .newAwan } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeColor.title)
                    }
                    if !state.suggestions.isEmpty {
                        RailButton(selected: state.homePage == .suggestions, help: "Suggestions") { state.homePage = .suggestions } label: {
                            Image(systemName: "sparkles").font(.system(size: 20, weight: .medium)).foregroundStyle(HomeColor.title)
                        }
                    }
                    VStack(spacing: 6) {
                        ForEach(state.agents.visibleAgents) { agent in
                            let t = state.agents.thread(agent.slug)
                            RailButton(selected: state.homePage == .agent(agent.slug), help: agent.name) { state.openAgent(agent.slug) } label: {
                                AgentAvatar(appearance: agent.character, size: 40, mood: t.activeTurn != nil ? .running : .idle)
                                    .overlay(alignment: .bottomTrailing) {
                                        if t.unread || t.activeTurn != nil {
                                            Circle().fill(Theme.lime).frame(width: 11, height: 11)
                                                .overlay(Circle().strokeBorder(HomeColor.body, lineWidth: 2.5))
                                                .offset(x: 2, y: 2)
                                        }
                                    }
                            }
                        }
                    }
                    .padding(.top, -4)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 10)
            .padding(.bottom, 11)
            VStack(spacing: 6) {
                RailButton(help: "Apps") { state.homePage = .settings(.integrations) } label: {
                    Image(systemName: "square.grid.2x2").font(.system(size: 18, weight: .regular)).foregroundStyle(HomeColor.secondary)
                }
                RailButton(help: "Invite & Earn") { state.homePage = .referral } label: {
                    Image(systemName: "gift.fill").font(.system(size: 18, weight: .regular)).foregroundStyle(HomeColor.secondary)
                }
                RailButton(help: "Settings") { state.homePage = .settings(.general) } label: {
                    Image(systemName: "gearshape").font(.system(size: 19, weight: .regular)).foregroundStyle(HomeColor.secondary)
                }
            }
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A 50×50 rail target with a hover / selected well.
struct RailButton<Label: View>: View {
    var selected = false
    var help: String = ""
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: 50, height: 50)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.09) : hovering ? HomeColor.rowHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Lime gel "✦ Upgrade" (reference: a 94×29 gel with a dark rim inside a 101×31 hit area).
struct UpgradePill: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                Text("Upgrade").font(.awan(14, .semibold))
            }
            .foregroundStyle(Theme.ink)
            .frame(width: 94, height: 29)
            .background(LimeGel())
            .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.75), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(width: 101, height: 31)
        .help("Upgrade Awan")
    }
}

/// One roster row: avatar at x=18, title/time on the first line, one-line subtitle, divider under
/// the text (hidden next to the selected row). Selected = bone gel capsule, 239×56 (attached).
struct SidebarRow: View {
    let selected: Bool
    let leading: AnyView
    let title: String
    let badge: Int?
    let time: String?
    let subtitle: String
    let unread: Bool
    let running: Bool
    var height: CGFloat = 56
    var divider = true
    let action: () -> Void
    /// Snapshot hook: draw this row in its hover state.
    static var debugHoverTitle: String? = nil
    @Environment(\.homeLayout) private var layout
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 13.5) {
                ZStack(alignment: .leading) {
                    leading
                    if unread { Circle().fill(Theme.lime).frame(width: 7, height: 7).offset(x: -12) }
                }
                .frame(width: layout.avatar, height: layout.avatar)
                .offset(y: -1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title).font(.awan(13, .semibold)).foregroundStyle(selected ? Theme.ink : HomeColor.title).lineLimit(1)
                        if let badge {
                            Text("\(badge)").font(.awan(12, .bold)).foregroundStyle(selected ? Theme.ink : HomeColor.title)
                                .frame(width: 19, height: 19)
                                .background(Circle().fill(selected ? Color.black.opacity(0.10) : Color.white.opacity(0.08)))
                        }
                        Spacer(minLength: 4)
                        if let time {
                            Text(time).font(.awan(12.5)).foregroundStyle(selected ? Theme.ink.opacity(0.62) : HomeColor.secondary).lineLimit(1).fixedSize()
                        }
                    }
                    Text(subtitle).font(.awan(13)).foregroundStyle(selected ? Theme.ink.opacity(0.72) : HomeColor.secondary).lineLimit(1)
                }
                .padding(.trailing, 23)
            }
            .padding(.leading, 18)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected
                          ? AnyShapeStyle(LinearGradient(colors: [Color.white, Theme.bone, Color(hex: 0xDCD6C6)], startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(hovering || title == Self.debugHoverTitle ? HomeColor.rowHover : Color.clear))
            )
            .overlay {
                if selected {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.ink.opacity(0.55), lineWidth: 1)
                        // the gel's inner bottom highlight
                        Capsule().fill(Color.white.opacity(0.6)).frame(height: 1.5).padding(.horizontal, 12).padding(.bottom, 2.5)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if divider {
                    Rectangle().fill(HomeColor.divider).frame(height: 1)
                        .padding(.leading, 18 + layout.avatar + 13)
                        .padding(.trailing, 24)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Bottom-left: avatar, name, plan + usage ring, ⓘ (shortcuts, opens on hover) and settings.
struct ProfileRow: View {
    @EnvironmentObject var state: AppState
    @Local private var showShortcuts = false

    var body: some View {
        HStack(spacing: 0) {
            Button { state.homePage = .settings(.account) } label: {
                HStack(spacing: 11.5) {
                    UserAvatar(url: state.user?.avatarUrl, name: state.user?.displayName ?? "You", size: 30)
                    VStack(alignment: .leading, spacing: -0.5) {
                        Text(state.user?.displayName ?? "Signed out").font(.awan(13, .semibold)).foregroundStyle(HomeColor.title).lineLimit(1)
                        HStack(spacing: 8) {
                            Text(state.plan.tierName).font(.awan(12)).foregroundStyle(HomeColor.secondary)
                            UsageRing(fraction: state.plan.isFree ? state.plan.usage.messages.fraction : state.plan.usage.agents.fraction)
                                .frame(width: 13, height: 13)
                        }
                    }
                }
                .frame(height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(state.plan.usage.messages.used)/\(state.plan.usage.messages.cap.map(String.init) ?? "∞") talks · \(state.plan.usage.agents.used)/\(state.plan.usage.agents.cap.map(String.init) ?? "∞") agent messages")
            Spacer(minLength: 8)
            BareIconButton(systemName: "info.circle", size: 15, weight: .regular, color: HomeColor.icon, help: "Keyboard shortcuts") { showShortcuts.toggle() }
                .onHover { if $0 { showShortcuts = true } }
                .popover(isPresented: $showShortcuts, arrowEdge: .top) { ShortcutsPopover().environmentObject(state).padding(4) }
                .padding(.trailing, 8)
            BareIconButton(systemName: "gearshape.fill", size: 13, weight: .regular, color: HomeColor.icon, help: "Settings") { state.homePage = .settings(.general) }
        }
    }
}

struct UsageRing: View {
    var fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 2)
            Circle().trim(from: 0, to: max(0.02, fraction)).stroke(fraction > 0.85 ? Theme.warning : Theme.bone, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
        }
    }
}

struct UserAvatar: View {
    var url: String?
    var name: String
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Theme.cardRaised)
            Text(String(name.prefix(1)).uppercased()).font(.awan(size * 0.42, .semibold)).foregroundStyle(Theme.text)
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.clear }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
