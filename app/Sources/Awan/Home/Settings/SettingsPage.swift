import SwiftUI
import AppKit

// MARK: - The page

/// Settings → one section. Header + grouped cards, scrolling, max width 640, 28 pt padding.
/// Modals (delete account, feedback, cancel plan) float over the page, not as system sheets,
/// because Home can live inside the notch panel where sheets misbehave.
struct SettingsPage: View {
    let section: SettingsSection
    /// Snapshot-only: render the page scrolled down by this many points (`settings-<page>@<offset>`).
    static var debugScrollOffset: CGFloat = 0
    @EnvironmentObject var state: AppState
    @ObservedObject private var ui = SettingsUI.shared

    var body: some View {
        ZStack {
            // Reference: pages scroll under a fixed 75 pt header band (window buttons live there),
            // 25 pt side padding, content capped at 620 and leading-aligned.
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.068),
                .init(color: Color(hex: 0x131312), location: 0.15),
                .init(color: Color(hex: 0x1B1A19), location: 0.21),
                .init(color: SettingsStyle.content, location: 0.29),
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: SettingsStyle.groupSpacing) {
                        content
                    }
                    .frame(maxWidth: section == .referral ? .infinity : SettingsStyle.pageMaxWidth, alignment: .leading)
                    .padding(.horizontal, SettingsStyle.pagePadding)
                    .padding(.top, section == .referral ? 0 : 10.6)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: -Self.debugScrollOffset)
                }
                .environment(\.settingsScroll, proxy)
                .scrollIndicators(.never)
                .clipped()
                .padding(.top, SettingsStyle.headerHeight)
            }
            .id(section)

            if let modal = ui.modal {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture { if !ui.modalBusy { ui.modal = nil } }
                    .transition(.opacity)
                SettingsModalHost(modal: modal)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(Theme.spring, value: ui.modal)
        .onReceive(NotificationCenter.default.publisher(for: .awanReportBug)) { _ in
            ui.modal = .feedback(.bug)
        }
        .onAppear { ui.consumePendingBugReport() }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .account: AccountSettings()
        case .general: GeneralSettings()
        case .referral: ReferralPage()
        case .voice: VoiceSettings()
        case .microphone: MicrophoneSettings()
        case .dictation: DictationSettings()
        case .shortcuts: ShortcutsSettings()
        case .cursor: CursorSettings()
        case .agents: AgentsSettings()
        case .integrations: IntegrationsSettings()
        case .developer: DeveloperSettings()
        }
    }
}

// MARK: - Shared settings state

enum FeedbackKind: String { case bug, feature }

enum SettingsModal: Equatable {
    case deleteAccount
    case cancelPlan
    case feedback(FeedbackKind)
}

/// Page-level UI state for Settings (which modal is open). Also catches "Report a bug" from the
/// Help menu, which is posted before the Settings page has mounted.
@MainActor
final class SettingsUI: ObservableObject {
    static let shared = SettingsUI()
    @Published var modal: SettingsModal?
    @Published var modalBusy = false
    private var pendingBug = false

    private init() {
        NotificationCenter.default.addObserver(forName: .awanReportBug, object: nil, queue: .main) { _ in
            Task { @MainActor in SettingsUI.shared.pendingBug = true }
        }
    }

    func consumePendingBugReport() {
        if pendingBug { pendingBug = false; modal = .feedback(.bug) }
    }
}

enum SettingsEnv {
    /// Headless snapshot renders must never hit the network or real devices.
    static let isSnapshot = CommandLine.arguments.contains("--snapshot")
}

/// Hidden developer section: option-click the version in General, or
/// `defaults write studio.ffdev.awan awan.developer 1`.
enum DeveloperMode {
    static let key = "awan.developer"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }
    @MainActor static func toggle() {
        UserDefaults.standard.set(!isEnabled, forKey: key)
        AppState.shared.objectWillChange.send()
    }
    /// Sections the sidebar should list (Developer only when enabled).
    static var visibleSections: [SettingsSection] {
        SettingsSection.allCases.filter { $0 != .developer || isEnabled }
    }
}

