import SwiftUI
import AppKit

/// Settings → Integrations: your connectors, the catalogue, and custom MCP connectors.
struct IntegrationsSettings: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var store = ConnectorStore.shared
    @Environment(\.settingsScroll) private var scroll
    @Local private var search = ""
    @Local private var form: CustomConnectorDraft? = nil
    @Local private var busy: Set<String> = []
    @Local private var showAll = false

    /// Composio brings hundreds of apps; the page lists the most used first and the rest on request.
    static let collapsedCount = 24

    var body: some View {
        SettingsPageHeader(title: "Integrations", subtitle: "Apps your agents can reach into.")

        HStack(spacing: 8) {
            SettingsSearchField(placeholder: "Search integrations", text: $search, fill: Color.white.opacity(0.065), fontSize: 15)
            Button("Add custom connector") {
                withAnimation(Theme.spring) { form = form == nil ? CustomConnectorDraft() : nil }
            }
            .buttonStyle(.gel(.bone, height: 31, padding: 15, fontSize: 14.5))
        }
        .padding(.bottom, 1.75)
        .id("integrations-top")

        if let draft = form {
            CustomConnectorForm(draft: draft, onCancel: { withAnimation(Theme.spring) { form = nil } }) { d in
                await store.addCustom(name: d.name, url: d.url.isEmpty ? nil : d.url, command: d.commandLine, auth: d.auth.wire, apiKey: d.auth == .apiKey ? d.apiKey : nil)
                withAnimation(Theme.spring) { form = nil }
                state.show("\(d.name) added. Your Awans can use it on their next task.")
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }

        if !connectors.isEmpty {
            SettingsGroup(label: "Your connectors") {
                ForEach(Array(connectors.enumerated()), id: \.element.id) { i, c in
                    connectorRow(c, last: i == connectors.count - 1)
                }
            }
        }

        SettingsGroup(label: search.isEmpty ? "Available integrations" : "Search results", footer: footer) {
            if available.isEmpty {
                Text(emptyText).font(.awan(12.5)).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
            } else {
                let shown = visible
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                    integrationRow(item, last: i == shown.count - 1 && shown.count == available.count)
                }
                if shown.count < available.count {
                    Button {
                        withAnimation(Theme.spring) { showAll = true }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Show all \(available.count) integrations").font(.awan(12.5, .semibold))
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task {
            guard !SettingsEnv.isSnapshot else { return }
            await store.loadCatalog()
            await store.loadComposioCatalog()
            await store.refreshComposioStatus()
        }
    }

    // MARK: Data

    private var connectors: [Connector] {
        guard !search.isEmpty else { return store.connectors }
        return store.connectors.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var available: [IntegrationDTO] {
        let connectedIDs = Set(store.connectors.map(\.id))
        // A Google row the user already has (either route) hides the other route's same app.
        let all = store.mergedCatalog.filter { !connectedIDs.contains($0.id) && !connectedIDs.contains(ConnectorStore.composioGoogleSlugs[$0.id] ?? "\u{0}") }
        guard !search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search) }
    }

    private var visible: [IntegrationDTO] {
        guard search.isEmpty, !showAll, available.count > Self.collapsedCount + 4 else { return available }
        return Array(available.prefix(Self.collapsedCount))
    }

    private var footer: String {
        let custom = "Custom connectors can be any MCP server: a hosted URL or a command on this Mac. Keys stay in your Keychain and only go to your Awans."
        guard store.composioEnabled, !store.composioCatalog.isEmpty else { return custom }
        return "Apps marked “via Composio” connect through Composio’s secure sign-in; Awan never sees your password. " + custom
    }

    private var emptyText: String {
        if !search.isEmpty { return "Nothing matches “\(search)”." }
        if store.catalog.isEmpty { return state.signInState == .signedIn ? "Loading integrations…" : "Sign in to connect integrations." }
        return "You've connected everything we have. Nice."
    }

    // MARK: Rows

    private func connectorRow(_ c: Connector, last: Bool) -> some View {
        HStack(spacing: 12) {
            IntegrationIcon(id: catalogItem(c.id)?.id ?? c.name.lowercased().replacingOccurrences(of: " ", with: "-"), symbol: catalogItem(c.id)?.icon ?? (c.command != nil ? "terminal" : "link"), logo: catalogItem(c.id)?.logo)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.awan(14.5, .medium)).foregroundStyle(Theme.text)
                Text(connectorSubtitle(c))
                    .font(.awan(13)).foregroundStyle(SettingsStyle.dim).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            let hostedConnect = c.auth == ConnectorStore.awanGoogleAuth || c.auth == ConnectorStore.composioAuth
            if !hostedConnect || c.status == "connected" {
                StatusChip(text: statusLabel(c.status), tone: statusTone(c.status))
            }
            if c.auth == ConnectorStore.composioAuth && c.status != "connected" {
                // Composio connect page not finished (or the grant ended): Connect opens it again.
                SmallPillButton(title: busy.contains(c.id) ? "Opening…" : "Connect", tint: Theme.lime) {
                    Task {
                        busy.insert(c.id)
                        let item = catalogItem(c.id)
                            ?? IntegrationDTO(id: c.id, name: c.name, description: "", url: nil, auth: ConnectorStore.composioAuth, icon: "square.grid.2x2", category: "")
                        await store.connect(item)
                        busy.remove(c.id)
                    }
                }
                .disabled(busy.contains(c.id))
            }
            if c.auth == ConnectorStore.awanGoogleAuth && c.status != "connected" {
                // Google toolkits waiting for (or refused) consent: Connect opens Google again.
                SmallPillButton(title: busy.contains(c.id) ? "Opening…" : "Connect", tint: Theme.lime) {
                    Task {
                        busy.insert(c.id)
                        let item = store.catalog.first { $0.id == c.id }
                            ?? IntegrationDTO(id: c.id, name: c.name, description: "", url: nil, auth: ConnectorStore.awanGoogleAuth, icon: "envelope", category: "google")
                        await store.connectAwanGoogle([item])
                        busy.remove(c.id)
                    }
                }
                .disabled(busy.contains(c.id))
            }
            SmallPillButton(title: busy.contains(c.id) ? "Disconnecting…" : "Disconnect") {
                Task {
                    busy.insert(c.id)
                    await store.disconnect(c.id)
                    busy.remove(c.id)
                }
            }
            .disabled(busy.contains(c.id))
        }
        .padding(.leading, 12).padding(.trailing, SettingsStyle.rowTrailing).padding(.vertical, 12)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(SettingsStyle.stroke).frame(height: 1).padding(.leading, 52.5) } }
    }

    private func catalogItem(_ id: String) -> IntegrationDTO? {
        store.mergedCatalog.first { $0.id == id } ?? store.composioCatalog.first { $0.id == id } ?? store.catalog.first { $0.id == id }
    }

    /// Reference row: 66.5 pt, 30 pt logo at the leading edge, title 15 medium + two-line dim
    /// description at x+52, Connect gel 83×32 (bone), divider from the text.
    private func integrationRow(_ item: IntegrationDTO, last: Bool) -> some View {
        HStack(alignment: .center, spacing: 0) {
            IntegrationIcon(id: item.id, symbol: item.icon, logo: item.logo)
                .padding(.trailing, 8)
            VStack(alignment: .leading, spacing: 1.2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.awan(14.5, .medium)).foregroundStyle(Theme.text)
                    if item.auth == ConnectorStore.composioAuth {
                        Text("via Composio").font(.awan(10.5, .medium)).foregroundStyle(SettingsStyle.dim)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Capsule().strokeBorder(SettingsStyle.stroke, lineWidth: 1))
                    }
                }
                Text(item.description).font(.awan(13)).foregroundStyle(SettingsStyle.dim).lineLimit(2).lineSpacing(-1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 40)
            Spacer(minLength: 8)
            if item.auth == "local" {
                Button("Configure") { configureLocal(item) }
                    .buttonStyle(.gel(.bone, height: 32, padding: 13, fontSize: 15))
            } else {
                Button(busy.contains(item.id) ? "Connecting…" : "Connect") { connect(item) }
                    .buttonStyle(.gel(.bone, height: 32, padding: 13, fontSize: 15))
                    .disabled(busy.contains(item.id))
            }
        }
        .padding(.leading, 12).padding(.trailing, SettingsStyle.rowTrailing)
        .padding(.top, 9).padding(.bottom, 10)
        .frame(minHeight: 66.5)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(SettingsStyle.stroke).frame(height: 1).padding(.leading, 52.5) } }
    }

    private func connectorSubtitle(_ c: Connector) -> String {
        if c.auth == ConnectorStore.awanGoogleAuth { return store.details[c.id] ?? "Google account · runs on Awan" }
        if c.auth == ConnectorStore.composioAuth { return store.details[c.id] ?? "Connected through Composio" }
        return c.url ?? c.command ?? (c.auth == "local" ? "Local" : "Custom connector")
    }

    private func connect(_ item: IntegrationDTO) {
        if item.auth == ConnectorStore.awanGoogleAuth || item.auth == ConnectorStore.composioAuth {
            // First-party: Awan's server hosts this MCP server; Google consent opens in the browser.
            Task {
                busy.insert(item.id)
                await store.connect(item)
                busy.remove(item.id)
            }
            return
        }
        guard item.url != nil else {
            // No hosted MCP server we know of — the user brings one.
            withAnimation(Theme.spring) { form = CustomConnectorDraft(name: item.name, urlPlaceholder: "Paste this app's MCP server URL") }
            withAnimation(Theme.spring) { scroll?.scrollTo("integrations-top", anchor: .top) }
            return
        }
        Task {
            busy.insert(item.id)
            await store.connect(item)
            busy.remove(item.id)
        }
    }

    private func configureLocal(_ item: IntegrationDTO) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Vault"
        panel.message = "Choose the folder that holds your \(item.name) notes."
        let icloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents")
        if FileManager.default.fileExists(atPath: icloud.path) { panel.directoryURL = icloud }
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await ObsidianBridge.configure(vaultPath: url.path)
                state.show("\(item.name) vault set. Your Awans can read those notes now.")
            }
        }
    }

    private func statusLabel(_ s: String) -> String {
        switch s {
        case "checking": return "Checking"
        case "connected": return "Connected"
        case "needsSignIn": return "Sign in"
        case "rejected": return "Token rejected"
        case "disconnected": return "Disconnected"
        default: return s.capitalized
        }
    }

    private func statusTone(_ s: String) -> ChipTone {
        switch s {
        case "connected": return .good
        case "needsSignIn": return .warn
        case "rejected": return .bad
        default: return .neutral
        }
    }
}

