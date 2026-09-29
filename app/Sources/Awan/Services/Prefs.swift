import Foundation
import SwiftUI
import Combine
import AppKit

/// User preferences (Settings). One ObservableObject so every view reacts; persisted to UserDefaults.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()

    enum Key {
        static let apiBaseURL = "awan.api.baseURL"
        static let agentFolder = "awan.agents.folder"
        static let showInDock = "awan.general.showInDock"
        static let showInScreenRecordings = "awan.general.showInScreenRecordings"
        static let quickPeekOnHover = "awan.general.quickPeekOnHover"
        static let voiceID = "awan.voice.id"
        static let speechSpeed = "awan.voice.speed"
        static let microphoneUID = "awan.mic.deviceUID"
        static let dictationAutoDetect = "awan.dictation.autoDetect"
        static let dictationLanguage = "awan.dictation.language"
        static let dictionary = "awan.dictation.dictionary"
        static let cursorColor = "awan.cursor.color"
        static let cursorDocked = "awan.cursor.docked"
        static let autoApproveExtraUsage = "awan.agents.autoApproveExtraUsage"
        static let alwaysAllowComputerUse = "awan.agents.alwaysAllowComputerUse"
        static let suggestAgentTasks = "awan.agents.suggestTasks"
        static let speakAgentUpdates = "awan.agents.speakUpdates"
        static let showUpdatesBesideCursor = "awan.agents.showUpdatesBesideCursor"
        static let showLegacyAgents = "awan.agents.showLegacy"
        static let onboardingCompleted = "awan.onboarding.completed.v1"
        static let tourMusic = "awan.onboarding.tourMusic"
        static let catMode = "awan.general.catMode"
        static let homeSize = "awan.home.size"
        static let homeDetached = "awan.home.detached"
        static let shortcuts = "awan.hotkeys.v1"
        static let alwaysOnVoice = "awan.voice.alwaysOn"
        static let modelLane = "awan.developer.modelLane"
        static let reasoningEffort = "awan.developer.effort"
        static let morningSuggestionsLastShown = "awan.suggestions.morningLastShown"
    }

    private let d = UserDefaults.standard

    @Published var apiBaseURL: String { didSet { d.set(apiBaseURL, forKey: Key.apiBaseURL) } }
    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: Key.showInDock) } }
    @Published var showInScreenRecordings: Bool { didSet { d.set(showInScreenRecordings, forKey: Key.showInScreenRecordings) } }
    @Published var quickPeekOnHover: Bool { didSet { d.set(quickPeekOnHover, forKey: Key.quickPeekOnHover) } }
    @Published var voiceID: String { didSet { d.set(voiceID, forKey: Key.voiceID) } }
    @Published var speechSpeed: Double { didSet { d.set(speechSpeed, forKey: Key.speechSpeed) } }
    @Published var microphoneUID: String { didSet { d.set(microphoneUID, forKey: Key.microphoneUID) } }
    @Published var dictationAutoDetect: Bool { didSet { d.set(dictationAutoDetect, forKey: Key.dictationAutoDetect) } }
    @Published var dictationLanguage: String { didSet { d.set(dictationLanguage, forKey: Key.dictationLanguage) } }
    @Published var dictionary: [String] { didSet { d.set(dictionary, forKey: Key.dictionary) } }
    @Published var cursorColor: CursorColor { didSet { d.set(cursorColor.rawValue, forKey: Key.cursorColor) } }
    @Published var cursorDocked: Bool { didSet { d.set(cursorDocked, forKey: Key.cursorDocked) } }
    @Published var autoApproveExtraUsage: Bool { didSet { d.set(autoApproveExtraUsage, forKey: Key.autoApproveExtraUsage) } }
    @Published var alwaysAllowComputerUse: Bool { didSet { d.set(alwaysAllowComputerUse, forKey: Key.alwaysAllowComputerUse) } }
    @Published var suggestAgentTasks: Bool { didSet { d.set(suggestAgentTasks, forKey: Key.suggestAgentTasks) } }
    @Published var speakAgentUpdates: Bool { didSet { d.set(speakAgentUpdates, forKey: Key.speakAgentUpdates) } }
    @Published var showUpdatesBesideCursor: Bool { didSet { d.set(showUpdatesBesideCursor, forKey: Key.showUpdatesBesideCursor) } }
    @Published var showLegacyAgents: Bool { didSet { d.set(showLegacyAgents, forKey: Key.showLegacyAgents) } }
    @Published var onboardingCompleted: Bool { didSet { d.set(onboardingCompleted, forKey: Key.onboardingCompleted) } }
    @Published var tourMusic: Bool { didSet { d.set(tourMusic, forKey: Key.tourMusic) } }
    @Published var catMode: Bool { didSet { d.set(catMode, forKey: Key.catMode) } }
    @Published var homeDetached: Bool { didSet { d.set(homeDetached, forKey: Key.homeDetached) } }
    @Published var alwaysOnVoice: Bool { didSet { d.set(alwaysOnVoice, forKey: Key.alwaysOnVoice) } }
    @Published var shortcuts: ShortcutSet { didSet { if let data = try? JSONEncoder().encode(shortcuts) { d.set(data, forKey: Key.shortcuts) } } }
    @Published var modelLane: String { didSet { d.set(modelLane, forKey: Key.modelLane) } }
    @Published var reasoningEffort: String { didSet { d.set(reasoningEffort, forKey: Key.reasoningEffort) } }

    private init() {
        d.register(defaults: [
            Key.apiBaseURL: "http://127.0.0.1:8787",
            Key.showInDock: true,
            Key.showInScreenRecordings: true,
            Key.quickPeekOnHover: true,
            Key.voiceID: "cedar",
            Key.speechSpeed: 1.0,
            Key.microphoneUID: "",
            Key.dictationAutoDetect: true,
            Key.dictationLanguage: "en",
            Key.dictionary: ["Awan", "FF Dev Studio"],
            Key.cursorColor: CursorColor.lime.rawValue,
            Key.cursorDocked: false,
            Key.autoApproveExtraUsage: false,
            Key.alwaysAllowComputerUse: false,
            Key.suggestAgentTasks: true,
            Key.speakAgentUpdates: true,
            Key.showUpdatesBesideCursor: true,
            Key.showLegacyAgents: false,
            Key.onboardingCompleted: false,
            Key.tourMusic: true,
            Key.catMode: false,
            Key.homeDetached: false,
            Key.alwaysOnVoice: false,
            Key.modelLane: "awan-agent",
            Key.reasoningEffort: "medium",
        ])
        apiBaseURL = d.string(forKey: Key.apiBaseURL) ?? "http://127.0.0.1:8787"
        showInDock = d.bool(forKey: Key.showInDock)
        showInScreenRecordings = d.bool(forKey: Key.showInScreenRecordings)
        quickPeekOnHover = d.bool(forKey: Key.quickPeekOnHover)
        voiceID = d.string(forKey: Key.voiceID) ?? "cedar"
        speechSpeed = d.double(forKey: Key.speechSpeed)
        microphoneUID = d.string(forKey: Key.microphoneUID) ?? ""
        dictationAutoDetect = d.bool(forKey: Key.dictationAutoDetect)
        dictationLanguage = d.string(forKey: Key.dictationLanguage) ?? "en"
        dictionary = d.stringArray(forKey: Key.dictionary) ?? []
        cursorColor = CursorColor(rawValue: d.string(forKey: Key.cursorColor) ?? "") ?? .lime
        cursorDocked = d.bool(forKey: Key.cursorDocked)
        autoApproveExtraUsage = d.bool(forKey: Key.autoApproveExtraUsage)
        alwaysAllowComputerUse = d.bool(forKey: Key.alwaysAllowComputerUse)
        suggestAgentTasks = d.bool(forKey: Key.suggestAgentTasks)
        speakAgentUpdates = d.bool(forKey: Key.speakAgentUpdates)
        showUpdatesBesideCursor = d.bool(forKey: Key.showUpdatesBesideCursor)
        showLegacyAgents = d.bool(forKey: Key.showLegacyAgents)
        onboardingCompleted = d.bool(forKey: Key.onboardingCompleted)
        tourMusic = d.bool(forKey: Key.tourMusic)
        catMode = d.bool(forKey: Key.catMode)
        homeDetached = d.bool(forKey: Key.homeDetached)
        alwaysOnVoice = d.bool(forKey: Key.alwaysOnVoice)
        if let data = d.data(forKey: Key.shortcuts), let s = try? JSONDecoder().decode(ShortcutSet.self, from: data) {
            shortcuts = s
        } else {
            shortcuts = .defaults
        }
        modelLane = d.string(forKey: Key.modelLane) ?? "awan-agent"
        reasoningEffort = d.string(forKey: Key.reasoningEffort) ?? "medium"
    }
}

