import AppKit
import EventKit
import SwiftUI

/// Upcoming meetings (reference: /me/calendar/upcoming + NotchMeetingCountdownSurface). Awan reads the local
/// calendars with EventKit instead of a server-side calendar connection: today's next event that carries a
/// video link (Zoom, Meet, Teams, Webex, Around, Whereby…). Five minutes before it starts the notch shows
/// "Meeting starting soon: <title> · in 4 min" with Join; Home's empty view shows "Next: <title> at 10:30 · Join".
/// Off by default — Settings → General → "Upcoming meetings" asks for calendar access when first turned on.
@MainActor
final class MeetingMonitor: ObservableObject {
    static let shared = MeetingMonitor()
    static let enabledKey = "awan.general.upcomingMeetings"
    static let leadTime: TimeInterval = 5 * 60

    @Published private(set) var enabled: Bool
    @Published private(set) var next: UpcomingMeeting?
    /// The meeting the notch countdown is showing.
    @Published private(set) var countdown: UpcomingMeeting?
    @Published private(set) var accessDenied = false

    private let store = EKEventStore()
    private var timer: Timer?
    private var announced = Set<String>()
    private var started = false

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func start() {
        guard !started, !SettingsEnv.isSnapshot else { return }
        started = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in MeetingMonitor.shared.refresh() }
        }
        if enabled { schedule() }
    }

    /// Settings toggle. Turning it on asks for full calendar access (once); a refusal turns it back off.
    func setEnabled(_ on: Bool) {
        guard on else {
            enabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            stop()
            return
        }
        enabled = true
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        Task {
            let granted = await requestAccess()
            accessDenied = !granted
            if granted { schedule() } else {
                enabled = false
                UserDefaults.standard.set(false, forKey: Self.enabledKey)
            }
        }
    }

    private func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .denied, .restricted, .writeOnly: return false
        default:
            return (try? await store.requestFullAccessToEvents()) ?? false
        }
    }

    private func schedule() {
        timer?.invalidate()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingMonitor.shared.tick() }
        }
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        next = nil
        if countdown != nil { dismissCountdown() }
    }

    private var lastFetch = Date.distantPast

    /// Re-reads today's calendar (at most once a minute from the timer; immediately on store changes).
    func refresh() {
        guard enabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        lastFetch = Date()
        let now = Date()
        let end = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-10 * 60), end: end, calendars: nil)
        let events = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
        next = events.lazy.compactMap { e -> UpcomingMeeting? in
            guard let link = MeetingLinks.find(in: [e.url?.absoluteString, e.location, e.notes]) else { return nil }
            return UpcomingMeeting(id: "\(e.calendarItemIdentifier)@\(Int(e.startDate.timeIntervalSince1970))", title: e.title ?? "Meeting",
                                   start: e.startDate, end: e.endDate, joinURL: link)
        }.first { $0.end > now && $0.start > now.addingTimeInterval(-5 * 60) }
        tick()
    }

    func tick(now: Date = Date()) {
        if now.timeIntervalSince(lastFetch) > 60 { refresh(); return }
        if let c = countdown, now > c.start.addingTimeInterval(3 * 60) { dismissCountdown() }
        guard let m = next, Self.shouldAnnounce(m, now: now), !announced.contains(m.id) else { return }
        announced.insert(m.id)
        countdown = m
        Sounds.play(.question, volume: 0.45)
        NotchController.shared.present(.meetingCountdown, for: 90)
    }

    static func shouldAnnounce(_ m: UpcomingMeeting, now: Date) -> Bool {
        let lead = m.start.timeIntervalSince(now)
        return lead <= leadTime && lead > -60
    }

    func join(_ m: UpcomingMeeting) {
        NSWorkspace.shared.open(m.joinURL)
        dismissCountdown()
    }

    func dismissCountdown() {
        countdown = nil
        if NotchController.shared.mode == .surface(.meetingCountdown) { NotchController.shared.dismissSurface() }
    }

    /// Snapshot/demo only.
    func debugInstall(next: UpcomingMeeting?, countdown: UpcomingMeeting?) {
        self.next = next
        self.countdown = countdown
        enabled = true
    }
}

struct UpcomingMeeting: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let joinURL: URL

    /// "in 4 min" · "in 45 s" · "now" · "started 2 min ago"
    static func countdownText(until start: Date, now: Date = Date()) -> String {
        let s = Int(start.timeIntervalSince(now).rounded())
        if s > 90 { return "in \(Int((Double(s) / 60).rounded(.up))) min" }
        if s > 0 { return "in \(s) s" }
        if s > -60 { return "starting now" }
        return "started \(-s / 60) min ago"
    }

    /// "10:30 am"
    var clock: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f.string(from: start).lowercased()
    }
}

