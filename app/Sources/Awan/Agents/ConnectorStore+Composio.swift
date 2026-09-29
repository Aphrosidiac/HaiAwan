import AppKit

/// `POST /v1/composio/session`: where the runtime reaches the user's Composio apps. `mcpUrl` is Awan's own proxy
/// (`<api>/mcp/composio`), authenticated by the env var named in `bearerTokenEnvVar` (the user's Awan token).
/// `headers` are extra header values; they only ever travel as environment variables, never in config.toml.
struct ComposioSession: Codable, Equatable {
    var mcpUrl: String
    var bearerTokenEnvVar: String?
    var headers: [String: String]
    var toolkits: [String]

    init(mcpUrl: String, bearerTokenEnvVar: String?, headers: [String: String] = [:], toolkits: [String] = []) {
        self.mcpUrl = mcpUrl
        self.bearerTokenEnvVar = bearerTokenEnvVar
        self.headers = headers
        self.toolkits = toolkits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mcpUrl = try c.decode(String.self, forKey: .mcpUrl)
        bearerTokenEnvVar = try c.decodeIfPresent(String.self, forKey: .bearerTokenEnvVar)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        toolkits = try c.decodeIfPresent([String].self, forKey: .toolkits) ?? []
    }
}

/// Composio side of ConnectorStore (see the contract at the top of ConnectorStore.swift).
extension ConnectorStore {
    /// Composio's Google slugs → Awan's first-party ids (for de-duplicating the merged catalogue).
    static let composioGoogleSlugs: [String: String] = [
        "gmail": "gmail", "googlecalendar": "google-calendar", "googledrive": "google-drive",
        "googledocs": "google-docs", "googlesheets": "google-sheets",
    ]

    func applyServerFeatures(composio: Bool, awanGoogle: Bool) {
        composioEnabled = composio
        awanGoogleEnabled = awanGoogle
        if !composio { composioCatalog = [] }
    }

    /// What Settings → Integrations lists. Without Composio it is Awan's catalogue. With it:
    /// - Google: Awan-hosted when the server has Google set up, otherwise Composio's Google toolkits;
    /// - a Composio toolkit replaces one of ours with the same id (Composio then holds the OAuth);
    /// - local items (Obsidian) always stay ours.
    var mergedCatalog: [IntegrationDTO] {
        guard composioEnabled, !composioCatalog.isEmpty else { return catalog }
        let composioIDs = Set(composioCatalog.map(\.id))
        let composioGoogle = Set(composioCatalog.compactMap { Self.composioGoogleSlugs[$0.id] })
        let ours = catalog.filter { item in
            if item.auth == "local" { return true }
            if item.auth == Self.awanGoogleAuth { return awanGoogleEnabled || !composioGoogle.contains(item.id) }
            return !composioIDs.contains(item.id)
        }
        let keptIDs = Set(ours.map(\.id))
        let theirs = composioCatalog.filter { item in
            if Self.composioGoogleSlugs[item.id] != nil && awanGoogleEnabled { return false }
            return !keptIDs.contains(item.id)
        }
        return ours + theirs
    }

    private struct ToolkitDTO: Decodable {
        var slug: String
        var name: String
        var description: String
        var logo: String?
        var categories: [String]
    }

    /// `GET /v1/composio/toolkits` → catalogue items (auth "composio").
    func loadComposioCatalog() async {
        guard composioEnabled else { return }
        struct R: Decodable { var toolkits: [ToolkitDTO] }
        do {
            let data = try await apiCall("v1/composio/toolkits", "GET", nil)
            setComposioCatalog(try JSONDecoder().decode(R.self, from: data).toolkits.map {
                (slug: $0.slug, name: $0.name, description: $0.description, logo: $0.logo, category: $0.categories.first ?? "")
            })
        } catch {
            Log.error("integrations: Composio catalogue failed — \(error.localizedDescription)")
        }
    }

    /// Split out for snapshots and the self-test.
    func setComposioCatalog(_ items: [(slug: String, name: String, description: String, logo: String?, category: String)]) {
        composioCatalog = items.map {
            IntegrationDTO(id: $0.slug, name: $0.name, description: $0.description.isEmpty ? "Connect \($0.name) through Composio." : $0.description,
                           url: nil, auth: Self.composioAuth, icon: Self.composioSymbol($0.category), category: $0.category.lowercased(), logo: $0.logo)
        }
    }

    static func composioSymbol(_ category: String) -> String {
        let c = category.lowercased()
        if c.contains("crm") || c.contains("sales") { return "person.2" }
        if c.contains("market") || c.contains("social") { return "megaphone" }
        if c.contains("commun") || c.contains("chat") { return "bubble.left.and.bubble.right" }
        if c.contains("dev") || c.contains("code") { return "chevron.left.forwardslash.chevron.right" }
        if c.contains("financ") || c.contains("account") || c.contains("payment") { return "creditcard" }
        if c.contains("design") { return "paintpalette" }
        if c.contains("document") || c.contains("note") { return "doc.text" }
        if c.contains("calendar") || c.contains("schedul") { return "calendar" }
        if c.contains("mail") { return "envelope" }
        if c.contains("storage") || c.contains("file") { return "externaldrive" }
        if c.contains("analytic") { return "chart.bar" }
        return "square.grid.2x2"
    }

