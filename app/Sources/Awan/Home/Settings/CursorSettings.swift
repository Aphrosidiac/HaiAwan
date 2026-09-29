import SwiftUI

/// Settings → Cursor: buddy colour + docking.
struct CursorSettings: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        SettingsPageHeader(title: "Cursor", subtitle: "The little Awan cursor that lives on your screen.")

        // Reference: four 120 pt square tiles, 13 pt apart, no card, no captions.
        SettingsGroup(label: "Color", plain: true) {
            HStack(spacing: 13) {
                ForEach(CursorColor.allCases) { c in tile(c) }
            }
            .padding(.top, 3)
        }

        SettingsGroup(label: "Visibility") {
            SettingToggle(title: "Dock cursor", subtitle: "Docking hides the cursor and stops it from following you.", isOn: $prefs.cursorDocked, showDivider: false)
        }
        .onChange(of: prefs.cursorDocked) { _, _ in CursorOverlayController.shared.refreshAppearance() }
        .onChange(of: prefs.cursorColor) { _, _ in CursorOverlayController.shared.refreshAppearance() }
    }

    private func tile(_ c: CursorColor) -> some View {
        let on = prefs.cursorColor == c
        return Button { withAnimation(Theme.snappy) { prefs.cursorColor = c } } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(on ? Color(hex: 0x323230) : Color(hex: 0x272726))
                CursorSwatchTriangle()
                    .fill(c.color)
                    .frame(width: 24, height: 26)
                    .rotationEffect(.degrees(-6))
                    .shadow(color: c.color.opacity(0.55), radius: 9)
                    .offset(x: 1.5)
            }
            .frame(width: 120, height: 120)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            .overlay {
                if on { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.lime, lineWidth: 2) }
            }
            .overlay(alignment: .topTrailing) {
                if on { SettingsCheckBadge().padding(.top, 9).padding(.trailing, 9.5) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .help(c.label)
    }
}

/// The buddy's pointer as the reference draws it in the picker: an equilateral triangle, apex right,
/// with softly rounded corners.
struct CursorSwatchTriangle: Shape {
    func path(in r: CGRect) -> Path {
        let a = CGPoint(x: r.maxX, y: r.midY), b = CGPoint(x: r.minX, y: r.maxY), c = CGPoint(x: r.minX, y: r.minY)
        var p = Path()
        let k: CGFloat = 3
        func toward(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
            let dx = to.x - from.x, dy = to.y - from.y, d = max(0.001, (dx * dx + dy * dy).squareRoot())
            return CGPoint(x: from.x + dx / d * k, y: from.y + dy / d * k)
        }
        p.move(to: toward(a, b))
        p.addLine(to: toward(b, a)); p.addQuadCurve(to: toward(b, c), control: b)
        p.addLine(to: toward(c, b)); p.addQuadCurve(to: toward(c, a), control: c)
        p.addLine(to: toward(a, c)); p.addQuadCurve(to: toward(a, b), control: a)
        p.closeSubpath()
        return p
    }
}
