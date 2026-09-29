import SwiftUI

/// Presets and palettes for the six character packs. Everything is procedural (no bitmap art),
/// so an appearance is just a handful of indices into the tables below.
///
/// Index stability matters: saved looks store indices, so new entries are only ever appended.
enum CharacterCatalog {
    // MARK: Awan Clouds

    struct CloudPreset: Identifiable, Hashable {
        let id: String
        let name: String
        let hue: Double
        let saturation: Double
        let brightness: Double
    }

    /// Awan Clouds — ten colourways, named in Malay.
    static let cloudPresets: [CloudPreset] = [
        .init(id: "langit", name: "Langit", hue: 0.57, saturation: 0.42, brightness: 0.98),   // sky
        .init(id: "pic", name: "Pic", hue: 0.04, saturation: 0.36, brightness: 0.98),         // peach
        .init(id: "padi", name: "Padi", hue: 0.36, saturation: 0.38, brightness: 0.86),       // meadow
        .init(id: "mentari", name: "Mentari", hue: 0.14, saturation: 0.55, brightness: 0.98), // sun
        .init(id: "senja", name: "Senja", hue: 0.74, saturation: 0.32, brightness: 0.92),     // dusk
        .init(id: "oren", name: "Oren", hue: 0.08, saturation: 0.55, brightness: 0.97),       // apricot
        .init(id: "bunga", name: "Bunga", hue: 0.93, saturation: 0.34, brightness: 0.97),     // petal
        .init(id: "nila", name: "Nila", hue: 0.64, saturation: 0.36, brightness: 0.86),       // indigo
        .init(id: "kapas", name: "Kapas", hue: 0.10, saturation: 0.16, brightness: 0.98),     // cotton
        .init(id: "bulan", name: "Bulan", hue: 0.60, saturation: 0.06, brightness: 0.88),     // moon
    ]

    // MARK: Figure packs

    /// A named look on the figure rig (Kawan, Pahlawan, Arked, Gebu, Hikayat).
    struct FigurePreset: Identifiable, Hashable {
        var pack: CharacterPack = .kawan
        let id: String
        let name: String
        let hairstyle: Int
        let hairColor: Int
        let skinTone: Int
        let eyeColor: Int
        let background: Int
        var outfit: Int = 0
        var outfitColor: Int = 0
        var accent: Int = 1
        var expression: CharacterExpression? = nil
        var blurb: String = ""
    }
    typealias KawanPreset = FigurePreset

    /// Kawan — ten big-eyed friends.
    static let kawanPresets: [FigurePreset] = [
        .init(id: "nila", name: "Nila", hairstyle: 0, hairColor: 0, skinTone: 1, eyeColor: 0, background: 3, outfit: 0, outfitColor: 1, accent: 1, blurb: "Tidy notes, calm answers."),
        .init(id: "kuning", name: "Kuning", hairstyle: 3, hairColor: 3, skinTone: 1, eyeColor: 3, background: 2, outfit: 2, outfitColor: 3, accent: 1, blurb: "Sunny about every to-do."),
        .init(id: "pucuk", name: "Pucuk", hairstyle: 2, hairColor: 2, skinTone: 2, eyeColor: 2, background: 4, outfit: 1, outfitColor: 2, accent: 1, blurb: "Always first to try the new thing."),
        .init(id: "mawar", name: "Mawar", hairstyle: 1, hairColor: 1, skinTone: 1, eyeColor: 1, background: 0, outfit: 17, outfitColor: 0, accent: 1, blurb: "Sweet, sharp, never late."),
        .init(id: "ungu", name: "Ungu", hairstyle: 4, hairColor: 4, skinTone: 2, eyeColor: 4, background: 1, outfit: 18, outfitColor: 4, accent: 1, blurb: "Reads the whole thread first."),
        .init(id: "bara", name: "Bara", hairstyle: 5, hairColor: 5, skinTone: 4, eyeColor: 5, background: 7, outfit: 3, outfitColor: 5, accent: 0, blurb: "Rolls up the sleeves, gets it done."),
        .init(id: "jambu", name: "Jambu", hairstyle: 6, hairColor: 6, skinTone: 1, eyeColor: 6, background: 8, outfit: 2, outfitColor: 6, accent: 1, blurb: "Makes busywork feel like play."),
        .init(id: "malam", name: "Malam", hairstyle: 7, hairColor: 7, skinTone: 5, eyeColor: 7, background: 6, outfit: 4, outfitColor: 7, accent: 5, blurb: "Night-owl researcher."),
        .init(id: "koko", name: "Koko", hairstyle: 8, hairColor: 8, skinTone: 6, eyeColor: 8, background: 5, outfit: 16, outfitColor: 8, accent: 0, blurb: "Warm, patient, remembers everything."),
        .init(id: "kabus", name: "Kabus", hairstyle: 9, hairColor: 9, skinTone: 7, eyeColor: 9, background: 9, outfit: 7, outfitColor: 4, accent: 1, blurb: "Quiet mist, big ideas."),
    ]

