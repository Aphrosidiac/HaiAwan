import AppKit
import SwiftUI

/// Snapshots for the companion extras: Cat Mode frames and the [IMAGES] answer card.
extension Snapshots {
    static var companionExtraNames: [String] { ["companion-catmode", "companion-images-card"] }

    static func companionExtra(_ name: String) -> AnyView? {
        switch name {
        case "companion-catmode": return AnyView(CatModeSnapshot())
        case "companion-images-card": return AnyView(ImagesCardSnapshot())
        default: return nil
        }
    }
}

private struct CatModeSnapshot: View {
    private let lime = CursorColor.lime.color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("Cat Mode").font(.awan(15, .semibold)).foregroundStyle(Theme.text)
                Text("16×12 procedural sprite · ink outline · Signal Lime eyes · collar in the cursor colour").font(.awan(12)).foregroundStyle(Theme.textTertiary)
            }
            // The frames, big.
            HStack(alignment: .top, spacing: 10) {
                frame("idle", PixelCat.frame(pose: .idle))
                frame("blink", PixelCat.frame(pose: .idle, blink: true))
                frame("tail swish", PixelCat.frame(pose: .idle, tailUp: false))
                ForEach(0..<4, id: \.self) { i in frame("walk \(i + 1)", PixelCat.frame(pose: .walk, step: i)) }
                frame("sit", PixelCat.frame(pose: .sit))
            }
            // Live size, in context.
            HStack(alignment: .top, spacing: 12) {
                cell("following", dark: false) { CatBuddy(pose: .idle, collar: lime, facingLeft: false, meow: false, animated: false, fixedStep: 0) }
                cell("walking left", dark: true) { CatBuddy(pose: .walk, collar: lime, facingLeft: true, meow: false, animated: false, fixedStep: 1) }
                cell("landed · meow", dark: false) { CatBuddy(pose: .sit, collar: lime, facingLeft: false, meow: true, animated: false, fixedStep: 0) }
                cell("listening", dark: true) {
                    BuddyGlyph(state: .listening, color: lime, audioLevel: 0.25, animated: false, cat: .init(pose: .idle, facingLeft: false, meow: false))
                }
                cell("thinking", dark: false) {
                    BuddyGlyph(state: .processing, color: lime, audioLevel: 0, animated: false, cat: .init(pose: .idle, facingLeft: false, meow: false))
                }
                cell("sky cursor · blink", dark: true) { CatBuddy(pose: .idle, collar: CursorColor.sky.color, facingLeft: false, meow: false, animated: false, fixedStep: 0, fixedBlink: true) }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.window)
    }

    private func frame(_ title: String, _ rows: [String]) -> some View {
        VStack(spacing: 6) {
            PixelCatSprite(rows: rows, collar: lime, pixel: 5.5)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bone))
            Text(title).font(.awan(11, .semibold)).foregroundStyle(Theme.textSecondary)
        }
    }

    private func cell<C: View>(_ title: String, dark: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                Image(systemName: "cursorarrow").font(.system(size: 20)).foregroundStyle(dark ? .white : .black).offset(x: 34, y: 30)
                content().offset(x: 56, y: 56)
            }
            .frame(width: 150, height: 120, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dark ? Theme.graphite : Theme.bone))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(title).font(.awan(12, .semibold)).foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct ImagesCardSnapshot: View {
    @StateObject private var model: ImageAnswerModel = {
        let m = ImageAnswerModel()
        m.query = "quokka on rottnest island"
        let specs: [(String, String, [UInt32])] = [
            ("Quokka smiling at the camera", "wikipedia.org", [0x8C6B4A, 0xD9C2A0]),
            ("Rottnest Island beach", "rottnestisland.com", [0x2E7FA8, 0xE9DDB8]),
            ("Mother with joey", "commons.wikimedia.org", [0x5B4A36, 0xA78F6C]),
            ("Quokka eating leaves", "australiangeographic.com.au", [0x3F6B35, 0xB8C98A]),
            ("Close-up portrait", "nationalgeographic.com", [0x6E5A48, 0xE3CFB2]),
        ]
        m.items = specs.map { t, host, c in
            ImageAnswer(title: t, imageURL: URL(string: "https://\(host)/image.jpg")!, pageURL: URL(string: "https://www.\(host)/page"),
                        thumbnailURL: nil, image: DemoPhoto.make(colors: c))
        }
        return m
    }()

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: 0x3B2A6B), Color(hex: 0x8E7BD0)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 10) {
                // The notch it hangs under.
                UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(.black).frame(width: 200, height: 32)
                ImageAnswerCardView(model: model)
                    .frame(width: ImageAnswerCard.size.width, height: ImageAnswerCard.size.height)
            }
        }
    }
}

/// A soft landscape-ish placeholder photo for snapshots (no network in snapshot mode).
private enum DemoPhoto {
    static func make(colors: [UInt32]) -> NSImage {
        let size = NSSize(width: 256, height: 192)
        return NSImage(size: size, flipped: false) { rect in
            let c = colors.map { NSColor(red: CGFloat(($0 >> 16) & 0xFF) / 255, green: CGFloat(($0 >> 8) & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1) }
            NSGradient(starting: c[1], ending: c[0])?.draw(in: rect, angle: -90)
            c[0].blended(withFraction: 0.35, of: .black)?.setFill()
            NSBezierPath(ovalIn: NSRect(x: 70, y: 30, width: 120, height: 110)).fill()
            c[1].blended(withFraction: 0.5, of: .white)?.setFill()
            NSBezierPath(ovalIn: NSRect(x: 180, y: 130, width: 40, height: 40)).fill()
            return true
        }
    }
}
