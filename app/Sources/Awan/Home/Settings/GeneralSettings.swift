import SwiftUI
import AppKit

/// Settings → General: behaviour, updates, community, welcome tour, support.
struct GeneralSettings: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var links = RemoteLinks.shared
    @ObservedObject private var ui = SettingsUI.shared

    var body: some View {
        SettingsPageHeader(title: "General", subtitle: "How Awan behaves on your Mac.")

        SettingsGroup(label: "Behavior") {
            SettingToggle(title: "Show in Dock", subtitle: "Turn off to keep Awan in the notch only.", isOn: $prefs.showInDock)
            SettingToggle(title: "Show in screen recordings", subtitle: "Let screen sharing and recording apps capture Awan.", isOn: $prefs.showInScreenRecordings)
            SettingToggle(title: "Quick peek on notch hover", subtitle: "Hovering the notch shows your Awans and their latest files. Turn off to open Home straight away.", isOn: $prefs.quickPeekOnHover, showDivider: false)
        }
        .onChange(of: prefs.showInDock) { _, _ in
            (NSApp.delegate as? AppDelegate)?.applyDockPolicy()
        }
        .onChange(of: prefs.showInScreenRecordings) { _, on in
            for w in NSApp.windows { w.sharingType = on ? .readOnly : .none }
        }

        SettingsGroup(label: "Updates") {
            SettingsRow(title: "App updates", subtitle: updater.status ?? "You're on version \(Bundle.main.shortVersion) (\(Bundle.main.buildNumber)).") {
                Button(updater.checking ? "Checking…" : "Check for updates") { updater.checkNow(userInitiated: false) }
                    .buttonStyle(.gel(.bone, height: 32, padding: 15, fontSize: 14.5))
                    .disabled(updater.checking)
            }
            SettingsButtonRow(title: "What's new", subtitle: "Everything that's shipped in Awan, newest first.", trailingSymbol: "arrow.up.right", showDivider: false) {
                links.open("changelog")
            }
        }

        SettingsGroup(label: "Community") {
            SettingsLinkRow(title: "WhatsApp community", icon: .whatsapp) { links.open("whatsapp") }
            SettingsLinkRow(title: "Instagram", icon: .instagram, showDivider: false) { links.open("community") }
        }

        SettingsGroup(label: "Welcome tour") {
            SettingsButtonRow(title: "Replay the welcome tour",
                              subtitle: "Watch the intro again, then redo the hands-on tour and the interview. Awan makes three new Awans from your answers; the ones you have stay.",
                              trailingSymbol: "play.fill", showDivider: false) {
                state.closeHome()
                OnboardingController.shared.replay()
            }
        }

        SettingsGroup(label: "Support") {
            SettingsButtonRow(title: "Request a feature", trailingSymbol: "arrow.up.right") {
                ui.modal = .feedback(.feature)
            }
            SettingsButtonRow(title: "Report a bug", subtitle: "Sends diagnostics along so we can actually fix it.", trailingSymbol: nil, showDivider: false) {
                ui.modal = .feedback(.bug)
            }
        }
        .onAppear { links.load() }

        // Awan-only groups sit after the reference's five so the shared structure reads the same.
        SettingsGroup(label: "Extras") {
            SettingToggle(title: "Cat Mode", subtitle: "Your cursor buddy turns into a tiny pixel cat. Purely for fun.", isOn: $prefs.catMode, showDivider: false)
        }
        .onChange(of: prefs.catMode) { _, _ in
            CursorOverlayController.shared.refreshAppearance()
        }

        SettingsGroup(label: "Meetings") {
            UpcomingMeetingsToggle()
        }

        Text("Awan \(Bundle.main.shortVersion) (\(Bundle.main.buildNumber)) · Made by FF Dev Studio in Malaysia")
            .font(.awan(11)).foregroundStyle(SettingsStyle.footer)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.option) {
                    DeveloperMode.toggle()
                    state.show(DeveloperMode.isEnabled ? "Developer tools are on." : "Developer tools are hidden.")
                }
            }
            .help("Option-click to toggle developer tools")
    }
}

/// Title-only link row with a brand glyph (Community): 38 pt, 16 pt glyph, ↗.
struct SettingsLinkRow: View {
    enum Icon { case whatsapp, instagram }
    let title: String
    let icon: Icon
    var showDivider = true
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10.5) {
                glyph.frame(width: 16, height: 16)
                Text(title).font(SettingsStyle.rowTitle).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.text : SettingsStyle.dim).padding(.trailing, 1.5)
            }
            .padding(.leading, SettingsStyle.rowLeading).padding(.trailing, SettingsStyle.rowTrailing)
            .frame(height: 38)
            .background(hovering ? Color.white.opacity(0.03) : .clear)
            .overlay(alignment: .bottom) {
                if showDivider { Rectangle().fill(SettingsStyle.stroke).frame(height: 1).padding(.leading, SettingsStyle.rowLeading + 0.5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var glyph: some View {
        switch icon {
        case .whatsapp:
            ZStack {
                Circle().fill(Color(hex: 0x25D366))
                Image(systemName: "phone.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            }
        case .instagram:
            ZStack {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xFEDA75), Color(hex: 0xFA7E1E), Color(hex: 0xD62976), Color(hex: 0x962FBF)], startPoint: .bottomLeading, endPoint: .topTrailing))
                RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.white, lineWidth: 1.4).padding(3)
                Circle().strokeBorder(.white, lineWidth: 1.4).frame(width: 5.5, height: 5.5)
            }
        }
    }
}