    /// Pahlawan — little martial-arts heroes.
    static let pahlawanPresets: [FigurePreset] = [
        .init(pack: .pahlawan, id: "wira", name: "Wira", hairstyle: 11, hairColor: 7, skinTone: 2, eyeColor: 0, background: 3, outfit: 5, outfitColor: 8, accent: 2, expression: .determined, blurb: "Ties the headband tight before every task."),
        .init(pack: .pahlawan, id: "tuah", name: "Tuah", hairstyle: 16, hairColor: 8, skinTone: 4, eyeColor: 8, background: 0, outfit: 8, outfitColor: 5, accent: 0, blurb: "Loyal to your inbox to the very end."),
        .init(pack: .pahlawan, id: "jebat", name: "Jebat", hairstyle: 10, hairColor: 5, skinTone: 3, eyeColor: 5, background: 7, outfit: 7, outfitColor: 0, accent: 9, expression: .determined, blurb: "Fights the backlog head-on."),
        .init(pack: .pahlawan, id: "kasturi", name: "Kasturi", hairstyle: 12, hairColor: 7, skinTone: 1, eyeColor: 7, background: 1, outfit: 5, outfitColor: 7, accent: 1, blurb: "Swift, precise, one clean move."),
        .init(pack: .pahlawan, id: "lekir", name: "Lekir", hairstyle: 13, hairColor: 2, skinTone: 5, eyeColor: 2, background: 4, outfit: 6, outfitColor: 2, accent: 0, blurb: "Guards your calendar like a fortress."),
        .init(pack: .pahlawan, id: "lekiu", name: "Lekiu", hairstyle: 18, hairColor: 8, skinTone: 6, eyeColor: 3, background: 2, outfit: 7, outfitColor: 3, accent: 9, expression: .happy, blurb: "Trains every morning, reports by nine."),
        .init(pack: .pahlawan, id: "siti", name: "Siti", hairstyle: 19, hairColor: 1, skinTone: 1, eyeColor: 1, background: 8, outfit: 5, outfitColor: 6, accent: 1, expression: .excited, blurb: "Small, fast, fearless."),
        .init(pack: .pahlawan, id: "melur", name: "Melur", hairstyle: 17, hairColor: 9, skinTone: 2, eyeColor: 4, background: 9, outfit: 8, outfitColor: 4, accent: 4, blurb: "Graceful under a pile of tabs."),
        .init(pack: .pahlawan, id: "bayu", name: "Bayu", hairstyle: 14, hairColor: 0, skinTone: 2, eyeColor: 0, background: 5, outfit: 10, outfitColor: 5, accent: 5, expression: .curious, blurb: "Goes where the wind (and the leads) go."),
        .init(pack: .pahlawan, id: "guruh", name: "Guruh", hairstyle: 15, hairColor: 3, skinTone: 4, eyeColor: 3, background: 6, outfit: 6, outfitColor: 7, accent: 0, expression: .laughing, blurb: "Loud laugh, louder results."),
    ]

