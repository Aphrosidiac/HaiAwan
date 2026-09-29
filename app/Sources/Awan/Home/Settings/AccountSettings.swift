import SwiftUI
import AppKit

/// Settings → Account: plan + usage, referrals, log out / delete / quit.
struct AccountSettings: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var ui = SettingsUI.shared
    @Local private var portalBusy = false

    var body: some View {
        SettingsPageHeader(title: "Account", subtitle: "Your plan, usage, and account.")

        if state.signInState != .signedIn {
            signedOut
        } else {
            SettingsGroup(label: "Plan") { planCard }

            SettingsGroup(label: "Referrals") {
                SettingsButtonRow(title: "Invite & Earn", subtitle: "Get paid a share of every payment your friends make.", showDivider: false) {
                    state.homePage = .settings(.referral)
                }
            }

            SettingsGroup(label: "Account") {
                SettingsButtonRow(title: "Log out", subtitle: state.user?.email, trailingSymbol: nil) {
                    Task { await state.signOut() }
                }
                SettingsButtonRow(title: "Delete account", subtitle: "Erase your account and everything Awan knows about you.", titleColor: Theme.danger, trailingSymbol: nil) {
                    ui.modal = .deleteAccount
                }
                SettingsButtonRow(title: "Quit Awan", titleColor: Theme.danger, trailingSymbol: nil, showDivider: false) {
                    NSApp.terminate(nil)
                }
            }

            // Awan-only (teams): after the reference's three groups so their order matches.
            SettingsGroup(label: "Team") { TeamSettingsRows() }
        }
    }

    // MARK: Plan

    private var plan: PlanSnapshot { state.plan }

    /// Reference: 16 pt inset, title cap at +19, two meters side by side (gap 20), 42 pt gel.
    @ViewBuilder private var planCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(headline).font(.awan(15.5, .semibold)).foregroundStyle(Theme.text)
                if !plan.isFree, let interval = plan.interval {
                    StatusChip(text: interval == "year" ? "Yearly" : "Monthly", tone: .lime)
                }
            }
            Text(detail).font(.awan(13.25)).foregroundStyle(SettingsStyle.navText).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2.7)

            HStack(alignment: .top, spacing: 20) {
                UsageMeter(label: "Talk to Awan", bucket: plan.usage.messages)
                UsageMeter(label: "Agent messages", bucket: plan.usage.agents)
            }
            .padding(.top, 12.1)

            HStack(spacing: 10) {
                if plan.tier != "max" && !plan.isTeamSeat {
                    Button(plan.isFree ? "Upgrade Awan" : "Upgrade to Max") {
                        state.presentPaywall(.settingsUpgradeButton)
                    }
                    .buttonStyle(.gel(.lime, height: 42, padding: 23.5, fontSize: 16))
                }
                if plan.isTeamSeat {
                    Text("Billed to your team.").font(.awan(12.5)).foregroundStyle(SettingsStyle.dim)
                    Spacer()
                } else if !plan.isFree {
                    Button(portalBusy ? "Opening…" : "Manage billing") { Task { await openPortal() } }
                        .buttonStyle(.gel(.bone, height: 42, padding: 22, fontSize: 16))
                        .disabled(portalBusy)
                    Spacer()
                    Button("Cancel plan") { ui.modal = .cancelPlan }
                        .buttonStyle(.plain)
                        .font(.awan(13, .medium))
                        .foregroundStyle(SettingsStyle.dim)
                } else {
                    Spacer()
                }
            }
            .padding(.top, 13.5)
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.top, 15.1)
        .padding(.bottom, 15.5)
        .task { if !SettingsEnv.isSnapshot { await state.refreshPlan() } }
    }

    private var headline: String {
        switch plan.status {
        case "past_due", "unpaid": return "There's a problem with your \(plan.tierName) payment."
        default:
            if plan.isTeamSeat, let team = plan.team { return "You're on Awan \(plan.tierName) with \(team.name)." }
            return plan.isFree ? "You're on the Free plan." : "You're on Awan \(plan.tierName)."
        }
    }

    private var detail: String {
        let agents = plan.usage.agents.cap.map { "\($0.formatted()) agent messages" } ?? "unlimited agent messages"
        let reset = resetText.map { " Your usage resets \($0)." } ?? ""
        if plan.status == "past_due" || plan.status == "unpaid" {
            return "Update your payment method to keep Awan working. Agent work is paused until billing is fixed."
        }
        if let talks = plan.usage.messages.cap {
            return "Talk to Awan \(talks) times a month and send \(agents).\(reset)"
        }
        return "Talk to Awan as much as you like and send \(agents) a month.\(reset)"
    }

    private var resetText: String? {
        guard let at = plan.resetsAt else { return nil }
        let s = max(0, Int(at.timeIntervalSinceNow))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "in \(d)d \(h)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(max(1, m))m"
    }

    private func openPortal() async {
        portalBusy = true
        defer { portalBusy = false }
        struct R: Decodable { var url: String }
        do {
            let r: R = try await APIClient.shared.send("v1/billing/portal", method: "POST", body: [String: String]())
            if let url = URL(string: r.url) { NSWorkspace.shared.open(url) }
        } catch APIError.server(501, _) {
            state.show("Billing management isn't switched on for this server yet.")
        } catch {
            state.show(error)
        }
    }

    // MARK: Signed out

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                CloudCreature(appearance: .mascot, mood: .sleeping, glow: false).frame(width: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("You're not signed in").font(.awan(16, .semibold)).foregroundStyle(Theme.text)
                    Text("Sign in to sync your plan, connect apps and let your Awans get to work.")
                        .font(.awan(12.5)).foregroundStyle(Theme.textSecondary)
                }
            }
            HStack {
                Button("Sign in") { OnboardingController.shared.begin() }
                    .buttonStyle(.gel(.lime, height: 34, padding: 20, fontSize: 13))
                Spacer()
                Button("Quit Awan") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.awan(12.5, .medium)).foregroundStyle(Theme.danger)
            }
        }
        .settingsCard()
    }
}

