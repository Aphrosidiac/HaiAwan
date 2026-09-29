import SwiftUI
import AppKit

// Small pieces shared by the Home pages (thread, suggestions, new Awan, inspector).

/// Home surface colours, measured on the reference and mapped to FF:
/// neutral greys become the warm Graphite family, the reference blue becomes Lime (primary) or Bone gel.
enum HomeColor {
    static let body = Color(hex: 0x1C1C1B)          // sidebar + panel body (ref #1C1C1B)
    static let content = Color(hex: 0x1E1E1D)       // page column (ref #1E1E1E)
    static let field = Color(hex: 0x222221)         // search field, + button (ref #222221)
    static let chip = Color(hex: 0x2A2A29)          // footer chips, name capsule (ref #292928/#292929)
    static let divider = Color(hex: 0x3B3B3A)       // row dividers, inspector hairline, card stroke (ref #3B3B3B)
    static let footerDivider = Color(hex: 0x313130) // above the profile row (ref #313131)
    static let title = Theme.bone                   // ref #F4F4F4
    static let secondary = Color(hex: 0xA4A29B)     // times, subtitles, hints (ref #A4A4A4)
    static let tertiary = Color(hex: 0x9A9892)      // "Release to send", ROUTINES, card copy (ref #999999/#9A9A9A)
    static let icon = Color(hex: 0xDCDAD3)          // ⓘ, gear, inspector ✕ (ref #DCDCDC)
    static let windowIcon = Color(hex: 0x7A7975)    // pop-out / close in the page header (ref #78787A)
    static let bubble = Color(hex: 0x3B3B38)        // agent bubbles (ref #3B3B3D)
    static let card = Color(hex: 0x232322)          // inspector routines card (ref #232323)
    static let outline = Color(hex: 0x505050)       // "Type…" capsule stroke (ref #505050)
    static let chipStroke = Color(hex: 0x4B4B49)    // next-action chip stroke (ref #4B4B4B)
    static let chipFill = Color(hex: 0x2C2C2B)      // next-action chip fill
    static let rowHover = Color(hex: 0x282827)      // sidebar row hover (ref #282827)
    static let hint = Color(hex: 0x92918B)          // Home hint line (ref #9093A0, warmed)
    static let placeholder = Color(hex: 0x9B9A95)   // search placeholder (ref #9B9B9B)
}

/// Home geometry for the attached panel (875×557) and the pop-out window (1197×809), measured from
/// the reference AX frames. Everything is in points, relative to the panel / window content.
struct HomeLayout {
    let detached: Bool

    var sidebarWidth: CGFloat { detached ? 327 : 255 }
    /// Sidebar content inset (glyph, avatars, chips, profile).
    var sidebarInset: CGFloat { 26 }
    /// Glyph / Upgrade / window-button row: top of the 30–31 pt buttons.
    var headerTop: CGFloat { detached ? 33 : 26 }
    /// Search row top (collapse / field / +).
    var searchTop: CGFloat { detached ? 93 : 79 }
    var rowHeight: CGFloat { detached ? 62 : 56 }
    var rowSpacing: CGFloat { 1 }
    var avatar: CGFloat { detached ? 46 : 40 }
    /// First roster row top.
    var listTop: CGFloat { detached ? 133 : 119 }
    /// Title top inside a row, from the row's top edge.
    var titleTop: CGFloat { detached ? 12 : 9 }
    /// Empty-state scale (the pop-out draws the mascot and greeting larger).
    var heroScale: CGFloat { detached ? 1.16 : 1 }
}

extension EnvironmentValues {
    var homeLayout: HomeLayout { HomeLayout(detached: homeIsDetached) }
}

/// Character editor open/close (reference ≈270 ms): the sheet cross-fades while the inspector portrait flies
/// into the editor's big preview (and back on close). Done with an explicit flying copy rather than
/// matchedGeometryEffect, which swallowed the sheet's removal animation.
@MainActor
final class CharacterHero: ObservableObject {
    static let shared = CharacterHero()
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.9)

    /// Frames in the Home root's coordinate space ("homeRoot").
    @Published var portraitFrame: CGRect = .zero
    @Published var previewFrame: CGRect = .zero
    /// The flying copy: nil when idle.
    @Published private(set) var flight: Flight?
    struct Flight: Equatable { var slug: String; var appearance: CharacterAppearance; var atPreview: Bool }

    static func open(_ slug: String) { shared.open(slug) }
    static func close() { shared.close() }

    private func open(_ slug: String) {
        let appearance = AppState.shared.agents.agent(slug)?.character
        withAnimation(Self.spring) { AppState.shared.characterEditorSlug = slug }
        guard let appearance, portraitFrame != .zero else { return }
        flight = Flight(slug: slug, appearance: appearance, atPreview: false)
        // Next frame: the sheet has laid out and reported where its preview sits.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            withAnimation(Self.spring) { self.flight?.atPreview = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { if self.flight?.atPreview == true { self.flight = nil } }
        }
    }

    private func close() {
        let slug = AppState.shared.characterEditorSlug
        let appearance = slug.flatMap { AppState.shared.agents.agent($0)?.character }
        if let slug, let appearance, previewFrame != .zero, portraitFrame != .zero {
            flight = Flight(slug: slug, appearance: appearance, atPreview: true)
        }
        withAnimation(Self.spring) {
            AppState.shared.characterEditorSlug = nil
            flight?.atPreview = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { if self.flight?.atPreview == false { self.flight = nil } }
    }

    /// True while the copy is in the air for this slug (the real portrait/preview hide meanwhile).
    func flying(_ slug: String) -> Bool { flight?.slug == slug }
}