    /// Arked — arcade heroes with pixel eyes.
    static let arkedPresets: [FigurePreset] = [
        .init(pack: .arked, id: "piksel", name: "Piksel", hairstyle: 26, hairColor: 4, skinTone: 1, eyeColor: 7, background: 1, outfit: 19, outfitColor: 1, accent: 1, blurb: "Pushes every detail to the pixel."),
        .init(pack: .arked, id: "koin", name: "Koin", hairstyle: 23, hairColor: 3, skinTone: 3, eyeColor: 3, background: 2, outfit: 4, outfitColor: 4, accent: 0, expression: .happy, blurb: "Counts every sen, twice."),
        .init(pack: .arked, id: "turbo", name: "Turbo", hairstyle: 21, hairColor: 5, skinTone: 2, eyeColor: 5, background: 0, outfit: 9, outfitColor: 9, accent: 2, expression: .excited, blurb: "Already done. What's next?"),
        .init(pack: .arked, id: "roket", name: "Roket", hairstyle: 24, hairColor: 8, skinTone: 4, eyeColor: 8, background: 3, outfit: 12, outfitColor: 8, accent: 6, blurb: "Launches side projects for fun."),
        .init(pack: .arked, id: "skor", name: "Skor", hairstyle: 20, hairColor: 7, skinTone: 5, eyeColor: 0, background: 4, outfit: 19, outfitColor: 2, accent: 3, expression: .determined, blurb: "Keeps score so you don't have to."),
        .init(pack: .arked, id: "neon", name: "Neon", hairstyle: 25, hairColor: 6, skinTone: 1, eyeColor: 6, background: 9, outfit: 7, outfitColor: 7, accent: 4, blurb: "Works best with the music on."),
        .init(pack: .arked, id: "kombo", name: "Kombo", hairstyle: 27, hairColor: 8, skinTone: 6, eyeColor: 2, background: 5, outfit: 10, outfitColor: 3, accent: 2, expression: .skeptical, blurb: "Chains five tasks into one."),
        .init(pack: .arked, id: "laser", name: "Laser", hairstyle: 22, hairColor: 0, skinTone: 0, eyeColor: 5, background: 3, outfit: 12, outfitColor: 1, accent: 6, expression: .curious, blurb: "Beep. Found it."),
        .init(pack: .arked, id: "bos", name: "Bos", hairstyle: 28, hairColor: 5, skinTone: 3, eyeColor: 1, background: 7, outfit: 11, outfitColor: 7, accent: 2, blurb: "The final level of admin."),
        .init(pack: .arked, id: "nyawa", name: "Nyawa", hairstyle: 29, hairColor: 1, skinTone: 2, eyeColor: 2, background: 8, outfit: 1, outfitColor: 6, accent: 3, expression: .happy, blurb: "Always has one more try left."),
    ]

