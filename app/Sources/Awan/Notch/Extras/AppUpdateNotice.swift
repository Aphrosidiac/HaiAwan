import AppKit
import SwiftUI

/// "App updated" (reference: NotchAppUpdatedSurface + AppUpdatedNotice). On the first launch after the
/// bundle version changes, the notch says "Awan updated to X" with a What's new button (the changelog link
/// from /v1/config). The very first install records the version quietly.
@MainActor
enum AppUpdateNotice {
    static let lastSeenKey = "awan.update.lastSeenVersion"

    enum Decision: Equatable { case firstInstall, same, updated(String) }

    /// Pure: what to do given the stored version and the running one.
    static func decide(lastSeen: String?, current: String) -> Decision {
        guard let lastSeen, !lastSeen.isEmpty else { return .firstInstall }
        if lastSeen == current { return .same }
        return current.compare(lastSeen, options: .numeric) == .orderedDescending ? .updated(current) : .same
    }

    /// Call once at launch. Records the running version; presents the card a moment later if it's new.
    static func checkOnLaunch(defaults: UserDefaults = .standard, current: String = Bundle.main.shortVersion) {
        guard !SettingsEnv.isSnapshot else { return }
        let decision = decide(lastSeen: defaults.string(forKey: lastSeenKey), current: current)
        defaults.set(current, forKey: lastSeenKey)
        guard case let .updated(version) = decision else { return }
        RemoteLinks.shared.load()
        Task {
            try? await Task.sleep(for: .seconds(4))   // after the notch and the buddy have settled
            // Onboarding owns the screen on a fresh account; don't talk over it.
            guard Prefs.shared.onboardingCompleted else { return }
            for _ in 0 ..< 20 {
                if case .resting = NotchController.shared.mode { break }
                if NotchController.shared.mode == .activity { break }
                try? await Task.sleep(for: .seconds(3))
            }
            NotchController.shared.present(.appUpdated(version), for: 14)
        }
    }
}

/// "Awan updated to 1.1 — see what's new."  What's new / ×.
struct AppUpdatedSurface: View {
    let version: String
    @ObservedObject private var links = RemoteLinks.shared

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                CloudCreature(appearance: .mascot, mood: .happy, glow: false).frame(width: 40)
                Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.lime).offset(x: 4, y: 2)
            }
            .frame(width: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Awan updated to \(version)").font(.awan(14.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("New tricks just landed.").font(.awan(12.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            Button { links.open("changelog"); NotchController.shared.dismissSurface() } label: { Label("What's new", systemImage: "arrow.up.right") }
                .buttonStyle(.gel(.lime, height: 30, padding: 14, fontSize: 12.5))
                .fixedSize()
                .help("Open Awan's changelog")
            CircleIconButton(systemName: "xmark", size: 26, help: "Dismiss") { NotchController.shared.dismissSurface() }
        }
        .padding(.horizontal, 22).padding(.top, 36)
    }
}
