import SwiftUI

/// "New Awan": Awan asks out loud what the new Awan should do (one or two follow-ups at most),
/// the server turns the answers into a spec, and the new Awan hatches into the roster.
/// Creating an Awan never spends agent messages — the interview is a companion-model call.
struct NewAwanPage: View {
    enum Phase: Equatable { case starting, speaking, answering, thinking, creating, failed(String) }
    struct Line: Codable, Equatable { var role: String; var text: String }   // role: awan | user
    /// POST /v1/awans/interview → { done, say[], awan? }
    struct Reply: Decodable { var done: Bool; var say: [String]; var awan: AwanSpecDTO? }

    /// Snapshot hook: show these lines as Awan's current question, mid-speech.
    static var debugScript: [String]? = nil

    @EnvironmentObject var state: AppState
    @EnvironmentObject var companion: CompanionEngine
    @Local private var transcript: [Line] = []
    @Local private var bubble: [String] = []
    @Local private var phase: Phase = .starting
    @Local private var typed = ""
    @Local private var started = false
    @Local private var lastAnswer = ""
    @FocusState private var typing: Bool

    static let firstQuestion = "What would you like this new Awan to do?"

    /// Layout: full-width page, Settings-style header (Back pill + title),
    /// a 176 pt mascot 127.5 pt left of centre with Awan's lines as stacked peach pills up and to its right,
    /// a 290×54 hold-to-answer gel and a 360×38 "or type your answer" field centred below, 43.5 pt from the
    /// bottom.
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 19) {
                ShowSidebarButton()
                Button {
                    VoiceAnswer.shared.cancel()
                    state.homePage = .home
                } label: {
                    HStack(spacing: 0) {
                        Image(systemName: "chevron.left").font(.system(size: 11.5, weight: .semibold)).frame(width: 14, alignment: .leading)
                        Text("Back").font(.awan(13, .medium)).fixedSize()
                    }
                    .foregroundStyle(SettingsStyle.navText)
                    .padding(.leading, 9.5)
                    .frame(width: 60.5, height: 30, alignment: .leading)
                    .background(Capsule().fill(SettingsStyle.backPill))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Text("New Awan").font(.awan(16.5, .semibold)).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.leading, 19)
            .padding(.top, 26)

            Spacer(minLength: 10)

            ZStack(alignment: .topLeading) {
                CloudCreature(appearance: .mascot, mood: mood, showPaws: true)
                    .frame(width: 176)
                    .offset(x: 172.5, y: 94)
                if !bubble.isEmpty {
                    ThoughtBubble(lines: bubble)
                        .offset(x: 320.5, y: 0)
                        .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
                        .id(bubble.joined())
                }
            }
            .frame(width: 600, height: 232.5, alignment: .topLeading)

            controls
                .padding(.top, 45)
                .padding(.bottom, 20.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Theme.spring, value: bubble)
        .animation(Theme.snappy, value: phase)
        .onAppear {
            guard !started else { return }
            started = true
            if let script = Self.debugScript {
                bubble = script
                phase = Self.debugPhase ?? .speaking
                return
            }
            say([Self.firstQuestion])
        }
        .onDisappear { VoiceAnswer.shared.cancel() }
    }

    /// Snapshot hook: the phase to show with `debugScript` (default: speaking).
    static var debugPhase: Phase? = nil

    private var mood: CharacterMood {
        switch phase {
        case .speaking: return .speaking
        case .thinking, .starting: return .thinking
        case .answering: return companion.voiceState == .listening ? .listening : .idle
        case .creating: return .happy
        case .failed: return .sad
        }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        VStack(spacing: 15.5) {
            switch phase {
            case .answering:
                HoldToAnswerPill(title: "Hold \(HomeUI.talkKeys) to answer", width: 290, height: 54, fontSize: 14.5)
            case .speaking:
                statusPill(icon: "speaker.wave.2.fill", text: "Awan is speaking…", waves: true)
            case .starting, .thinking:
                statusPill(icon: nil, text: phase == .starting ? "Awan is getting ready…" : "Got it…", waves: false)
            case .creating:
                statusPill(icon: "sparkles", text: "Setting up your space…", waves: false)
            case let .failed(message):
                VStack(spacing: 8) {
                    Text(message).font(.awan(12.5)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 320)
                    Button { retry() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                        .buttonStyle(.gel(.bone, height: 32, padding: 16, fontSize: 13))
                }
            }

            HStack(spacing: 11) {
                Image(systemName: "keyboard").font(.system(size: 12.5)).foregroundStyle(SettingsStyle.dim)
                ZStack(alignment: .leading) {
                    if typed.isEmpty {
                        Text("or type your answer").font(.awan(14.5)).foregroundStyle(SettingsStyle.dim).allowsHitTesting(false)
                    }
                    TextField("", text: $typed)
                        .textFieldStyle(.plain)
                        .font(.awan(14.5))
                        .foregroundStyle(Theme.text)
                        .focused($typing)
                        .onSubmit { answer(typed) }
                }
                if !typed.isEmpty {
                    Button { answer(typed) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 26, height: 26).background(Circle().fill(Theme.bone))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 15.5)
            .padding(.trailing, 6)
            .frame(width: 360, height: 38)
            .background(Capsule().fill(Color.white.opacity(0.02)))
            .overlay(Capsule().strokeBorder(typing ? Theme.bone.opacity(0.35) : Color.white.opacity(0.13), lineWidth: 1))
            .opacity(phase == .answering || phase == .speaking ? 1 : 0.45)
            .disabled(!(phase == .answering || phase == .speaking))
        }
    }

    private func statusPill(icon: String?, text: String, waves: Bool) -> some View {
        HStack(spacing: 9) {
            if let icon { Image(systemName: icon).font(.system(size: 14, weight: .semibold)) } else { TypingDots(color: Theme.ink, dot: 5) }
            Text(text).lineLimit(1)
            if waves { WaveformBars(level: 0.5, color: Theme.ink, bars: 4).frame(width: 18, height: 12) }
        }
        .font(.awan(14.5, .semibold))
        .foregroundStyle(Theme.ink)
        .frame(width: 290, height: 54)
        .background(LimeGel().opacity(0.92))
        .shadow(color: Theme.lime.opacity(0.25), radius: 8, y: 3)
    }

    // MARK: Interview loop

    /// Show and speak Awan's lines, then wait for an answer.
    private func say(_ lines: [String], then next: (() -> Void)? = nil) {
        transcript += lines.map { Line(role: "awan", text: $0) }
        bubble = lines
        phase = .speaking
        for line in lines { companion.announce(line) }
        Task {
            // Wait roughly as long as it takes to say, and for the companion to finish speaking.
            let words = lines.joined(separator: " ").split(separator: " ").count
            try? await Task.sleep(for: .seconds(max(1.4, Double(words) * 0.34 + 0.5)))
            for _ in 0..<40 where companion.voiceState == .responding {
                try? await Task.sleep(for: .milliseconds(150))
            }
            if let next { next(); return }
            guard phase == .speaking else { return }
            phase = .answering
            VoiceAnswer.shared.expect { answer($0) }
        }
    }

    private func answer(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase == .answering || phase == .speaking else { return }
        VoiceAnswer.shared.cancel()
        typed = ""
        lastAnswer = text
        transcript.append(Line(role: "user", text: text))
        send()
    }

    private func retry() { send() }

    private func send() {
        phase = .thinking
        struct Body: Encodable { var messages: [Line] }
        let body = Body(messages: transcript)
        Task {
            do {
                let r: Reply = try await state.api.send("v1/awans/interview", method: "POST", body: body)
                if r.done, let spec = r.awan {
                    say(r.say.isEmpty ? ["Alright, let me set this up for you."] : r.say) { hatch(spec) }
                } else {
                    say(r.say.isEmpty ? ["Tell me a little more?"] : r.say)
                }
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't reach Awan. Check your connection and try again.")
            }
        }
    }

    private func hatch(_ spec: AwanSpecDTO) {
        phase = .creating
        let agent = state.agents.create(from: spec)
        Sounds.play(.hatch)
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            state.openAgent(agent.slug)
        }
    }
}