    /// Gebu — soft round blob buddies, named after kuih.
    static let gebuPresets: [FigurePreset] = [
        .init(pack: .gebu, id: "onde", name: "Onde", hairstyle: 40, hairColor: 2, skinTone: 2, eyeColor: 0, background: 4, outfit: 0, outfitColor: 8, accent: 8, blurb: "Small, round, surprisingly sweet."),
        .init(pack: .gebu, id: "apam", name: "Apam", hairstyle: 42, hairColor: 8, skinTone: 6, eyeColor: 0, background: 2, outfit: 14, outfitColor: 3, accent: 4, expression: .happy, blurb: "Rises to every occasion."),
        .init(pack: .gebu, id: "lepat", name: "Lepat", hairstyle: 43, hairColor: 2, skinTone: 5, eyeColor: 0, background: 5, outfit: 13, outfitColor: 2, accent: 3, blurb: "Wraps things up neatly."),
        .init(pack: .gebu, id: "dodol", name: "Dodol", hairstyle: 41, hairColor: 8, skinTone: 7, eyeColor: 0, background: 7, outfit: 18, outfitColor: 5, accent: 0, expression: .sleepy, blurb: "Slow and steady, sticks with it."),
        .init(pack: .gebu, id: "kaswi", name: "Kaswi", hairstyle: 44, hairColor: 6, skinTone: 1, eyeColor: 0, background: 8, outfit: 17, outfitColor: 6, accent: 1, expression: .shy, blurb: "Shy at first, then never stops helping."),
        .init(pack: .gebu, id: "putu", name: "Putu", hairstyle: 46, hairColor: 0, skinTone: 0, eyeColor: 0, background: 3, outfit: 10, outfitColor: 1, accent: 1, expression: .curious, blurb: "Steams through the queue."),
        .init(pack: .gebu, id: "bingka", name: "Bingka", hairstyle: 45, hairColor: 8, skinTone: 3, eyeColor: 0, background: 0, outfit: 1, outfitColor: 3, accent: 1, blurb: "Big hugs, bigger spreadsheets."),
        .init(pack: .gebu, id: "serabai", name: "Serabai", hairstyle: 47, hairColor: 9, skinTone: 4, eyeColor: 0, background: 9, outfit: 2, outfitColor: 4, accent: 1, expression: .loving, blurb: "Soft-spoken, very thorough."),
        .init(pack: .gebu, id: "cendol", name: "Cendol", hairstyle: 48, hairColor: 2, skinTone: 2, eyeColor: 0, background: 5, outfit: 19, outfitColor: 2, accent: 1, expression: .excited, blurb: "Cool head on a hot day."),
        .init(pack: .gebu, id: "lapis", name: "Lapis", hairstyle: 49, hairColor: 4, skinTone: 4, eyeColor: 0, background: 1, outfit: 18, outfitColor: 4, accent: 4, blurb: "Does it layer by layer."),
    ]

    /// Hikayat — storybook spirits.
    static let hikayatPresets: [FigurePreset] = [
        .init(pack: .hikayat, id: "pelita", name: "Pelita", hairstyle: 33, hairColor: 8, skinTone: 4, eyeColor: 3, background: 7, outfit: 15, outfitColor: 7, accent: 6, blurb: "Lights the way through late nights."),
        .init(pack: .hikayat, id: "purnama", name: "Purnama", hairstyle: 32, hairColor: 7, skinTone: 1, eyeColor: 7, background: 9, outfit: 8, outfitColor: 7, accent: 0, expression: .sleepy, blurb: "Keeps watch while you sleep."),
        .init(pack: .hikayat, id: "daun", name: "Daun", hairstyle: 30, hairColor: 8, skinTone: 3, eyeColor: 2, background: 4, outfit: 13, outfitColor: 2, accent: 8, expression: .happy, blurb: "Grows your ideas a little every day."),
        .init(pack: .hikayat, id: "embun", name: "Embun", hairstyle: 38, hairColor: 0, skinTone: 1, eyeColor: 0, background: 3, outfit: 2, outfitColor: 1, accent: 1, expression: .curious, blurb: "Fresh eyes every morning."),
        .init(pack: .hikayat, id: "kemboja", name: "Kemboja", hairstyle: 31, hairColor: 6, skinTone: 2, eyeColor: 6, background: 8, outfit: 14, outfitColor: 8, accent: 3, expression: .loving, blurb: "Gentle with the hard emails."),
        .init(pack: .hikayat, id: "sulur", name: "Sulur", hairstyle: 37, hairColor: 2, skinTone: 5, eyeColor: 2, background: 5, outfit: 14, outfitColor: 3, accent: 8, blurb: "Connects the loose ends."),
        .init(pack: .hikayat, id: "cendawan", name: "Cendawan", hairstyle: 34, hairColor: 8, skinTone: 2, eyeColor: 8, background: 0, outfit: 10, outfitColor: 3, accent: 2, expression: .shy, blurb: "Pops up right when you need it."),
        .init(pack: .hikayat, id: "rubah", name: "Rubah", hairstyle: 36, hairColor: 5, skinTone: 3, eyeColor: 5, background: 2, outfit: 18, outfitColor: 5, accent: 1, expression: .skeptical, blurb: "Clever, and checks the fine print."),
        .init(pack: .hikayat, id: "pari", name: "Pari", hairstyle: 39, hairColor: 4, skinTone: 1, eyeColor: 4, background: 9, outfit: 15, outfitColor: 4, accent: 0, blurb: "Tells your story, beautifully."),
        .init(pack: .hikayat, id: "arnab", name: "Arnab", hairstyle: 35, hairColor: 9, skinTone: 2, eyeColor: 6, background: 6, outfit: 1, outfitColor: 8, accent: 4, expression: .excited, blurb: "Hops between tasks all day."),
    ]

