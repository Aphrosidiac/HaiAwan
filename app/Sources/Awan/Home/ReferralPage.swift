import SwiftUI
import AppKit

/// Invite & Earn, laid out on the reference: hero card with the mascot peeking over
/// its edge, link field + Copy link / Copy code, three stat cards, people you've invited (examples while empty),
/// what you could make (total, 12-bar chart, three gel sliders, summary), getting paid.
/// Rendered inside a ScrollView by its host (Home's .referral page or Settings).
struct ReferralPage: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var model = ReferralModel.shared
    @ObservedObject private var links = RemoteLinks.shared
    @Local private var editing = false
    @Local private var draftHandle = ""
    @Local private var copied: String? = nil
    @Local private var proPerMonth: Double = 10
    @Local private var maxPerMonth: Double = 5
    @Local private var stayMonths: Double = 12

    static let heroFill = Color(hex: 0x3B3B38)      // ref #3B3B3D
    static let statFill = Color(hex: 0x2C2C2A)      // ref #2C2B2C
    static let proGel = [Color(hex: 0xF0FFB0), Theme.lime, Color(hex: 0xC8EE2C)]
    static let maxGel = [Color(hex: 0xFFE7CF), Color(hex: 0xFFC996), Color(hex: 0xF4A864)]
    static let stayGel = [Color(hex: 0xF3FFF5), Color(hex: 0xCDEFD6), Color(hex: 0xA9DDB8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero.padding(.top, 29)
            statTiles.padding(.top, 20.5)
            SettingsSectionLabel(model.info?.referrals.isEmpty == false ? "People you've invited · \(model.info?.referrals.count ?? 0)" : "People you've invited")
                .padding(.leading, 5).padding(.top, 22).padding(.bottom, SettingsStyle.labelGap + 0.5)
            invited
            SettingsSectionLabel("What you could make")
                .padding(.leading, 5).padding(.top, 18.5).padding(.bottom, SettingsStyle.labelGap + 0.5)
            estimator
            SettingsSectionLabel("Getting paid")
                .padding(.leading, 5).padding(.top, 18.5).padding(.bottom, SettingsStyle.labelGap + 0.5)
            gettingPaid
            if model.showsClaim { ReferralClaimRow().padding(.top, SettingsStyle.groupSpacing) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            if model.info == nil, let h = state.user?.referralHandle { model.fallback(handle: h) }
            await model.load()
        }
        .onAppear { links.load() }
    }

    private var terms: ReferralInfo.Terms { model.info?.terms ?? .init(share: 0.25, friendDiscount: 0.25, months: 12) }
    private var sharePct: String { "\(Int((terms.share * 100).rounded()))%" }
    private var discountPct: String { "\(Int((terms.friendDiscount * 100).rounded()))%" }

    // MARK: Hero (ref: card 625×207.5, radius 22; mascot 136 wide, 80 above the card, paws on its edge)

    private var hero: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Invite your friends and earn.")
                    .font(.awan(21.5, .medium)).foregroundStyle(Theme.text)
                Text("Earn \(money(minEarn)) to \(money(maxEarn)) per friend. They get \(discountPct) off.")
                    .font(.awan(14.5)).foregroundStyle(SettingsStyle.navText)
                    .padding(.top, 5)
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.top, 8.5)
                Text("SHARE THIS TO EARN").font(SettingsStyle.label).tracking(1.6).foregroundStyle(SettingsStyle.navText)
                    .padding(.top, 7.5)
                linkField.padding(.top, 5)
                if let err = model.handleError {
                    Text(err).font(.awan(12)).foregroundStyle(Theme.danger).padding(.top, 6)
                }
                HStack(spacing: 10) {
                    Button { copy(model.shareURL, "Link copied") } label: {
                        Label(copied == "Link copied" ? "Link copied" : "Copy link", systemImage: copied == "Link copied" ? "checkmark" : "link")
                    }
                    .buttonStyle(.gel(.lime, height: 42, padding: 17, fontSize: 16.5))
                    Button { copy("@" + model.handle, "Code copied") } label: {
                        Label(copied == "Code copied" ? "Code copied" : "Copy code", systemImage: copied == "Code copied" ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.gel(.bone, height: 42, padding: 20, fontSize: 16.5))
                }
                .padding(.top, 9)
            }
            .padding(.leading, 15).padding(.trailing, 15)
            .padding(.top, 14.5).padding(.bottom, 13.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Self.heroFill))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.05), lineWidth: 1))
            .padding(.top, 80.5)

            CloudCreature(appearance: .mascot, mood: .happy, showPaws: true)
                .frame(width: 136)
                .padding(.leading, 13)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var linkField: some View {
        HStack(spacing: 0) {
            if editing {
                Text(model.linkPrefix).font(.awan(22, .semibold)).foregroundStyle(Theme.ink.opacity(0.45))
                TextField("yourname", text: $draftHandle)
                    .textFieldStyle(.plain)
                    .font(.awan(22, .semibold))
                    .foregroundStyle(Theme.ink)
                    .onSubmit { Task { await saveHandle() } }
                Spacer(minLength: 8)
                Button("Cancel") { editing = false; model.handleError = nil }
                    .buttonStyle(.plain).font(.awan(13.5, .semibold)).foregroundStyle(Theme.ink.opacity(0.6))
                    .padding(.trailing, 10)
                Button(model.savingHandle ? "Saving…" : "Save") { Task { await saveHandle() } }
                    .buttonStyle(.gel(.dark, height: 28, padding: 12, fontSize: 13.5))
                    .disabled(model.savingHandle)
            } else {
                (Text(model.linkPrefix).foregroundColor(Theme.ink.opacity(0.45)) + Text(model.handle).foregroundColor(Theme.ink))
                    .font(.awan(22, .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button {
                    draftHandle = model.handle
                    model.handleError = nil
                    editing = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil").font(.system(size: 12, weight: .semibold))
                        Text("Edit").font(.awan(14.5, .semibold))
                    }
                    .foregroundStyle(Theme.ink.opacity(0.62))
                    .padding(.horizontal, 12).frame(height: 27)
                    .background(Capsule().fill(Color.black.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .frame(height: 45)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(LinearGradient(colors: [Color.white, Theme.bone, Color(hex: 0xE4DFD1)], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.black.opacity(0.15), lineWidth: 1))
    }

    private func saveHandle() async {
        if await model.saveHandle(draftHandle) { editing = false; state.show("Your link is now \(model.displayLink).") }
    }

    private func copy(_ s: String, _ label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        withAnimation(Theme.snappy) { copied = label }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if copied == label { withAnimation(Theme.snappy) { copied = nil } }
        }
    }

    // MARK: Stats (ref: three 200×122 cards, 11 apart, radius 16)

    private var statTiles: some View {
        HStack(spacing: 11) {
            tile("For every friend", "Earn \(sharePct)", "For example, a $20/month plan earns you \(money(20 * terms.share)) each month.")
            tile("Your friend gets", "\(discountPct) off", "Their first month of Pro or Max on a monthly plan.")
            tile("Earn for up to", "\(terms.months) months", "You earn from their first paid month, for as long as they stay subscribed.")
        }
    }

    private func tile(_ label: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.awan(14.5, .semibold)).foregroundStyle(Theme.text.opacity(0.78))
            Text(value).font(.awan(26, .bold)).foregroundStyle(Theme.text).padding(.top, -1)
            Text(note).font(.awan(12.75)).foregroundStyle(SettingsStyle.navText).lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            Spacer(minLength: 0)
        }
        .padding(.leading, 13).padding(.trailing, 12).padding(.top, 11)
        .frame(maxWidth: .infinity, minHeight: 122, maxHeight: 122, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Self.statFill))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }

    // MARK: Invited (ref: 35.5 pt EXAMPLE row, 51.5 pt friend rows)

    private var invited: some View {
        let people = model.info?.referrals ?? []
        let rows = people.isEmpty ? ReferralInfo.examples : people
        return VStack(spacing: 0) {
            if people.isEmpty {
                HStack(spacing: 10) {
                    Text("EXAMPLE").font(.awan(12, .bold)).tracking(1.8).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 9).frame(height: 21)
                        .background(Capsule().fill(LinearGradient(colors: Self.maxGel, startPoint: .top, endPoint: .bottom)))
                        .overlay(Capsule().strokeBorder(Color(hex: 0xB86B2A).opacity(0.7), lineWidth: 1))
                    Text("Nobody has joined yet. Here's how your list will look once friends do.")
                        .font(.awan(14.5, .medium)).foregroundStyle(SettingsStyle.navText).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).frame(height: 40)
                .overlay(alignment: .bottom) { Rectangle().fill(SettingsStyle.stroke).frame(height: 1).padding(.leading, 14) }
            } else if let total = model.info?.totalEarnedCents, total > 0 {
                HStack {
                    Text("Total earned").font(.awan(14.5, .medium)).foregroundStyle(SettingsStyle.navText)
                    Spacer()
                    Text("+\(money(Double(total) / 100))").font(.awan(16, .semibold)).foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 14).frame(height: 36)
                .overlay(alignment: .bottom) { Rectangle().fill(SettingsStyle.stroke).frame(height: 1).padding(.leading, 14) }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                friendRow(r, last: i == rows.count - 1)
            }
        }
        .background(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous).fill(SettingsStyle.card))
        .overlay(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous).strokeBorder(SettingsStyle.stroke, lineWidth: 1))
    }

    private func friendRow(_ r: ReferralInfo.Friend, last: Bool) -> some View {
        HStack(spacing: 0) {
            ZStack {
                Circle().fill(Color.pastel(hue: Self.hue(for: r.name), saturation: 0.35, brightness: 0.85))
                Text(String(r.name.prefix(1)).uppercased()).font(.awan(13, .semibold)).foregroundStyle(Theme.ink)
            }
            .frame(width: 30, height: 30)
            .padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(.awan(15, .medium)).foregroundStyle(Theme.text)
                Text(r.months > 0 ? "Subscribed for \(r.months) \(r.months == 1 ? "month" : "months")" : "Joined through your link")
                    .font(.awan(13.5)).foregroundStyle(SettingsStyle.dim)
            }
            Spacer(minLength: 8)
            if r.earnedCents > 0 {
                HStack(spacing: 6) {
                    Text("You earned").font(.awan(13.5)).foregroundStyle(SettingsStyle.dim)
                    Text("+\(money(Double(r.earnedCents) / 100))").font(.awan(16, .semibold)).foregroundStyle(Theme.text)
                }
                .padding(.trailing, 12)
            }
            planBadge(r.plan)
        }
        .padding(.leading, 14).padding(.trailing, 13)
        .frame(height: 51.5)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(SettingsStyle.stroke).frame(height: 1).padding(.leading, 56) } }
    }

    /// Gel plan badge, 52×22 (ref: Max peach, Pro blue, Free outline → Awan: Max apricot, Pro lime, Free outline).
    private func planBadge(_ plan: String) -> some View {
        let label = plan == "free" ? "Free" : plan.capitalized
        return Text(label)
            .font(.awan(14, .bold))
            .foregroundStyle(plan == "free" ? Theme.text : Theme.ink)
            .frame(width: 52, height: 22)
            .background {
                if plan == "free" {
                    Capsule().fill(Color.white.opacity(0.06)).overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                } else {
                    Capsule().fill(LinearGradient(colors: plan == "max" ? Self.maxGel : Self.proGel, startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
                }
            }
    }

    // MARK: Estimator

    private var monthly: [Double] {
        let proEach = 20 * terms.share, maxEach = 100 * terms.share
        let stay = Int(stayMonths)
        return (1 ... 12).map { m in
            // everyone who joined in the last `stay` months is still paying
            let active = Double(min(m, stay))
            return active * (proPerMonth * proEach + maxPerMonth * maxEach)
        }
    }

    private var estimator: some View {
        let total = monthly.reduce(0, +)
        return VStack(alignment: .leading, spacing: 0) {
            Text("IN YOUR FIRST YEAR").font(SettingsStyle.label).tracking(1.6).foregroundStyle(SettingsStyle.dim)
            Text(money(total))
                .font(.awan(41, .bold)).tracking(-0.3)
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0xF0FFB0), Theme.lime], startPoint: .top, endPoint: .bottom))
                .contentTransition(.numericText())
                .animation(Theme.snappy, value: total)
                .padding(.top, 1)
            EarningsBars(values: monthly, label: money(monthly.last ?? 0))
                .frame(height: 118)
                .padding(.top, 10)
            VStack(spacing: 18) {
                slider(value: $proPerMonth, range: 1 ... 20, big: "\(Int(proPerMonth)) Pro referrals", unit: "/ month", note: "$20/mo plan", gel: Self.proGel)
                slider(value: $maxPerMonth, range: 1 ... 20, big: "\(Int(maxPerMonth)) Max referrals", unit: "/ month", note: "$100/mo plan", gel: Self.maxGel)
                slider(value: $stayMonths, range: 1 ... 12, big: "\(Int(stayMonths)) months", unit: "/ friend", note: "how long they stick around", gel: Self.stayGel)
            }
            .padding(.top, 18)
            Text("Refer \(Int(proPerMonth)) people on Pro and \(Int(maxPerMonth)) people on Max a month who each stay \(Int(stayMonths)) months. That's about \(money(total)) in your first year, and the people who join late keep paying into the next.")
                .font(.awan(15.5, .medium)).foregroundStyle(SettingsStyle.navText).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)
        }
        .padding(.leading, 17).padding(.trailing, 17).padding(.top, 19.5).padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(SettingsStyle.stroke, lineWidth: 1))
    }

    private func slider(value: Binding<Double>, range: ClosedRange<Double>, big: String, unit: String, note: String, gel: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(big).font(.awan(22, .bold)).foregroundStyle(Theme.text).monospacedDigit()
                Text(unit).font(.awan(22, .bold)).foregroundStyle(SettingsStyle.dim)
                Spacer()
                Text(note).font(.awan(14.5, .medium)).foregroundStyle(SettingsStyle.dim)
            }
            GelSlider(value: value, range: range, gel: gel)
        }
    }

    // MARK: Getting paid

    private var gettingPaid: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "Get paid", subtitle: "Real money, not credits. We pay out monthly once you've earned \(money(25)); smaller balances roll over.") {
                Button("Email us") { links.open("payouts") }
                    .buttonStyle(.gel(.dark, height: 33, padding: 16, fontSize: 14.5))
            }
            SettingsButtonRow(title: "Referral terms", subtitle: "What counts, what doesn't, and how payouts work.", trailingSymbol: "arrow.up.right", showDivider: false) {
                links.open("terms")
            }
        }
        .background(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous).fill(SettingsStyle.card))
        .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous).strokeBorder(SettingsStyle.stroke, lineWidth: 1))
    }

    // MARK: Helpers

    static func hue(for name: String) -> Double {
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Double(sum % 97) / 97.0
    }

    private var minEarn: Double { 20 * terms.share }
    private var maxEarn: Double { 100 * terms.share * Double(terms.months) }

    private func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = v.rounded() == v ? 0 : 2
        return f.string(from: NSNumber(value: v)) ?? "$\(Int(v))"
    }
}