/// Links from `GET /v1/config` (changelog, community, terms…), with sane fallbacks.
@MainActor
final class RemoteLinks: ObservableObject {
    static let shared = RemoteLinks()
    @Published var links: [String: String] = [
        "changelog": "https://awan.ffdev.studio/changelog",
        "featureRequest": "https://awan.ffdev.studio/feedback",
        "community": "https://www.instagram.com/ffdev.studio",
        "whatsapp": "https://awan.ffdev.studio/community",
        "privacy": "https://awan.ffdev.studio/privacy",
        "terms": "https://awan.ffdev.studio/terms",
        "payouts": "https://awan.ffdev.studio/referrals/payouts",
    ]
    private var loaded = false

    func load() {
        guard !loaded, !SettingsEnv.isSnapshot else { return }
        loaded = true
        Task {
            struct Config: Decodable { var links: [String: String] }
            if let c: Config = try? await APIClient.shared.send("v1/config", auth: false) {
                links.merge(c.links) { _, new in new }
            } else {
                loaded = false
            }
        }
    }

    func open(_ key: String) {
        if let s = links[key], let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

private struct SettingsScrollKey: EnvironmentKey {
    static let defaultValue: ScrollViewProxy? = nil
}

extension EnvironmentValues {
    var settingsScroll: ScrollViewProxy? {
        get { self[SettingsScrollKey.self] }
        set { self[SettingsScrollKey.self] = newValue }
    }
}

// MARK: - Building blocks shared by the sections

/// A whole row that acts as a button, with a trailing glyph (chevron, ↗, ▶).
struct SettingsButtonRow: View {
    let title: String
    var subtitle: String? = nil
    var titleColor: Color = Theme.text
    var trailingSymbol: String? = "chevron.right"
    var trailingText: String? = nil
    var showDivider = true
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            SettingsRow(title: title, subtitle: subtitle, titleColor: titleColor, showDivider: showDivider) {
                HStack(spacing: 8) {
                    if let trailingText {
                        Text(trailingText).font(.awan(14)).foregroundStyle(SettingsStyle.dim).lineLimit(1)
                    }
                    if let trailingSymbol {
                        Image(systemName: trailingSymbol)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(hovering ? Theme.text : SettingsStyle.dim)
                            .padding(.trailing, 1.5)
                    }
                }
            }
            .background(hovering ? Color.white.opacity(0.03) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

enum ChipTone { case neutral, good, warn, bad, lime }

struct StatusChip: View {
    let text: String
    var tone: ChipTone = .neutral
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text).font(.awan(11, .semibold))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(bg))
    }
    private var dot: Color {
        switch tone {
        case .neutral: return Theme.textTertiary
        case .good: return Theme.success
        case .warn: return Theme.warning
        case .bad: return Theme.danger
        case .lime: return Theme.lime
        }
    }
    private var fg: Color { tone == .neutral ? Theme.textSecondary : Theme.text }
    private var bg: Color { dot.opacity(tone == .neutral ? 0.12 : 0.16) }
}

/// Pill segmented control — lime marks the selection (the one active state in the group).
struct PillSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var height: CGFloat = 30
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Button {
                    withAnimation(Theme.snappy) { selection = value }
                } label: {
                    Text(label)
                        .font(.awan(12.5, .semibold))
                        .foregroundStyle(on ? Theme.ink : Theme.textSecondary)
                        .padding(.horizontal, 13)
                        .frame(height: height - 6)
                        .background {
                            if on {
                                Capsule()
                                    .fill(LinearGradient(colors: [Color(hex: 0xEAFF8C), Theme.lime], startPoint: .top, endPoint: .bottom))
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// Small outlined button ("Change", "Restore", "Connect").
struct SmallPillButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color? = nil
    let action: () -> Void
    @Local private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10.5, weight: .bold)) }
                Text(title).font(.awan(12.5, .semibold))
            }
            .foregroundStyle(tint ?? Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill((tint ?? .white).opacity(hovering ? 0.16 : 0.09)))
            .overlay(Capsule().strokeBorder((tint ?? .white).opacity(tint == nil ? 0.10 : 0.28), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Plain text field in the settings style.
struct SettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var mono = false
    var height: CGFloat = 34
    var onSubmit: () -> Void = {}
    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(mono ? .awanMono(12.5, .regular) : .awan(13.5))
        .foregroundStyle(Theme.text)
        .onSubmit(onSubmit)
        .padding(.horizontal, 11)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// Usage meter (reference): dim label, "6 / 25" value, a 5 pt bar with a bone fill.
struct UsageMeter: View {
    let label: String
    let bucket: UsageBucket
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.awan(12)).foregroundStyle(SettingsStyle.dim)
            Group {
                if bucket.isUnlimited {
                    Text("Unlimited")
                } else {
                    Text("\(bucket.used) / \(bucket.cap ?? 0)").monospacedDigit()
                }
            }
            .font(.awan(14, .semibold)).foregroundStyle(Theme.text)
            .padding(.top, 2.9)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    if !bucket.isUnlimited {
                        Capsule()
                            .fill(bucket.fraction >= 1 ? Theme.danger : bucket.fraction > 0.8 ? Theme.warning : Color(hex: 0xE4E1D8))
                            .frame(width: max(bucket.used > 0 ? 11 : 0, geo.size.width * bucket.fraction))
                    }
                }
            }
            .frame(height: 5)
            .padding(.top, 2.4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Card chrome matching SettingsGroup, for free-form content.
    func settingsCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous).fill(SettingsStyle.card))
            .overlay(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous).strokeBorder(SettingsStyle.stroke, lineWidth: 1))
    }
}