    static func figurePresets(_ pack: CharacterPack) -> [FigurePreset] {
        switch pack {
        case .awanClouds: return []
        case .kawan: return kawanPresets
        case .pahlawan: return pahlawanPresets
        case .arked: return arkedPresets
        case .gebu: return gebuPresets
        case .hikayat: return hikayatPresets
        }
    }

    /// Every preset look of a pack, in display order.
    static func presetLooks(_ pack: CharacterPack) -> [(id: String, name: String, look: CharacterAppearance)] {
        if pack == .awanClouds { return cloudPresets.map { ($0.id, $0.name, apply($0)) } }
        return figurePresets(pack).map { ($0.id, $0.name, apply($0)) }
    }

    // MARK: Palettes

    static let hairColors: [Color] = [
        Color(hex: 0x3F97BF), Color(hex: 0xF0736A), Color(hex: 0x21A576), Color(hex: 0xE9B42D), Color(hex: 0x8C73D0),
        Color(hex: 0xA2412E), Color(hex: 0xE35A94), Color(hex: 0x3A3F86), Color(hex: 0x5A3A34), Color(hex: 0xC9CFDE),
    ]

    static let skinTones: [Color] = [
        Color(hex: 0xFCE3D6), Color(hex: 0xF8CDB0), Color(hex: 0xF2C29A), Color(hex: 0xE8B089),
        Color(hex: 0xC98556), Color(hex: 0xA86A45), Color(hex: 0x87543A), Color(hex: 0x5E3A2A),
    ]

    /// Gebu reads `skinTone` as one of these soft body colours.
    static let gebuBodies: [Color] = [
        Color(hex: 0xBFE2F6), Color(hex: 0xF8CEDF), Color(hex: 0xC6ECCD), Color(hex: 0xFBE5A0),
        Color(hex: 0xDAD0F6), Color(hex: 0xFACFB3), Color(hex: 0xF3F1EA), Color(hex: 0xE4C29A),
    ]

    static let eyeColors: [Color] = [
        Color(hex: 0x3D9FD0), Color(hex: 0xE0736A), Color(hex: 0x2FAE82), Color(hex: 0xE3B13A), Color(hex: 0x8F7BDD),
        Color(hex: 0xD8894A), Color(hex: 0xD86FA9), Color(hex: 0x6E7BE0), Color(hex: 0xC88A5A), Color(hex: 0x8FCFB6),
    ]

    static let backgrounds: [Color] = [
        Color(hex: 0xF7C9A8), Color(hex: 0xD8CCF4), Color(hex: 0xF4E3A1), Color(hex: 0xBFE0F4), Color(hex: 0xCDEBC5),
        Color(hex: 0xBDE7DD), Color(hex: 0xC6D6F7), Color(hex: 0xF3D2A6), Color(hex: 0xF6CFE0), Color(hex: 0xE0D2F6),
    ]

    static let outfitColors: [Color] = [
        Color(hex: 0xF07A64), Color(hex: 0x5AA9E6), Color(hex: 0x45BF93), Color(hex: 0xF2BF4A), Color(hex: 0x9A7BE0),
        Color(hex: 0xC4553A), Color(hex: 0xEE7FAE), Color(hex: 0x3D4B91), Color(hex: 0xF3E9D4), Color(hex: 0x3A3A40),
    ]

    static let accentColors: [Color] = [
        Color(hex: 0xF6C744), Color(hex: 0xFBF7EE), Color(hex: 0xE5484D), Color(hex: 0x2BB3A6), Color(hex: 0xF59AC0),
        Color(hex: 0x8DD3F7), Color(hex: 0xF59A3C), Color(hex: 0x8B6FE8), Color(hex: 0x62B85E), Color(hex: 0x2A2A2E),
    ]

