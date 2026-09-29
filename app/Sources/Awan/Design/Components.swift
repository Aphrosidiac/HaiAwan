import SwiftUI

// MARK: - Gel buttons (the reference's glossy "gel" pills, re-coloured to FF)

enum GelKind {
    case lime      // the one key action in a view
    case bone      // secondary gel (Cancel, No, Check for updates)
    case dark      // chip-like dark gel
    case danger
}

struct GelButtonStyle: ButtonStyle {
    var kind: GelKind = .lime
    var height: CGFloat = 36
    var horizontalPadding: CGFloat = 18
    var fullWidth = false
    var fontSize: CGFloat = 13.5

    func makeBody(configuration: Configuration) -> some View {
        GelBody(configuration: configuration, kind: kind, height: height, horizontalPadding: horizontalPadding, fullWidth: fullWidth, fontSize: fontSize)
    }

    private struct GelBody: View {
        let configuration: Configuration
        let kind: GelKind
        let height: CGFloat
        let horizontalPadding: CGFloat
        let fullWidth: Bool
        let fontSize: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Local private var hovering = false

        var body: some View {
            configuration.label
                .font(.awan(fontSize, .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(background)
                .overlay(
                    Capsule().strokeBorder(borderColor, lineWidth: 1)
                )
                .overlay(alignment: .top) {
                    // specular highlight across the top third — the "gel"
                    Capsule()
                        .fill(LinearGradient(colors: [.white.opacity(kind == .dark ? 0.10 : 0.55), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .frame(height: height * 0.46)
                        .padding(.horizontal, height * 0.18)
                        .padding(.top, 1.5)
                        .allowsHitTesting(false)
                }
                .shadow(color: shadowColor, radius: configuration.isPressed ? 2 : 6, y: configuration.isPressed ? 1 : 3)
                .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.015 : 1))
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Theme.snappy, value: configuration.isPressed)
                .animation(Theme.snappy, value: hovering)
                .onHover { hovering = $0 }
                .contentShape(Capsule())
        }

        private var background: some View {
            Capsule().fill(fill)
        }

        private var fill: LinearGradient {
            switch kind {
            case .lime:
                return LinearGradient(colors: [Color(hex: 0xEAFF8C), Theme.lime, Theme.limeDeep], startPoint: .top, endPoint: .bottom)
            case .bone:
                return LinearGradient(colors: [Color.white, Theme.bone, Color(hex: 0xD9D4C6)], startPoint: .top, endPoint: .bottom)
            case .dark:
                return LinearGradient(colors: [Color(hex: 0x3A3A36), Color(hex: 0x2A2A27)], startPoint: .top, endPoint: .bottom)
            case .danger:
                return LinearGradient(colors: [Color(hex: 0xFF8A7E), Theme.danger], startPoint: .top, endPoint: .bottom)
            }
        }

        private var foreground: Color {
            switch kind {
            case .lime, .bone: return Theme.ink
            case .dark: return Theme.text
            case .danger: return .white
            }
        }

        private var borderColor: Color {
            switch kind {
            case .lime: return Color(hex: 0x8FB000).opacity(0.55)
            case .bone: return Color.black.opacity(0.18)
            case .dark: return Color.white.opacity(0.10)
            case .danger: return Color.black.opacity(0.2)
            }
        }

        private var shadowColor: Color {
            switch kind {
            case .lime: return Theme.lime.opacity(0.28)
            case .bone: return Color.black.opacity(0.35)
            case .dark, .danger: return Color.black.opacity(0.35)
            }
        }
    }
}

extension ButtonStyle where Self == GelButtonStyle {
    static var gel: GelButtonStyle { GelButtonStyle() }
    static func gel(_ kind: GelKind, height: CGFloat = 36, padding: CGFloat = 18, fullWidth: Bool = false, fontSize: CGFloat = 13.5) -> GelButtonStyle {
        GelButtonStyle(kind: kind, height: height, horizontalPadding: padding, fullWidth: fullWidth, fontSize: fontSize)
    }
}

// MARK: - Circle icon button (close ×, info ⓘ, gear)

struct CircleIconButton: View {
    let systemName: String
    var size: CGFloat = 26
    var filled = false
    var help: String? = nil
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(hovering ? Theme.text : Theme.textSecondary)
                .frame(width: size, height: size)
                .background(Circle().fill(filled || hovering ? Theme.cardRaised : Color.clear))
                .overlay(Circle().strokeBorder(filled ? Theme.strokeStrong : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

// MARK: - Chips

struct ChipButton: View {
    let title: String
    var systemImage: String? = nil
    var trailingImage: String? = nil
    let action: () -> Void
    @Local private var hovering = false

    /// Measured on the reference's peek footer: capsule 32 tall, fill #2A2A29, 13 semibold secondary text,
    /// 11 pt icons 11 pt in from the edge, 6 pt gaps, no rim.
    var body: some View {
        let fg = hovering ? Theme.text : Theme.textSecondary
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)).foregroundStyle(fg) }
                Text(title).font(.awan(13, .semibold)).lineLimit(1).foregroundStyle(fg)
                if let trailingImage { Image(systemName: trailingImage).font(.system(size: 9, weight: .bold)).foregroundStyle(fg).padding(.leading, 1) }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Capsule().fill(hovering ? Color(hex: 0x333331) : Color(hex: 0x2A2A29)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hovering = h } }
    }
}

// MARK: - Toggle (gel track, ink knob — like the reference's switch)

struct GelToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            GelSwitch(isOn: configuration.isOn) { configuration.isOn.toggle() }
        }
    }
}

