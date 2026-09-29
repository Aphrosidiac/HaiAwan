import SwiftUI

/// Settings-only tokens, measured on the reference's Settings and
/// re-tinted into FF's warm neutrals at the same luminance. Shared Theme tokens stay untouched.
enum SettingsStyle {
    // Surfaces
    static let content = Color(hex: 0x1E1E1D)         // page background under the header gradient (ref #1E1E1E)
    static let card = Color(hex: 0x292927)            // group card fill (ref #292929)
    static let stroke = Color.white.opacity(0.055)    // card stroke + row dividers (ref #363636 on the card)
    static let navSelected = Color.white.opacity(0.11) // selected nav row (ref #373736 on #1C1C1B)
    static let navHover = Color.white.opacity(0.06)
    static let backPill = Color.white.opacity(0.05)   // ref #2A2A29
    static let divider = Color(hex: 0x2E2E2C)         // sidebar trailing edge (ref #2E2E2D)

    // Text (ref #ECECEF / #9093A0 / #5C5E6A / #4F515A)
    static let title = Theme.text
    static let navText = Color(hex: 0x9A978E)
    static let dim = Color(hex: 0x605E57)
    static let footer = Color(hex: 0x52504A)

    // Type (cap heights matched to the reference; Instrument Sans cap = 0.72 em)
    static let pageTitle = Font.awan(19, .semibold)
    static let pageSubtitle = Font.awan(13.5)
    static let rowTitle = Font.awan(14, .medium)
    static let rowSubtitle = Font.awan(12)
    static let label = Font.awan(11, .semibold)
    static let navItem = Font.awan(14, .medium)
    static let navItemSelected = Font.awan(14, .semibold)

    // Geometry
    static let sidebarWidth: CGFloat = 200            // 199 of sidebar + the 1 pt trailing divider
    static let headerHeight: CGFloat = 75             // fixed header band; pages scroll under it
    static let pagePadding: CGFloat = 25
    static let pageMaxWidth: CGFloat = 620
    static let cardRadius: CGFloat = 14
    static let rowLeading: CGFloat = 14.5
    static let rowTrailing: CGFloat = 13.5
    static let groupSpacing: CGFloat = 12.5
    static let labelGap: CGFloat = 6.3           // card bottom → next section label
}

extension HomePage {
    var isSettings: Bool { if case .settings = self { return true } else { return false } }
    /// Pages that take the full panel width like the reference (New Awan interview).
    var hidesSidebar: Bool { self == .newAwan }
}

/// Caps, tracked, dim — "BEHAVIOR", "SPEECH SPEED".
struct SettingsSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(SettingsStyle.label)
            .tracking(1.6)
            .foregroundStyle(SettingsStyle.dim)
            .lineLimit(1)
    }
}

// MARK: - Settings mode of the Home sidebar

/// Back pill + "Settings", grouped sections with icons, version footer. The list scrolls under
/// the fixed header band and above the footer, like the reference.
struct SettingsSidebar: View {
    @EnvironmentObject var state: AppState
    @Environment(\.homeIsDetached) private var detached

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 19) {
                Button { state.homePage = .home } label: {
                    HStack(spacing: 0) {
                        Image(systemName: "chevron.left").font(.system(size: 11.5, weight: .semibold)).frame(width: 14, alignment: .leading)
                        Text("Back").font(.awan(13, .medium)).fixedSize()
                    }
                    .foregroundStyle(SettingsStyle.navText)
                    .padding(.leading, 9.5)
                    .frame(width: 60.5, height: 30, alignment: .leading)
                    .background(Capsule().fill(SettingsStyle.backPill))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Text("Settings").font(.awan(16.5, .semibold)).foregroundStyle(SettingsStyle.title)
            }
            .padding(.leading, 19)
            .padding(.top, detached ? 36 : 26)
            .frame(height: detached ? 85 : SettingsStyle.headerHeight, alignment: .top)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(groups, id: \.0) { group, sections in
                        if !group.isEmpty {
                            SettingsSectionLabel(group)
                                .padding(.leading, 10)
                                .padding(.top, 12.75)
                                .padding(.bottom, 2.3)
                        }
                        ForEach(sections) { s in
                            SettingsNavRow(section: s, selected: state.homePage == .settings(s)) { state.homePage = .settings(s) }
                        }
                    }
                }
                .padding(.leading, 14.5)
                .padding(.trailing, 16.5)
                .padding(.top, 7.5)
                .padding(.bottom, 8)
            }
            .clipped()

            Text("Awan \(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")
                .font(.awan(11, .medium))
                .foregroundStyle(SettingsStyle.footer)
                .padding(.leading, 24.5)
                .padding(.top, 1)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.trailing, 1)
        .overlay(alignment: .trailing) {
            // 1 pt trailing divider that fades in below the header band.
            LinearGradient(stops: [
                .init(color: SettingsStyle.divider.opacity(0), location: 0),
                .init(color: SettingsStyle.divider.opacity(0), location: 0.135),
                .init(color: SettingsStyle.divider.opacity(0.55), location: 0.14),
                .init(color: SettingsStyle.divider, location: 0.25),
                .init(color: SettingsStyle.divider, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(width: 1)
        }
    }

    private var groups: [(String, [SettingsSection])] {
        let all = DeveloperMode.visibleSections
        return ["", "AWAN", "WORK", "INTERNAL"].map { g in (g, all.filter { $0.group == g }) }
    }
}

struct SettingsNavRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @EnvironmentObject var state: AppState
    @Local private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9.5) {
                Group {
                    if section == .account {
                        UserAvatar(url: state.user?.avatarUrl, name: state.user?.displayName ?? "You", size: 19)
                    } else {
                        Image(systemName: section.symbol).font(.system(size: 13, weight: .semibold))
                    }
                }
                .frame(width: 18)
                Text(section.title).font(selected ? SettingsStyle.navItemSelected : SettingsStyle.navItem)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? SettingsStyle.title : SettingsStyle.navText)
            .padding(.leading, 9.5)
            .frame(height: 41)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? SettingsStyle.navSelected : (hovering ? SettingsStyle.navHover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Fields

/// Search field inside a settings card (reference: 29 pt, white 3 %, radius 9, 11 pt glyph).
struct SettingsSearchField: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 29
    var fill: Color = Color.white.opacity(0.03)
    var fontSize: CGFloat = 14.5
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .medium)).foregroundStyle(SettingsStyle.dim)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder).font(.awan(fontSize)).foregroundStyle(SettingsStyle.dim).allowsHitTesting(false)
                }
                TextField("", text: $text).textFieldStyle(.plain).font(.awan(fontSize)).foregroundStyle(Theme.text)
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(SettingsStyle.dim)
                }.buttonStyle(.plain)
            }
        }
        .padding(.leading, 11).padding(.trailing, 10)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
    }
}

/// Text input inside a settings card (reference dictionary field: 29 pt, white 6 %, radius 9).
struct SettingsInputField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder).font(.awan(14.5)).foregroundStyle(SettingsStyle.navText).allowsHitTesting(false)
            }
            TextField("", text: $text).textFieldStyle(.plain).font(.awan(14.5)).foregroundStyle(Theme.text).onSubmit(onSubmit)
        }
        .padding(.horizontal, 11)
        .frame(height: 29)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}
