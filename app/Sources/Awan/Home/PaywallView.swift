import SwiftUI

/// The upgrade card (reference: PaywallCardContent, measured in the measurements): 544×525.5 card,
/// radius 26, 28 pt side padding; glyph + title row with a 25 pt close; Monthly/Yearly pill 208×35.5 with a
/// "Save 20%" badge; two 238.5×368.5 plan cards 11.5 apart (Popular badge, $ price, billed-annually line,
/// tagline, divider, check rows with ⓘ tooltips, 40 pt gel CTA). The CTA opens checkout via AppState.checkout.
struct PaywallView: View {
    let source: PaywallSource
    @EnvironmentObject var state: AppState
    @Local private var yearly: Bool
    @Local private var pending: String? = nil
    @Local private var tip: String? = nil
    @Namespace private var ns
    /// Snapshot-only: show one feature's ⓘ tooltip (e.g. "pro-talk").
    static var debugTip: String? = nil

    init(source: PaywallSource, yearly: Bool = false) {
        self.source = source
        _yearly = Local(wrappedValue: yearly)
        _tip = Local(wrappedValue: Self.debugTip)
    }

    struct Tier {
        let id: String
        let name: String
        let monthly: Int
        let yearlyPerMonth: Int
        let tagline: String
        let agents: Int
        var yearlyTotal: Int { yearlyPerMonth * 12 }
    }

    private var tiers: [Tier] {
        [
            Tier(id: "pro", name: "Pro", monthly: 20, yearlyPerMonth: 16, tagline: "Great for everyday Awan use.", agents: state.plan.pro_agents_cap ?? 150),
            Tier(id: "max", name: "Max", monthly: 100, yearlyPerMonth: 80, tagline: "For power users who lean on agents.", agents: state.plan.max_agents_cap ?? 1000),
        ]
    }

    private var visibleTiers: [Tier] {
        switch state.plan.tier {
        case "pro": return tiers.filter { $0.id == "max" }
        case "max": return []
        default: return tiers
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if teamSeat != nil || visibleTiers.isEmpty, let sub = subtitle {
                Text(sub).font(.awan(13)).foregroundStyle(Theme.textSecondary).padding(.leading, 57).padding(.top, 4)
            }
            if let team = teamSeat {
                teamPlan(team)
            } else if visibleTiers.isEmpty {
                biggestPlan
            } else {
                intervalToggle
                    .padding(.top, 26.5)
                HStack(alignment: .top, spacing: 11.5) {
                    ForEach(visibleTiers, id: \.id) { planCard($0) }
                }
                .padding(.top, 13.5)
                .zIndex(1)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 30.5)
        .padding(.bottom, visibleTiers.isEmpty || teamSeat != nil ? 26 : 26)
        .frame(width: 544)
        .frame(minHeight: visibleTiers.isEmpty || teamSeat != nil ? nil : 525.5,
               maxHeight: visibleTiers.isEmpty || teamSeat != nil ? nil : 525.5, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(hex: 0x21211F))
        )
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 40, y: 18)
        .background {
            Button("") { close() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            AwanGlyph(color: Theme.bone).frame(width: 29)
                .padding(.leading, 7)
            Text(title).font(.awan(20, .semibold)).foregroundStyle(Theme.text)
                .padding(.leading, 21)
            Spacer(minLength: 8)
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.text.opacity(0.85))
                    .frame(width: 25, height: 25)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .frame(height: 25)
    }

    /// Teams v0: a paid plan that comes from a team seat is managed by the team, not bought here.
    private var teamSeat: PlanTeam? { state.plan.isTeamSeat ? state.plan.team : nil }