/// The reference's switch, measured: 46×24 track with a 0.5 pt dark rim, 20 pt knob inset 2.
/// On = lime gel with an ink knob; off = graphite with a bone knob.
struct GelSwitch: View {
    let isOn: Bool
    let toggle: () -> Void
    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn
                      ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xF0FFB0), Theme.lime, Color(hex: 0xC8EE2C)], startPoint: .top, endPoint: .bottom))
                      : AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x3A3A37), Color(hex: 0x444440)], startPoint: .top, endPoint: .bottom)))
                .overlay(alignment: .top) {
                    Capsule().fill(Color.white.opacity(isOn ? 0.45 : 0.06)).frame(height: 7).padding(.horizontal, 6).padding(.top, 2.5)
                }
                .overlay(Capsule().strokeBorder(isOn ? Color(hex: 0x6F8A00).opacity(0.9) : Color.black.opacity(0.35), lineWidth: 0.75))
            Circle()
                .fill(isOn ? Theme.ink : Color(hex: 0xD9D5CB))
                .frame(width: 20, height: 20)
                .padding(2)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
        }
        .frame(width: 46, height: 24)
        .animation(Theme.snappy, value: isOn)
        .contentShape(Capsule())
        .onTapGesture(perform: toggle)
    }
}

// MARK: - Settings building blocks

/// Page title + subtitle at the top of every Settings page (reference: title cap 14 pt, subtitle cap 9.7 pt).
struct SettingsPageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3.2) {
            Text(title).font(SettingsStyle.pageTitle).foregroundStyle(SettingsStyle.title)
            Text(subtitle).font(SettingsStyle.pageSubtitle).foregroundStyle(SettingsStyle.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Section label + card (+ footer). `plain` drops the card chrome for content that brings its own
/// tiles (voice grid, cursor colours).
struct SettingsGroup<Content: View>: View {
    var label: String? = nil
    var footer: String? = nil
    var plain = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label { SettingsSectionLabel(label).padding(.leading, 5).padding(.bottom, SettingsStyle.labelGap) }
            if plain {
                content
            } else {
                VStack(spacing: 0) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous).fill(SettingsStyle.card))
                    .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous).strokeBorder(SettingsStyle.stroke, lineWidth: 1))
            }
            if let footer {
                Text(footer).font(.awan(11.75)).foregroundStyle(SettingsStyle.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4.5).padding(.top, 6)
            }
        }
    }
}