/// Reports a view's frame in the Home root's space to the hero.
struct HeroFrameReporter: ViewModifier {
    let keyPath: ReferenceWritableKeyPath<CharacterHero, CGRect>
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            Color.clear
                .onAppear { CharacterHero.shared[keyPath: keyPath] = g.frame(in: .named("homeRoot")) }
                .onChange(of: g.frame(in: .named("homeRoot"))) { _, f in CharacterHero.shared[keyPath: keyPath] = f }
        })
    }
}

/// The flying copy, drawn above everything in the Home root.
struct CharacterHeroLayer: View {
    @ObservedObject private var hero = CharacterHero.shared
    var body: some View {
        if let f = hero.flight {
            let r = f.atPreview ? hero.previewFrame : hero.portraitFrame
            CharacterFigure(appearance: f.appearance, mood: .idle, showPaws: !f.appearance.pack.isFigure, expression: .happy)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
                .transition(.identity)
        }
    }
}


enum HomeUI {
    /// Snapshot runs must never touch the network or the user's files.
    static let isSnapshot = CommandLine.arguments.contains("--snapshot")

    /// "Control + Option" from the user's talk shortcut.
    @MainActor static var talkKeys: String {
        let keys = Prefs.shared.shortcuts.talk.displayKeys.map { $0.components(separatedBy: " ").last?.capitalized ?? $0 }
        return keys.isEmpty ? "Control + Option" : keys.joined(separator: " + ")
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    /// "Today 2:13 AM", "Yesterday 4:00 PM", "28 Sep 4:00 PM".
    static func separator(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today \(clock(d))" }
        if cal.isDateInYesterday(d) { return "Yesterday \(clock(d))" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return "\(f.string(from: d)) \(clock(d))"
    }

    static func elapsed(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Voice answers (Adjust a suggestion, New Awan interview)

/// Captures one spoken answer for a page that asked the user a question out loud.
///
/// The page holds the companion's talk pill with `target: VoiceAnswer.target`, so the utterance is
/// not treated as a companion request, then reads the final transcript. The companion engine can
/// route the global talk shortcut here too: while `isWaiting`, call `deliver(transcript)` with the
/// finished utterance instead of answering it (returns true when it was consumed).
@MainActor
final class VoiceAnswer: ObservableObject {
    static let shared = VoiceAnswer()
    static let target = "__awan_answer__"

    @Published private(set) var isWaiting = false
    private var handler: ((String) -> Void)?

    func expect(_ handler: @escaping (String) -> Void) {
        self.handler = handler
        isWaiting = true
    }

    func cancel() {
        handler = nil
        isWaiting = false
    }

    @discardableResult
    func deliver(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isWaiting, let handler, !t.isEmpty else { return false }
        cancel()
        handler(t)
        return true
    }
}

/// Lime "Hold Control + Option to answer" pill: press and hold with the mouse (or the shortcut),
/// release to send. The transcript goes to `VoiceAnswer`.
struct HoldToAnswerPill: View {
    @EnvironmentObject var companion: CompanionEngine
    var title: String
    var width: CGFloat = 300
    var height: CGFloat = 40
    var fontSize: CGFloat = 13.5
    @Local private var pressing = false

    var body: some View {
        HStack(spacing: 9) {
            if pressing || companion.voiceState == .listening {
                WaveformBars(level: CGFloat(companion.audioLevel), color: Theme.ink).frame(width: 30, height: 14)
                Text("Listening… release to send").lineLimit(1)
            } else {
                Image(systemName: "mic.fill").font(.system(size: fontSize - 1.5, weight: .semibold))
                Text(title).lineLimit(1)
            }
        }
        .font(.awan(fontSize, .semibold))
        .foregroundStyle(Theme.ink)
        .frame(width: width, height: height)
        .background(LimeGel())
        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.85), lineWidth: 2).padding(-4).opacity(pressing ? 1 : 0))
        .shadow(color: Theme.lime.opacity(0.35), radius: pressing ? 4 : 10, y: 3)
        .scaleEffect(pressing ? 0.97 : 1)
        .animation(Theme.snappy, value: pressing)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    companion.beginListening(target: VoiceAnswer.target)
                }
                .onEnded { _ in
                    pressing = false
                    companion.endListening()
                    Task { @MainActor in
                        // Give the recogniser a moment to finalise, then hand over what it heard.
                        for _ in 0..<25 {
                            if !companion.liveTranscript.isEmpty && companion.voiceState != .listening { break }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                        VoiceAnswer.shared.deliver(companion.liveTranscript)
                    }
                }
        )
        .help("Press and hold, or hold the talk shortcut. Release to send.")
    }
}