/// The one place Settings touches the Obsidian path, so switching to the integrations builder's
/// dedicated API is a one-line change.
enum ObsidianBridge {
    static let vaultKey = "awan.integrations.obsidianVault"

    @MainActor
    static func configure(vaultPath: String) async {
        UserDefaults.standard.set(vaultPath, forKey: vaultKey)
        // TODO(integrations): switch to `ConnectorStore.shared.configureObsidian(vaultPath:)` once it lands.
        await ConnectorStore.shared.addCustom(name: "Obsidian", url: nil, command: nil, auth: "local", apiKey: nil)
    }
}

/// Integration logo (reference: the brand logo ~28 pt with no tile; a dim 4-square glyph when there is none).
/// Built-in catalogue apps use the logo bundled in Resources/Logos/<id>.png; Composio logos load over https;
/// anything else gets a brand-neutral SF Symbol.
struct IntegrationIcon: View {
    var id: String? = nil
    let symbol: String
    var logo: String? = nil
    var body: some View {
        let name = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil ? symbol : "square.grid.2x2"
        let glyph = Image(systemName: name).font(.system(size: 17, weight: .regular)).foregroundStyle(SettingsStyle.navText)
        Group {
            if let bundled = Self.bundledLogo(id) {
                Image(nsImage: bundled).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if let logo, let url = URL(string: logo), url.scheme == "https", !SettingsEnv.isSnapshot {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        glyph
                    }
                }
            } else {
                glyph
            }
        }
        .frame(width: 32.5, height: 32)
    }

    private static var logoCache: [String: NSImage] = [:]
    static func bundledLogo(_ id: String?) -> NSImage? {
        guard let id else { return nil }
        if let hit = logoCache[id] { return hit }
        let url = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "Logos")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../Resources/Logos/\(id).png").standardized
        guard let image = NSImage(contentsOf: url) else { return nil }
        logoCache[id] = image
        return image
    }
}