    static let hairstyleNames = [
        // Kawan (0–9, the original styles; indices are stored, never reorder)
        "Bob", "Bun", "Spikes", "Twin buns", "Long", "Curls", "Side tail", "Fringe", "Braids", "Puff",
        // Pahlawan
        "Blaze", "Ikat spikes", "High tail", "Mohawk", "Swoop", "Wild", "Top knot", "Ribbon band", "Buzz", "Twin tails",
        // Arked
        "Visor cap", "Racer helmet", "Antenna", "Crown", "Goggles", "Headphones", "Pixel quiff", "Bandana", "Plume helm", "Beanie",
        // Hikayat
        "Leaf crown", "Petal hood", "Moon hood", "Lantern flame", "Mushroom", "Bunny hood", "Fox ears", "Vine braids", "Star clip", "Story hat",
        // Gebu
        "Sprout", "Swirl", "Tuft trio", "Bean", "Cat ears", "Bear ears", "Drop", "Cloudlet", "Nubs", "Shine",
    ]

    static let outfitNames = [
        "Tee", "Hoodie", "Pinafore", "Overalls", "Jacket", "Gi", "Armour", "Track top", "Sash robe", "Flight suit",
        "Explorer", "Knight", "Space suit", "Poncho", "Garden apron", "Lantern robe", "Baju Melayu", "Sailor", "Cardigan", "Jersey",
    ]

    static var hairstyleCount: Int { hairstyleNames.count }
    static var outfitCount: Int { outfitNames.count }

    // MARK: Lookups

    static func cloudPreset(_ id: String?) -> CloudPreset? { cloudPresets.first { $0.id == id } }
    static func kawanPreset(_ id: String?) -> FigurePreset? { kawanPresets.first { $0.id == id } }
    static func figurePreset(_ pack: CharacterPack, _ id: String?) -> FigurePreset? { figurePresets(pack).first { $0.id == id } }

    /// Display name of the preset an appearance came from ("Custom" once edited).
    static func presetName(_ a: CharacterAppearance) -> String {
        if a.pack == .awanClouds { return cloudPreset(a.preset)?.name ?? "Custom" }
        return figurePreset(a.pack, a.preset)?.name ?? "Custom"
    }

    static func presetBlurb(_ a: CharacterAppearance) -> String? {
        guard a.pack.isFigure, let p = figurePreset(a.pack, a.preset), !p.blurb.isEmpty else { return nil }
        return p.blurb
    }

    static func skinColor(_ a: CharacterAppearance) -> Color {
        a.pack == .gebu ? gebuBodies[wrap(a.skinTone, gebuBodies.count)] : skinTones[wrap(a.skinTone, skinTones.count)]
    }
    static func hairColor(_ a: CharacterAppearance) -> Color { hairColors[wrap(a.hairColor, hairColors.count)] }
    static func eyeColor(_ a: CharacterAppearance) -> Color { eyeColors[wrap(a.eyeColor, eyeColors.count)] }
    static func outfitColor(_ a: CharacterAppearance) -> Color { outfitColors[wrap(a.outfitColor, outfitColors.count)] }
    static func accentColor(_ a: CharacterAppearance) -> Color { accentColors[wrap(a.accentColor, accentColors.count)] }
    static func backgroundColor(_ a: CharacterAppearance) -> Color {
        a.pack == .awanClouds ? cloudColors(for: a).ring : backgrounds[wrap(a.background, backgrounds.count)]
    }

    static func wrap(_ i: Int, _ n: Int) -> Int { ((i % n) + n) % n }

    // MARK: Building looks

    /// A pleasant default for a generated agent: the cloud preset nearest its hue.
    static func appearance(forHue hue: Double, seed: String) -> CharacterAppearance {
        let preset = cloudPresets.prefix(8).min { abs($0.hue - hue) < abs($1.hue - hue) } ?? cloudPresets[0]
        return CharacterAppearance(pack: .awanClouds, preset: preset.id, cloudHue: preset.hue)
    }

