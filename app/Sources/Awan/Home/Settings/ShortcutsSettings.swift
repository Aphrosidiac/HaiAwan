import SwiftUI

/// Settings → Shortcuts: every global shortcut, each with a recorder.
struct ShortcutsSettings: View {
    @ObservedObject private var prefs = Prefs.shared
    @Local private var recording: WritableKeyPath<ShortcutSet, HotkeyBinding>? = nil
    @Local private var conflict: String? = nil

    struct Item {
        let key: WritableKeyPath<ShortcutSet, HotkeyBinding>
        let title: String
        let subtitle: String
    }

    static let talk: [Item] = [
        .init(key: \.talk, title: "Push to talk", subtitle: "Hold to talk to Awan. Let go to send."),
        .init(key: \.text, title: "Text mode", subtitle: "Type to Awan instead of talking."),
    ]
    static let dictation: [Item] = [
        .init(key: \.dictate, title: "Dictate", subtitle: "Hold and speak. Let go and your words land at your cursor."),
        .init(key: \.handsFreeDictate, title: "Hands-free dictation", subtitle: "No holding: start once, stop when you're done."),
    ]
    static let home: [Item] = [
        .init(key: \.openHome, title: "Open Home", subtitle: "Bring up your Awans from anywhere."),
    ]
    static let handoff: [Item] = [
        .init(key: \.handoff, title: "Send a screen region", subtitle: "Hold, then drag a box around anything. Ask Awan about it, send it to an Awan, or paste it into another app."),
    ]

    var body: some View {
        SettingsPageHeader(title: "Shortcuts", subtitle: "The keys that summon Awan.")

        SettingsGroup(label: "Talk to Awan") { rows(Self.talk) }
        SettingsGroup(label: "Dictation") { rows(Self.dictation) }
        // Awan-only shortcuts, after the reference's two groups.
        SettingsGroup(label: "Home") { rows(Self.home) }
        SettingsGroup(label: "Handoff") { rows(Self.handoff) }

        if let conflict {
            Label(conflict, systemImage: "exclamationmark.triangle.fill")
                .font(.awan(12)).foregroundStyle(Theme.warning)
        }

        // Reference: a lone title-only card; the whole row resets.
        SettingsGroup {
            SettingsButtonRow(title: "Reset to defaults", trailingSymbol: nil, showDivider: false) {
                prefs.shortcuts = .defaults
                conflict = nil
                recording = nil
            }
            .disabled(prefs.shortcuts == .defaults && !SettingsEnv.isSnapshot)
        }
    }

    @ViewBuilder private func rows(_ items: [Item]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
            SettingsRow(title: item.title, subtitle: item.subtitle, showDivider: i < items.count - 1) {
                HStack(spacing: 11) {
                    if recording == item.key {
                        Text("Press your new shortcut…")
                            .font(.awan(12.5, .medium)).foregroundStyle(Theme.lime)
                            .padding(.horizontal, 10).frame(height: 20)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.lime.opacity(0.10)))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.lime.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        Button("Cancel") { recording = nil }
                            .buttonStyle(.gel(.bone, height: 24, padding: 8, fontSize: 14))
                    } else {
                        ShortcutKeys(binding: prefs.shortcuts[keyPath: item.key])
                        Button("Change") { record(item) }
                            .buttonStyle(.gel(.bone, height: 24, padding: 8, fontSize: 14))
                    }
                }
                .padding(.trailing, 1.5)
            }
        }
    }

    private func record(_ item: Item) {
        conflict = nil
        recording = item.key
        HotkeyMonitor.shared.recordNext { binding in
            defer { if recording == item.key { recording = nil } }
            guard let binding else { return }
            let all = Self.talk + Self.dictation + Self.home + Self.handoff
            if let clash = all.first(where: { $0.key != item.key && prefs.shortcuts[keyPath: $0.key] == binding }) {
                conflict = "That's already used by \(clash.title). Pick a different combo."
                return
            }
            prefs.shortcuts[keyPath: item.key] = binding
        }
    }
}

/// "⌃ control  ⌥ option" as keycaps (reference: 20 pt caps, white 10 %, mono labels; a double-tap
/// shows the combination twice, fn after the modifiers).
struct ShortcutKeys: View {
    let binding: HotkeyBinding
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in ShortcutKeycap(label: k) }
        }
        .help(binding.summary)
    }

    private var keys: [String] {
        let one = binding.displayKeys.filter { $0 != "fn" } + (binding.displayKeys.contains("fn") ? ["fn"] : [])
        return binding.trigger == .doubleTap ? one + one : one
    }

    /// "⌃ control" → "⌃", keeps "fn", "A", "space".
    static func short(_ key: String) -> String {
        let parts = key.split(separator: " ")
        return parts.count == 2 ? String(parts[0]) : key
    }
}

struct ShortcutKeycap: View {
    let label: String
    var body: some View {
        let parts = label.split(separator: " ", maxSplits: 1).map(String.init)
        HStack(spacing: 5) {
            if parts.count == 2 {
                Text(parts[0]).font(.system(size: 12, weight: .bold))
                Text(parts[1]).font(.awanMono(12, .semibold))
            } else {
                Text(label).font(.awanMono(12, .semibold))
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 7.5)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(Color.white.opacity(0.1)))
    }
}
