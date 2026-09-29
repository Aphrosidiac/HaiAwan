import SwiftUI

/// "Suggested for you": one idea at a time from the user's Awans — No / Adjust / Yes, do it.
/// Adjust asks out loud what to change and takes a spoken (or typed) answer.
struct SuggestionsPage: View {
    enum AdjustPhase: Equatable { case idle, thinking, answering, applying }

    /// Snapshot hook: start the page in a given Adjust phase.
    static var debugPhase: AdjustPhase? = nil

    @EnvironmentObject var state: AppState
    @EnvironmentObject var companion: CompanionEngine
    @Local private var phase: AdjustPhase = SuggestionsPage.debugPhase ?? .idle
    @Local private var typed = ""
    @Local private var refreshing = false
    @Local private var deciding = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.suggestions.isEmpty {
                empty
            } else {
                ScrollView(showsIndicators: false) {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDisabled(phase == .idle)
            }
            ShowSidebarButton().padding(16)
        }
        .onDisappear { if phase != .idle { VoiceAnswer.shared.cancel() } }
    }

    static let cardWidth: CGFloat = 531
    static let cardGap: CGFloat = 33
    /// Measured on the reference pager: ≈250 ms to settle, no overshoot.
    static let slide = Animation.spring(response: 0.3, dampingFraction: 1.0)

    private var current: Suggestion? {
        guard !state.suggestions.isEmpty else { return nil }
        return state.suggestions[min(max(0, state.suggestionIndex), state.suggestions.count - 1)]
    }

    // MARK: Content

    /// Reference layout (home-suggestions.ax, detail-relative): title at (42.5, 21), pager at (51, 81.5),
    /// card 531×161 at (51, 230) with the next card peeking 33 pt to its right, question + No / Adjust /
    /// Yes, do it (32 pt gels, 7 apart) left-aligned under the card.
    @ViewBuilder private var content: some View {
        if let s = current {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 1.2) {
                    Text("Suggested for you").font(.awan(17, .semibold)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.awan(13)).foregroundStyle(SettingsStyle.navText)
                }
                .padding(.leading, 42.5)
                .padding(.top, 22.75)

                Group {
                    if state.suggestions.count > 1 { pager } else { Color.clear.frame(height: 24) }
                }
                .padding(.leading, 51)
                .padding(.top, 20.9)

                // Carousel like the reference: every card in one row (531 wide, 33 apart), the row slides one card
                // per step; the next card peeks at the right edge, the previous one slides out under the left edge.
                // A hidden copy of the current card sizes the area (the row itself doesn't widen the page); the clip
                // leaves 80 pt above the cards for the mascot peeking over them.
                SuggestionCard(suggestion: s, agent: state.agents.agent(s.awanSlug), mood: .idle)
                    .frame(width: Self.cardWidth)
                    .padding(.top, 80)
                    .hidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .topLeading) {
                        HStack(alignment: .top, spacing: Self.cardGap) {
                            ForEach(Array(state.suggestions.enumerated()), id: \.element.id) { i, sug in
                                SuggestionCard(suggestion: sug, agent: state.agents.agent(sug.awanSlug),
                                               mood: i == state.suggestionIndex ? companion.voiceState.mood : .idle)
                                    .frame(width: Self.cardWidth)
                                    .opacity(i < state.suggestionIndex ? 0 : 1)   // no sliver of the previous card at the left edge
                                    .allowsHitTesting(i == state.suggestionIndex)
                            }
                        }
                        .fixedSize()
                        .padding(.top, 80)
                        .offset(x: 51 - CGFloat(state.suggestionIndex) * (Self.cardWidth + Self.cardGap))
                    }
                    .clipped()
                    .padding(.top, 124.5 - 80)

                decision(s)
                    .id(s.id)
                    .transition(.opacity)
                    .padding(.leading, 51)
                    .padding(.top, 13.1)
                Spacer(minLength: 24)
            }
            .animation(Self.slide, value: s.id)
            .animation(Theme.snappy, value: phase)
        }
    }

    private var subtitle: String {
        let n = state.suggestions.count
        var line = n == 1 ? "One idea, ready when you are." : "\(n) ideas, ready when you are."
        if let at = state.suggestionsCheckedAt { line += " Last checked \(HomeUI.clock(at))." }
        return line
    }

    /// Reference pager: 29×23 gel arrows either side of "1 of 3" (the disabled one greys out).
    private var pager: some View {
        HStack(spacing: 10) {
            pagerButton("chevron.left", enabled: state.suggestionIndex > 0, help: "Previous suggestion") { move(-1) }
            Text("\(state.suggestionIndex + 1) of \(state.suggestions.count)")
                .font(.awan(12.5, .medium)).foregroundStyle(SettingsStyle.navText)
                .monospacedDigit()
            pagerButton("chevron.right", enabled: state.suggestionIndex < state.suggestions.count - 1, help: "Next suggestion") { move(1) }
        }
        .frame(height: 24)
    }

    private func pagerButton(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(enabled ? Theme.ink : Theme.text.opacity(0.45))
                .frame(width: 29, height: 23)
                .background {
                    if enabled {
                        Capsule().fill(LinearGradient(colors: [Color.white, Theme.bone, Color(hex: 0xD9D4C6)], startPoint: .top, endPoint: .bottom))
                            .overlay(Capsule().strokeBorder(Color.black.opacity(0.18), lineWidth: 1))
                    } else {
                        Capsule().fill(Color.white.opacity(0.12))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private func move(_ d: Int) {
        cancelAdjust()
        withAnimation(Self.slide) {
            state.suggestionIndex = min(max(0, state.suggestionIndex + d), state.suggestions.count - 1)
        }
    }

    // MARK: Decision row

    @ViewBuilder private func decision(_ s: Suggestion) -> some View {
        switch phase {
        case .idle:
            VStack(alignment: .leading, spacing: 11.4) {
                Text(question(s)).font(.awan(13.5, .medium)).foregroundStyle(SettingsStyle.navText)
                HStack(spacing: 7) {
                    Button { decide { await state.decline(s) } } label: { Label("No", systemImage: "xmark") }
                        .buttonStyle(.gel(.bone, height: 32, padding: 13, fontSize: 14))
                    Button { startAdjust(s) } label: { Label("Adjust", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.gel(.bone, height: 32, padding: 13, fontSize: 14))
                    Button { decide { await state.accept(s) } } label: { Label("Yes, do it", systemImage: "checkmark") }
                        .buttonStyle(.gel(.lime, height: 32, padding: 13, fontSize: 14))
                        .keyboardShortcut(.defaultAction)
                }
                .disabled(deciding)
            }
        case .thinking, .applying:
            VStack(alignment: .leading, spacing: 11.4) {
                Text(phase == .thinking ? "What would you like to change about it?" : "Reworking the idea…")
                    .font(.awan(13.5, .medium)).foregroundStyle(SettingsStyle.navText)
                HStack(spacing: 9) {
                    TypingDots(color: Theme.ink, dot: 5)
                    Text("Thinking…")
                }
                .font(.awan(13.5, .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 200, height: 32)
                .background(Capsule().fill(LinearGradient(colors: [.white, Theme.bone, Color(hex: 0xD9D4C6)], startPoint: .top, endPoint: .bottom)))
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.18), lineWidth: 1))
            }
        case .answering:
            VStack(alignment: .leading, spacing: 10) {
                Text("What would you like to change about it?").font(.awan(13.5, .medium)).foregroundStyle(SettingsStyle.navText)
                HStack(spacing: 10) {
                    HoldToAnswerPill(title: "Hold \(HomeUI.talkKeys) to answer", width: 300, height: 38)
                    Button("Cancel") { cancelAdjust() }
                        .buttonStyle(.gel(.bone, height: 38, padding: 18))
                        .keyboardShortcut(.cancelAction)
                        .help("Cancel adjustment (Esc)")
                }
                Text("Release to send · Esc to cancel").font(.awan(11.5, .medium)).foregroundStyle(Theme.textTertiary)
                HStack(spacing: 8) {
                    Image(systemName: "keyboard").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    TextField("or type what to change", text: $typed)
                        .textFieldStyle(.plain)
                        .font(.awan(13))
                        .foregroundStyle(Theme.text)
                        .onSubmit { apply(s, typed) }
                }
                .padding(.horizontal, 14)
                .frame(width: 300, height: 34)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .padding(.top, 4)
            }
        }
    }

    private func question(_ s: Suggestion) -> String {
        if let r = s.routine {
            let cadence = Routine(slug: s.awanSlug, title: "", task: "", intervalMinutes: r.everyMinutes, nextRunAt: Date()).cadenceText.lowercased()
            return "Want me to keep doing this \(cadence)?"
        }
        return "Want me to do it?"
    }

    private func decide(_ work: @escaping () async -> Void) {
        deciding = true
        Task {
            await work()
            deciding = false
        }
    }

    // MARK: Adjust

    private func startAdjust(_ s: Suggestion) {
        phase = .thinking
        typed = ""
        companion.announce("What would you like to change about it?")
        VoiceAnswer.shared.expect { answer in apply(s, answer) }
        Task {
            try? await Task.sleep(for: .milliseconds(1300))
            if phase == .thinking { phase = .answering }
        }
    }

    private func apply(_ s: Suggestion, _ change: String) {
        let text = change.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        VoiceAnswer.shared.cancel()
        phase = .applying
        Task {
            await state.adjust(s, change: text)
            phase = .idle
            typed = ""
        }
    }

    private func cancelAdjust() {
        VoiceAnswer.shared.cancel()
        if companion.voiceState == .listening { companion.cancel() }
        phase = .idle
        typed = ""
    }

    // MARK: Empty

    private var empty: some View {
        VStack(spacing: 12) {
            CloudCreature(appearance: .mascot, mood: refreshing ? .thinking : .sleeping, showPaws: true)
                .frame(width: 118)
                .padding(.bottom, 6)
            Text(refreshing ? "Finding a few good ideas" : "No suggestions right now.")
                .font(.awan(18, .semibold)).foregroundStyle(Theme.text)
            Text(refreshing ? "Looking through what your Awans know about you." : "Your Awans look for fresh ideas every morning.")
                .font(.awan(13)).foregroundStyle(Theme.textSecondary)
            Button {
                refreshing = true
                Task {
                    await state.refreshSuggestions()
                    state.suggestionIndex = 0
                    refreshing = false
                }
            } label: {
                if refreshing {
                    HStack(spacing: 8) { TypingDots(color: Theme.ink, dot: 4); Text("Checking…") }
                } else {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.gel(.bone, height: 34, padding: 18))
            .disabled(refreshing)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The idea: owning Awan peeking over the card, its name and app, the promise, and why.
/// Reference card: 531 wide, radius 20, fill #3B3B3D; owner at +13/+12.75, title (15 semibold, 2 lines)
/// at +38, body (13, ~16.75 pt lines) at +82; the mascot (100 wide) sits 9 pt in from the left.
struct SuggestionCard: View {
    let suggestion: Suggestion
    let agent: AwanAgent?
    var mood: CharacterMood = .idle
    static let fill = Color(hex: 0x3B3B38)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(agent?.name ?? "A new Awan")
                    .font(.awan(13, .semibold)).foregroundStyle(SettingsStyle.navText)
                Spacer(minLength: 8)
                if let r = suggestion.routine {
                    chip(Routine(slug: "", title: "", task: "", intervalMinutes: r.everyMinutes, nextRunAt: Date()).cadenceText, symbol: "repeat")
                }
                if let app = suggestion.appHint, !app.isEmpty {
                    chip(app, symbol: Self.symbol(for: app))
                }
            }
            Text(suggestion.title)
                .font(.awan(15, .semibold)).foregroundStyle(Theme.text)
                .lineSpacing(-1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7.5)
            Text(suggestion.description)
                .font(.awan(13)).foregroundStyle(Theme.text.opacity(0.86))
                .lineSpacing(0.9)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 6.5)
        }
        .padding(.leading, 13)
        .padding(.trailing, 13)
        .padding(.top, 11.25)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Self.fill))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .peeking(agent?.character ?? .mascot, mood: mood, width: 100, x: 9, sink: 8)
    }

    private func chip(_ title: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(title).font(.awan(11.5, .medium))
        }
        .foregroundStyle(SettingsStyle.navText)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }

    static func symbol(for app: String) -> String {
        let a = app.lowercased()
        if a.contains("safari") || a.contains("web") || a.contains("chrome") || a.contains("browser") { return "safari" }
        if a.contains("sheet") || a.contains("excel") || a.contains("numbers") { return "tablecells" }
        if a.contains("notion") || a.contains("doc") || a.contains("pages") { return "doc.text" }
        if a.contains("mail") || a.contains("gmail") { return "envelope" }
        if a.contains("calendar") { return "calendar" }
        if a.contains("slack") || a.contains("message") || a.contains("whatsapp") { return "bubble.left.and.bubble.right" }
        if a.contains("figma") || a.contains("design") { return "paintpalette" }
        if a.contains("github") || a.contains("xcode") || a.contains("terminal") { return "chevron.left.forwardslash.chevron.right" }
        return "app"
    }
}