/// Cursor colours (the reference offers red/blue/yellow/green; ours leads with Signal Lime).
enum CursorColor: String, CaseIterable, Codable, Identifiable {
    case lime, bone, coral, sky
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .lime: return Theme.lime
        case .bone: return Theme.bone
        case .coral: return Color(hex: 0xFF6B5E)
        case .sky: return Color(hex: 0x5AA9FF)
        }
    }
    var nsColor: NSColor {
        switch self {
        case .lime: return NSColor(hex: 0xD9FF43)
        case .bone: return NSColor(hex: 0xF3EFE4)
        case .coral: return NSColor(hex: 0xFF6B5E)
        case .sky: return NSColor(hex: 0x5AA9FF)
        }
    }
    var label: String { rawValue.capitalized }
}

// MARK: - Shortcuts

/// A hotkey binding: either a held combination of modifiers (optionally + key) or a double-tap of modifiers.
struct HotkeyBinding: Codable, Equatable, Hashable {
    enum Trigger: String, Codable { case hold, doubleTap }
    var trigger: Trigger
    /// NSEvent.ModifierFlags raw value (device-independent bits only).
    var modifiers: UInt
    /// Optional key code (e.g. space); nil = modifiers only.
    var keyCode: UInt16?

    var displayKeys: [String] {
        var keys: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.function) { keys.append("fn") }
        if flags.contains(.control) { keys.append("⌃ control") }
        if flags.contains(.option) { keys.append("⌥ option") }
        if flags.contains(.shift) { keys.append("⇧ shift") }
        if flags.contains(.command) { keys.append("⌘ command") }
        if let keyCode { keys.append(KeyNames.name(for: keyCode)) }
        return keys
    }

    var summary: String {
        (trigger == .doubleTap ? "Double-tap " : "Hold ") + displayKeys.map { $0.components(separatedBy: " ").last ?? $0 }.joined(separator: " + ")
    }
}

