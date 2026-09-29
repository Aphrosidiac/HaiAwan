import SwiftUI

/// Cat Mode: the cursor buddy becomes a small pixel cat (16×12 sprite, drawn procedurally — no atlas).
/// Ink outline, warm-grey coat with darker stripes, Signal Lime eyes, a collar in the buddy's colour.
/// Idle: blinks and swishes its tail. Following / flying: a four-frame walk. Landing on a point: sits
/// and says "meow".
enum CatPose: Equatable {
    case idle
    case walk
    case sit
}

enum PixelCat {
    static let width = 16
    static let height = 12

    // k ink · b coat · s stripe · e eye · n nose · c collar · . clear
    private static let head: [String] = [
        "..........k...k.",
        ".........kbk.kbk",
        ".........kbbbbbk",
        ".........kbebebk",
        "..........kbnbk.",
    ]

    /// Standing body rows 4…8 (head overlays the right side), facing right.
    private static let standBody: [String] = [
        "....kkkkkkkbbbbk",
        "...kbbbbbbbkbbk.",
        "...kbbsbbsbbccck",
        "...kbbsbbsbbbbk.",
        "....kkkkkkkkkk..",
    ]

    private static let sitRows: [String] = [
        "..........k...k.",
        ".........kbk.kbk",
        ".........kbbbbbk",
        ".........kbebebk",
        "........kkbbnbbk",
        ".......kbbkbbbk.",
        "......kbbbbccck.",
        "......kbsbbbbbk.",
        ".....kbbsbbbbbk.",
        ".....kbbbsbbbbk.",
        "..kkkkbbbbkbbbk.",
        "...kkkkkkkkkkkk.",
    ]

    /// x positions of the four legs (back pair, front pair) per walk frame, and the body bob.
    static let walkLegs: [[Int]] = [[4, 7, 10, 13], [5, 6, 11, 12], [4, 7, 10, 13], [6, 5, 12, 11]]
    static let walkBob: [Int] = [0, -1, 0, -1]

    /// A frame as 12 rows of 16 characters.
    static func frame(pose: CatPose, step: Int = 0, blink: Bool = false, tailUp: Bool = true) -> [String] {
        var rows: [[Character]]
        switch pose {
        case .sit:
            rows = sitRows.map(Array.init)
            if !tailUp {   // tail flick along the floor
                rows[10][2] = "."; rows[9][3] = "k"
            }
        case .idle, .walk:
            rows = Array(repeating: Array(repeating: ".", count: width), count: height)
            let bob = pose == .walk ? walkBob[step % 4] : 0
            func put(_ src: [String], at top: Int) {
                for (i, line) in src.enumerated() where top + i >= 0 && top + i < height {
                    for (x, ch) in line.enumerated() where ch != "." { rows[top + i][x] = ch }
                }
            }
            put(standBody, at: 5 + bob)
            put(head, at: 1 + bob)
            // Legs rows 10-11 (a foot on the last row).
            let legs = pose == .walk ? walkLegs[step % 4] : [4, 7, 10, 13]
            for x in legs {
                if bob < 0 { rows[9][x] = "k" }   // body lifted: the legs stretch to reach the floor
                rows[10][x] = "k"
                rows[11][min(width - 1, x)] = "k"
            }
            // Tail: up-curl or a lower swish (idle alternates, walking keeps it up).
            let tail: [(Int, Int)] = tailUp ? [(6 + bob, 3), (5 + bob, 2), (4 + bob, 2), (3 + bob, 1), (2 + bob, 1)]
                                            : [(6 + bob, 3), (6 + bob, 2), (5 + bob, 1), (5 + bob, 0), (4 + bob, 0)]
            for (y, x) in tail where y >= 0 && y < height { rows[y][x] = "k" }
        }
        if blink {
            for y in rows.indices { for x in rows[y].indices where rows[y][x] == "e" { rows[y][x] = "k" } }
        }
        return rows.map { String($0) }
    }

    static func color(_ ch: Character, collar: Color) -> Color? {
        switch ch {
        case "k": return Theme.ink
        case "b": return Color(hex: 0x5E5C55)
        case "s": return Color(hex: 0x3A3935)
        case "e": return Theme.lime
        case "n": return Color(hex: 0xE3A6A0)
        case "c": return collar
        default: return nil
        }
    }
}

/// One sprite frame drawn on a Canvas at `pixel` points per sprite pixel.
struct PixelCatSprite: View {
    var rows: [String]
    var collar: Color
    var pixel: CGFloat = 2.25
    var facingLeft = false

    var body: some View {
        Canvas { ctx, _ in
            for (y, line) in rows.enumerated() {
                for (x, ch) in line.enumerated() {
                    guard let c = PixelCat.color(ch, collar: collar) else { continue }
                    // A hair of overlap so no seams show between pixels at fractional scales.
                    let r = CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel + 0.35, height: pixel + 0.35)
                    ctx.fill(Path(r), with: .color(c))
                }
            }
        }
        .frame(width: CGFloat(PixelCat.width) * pixel, height: CGFloat(PixelCat.height) * pixel)
        .scaleEffect(x: facingLeft ? -1 : 1, y: 1)
    }
}

/// The live cat: picks the frame from the pose and the clock (blink every ~3.5 s, tail swish, 8 fps walk).
struct CatBuddy: View {
    var pose: CatPose
    var collar: Color
    var facingLeft: Bool
    var meow: Bool
    var animated = true
    /// Snapshot hook: a fixed frame instead of the clock.
    var fixedStep: Int? = nil
    var fixedBlink = false
    var fixedTailUp = true

    var body: some View {
        if animated && fixedStep == nil {
            TimelineView(.animation(minimumInterval: 1.0 / 12)) { ctx in content(ctx.date.timeIntervalSinceReferenceDate) }
        } else {
            content(nil)
        }
    }

    private func content(_ t: TimeInterval?) -> some View {
        let step = fixedStep ?? t.map { Int($0 * 8) % 4 } ?? 0
        let blink = t.map { $0.truncatingRemainder(dividingBy: 3.6) < 0.14 } ?? fixedBlink
        let tailUp = t.map { Int($0 / 0.9) % 2 == 0 } ?? fixedTailUp
        return ZStack(alignment: .topLeading) {
            PixelCatSprite(rows: PixelCat.frame(pose: pose, step: step, blink: pose == .walk ? false : blink, tailUp: pose == .walk ? true : tailUp),
                           collar: collar, facingLeft: facingLeft)
                .shadow(color: collar.opacity(0.55), radius: 5)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            if meow {
                CatMeowBubble()
                    .offset(x: facingLeft ? -26 : 22, y: -20)
                    .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .frame(width: CGFloat(PixelCat.width) * 2.25, height: CGFloat(PixelCat.height) * 2.25, alignment: .topLeading)
    }
}

struct CatMeowBubble: View {
    var body: some View {
        Text("meow")
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.bone))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.ink, lineWidth: 1.5))
            .fixedSize()
    }
}
