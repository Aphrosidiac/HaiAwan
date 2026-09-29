import SwiftUI

/// "Edit character": live preview + name on the left; packs, presets and every custom part on the right.
/// Presented over Home by HomeRootView when `AppState.characterEditorSlug` is set.
struct CharacterEditorView: View {
    let slug: String
    @EnvironmentObject var state: AppState
    @ObservedObject private var hero = CharacterHero.shared
    @Local private var draft: CharacterAppearance
    @Local private var name: String
    @Local private var react = ReactionTrigger()

    init(slug: String) {
        self.slug = slug
        let agent = MainActor.assumeIsolated { AgentStore.shared.agent(slug) }
        _draft = Local(wrappedValue: agent?.character ?? .default)
        _name = Local(wrappedValue: agent?.name ?? "")
    }

    /// Snapshot hooks: let the editor grow taller than on screen; freeze the preview mid-reaction.
    static var debugMaxHeight: CGFloat = 680
    static var debugReaction: (CharacterReaction, Double)? = nil

    private var agent: AwanAgent? { state.agents.agent(slug) }

    /// Reference sheet (character-editor*.png): 851×533 inside the Home panel, 59.5 pt header (title,
    /// plain Cancel, 78×31 Save gel), a 290 pt preview column (look name + shuffle, big figure, name field
    /// pinned to the bottom) and a scrolling 520 pt picker column with sentence-case section titles.
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            HStack(spacing: 0) {
                previewColumn
                    .frame(width: 290)
                    .background(Color(hex: 0x282825))
                Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        packs
                        presets.padding(.top, 21)
                        yourLook.padding(.top, 11.5)
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.top, 29)
                        expressions.padding(.top, 30)
                        if draft.pack == .awanClouds { cloudColor.padding(.top, 34) } else { figureControls.padding(.top, 34) }
                    }
                    .padding(.leading, 20.5).padding(.trailing, 20.5)
                    .padding(.top, 17).padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: 980, maxHeight: Self.debugMaxHeight)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0x1E1E1D)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 30, y: 12)
        .onExitCommand { CharacterHero.close() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            Text("Edit character").font(.awan(17, .semibold)).foregroundStyle(Theme.text)
            Spacer()
            Button("Cancel") { CharacterHero.close() }
                .buttonStyle(.plain)
                .font(.awan(15, .medium)).foregroundStyle(SettingsStyle.navText)
                .keyboardShortcut(.cancelAction)
                .padding(.trailing, 17)
            Button { save() } label: { Label("Save", systemImage: "checkmark") }
                .buttonStyle(.gel(.lime, height: 31, padding: 13, fontSize: 15))
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.leading, 20.5).padding(.trailing, 20)
        .frame(height: 59.5)
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let look = draft
        state.agents.update(slug) { a in
            a.character = look
            if !n.isEmpty { a.name = String(n.prefix(40)) }
        }
        Sounds.play(.thumbsUp, volume: 0.4)
        CharacterHero.close()
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(CharacterCatalog.presetName(draft)).font(.awan(15.5, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button { withAnimation(Theme.spring) { draft = CharacterCatalog.random(pack: draft.pack) } } label: {
                    Image(systemName: "dice.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                        .frame(width: 35, height: 35)
                        .background(Circle().fill(LinearGradient(colors: [Color(hex: 0xF0FFB0), Theme.lime, Color(hex: 0xC8EE2C)], startPoint: .top, endPoint: .bottom)))
                        .overlay(Circle().strokeBorder(Color(hex: 0x6F8A00).opacity(0.9), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Randomize every part of this character")
            }
            .padding(.top, 20)

            Spacer(minLength: 8)
            preview
                .frame(width: draft.pack.isFigure ? 210 : 208, height: draft.pack.isFigure ? 210 : 176)
                .opacity(hero.flying(slug) ? 0 : 1)
                .modifier(HeroFrameReporter(keyPath: \.previewFrame))
                .frame(maxWidth: .infinity)
                .id(draft)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
                .contentShape(Rectangle())
                .onTapGesture { react.fire(.boop) }
                .animation(Theme.spring, value: draft)
                .accessibilityLabel("Live preview of \(name). Tap to boop.")
                .help("Tap to boop")
            // Awan-only: play a reaction on the preview.
            reactionBar.padding(.top, 14)
            Spacer(minLength: 8)

            HStack(alignment: .center, spacing: 12) {
                AgentAvatar(appearance: draft, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Name").font(.awan(12, .medium)).foregroundStyle(SettingsStyle.navText)
                    HStack(spacing: 6) {
                        TextField("Give your Awan a name.", text: $name)
                            .textFieldStyle(.plain)
                            .font(.awan(16.5, .semibold))
                            .foregroundStyle(Theme.text)
                        Image(systemName: "pencil").font(.system(size: 11, weight: .medium)).foregroundStyle(SettingsStyle.navText)
                    }
                    .padding(.bottom, 5)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1) }
                }
            }
            .padding(.bottom, 20)
        }
        .padding(.leading, 20).padding(.trailing, 20.5)
    }

    @ViewBuilder private var preview: some View {
        if let (r, t) = Self.debugReaction {
            CharacterFigure(appearance: draft, mood: .idle, showPaws: !draft.pack.isFigure, expression: draft.expression ?? .happy, reaction: r, reactionProgress: t)
        } else {
            ReactiveCharacter(appearance: draft, mood: .idle, expression: draft.expression ?? .happy, showPaws: !draft.pack.isFigure, trigger: react)
        }
    }

    private var displayName: String { name.isEmpty ? "your new Awan" : name }

    private var reactionBar: some View {
        HStack(spacing: 6) {
            ForEach(CharacterReaction.allCases) { r in
                Button { react.fire(r) } label: {
                    Image(systemName: r.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(SettingsStyle.navText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(Capsule().fill(Color.white.opacity(0.05)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(r.title)
                .accessibilityLabel(r.title)
            }
        }
    }

    private var backdrop: Color { CharacterCatalog.backgroundColor(draft) }

    private var lookLabel: String { "\(draft.pack.title) · \(CharacterCatalog.presetName(draft))" }

    // MARK: Packs

    private var packs: some View {
        VStack(alignment: .leading, spacing: 12.5) {
            sectionTitle("Character packs")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(CharacterPack.allCases) { pack in
                            PackCard(pack: pack, selected: draft.pack == pack) { switchPack(pack) }
                                .frame(width: 255)
                                .id(pack)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .onAppear { proxy.scrollTo(draft.pack, anchor: .leading) }
                .onChange(of: draft.pack) { _, p in withAnimation(Theme.spring) { proxy.scrollTo(p, anchor: .center) } }
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.awan(15.5, .semibold)).foregroundStyle(Theme.text)
    }

    private func switchPack(_ pack: CharacterPack) {
        guard pack != draft.pack else { return }
        withAnimation(Theme.spring) {
            draft = CharacterCatalog.defaultLook(for: pack, seed: slug, hue: agent?.baseHue ?? 0.57)
        }
    }

    // MARK: Presets

    private let grid = Array(repeating: GridItem(.flexible(), spacing: 11.25), count: 5)
    private let partGrid = [GridItem(.adaptive(minimum: 58, maximum: 80), spacing: 8)]

    private var presets: some View {
        VStack(alignment: .leading, spacing: 12.5) {
            sectionTitle("Characters")
            LazyVGrid(columns: grid, spacing: 11.25) {
                ForEach(CharacterCatalog.presetLooks(draft.pack), id: \.id) { p in
                    PresetTile(appearance: p.look, title: p.name, selected: draft.preset == p.id) { set(p.look) }
                        .id("\(draft.pack.rawValue)-\(p.id)")
                }
            }
            .id(draft.pack)
        }
    }

    private func set(_ look: CharacterAppearance) {
        withAnimation(Theme.spring) { draft = look }
    }

    /// Reference: one 520×50 row (avatar, "Your look", check when it's the current look).
    private var yourLook: some View {
        Button { var c = draft; c.preset = nil; set(c) } label: {
            HStack(spacing: 12) {
                AgentAvatar(appearance: draft, size: 32)
                Text("Your look").font(.awan(15, .medium)).foregroundStyle(Theme.text)
                Spacer()
                if draft.preset == nil { SettingsCheckBadge(size: 20) }
            }
            .padding(.leading, 9).padding(.trailing, 18)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(draft.preset == nil ? Theme.lime : SettingsStyle.stroke, lineWidth: draft.preset == nil ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
    }

    // MARK: Expression

    /// Laid out like the reference's "Cloud pattern" grid (5 columns of 95×111 tiles): Awan's faces.
    private var expressions: some View {
        VStack(alignment: .leading, spacing: 12.5) {
            sectionTitle("Expression")
            LazyVGrid(columns: grid, spacing: 11.25) {
                ForEach(CharacterExpression.allCases) { e in
                    PartTile(selected: (draft.expression ?? .idle) == e, help: e.title, height: 111) {
                        if draft.pack.isFigure {
                            FigurePortrait(appearance: draft, pose: FigurePose(expression: e, showExtras: false), framing: .face)
                                .padding(8)
                        } else {
                            CloudCreature(appearance: draft, glow: false, expression: e).frame(width: 72)
                        }
                    } action: { edit { $0.expression = e == .idle ? nil : e } }
                }
            }
        }
    }

    // MARK: Awan Clouds — custom colour (reference: ten 26 pt dots on a 44 pt pitch)

    private var cloudColor: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Cloud color")
            HStack(spacing: 18) {
                ForEach(CharacterCatalog.cloudPresets, id: \.id) { p in
                    let on = draft.preset == nil && abs(draft.cloudHue - p.hue) < 0.005
                    Button { edit { $0.cloudHue = p.hue } } label: {
                        ColorDot(color: Color(hue: p.hue, saturation: min(0.62, p.saturation + 0.12), brightness: p.brightness * 0.92), selected: on)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cloud color \(p.name)")
                }
            }
            .padding(.leading, 5)
        }
    }

    // MARK: Figure packs — custom parts

    private var figureControls: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 12.5) {
                label("Hair", CharacterCatalog.hairstyleNames[CharacterCatalog.wrap(draft.hairstyle, CharacterCatalog.hairstyleCount)],
                      trailing: "\(CharacterCatalog.hairstyleCount) styles")
                LazyVGrid(columns: partGrid, spacing: 8) {
                    ForEach(0..<CharacterCatalog.hairstyleCount, id: \.self) { i in
                        PartTile(tint: backdrop, selected: draft.hairstyle == i, help: CharacterCatalog.hairstyleNames[i]) {
                            FigurePortrait(appearance: with { $0.hairstyle = i; $0.expression = nil }, pose: FigurePose(expression: .idle, showExtras: false), framing: .face)
                                .padding(3)
                        } action: { edit { $0.hairstyle = i } }
                    }
                }
            }
            swatchSection("Hair color", CharacterCatalog.hairColors, selected: draft.hairColor) { i in edit { $0.hairColor = i } }
            swatchSection(draft.pack == .gebu ? "Body color" : "Skin tone", draft.pack == .gebu ? CharacterCatalog.gebuBodies : CharacterCatalog.skinTones,
                          selected: draft.skinTone) { i in edit { $0.skinTone = i } }
            if draft.pack.faceStyle != .dot {
                swatchSection("Eyes", CharacterCatalog.eyeColors, selected: draft.eyeColor) { i in edit { $0.eyeColor = i } }
            }
            VStack(alignment: .leading, spacing: 12.5) {
                label("Outfit", CharacterCatalog.outfitNames[CharacterCatalog.wrap(draft.outfitStyle, CharacterCatalog.outfitCount)],
                      trailing: "\(CharacterCatalog.outfitCount) styles")
                LazyVGrid(columns: partGrid, spacing: 8) {
                    ForEach(0..<CharacterCatalog.outfitCount, id: \.self) { i in
                        PartTile(tint: backdrop, selected: draft.outfitStyle == i, help: CharacterCatalog.outfitNames[i]) {
                            FigurePortrait(appearance: with { $0.outfitStyle = i }, pose: FigurePose(expression: .idle, showExtras: false), framing: .outfit)
                        } action: { edit { $0.outfitStyle = i } }
                    }
                }
            }
            swatchSection("Outfit color", CharacterCatalog.outfitColors, selected: draft.outfitColor) { i in edit { $0.outfitColor = i } }
            swatchSection("Accent", CharacterCatalog.accentColors, selected: draft.accentColor) { i in edit { $0.accentColor = i } }
            swatchSection("Avatar background", CharacterCatalog.backgrounds, selected: draft.background) { i in edit { $0.background = i } }
        }
    }

    private func label(_ title: String, _ value: String?, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            sectionTitle(title)
            if let value {
                Text("· \(value)").font(.awan(13, .medium)).foregroundStyle(SettingsStyle.navText)
            }
            Spacer()
            if let trailing { Text(trailing).font(.awan(12)).foregroundStyle(SettingsStyle.dim) }
        }
    }

    private func with(_ change: (inout CharacterAppearance) -> Void) -> CharacterAppearance {
        var c = draft
        change(&c)
        return c
    }

    private func edit(_ change: (inout CharacterAppearance) -> Void) {
        var c = draft
        change(&c)
        c.preset = nil
        set(c)
    }

    private func swatchSection(_ title: String, _ colors: [Color], selected: Int, pick: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle(title)
            HStack(spacing: 18) {
                ForEach(Array(colors.enumerated()), id: \.offset) { i, color in
                    Button { pick(i) } label: {
                        ColorDot(color: color, selected: CharacterCatalog.wrap(selected, colors.count) == i)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(i + 1)")
                }
            }
            .padding(.leading, 5)
        }
    }
}

/// A 26 pt colour dot; selected = a 2 pt ring 3 pt outside it.
private struct ColorDot: View {
    let color: Color
    let selected: Bool
    var body: some View {
        Circle().fill(color)
            .frame(width: 26, height: 26)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 1))
            .padding(4)
            .overlay(Circle().strokeBorder(selected ? Theme.lime : .clear, lineWidth: 2))
            .padding(-4)
            .contentShape(Circle())
    }
}

// MARK: - Pieces

/// Reference pack tile: 255×106, three overlapping avatars centred up top, the pack name under them;
/// selected = 2 pt ring + check badge.
private struct PackCard: View {
    let pack: CharacterPack
    let selected: Bool
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        let cluster = CharacterCatalog.packCluster(pack)
        Button(action: action) {
            VStack(spacing: 11) {
                HStack(spacing: -14) {
                    AgentAvatar(appearance: cluster[0], size: 40)
                    AgentAvatar(appearance: cluster[1], size: 40)
                    AgentAvatar(appearance: cluster[2], size: 40)
                }
                Text(pack.title).font(.awan(13, .semibold)).foregroundStyle(Theme.text)
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 106)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Color(hex: 0x33312C) : (hovering ? Color.white.opacity(0.05) : Color.white.opacity(0.025))))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? Theme.lime : SettingsStyle.stroke, lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected { SettingsCheckBadge(size: 19).padding(7) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(pack.tagline)
        .accessibilityLabel("\(pack.title) pack. \(pack.tagline)")
    }
}

