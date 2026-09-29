import SwiftUI
import AppKit

// MARK: - Plan step (after the tutorial or "Skip demo")
//
// Measured on the reference's plan chooser: an 800×543 window holding a dark panel
// inset 8 pt (radius ≈22), header glyph + title + close, a Monthly/Yearly pill, then Free / Pro / Max cards
// 235 wide with a gel CTA each. Awan: lime for the one primary action ("Use Awan for free"), bone gels for the
// paid plans, its own copy and caps (server/src/plans.ts). Positions are panel-local points.

enum PlanChooserLayout {
    static let window = CGSize(width: 800, height: 543)
    static let inset: CGFloat = 8
    static let radius: CGFloat = 22
    static let cardWidth: CGFloat = 235
    static let cardGap: CGFloat = 11.5
    static let cardTop: CGFloat = 130.5
    static let cardHeight: CGFloat = 371.5
    static let side: CGFloat = 28
}

struct PlanChooserView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var state = AppState.shared
    @Local private var yearly = false
    @Local private var pending: String? = nil
    @Namespace private var ns

    struct Plan: Identifiable {
        let id: String
        let name: String
        let monthly: Int
        let yearlyPerMonth: Int
        let note: String?
        let tagline: String
        let features: [(String, String)]
        let cta: String
    }

    private var plans: [Plan] {
        let pro = state.plan.pro_agents_cap ?? 150, max = state.plan.max_agents_cap ?? 1000
        return [
            Plan(id: "free", name: "Free", monthly: 0, yearlyPerMonth: 0, note: "No card needed",
                 tagline: "Try Awan on your own work. Upgrade whenever you like.",
                 features: [("25 talk messages a month", "Hold the keys and ask. Resets every month."),
                            ("50 dictations a month", "Talk instead of typing, in any app."),
                            ("25 agent messages\na month", "Hand small jobs to your Awans.")],
                 cta: "Use Awan for free"),
            Plan(id: "pro", name: "Pro", monthly: 20, yearlyPerMonth: 16, note: nil,
                 tagline: "For everyday Awan, all day long.",
                 features: [("Unlimited talk", "Ask, point and talk as much as you like."),
                            ("Unlimited dictation", "Dictate anywhere, for as long as you want."),
                            ("\(pro.formatted()) agent messages\na month", "Research, builds and routines. Refreshes monthly.")],
                 cta: "Get Awan Pro"),
            Plan(id: "max", name: "Max", monthly: 100, yearlyPerMonth: 80, note: nil,
                 tagline: "For a squad of Awans working\nin the background.",
                 features: [("Unlimited talk", "Ask, point and talk as much as you like."),
                            ("Unlimited dictation", "Dictate anywhere, for as long as you want."),
                            ("\(max.formatted()) agent messages\na month", "Plenty of room for long agent runs.")],
                 cta: "Get Awan Max"),
        ]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: PlanChooserLayout.radius, style: .continuous).fill(Color(hex: 0x1C1C1B))
            RoundedRectangle(cornerRadius: PlanChooserLayout.radius, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            header
            intervalToggle.offset(x: 27.5, y: 81.5)
            ForEach(Array(plans.enumerated()), id: \.element.id) { i, p in
                card(p)
                    .offset(x: PlanChooserLayout.side + CGFloat(i) * (PlanChooserLayout.cardWidth + PlanChooserLayout.cardGap), y: PlanChooserLayout.cardTop)
            }
        }
        .frame(width: PlanChooserLayout.window.width - 2 * PlanChooserLayout.inset, height: PlanChooserLayout.window.height - 2 * PlanChooserLayout.inset)
        .clipShape(RoundedRectangle(cornerRadius: PlanChooserLayout.radius, style: .continuous))
        .padding(PlanChooserLayout.inset)
        .preferredColorScheme(.dark)
        .background {
            Button("") { model.choosePlan(nil, yearly: false) }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        }
    }

    // MARK: Header: glyph · "Choose your Awan plan" · close

    private var header: some View {
        ZStack(alignment: .topLeading) {
            AwanGlyph(color: Theme.bone).frame(width: 32).offset(x: 33.5, y: 29.5)
            Text("Choose your Awan plan").font(.awan(20, .semibold)).foregroundStyle(Theme.text)
                .offset(x: 84.5, y: 30.5)
            Button { model.choosePlan(nil, yearly: false) } label: {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 25, height: 25)
                    .background(Circle().fill(Color.white.opacity(0.05)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Decide later")
            .offset(x: 731.5, y: 30.5)
        }
    }

    // MARK: Monthly / Yearly

    private var intervalToggle: some View {
        HStack(spacing: 0) {
            segment("Monthly", on: !yearly, width: 71.5) { yearly = false }
            segment("Yearly", badge: "Save 20%", on: yearly, width: 128) { yearly = true }
        }
        .padding(.horizontal, 3)
        .frame(width: 209, height: 36, alignment: .leading)
        .background(Capsule().fill(Color.white.opacity(0.045)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func segment(_ label: String, badge: String? = nil, on: Bool, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { action() }
        } label: {
            HStack(spacing: 8) {
                Text(label).font(.awan(14, .semibold)).foregroundStyle(on ? Theme.ink : Theme.textSecondary)
                if let badge {
                    Text(badge).font(.awan(11.5, .bold))
                        .foregroundStyle(on ? Theme.ink : Theme.lime)
                        .padding(.horizontal, 7).frame(height: 17)
                        .background(Capsule().fill(on ? Color.black.opacity(0.10) : Theme.lime.opacity(0.14)))
                }
            }
            .frame(width: width, height: 27)
            .background {
                if on {
                    Capsule().fill(TutorialGel.fill)
                        .overlay(Capsule().strokeBorder(TutorialGel.rim, lineWidth: 1))
                        .matchedGeometryEffect(id: "interval", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Card

    private func card(_ p: Plan) -> some View {
        let price = yearly ? p.yearlyPerMonth : p.monthly
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05))
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Text(p.name).font(.awan(16, .semibold)).foregroundStyle(Theme.text)
                    if p.id == "pro" {
                        Text("Popular").font(.awan(10.5, .bold)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 8).frame(height: 15)
                            .background(Capsule().fill(Theme.lime))
                    }
                }
                .frame(height: 22)
                .padding(.top, -1.5)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("$\(price)").font(.awan(30, .bold)).foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                    if p.monthly > 0 {
                        Text("/mo").font(.awan(14.5)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.top, 14.5)
                Group {
                    if let note = p.note {
                        Text(note).font(.awan(11.5, .medium)).foregroundStyle(Theme.textSecondary)
                    } else if yearly {
                        Text("billed yearly ($\(p.yearlyPerMonth * 12))").font(.awan(11.5, .medium)).foregroundStyle(Theme.textSecondary)
                    } else {
                        Text(" ").font(.awan(11.5, .medium))
                    }
                }
                .frame(height: 16, alignment: .topLeading)
                .padding(.top, -1.5)
                Text(p.tagline).font(.awan(12.5)).foregroundStyle(Theme.textSecondary)
                    .linePitch(14, fontSize: 12.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 199, alignment: .leading)
                    .frame(height: 34, alignment: .topLeading)
                    .padding(.top, 14)
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.top, 13)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(p.features.enumerated()), id: \.offset) { _, f in feature(f.0, info: f.1) }
                }
                .padding(.top, 11)
                Spacer(minLength: 0)
            }
            .padding(.leading, 19).padding(.trailing, 17.5).padding(.top, 18.5)
            // Pin the content to the card's top-left even when a feature row is wider than the inner column.
            .frame(width: PlanChooserLayout.cardWidth, height: PlanChooserLayout.cardHeight, alignment: .topLeading)
            Button {
                pending = p.id
                model.choosePlan(p.id == "free" ? nil : p.id, yearly: yearly)
            } label: {
                Text(pending == p.id && p.id != "free" ? "Opening checkout\u{2026}" : p.cta)
            }
            .buttonStyle(TutorialGelStyle(enabled: true, size: CGSize(width: 200, height: 42), fontSize: 15, bone: p.id != "free"))
            .disabled(pending != nil)
            .offset(x: 17.5, y: PlanChooserLayout.cardHeight - 17.5 - 42)
        }
        .frame(width: PlanChooserLayout.cardWidth, height: PlanChooserLayout.cardHeight)
    }

    private func feature(_ text: String, info: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8.5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink, Theme.lime)
            // Lines are broken by hand where the reference wraps, and stacked at its 13.5 pt pitch.
            VStack(alignment: .leading, spacing: -2.5) {
                ForEach(Array(text.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    Text(String(line)).font(.awan(13, .medium)).foregroundStyle(Color(hex: 0xE4E1D8)).fixedSize()
                }
            }
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .help(info)
        }
        .frame(maxWidth: 205, alignment: .leading)
    }
}