/// The reference's calculator slider: a 24 pt dark track with a dot per step, a gel fill up to the
/// knob, and a 30 pt white knob with ‹ › on it. Drag or click anywhere on the track.
struct GelSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let gel: [Color]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, knob: CGFloat = 30
            let steps = Int(range.upperBound - range.lowerBound)
            let t = CGFloat((value - range.lowerBound) / max(1, range.upperBound - range.lowerBound))
            let cx = knob / 2 + t * (w - knob)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.48)).frame(height: 24)
                ForEach(0 ... max(steps, 1), id: \.self) { i in
                    Circle().fill(Color.white.opacity(0.28)).frame(width: 3, height: 3)
                        .position(x: knob / 2 + CGFloat(i) / CGFloat(max(steps, 1)) * (w - knob), y: 15)
                }
                Capsule()
                    .fill(LinearGradient(colors: gel, startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .top) { Capsule().fill(Color.white.opacity(0.5)).frame(height: 5).padding(.horizontal, 8).padding(.top, 3) }
                    .frame(width: max(24, cx + 6), height: 22)
                    .padding(.leading, 1)
                    .shadow(color: gel[1].opacity(0.35), radius: 6)
                ZStack {
                    Circle().fill(.white).shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.ink)
                }
                .frame(width: knob, height: knob)
                .position(x: cx, y: 15)
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = min(1, max(0, (g.location.x - knob / 2) / max(1, w - knob)))
                value = (range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)).rounded()
            })
        }
        .frame(height: 30)
        .animation(Theme.snappy, value: value)
    }
}

