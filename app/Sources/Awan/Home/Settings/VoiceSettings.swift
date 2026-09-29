import SwiftUI

/// Settings → Voice: speech speed + the 10 voices (tap to select and hear it).
struct VoiceSettings: View {
    @ObservedObject private var prefs = Prefs.shared
    @Local private var hovered: String? = nil

    struct Voice: Identifiable {
        let id: String
        let name: String
        let trait: String
        let symbol: String
        let tint: UInt32
    }

    static let voices: [Voice] = [
        .init(id: "cedar", name: "Cedar", trait: "Warm default", symbol: "leaf.fill", tint: 0x6BB884),
        .init(id: "marin", name: "Marin", trait: "Bright & natural", symbol: "drop.fill", tint: 0x5CA8FF),
        .init(id: "alloy", name: "Alloy", trait: "Balanced", symbol: "circle.lefthalf.filled", tint: 0xA9ABB5),
        .init(id: "ash", name: "Ash", trait: "Calm & even", symbol: "wind", tint: 0x9AA3B5),
        .init(id: "ballad", name: "Ballad", trait: "Expressive", symbol: "music.note", tint: 0xC77DFF),
        .init(id: "coral", name: "Coral", trait: "Friendly", symbol: "sun.max.fill", tint: 0xFF6B7A),
        .init(id: "echo", name: "Echo", trait: "Crisp", symbol: "waveform", tint: 0x66B3DC),
        .init(id: "sage", name: "Sage", trait: "Measured", symbol: "book.closed.fill", tint: 0x5FBF7F),
        .init(id: "shimmer", name: "Shimmer", trait: "Light & airy", symbol: "sparkles", tint: 0xF5C451),
        .init(id: "verse", name: "Verse", trait: "Lively", symbol: "bolt.fill", tint: 0xFF9F43),
    ]

    static let speeds: [(Double, String)] = [(0.5, "0.5x"), (0.75, "0.75x"), (1.0, "1x"), (1.25, "1.25x"), (1.5, "1.5x")]

    var body: some View {
        SettingsPageHeader(title: "Voice", subtitle: "The voice Awan answers in, and how fast it talks.")

        SettingsGroup(label: "Speech speed", footer: "Takes effect on the next spoken reply.") {
            HStack(spacing: 6) {
                ForEach(Self.speeds, id: \.0) { value, label in speedPill(value, label) }
            }
            .padding(.horizontal, 13.5)
            .padding(.vertical, 14)
            .fixedSize()
        }
        .fixedSize(horizontal: true, vertical: false)

        SettingsGroup(label: "Voice", footer: "Tap a voice to hear it. Your pick is used for every spoken reply from now on.", plain: true) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 13), count: 5), spacing: 12) {
                ForEach(Self.voices) { v in voiceCard(v) }
            }
            .padding(.top, 3.5)
            .padding(.bottom, 6.6)
        }
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { Self.speeds.map(\.0).min(by: { abs($0 - prefs.speechSpeed) < abs($1 - prefs.speechSpeed) }) ?? 1 },
            set: { prefs.speechSpeed = $0 }
        )
    }

    /// Reference: separate 26 pt capsules (white 6 % on the card), 13.5 pt side padding, 6 pt apart;
    /// the selected one is the gel (lime).
    private func speedPill(_ value: Double, _ label: String) -> some View {
        let on = speedBinding.wrappedValue == value
        return Button { withAnimation(Theme.snappy) { speedBinding.wrappedValue = value } } label: {
            Text(label)
                .font(.awan(14, .semibold))
                .foregroundStyle(on ? Theme.ink : SettingsStyle.navText)
                .padding(.horizontal, on ? 12 : 13.5)
                .frame(height: 26)
                .background {
                    if on {
                        Capsule().fill(LinearGradient(colors: [Color(hex: 0xF0FFB0), Theme.lime, Color(hex: 0xC8EE2C)], startPoint: .top, endPoint: .bottom))
                            .overlay(Capsule().strokeBorder(Color(hex: 0x6F8A00).opacity(0.9), lineWidth: 1))
                            .padding(.vertical, -1)
                    } else {
                        Capsule().fill(Color.white.opacity(0.06))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Reference tile: 113×114, radius 16, glyph centred at +32, name cap at +56, trait at +74,
    /// selected = 2 pt ring + check badge (lime here, blue there).
    private func voiceCard(_ v: Voice) -> some View {
        let on = prefs.voiceID == v.id
        let hover = hovered == v.id
        return Button {
            prefs.voiceID = v.id
            CompanionEngine.shared.announce("Hi, I'm Awan. This is how I sound.")
        } label: {
            VStack(spacing: 0) {
                Image(systemName: v.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color(hex: v.tint))
                    .frame(height: 31)
                    .padding(.top, 16.5)
                Text(v.name).font(.awan(14.5, .semibold)).foregroundStyle(Theme.text)
                    .padding(.top, 5)
                Text(v.trait).font(.awan(12.5)).foregroundStyle(SettingsStyle.dim).lineLimit(1).minimumScaleFactor(0.85)
                    .padding(.top, 2.5)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 114)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(on ? Color(hex: 0x323230) : (hover ? Color(hex: 0x2D2D2B) : SettingsStyle.card)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            .overlay {
                if on { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.lime, lineWidth: 2) }
            }
            .overlay(alignment: .topTrailing) {
                if on { SettingsCheckBadge().padding(.top, 7.5).padding(.trailing, 8) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? v.id : (hovered == v.id ? nil : hovered) }
        .help("Select and preview \(v.name)")
        .animation(Theme.snappy, value: on)
    }
}

/// The reference's round check badge on a selected tile (voice, cursor colour): 20 pt gel, ink tick.
struct SettingsCheckBadge: View {
    var size: CGFloat = 20
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hex: 0xF0FFB0), Theme.lime], startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(Theme.ink.opacity(0.85), lineWidth: 1.2)
            Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(Theme.ink)
        }
        .frame(width: size, height: size)
    }
}
