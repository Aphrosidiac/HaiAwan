import Foundation
import AppKit
import Network
import IOKit.pwr_mgt
import IOKit.ps

/// Local routine scheduler: re-runs an Awan's task every N minutes while the Mac is awake and Awan is open.
/// Each run is an ordinary agent turn in that Awan's chat (`source: "routine"`).
/// Public API (keep): routines, routines(for:), create(slug:title:task:everyMinutes:runNow:),
///   pause(_:), resume(_:), runNow(_:), delete(_:), start()
/// Added: update(_:title:task:everyMinutes:), routine(slug:titled:), apply(_:slug:sourceTurn:),
///   turnFinished(turnID:slug:succeeded:summary:), installDemo(_:)
@MainActor
final class RoutineScheduler: ObservableObject {
    static let shared = RoutineScheduler()
    @Published private(set) var routines: [Routine] = []

    static let minimumMinutes = 2
    static let maxConsecutiveFailures = 3
    /// Hold the Mac awake (AC power only) when a run is due this soon.
    static let keepAwakeLead: TimeInterval = 5 * 60

    private let fileURL = Paths.homeCache.appendingPathComponent("routines.json")
    private var timer: Timer?
    private var started = false
    private var networkUp = true
    private let pathMonitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var assertionID: IOPMAssertionID = 0
    private var holdingAssertion = false
    private var settleUntil: Date?
    private var persistence: Bool { AgentStore.persistenceEnabled }

    private init() {
        if persistence { load() }
    }

    // MARK: - Queries

    func routines(for slug: String) -> [Routine] { routines.filter { $0.slug == slug }.sorted { $0.createdAt < $1.createdAt } }

    func routine(slug: String, titled title: String) -> Routine? {
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        return routines.first { $0.slug == slug && $0.title.lowercased() == t }
    }

    // MARK: - Mutations

    @discardableResult
    func create(slug: String, title: String, task: String, everyMinutes: Int, runNow: Bool) -> Routine {
        let minutes = max(Self.minimumMinutes, everyMinutes)
        let r = Routine(slug: slug, title: title, task: task, intervalMinutes: minutes, nextRunAt: runNow ? Date() : Date().addingTimeInterval(Double(minutes) * 60))
        routines.append(r)
        save()
        Log.info("routine created \(r.id) \(slug) every \(minutes)m: \(title)")
        if runNow { fire(r.id, trigger: "manual") }
        return r
    }

    func update(_ id: String, title: String? = nil, task: String? = nil, everyMinutes: Int? = nil) {
        mutate(id) { r in
            if let title, !title.isEmpty { r.title = title }
            if let task, !task.isEmpty { r.task = task }
            if let everyMinutes {
                r.intervalMinutes = max(Self.minimumMinutes, everyMinutes)
                let base = r.lastRunStartedAt ?? Date()
                r.nextRunAt = max(Date().addingTimeInterval(60), base.addingTimeInterval(Double(r.intervalMinutes) * 60))
            }
        }
    }

    func pause(_ id: String) { mutate(id) { $0.isPaused = true; $0.autoPaused = nil } }

    func resume(_ id: String) {
        mutate(id) { r in
            r.isPaused = false
            r.autoPaused = nil
            r.consecutiveFailures = 0
            if r.nextRunAt < Date() { r.nextRunAt = Date().addingTimeInterval(Double(r.intervalMinutes) * 60) }
        }
    }

    func runNow(_ id: String) { fire(id, trigger: "manual") }

    func delete(_ id: String) {
        routines.removeAll { $0.id == id }
        save()
    }

    /// Demo/snapshot data only (never persisted).
    func installDemo(_ demo: [Routine]) { routines = demo }

    /// Applies a `<ROUTINE>` command from an agent's final message. Returns a short note for the progress list.
    @discardableResult
    func apply(_ cmd: RoutineCommand, slug: String, sourceTurn: AgentTurn?) -> String? {
        switch cmd.action {
        case .create:
            // A routine run never spawns another routine; an existing title is an update, not a twin.
            if sourceTurn?.source == "routine" { return nil }
            guard let task = cmd.task, let minutes = cmd.everyMinutes else { return nil }
            let title = cmd.title ?? String(task.prefix(32))
            if let existing = routine(slug: slug, titled: title) {
                update(existing.id, task: task, everyMinutes: minutes)
                if existing.isPaused { resume(existing.id) }
                return "Updated routine “\(title)”"
            }
            let r = create(slug: slug, title: title, task: task, everyMinutes: minutes, runNow: false)
            return "Scheduled “\(r.title)” · \(r.cadenceText.lowercased())"
        case .update:
            guard let title = cmd.title, let r = routine(slug: slug, titled: title) else { return nil }
            update(r.id, title: cmd.newTitle, task: cmd.task, everyMinutes: cmd.everyMinutes)
            return "Updated routine “\(cmd.newTitle ?? r.title)”"
        case .pause:
            guard let title = cmd.title, let r = routine(slug: slug, titled: title) else { return nil }
            pause(r.id)
            return "Paused routine “\(r.title)”"
        case .resume:
            guard let title = cmd.title, let r = routine(slug: slug, titled: title) else { return nil }
            resume(r.id)
            return "Resumed routine “\(r.title)”"
        case .delete:
            guard let title = cmd.title, let r = routine(slug: slug, titled: title) else { return nil }
            delete(r.id)
            return "Deleted routine “\(r.title)”"
        }
    }

