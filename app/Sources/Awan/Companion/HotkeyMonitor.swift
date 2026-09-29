// Adapted from farzaa/clicky (MIT) — GlobalPushToTalkShortcutMonitor's listen-only CGEvent tap.
import AppKit
import Combine
import CoreGraphics

/// Global shortcuts: talk (hold ⌃⌥), text (double-tap ⌃), dictate (hold fn⌃), hands-free dictate (double-tap fn⌃),
/// always-on voice (triple-tap ⌃), open Home (⌃⌘A), Esc (interrupt). Bindings come from `Prefs.shared.shortcuts`.
///
/// A listen-only CGEvent tap (needs Input Monitoring) sees modifier-only combos system-wide; without it we fall back
/// to NSEvent global + local monitors (needs Accessibility for key events) and retry the tap every few seconds.
/// Keep: shared, start(), stop(), hasPermission, recordNext(completion:).
@MainActor final class HotkeyMonitor {
    static let shared = HotkeyMonitor()

    /// The system-wide tap is running (Input Monitoring granted).
    private(set) var hasPermission = false
    /// Running on NSEvent monitors because the tap couldn't be created.
    private(set) var usingFallback = false

    private var machine = HotkeyStateMachine(shortcuts: .defaults)
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var monitors: [Any] = []
    private var retryTimer: Timer?
    private var pendingTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var ignoredTalk = false
    private var ignoredDictate = false
    private var recorder: HotkeyRecorder?
    private static let clock = { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard !started else { return }
        started = true
        machine.shortcuts = Prefs.shared.shortcuts
        Prefs.shared.$shortcuts.sink { [weak self] s in self?.machine.shortcuts = s }.store(in: &cancellables)
        if !installTap() {
            installFallback()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let me = HotkeyMonitor.shared
                    if CGPreflightListenEventAccess(), me.installTap() { me.removeFallback(); me.retryTimer?.invalidate(); me.retryTimer = nil }
                }
            }
        }
    }

    func stop() {
        started = false
        retryTimer?.invalidate(); retryTimer = nil
        pendingTimer?.invalidate(); pendingTimer = nil
        removeFallback()
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil; tapSource = nil
        hasPermission = false
        cancellables.removeAll()
    }

    /// Settings → Shortcuts "Change": capture the next hold/double-tap combo the user performs (nil = cancelled / timed out).
    func recordNext(completion: @escaping (HotkeyBinding?) -> Void) {
        recorder?.finish(nil)
        recorder = HotkeyRecorder { [weak self] b in
            self?.recorder = nil
            completion(b)
        }
        if !started { start() }
    }

    // MARK: - Tap

    @discardableResult
    private func installTap() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            if let info {
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.handleTap(type: type, event: event) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            if !usingFallback { Log.info("hotkeys: no Input Monitoring permission — using fallback monitors") }
            hasPermission = false
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        tap = port
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        hasPermission = true
        Log.info("hotkeys: event tap installed")
        return true
    }

    private func handleTap(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            handleFlags(NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)))
        case .keyDown:
            handleKeyDown(UInt16(event.getIntegerValueField(.keyboardEventKeycode)), flags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
                          isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp:
            handleKeyUp(UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
        default:
            break
        }
    }

    // MARK: - Fallback monitors

    private func installFallback() {
        guard monitors.isEmpty else { return }
        usingFallback = true
        let handler: (NSEvent) -> Void = { e in
            MainActor.assumeIsolated {
                let me = HotkeyMonitor.shared
                switch e.type {
                case .flagsChanged: me.handleFlags(e.modifierFlags)
                case .keyDown: me.handleKeyDown(e.keyCode, flags: e.modifierFlags, isRepeat: e.isARepeat)
                case .keyUp: me.handleKeyUp(e.keyCode)
                default: break
                }
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp], handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp], handler: { e in handler(e); return e }) { monitors.append(l) }
        if !AXIsProcessTrusted() { Log.info("hotkeys: no Accessibility either — shortcuts only work while Awan is frontmost") }
    }

    private func removeFallback() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        usingFallback = false
    }

    // MARK: - Events → state machine → actions

    private func handleFlags(_ flags: NSEvent.ModifierFlags) {
        let t = Self.clock()
        if let recorder { recorder.flags(flags.intersection(HotkeyStateMachine.relevant), at: t); return }
        perform(machine.flags(flags, at: t))
        schedulePending()
    }

    private func handleKeyDown(_ code: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool) {
        let t = Self.clock()
        if let recorder { recorder.keyDown(code, flags: flags.intersection(HotkeyStateMachine.relevant)); return }
        perform(machine.keyDown(code, flags: flags, isRepeat: isRepeat, at: t))
    }

    private func handleKeyUp(_ code: UInt16) {
        guard recorder == nil else { return }
        perform(machine.keyUp(code, at: Self.clock()))
    }

    private func schedulePending() {
        pendingTimer?.invalidate()
        guard let deadline = machine.pendingDeadline else { return }
        pendingTimer = Timer.scheduledTimer(withTimeInterval: max(0.01, deadline - Self.clock()), repeats: false) { _ in
            MainActor.assumeIsolated {
                let me = HotkeyMonitor.shared
                me.perform(me.machine.tick(at: Self.clock()))
                me.schedulePending()
            }
        }
    }

    private func perform(_ outputs: [HotkeyStateMachine.Output]) {
        let companion = CompanionEngine.shared
        let dictation = DictationManager.shared
        for o in outputs {
            Log.info("hotkey \(o.action.rawValue) \(o.phase)")
            switch (o.action, o.phase) {
            case (.talk, .pressed):
                ignoredTalk = dictation.isDictating
                if !ignoredTalk { companion.beginListening() }
            case (.talk, .released):
                if !ignoredTalk { companion.endListening() }
            case (.talk, .cancelled):
                if !ignoredTalk { companion.abortListening() }
            case (.dictate, .pressed):
                ignoredDictate = companion.voiceState == .listening
                if dictation.isHandsFree { dictation.stop(); ignoredDictate = true }
                if !ignoredDictate { dictation.start(handsFree: false) }
            case (.dictate, .released):
                if !ignoredDictate { dictation.stop() }
            case (.dictate, .cancelled):
                if !ignoredDictate { dictation.cancel() }
            case (.handsFreeDictate, _):
                if companion.voiceState == .listening { break }
                if dictation.isHandsFree { dictation.stop() } else { dictation.start(handsFree: true) }
            case (.text, _):
                companion.openTextComposer()
            case (.alwaysOn, _):
                companion.toggleAlwaysOn()
            case (.openHome, _):
                HomeWindowController.shared.toggle()
            case (.handoff, .pressed):
                HandoffManager.shared.beginRegionSelect()
            case (.escape, _):
                companion.handleEscape()
            default:
                break
            }
        }
    }
}