    /// "Connect" for a Composio toolkit: ask Awan's server for Composio's hosted page and open it. The row waits in
    /// `needsSignIn` until `awan://connectors?connected=<slug>&source=composio` arrives.
    func connectComposio(_ item: IntegrationDTO) async {
        upsertComposio(item.id, name: item.name, status: "needsSignIn", detail: "Finish connecting \(item.name) in your browser…")
        struct Body: Encodable { var toolkit: String; var redirect: String }
        struct R: Decodable { var redirectUrl: String }
        do {
            let data = try await apiCall("v1/composio/connect", "POST", Body(toolkit: item.id, redirect: "awan://connectors"))
            let r = try JSONDecoder().decode(R.self, from: data)
            guard let url = URL(string: r.redirectUrl), url.scheme == "https" else { throw APIError.server(502, "Bad connect URL") }
            openURL(url)
        } catch {
            let reason: String
            if case let APIError.server(code, _) = error, code == 501 {
                reason = "Composio isn't set up on this Awan server yet"
            } else {
                reason = error.localizedDescription
            }
            setStatus(item.id, "rejected", detail: reason)
        }
    }

    private func upsertComposio(_ id: String, name: String, status: String, detail: String) {
        if let i = connectors.firstIndex(where: { $0.id == id }) {
            connectors[i] = Connector(id: id, name: name, url: nil, command: nil, auth: Self.composioAuth, status: status, addedAt: connectors[i].addedAt)
        } else {
            connectors.append(Connector(id: id, name: name, url: nil, command: nil, auth: Self.composioAuth, status: status))
        }
        setStatus(id, status, detail: detail)
    }

    /// `awan://connectors?source=composio&connected=<slug>` (or `&error=…&toolkit=<slug>`). Only a toolkit that is in
    /// Composio's catalogue or was waiting for a Composio connect can be marked connected this way.
    func handleComposioReturn(_ items: [URLQueryItem]) -> String {
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        let known = { (slug: String) in
            self.composioCatalog.contains { $0.id == slug } || self.connectors.contains { $0.id == slug && $0.auth == Self.composioAuth }
        }
        let name = { (slug: String) in self.composioCatalog.first { $0.id == slug }?.name ?? self.connectors.first { $0.id == slug }?.name ?? slug }
        if let error = value("error") {
            let slug = value("toolkit") ?? ""
            guard known(slug) else { return "Nothing was connected." }
            let why: String
            switch error {
            case "not_active": why = "Not confirmed yet. Press Connect to try again."
            case "cancelled", "access_denied": why = "Sign-in was cancelled"
            default: why = "Didn't finish connecting (\(error))"
            }
            upsertComposio(slug, name: name(slug), status: "needsSignIn", detail: why)
            return "\(name(slug)) wasn't connected."
        }
        let slugs = (value("connected") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter(known)
        guard !slugs.isEmpty else { return "Nothing new was connected." }
        for slug in slugs { upsertComposio(slug, name: name(slug), status: "connected", detail: "Connected through Composio") }
        return "\(slugs.map(name).joined(separator: ", ")) connected. Your Awans can use \(slugs.count == 1 ? "it" : "them") on their next task."
    }

    /// Mirrors `GET /v1/composio/connections` onto the local rows (connected elsewhere, revoked elsewhere).
    func refreshComposioStatus() async {
        guard composioEnabled else { return }
        struct R: Decodable {
            struct T: Decodable { var connected: Bool }
            var toolkits: [String: T]
        }
        do {
            let data = try await apiCall("v1/composio/connections", "GET", nil)
            applyComposioStatus(try JSONDecoder().decode(R.self, from: data).toolkits.mapValues(\.connected))
        } catch {
            Log.error("integrations: Composio status refresh failed — \(error.localizedDescription)")
        }
    }

    /// Split out for the self-test: toolkit slug → connected.
    func applyComposioStatus(_ toolkits: [String: Bool]) {
        for (slug, ok) in toolkits.sorted(by: { $0.key < $1.key }) where ok {
            let row = connectors.first { $0.id == slug }
            if row == nil {
                upsertComposio(slug, name: composioCatalog.first { $0.id == slug }?.name ?? slug, status: "connected", detail: "Connected through Composio")
            } else if row?.auth == Self.composioAuth && row?.status != "connected" {
                setStatus(slug, "connected", detail: "Connected through Composio")
            }
        }
        for c in connectors where c.auth == Self.composioAuth && c.status == "connected" && toolkits[c.id] != true {
            setStatus(c.id, "needsSignIn", detail: "The connection ended. Press Connect to link it again.")
        }
        if !hasComposioConnection { composioSession = nil }
    }

    var hasComposioConnection: Bool { connectors.contains { $0.auth == Self.composioAuth && $0.status == "connected" } }

    /// Before each runtime start: fetch (or drop) the session CodexConfig writes as `[mcp_servers.composio]`.
    @discardableResult
    func prepareComposioSession() async -> ComposioSession? {
        guard hasComposioConnection else {
            composioSession = nil
            return nil
        }
        do {
            let data = try await apiCall("v1/composio/session", "POST", [String: String]())
            composioSession = try JSONDecoder().decode(ComposioSession.self, from: data)
        } catch {
            Log.error("integrations: Composio session failed — \(error.localizedDescription)")
            composioSession = nil
        }
        return composioSession
    }

    /// `AWAN_COMPOSIO_HEADER_<NAME>`: the env var that carries one extra Composio header's value.
    nonisolated static func composioHeaderEnvVar(_ header: String) -> String {
        "AWAN_COMPOSIO_HEADER_" + header.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }

    /// What CodexConfig renders as `[mcp_servers.composio]` (nil → no block): only with ≥1 Composio connection.
    var composioServerConfig: CodexConfig.ComposioServer? {
        guard hasComposioConnection, let s = composioSession else { return nil }
        return CodexConfig.ComposioServer(
            url: s.mcpUrl, bearerTokenEnvVar: s.bearerTokenEnvVar,
            headerEnvVars: Dictionary(uniqueKeysWithValues: s.headers.keys.map { ($0, Self.composioHeaderEnvVar($0)) })
        )
    }
}