// MARK: - Delete account

struct DeleteAccountSheet: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var ui = SettingsUI.shared
    @Local private var reason: String? = nil
    @Local private var confirm = ""

    static let reasons = ["Too expensive", "Not useful yet", "Privacy", "Something else"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(Theme.danger.opacity(0.16))
                    Image(systemName: "trash.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.danger)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Delete your account?").font(.awan(18, .semibold)).foregroundStyle(Theme.text)
                    Text("This wipes your chats, agents and everything Awan remembers about you, and cancels any subscription. It can't be undone.")
                        .font(.awan(12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Before you go, what made you leave?").font(.awan(12.5, .semibold)).foregroundStyle(Theme.text)
                FlowRow(spacing: 8) {
                    ForEach(Self.reasons, id: \.self) { r in
                        let on = reason == r
                        Button { reason = r } label: {
                            Text(r).font(.awan(12.5, .medium))
                                .foregroundStyle(on ? Theme.ink : Theme.text)
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(Capsule().fill(on ? Theme.bone : Theme.card))
                                .overlay(Capsule().strokeBorder(on ? .clear : Theme.stroke, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Type DELETE to confirm").font(.awan(11.5)).foregroundStyle(Theme.textTertiary)
                SettingsTextField(placeholder: "DELETE", text: $confirm, mono: true)
            }

            HStack {
                Spacer()
                Button("Never mind") { ui.modal = nil }.buttonStyle(.gel(.bone, height: 32, padding: 16, fontSize: 13))
                Button(ui.modalBusy ? "Deleting…" : "Delete forever") {
                    Task {
                        ui.modalBusy = true
                        Log.info("account deletion requested, reason: \(reason ?? "none")")
                        await state.deleteAccount()
                        ui.modalBusy = false
                        ui.modal = nil
                        if state.signInState == .signedOut {
                            state.homePage = .home
                            state.show("Your account is gone. Take care.")
                        }
                    }
                }
                .buttonStyle(.gel(.danger, height: 32, padding: 16, fontSize: 13))
                .disabled(confirm != "DELETE" || ui.modalBusy)
            }
        }
        .padding(22)
    }
}

// MARK: - Cancel plan

struct CancelPlanSheet: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var ui = SettingsUI.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cancel Awan \(state.plan.tierName)?").font(.awan(18, .semibold)).foregroundStyle(Theme.text)
            Text("You'll drop back to the Free plan: 25 talks and 25 agent messages a month. Your Awans, chats and files stay right where they are.")
                .font(.awan(12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Keep \(state.plan.tierName)") { ui.modal = nil }.buttonStyle(.gel(.bone, height: 32, padding: 16, fontSize: 13))
                Button(ui.modalBusy ? "Cancelling…" : "Cancel plan") {
                    Task {
                        ui.modalBusy = true
                        defer { ui.modalBusy = false }
                        do {
                            let p: PlanSnapshot = try await APIClient.shared.send("v1/billing/cancel", method: "POST", body: [String: String]())
                            state.plan = p
                            ui.modal = nil
                            state.show("Your plan is cancelled. You're on Free now.")
                        } catch { state.show(error) }
                    }
                }
                .buttonStyle(.gel(.danger, height: 32, padding: 16, fontSize: 13))
                .disabled(ui.modalBusy)
            }
        }
        .padding(22)
    }
}

// MARK: - Flow layout (wrapping chips)

struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxW { x = 0; y += lineH + (lineSpacing ?? spacing); lineH = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineH = max(lineH, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += lineH + (lineSpacing ?? spacing); lineH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineH = max(lineH, size.height)
        }
    }
}