/// Title (14.5 medium) + optional dim subtitle, trailing accessory, hairline divider inset to the text.
/// Reference rows: 55 pt with a one-line subtitle, 38 pt title-only, +14 pt per extra subtitle line.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var titleColor: Color = Theme.text
    var showDivider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1.4) {
                Text(title).font(SettingsStyle.rowTitle).foregroundStyle(titleColor)
                if let subtitle {
                    Text(subtitle).font(SettingsStyle.rowSubtitle).foregroundStyle(SettingsStyle.dim)
                        .lineSpacing(-0.6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Reference wraps subtitles at ~515 pt whatever the accessory is.
            .frame(maxWidth: 515, alignment: .leading)
            Spacer(minLength: 12)
            trailing.fixedSize()
        }
        .padding(.leading, SettingsStyle.rowLeading)
        .padding(.trailing, SettingsStyle.rowTrailing)
        .padding(.top, 10.5)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if showDivider { Rectangle().fill(SettingsStyle.stroke).frame(height: 1).padding(.leading, SettingsStyle.rowLeading + 0.5) }
        }
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, titleColor: Color = Theme.text, showDivider: Bool = true) {
        self.init(title: title, subtitle: subtitle, titleColor: titleColor, showDivider: showDivider) { EmptyView() }
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var showDivider = true
    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, showDivider: showDivider) {
            GelSwitch(isOn: isOn) { isOn.toggle() }
        }
    }
}

// MARK: - Search field

struct AwanSearchField: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 32
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.awan(13.5))
                .foregroundStyle(Theme.text)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.055)))
    }
}

// MARK: - Keycap (shortcut display)

struct Keycap: View {
    let label: String
    var height: CGFloat = 22
    var fontSize: CGFloat = 11
    var radius: CGFloat = 6
    var body: some View {
        let compact = height < 20   // the peek's shortcuts card: 17 tall, hairline rim
        Text(label)
            .font(.awanMono(fontSize, .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, compact ? 3.5 : 7)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius).fill(Color.white.opacity(compact ? 0.075 : 0.09)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white.opacity(compact ? 0.14 : 0.08), lineWidth: compact ? 0.5 : 1))
    }
}

// MARK: - Brand mark (//FF as artwork, never typed)

struct FFMark: View {
    var color: Color = Theme.bone
    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 194, sy = size.height / 72
            func p(_ pts: [(CGFloat, CGFloat)]) -> Path {
                var path = Path()
                path.move(to: CGPoint(x: pts[0].0 * sx, y: pts[0].1 * sy))
                for pt in pts.dropFirst() { path.addLine(to: CGPoint(x: pt.0 * sx, y: pt.1 * sy)) }
                path.closeSubpath()
                return path
            }
            let shapes: [[(CGFloat, CGFloat)]] = [
                [(0, 72), (16, 0), (30, 0), (14, 72)],
                [(24, 72), (40, 0), (54, 0), (38, 72)],
                [(72, 0), (126, 0), (126, 15), (88, 15), (88, 28), (120, 28), (120, 42), (88, 42), (88, 72), (72, 72)],
                [(140, 0), (194, 0), (194, 15), (156, 15), (156, 28), (188, 28), (188, 42), (156, 42), (156, 72), (140, 72)],
            ]
            for s in shapes { ctx.fill(p(s), with: .color(color)) }
        }
        .aspectRatio(194.0 / 72.0, contentMode: .fit)
    }
}

/// The product logo in the top-left of Home: a small cloud glyph (Awan's own mark).
struct AwanGlyph: View {
    var color: Color = Theme.bone
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var cloud = Path()
            cloud.addEllipse(in: CGRect(x: w * 0.06, y: h * 0.38, width: w * 0.40, height: h * 0.42))
            cloud.addEllipse(in: CGRect(x: w * 0.26, y: h * 0.16, width: w * 0.48, height: h * 0.54))
            cloud.addEllipse(in: CGRect(x: w * 0.54, y: h * 0.34, width: w * 0.40, height: h * 0.44))
            cloud.addRoundedRect(in: CGRect(x: w * 0.14, y: h * 0.52, width: w * 0.72, height: h * 0.30), cornerSize: CGSize(width: h * 0.15, height: h * 0.15))
            ctx.fill(cloud, with: .color(color))
            // two ^ ^ eyes
            for cx in [w * 0.40, w * 0.60] {
                var eye = Path()
                eye.move(to: CGPoint(x: cx - w * 0.06, y: h * 0.56))
                eye.addLine(to: CGPoint(x: cx, y: h * 0.49))
                eye.addLine(to: CGPoint(x: cx + w * 0.06, y: h * 0.56))
                ctx.stroke(eye, with: .color(Theme.ink), style: StrokeStyle(lineWidth: max(1.4, w * 0.055), lineCap: .round, lineJoin: .round))
            }
        }
        .aspectRatio(1.2, contentMode: .fit)
    }
}