// MARK: - The pure state machine (unit-tested)

enum HotkeyAction: String { case talk, text, dictate, handsFreeDictate, openHome, alwaysOn, escape, handoff }
enum HotkeyPhase: Equatable { case pressed, released, cancelled, fired }

/// Turns modifier/key events into shortcut actions. No timers, no globals: time comes in, actions come out.
/// `pendingDeadline` asks the caller to call `tick(at:)` (double-tap ⌃ waits briefly for a third tap).
struct HotkeyStateMachine {
    struct Output: Equatable { var action: HotkeyAction; var phase: HotkeyPhase }
    typealias Flags = NSEvent.ModifierFlags
    static let relevant: Flags = [.control, .option, .shift, .command, .function]

    var shortcuts: ShortcutSet
    var tripleTapModifiers: Flags = .control
    /// A press shorter than this is a tap (and cancels a hold that just started).
    var tapMaxDuration: TimeInterval = 0.28
    /// Max gap between one tap's release and the next tap's press.
    var tapGap: TimeInterval = 0.35
    /// A key joining a modifier-only hold this soon means "that was a shortcut", so the hold is cancelled.
    var holdCancelWindow: TimeInterval = 0.6

    private(set) var pendingDeadline: TimeInterval?
    private var current: Flags = []
    private var pressStart: TimeInterval = 0
    private var pressMax: Flags = []
    private var pressDirty = false
    private var pressConsumed = false
    private var activeHold: (action: HotkeyAction, mods: Flags, keyCode: UInt16?, since: TimeInterval)?
    private var tapMods: Flags = []
    private var tapCount = 0
    private var lastTapEnd: TimeInterval = -100

