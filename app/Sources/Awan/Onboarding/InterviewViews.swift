import SwiftUI

// MARK: - 5. Interview (4 questions + where did you hear about us)

struct InterviewStepView: View {
    @ObservedObject var model: OnboardingModel

    private var onDiscovery: Bool { model.questionIndex >= InterviewScript.questions.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                CloudCreature(appearance: .mascot, mood: model.recordingAnswer ? .listening : .speaking, showPaws: true)
                    .frame(width: 62)
                SpeechBubble(text: model.questionIndex == 0 ? InterviewScript.opener : onDiscovery ? "Last one, I promise. It helps a tiny studio a lot." : reaction)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.top, 8)

            Group {
                if onDiscovery { discovery } else { question }
            }
            .id(model.questionIndex)
            .transition(.opacity.combined(with: .offset(y: 8)))
            .padding(.top, 14)
            .frame(maxHeight: .infinity, alignment: .top)

            footer
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 22)
    }

    private var reaction: String {
        ["", "Love that. Next one.", "Nice. And the tools?", "Okay, last question."][min(model.questionIndex, 3)]
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("QUESTION \(model.questionIndex + 1) OF \(InterviewScript.questions.count)")
                    .font(.awan(10.5, .semibold)).tracking(0.9).foregroundStyle(Theme.textTertiary)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(0 ..< InterviewScript.questions.count, id: \.self) { i in
                        Capsule().fill(i <= model.questionIndex ? Theme.bone.opacity(i == model.questionIndex ? 1 : 0.55) : Color.white.opacity(0.14))
                            .frame(width: i == model.questionIndex ? 18 : 6, height: 6)
                    }
                }
            }
            Text(model.currentQuestion).font(.awanSerif(30)).foregroundStyle(Theme.text)
            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if model.answers[model.questionIndex].isEmpty {
                        Text(model.recordingAnswer ? "Listening…" : InterviewScript.placeholders[model.questionIndex])
                            .font(.awan(14.5)).foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $model.answers[model.questionIndex])
                        .font(.awan(14.5)).foregroundStyle(Theme.text)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 9).padding(.vertical, 8)
                }
                .frame(height: 84)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(model.recordingAnswer ? Theme.lime.opacity(0.7) : Theme.strokeStrong, lineWidth: 1))
                InterviewHoldToTalkButton(recording: model.recordingAnswer, busy: model.transcribing, level: model.micLevel,
                                 begin: { model.beginAnswerRecording() }, end: { model.endAnswerRecording() })
            }
            Text("Type, or hold the mic and say it.").font(.awan(11.5)).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: 560)
        .padding(.top, 16)
    }

    private var discovery: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where did you hear about Awan?").font(.awanSerif(30)).foregroundStyle(Theme.text)
            FlowChips(items: InterviewScript.channels, selected: model.discoveryChannel) { c in
                model.discoveryChannel = model.discoveryChannel == c ? nil : c
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.top, 20)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if model.questionIndex > 0 {
                Button { model.previousQuestion() } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(.awan(13, .medium)).foregroundStyle(Theme.textSecondary)
            }
            Button("Skip the questions") { model.skipInterview() }
                .buttonStyle(.plain).font(.awan(13, .medium)).foregroundStyle(Theme.textTertiary)
            Spacer()
            if onDiscovery {
                Button("Build my squad") { model.finishInterview() }
                    .buttonStyle(.gel(.lime, height: 38, padding: 24))
            } else {
                let empty = model.answers[model.questionIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button(empty ? "Skip question" : "Next") { model.nextQuestion() }
                    .buttonStyle(.gel(empty ? .dark : .lime, height: 36, padding: 22))
                    .disabled(model.recordingAnswer)
            }
        }
        .frame(height: 40)
    }
}

struct SpeechBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.awan(13.5)).foregroundStyle(Theme.text).lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous).fill(Theme.agentBubble)
            )
            .frame(maxWidth: 480, alignment: .leading)
    }
}

/// Press and hold to record; release to transcribe.
struct InterviewHoldToTalkButton: View {
    var recording: Bool
    var busy: Bool
    var level: Float
    var begin: () -> Void
    var end: () -> Void

    var body: some View {
        ZStack {
            Circle()
                .fill(recording ? Theme.lime : Theme.cardRaised)
                .scaleEffect(recording ? 1 + CGFloat(level) * 0.18 : 1)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "mic.fill").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(recording ? Theme.ink : Theme.bone)
            }
        }
        .frame(width: 52, height: 52)
        .overlay(Circle().strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !recording { begin() } }
            .onEnded { _ in end() })
        .help("Hold to answer out loud")
        .animation(Theme.snappy, value: recording)
    }
}

/// Chips that wrap onto a second row.
struct FlowChips: View {
    let items: [String]
    var selected: String?
    let pick: (String) -> Void