/// "Were you invited?" — a friend who signed up without the link names their referrer afterwards.
struct ReferralClaimRow: View {
    @ObservedObject private var model = ReferralModel.shared
    @EnvironmentObject var state: AppState
    @Local private var draft = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.info?.invitedBy != nil ? "heart.fill" : "person.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.07)))
            if let inviter = model.info?.invitedBy {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invited by \(inviter.name)").font(.awan(13, .semibold)).foregroundStyle(Theme.text)
                    Text("@\(inviter.handle) gets a share when you upgrade.").font(.awan(11.5)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Were you invited?").font(.awan(13, .semibold)).foregroundStyle(Theme.text)
                    HStack(spacing: 8) {
                        TextField("Their link or name, like @sam", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.awan(13))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.055)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke, lineWidth: 1))
                            .onSubmit { Task { await claim() } }
                        Button(model.claiming ? "Claiming…" : "Claim") { Task { await claim() } }
                            .buttonStyle(.gel(.bone, height: 30, padding: 14, fontSize: 12.5))
                            .disabled(model.claiming || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let err = model.claimError {
                        Text(err).font(.awan(11.5)).foregroundStyle(Theme.danger)
                    }
                }
            }
        }
        .settingsCard(padding: 14)
    }

    private func claim() async {
        if await model.claim(draft) {
            draft = ""
            if let n = model.info?.invitedBy?.name { state.show("Thanks! \(n) gets the credit.") }
        }
    }
}