    /// The dice: a random look in `pack`, across every field the pack uses.
    static func random(pack: CharacterPack) -> CharacterAppearance {
        let expr: CharacterExpression? = Bool.random() ? nil : [.idle, .happy, .curious, .excited, .shy, .determined, .loving, .skeptical].randomElement()
        switch pack {
        case .awanClouds:
            var a = apply(cloudPresets.randomElement()!)
            if Bool.random() { a.preset = nil; a.cloudHue = Double.random(in: 0..<1) }
            a.expression = expr
            return a
        default:
            let hair: Int
            switch pack {
            case .gebu: hair = Int.random(in: 0..<10) < 7 ? Int.random(in: 40..<50) : Int.random(in: 0..<hairstyleCount)
            default: hair = Int.random(in: 0..<hairstyleCount)
            }
            return CharacterAppearance(pack: pack, preset: nil, cloudHue: 0.5,
                                       hairstyle: hair, hairColor: Int.random(in: 0..<hairColors.count),
                                       skinTone: Int.random(in: 0..<8), eyeColor: Int.random(in: 0..<eyeColors.count),
                                       background: Int.random(in: 0..<backgrounds.count),
                                       outfitStyle: Int.random(in: 0..<outfitCount), outfitColor: Int.random(in: 0..<outfitColors.count),
                                       accentColor: Int.random(in: 0..<accentColors.count), expression: expr)
        }
    }

    static func apply(_ preset: FigurePreset) -> CharacterAppearance {
        CharacterAppearance(pack: preset.pack, preset: preset.id, cloudHue: 0.5, hairstyle: preset.hairstyle, hairColor: preset.hairColor,
                            skinTone: preset.skinTone, eyeColor: preset.eyeColor, background: preset.background,
                            outfitStyle: preset.outfit, outfitColor: preset.outfitColor, accentColor: preset.accent, expression: preset.expression)
    }

    static func apply(_ preset: CloudPreset) -> CharacterAppearance {
        CharacterAppearance(pack: .awanClouds, preset: preset.id, cloudHue: preset.hue)
    }

    /// First look shown when switching an agent into `pack` (stable per agent).
    static func defaultLook(for pack: CharacterPack, seed: String, hue: Double) -> CharacterAppearance {
        if pack == .awanClouds { return appearance(forHue: hue, seed: seed) }
        let list = figurePresets(pack)
        let h = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        return apply(list[h % list.count])
    }

    /// Three looks that represent a pack on its card.
    static func packCluster(_ pack: CharacterPack) -> [CharacterAppearance] {
        switch pack {
        case .awanClouds: return ["senja", "langit", "pic"].compactMap(cloudPreset).map(apply)
        case .kawan: return ["mawar", "nila", "kuning"].compactMap(kawanPreset).map(apply)
        case .pahlawan: return ["siti", "wira", "guruh"].compactMap { figurePreset(.pahlawan, $0) }.map(apply)
        case .arked: return ["neon", "turbo", "koin"].compactMap { figurePreset(.arked, $0) }.map(apply)
        case .gebu: return ["kaswi", "onde", "apam"].compactMap { figurePreset(.gebu, $0) }.map(apply)
        case .hikayat: return ["kemboja", "pelita", "daun"].compactMap { figurePreset(.hikayat, $0) }.map(apply)
        }
    }

    static func cloudColors(for a: CharacterAppearance) -> (top: Color, bottom: Color, ring: Color) {
        let p = cloudPreset(a.preset) ?? CloudPreset(id: "custom", name: "Custom", hue: a.cloudHue, saturation: 0.4, brightness: 0.96)
        let top = Color(hue: p.hue, saturation: max(0.04, p.saturation * 0.75), brightness: min(1, p.brightness + 0.02))
        let bottom = Color(hue: (p.hue + 0.02).truncatingRemainder(dividingBy: 1), saturation: min(1, p.saturation * 1.15), brightness: p.brightness * 0.93)
        let ring = Color(hue: (p.hue + 0.5).truncatingRemainder(dividingBy: 1), saturation: 0.28, brightness: 0.97)
        return (top, bottom, ring)
    }
}
