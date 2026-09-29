import SwiftUI

/// Onboarding, right after the intro voice step: "What should Awan be good at?" — pick up to three official
/// skills (bundled catalog, no account needed yet). They're switched on after sign-in. Skippable.
struct SkillPickerStepView: View {
    @ObservedObject var model: OnboardingModel
    @Local private var fullHint = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            OnboardingTitle("What should Awan be good at?", size: 30)
                .padding(.top, 2)
            OnboardingSubtitle("Pick up to three. They shape how Awan answers and guide your Awans. Swap them any time in Skills.")
                .padding(.top, 6)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(SkillsCatalog.onboarding) { s in
                    PickTile(skill: s, picked: model.skillPicks.contains(s.slug)) {
                        if !model.toggleSkillPick(s.slug) { flashHint() }
                    }
                }
            }
            .padding(.top, 16)
            Spacer(minLength: 10)
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    ForEach(0 ..< SkillsStore.maxActive, id: \.self) { i in
                        Capsule()
                            .fill(i < model.skillPicks.count ? Theme.lime : Color.white.opacity(0.14))
                            .frame(width: i < model.skillPicks.count ? 18 : 7, height: 7)
                    }
                }
                .animation(Theme.spring, value: model.skillPicks.count)
                Text(fullHint ? "Three at most. Tap one to drop it." : "\(model.skillPicks.count) of \(SkillsStore.maxActive) picked")
                    .font(.awan(12.5, .medium))
                    .foregroundStyle(fullHint ? Theme.warning : Theme.textTertiary)
                Spacer()
                Button("Skip for now") { model.skillPicks = []; model.advance() }
                    .buttonStyle(.plain).font(.awan(13, .medium)).foregroundStyle(Theme.textSecondary)
                Button(model.skillPicks.isEmpty ? "Continue" : "Continue with \(model.skillPicks.count)") { model.advance() }
                    .buttonStyle(.gel(.lime, height: 38, padding: 24, fontSize: 14))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 22)
        }
        .padding(.horizontal, 36)
    }

    private func flashHint() {
        withAnimation(Theme.gentle) { fullHint = true }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(Theme.gentle) { fullHint = false }
        }
    }
}

private struct PickTile: View {
    let skill: SkillItem
    let picked: Bool
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SkillSymbolTile(symbol: skill.symbol, tint: skill.tint, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(skill.title).font(.awan(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.8)
                    Text(skill.categoryName ?? skill.category).font(.awan(11)).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle().strokeBorder(picked ? .clear : Theme.strokeStrong, lineWidth: 1.2)
                    if picked {
                        Circle().fill(Theme.lime)
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.ink)
                    }
                }
                .frame(width: 18, height: 18)
            }
            .padding(.horizontal, 10)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 14).fill(picked || hovering ? Theme.cardRaised : Theme.card.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(picked ? Theme.lime.opacity(0.8) : Theme.stroke, lineWidth: picked ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(skill.oneLiner)
    }
}