    init(shortcuts: ShortcutSet) { self.shortcuts = shortcuts }

    static func mods(_ b: HotkeyBinding) -> Flags { Flags(rawValue: b.modifiers).intersection(relevant) }

    private var bindings: [(HotkeyAction, HotkeyBinding)] {
        [(.talk, shortcuts.talk), (.text, shortcuts.text), (.dictate, shortcuts.dictate),
         (.handsFreeDictate, shortcuts.handsFreeDictate), (.openHome, shortcuts.openHome), (.handoff, shortcuts.handoff)]
    }

    private func holdAction(mods: Flags) -> HotkeyAction? {
        bindings.first { $0.1.trigger == .hold && $0.1.keyCode == nil && Self.mods($0.1) == mods }?.0
    }

    private func doubleTapAction(mods: Flags) -> HotkeyAction? {
        bindings.first { $0.1.trigger == .doubleTap && $0.1.keyCode == nil && Self.mods($0.1) == mods }?.0
    }

    private func isTapCandidate(_ mods: Flags) -> Bool {
        !mods.isEmpty && (doubleTapAction(mods: mods) != nil || mods == tripleTapModifiers)
    }

    mutating func flags(_ raw: Flags, at t: TimeInterval) -> [Output] {
        let new = raw.intersection(Self.relevant)
        let prev = current
        guard new != prev else { return [] }
        current = new
        var out: [Output] = []
        if prev.isEmpty { pressStart = t; pressMax = new; pressDirty = false; pressConsumed = false } else { pressMax.formUnion(new) }

        // 1. Release a hold whose modifiers are no longer all down.
        if let h = activeHold, !new.isSuperset(of: h.mods) {
            activeHold = nil
            let quick = h.keyCode == nil && t - h.since < tapMaxDuration
            out.append(Output(action: h.action, phase: quick ? .cancelled : .released))
        }

        // 1b. A modifier joined a fresh hold and the new set is a different hold (⌃⌥ talk + ⇧ = handoff): switch.
        if let h = activeHold, h.keyCode == nil, new != h.mods, new.isSuperset(of: h.mods), t - h.since < holdCancelWindow,
           let other = holdAction(mods: new), other != h.action {
            activeHold = nil
            out.append(Output(action: h.action, phase: .cancelled))
        }

        // 2. A modifier was added: the second press of a double-tap (when its modifiers also hold), or a hold.
        if activeHold == nil, !pressConsumed, new.isSuperset(of: prev), !new.isEmpty {
            if let dt = doubleTapAction(mods: new), holdAction(mods: new) != nil,
               tapMods == new, tapCount >= 1, pressStart - lastTapEnd < tapGap {
                tapCount = 0
                pressConsumed = true
                out.append(Output(action: dt, phase: .fired))
            } else if let hold = holdAction(mods: new) {
                activeHold = (hold, new, nil, t)
                out.append(Output(action: hold, phase: .pressed))
            }
        }

        // 3. All released: was that a tap?
        if new.isEmpty {
            let duration = t - pressStart
            if !pressDirty, !pressConsumed, duration < tapMaxDuration, isTapCandidate(pressMax) {
                if tapMods == pressMax, pressStart - lastTapEnd < tapGap { tapCount += 1 } else { tapMods = pressMax; tapCount = 1 }
                lastTapEnd = t
                out += resolveTaps(at: t)
            } else if pendingDeadline != nil {
                out += resolvePending()
            } else {
                tapCount = 0
            }
        }
        return out
    }

