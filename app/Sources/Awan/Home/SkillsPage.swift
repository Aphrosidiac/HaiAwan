import SwiftUI

/// Home → Skills: the library, the three active slots, filters, search, detail, create and import.
/// (Reference: Skills Library, "N of 3 skills active", All / Team / My skills, "Create a skill".)
struct SkillsPage: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var store = SkillsStore.shared

    private let columns = [GridItem(.adaptive(minimum: 236, maximum: 400), spacing: 12, alignment: .top)]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    SkillSlotsBar()
                        .padding(.top, 20)
                    filterRow
                        .padding(.top, 22)
                    grid
                        .padding(.top, 14)
                }
                .padding(.horizontal, 28)
                .padding(.top, 30)
                .padding(.bottom, 28)
                .frame(maxWidth: 1100, alignment: .leading)
            }
            ShowSidebarButton().padding(16)

            if let detail = store.detail {
                SkillSheetScrim { store.detail = nil }
                SkillDetailSheet(skill: detail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            if store.showCreate {
                SkillSheetScrim { if store.creating != .writing { store.showCreate = false } }
                CreateSkillSheet()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(Theme.spring, value: store.detail)
        .animation(Theme.spring, value: store.showCreate)
        .task { await store.load() }
        .onChange(of: store.filter) { _, _ in Task { await store.load() } }
        .onChange(of: store.query) { _, _ in store.queryChanged() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Skills Library").font(.awan(22, .semibold)).foregroundStyle(Theme.text)
                Text("Give Awan new ways to help. Active skills shape its answers and guide your Awans.")
                    .font(.awan(13)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button { store.chooseImport() } label: { Label("Import .md", systemImage: "square.and.arrow.down").lineLimit(1).fixedSize() }
                    .buttonStyle(.gel(.dark, height: 32, padding: 14, fontSize: 12.5))
                    .help("Import a SKILL.md file (front matter with a name and a description)")
                Button {
                    if case .done = store.creating { store.creating = .idle }
                    if case .failed = store.creating { store.creating = .idle }
                    store.showCreate = true
                } label: { Label("Create a skill", systemImage: "wand.and.stars").lineLimit(1).fixedSize() }
                    .buttonStyle(.gel(.bone, height: 32, padding: 14, fontSize: 12.5))
            }
            .padding(.trailing, 70) // clear the window buttons
        }
    }

    // MARK: Filters

    private var filterRow: some View {
        HStack(spacing: 10) {
            SkillFilterTabs(selection: $store.filter)
            Spacer(minLength: 8)
            AwanSearchField(placeholder: "Search skills", text: $store.query)
                .frame(width: 220)
        }
    }

    // MARK: Grid

    @ViewBuilder private var grid: some View {
        if store.library.isEmpty {
            emptyState
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(store.library) { s in
                    SkillCard(skill: s)
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: store.filter == .team ? "person.3.fill" : store.filter == .mine ? "wand.and.stars" : "sparkles")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            Text(emptyTitle).font(.awan(14, .semibold)).foregroundStyle(Theme.text)
            Text(emptyBody).font(.awan(12.5)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            if store.loading { ProgressView().controlSize(.small).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    private var emptyTitle: String {
        if !store.query.isEmpty { return "No skills match “\(store.query)”" }
        if let e = store.loadError, state.signInState == .signedIn { return "Couldn't load skills. \(e.prefix(60))" }
        switch store.filter {
        case .all: return state.signInState == .signedIn ? "Loading the library…" : "Sign in to browse skills"
        case .team: return store.teamName == nil ? "You're not in a team yet" : "No team skills yet"
        case .mine: return "You haven't made a skill yet"
        }
    }

    private var emptyBody: String {
        switch store.filter {
        case .all: return "Skills are short playbooks Awan follows when a task fits."
        case .team: return store.teamName == nil ? "Create or join one in Settings → Account, then share skills with everyone on it." : "Share one of your skills from its detail page and it shows up here for everyone on \(store.teamName!)."
        case .mine: return "Brain-dump what you want Awan to be good at and it writes the skill, or import a SKILL.md."
        }
    }
}

// MARK: - Slots

/// "N of 3 skills active" and the three slot chips. In the full-slot state each chip becomes a swap target.
struct SkillSlotsBar: View {
    @ObservedObject private var store = SkillsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(store.activeSlugs.count) of \(SkillsStore.maxActive) skills active")
                    .font(.awan(12.5, .semibold)).foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
                if let incoming = store.swapCandidate {
                    Text("·").foregroundStyle(Theme.textTertiary)
                    Text("All 3 skill slots are full. Tap one to swap it out for \(incoming.title).")
                        .font(.awan(12.5, .medium)).foregroundStyle(Theme.warning)
                    Button("Cancel") { withAnimation(Theme.spring) { store.swapCandidate = nil } }
                        .buttonStyle(.plain).font(.awan(12.5, .semibold)).foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(spacing: 10) {
                ForEach(0 ..< SkillsStore.maxActive, id: \.self) { i in
                    let items = store.activeItems
                    if i < items.count {
                        SlotChip(skill: items[i], swapping: store.swapCandidate != nil)
                    } else {
                        EmptySlotChip()
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(store.swapCandidate != nil ? Theme.warning.opacity(0.45) : Theme.stroke, lineWidth: 1))
    }
}

private struct SlotChip: View {
    let skill: SkillItem
    let swapping: Bool
    @ObservedObject private var store = SkillsStore.shared
    @Local private var hovering = false

    var body: some View {
        Button {
            if swapping { Task { await store.swap(out: skill.slug) } } else { store.open(skill) }
        } label: {
            HStack(spacing: 9) {
                SkillSymbolTile(symbol: skill.symbol, tint: skill.tint, size: 28)
                Text(skill.title).font(.awan(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: swapping ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(swapping ? Theme.warning : Theme.lime)
            }
            .padding(.leading, 6).padding(.trailing, 10)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(hovering ? Theme.cardRaised : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(swapping && hovering ? Theme.warning : Theme.stroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(swapping ? "Swap \(skill.title) out" : skill.oneLiner)
    }
}

private struct EmptySlotChip: View {
    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.strokeStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 28, height: 28)
                .overlay(Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textTertiary))
            Text("Empty slot").font(.awan(12.5, .medium)).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

// MARK: - Filter tabs

struct SkillFilterTabs: View {
    @Binding var selection: SkillFilter
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 2) {
            ForEach(SkillFilter.allCases) { f in
                let on = f == selection
                Button { withAnimation(Theme.snappy) { selection = f } } label: {
                    Text(f.title).font(.awan(12.5, .semibold))
                        .foregroundStyle(on ? Theme.ink : Theme.textSecondary)
                        .padding(.horizontal, 13).frame(height: 28)
                        .background {
                            if on { Capsule().fill(Theme.bone).matchedGeometryEffect(id: "tab", in: ns) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.055)))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

// MARK: - Card

struct SkillSymbolTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.88))
        }
        .frame(width: size, height: size)
    }
}

struct SkillCard: View {
    let skill: SkillItem
    @ObservedObject private var store = SkillsStore.shared
    @Local private var hovering = false

    private var active: Bool { store.isActive(skill) }
    private var waiting: Bool { store.swapCandidate?.slug == skill.slug }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                SkillSymbolTile(symbol: skill.symbol, tint: skill.tint, size: 40)
                Spacer()
                SkillToggleButton(skill: skill)
            }
            Text(skill.title).font(.awan(14.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                .padding(.top, 12)
            Text(skill.oneLiner).font(.awan(12.5)).foregroundStyle(Theme.textSecondary)
                .lineLimit(2, reservesSpace: true)
                .padding(.top, 3)
            HStack(spacing: 6) {
                Text("by \(skill.byline)").font(.awan(11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                if skill.teamShared { SkillBadge(text: "Team") }
                if skill.isMine && !skill.published && !skill.teamShared { SkillBadge(text: "Private") }
                Spacer(minLength: 4)
                Image(systemName: "person.2.fill").font(.system(size: 9.5)).foregroundStyle(Theme.textTertiary)
                Text(skill.usersLabel).font(.awan(11.5)).foregroundStyle(Theme.textTertiary).monospacedDigit()
            }
            .padding(.top, 12)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hovering ? Theme.card : Theme.card.opacity(0.62)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(waiting ? Theme.warning.opacity(0.7) : active ? Theme.lime.opacity(0.45) : Theme.stroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { store.open(skill) }
        .onHover { hovering = $0 }
    }
}

struct SkillBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.awan(10, .bold)).foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6).frame(height: 17)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

/// Activate / Active toggle. Lime is the active state.
struct SkillToggleButton: View {
    let skill: SkillItem
    var large = false
    @ObservedObject private var store = SkillsStore.shared
    @Local private var busy = false

    var body: some View {
        let active = store.isActive(skill)
        let waiting = store.swapCandidate?.slug == skill.slug
        Button {
            guard !busy else { return }
            busy = true
            Task { await store.toggle(skill); busy = false }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: active ? "checkmark" : waiting ? "hourglass" : "plus").font(.system(size: large ? 11 : 9.5, weight: .bold))
                Text(active ? "Active" : waiting ? "Pick a slot" : "Activate").font(.awan(large ? 13 : 11.5, .semibold))
            }
            .foregroundStyle(active ? Theme.ink : Theme.text)
            .padding(.horizontal, large ? 16 : 10)
            .frame(height: large ? 34 : 26)
            .background(Capsule().fill(active ? Theme.lime : Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(active ? .clear : waiting ? Theme.warning.opacity(0.7) : Theme.strokeStrong, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(busy ? 0.6 : 1)
        .help(active ? "Switch off" : "Switch on (up to 3 at once)")
    }
}

// MARK: - Sheets

struct SkillSheetScrim: View {
    let dismiss: () -> Void
    var body: some View {
        Color.black.opacity(0.45).ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: dismiss)
    }
}

private struct SheetCard<Content: View>: View {
    var width: CGFloat = 560
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(22)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x1F1F1D), Color(hex: 0x151514)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 40, y: 18)
    }
}

struct SkillDetailSheet: View {
    let skill: SkillItem
    @ObservedObject private var store = SkillsStore.shared

    var body: some View {
        SheetCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    SkillSymbolTile(symbol: skill.symbol, tint: skill.tint, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(skill.title).font(.awan(20, .semibold)).foregroundStyle(Theme.text)
                        HStack(spacing: 6) {
                            Text("by \(skill.byline)")
                            Text("·")
                            Text(skill.categoryName ?? skill.category.capitalized)
                            Text("·")
                            Text(skill.usersLabel)
                        }
                        .font(.awan(12)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    CircleIconButton(systemName: "xmark", size: 28, filled: true, help: "Close") { store.detail = nil }
                }
                Text(skill.oneLiner).font(.awan(13.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)

                if !skill.whatsInside.isEmpty {
                    SectionLabel("Inside this skill").padding(.top, 18).padding(.bottom, 8)
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(skill.whatsInside, id: \.self) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 12.5)).foregroundStyle(Theme.ink, skill.tint)
                                Text(line).font(.awan(12.5, .medium)).foregroundStyle(Theme.text)
                            }
                        }
                    }
                }

                SectionLabel("SKILL.md").padding(.top, 18).padding(.bottom, 8)
                ScrollView {
                    Text(skill.content ?? "Loading…")
                        .font(.awanMono(11.5, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(height: 168)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.3)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke, lineWidth: 1))

                HStack(spacing: 8) {
                    if skill.isMine {
                        Button(skill.published ? "Unpublish" : "Publish") { Task { await store.lifecycle(skill, skill.published ? "unpublish" : "publish") } }
                            .buttonStyle(.gel(.dark, height: 32, padding: 14, fontSize: 12.5))
                            .help(skill.published ? "Only you will see it" : "Everyone can find it in the library")
                        Button(skill.teamShared ? "Stop sharing" : "Share with team") { Task { await store.lifecycle(skill, skill.teamShared ? "unshare-from-team" : "share-to-team") } }
                            .buttonStyle(.gel(.dark, height: 32, padding: 14, fontSize: 12.5))
                    } else if skill.isOfficial {
                        Label("Made by FF Dev Studio", systemImage: "checkmark.seal.fill").font(.awan(11.5, .medium)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    SkillToggleButton(skill: skill, large: true)
                }
                .padding(.top, 18)
            }
        }
    }
}

struct CreateSkillSheet: View {
    @ObservedObject private var store = SkillsStore.shared
    @Local private var dump = ""
    /// Snapshot hook: prefill the brain dump.
    static var debugDump: String?

    var body: some View {
        SheetCard(width: 540) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Create a skill").font(.awan(20, .semibold)).foregroundStyle(Theme.text)
                        Text("Brain-dump what you want Awan to be good at. It writes the skill for you.")
                            .font(.awan(12.5)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    CircleIconButton(systemName: "xmark", size: 28, filled: true, help: store.creating == .writing ? "Close (it keeps writing)" : "Close") { store.showCreate = false }
                }
                switch store.creating {
                case .idle: form
                case .writing: writing
                case let .done(skill): done(skill)
                case let .failed(message): failed(message)
                }
            }
        }
        .onAppear { if let d = Self.debugDump, dump.isEmpty { dump = d } }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $dump)
                    .font(.awan(13.5))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if dump.isEmpty {
                    Text("Who it's for, how you like things done, what good looks like, what to avoid. Paste examples if you have them.\n\ne.g. “Quotes for my web studio's clients: short, friendly, three packages in ringgit, and always say what's not included.”")
                        .font(.awan(13.5)).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 176)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke, lineWidth: 1))
            .padding(.top, 16)

            HStack(spacing: 8) {
                Button { store.showCreate = false; store.chooseImport() } label: { Label("Import .md instead", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.plain).font(.awan(12.5, .medium)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Cancel") { store.showCreate = false }.buttonStyle(.gel(.bone, height: 34, padding: 16, fontSize: 13))
                Button("Write my skill") { store.create(brainDump: dump) }
                    .buttonStyle(.gel(.lime, height: 34, padding: 18, fontSize: 13))
                    .disabled(dump.trimmingCharacters(in: .whitespacesAndNewlines).count < 12)
            }
            .padding(.top, 16)
        }
    }

    private var writing: some View {
        VStack(spacing: 12) {
            CloudCreature(appearance: .mascot, mood: .thinking, glow: true).frame(width: 84)
            Text("Writing your skill…").font(.awan(16, .semibold)).foregroundStyle(Theme.text)
            Text("This can take a minute. Safe to leave: it lands in My skills when it's done.")
                .font(.awan(12.5)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            ProgressView().controlSize(.small).padding(.top, 2)
            Button("Close") { store.showCreate = false }.buttonStyle(.gel(.bone, height: 32, padding: 16, fontSize: 12.5)).padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private func done(_ skill: SkillItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SkillSymbolTile(symbol: skill.symbol, tint: skill.tint, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.title).font(.awan(16, .semibold)).foregroundStyle(Theme.text)
                    Text(skill.oneLiner).font(.awan(12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card.opacity(0.7)))
            .padding(.top, 16)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(skill.whatsInside.prefix(6), id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.ink, skill.tint)
                        Text(line).font(.awan(12.5)).foregroundStyle(Theme.text)
                    }
                }
            }
            .padding(.top, 14)
            Text("It's private to you until you publish it or share it with your team.")
                .font(.awan(11.5)).foregroundStyle(Theme.textTertiary).padding(.top, 14)
            HStack(spacing: 8) {
                Spacer()
                Button("See the skill") { store.showCreate = false; store.open(skill) }
                    .buttonStyle(.gel(.bone, height: 34, padding: 16, fontSize: 13))
                SkillToggleButton(skill: skill, large: true)
            }
            .padding(.top, 16)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Awan couldn't write that one.").font(.awan(15, .semibold)).foregroundStyle(Theme.text).padding(.top, 16)
            Text(message).font(.awan(12)).foregroundStyle(Theme.textSecondary).lineLimit(4)
            HStack {
                Spacer()
                Button("Try again") { store.creating = .idle }.buttonStyle(.gel(.bone, height: 34, padding: 16, fontSize: 13))
            }
        }
    }
}

// MARK: - Sidebar entry

/// "Skills" row above the Apps / Invite chips: the three slots as dots.
struct SkillsSidebarEntry: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var store = SkillsStore.shared
    @Local private var hovering = false

    var body: some View {
        let selected = state.homePage == .skills
        Button { state.homePage = .skills } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07))
                    Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                }
                .frame(width: 30, height: 30)
                Text("Skills").font(.awan(13.5, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(0 ..< SkillsStore.maxActive, id: \.self) { i in
                        let items = store.activeItems
                        Circle()
                            .fill(i < items.count ? items[i].tint : Color.white.opacity(0.12))
                            .frame(width: 7, height: 7)
                    }
                }
                .help("\(store.activeSlugs.count) of \(SkillsStore.maxActive) skills active")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color.white.opacity(0.10) : hovering ? Color.white.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task { if !store.loaded && state.signInState == .signedIn { await store.refreshActive() } }
    }
}
