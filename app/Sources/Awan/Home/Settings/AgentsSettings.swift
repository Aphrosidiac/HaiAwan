import SwiftUI
import AppKit
import ApplicationServices

/// Settings → Agents: workspace folder, autonomy, announcements, archived Awans, macOS reach.
struct AgentsSettings: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var prefs = Prefs.shared
    @Local private var folder: String? = UserDefaults.standard.string(forKey: Prefs.Key.agentFolder)
    @Local private var showArchived = false
    @Local private var perms = AgentPermissions.current()

    var body: some View {
        SettingsPageHeader(title: "Agents", subtitle: "Where your Awans work and how much they do on their own.")

        SettingsGroup(label: "Workspace") {
            SettingsButtonRow(title: "Agent folder",
                              subtitle: folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Where Awans work and keep the things they make.",
                              trailingText: folder == nil ? "Awan default" : "Custom",
                              showDivider: folder != nil) { chooseFolder() }
            if folder != nil {
                SettingsButtonRow(title: "Reset to default folder", subtitle: "Go back to Awan's own folder in Application Support.", trailingSymbol: "arrow.uturn.backward", showDivider: false) {
                    UserDefaults.standard.removeObject(forKey: Prefs.Key.agentFolder)
                    folder = nil
                }
            }
        }

        SettingsGroup(label: "Autonomy") {
            SettingToggle(title: "Auto-approve extra usage", subtitle: "Let long tasks keep going without asking each time. Uses more of your agent messages.", isOn: $prefs.autoApproveExtraUsage)
            SettingToggle(title: "Always allow computer use", subtitle: "Let Awans click and type on your Mac without asking first. Off means each task asks with an Allow card.", isOn: $prefs.alwaysAllowComputerUse)
            SettingToggle(title: "Suggest agent tasks", subtitle: "Fresh task suggestions every 24 hours, announced through the morning notch.", isOn: $prefs.suggestAgentTasks, showDivider: false)
        }

        SettingsGroup(label: "Announcements",
                      footer: "During calls, screen sharing and Do Not Disturb, Awan keeps its voice down and routines run silently. Results collect in each Awan's chat, and a count on the notch tells you who has news.") {
            SettingToggle(title: "Speak when an Awan starts or finishes", subtitle: "Awan's voice tells you what got done.", isOn: $prefs.speakAgentUpdates)
            SettingToggle(title: "Show updates beside the cursor", subtitle: "An Awan's reply streams into a bubble next to your cursor when it finishes.", isOn: $prefs.showUpdatesBesideCursor, showDivider: false)
        }

        // Reference: "Legacy agents" — a toggle row, then a footer that says what's there.
        SettingsGroup(label: "Archived Awans",
                      footer: archived.isEmpty ? "Nothing archived on this Mac. Every Awan is still in your list."
                                               : "\(archived.count) archived \(archived.count == 1 ? "Awan" : "Awans") on this Mac, with their full history.") {
            SettingToggle(title: "See archived Awans",
                          subtitle: "Show Awans you've archived, with their original name and history, so you can bring them back.",
                          isOn: $showArchived.animation(Theme.snappy),
                          showDivider: showArchived && !archived.isEmpty)
            if showArchived {
                ForEach(Array(archived.enumerated()), id: \.element.slug) { i, a in
                    HStack(spacing: 11) {
                        AgentAvatar(appearance: a.character, size: 30, mood: .sleeping)
                        VStack(alignment: .leading, spacing: 1.4) {
                            Text(a.name).font(SettingsStyle.rowTitle).foregroundStyle(Theme.text)
                            Text(a.roleText).font(SettingsStyle.rowSubtitle).foregroundStyle(SettingsStyle.dim)
                        }
                        Spacer()
                        Button("Restore") {
                            state.agents.update(a.slug) { $0.archived = false }
                            state.show("\(a.name) is back in your list.")
                        }
                        .buttonStyle(.gel(.bone, height: 24, padding: 9, fontSize: 14))
                    }
                    .padding(.leading, SettingsStyle.rowLeading).padding(.trailing, SettingsStyle.rowTrailing + 1.5)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        if i < archived.count - 1 { Rectangle().fill(SettingsStyle.stroke).frame(height: 1).padding(.leading, SettingsStyle.rowLeading + 0.5) }
                    }
                }
            }
        }

        SettingsGroup(label: "What agents can reach", footer: "macOS permissions your Awans inherit. Tap one to review it in System Settings.") {
            permRow("Files & Folders", "Manage Desktop, Documents, Downloads, and full-disk access", "folder", perms.files, SystemSettingsPane.fullDisk)
            permRow("Accessibility", "Lets Awans click, type and read what's on screen.", "accessibility", perms.accessibility, SystemSettingsPane.accessibility)
            permRow("Screen Recording", "Lets Awans see the window they're working in.", "rectangle.dashed", perms.screen, SystemSettingsPane.screenRecording, last: true)
        }
        .onAppear { perms = AgentPermissions.current() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in perms = AgentPermissions.current() }
    }

    private var archived: [AwanAgent] { state.agents.roster.filter(\.archived) }

    /// Reference: outline glyph at the leading edge, title 30 pt in, dim subtitle, CAPS status capsule.
    private func permRow(_ title: String, _ sub: String, _ symbol: String, _ status: AgentPermissions.Status, _ pane: String, last: Bool = false) -> some View {
        Button { SystemSettingsPane.open(pane) } label: {
            HStack(spacing: 0) {
                Image(systemName: symbol).font(.system(size: 14, weight: .regular)).foregroundStyle(SettingsStyle.navText)
                    .frame(width: 18)
                    .padding(.trailing, 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(SettingsStyle.rowTitle).foregroundStyle(Theme.text)
                    Text(sub).font(SettingsStyle.rowSubtitle).foregroundStyle(SettingsStyle.dim)
                }
                Spacer(minLength: 8)
                Text(status.label.uppercased())
                    .font(.awan(11.5, .semibold)).tracking(1.4)
                    .foregroundStyle(status == .granted ? Theme.lime : status == .notGranted ? Theme.warning : SettingsStyle.dim)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.05)))
            }
            .padding(.leading, SettingsStyle.rowLeading).padding(.trailing, SettingsStyle.rowTrailing)
            .padding(.top, 10.5).padding(.bottom, 11)
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(SettingsStyle.stroke).frame(height: 1).padding(.leading, SettingsStyle.rowLeading + 0.5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Pick the folder where your Awans should work and put what they make."
        if let folder { panel.directoryURL = URL(fileURLWithPath: folder) }
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: Prefs.Key.agentFolder)
            folder = url.path
        }
    }
}

/// Read-only probes of what macOS has granted Awan. None of these prompt.
struct AgentPermissions: Equatable {
    enum Status: Equatable {
        case granted, notGranted, unknown
        var label: String { self == .granted ? "Granted" : self == .notGranted ? "Not granted" : "Unknown" }
        var tone: ChipTone { self == .granted ? .good : self == .notGranted ? .warn : .neutral }
    }
    var files: Status
    var accessibility: Status
    var screen: Status

    static func current() -> AgentPermissions {
        if SettingsEnv.isSnapshot { return AgentPermissions(files: .granted, accessibility: .granted, screen: .notGranted) }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
        return AgentPermissions(
            files: FileManager.default.isReadableFile(atPath: desktop) ? .granted : .unknown,
            accessibility: AXIsProcessTrusted() ? .granted : .notGranted,
            screen: CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        )
    }
}