    mutating func keyDown(_ code: UInt16, flags raw: Flags, isRepeat: Bool, at t: TimeInterval) -> [Output] {
        let mods = raw.intersection(Self.relevant)
        var out: [Output] = []
        if pendingDeadline != nil { out += resolvePending() }   // typing right after a double-tap: open now
        pressDirty = true
        tapCount = 0
        if isRepeat { return out }
        if code == 53, mods.isEmpty { out.append(Output(action: .escape, phase: .fired)) }
        if let h = activeHold, h.keyCode == nil {
            if t - h.since < holdCancelWindow {
                activeHold = nil
                pressConsumed = true
                out.append(Output(action: h.action, phase: .cancelled))
            }
            return out
        }
        if activeHold == nil, let (action, _) = bindings.first(where: { $0.1.trigger == .hold && $0.1.keyCode == code && Self.mods($0.1) == mods }) {
            if action == .openHome || action == .text {
                out.append(Output(action: action, phase: .fired))
            } else {
                activeHold = (action, mods, code, t)
                out.append(Output(action: action, phase: .pressed))
            }
        }
        return out
    }

    mutating func keyUp(_ code: UInt16, at t: TimeInterval) -> [Output] {
        guard let h = activeHold, h.keyCode == code else { return [] }
        activeHold = nil
        return [Output(action: h.action, phase: .released)]
    }

    /// Resolves a pending double-tap once its triple-tap window has passed.
    mutating func tick(at t: TimeInterval) -> [Output] {
        guard let d = pendingDeadline else { return [] }
        if t < d { return [] }
        // A third press is in progress: wait for its release to decide.
        if current == tapMods, pressStart > lastTapEnd { pendingDeadline = t + 0.1; return [] }
        return resolvePending()
    }

    private mutating func resolveTaps(at t: TimeInterval) -> [Output] {
        let triple = tapMods == tripleTapModifiers
        if triple, tapCount >= 3 {
            tapCount = 0
            pendingDeadline = nil
            return [Output(action: .alwaysOn, phase: .fired)]
        }
        if tapCount == 2, let dt = doubleTapAction(mods: tapMods) {
            if triple { pendingDeadline = t + tapGap; return [] }
            tapCount = 0
            return [Output(action: dt, phase: .fired)]
        }
        return []
    }

    private mutating func resolvePending() -> [Output] {
        pendingDeadline = nil
        defer { tapCount = 0 }
        if tapCount == 2, let dt = doubleTapAction(mods: tapMods) { return [Output(action: dt, phase: .fired)] }
        return []
    }
}

// MARK: - Recorder (Settings → Shortcuts)

/// Captures the next combo: a held modifier set (≥0.45 s) → hold, two quick taps → double-tap,
/// modifiers + a key → hold with key. Esc cancels; 10 s timeout.
@MainActor
final class HotkeyRecorder {
    private let completion: (HotkeyBinding?) -> Void
    private var pressMax: NSEvent.ModifierFlags = []
    private var pressStart: TimeInterval = 0
    private var lastTap: (mods: NSEvent.ModifierFlags, end: TimeInterval)?
    private var holdTimer: Timer?
    private var timeout: Timer?
    private var done = false

    init(completion: @escaping (HotkeyBinding?) -> Void) {
        self.completion = completion
        timeout = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.finish(nil) } }
    }

    func flags(_ f: NSEvent.ModifierFlags, at t: TimeInterval) {
        holdTimer?.invalidate()
        if !f.isEmpty {
            if pressMax.isEmpty { pressStart = t }
            pressMax.formUnion(f)
            let mods = pressMax
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(HotkeyBinding(trigger: .hold, modifiers: mods.rawValue, keyCode: nil)) }
            }
        } else {
            let mods = pressMax
            pressMax = []
            guard !mods.isEmpty, t - pressStart < 0.45 else { return }
            if let last = lastTap, last.mods == mods, pressStart - last.end < 0.4 {
                finish(HotkeyBinding(trigger: .doubleTap, modifiers: mods.rawValue, keyCode: nil))
            } else {
                lastTap = (mods, t)
            }
        }
    }

    func keyDown(_ code: UInt16, flags: NSEvent.ModifierFlags) {
        holdTimer?.invalidate()
        if code == 53, flags.isEmpty { finish(nil); return }
        guard !flags.isEmpty else { return }
        finish(HotkeyBinding(trigger: .hold, modifiers: flags.rawValue, keyCode: code))
    }

    func finish(_ b: HotkeyBinding?) {
        guard !done else { return }
        done = true
        holdTimer?.invalidate()
        timeout?.invalidate()
        completion(b)
    }
}
