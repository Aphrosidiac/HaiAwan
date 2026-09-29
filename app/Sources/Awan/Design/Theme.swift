import SwiftUI
import AppKit
import CoreText

/// FF Dev Studio tokens applied to the reference's layout.
/// Ink / Graphite surfaces, Bone text, Field Grey metadata, Signal Lime only for the
/// one key action per view (push-to-talk, Upgrade, "Yes, do it", Save) and active state.
enum Theme {
    // MARK: Brand palette
    static let ink = Color(hex: 0x0B0B0A)
    static let graphite = Color(hex: 0x242421)
    static let bone = Color(hex: 0xF3EFE4)
    static let fieldGrey = Color(hex: 0x8B8981)
    static let hairline = Color(hex: 0xD7D2C6)
    static let softField = Color(hex: 0xE9E5DB)
    static let lime = Color(hex: 0xD9FF43)
    static let limeDeep = Color(hex: 0xB9E01F)

    // MARK: Surfaces (dark UI, measured against the reference's panel greys)
    static let window = Color(hex: 0x141413)          // Home content background
    static let sidebar = Color(hex: 0x1B1B19)         // Home sidebar
    static let panel = Color(hex: 0x1C1C1B)           // notch peek body (measured #1C1C1B) / cards on black
    static let card = Color(hex: 0x2A2A27)            // settings group, suggestion card
    static let cardRaised = Color(hex: 0x33332F)      // hover / chips
    static let stroke = Color.white.opacity(0.07)
    static let strokeStrong = Color.white.opacity(0.12)
    static let agentBubble = Color(hex: 0x33332F)
    static let userBubbleTop = Color(hex: 0xF7F4EB)
    static let userBubbleBottom = Color(hex: 0xE6E0D0)

    // MARK: Text
    static let text = bone
    static let textSecondary = Color(hex: 0xA9A69C)
    static let textTertiary = fieldGrey
    static let textOnLime = ink
    static let danger = Color(hex: 0xFF6B5E)
    static let success = Color(hex: 0x7BD88F)
    static let warning = Color(hex: 0xF5C451)

    // MARK: Radii & spacing (measured on the reference, in points)
    enum Radius {
        static let window: CGFloat = 22
        static let card: CGFloat = 14
        static let bubble: CGFloat = 17
        static let pill: CGFloat = 999
        static let row: CGFloat = 12
        static let tile: CGFloat = 16
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Motion
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
    static let snappy = Animation.spring(response: 0.26, dampingFraction: 0.86)
    static let gentle = Animation.easeInOut(duration: 0.22)
}

// MARK: - Typography (Instrument Sans, registered at launch)

enum AwanFont {
    static let family = "Instrument Sans"
    static let serif = "Instrument Serif"

    static func registerBundled() {
        let names = ["InstrumentSans-Variable", "InstrumentSans-Italic-Variable", "InstrumentSerif-Regular", "InstrumentSerif-Italic"]
        for name in names {
            let candidates = [
                Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts"),
                Bundle.main.url(forResource: name, withExtension: "ttf"),
            ]
            if let url = candidates.compactMap({ $0 }).first {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    static var isAvailable: Bool { NSFont(name: "InstrumentSans-Regular", size: 12) != nil || NSFontManager.shared.availableMembers(ofFontFamily: family) != nil }
}

extension Font {
    /// Brand sans at a size and weight; falls back to the system font if registration failed.
    static func awan(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        AwanFont.isAvailable ? .custom(AwanFont.family, size: size).weight(weight) : .system(size: size, weight: weight)
    }

    static func awanSerif(_ size: CGFloat) -> Font {
        .custom(AwanFont.serif, size: size)
    }

    static func awanMono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // Named scale (reference: 20/15/13/12/11 pt)
    static let awanTitle = Font.awan(20, .semibold)
    static let awanHeadline = Font.awan(15, .semibold)
    static let awanBody = Font.awan(13.5)
    static let awanBodyMedium = Font.awan(13.5, .medium)
    static let awanCaption = Font.awan(12)
    static let awanMicro = Font.awan(11, .semibold)
}

// MARK: - Helpers

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// A colour from a hue in 0…1 with the soft pastel treatment the character palettes use.
    static func pastel(hue: Double, saturation: Double = 0.42, brightness: Double = 0.96) -> Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Section header in caps, like "BEHAVIOR", "ROUTINES", "NEXT STEPS".
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.awan(10.5, .semibold))
            .tracking(0.9)
            .foregroundStyle(Theme.textTertiary)
    }
}
