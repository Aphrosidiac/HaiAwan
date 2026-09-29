import AppKit
import SwiftUI

/// Snapshot registrations for the character packs (contact sheet, parts strips, reactions, sizes, editor per pack).
/// Names are prefixed "chars-". `chars-selftest` runs the pure checks and exits (0 = all passed).
extension Snapshots {
    static var charactersNames: [String] {
        ["chars-sheet", "chars-expressions", "chars-outfits", "chars-hair", "chars-reactions", "chars-sizes",
         "chars-editor-pahlawan", "chars-editor-arked", "chars-editor-gebu", "chars-editor-hikayat", "chars-editor-parts", "chars-editor-clouds-faces",
         "chars-selftest"]
    }

    static func characters(_ name: String) -> AnyView? {
        guard name.hasPrefix("chars-") else { return nil }
        if name == "chars-selftest" { CharactersSelfTest.run() }
        let s = AppState.shared

        func editor(_ pack: CharacterPack, preset: String, tall: Bool = false, reaction: (CharacterReaction, Double)? = nil) -> AnyView {
            if let p = CharacterCatalog.figurePreset(pack, preset) {
                s.agents.update("customer-radar") { $0.character = CharacterCatalog.apply(p) }
            }
            CharacterEditorView.debugReaction = reaction
            if tall { CharacterEditorView.debugMaxHeight = 2600 }
            s.homePage = .agent("customer-radar")
            s.characterEditorSlug = "customer-radar"
            return AnyView(HomeRootView().environmentObject(s).environmentObject(s.agents).environmentObject(s.companion)
                .environmentObject(RoutineScheduler.shared).environmentObject(Prefs.shared))
        }

        switch name {
        case "chars-sheet": return AnyView(CharacterSheets.contactSheet)
        case "chars-expressions": return AnyView(CharacterSheets.expressions)
        case "chars-outfits": return AnyView(CharacterSheets.outfits)
        case "chars-hair": return AnyView(CharacterSheets.hair)
        case "chars-reactions": return AnyView(CharacterSheets.reactions)
        case "chars-sizes": return AnyView(CharacterSheets.sizes)
        case "chars-editor-pahlawan": return editor(.pahlawan, preset: "siti")
        case "chars-editor-arked": return editor(.arked, preset: "turbo", reaction: (.wave, 0.3))
        case "chars-editor-gebu": return editor(.gebu, preset: "kaswi")
        case "chars-editor-hikayat": return editor(.hikayat, preset: "pelita", reaction: (.celebrate, 0.35))
        case "chars-editor-parts": return editor(.hikayat, preset: "daun", tall: true)
        case "chars-editor-clouds-faces":
            s.agents.update("customer-radar") { $0.character = CharacterCatalog.apply(CharacterCatalog.cloudPresets[4]) }
            return editor(.awanClouds, preset: "", tall: true)
        default: return nil
        }
    }
}