/// Reference character tile: 95×138, dark card, the character up top, name (15 semibold) at the bottom.
private struct PresetTile: View {
    let appearance: CharacterAppearance
    let title: String
    let selected: Bool
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                CharacterFigure(appearance: appearance, mood: .idle)
                    .frame(width: appearance.pack.isFigure ? 78 : 82, height: appearance.pack.isFigure ? 84 : 66)
                    .padding(.top, appearance.pack.isFigure ? 10 : 18)
                Spacer(minLength: 0)
                Text(title).font(.awan(14.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 138)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hovering ? Color(hex: 0x2E2E2B) : Color(hex: 0x272725)))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? Theme.lime : SettingsStyle.stroke, lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected { SettingsCheckBadge(size: 19).padding(7) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.snappy, value: hovering)
        .help(title)
    }
}

/// A picker tile (hair, outfit, expression) — reference "Cloud pattern" tile: dark card, radius 14,
/// selected = 2 pt ring + check badge.
private struct PartTile<Content: View>: View {
    var tint: Color? = nil
    let selected: Bool
    let help: String
    var height: CGFloat? = nil
    @ViewBuilder let content: () -> Content
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Color(hex: 0x33312C) : (hovering ? Color(hex: 0x2E2E2B) : Color(hex: 0x272725)))
                if let tint { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(hovering ? 0.42 : 0.3)) }
                content()
            }
            .frame(height: height)
            .aspectRatio(height == nil ? 1 : nil, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? Theme.lime : SettingsStyle.stroke, lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected { SettingsCheckBadge(size: 19).padding(7) }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Rainbow track (in the cloud pastel treatment) with a draggable knob.
struct HueSlider: View {
    @Binding var hue: Double

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.1).map { Color.pastel(hue: $0, saturation: 0.5, brightness: 0.97) },
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
                Circle()
                    .fill(Color.pastel(hue: hue, saturation: 0.5, brightness: 0.97))
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .frame(width: h + 4, height: h + 4)
                    .offset(x: CGFloat(hue) * (w - h - 4))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                hue = min(1, max(0, Double((v.location.x - h / 2) / max(1, w - h))))
            })
        }
        .accessibilityLabel("Cloud color")
        .accessibilityValue("\(Int(hue * 360)) degrees")
    }
}