/// 12 monthly gel bars (ref: 44 pt wide, 6 apart, glossy), the last month's amount above the last bar.
struct EarningsBars: View {
    let values: [Double]
    var label: String? = nil
    var body: some View {
        let top = max(values.max() ?? 1, 1)
        GeometryReader { geo in
            let maxH = geo.size.height - 22
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    VStack(spacing: 5) {
                        if i == values.count - 1, let label {
                            Text(label).font(.awan(13.5, .bold)).foregroundStyle(Theme.lime).fixedSize()
                        }
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hex: 0xF4FFC4), Theme.lime.opacity(0.85 + 0.15 * Double(i) / 11)], startPoint: .top, endPoint: .bottom))
                            .overlay(alignment: .top) {
                                Capsule().fill(Color.white.opacity(0.55)).frame(height: 3).padding(.horizontal, 10).padding(.top, 3)
                            }
                            .frame(height: max(4, CGFloat(v / top) * maxH))
                            .opacity(0.35 + 0.65 * Double(i + 1) / Double(values.count))
                    }
                    .frame(maxWidth: .infinity)
                    .help("Month \(i + 1): $\(Int(v.rounded()))")
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .animation(Theme.snappy, value: values)
    }
}

// MARK: - Data

struct ReferralInfo: Decodable, Equatable {
    struct Terms: Decodable, Equatable { var share: Double; var friendDiscount: Double; var months: Int }
    struct Friend: Decodable, Equatable {
        var name: String
        var avatarUrl: String?
        var plan: String
        var months: Int
        var earnedCents: Int
        var joinedAt: String?
    }
    var handle: String
    var link: String
    var url: String
    var terms: Terms
    var totalEarnedCents: Int
    var referrals: [Friend]
    /// Who invited this account (nil until claimed / not referred). Older servers omit both fields.
    struct Inviter: Decodable, Equatable { var handle: String; var name: String }
    var invitedBy: Inviter? = nil
    /// True while this account may still claim a referrer (no referrer yet, account under 30 days old).
    var canClaim: Bool? = nil