/// The review sheets (rendered on a neutral dark board).
@MainActor
enum CharacterSheets {
    private static func board<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.awan(15, .semibold)).foregroundStyle(Theme.text)
            content()
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel)
    }

    private static func tile(_ look: CharacterAppearance, _ label: String, size: CGFloat = 92) -> some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(CharacterCatalog.backgroundColor(look))
                CharacterFigure(appearance: look)
                    .padding(look.pack.isFigure ? EdgeInsets(top: 8, leading: 5, bottom: 0, trailing: 5) : EdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10))
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(label).font(.awan(11, .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }

    /// All 60 presets, one row per pack.
    static var contactSheet: some View {
        board("Awan characters — 6 packs × 10") {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(CharacterPack.allCases) { pack in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pack.title).font(.awan(13, .semibold)).foregroundStyle(Theme.text)
                            Text(pack.tagline).font(.awan(10.5)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: 110, alignment: .leading)
                        ForEach(CharacterCatalog.presetLooks(pack), id: \.id) { p in tile(p.look, p.name) }
                    }
                }
            }
        }
    }

    /// Every expression on every face style (and the cloud).
    static var expressions: some View {
        let looks: [CharacterAppearance] = [
            CharacterCatalog.apply(CharacterCatalog.kawanPresets[3]),
            CharacterCatalog.apply(CharacterCatalog.pahlawanPresets[0]),
            CharacterCatalog.apply(CharacterCatalog.arkedPresets[5]),
            CharacterCatalog.apply(CharacterCatalog.gebuPresets[0]),
            CharacterCatalog.apply(CharacterCatalog.hikayatPresets[3]),
            CharacterCatalog.apply(CharacterCatalog.cloudPresets[0]),
        ]
        return board("Expressions — 14 faces × 6 packs") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("").frame(width: 70)
                    ForEach(CharacterExpression.allCases) { e in
                        Text(e.title).font(.awan(10.5, .medium)).foregroundStyle(Theme.textSecondary).frame(width: 74)
                    }
                }
                ForEach(Array(looks.enumerated()), id: \.offset) { _, look in
                    HStack(spacing: 8) {
                        Text(look.pack.title).font(.awan(11, .semibold)).foregroundStyle(Theme.text).frame(width: 70, alignment: .leading)
                        ForEach(CharacterExpression.allCases) { e in
                            ZStack {
                                RoundedRectangle(cornerRadius: 12).fill(CharacterCatalog.backgroundColor(look))
                                if look.pack.isFigure {
                                    FigurePortrait(appearance: look, pose: FigurePose(expression: e), framing: .face).padding(2)
                                } else {
                                    CloudCreature(appearance: look, glow: false, expression: e).padding(8)
                                }
                            }
                            .frame(width: 74, height: 74)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
    }

    /// All outfits on two characters.
    static var outfits: some View {
        let a = CharacterCatalog.apply(CharacterCatalog.kawanPresets[0])
        let b = CharacterCatalog.apply(CharacterCatalog.hikayatPresets[4])
        return board("Outfits — \(CharacterCatalog.outfitCount) styles") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach([a, b], id: \.self) { base in
                    HStack(spacing: 8) {
                        ForEach(0..<10, id: \.self) { i in outfitTile(base, i) }
                    }
                    HStack(spacing: 8) {
                        ForEach(10..<CharacterCatalog.outfitCount, id: \.self) { i in outfitTile(base, i) }
                    }
                }
            }
        }
    }

    private static func outfitTile(_ base: CharacterAppearance, _ i: Int) -> some View {
        var look = base
        look.outfitStyle = i
        look.outfitColor = i % CharacterCatalog.outfitColors.count
        look.accentColor = (i * 3 + 1) % CharacterCatalog.accentColors.count
        return tile(look, CharacterCatalog.outfitNames[i], size: 96)
    }

    /// All hairstyles, head only.
    static var hair: some View {
        board("Hair — \(CharacterCatalog.hairstyleCount) styles") {
            let cols = Array(repeating: GridItem(.fixed(88), spacing: 8), count: 10)
            LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                ForEach(0..<CharacterCatalog.hairstyleCount, id: \.self) { i in
                    let pack: CharacterPack = i < 10 ? .kawan : i < 20 ? .pahlawan : i < 30 ? .arked : i < 40 ? .hikayat : .gebu
                    let look = CharacterAppearance(pack: pack, preset: nil, hairstyle: i, hairColor: i % 10, skinTone: (i / 3) % 8, eyeColor: i % 10,
                                                   background: i % 10, outfitStyle: i % 20, outfitColor: i % 10, accentColor: (i + 2) % 10)
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12).fill(CharacterCatalog.backgroundColor(look))
                            FigurePortrait(appearance: look, pose: FigurePose(expression: .idle), framing: .face).padding(4)
                        }
                        .frame(width: 88, height: 88)
                        Text("\(i) · \(CharacterCatalog.hairstyleNames[i])").font(.awan(10)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
            }
        }
    }

    /// Each reaction frozen at four moments.
    static var reactions: some View {
        let looks: [CharacterAppearance] = [
            CharacterCatalog.apply(CharacterCatalog.pahlawanPresets[6]),
            CharacterCatalog.apply(CharacterCatalog.gebuPresets[1]),
            CharacterCatalog.apply(CharacterCatalog.arkedPresets[1]),
            CharacterCatalog.apply(CharacterCatalog.cloudPresets[6]),
            CharacterCatalog.apply(CharacterCatalog.hikayatPresets[9]),
            CharacterCatalog.apply(CharacterCatalog.kawanPresets[5]),
        ]
        return board("Reactions — wave, wink, boop, giggle, celebrate, dance") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(CharacterReaction.allCases.enumerated()), id: \.offset) { idx, r in
                    HStack(spacing: 10) {
                        Label(r.title, systemImage: r.symbol).font(.awan(12, .semibold)).foregroundStyle(Theme.text).frame(width: 96, alignment: .leading)
                        ForEach([0.12, 0.3, 0.5, 0.75], id: \.self) { t in
                            let look = looks[idx]
                            ZStack {
                                RoundedRectangle(cornerRadius: 14).fill(CharacterCatalog.backgroundColor(look))
                                CharacterFigure(appearance: look, showPaws: !look.pack.isFigure, reaction: r, reactionProgress: t)
                                    .padding(look.pack.isFigure ? EdgeInsets(top: 12, leading: 12, bottom: 0, trailing: 12) : EdgeInsets(top: 18, leading: 12, bottom: 18, trailing: 12))
                            }
                            .frame(width: 118, height: 118)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        AgentAvatar(appearance: looks[idx], size: 64, reaction: r, reactionProgress: 0.4)
                            .padding(.leading, 10)
                    }
                }
            }
        }
    }

    /// Crispness from notch size to hero size.
    static var sizes: some View {
        let looks = CharacterPack.allCases.map { CharacterCatalog.packCluster($0)[1] }
        return board("Sizes — 20, 28, 44, 76, 112 pt avatars and a 220 pt figure") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(looks.enumerated()), id: \.offset) { _, look in
                    HStack(alignment: .center, spacing: 16) {
                        ForEach([20, 28, 44, 76, 112] as [CGFloat], id: \.self) { s in AgentAvatar(appearance: look, size: s) }
                        ZStack {
                            RoundedRectangle(cornerRadius: 18).fill(CharacterCatalog.backgroundColor(look).opacity(0.8))
                            CharacterFigure(appearance: look, mood: .speaking, showPaws: !look.pack.isFigure).padding(.top, look.pack.isFigure ? 10 : 0)
                        }
                        .frame(width: 220, height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        AgentAvatar(appearance: look, size: 44, mood: .sleeping)
                        AgentAvatar(appearance: look, size: 44, mood: .running)
                        AgentAvatar(appearance: look, size: 44, mood: .thinking)
                    }
                }
            }
        }
    }
}