/// Finds a joinable video-call link in free text (event URL, location, notes).
enum MeetingLinks {
    private static let patterns = [
        #"https?://[\w.-]*zoom\.us/(j|my|w|s)/[^\s<>"')]+"#,
        #"https?://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\s<>"')]*"#,
        #"https?://teams\.microsoft\.com/l/meetup-join/[^\s<>"')]+"#,
        #"https?://teams\.live\.com/meet/[^\s<>"')]+"#,
        #"https?://[\w.-]*webex\.com/[^\s<>"')]+"#,
        #"https?://whereby\.com/[^\s<>"')]+"#,
        #"https?://(app\.)?around\.co/[^\s<>"')]+"#,
        #"https?://meet\.jit\.si/[^\s<>"')]+"#,
        #"https?://[\w.-]*chime\.aws/[^\s<>"')]+"#,
        #"https?://facetime\.apple\.com/join[^\s<>"')]+"#,
    ]
    private static let regexes: [NSRegularExpression] = patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func find(in fields: [String?]) -> URL? {
        for field in fields.compactMap({ $0 }) where !field.isEmpty {
            let ns = field as NSString
            for re in regexes {
                if let m = re.firstMatch(in: field, range: NSRange(location: 0, length: ns.length)) {
                    var s = ns.substring(with: m.range)
                    while let last = s.last, ".,;:>".contains(last) { s.removeLast() }
                    if let u = URL(string: s) { return u }
                }
            }
        }
        return nil
    }
}

// MARK: - Views

/// Notch card: "Meeting starting soon: Standup · in 4 min" — Join / ×.
struct MeetingCountdownSurface: View {
    @ObservedObject private var monitor = MeetingMonitor.shared

    var body: some View {
        if let m = monitor.countdown ?? monitor.next {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.bone)
                    VStack(spacing: 0) {
                        Text(Self.month(m.start)).font(.awan(8.5, .bold)).foregroundStyle(Theme.danger)
                        Text(Self.day(m.start)).font(.awan(17, .semibold)).foregroundStyle(Theme.ink)
                    }
                }
                .frame(width: 40, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Meeting starting soon").font(.awan(11.5, .semibold)).foregroundStyle(Theme.textTertiary)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        HStack(spacing: 6) {
                            Text(m.title).font(.awan(14.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            Text("·").foregroundStyle(Theme.textTertiary)
                            Text(UpcomingMeeting.countdownText(until: m.start, now: ctx.date))
                                .font(.awan(13.5, .medium)).foregroundStyle(Theme.lime).monospacedDigit().fixedSize()
                        }
                    }
                }
                Spacer(minLength: 6)
                Button { monitor.join(m) } label: { Label("Join", systemImage: "video.fill") }
                    .buttonStyle(.gel(.lime, height: 30, padding: 14, fontSize: 12.5))
                    .fixedSize()
                CircleIconButton(systemName: "xmark", size: 26, help: "Dismiss") { monitor.dismissCountdown() }
            }
            .padding(.horizontal, 22).padding(.top, 38)
        }
    }

    static func month(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MMM"; return f.string(from: d).uppercased() }
    static func day(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "d"; return f.string(from: d) }
}

/// Home empty view, under the greeting: "Next: Standup at 10:30 am · Join".
struct NextMeetingRow: View {
    @ObservedObject private var monitor = MeetingMonitor.shared

    var body: some View {
        if monitor.enabled, let m = monitor.next {
            HStack(spacing: 8) {
                Image(systemName: "calendar").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                Text("Next: ").font(.awan(12.5)).foregroundStyle(Theme.textTertiary)
                    + Text(m.title).font(.awan(12.5, .semibold)).foregroundStyle(Theme.text)
                    + Text(" at \(m.clock)").font(.awan(12.5)).foregroundStyle(Theme.textSecondary)
                Text("·").foregroundStyle(Theme.textTertiary)
                Button { monitor.join(m) } label: {
                    HStack(spacing: 3) {
                        Text("Join").font(.awan(12.5, .semibold))
                        Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .bold))
                    }
                    .foregroundStyle(Theme.lime)
                }
                .buttonStyle(.plain)
            }
            .lineLimit(1)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
        }
    }
}

/// Settings → General row (added in wave 2).
struct UpcomingMeetingsToggle: View {
    @ObservedObject private var monitor = MeetingMonitor.shared
    var body: some View {
        SettingToggle(
            title: "Upcoming meetings",
            subtitle: monitor.accessDenied
                ? "Awan can't read your calendars. Allow it in System Settings → Privacy & Security → Calendars."
                : "Five minutes before a call with a video link, the notch shows a countdown with Join. Reads your Mac's calendars; nothing leaves this Mac.",
            isOn: Binding(get: { monitor.enabled }, set: { monitor.setEnabled($0) }),
            showDivider: false
        )
    }
}