    static let examples: [Friend] = [
        .init(name: "Aina", plan: "max", months: 2, earnedCents: 5000),
        .init(name: "Danial", plan: "pro", months: 3, earnedCents: 1500),
        .init(name: "Mei Ling", plan: "free", months: 0, earnedCents: 0),
    ]
}

@MainActor
final class ReferralModel: ObservableObject {
    static let shared = ReferralModel()
    @Published var info: ReferralInfo?
    @Published var handleError: String?
    @Published var savingHandle = false
    @Published var claimError: String?
    @Published var claiming = false

    /// The "Were you invited?" row shows while the server says a claim is still possible, and after a
    /// successful claim (as a thank-you line).
    var showsClaim: Bool { info?.canClaim == true || info?.invitedBy != nil }

    var handle: String { info?.handle ?? AppState.shared.user?.referralHandle ?? "you" }
    var displayLink: String { info?.link ?? "awan.ffdev.studio/@\(handle)" }
    var shareURL: String { info?.url ?? "https://awan.ffdev.studio/@\(handle)" }
    var linkPrefix: String {
        let l = displayLink
        if let r = l.range(of: "/@") { return String(l[..<r.upperBound]) }
        return "awan.ffdev.studio/@"
    }

    func fallback(handle: String) {
        info = ReferralInfo(handle: handle, link: "awan.ffdev.studio/@\(handle)", url: "https://awan.ffdev.studio/@\(handle)",
                            terms: .init(share: 0.25, friendDiscount: 0.25, months: 12), totalEarnedCents: 0, referrals: [])
    }