/// `Awan --snapshot chars-selftest /dev/null` — catalogue and back-compat checks for the character packs.
@MainActor
enum CharactersSelfTest {
    static func run() -> Never {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "  ok   " : "  FAIL ") + what)
            if !ok { failures += 1 }
        }
        check(CharacterPack.allCases.count == 6, "6 packs")
        for pack in CharacterPack.allCases {
            let looks = CharacterCatalog.presetLooks(pack)
            check(looks.count == 10, "\(pack.title): 10 presets")
            check(Set(looks.map(\.id)).count == 10, "\(pack.title): preset ids unique")
            check(looks.allSatisfy { $0.look.pack == pack }, "\(pack.title): presets carry their pack")
            check(!pack.tagline.isEmpty, "\(pack.title): tagline")
        }
        let figureIDs = CharacterPack.allCases.filter(\.isFigure).flatMap { CharacterCatalog.figurePresets($0).map(\.id) }
        check(Set(figureIDs).count == figureIDs.count, "figure preset ids unique across packs")
        check(CharacterCatalog.hairstyleCount >= 30, "≥30 hairstyles (\(CharacterCatalog.hairstyleCount))")
        check(CharacterCatalog.outfitCount >= 12, "≥12 outfits (\(CharacterCatalog.outfitCount))")
        check(CharacterExpression.allCases.count == 14, "14 expressions")
        check(CharacterReaction.allCases.count == 6, "6 reactions")
        check(Array(CharacterCatalog.hairstyleNames.prefix(10)) == ["Bob", "Bun", "Spikes", "Twin buns", "Long", "Curls", "Side tail", "Fringe", "Braids", "Puff"],
              "original 10 hairstyle indices unchanged")
        for i in 0..<CharacterCatalog.hairstyleCount {
            let h = HairLibrary.pieces(i)
            if h.back.isEmpty && h.front.isEmpty && i != 49 { check(false, "hairstyle \(i) draws something") }
        }
        for i in 0..<CharacterCatalog.outfitCount where OutfitLibrary.pieces(i).isEmpty { check(false, "outfit \(i) draws something") }
        let allPresets = CharacterPack.allCases.flatMap { CharacterCatalog.presetLooks($0).map(\.look) }
        check(allPresets.allSatisfy { $0.hairstyle < CharacterCatalog.hairstyleCount && $0.outfitStyle < CharacterCatalog.outfitCount && $0.accentColor < 10 && $0.outfitColor < 10 },
              "every preset indexes inside the palettes")

        // Looks saved by the first build (no outfit/accent/expression keys) still decode.
        let legacy = #"{"pack":"kawan","preset":"mawar","cloudHue":0.5,"hairstyle":1,"hairColor":1,"skinTone":1,"eyeColor":1,"background":0}"#
        let old = try? JSONDecoder().decode(CharacterAppearance.self, from: Data(legacy.utf8))
        check(old?.pack == .kawan && old?.hairstyle == 1 && old?.outfitStyle == 0 && old?.outfitColor == 1 && old?.expression == nil, "legacy Kawan look decodes (outfit matches hair)")
        let cloud = try? JSONDecoder().decode(CharacterAppearance.self, from: Data(#"{"pack":"awanClouds","preset":"langit","cloudHue":0.57,"hairstyle":0,"hairColor":0,"skinTone":1,"eyeColor":0,"background":0}"#.utf8))
        check(cloud == CharacterAppearance.mascot, "legacy cloud look decodes equal to the mascot")
        let future = try? JSONDecoder().decode(CharacterAppearance.self, from: Data(#"{"pack":"someNewPack","expression":"grumpy"}"#.utf8))
        check(future?.pack == .kawan && future?.expression == nil, "unknown pack / expression fall back instead of failing")
        let full = CharacterCatalog.apply(CharacterCatalog.hikayatPresets[4])
        let round = (try? JSONEncoder().encode(full)).flatMap { try? JSONDecoder().decode(CharacterAppearance.self, from: $0) }
        check(round == full, "new look round-trips through JSON")
        let agentJSON = #"{"slug":"a","name":"A","roleText":"r","oneLiner":"o","introMessages":[],"suggestedAsks":[],"baseHue":0.5,"character":{"pack":"kawan","preset":null,"cloudHue":0.5,"hairstyle":3,"hairColor":3,"skinTone":2,"eyeColor":3,"background":2},"createdAt":0,"isStarter":false,"pinned":false,"archived":false}"#
        check((try? JSONDecoder().decode(AwanAgent.self, from: Data(agentJSON.utf8)))?.character.hairstyle == 3, "saved agent with an old look decodes")

        for pack in CharacterPack.allCases {
            let r = CharacterCatalog.random(pack: pack)
            check(r.pack == pack && r.preset == nil || (pack == .awanClouds && r.pack == pack), "\(pack.title): dice stays in the pack")
        }
        check(CharacterCatalog.defaultLook(for: .gebu, seed: "x", hue: 0.3) == CharacterCatalog.defaultLook(for: .gebu, seed: "x", hue: 0.3), "pack switch default is stable per agent")
        check(ReactionPose.at(.boop, 1).scale.height > 0.99 && ReactionPose.at(nil, 0.5) == ReactionPose(), "reactions settle back to rest")
        check(CharacterMood.running.figurePose(resting: nil).expression == .determined && CharacterMood.idle.figurePose(resting: .shy).expression == .shy,
              "moods map onto expressions (idle keeps the resting face)")

        print(failures == 0 ? "chars-selftest: all passed" : "chars-selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
