import Foundation
import AppKit

/// Once a day between 7am and noon, if the user has pending suggestions (and wants them), Awan
/// says good morning from the notch. Backs off after three mornings dismissed in a row.
@MainActor
final class MorningSuggestions {
    static let shared = MorningSuggestions()

    private let defaults = UserDefaults.standard
    private let streakKey = "awan.suggestions.morningDismissStreak"
    private var timer: Timer?
    private var presentedAt: Date?

    /// Call once at launch.
    func start() {
        guard timer == nil, !HomeUI.isSnapshot else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in MorningSuggestions.shared.check() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                MorningSuggestions.shared.check()
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(25))
            check()
        }
    }

    /// Present the card if every condition holds.
    func check(now: Date = Date()) {
        let state = AppState.shared
        guard state.signInState == .signedIn else { return }
        Task {
            if state.suggestions.isEmpty { await state.loadSuggestions() }
            let quiet = state.companion.voiceState != .idle || state.dictation.isDictating || state.isHomeOpen || state.isPeekOpen
                || { if case .surface = NotchController.shared.mode { return true } else { return false } }()
            guard Self.shouldPresent(
                now: now,
                lastShown: defaults.object(forKey: Prefs.Key.morningSuggestionsLastShown) as? Date,
                dismissStreak: defaults.integer(forKey: streakKey),
                enabled: Prefs.shared.suggestAgentTasks,
                pending: state.suggestions.filter { $0.status == "pending" }.count,
                quiet: quiet
            ) else { return }
            present(now: now)
        }
    }

    func present(now: Date = Date()) {
        defaults.set(now, forKey: Prefs.Key.morningSuggestionsLastShown)
        // Counts as dismissed unless the user taps Show me.
        defaults.set(defaults.integer(forKey: streakKey) + 1, forKey: streakKey)
        presentedAt = now
        Sounds.play(.reveal, volume: 0.4)
        NotchController.shared.present(.morningSuggestions, for: 20)
    }

    func showMe() {
        defaults.set(0, forKey: streakKey)
        NotchController.shared.dismissSurface()
        AppState.shared.openHome(.suggestions)
    }

    func later() {
        NotchController.shared.dismissSurface()
    }

    /// Pure decision, unit-testable.
    static func shouldPresent(now: Date, lastShown: Date?, dismissStreak: Int, enabled: Bool, pending: Int, quiet: Bool,
                              calendar: Calendar = .current) -> Bool {
        guard enabled, pending > 0, !quiet else { return false }
        let hour = calendar.component(.hour, from: now)
        guard (7..<12).contains(hour) else { return false }
        if let last = lastShown {
            if calendar.isDate(last, inSameDayAs: now) { return false }
            // Three mornings waved away in a row: only try again every third day.
            if dismissStreak >= 3, let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: now)).day, days < 3 {
                return false
            }
        }
        return true
    }

    static func greeting(name: String?, count: Int, now: Date = Date()) -> String {
        let h = Calendar.current.component(.hour, from: now)
        let part = h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
        let who = name.flatMap { $0.isEmpty ? nil : ", \($0)" } ?? ""
        let ideas: String
        switch count {
        case 0: ideas = "I'll look for ideas today."
        case 1: ideas = "I have an idea for today."
        default: ideas = "I have \(count) ideas for today."
        }
        return "\(part)\(who)! \(ideas)"
    }
}
