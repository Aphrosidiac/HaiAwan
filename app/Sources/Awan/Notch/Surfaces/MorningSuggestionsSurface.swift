import SwiftUI

/// Morning hello in the notch: the Awans with ideas float in a little constellation,
/// "Good morning, Fakhrul! I have 3 ideas for today." — Show me / Later.
struct MorningSuggestionsSurface: View {
    @EnvironmentObject var state: AppState

    private var awans: [CharacterAppearance] {
        var seen = Set<String>()
        let looks = state.suggestions.compactMap { s -> CharacterAppearance? in
            guard seen.insert(s.awanSlug).inserted else { return nil }
            return state.agents.agent(s.awanSlug)?.character
        }
        let filled = looks + [CharacterAppearance.mascot, CharacterCatalog.apply(CharacterCatalog.cloudPresets[1]), CharacterCatalog.apply(CharacterCatalog.cloudPresets[2])]
        return Array(filled.prefix(3))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Constellation(looks: awans)
                .frame(width: 128, height: 128)
            VStack(alignment: .leading, spacing: 8) {
                let lines = MorningSuggestions.greeting(name: state.user?.firstName, count: state.suggestions.count).components(separatedBy: "! ")
                VStack(alignment: .leading, spacing: 1) {
                    Text(lines[0] + (lines.count > 1 ? "!" : "")).font(.awan(16, .semibold)).foregroundStyle(Theme.text)
                    if lines.count > 1 { Text(lines[1]).font(.awan(16, .semibold)).foregroundStyle(Theme.text) }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                if let first = state.suggestions.first {
                    Text(first.title)
                        .font(.awan(12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Button("Later") { MorningSuggestions.shared.later() }
                        .buttonStyle(.gel(.dark, height: 30, padding: 14, fontSize: 12.5))
                    Button { MorningSuggestions.shared.showMe() } label: { Label("Show me", systemImage: "sparkles") }
                        .buttonStyle(.gel(.lime, height: 30, padding: 14, fontSize: 12.5))
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 44)
    }
}

/// Three avatars drifting around a soft glow.
private struct Constellation: View {
    let looks: [CharacterAppearance]
    private let spots: [(CGFloat, CGFloat, CGFloat)] = [(-30, -26, 50), (32, -8, 44), (-6, 34, 40)]  // x, y, size

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().fill(RadialGradient(colors: [Color.white.opacity(0.10), .clear], center: .center, startRadius: 4, endRadius: 64)).frame(width: 128)
                // faint lines joining the stars
                Path { p in
                    let pts = spots.enumerated().map { i, s in point(s, i, t) }
                    p.move(to: pts[0]); p.addLine(to: pts[1]); p.addLine(to: pts[2]); p.closeSubpath()
                }
                .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                ForEach(Array(looks.enumerated()), id: \.offset) { i, look in
                    let s = spots[i % 3]
                    let p = point(s, i, t)
                    AgentAvatar(appearance: look, size: s.2, mood: .happy)
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
                        .position(p)
                }
                ForEach(0..<5, id: \.self) { i in
                    let a = Double(i) * 1.26 + t * 0.2
                    Circle().fill(Theme.bone.opacity(0.35 + 0.3 * sin(t * 2 + Double(i))))
                        .frame(width: 2.5, height: 2.5)
                        .position(x: 64 + CGFloat(cos(a)) * 58, y: 64 + CGFloat(sin(a)) * 54)
                }
            }
            .frame(width: 128, height: 128)
        }
    }

    private func point(_ s: (CGFloat, CGFloat, CGFloat), _ i: Int, _ t: Double) -> CGPoint {
        let bob = CGFloat(sin(t * 1.3 + Double(i) * 2.1)) * 3
        let sway = CGFloat(cos(t * 0.9 + Double(i) * 1.7)) * 2
        return CGPoint(x: 64 + s.0 + sway, y: 64 + s.1 + bob)
    }
}
