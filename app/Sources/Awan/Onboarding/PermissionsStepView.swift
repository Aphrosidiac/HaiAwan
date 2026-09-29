import AppKit
import SwiftUI

// MARK: - 3. Permissions

struct PermissionsStepView: View {
    @ObservedObject var model: OnboardingModel

    private var kind: PermissionKind { PermissionKind.allCases[model.permissionIndex] }
    private var status: PermissionStatus { model.permissionStatus[kind] ?? .notDetermined }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            card
            checklist
        }
        .padding(.horizontal, 34)
        .padding(.top, 14)
        .padding(.bottom, 28)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(model.permissionIndex + 1) of \(PermissionKind.allCases.count)")
                .font(.awan(11, .semibold)).tracking(0.6).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(status == .granted ? Theme.lime : Theme.cardRaised)
                    Image(systemName: status == .granted ? "checkmark" : kind.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(status == .granted ? Theme.ink : Theme.bone)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title.uppercased()).font(.awan(10.5, .semibold)).tracking(0.9).foregroundStyle(Theme.textTertiary)
                    Text(kind.headline).font(.awanSerif(28)).foregroundStyle(Theme.text)
                }
            }
            .padding(.top, 14)
            Text(kind.explanation)
                .font(.awan(14)).foregroundStyle(Theme.textSecondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            PrivacyLine(kind.privacyLine).padding(.top, 12)
            if kind.usesSettingsList, status != .granted {
                Text("In System Settings, find Awan in the list and switch it on. I'll pop up a little card with my icon you can drag straight into the list.")
                    .font(.awan(12.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
                    .padding(.top, 16)
            }

            statusPill.padding(.top, 18)

            if kind.usesSettingsList, status == .waiting {
                VStack(alignment: .leading, spacing: 8) {
                    Text(kind == .screenRecording
                         ? "Already switched on but still waiting? If Awan was installed before, that switch may belong to the old copy: select Awan, press −, then drag me in again. macOS can also need a quick reopen."
                         : "Already switched on but still waiting? If Awan was installed before, that switch belongs to the old copy: select Awan, press −, then drag me in again.")
                        .font(.awan(11.5)).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if kind == .screenRecording {
                        Button("Quit & reopen Awan") { AppRelauncher.relaunch() }
                            .buttonStyle(.gel(.dark, height: 26, padding: 12, fontSize: 12))
                    }
                }
                .padding(.top, 10)
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                if status == .granted {
                    Button("Continue") { model.nextPermission() }
                        .buttonStyle(.gel(.lime, height: 38, padding: 24))
                } else if status == .notDetermined && !kind.usesSettingsList {
                    Button("Allow \(kind.title.lowercased())") { model.allow(kind) }
                        .buttonStyle(.gel(.lime, height: 38, padding: 22))
                } else {
                    Button("Open System Settings") { kind.usesSettingsList && status == .notDetermined ? model.allow(kind) : model.openSettings(kind) }
                        .buttonStyle(.gel(.lime, height: 38, padding: 22))
                }
                Spacer()
                if status != .granted {
                    Button("Skip for now") { model.nextPermission() }
                        .buttonStyle(.plain)
                        .font(.awan(13, .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(22)
        .frame(width: 420)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.stroke, lineWidth: 1))
        .id(kind)
        .transition(.opacity)
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle().fill(color(status)).frame(width: 7, height: 7)
            Text(status.label).font(.awan(12, .medium)).foregroundStyle(Theme.text)
            if status == .waiting { TypingDots(color: Theme.textTertiary, dot: 3.5) }
        }
        .padding(.horizontal, 11).frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("What Awan needs").padding(.bottom, 10)
            ForEach(Array(PermissionKind.allCases.enumerated()), id: \.element) { i, k in
                let s = model.permissionStatus[k] ?? .notDetermined
                Button { withAnimation(Theme.spring) { model.permissionIndex = i } } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(s == .granted ? Theme.lime : Color.white.opacity(0.07))
                            Image(systemName: s == .granted ? "checkmark" : k.symbol)
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(s == .granted ? Theme.ink : Theme.textSecondary)
                        }
                        .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(k.title).font(.awan(13, .medium)).foregroundStyle(Theme.text)
                            Text(s.shortLabel).font(.awan(11)).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 12).fill(i == model.permissionIndex ? Theme.card : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Skipped ones can be turned on later in System Settings. Awan works with whatever you allow.")
                .font(.awan(11)).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }

    private func color(_ s: PermissionStatus) -> Color {
        switch s {
        case .granted: return Theme.lime
        case .waiting: return Theme.warning
        case .denied: return Theme.danger
        case .notDetermined: return Theme.fieldGrey
        }
    }
}


/// Quits and reopens Awan (some macOS permissions only take effect on a fresh launch).
enum AppRelauncher {
    @MainActor static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}