    var body: some View {
        let rows = [Array(items.prefix(4)), Array(items.dropFirst(4))]
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0 ..< rows.count, id: \.self) { r in
                HStack(spacing: 10) {
                    ForEach(rows[r], id: \.self) { item in
                        Button { pick(item) } label: {
                            Text(item).font(.awan(13.5, .medium))
                                .foregroundStyle(selected == item ? Theme.ink : Theme.text)
                                .padding(.horizontal, 16).frame(height: 36)
                                .background(Capsule().fill(selected == item ? Theme.bone : Theme.card))
                                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Squad (three generated Awans → Use this squad → hatch)

struct SquadStepView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            switch model.cast {
            case .loading, .idle:
                loading
            case let .failed(message):
                failed(message)
            case let .ready(goal, awans):
                ready(title: "Meet your squad", subtitle: goal, cards: awans.map { ($0, CharacterCatalog.appearance(forHue: $0.baseHue, seed: $0.slug)) }, primary: "Use this squad", regenerate: true)
            case .skipped:
                ready(title: "Meet your first Awans", subtitle: "Two helpers to start with. Make more of your own any time from Home.",
                      cards: StarterCast.all.map { ($0.dto, $0.character) }, primary: "Let's go", regenerate: false)
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }

    private var loading: some View {
        VStack(spacing: 0) {
            CloudCreature(appearance: .mascot, mood: .thinking, showPaws: true).frame(width: 90).padding(.top, 14)
            OnboardingTitle("Hatching your squad…", size: 31).padding(.top, 10)
            OnboardingSubtitle("I'm building three Awans around what you told me.").padding(.top, 6)
            HStack(spacing: 14) {
                ForEach(0 ..< 3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 18).fill(Theme.card.opacity(0.7))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.stroke, lineWidth: 1))
                        .overlay(TypingDots(color: Theme.textTertiary, dot: 5))
                        .frame(width: 196, height: 170)
                        .opacity(1 - Double(i) * 0.18)
                }
            }
            .padding(.top, 22)
            Spacer()
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 0) {
            CloudCreature(appearance: .mascot, mood: .sad, showPaws: true).frame(width: 96).padding(.top, 30)
            OnboardingTitle("I couldn't build your squad", size: 31).padding(.top, 12)
            OnboardingSubtitle("Something went wrong on my side. You can try again, or start with my two starter Awans and make your own later.").padding(.top, 6)
            Text(message).font(.awan(11.5)).foregroundStyle(Theme.textTertiary).lineLimit(2).padding(.top, 10).frame(maxWidth: 460)
            HStack(spacing: 12) {
                Button("Skip, use the starter Awans") { model.useStarters() }
                    .buttonStyle(.gel(.dark, height: 38, padding: 20))
                Button("Try again") { model.requestCast() }
                    .buttonStyle(.gel(.lime, height: 38, padding: 24))
            }
            .padding(.top, 24)
            Spacer()
        }
    }

    private func ready(title: String, subtitle: String, cards: [(AwanSpecDTO, CharacterAppearance)], primary: String, regenerate: Bool) -> some View {
        VStack(spacing: 0) {
            OnboardingTitle(title, size: 32).padding(.top, 6)
            OnboardingSubtitle(subtitle).padding(.top, 4).lineLimit(2)
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(cards.enumerated()), id: \.offset) { i, pair in
                    SquadCard(spec: pair.0, appearance: pair.1, index: i)
                }
            }
            .padding(.top, 20)
            Spacer(minLength: 10)
            HStack(spacing: 16) {
                if regenerate {
                    Button { model.requestCast() } label: { Label("Regenerate", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.plain).font(.awan(13, .medium)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text("You can change them any time.").font(.awan(11.5)).foregroundStyle(Theme.textTertiary)
                Button(primary) { model.useSquad() }
                    .buttonStyle(.gel(.lime, height: 40, padding: 26, fontSize: 14))
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.hatching)
            }
            .padding(.horizontal, 8)
        }
    }
}

struct SquadCard: View {
    let spec: AwanSpecDTO
    let appearance: CharacterAppearance
    var index = 0
    @Local private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            AgentAvatar(appearance: appearance, size: 66, mood: .happy)
                .padding(.top, 18)
            Text(spec.name).font(.awan(15, .semibold)).foregroundStyle(Theme.text).padding(.top, 10).lineLimit(1)
            Text(spec.roleText.uppercased()).font(.awan(10, .semibold)).tracking(0.8).foregroundStyle(Theme.textTertiary).padding(.top, 3).lineLimit(1)
            Text(spec.oneLiner).font(.awan(12.5)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9).padding(.horizontal, 14)
            Spacer(minLength: 12)
        }
        .frame(width: 204, height: 214)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.stroke, lineWidth: 1))
        .scaleEffect(shown ? 1 : 0.85)
        .opacity(shown ? 1 : 0)
        .onAppear {
            if CommandLine.arguments.contains("--snapshot") { shown = true; return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.08 + Double(index) * 0.1)) { shown = true }
        }
    }
}