/// Awan's lines as the reference draws them: one peach pill per line (31 pt, 14.5 medium ink), each
/// 12.5 pt further left than the one above, with two thought dots trailing from the last toward the mascot.
struct ThoughtBubble: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                Text(line)
                    .font(.awan(13.5, .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 12.5)
                    .frame(height: 31)
                    .background(Capsule().fill(LinearGradient(colors: [Color(hex: 0xFFE3C8), Color(hex: 0xF6C096)], startPoint: .top, endPoint: .bottom)))
                    .overlay(Capsule().strokeBorder(Color(hex: 0xC97A3C).opacity(0.55), lineWidth: 1))
                    .shadow(color: Color(hex: 0xF4B784).opacity(0.25), radius: 10, y: 3)
                    .padding(.leading, CGFloat(lines.count - 1 - i) * 12.5)
            }
            ZStack(alignment: .topLeading) {
                Circle().fill(Color(hex: 0xF6C096)).frame(width: 6, height: 6).offset(x: 6, y: 0)
                Circle().fill(Color(hex: 0xF6C096)).frame(width: 4, height: 4).offset(x: 0, y: 6)
            }
            .frame(width: 14, height: 12, alignment: .topLeading)
            .padding(.top, 4)
            .padding(.leading, -3)
        }
    }
}