    private func teamPlan(_ team: PlanTeam) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.lime.opacity(0.16))
                    Image(systemName: "person.3.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.lime)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(team.seatName) seat on \(team.name)").font(.awan(14.5, .semibold)).foregroundStyle(Theme.text)
                    Text("Unlimited talk and dictation, \((team.seat == "max" ? state.plan.max_agents_cap ?? 1000 : state.plan.pro_agents_cap ?? 150).formatted()) agent messages a month.")
                        .font(.awan(12.5)).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke, lineWidth: 1))
            Text(team.seat == "max"
                 ? "Your team covers the biggest plan. Nothing to buy here."
                 : "Need more room? Ask your team's owner or an admin to move you to a Max seat.")
                .font(.awan(12.5)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Manage team") { Task { await TeamStore.shared.openDashboard() } }
                    .buttonStyle(.gel(.bone, height: 34, padding: 18, fontSize: 13))
                Button("Close") { close() }.buttonStyle(.gel(.dark, height: 34, padding: 18, fontSize: 13))
            }
        }
        .padding(.top, 18)
    }

    private var title: String {
        if teamSeat != nil { return "Included with your team plan." }
        switch state.plan.tier {
        case "pro": return "Upgrade to Awan Max."
        case "max": return "You're on our biggest plan."
        default: return "Upgrade Awan to keep going."
        }
    }

    /// Only the team and biggest-plan states carry a subtitle (the reference's upgrade card has none).
    private var subtitle: String? {
        if let t = teamSeat { return "Your \(t.seatName) seat is paid for by \(t.name)." }
        if source == .limitHit && state.plan.tier != "max" { return "You've used this month's agent messages." }
        if state.plan.tier == "pro" { return "You're on Pro. Max gives your Awans a lot more room." }
        if state.plan.tier == "max" { return nil }
        return "Unlimited talking and dictation, and far more agent work."
    }

    // MARK: Toggle (ref: 208×35.5 track, 71.5×27 gel for the selection, Save 20% badge 63×17)

    private var intervalToggle: some View {
        HStack(spacing: 0) {
            segment("Monthly", on: !yearly) { yearly = false }
            segment("Yearly", badge: "Save 20%", on: yearly) { yearly = true }
        }
        .padding(.horizontal, 2.5)
        .frame(height: 35.5)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func segment(_ label: String, badge: String? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { action() }
        } label: {
            HStack(spacing: 6) {
                Text(label).font(.awan(12.5, .semibold)).foregroundStyle(on ? Theme.ink : Theme.text.opacity(0.55))
                if let badge {
                    Text(badge).font(.awan(11, .bold))
                        .foregroundStyle(on ? Theme.ink : Theme.lime)
                        .frame(width: 63, height: 17)
                        .background(Capsule().fill(on ? Color.black.opacity(0.10) : Theme.lime.opacity(0.13)))
                }
            }
            .padding(.leading, badge == nil ? 12.5 : 14).padding(.trailing, badge == nil ? 12.5 : 6)
            .frame(height: 27)
            .background {
                if on {
                    Capsule()
                        .fill(LinearGradient(colors: [Color(hex: 0xF0FFB0), Theme.lime, Color(hex: 0xC8EE2C)], startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(Color(hex: 0x6F8A00).opacity(0.9), lineWidth: 1))
                        .matchedGeometryEffect(id: "interval", in: ns)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Plan card (ref: 238.5×368.5, radius 20, 18 pt inset)

    private func planCard(_ t: Tier) -> some View {
        let popular = t.id == "pro"
        let price = yearly ? t.yearlyPerMonth : t.monthly
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(t.name).font(.awan(16.5, .semibold)).foregroundStyle(Theme.text)
                if popular {
                    Text("Popular").font(.awan(10.5, .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 46, height: 15)
                        .background(Capsule().fill(LinearGradient(colors: [Color(hex: 0xF0FFB0), Theme.lime, Color(hex: 0xC8EE2C)], startPoint: .top, endPoint: .bottom)))
                        .overlay(Capsule().strokeBorder(Color(hex: 0x6F8A00).opacity(0.9), lineWidth: 1))
                }
                Spacer()
            }
            .frame(height: 21)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("$\(price)").font(.awan(30, .bold)).foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                Text("/mo").font(.awan(12.5, .medium)).foregroundStyle(Theme.text.opacity(0.6))
            }
            .padding(.top, 14.5)
            Text(yearly ? "billed annually ($\(t.yearlyTotal))" : " ")
                .font(.awan(11, .semibold)).foregroundStyle(Theme.text.opacity(0.6))
                .padding(.top, 1.5)
            Text(t.tagline).font(.awan(11.75)).foregroundStyle(Theme.text.opacity(0.62)).lineLimit(1).minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 15)

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.top, 27)

            VStack(alignment: .leading, spacing: 7) {
                feature("\(t.id)-talk", "Unlimited talk", info: "Ask, point and talk without watching the meter.")
                feature("\(t.id)-dictation", "Unlimited dictation", info: "Hold to dictate anywhere, for as long as you want.")
                feature("\(t.id)-agents", "\(t.agents) agent messages a month", info: "Hand work to your Awans: research, builds, routines. Refreshes every month.")
            }
            .padding(.top, 15.5)

            Spacer(minLength: 18)

            Button {
                pending = t.id
                Task {
                    await state.checkout(plan: t.id, yearly: yearly)
                    pending = nil
                }
            } label: {
                Text(pending == t.id ? "Opening checkout…" : "Get Awan \(t.name)")
            }
            .buttonStyle(.gel(popular ? .lime : .bone, height: 40, fullWidth: true, fontSize: 15))
            .disabled(pending != nil)
        }
        .padding(.leading, 18).padding(.trailing, 18)
        .padding(.top, 17.5).padding(.bottom, 18.5)
        .frame(maxWidth: .infinity, minHeight: 368.5, maxHeight: 368.5, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0x2D2D2A)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .zIndex(tip?.hasPrefix(t.id) == true ? 1 : 0)
    }

    /// Check row (ref: 14 pt check, 14.5 semibold text, ⓘ after the text; hovering ⓘ shows a glass
    /// tooltip 222 wide under it).
    private func feature(_ id: String, _ text: String, info: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(hex: 0xF0FFB0), Theme.lime], startPoint: .top, endPoint: .bottom))
                Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(Theme.ink)
            }
            .frame(width: 14, height: 14)
            .padding(.top, 2.5)
            CapWidth(cap: 146) {
                Text(text).font(.awan(12.75, .semibold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            }
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text.opacity(0.45))
                .padding(.top, 3)
                .padding(.leading, 5)
                .contentShape(Rectangle())
                .onHover { tip = $0 ? id : (tip == id ? nil : tip) }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .topLeading) {
            if tip == id { tooltip(info).offset(x: 0, y: 25) }
        }
        .zIndex(tip == id ? 1 : 0)
    }

    private func tooltip(_ text: String) -> some View {
        Text(text)
            .font(.awan(12.5, .medium)).foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 198, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0x4A4A46).opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: Max

    private var biggestPlan: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Awan Max gives you unlimited talk and dictation, and \((state.plan.max_agents_cap ?? 1000).formatted()) agent messages a month. Thanks for backing Awan this hard.")
                .font(.awan(13)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { close() }.buttonStyle(.gel(.bone, height: 34, padding: 20, fontSize: 13))
            }
        }
        .padding(.top, 16)
    }

    private func close() { state.paywall = nil }
}

/// Lays its child out at most `cap` wide and reports the child's own (possibly narrower) size, so a
/// trailing glyph can sit right after short text and after the wrapped line of long text.
struct CapWidth: Layout {
    let cap: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? cap, cap), height: nil)) ?? .zero
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