/// The lime gel capsule used by every talk pill.
struct LimeGel: View {
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                Capsule().fill(LinearGradient(colors: [Color(hex: 0xEAFF8C), Theme.lime, Theme.limeDeep], startPoint: .top, endPoint: .bottom))
                Capsule().strokeBorder(Color(hex: 0x8FB000).opacity(0.6), lineWidth: 1)
                Capsule().fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(height: g.size.height * 0.45).padding(.horizontal, 10).padding(.top, 1.5)
            }
        }
    }
}

/// A character peeking over the top edge of whatever sits below it (the talk pill, a card).
struct PeekingCharacter: View {
    var appearance: CharacterAppearance
    var mood: CharacterMood = .idle
    var width: CGFloat = 104

    /// Height from the top of the figure to where its body ends.
    static func bodyHeight(_ a: CharacterAppearance, width: CGFloat) -> CGFloat {
        a.pack == .awanClouds ? width / 1.35 * 0.88 : width * 0.82 * 0.86
    }

    var body: some View {
        Group {
            switch appearance.pack {
            case .awanClouds:
                CloudCreature(appearance: appearance, mood: mood, showPaws: false)
                    .frame(width: width, height: width / 1.35)
            default:
                KawanFace(appearance: appearance, mood: mood)
                    .frame(width: width * 0.82, height: width * 0.82)
                    .background(Circle().fill(CharacterCatalog.backgroundColor(appearance)).scaleEffect(0.92))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Two little paws resting on the edge the character peeks over.
struct PeekPaws: View {
    var appearance: CharacterAppearance
    var width: CGFloat
    var body: some View {
        let c = CharacterCatalog.cloudColors(for: appearance)
        HStack(spacing: width * 0.30) {
            ForEach(0..<2, id: \.self) { _ in
                Capsule()
                    .fill(LinearGradient(colors: [c.top, c.bottom], startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.10), lineWidth: 1))
                    .frame(width: width * 0.17, height: width * 0.11)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
        .allowsHitTesting(false)
    }
}

extension View {
    /// The character sits behind this view with its body showing above the top edge (sinking `sink`
    /// points behind it); cloud paws rest on the edge in front.
    func peeking(_ a: CharacterAppearance, mood: CharacterMood = .idle, width: CGFloat, x: CGFloat, sink: CGFloat = 10) -> some View {
        let bodyH = PeekingCharacter.bodyHeight(a, width: width)
        let pawsW = width * 0.30 + width * 0.34
        return self
            .background(alignment: .topLeading) {
                PeekingCharacter(appearance: a, mood: mood, width: width)
                    .offset(x: a.pack == .awanClouds ? x : x + width * 0.09, y: -(bodyH - sink))
            }
            .overlay(alignment: .topLeading) {
                if a.pack == .awanClouds {
                    PeekPaws(appearance: a, width: width)
                        .offset(x: x + width / 2 - pawsW / 2, y: -width * 0.055)
                }
            }
    }
}

/// Mood for a figure that follows the companion's voice state.
extension VoiceState {
    var mood: CharacterMood {
        switch self {
        case .idle: return .idle
        case .listening: return .listening
        case .processing: return .thinking
        case .responding: return .speaking
        }
    }
}

/// Header of a Home page: "‹ Back   Title".
struct PageTitleBar: View {
    let title: String
    var back: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 12) {
            if let back {
                Button(action: back) {
                    Label("Back", systemImage: "chevron.left").font(.awan(12.5, .medium)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10).frame(height: 28).background(Capsule().fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }
            Text(title).font(.awan(18, .semibold)).foregroundStyle(Theme.text)
            Spacer()
        }
    }
}

/// Kept for pages that still place it: the collapsed sidebar is now an icon rail with its own
/// expand button (reference home-collapsed), so pages draw nothing here.
struct ShowSidebarButton: View {
    var body: some View { EmptyView() }
}