enum SystemSettingsPane {
    static let fullDisk = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    static let microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    /// Opens the pane for the user to review. Never changes anything itself.
    static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

/// ToggleRow with a non-greedy switch. (GelToggleStyle's inner Spacer makes the shared ToggleRow
/// split the row width with the text, squeezing subtitles; `.fixedSize()` keeps the switch compact.)
struct SettingToggle: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var showDivider = true
    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, showDivider: showDivider) {
            GelSwitch(isOn: isOn) { isOn.toggle() }
        }
    }
}

// MARK: - Modals

struct SettingsModalHost: View {
    let modal: SettingsModal
    var body: some View {
        Group {
            switch modal {
            case .deleteAccount: DeleteAccountSheet()
            case .cancelPlan: CancelPlanSheet()
            case let .feedback(kind): FeedbackSheet(kind: kind)
            }
        }
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        .padding(24)
    }
}

/// Request a feature / Report a bug → POST /v1/feedback.
struct FeedbackSheet: View {
    let kind: FeedbackKind
    @EnvironmentObject var state: AppState
    @ObservedObject private var ui = SettingsUI.shared
    @Local private var text = ""
    @Local private var error: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind == .bug ? "Report a bug" : "Request a feature").font(.awan(18, .semibold)).foregroundStyle(Theme.text)
                    Text(kind == .bug ? "Tell us what broke and what you expected instead." : "What should Awan do next? The more specific, the better.")
                        .font(.awan(12.5)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                CircleIconButton(systemName: "xmark", size: 26, filled: true) { ui.modal = nil }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.awan(13.5))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if text.isEmpty {
                    Text(kind == .bug ? "When I hold ⌃⌥ in Safari, Awan…" : "I'd love it if Awan could…")
                        .font(.awan(13.5)).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke, lineWidth: 1))

            if kind == .bug {
                Label("Sends diagnostics along so we can actually fix it.", systemImage: "stethoscope")
                    .font(.awan(11.5)).foregroundStyle(Theme.textTertiary)
            }
            if let error { Text(error).font(.awan(12)).foregroundStyle(Theme.danger) }

            HStack {
                Spacer()
                Button("Cancel") { ui.modal = nil }.buttonStyle(.gel(.bone, height: 32, padding: 16, fontSize: 13))
                Button(ui.modalBusy ? "Sending…" : "Send") { Task { await send() } }
                    .buttonStyle(.gel(.lime, height: 32, padding: 18, fontSize: 13))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ui.modalBusy)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(22)
    }

    private func send() async {
        ui.modalBusy = true
        defer { ui.modalBusy = false }
        var body: [String: JSON] = ["kind": .string(kind.rawValue), "body": .string(text)]
        if kind == .bug {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            body["diagnostics"] = [
                "version": .string(Bundle.main.shortVersion),
                "build": .string(Bundle.main.buildNumber),
                "macOS": .string("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
                "log": .string(Log.tail()),
            ]
        }
        do {
            try await APIClient.shared.sendRaw("v1/feedback", method: "POST", body: body)
            ui.modal = nil
            state.show(kind == .bug ? "Got it. Thanks for helping fix Awan." : "Thanks! Your idea is with the team.")
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
