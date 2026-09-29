import AppKit
import Foundation

/// Once a day, the first time the Mac wakes or unlocks (or Awan starts) between 5am and noon, Awan arms
/// for 10 s and then says one short cheerful line, shown beside the cursor too. Always on, but skipped
/// while on a call / sharing the screen, while Awan is busy, with always-on voice on, or when the Mac
/// is muted. A skipped morning tries again on the next wake or unlock.
@MainActor
final class MorningGreeting {
    static let shared = MorningGreeting()

    static let lastDayKey = "awan.morningGreeting.lastGreetedDay"
    static let armDelay: Double = 10

    /// Awan's own lines (lowercase, short, warm).
    static let lines = [
        "morning! stretch it out, sip something warm, then we get going.",
        "selamat pagi! fresh day, clean slate. i'm ready when you are.",
        "good morning. one small win at a time today, that's the plan.",
        "morning, sunshine. take it slow, i've got the busywork.",
        "hey, good morning! whatever's on the list, we'll chip away at it.",
        "morning! the coffee's on you, the tedious stuff's on me.",
        "good morning. hope you slept well. let's warm up gently.",
        "morning! new day, new tabs. shout if you need a hand.",
    ]

    private var armTask: Task<Void, Never>?
    private var started = false

    func start() {
        guard !started, !HomeUI.isSnapshot else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MorningGreeting.shared.arm() }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MorningGreeting.shared.arm() }
        }
        arm()   // launching Awan in the morning counts as the first "hello"
    }

    /// A wake/unlock happened: greet in 10 s if it's still a good moment.
    func arm() {
        guard Self.isEligible(now: Date(), lastGreetedDay: UserDefaults.standard.string(forKey: Self.lastDayKey)) else { return }
        armTask?.cancel()
        armTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.armDelay))
            guard !Task.isCancelled else { return }
            self?.greetIfAppropriate()
        }
    }

    private func greetIfAppropriate(now: Date = Date()) {
        let defaults = UserDefaults.standard
        guard Self.isEligible(now: now, lastGreetedDay: defaults.string(forKey: Self.lastDayKey)) else { return }
        let state = AppState.shared
        let companion = state.companion
        let blockers = Self.blockers(
            alwaysOnVoice: Prefs.shared.alwaysOnVoice,
            muted: SystemAudio.isMuted,
            quiet: companion.isQuiet,
            busy: companion.voiceState != .idle || companion.isTextComposerOpen || state.dictation.isDictating,
            onboarding: !Prefs.shared.onboardingCompleted
        )
        guard blockers.isEmpty else {
            Log.info("morning greeting skipped: \(blockers.joined(separator: ", "))")
            return
        }
        defaults.set(Self.dayKey(now), forKey: Self.lastDayKey)
        let line = Self.line(for: now)
        Log.info("morning greeting: \(line)")
        CursorOverlayController.shared.showCursorBubble(line)
        companion.announce(line)
    }

    // MARK: - Pure decisions (checked by --selftest)

    static func isEligible(now: Date, lastGreetedDay: String?, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        guard (5..<12).contains(hour) else { return false }
        return lastGreetedDay != dayKey(now, calendar: calendar)
    }

    static func blockers(alwaysOnVoice: Bool, muted: Bool, quiet: Bool, busy: Bool, onboarding: Bool) -> [String] {
        var out: [String] = []
        if alwaysOnVoice { out.append("always-on voice") }
        if muted { out.append("muted") }
        if quiet { out.append("on a call") }
        if busy { out.append("busy") }
        if onboarding { out.append("onboarding") }
        return out
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A different line each day, stable within a day.
    static func line(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let day = (c.year ?? 0) * 372 + (c.month ?? 0) * 31 + (c.day ?? 0)
        return lines[day % lines.count]
    }
}
