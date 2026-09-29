import SwiftUI

/// Settings → Developer (internal): model lane, reasoning effort, previews, API base URL.
struct DeveloperSettings: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var prefs = Prefs.shared
    @Local private var baseURL = Prefs.shared.apiBaseURL

    static let lanes: [(String, String)] = [
        ("awan-agent", "Awan default lane"),
        ("openai/gpt-5.1-codex", "OpenRouter"),
        ("anthropic/claude-sonnet-4.5", "OpenRouter"),
        ("google/gemini-2.5-pro", "OpenRouter"),
        ("x-ai/grok-code-fast-1", "OpenRouter"),
        ("qwen/qwen3-coder", "OpenRouter"),
    ]
    static let efforts: [(String, String)] = [("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "X-High")]

    var body: some View {
        SettingsPageHeader(title: "Developer", subtitle: "Previews and debug tools. Hidden from everyone else.")

        if !DeveloperMode.isEnabled {
            Label("Developer tools are off. Option-click the version number in General to turn them on.", systemImage: "lock.fill")
                .font(.awan(12.5)).foregroundStyle(Theme.textSecondary)
                .settingsCard()
        }

        SettingsGroup(label: "Agent model", footer: "Applies to the next agent turn. \"awan-agent\" lets the server pick.") {
            ForEach(Array(Self.lanes.enumerated()), id: \.offset) { i, lane in
                Button { prefs.modelLane = lane.0 } label: {
                    SettingsRow(title: lane.0, subtitle: lane.1, showDivider: i < Self.lanes.count - 1) {
                        if prefs.modelLane == lane.0 {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.lime)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }

        SettingsGroup(label: "Reasoning effort") {
            HStack {
                PillSegmented(options: Self.efforts, selection: $prefs.reasoningEffort)
                Spacer(minLength: 0)
            }
            .padding(12)
        }

        SettingsGroup(label: "Previews") {
            SettingsRow(title: "Paywall", subtitle: "Shows the upgrade card as if you hit a limit.") {
                SmallPillButton(title: "Preview") { state.presentPaywall(.limitHit) }
            }
            SettingsRow(title: "Onboarding", subtitle: "Runs the intro, tour and interview again.") {
                SmallPillButton(title: "Replay") { state.closeHome(); OnboardingController.shared.replay() }
            }
            SettingsRow(title: "Suggestions", subtitle: "Asks the server for a fresh batch now.") {
                SmallPillButton(title: "Refresh") { Task { await state.refreshSuggestions(); state.show("Suggestions refreshed.") } }
            }
            SettingsRow(title: "Morning notch", subtitle: "Shows the morning suggestions card in the notch.", showDivider: false) {
                SmallPillButton(title: "Show") { NotchController.shared.present(.morningSuggestions, for: 12) }
            }
        }

        SettingsGroup(label: "Server", footer: "Where Awan's API lives. Restart Awan after changing it.") {
            HStack(spacing: 8) {
                SettingsTextField(placeholder: "http://127.0.0.1:8787", text: $baseURL, mono: true) { save() }
                Button("Save", action: save)
                    .buttonStyle(.gel(.bone, height: 34, padding: 16, fontSize: 13))
                    .disabled(baseURL == prefs.apiBaseURL || URL(string: baseURL)?.host == nil)
            }
            .padding(12)
        }
    }

    private func save() {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let u = URL(string: trimmed), u.host != nil else { return }
        prefs.apiBaseURL = trimmed
        baseURL = trimmed
        state.show("API base set to \(u.host ?? trimmed).")
    }
}