    func load() async {
        guard !SettingsEnv.isSnapshot else { return }
        if let r: ReferralInfo = try? await APIClient.shared.send("v1/referrals") { info = r }
    }

    /// PATCH /v1/referrals/handle. Returns true on success.
    func saveHandle(_ raw: String) async -> Bool {
        let h = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@")).lowercased()
        guard h != handle else { return true }
        guard h.range(of: "^[a-z0-9_]{3,24}$", options: .regularExpression) != nil else {
            handleError = "Use 3 to 24 letters, numbers or underscores."
            return false
        }
        savingHandle = true
        defer { savingHandle = false }
        struct R: Decodable { var handle: String }
        do {
            let _: R = try await APIClient.shared.send("v1/referrals/handle", method: "PATCH", body: ["handle": h])
            handleError = nil
            await load()
            if info?.handle != h { fallbackKeepingTerms(h) }
            return true
        } catch APIError.server(409, _) {
            handleError = "@\(h) is taken. Try another."
        } catch APIError.server(400, _) {
            handleError = "Use 3 to 24 letters, numbers or underscores."
        } catch {
            handleError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return false
    }

    /// POST /v1/referrals/claim — `raw` may be "@sam", "sam" or the invite link. Returns true on success.
    func claim(_ raw: String) async -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { claimError = "Paste their link or type their name, like @sam."; return false }
        claiming = true
        defer { claiming = false }
        struct R: Decodable { struct Ref: Decodable { var handle: String; var name: String }; var ok: Bool; var referrer: Ref }
        do {
            let r: R = try await APIClient.shared.send("v1/referrals/claim", method: "POST", body: ["handle": trimmed])
            claimError = nil
            if var i = info { i.invitedBy = .init(handle: r.referrer.handle, name: r.referrer.name); i.canClaim = false; info = i }
            await load()
            return true
        } catch let APIError.server(code, message) {
            claimError = Self.claimMessage(code: code, error: message)
        } catch {
            claimError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return false
    }

    static func claimMessage(code: Int, error: String) -> String {
        switch error {
        case "unknown_handle": return "We couldn't find that name. Check the spelling, or paste their link."
        case "invalid_handle": return "That doesn't look like an invite. Try their link or @name."
        case "self_referral": return "That's your own link. Nice try ^_^"
        case "already_claimed": return "You've already said who invited you."
        case "account_too_old": return "Invites can only be claimed in your first 30 days."
        default: return code == 409 ? "This account can't claim an invite any more." : "Couldn't claim that invite (\(code))."
        }
    }

    private func fallbackKeepingTerms(_ h: String) {
        guard var i = info else { fallback(handle: h); return }
        i.link = i.link.replacingOccurrences(of: "@\(i.handle)", with: "@\(h)")
        i.url = i.url.replacingOccurrences(of: "@\(i.handle)", with: "@\(h)")
        i.handle = h
        info = i
    }
}