struct ShortcutSet: Codable, Equatable {
    var talk: HotkeyBinding
    var text: HotkeyBinding
    var dictate: HotkeyBinding
    var handsFreeDictate: HotkeyBinding
    var openHome: HotkeyBinding
    /// Handoff: hold ⌃⌥⇧, then drag a box around part of the screen. (Added in wave 2; older saved sets decode with the default.)
    var handoff: HotkeyBinding = ShortcutSet.defaultHandoff

    static let defaultHandoff = HotkeyBinding(trigger: .hold, modifiers: NSEvent.ModifierFlags([.control, .option, .shift]).rawValue, keyCode: nil)

    static let defaults = ShortcutSet(
        talk: .init(trigger: .hold, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, keyCode: nil),
        text: .init(trigger: .doubleTap, modifiers: NSEvent.ModifierFlags.control.rawValue, keyCode: nil),
        dictate: .init(trigger: .hold, modifiers: NSEvent.ModifierFlags([.control, .function]).rawValue, keyCode: nil),
        handsFreeDictate: .init(trigger: .doubleTap, modifiers: NSEvent.ModifierFlags([.control, .function]).rawValue, keyCode: nil),
        openHome: .init(trigger: .hold, modifiers: NSEvent.ModifierFlags([.control, .command]).rawValue, keyCode: 0) // ⌃⌘A
    )
}

extension ShortcutSet {
    private enum CodingKeys: String, CodingKey { case talk, text, dictate, handsFreeDictate, openHome, handoff }

    /// Tolerates sets saved before a binding existed (each missing one takes its default).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShortcutSet.defaults
        talk = try c.decodeIfPresent(HotkeyBinding.self, forKey: .talk) ?? d.talk
        text = try c.decodeIfPresent(HotkeyBinding.self, forKey: .text) ?? d.text
        dictate = try c.decodeIfPresent(HotkeyBinding.self, forKey: .dictate) ?? d.dictate
        handsFreeDictate = try c.decodeIfPresent(HotkeyBinding.self, forKey: .handsFreeDictate) ?? d.handsFreeDictate
        openHome = try c.decodeIfPresent(HotkeyBinding.self, forKey: .openHome) ?? d.openHome
        handoff = try c.decodeIfPresent(HotkeyBinding.self, forKey: .handoff) ?? d.handoff
    }
}

enum KeyNames {
    static func name(for code: UInt16) -> String {
        switch code {
        case 0: return "A"
        case 49: return "space"
        case 36: return "return"
        case 53: return "esc"
        default: return "key \(code)"
        }
    }
}