    /// Called by AgentRunner when any turn ends; closes the loop for routine runs.
    func turnFinished(turnID: String, slug: String, succeeded: Bool, summary: String?) {
        guard let r = routines.first(where: { $0.lastRunTurnID == turnID }) else { return }
        mutate(r.id) { r in
            r.lastRunFinishedAt = Date()
            r.lastRunFailed = !succeeded
            if let summary { r.lastRunSummary = summary }
            if succeeded {
                r.consecutiveFailures = 0
            } else {
                r.consecutiveFailures += 1
                if r.consecutiveFailures >= Self.maxConsecutiveFailures {
                    r.isPaused = true
                    r.autoPaused = true
                    Log.info("routine \(r.id) auto-paused after \(r.consecutiveFailures) failures")
                } else {
                    // Retry sooner than the full interval, but never hammer.
                    let retry = Date().addingTimeInterval(min(Double(r.intervalMinutes) * 60, Double(5 * 60 * r.consecutiveFailures)))
                    r.nextRunAt = min(r.nextRunAt, retry)
                }
            }
        }
    }

    // MARK: - Engine

    func start() {
        guard !started else { return }
        started = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.networkChanged(up) } }
        }
        pathMonitor.start(queue: DispatchQueue(label: "awan.routines.network"))
        let ws = NSWorkspace.shared.notificationCenter
        wakeObserver = ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        sleepObserver = ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseKeepAwake() }
        }
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func networkChanged(_ up: Bool) {
        let was = networkUp
        networkUp = up
        if up && !was { tick() }
    }

    /// After sleep, let Wi-Fi settle, then catch up: every overdue routine runs ONCE (not once per missed slot).
    private func didWake() {
        settleUntil = Date().addingTimeInterval(20)
        DispatchQueue.main.asyncAfter(deadline: .now() + 21) { [weak self] in self?.tick() }
    }

    private func tick() {
        updateKeepAwake()
        if let s = settleUntil, s > Date() { return }
        settleUntil = nil
        let now = Date()
        for r in routines where !r.isPaused && r.nextRunAt <= now {
            if !networkUp {
                if r.waitingForNetworkSince == nil { mutate(r.id) { $0.waitingForNetworkSince = now } }
                continue
            }
            // One run at a time per Awan: if it's busy, try again shortly.
            if AgentStore.shared.runner.isRunning(r.slug) {
                mutate(r.id) { $0.nextRunAt = now.addingTimeInterval(60) }
                continue
            }
            fire(r.id, trigger: "scheduled")
        }
    }

    private func fire(_ id: String, trigger: String) {
        guard let r = routines.first(where: { $0.id == id }) else { return }
        guard AgentStore.shared.agent(r.slug) != nil else {
            Log.error("routine \(r.id) points at a missing Awan \(r.slug); pausing")
            mutate(id) { $0.isPaused = true }
            return
        }
        let turnID = AgentStore.shared.send(r.task, to: r.slug, display: "Routine: \(r.title)", source: "routine")
        mutate(id) { r in
            let now = Date()
            r.runCount += 1
            r.lastRunStartedAt = now
            r.lastRunTurnID = turnID
            r.waitingForNetworkSince = nil
            // Catch-up runs once, then realigns to the interval from now.
            r.nextRunAt = now.addingTimeInterval(Double(r.intervalMinutes) * 60)
        }
        Log.info("routine \(id) fired (\(trigger)) → turn \(turnID ?? "-")")
    }

    // MARK: - Keep awake (AC power only, only when a run is imminent)

    private func updateKeepAwake() {
        let soon = Date().addingTimeInterval(Self.keepAwakeLead)
        let imminent = routines.contains { !$0.isPaused && $0.nextRunAt <= soon }
        let routineRunning = routines.contains { r in r.lastRunTurnID != nil && AgentStore.shared.thread(r.slug).activeTurn?.id == r.lastRunTurnID }
        if (imminent || routineRunning) && Self.onACPower() {
            guard !holdingAssertion else { return }
            let reason = "Awan has a routine due" as CFString
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertionID) == kIOReturnSuccess {
                holdingAssertion = true
            }
        } else {
            releaseKeepAwake()
        }
    }

    private func releaseKeepAwake() {
        guard holdingAssertion else { return }
        IOPMAssertionRelease(assertionID)
        holdingAssertion = false
    }

    static func onACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }

    // MARK: - Persistence

    private func mutate(_ id: String, _ change: (inout Routine) -> Void) {
        guard let i = routines.firstIndex(where: { $0.id == id }) else { return }
        change(&routines[i])
        save()
    }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let r = try? dec.decode([Routine].self, from: data) { routines = r }
    }

    private func save() {
        guard persistence else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(routines) { try? data.write(to: fileURL, options: .atomic) }
    }
}