// MARK: - Custom connector form

struct CustomConnectorDraft: Equatable {
    enum Auth: String, CaseIterable { case browser, apiKey, none
        var label: String { self == .browser ? "Sign in with browser" : self == .apiKey ? "API key" : "None" }
        var wire: String { self == .browser ? "oauth" : self == .apiKey ? "api_key" : "none" }
    }
    var name = ""
    var url = ""
    var urlPlaceholder = "https://example.com/mcp"
    var auth: Auth = .browser
    var apiKey = ""
    var command = ""
    var args = ""

    var commandLine: String? {
        let c = command.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return nil }
        let a = args.trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? c : "\(c) \(a)"
    }
}

struct CustomConnectorForm: View {
    @Local private var draft: CustomConnectorDraft
    @Local private var advanced = false
    @Local private var error: String? = nil
    @Local private var saving = false
    let onCancel: () -> Void
    let onAdd: (CustomConnectorDraft) async -> Void

    init(draft: CustomConnectorDraft, onCancel: @escaping () -> Void, onAdd: @escaping (CustomConnectorDraft) async -> Void) {
        _draft = Local(wrappedValue: draft)
        self.onCancel = onCancel
        self.onAdd = onAdd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New connector").font(.awan(15, .semibold)).foregroundStyle(Theme.text)

            field("Name") { SettingsTextField(placeholder: "My tools", text: $draft.name) }
            field("Server URL") { SettingsTextField(placeholder: draft.urlPlaceholder, text: $draft.url, mono: true) }
            if draft.url.hasPrefix("http://") && !draft.url.contains("127.0.0.1") && !draft.url.contains("localhost") {
                Label("This server uses plain http, so its traffic isn't encrypted.", systemImage: "exclamationmark.triangle.fill")
                    .font(.awan(11.5)).foregroundStyle(Theme.warning)
            }
            field("Authentication") {
                PillSegmented(options: CustomConnectorDraft.Auth.allCases.map { ($0, $0.label) }, selection: $draft.auth)
            }
            if draft.auth == .apiKey {
                field("API key") { SettingsTextField(placeholder: "Paste your key", text: $draft.apiKey, secure: true) }
            } else if draft.auth == .browser {
                Text("You'll sign in through your browser after adding it.").font(.awan(11.5)).foregroundStyle(Theme.textTertiary)
            }

            Button { withAnimation(Theme.snappy) { advanced.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(advanced ? 90 : 0))
                    Text("Advanced").font(.awan(12.5, .semibold))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            if advanced {
                VStack(alignment: .leading, spacing: 10) {
                    field("Command on this Mac") { SettingsTextField(placeholder: "npx", text: $draft.command, mono: true) }
                    field("Arguments") { SettingsTextField(placeholder: "-y some-mcp-server --flag value", text: $draft.args, mono: true) }
                    Text("Runs a local MCP server instead of a URL. Everything after the command, quoted like a shell.")
                        .font(.awan(11.5)).foregroundStyle(Theme.textTertiary)
                }
            }

            if let error { Text(error).font(.awan(12)).foregroundStyle(Theme.danger) }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.gel(.bone, height: 32, padding: 16, fontSize: 13))
                Button(saving ? "Adding…" : "Add connector") {
                    guard validate() else { return }
                    saving = true
                    Task { await onAdd(draft); saving = false }
                }
                .buttonStyle(.gel(.lime, height: 32, padding: 16, fontSize: 13))
                .disabled(saving)
            }
        }
        .settingsCard(padding: 18)
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.awan(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private func validate() -> Bool {
        error = nil
        let url = draft.url.trimmingCharacters(in: .whitespaces)
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { error = "Give the connector a name."; return false }
        if url.isEmpty && draft.commandLine == nil { error = "Enter the server's full URL, starting with https://, or a command under Advanced."; return false }
        if !url.isEmpty {
            guard let u = URL(string: url), let scheme = u.scheme, ["http", "https"].contains(scheme), u.host != nil else {
                error = "Enter the server's full URL, starting with https://."; return false
            }
            if u.user != nil || u.password != nil { error = "Take the credentials out of the URL and use the authentication fields."; return false }
        }
        if draft.auth == .apiKey && draft.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            error = "Paste the API key, or pick a different authentication."; return false
        }
        draft.url = url
        return true
    }
}
