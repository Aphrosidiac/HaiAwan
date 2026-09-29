import AppKit

/// OWNER: computer-use/integrations builder. Connected integrations and custom MCP connectors.
/// Settings → Integrations (settings builder) renders `catalog` + `connectors` and calls connect/disconnect.
/// The runtime builder appends `mcpServersTOML()` to the Codex config.
///
/// Contract for the runtime builder (Codex launcher):
/// - Append `mcpServersTOML()` to config.toml (it never contains secrets) and merge `mcpEnvironment()` into the
///   Codex process environment. That env carries each connector's key under `AWAN_MCP_<ID>_TOKEN` (named in the
///   TOML via `bearer_token_env_var` / `env_http_headers` / `env_vars`), `OBSIDIAN_VAULT_PATH` when a vault is set,
///   and the computer-use bearer token.
/// - Append `integrationInstructions()` to the model-instructions file so agents know what is connected.
/// - Remote OAuth connectors are written to the TOML while they are `needsSignIn` too, so Codex can run
///   `mcpServer/oauth/login` for them. Set `oauthLoginHandler` to a closure that drives that call; the UI's
///   "Sign in" button calls `signIn(_:)`, which uses it and marks the connector connected on success. After a
///   runtime-side sign-in or sign-out, call `setStatus(_:_:)`.
/// - Rewrite the config when `connectors` or `obsidianVaultPath` changes (both are @Published).
///
/// Status values: checking | connected | needsSignIn | rejected | disconnected | needsSetup (Obsidian before a
/// vault is chosen). `details[id]` holds a one-line human reason for the current status.
///
/// First-party Google toolkits (catalogue `auth == "awan-google"`: gmail, google-calendar, google-drive,
/// google-docs, google-sheets) are MCP servers hosted by Awan's own server at `<api>/mcp/<id>`. "Connect"
/// asks the server for a one-shot Google consent URL and opens it; the browser comes back through
/// `awan://connectors?connected=…` → `handleConnectorsURL(_:)`. They authenticate with the user's Awan token
/// (`bearer_token_env_var = "AWAN_AGENT_TOKEN"`, already in the Codex env), so no key is stored for them.
/// Their status mirrors `GET /v1/connectors` (`refreshAwanStatus()`).
///
/// Composio (when the server's `features.composio` is on): `composioCatalog` holds Composio's toolkits
/// (auth "composio"); `mergedCatalog` is what the Integrations page lists — Awan's own catalogue with Composio's
/// merged in (Awan-hosted Google wins when the server has Google configured, otherwise Composio's Google rows do;
/// otherwise a Composio toolkit replaces a same-id entry of ours). "Connect" opens Composio's hosted page through
/// `POST /v1/composio/connect`; the browser returns via `awan://connectors?connected=<slug>&source=composio`.
/// Status mirrors `GET /v1/composio/connections` (`refreshComposioStatus()`). Every Composio toolkit shares ONE
/// runtime server: `CodexConfig` writes `[mcp_servers.composio]` from `composioSession` (Awan's proxy URL + the
/// Awan token env var; any extra headers travel as env vars) once the user has at least one Composio connection.
@MainActor final class ConnectorStore: ObservableObject {
    static let shared = ConnectorStore()
    @Published var catalog: [IntegrationDTO] = []
    @Published var connectors: [Connector] = []
    @Published private(set) var obsidianVaultPath: String?
    /// Why a connector is in its current state ("Token rejected", "Needs sign-in", the server's error…).
    @Published private(set) var details: [String: String] = [:]
    /// Composio's toolkits as catalogue items (auth "composio"); empty while Composio is off.
    @Published var composioCatalog: [IntegrationDTO] = []
    /// Server features (from `/v1/config`): Composio brokered integrations, Awan-hosted Google.
    @Published var composioEnabled = false
    @Published var awanGoogleEnabled = false
    /// What `POST /v1/composio/session` returned last (nil until the user has a Composio connection).
    @Published var composioSession: ComposioSession?

    /// Set by the runtime: performs Codex's MCP OAuth login for a connector id; returns true once signed in.
    var oauthLoginHandler: ((String) async -> Bool)?

    /// Secret storage (Keychain in the app; swappable for the self-test).
    var secretGet: (String) -> String? = { Keychain.get($0) }
    var secretSet: (String?, String) -> Void = { Keychain.set($0, for: $1) }

    static let reservedIDs: Set<String> = [ComputerUseServer.serverName, "awan", "codex", "composio"]
    static let obsidianID = "obsidian"
    static let awanGoogleAuth = "awan-google"
    static let composioAuth = "composio"
    static let composioServerName = "composio"
    static let awanGoogleToolkits: Set<String> = ["gmail", "google-calendar", "google-drive", "google-docs", "google-sheets"]

    /// Awan's API base for the hosted MCP URLs (swappable for the self-test).
    var awanAPIBase: () -> String = { APIClient.shared.baseURL.absoluteString }
    /// Opens the Google consent page (swappable for the self-test).
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Awan API calls for the Composio broker: (path, method, body) → response JSON (swappable for the self-test).
    var apiCall: (String, String, Encodable?) async throws -> Data = { path, method, body in
        try await APIClient.shared.sendRaw(path, method: method, body: body)
    }
    static let vaultDefaultsKey = "awan.integrations.obsidianVaultPath"
    static var persistenceEnabled = !CommandLine.arguments.contains("--snapshot")

    private let directory: URL?
    private var connectorsURL: URL? { directory?.appendingPathComponent("connectors.json") }
    private var catalogURL: URL? { directory?.appendingPathComponent("integrations-catalog.json") }
    private let defaults: UserDefaults

    /// `directory`: omitted → Application Support/Awan (in-memory in snapshot mode); `.some(nil)` → memory only (self-tests).
    init(directory: URL?? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory ?? (Self.persistenceEnabled ? Paths.support : nil)
        self.defaults = defaults
        load()
    }

    // MARK: Catalogue

    private struct CatalogResponse: Decodable { var integrations: [IntegrationDTO] }

    /// Shows the cached catalogue at once, then refreshes it from `GET /v1/integrations`.
    func loadCatalog() async {
        if catalog.isEmpty, let url = catalogURL, let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode([IntegrationDTO].self, from: data) {
            catalog = cached
        }
        do {
            let r: CatalogResponse = try await APIClient.shared.send("v1/integrations", auth: false)
            catalog = r.integrations
            if let url = catalogURL, let data = try? JSONEncoder().encode(r.integrations) { try? data.write(to: url, options: .atomic) }
        } catch {
            Log.error("integrations: catalogue refresh failed — \(error.localizedDescription)")
        }
    }

    // MARK: Connect / disconnect

    /// Catalogue item → connector. Remote servers are probed with a real MCP `initialize`:
    /// 200 → connected, 401 → needsSignIn (the UI shows "Sign in"), anything else → rejected.
    /// Items without a hosted server (`url == nil`, e.g. Gmail) need `addCustom` with the user's server URL.
    /// Obsidian is local: it becomes connected once `configureObsidian(vaultPath:)` gets a folder.
    func connect(_ integration: IntegrationDTO) async {
        if integration.auth == Self.composioAuth {
            await connectComposio(integration)
            return
        }
        if integration.auth == Self.awanGoogleAuth {
            await connectAwanGoogle([integration])
            return
        }
        if integration.auth == "local" || integration.id == Self.obsidianID {
            if let path = obsidianVaultPath {
                upsert(Connector(id: Self.obsidianID, name: integration.name, url: nil, command: nil, auth: "local", status: "connected"),
                       detail: "Vault: \(path)")
            } else {
                upsert(Connector(id: Self.obsidianID, name: integration.name, url: nil, command: nil, auth: "local", status: "needsSetup"),
                       detail: "Choose your vault folder")
            }
            return
        }
        guard let urlString = integration.url, let url = URL(string: urlString) else {
            details[integration.id] = "No hosted server for \(integration.name) — add your own MCP server URL as a custom connector."
            return
        }
        upsert(Connector(id: integration.id, name: integration.name, url: url.absoluteString, command: nil, auth: "oauth", status: "checking"),
               detail: "Checking…")
        let outcome = await MCPProbe.http(url: url)
        apply(outcome, to: integration.id, sentKey: false)
    }

    /// A custom connector: a remote Streamable-HTTP MCP server (`url`) or a local stdio one (`command`).
    /// `auth`: "oauth" | "api_key" (sent as a bearer token) | "header:<Name>" (key sent in that header) | "none".
    /// The key goes to the Keychain; the connection is checked with a real initialize request.
    func addCustom(name: String, url: String?, command: String?, auth: String, apiKey: String?) async {
        let id = uniqueID(for: name)
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        secretSet((key?.isEmpty ?? true) ? nil : key, secretAccount(id))
        let trimmedURL = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = trimmedURL, !u.isEmpty {
            guard let parsed = URL(string: u), let scheme = parsed.scheme?.lowercased(), scheme == "https" || scheme == "http", parsed.host != nil else {
                upsert(Connector(id: id, name: name, url: u, command: nil, auth: auth, status: "rejected"), detail: "That isn't a valid http(s) URL")
                return
            }
            upsert(Connector(id: id, name: name, url: parsed.absoluteString, command: nil, auth: auth, status: "checking"), detail: "Checking…")
            let outcome = await MCPProbe.http(url: parsed, headers: authHeaders(id: id, auth: auth))
            apply(outcome, to: id, sentKey: secretGet(secretAccount(id)) != nil)
        } else if let c = trimmedCommand, !c.isEmpty {
            upsert(Connector(id: id, name: name, url: nil, command: c, auth: auth, status: "checking"), detail: "Starting…")
            let argv = Self.splitCommand(c)
            guard let exe = argv.first else { return }
            var env: [String: String] = [:]
            if let k = secretGet(secretAccount(id)) { env[Self.envVar(for: id)] = k }
            let outcome = await MCPProbe.stdio(command: exe, args: Array(argv.dropFirst()), env: env)
            apply(outcome, to: id, sentKey: env.isEmpty == false)
        } else {
            details[id] = "Give a server URL or a command"
        }
    }

    func disconnect(_ id: String) async {
        let wasAwanGoogle = connectors.first { $0.id == id }?.auth == Self.awanGoogleAuth
        let wasComposio = connectors.first { $0.id == id }?.auth == Self.composioAuth
        connectors.removeAll { $0.id == id }
        details.removeValue(forKey: id)
        secretSet(nil, secretAccount(id))
        if id == Self.obsidianID {
            obsidianVaultPath = nil
            defaults.removeObject(forKey: Self.vaultDefaultsKey)
        }
        save()
        if wasComposio {
            if !connectors.contains(where: { $0.auth == Self.composioAuth }) { composioSession = nil }
            struct Body: Encodable { var toolkit: String }
            do { _ = try await apiCall("v1/composio/disconnect", "POST", Body(toolkit: id)) } catch {
                Log.error("integrations: Composio disconnect failed — \(error.localizedDescription)")
            }
        }
        // One Google grant backs every Google toolkit: hand it back only when the last one goes.
        if wasAwanGoogle && !connectors.contains(where: { $0.auth == Self.awanGoogleAuth }) && directory != nil {
            do { _ = try await APIClient.shared.sendRaw("v1/connectors/google/disconnect") } catch {
                Log.error("integrations: Google disconnect failed — \(error.localizedDescription)")
            }
        }
    }

    // MARK: Awan-hosted Google toolkits

    private struct StartResponse: Decodable { var url: String }

    /// "Connect" for one or more Google toolkits: mint a consent URL on Awan's server and open it.
    /// The rows wait in `needsSignIn` until `awan://connectors?connected=…` arrives.
    func connectAwanGoogle(_ items: [IntegrationDTO]) async {
        guard !items.isEmpty else { return }
        for item in items {
            upsert(Connector(id: item.id, name: item.name, url: nil, command: nil, auth: Self.awanGoogleAuth, status: "needsSignIn"),
                   detail: "Finish connecting Google in your browser…")
        }
        struct Body: Encodable { var toolkits: [String]; var redirect: String }
        do {
            let r: StartResponse = try await APIClient.shared.send("v1/connectors/google/start", method: "POST",
                                                                   body: Body(toolkits: items.map(\.id), redirect: "awan://connectors"))
            guard let url = URL(string: r.url) else { throw APIError.server(500, "Bad start URL") }
            openURL(url)
        } catch {
            let reason: String
            if case let APIError.server(code, _) = error, code == 501 {
                reason = "Google connectors aren't set up on this Awan server yet"
            } else {
                reason = error.localizedDescription
            }
            for item in items { setStatus(item.id, "rejected", detail: reason) }
        }
    }

    /// `awan://connectors?connected=gmail,google-calendar&missing=google-docs&email=…` (or `?error=…`) from the
    /// OAuth callback page. Marks toolkits connected (the $connectors change reloads the runtime) and returns a
    /// line for a toast.
    @discardableResult
    func handleConnectorsURL(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.first(where: { $0.name == "source" })?.value == Self.composioAuth { return handleComposioReturn(items) }
        func list(_ name: String) -> [String] {
            (items.first { $0.name == name }?.value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { Self.awanGoogleToolkits.contains($0) }
        }
        let email = items.first { $0.name == "email" }?.value
        let connected = list("connected")
        let missing = list("missing")
        let name = { (id: String) in self.catalog.first { $0.id == id }?.name ?? Self.defaultName(id) }
        for id in connected {
            upsert(Connector(id: id, name: name(id), url: nil, command: nil, auth: Self.awanGoogleAuth, status: "connected"),
                   detail: email.map { "Connected as \($0)" } ?? "Connected")
        }
        for id in missing {
            upsert(Connector(id: id, name: name(id), url: nil, command: nil, auth: Self.awanGoogleAuth, status: "needsSignIn"),
                   detail: "Google didn't grant access yet")
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            for c in connectors where c.auth == Self.awanGoogleAuth && c.status == "needsSignIn" {
                details[c.id] = error == "access_denied" ? "Google sign-in was cancelled" : "Google sign-in didn't finish (\(error))"
            }
            return "Google wasn't connected."
        }
        if connected.isEmpty { return missing.isEmpty ? "Nothing new was connected." : "Google didn't grant access to \(missing.map(name).joined(separator: ", "))." }
        return "\(connected.map(name).joined(separator: ", ")) connected. Your Awans can use \(connected.count == 1 ? "it" : "them") on their next task."
    }

    private struct StatusResponse: Decodable {
        struct Toolkit: Decodable { var connected: Bool; var email: String? }
        var toolkits: [String: Toolkit]
    }

    /// Mirrors the server's grant onto the local Google rows (a revoke elsewhere turns them back to "Connect").
    func refreshAwanStatus() async {
        guard connectors.contains(where: { $0.auth == Self.awanGoogleAuth }) else { return }
        do {
            let r: StatusResponse = try await APIClient.shared.send("v1/connectors")
            applyAwanStatus(r.toolkits.mapValues { ($0.connected, $0.email) })
        } catch {
            Log.error("integrations: connector status refresh failed — \(error.localizedDescription)")
        }
    }

    /// Split out for the self-test: toolkit id → (connected, account email).
    func applyAwanStatus(_ toolkits: [String: (Bool, String?)]) {
        for c in connectors where c.auth == Self.awanGoogleAuth {
            guard let (ok, email) = toolkits[c.id] else { continue }
            if ok && c.status != "connected" {
                setStatus(c.id, "connected", detail: email.map { "Connected as \($0)" } ?? "Connected")
            } else if !ok && c.status == "connected" {
                setStatus(c.id, "needsSignIn", detail: "Google access ended")
            }
        }
    }

    private static func defaultName(_ id: String) -> String {
        switch id {
        case "gmail": return "Gmail"
        case "google-calendar": return "Google Calendar"
        case "google-drive": return "Google Drive"
        case "google-docs": return "Google Docs"
        case "google-sheets": return "Google Sheets"
        default: return id
        }
    }

    func isConnected(_ integrationID: String) -> Bool { connectors.contains { $0.id == integrationID && $0.status == "connected" } }

    /// "Sign in" for a remote OAuth connector — runs through the Codex runtime (`oauthLoginHandler`).
    func signIn(_ id: String) async {
        guard connectors.contains(where: { $0.id == id }) else { return }
        guard let handler = oauthLoginHandler else {
            details[id] = "Sign-in runs through Awan's agent runtime, which isn't running yet"
            return
        }
        setStatus(id, "checking", detail: "Waiting for sign-in in your browser…")
        let ok = await handler(id)
        setStatus(id, ok ? "connected" : "needsSignIn", detail: ok ? "Signed in" : "Sign-in didn't finish")
    }

    /// For the runtime: record a status it learned (OAuth finished, a 401 at call time, a sign-out).
    func setStatus(_ id: String, _ status: String, detail: String? = nil) {
        guard let i = connectors.firstIndex(where: { $0.id == id }) else { return }
        connectors[i].status = status
        if let detail { details[id] = detail }
        save()
    }

    /// Re-checks connectors (e.g. at launch). OAuth connectors already marked connected are left alone:
    /// their tokens live in the runtime, so a bare probe would only see a 401.
    func recheckAll() async {
        await refreshAwanStatus()
        await refreshComposioStatus()
        for c in connectors {
            if c.auth == "oauth" && c.status == "connected" { continue }
            if c.auth == "local" || c.auth == Self.awanGoogleAuth || c.auth == Self.composioAuth { continue }
            if let u = c.url.flatMap(URL.init(string:)) {
                let outcome = await MCPProbe.http(url: u, headers: authHeaders(id: c.id, auth: c.auth))
                apply(outcome, to: c.id, sentKey: secretGet(secretAccount(c.id)) != nil)
            }
        }
    }

    // MARK: Obsidian

    /// Points the Obsidian skill at a local vault (the UI picks the folder with NSOpenPanel).
    @discardableResult
    func configureObsidian(vaultPath: String?) -> Bool {
        guard let raw = vaultPath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            obsidianVaultPath = nil
            defaults.removeObject(forKey: Self.vaultDefaultsKey)
            if connectors.contains(where: { $0.id == Self.obsidianID }) { setStatus(Self.obsidianID, "needsSetup", detail: "Choose your vault folder") }
            return false
        }
        let path = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            details[Self.obsidianID] = "That folder doesn't exist"
            return false
        }
        obsidianVaultPath = path
        defaults.set(path, forKey: Self.vaultDefaultsKey)
        let looksLikeVault = FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".obsidian"))
        upsert(Connector(id: Self.obsidianID, name: "Obsidian", url: nil, command: nil, auth: "local", status: "connected"),
               detail: looksLikeVault ? "Vault: \(path)" : "Folder: \(path) (no .obsidian settings folder — plain Markdown works too)")
        return true
    }

    // MARK: Runtime outputs

    /// `[mcp_servers.<id>]` blocks for connected remote/local servers. Secrets are referenced by env var name only.
    func mcpServersTOML() -> String {
        var out = ""
        for c in connectors.sorted(by: { $0.addedAt < $1.addedAt }) {
            guard c.auth != "local" || c.command != nil else { continue } // Obsidian is a skill, not a server
            guard c.auth != Self.composioAuth else { continue } // all Composio toolkits share [mcp_servers.composio] (CodexConfig)
            if c.auth == Self.awanGoogleAuth {
                // Hosted by Awan's server; the user's Awan token (already in the Codex env) is the credential.
                guard c.status == "connected", Self.awanGoogleToolkits.contains(c.id) else { continue }
                let base = awanAPIBase().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                out += "[mcp_servers.\(c.id)]\n"
                out += "url = \(Self.tomlString("\(base)/mcp/\(c.id)"))\n"
                out += "bearer_token_env_var = \(Self.tomlString(CodexConfig.tokenEnvKey))\n"
                out += "startup_timeout_sec = 20.0\ntool_timeout_sec = 120.0\n\n"
                continue
            }
            let usable = c.status == "connected" || (c.status == "needsSignIn" && c.auth == "oauth" && c.url != nil)
            guard usable else { continue }
            let hasKey = secretGet(secretAccount(c.id)) != nil
            out += "[mcp_servers.\(c.id)]\n"
            if let url = c.url {
                out += "url = \(Self.tomlString(url))\n"
                if hasKey {
                    if let header = Self.headerName(c.auth) {
                        out += "env_http_headers = { \(Self.tomlString(header)) = \(Self.tomlString(Self.envVar(for: c.id))) }\n"
                    } else {
                        out += "bearer_token_env_var = \(Self.tomlString(Self.envVar(for: c.id)))\n"
                    }
                }
            } else if let command = c.command {
                let argv = Self.splitCommand(command)
                guard let exe = argv.first else { continue }
                out += "command = \(Self.tomlString(exe))\n"
                out += "args = [\(argv.dropFirst().map(Self.tomlString).joined(separator: ", "))]\n"
                if hasKey { out += "env_vars = [\(Self.tomlString(Self.envVar(for: c.id)))]\n" }
            }
            out += "startup_timeout_sec = 20.0\ntool_timeout_sec = 120.0\n\n"
        }
        return out
    }

    /// Environment for the Codex process: connector keys, the Obsidian vault, and the computer-use token.
    func mcpEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        for c in connectors where c.status == "connected" || c.status == "needsSignIn" {
            if let k = secretGet(secretAccount(c.id)) { env[Self.envVar(for: c.id)] = k }
        }
        if let v = obsidianVaultPath { env["OBSIDIAN_VAULT_PATH"] = v }
        if hasComposioConnection, let s = composioSession {
            for (name, value) in s.headers { env[Self.composioHeaderEnvVar(name)] = value }
        }
        env.merge(ComputerUseServer.shared.environment) { a, _ in a }
        return env
    }

    /// The "External integrations" block appended to the agents' model instructions.
    func integrationInstructions() -> String {
        var lines = ["External integrations:"]
        let live = connectors.filter { $0.status == "connected" && $0.auth != "local" && $0.auth != Self.composioAuth }
        let composioLive = connectors.filter { $0.status == "connected" && $0.auth == Self.composioAuth }
        if !composioLive.isEmpty {
            lines.append("- Composio is attached as the `composio` MCP server for these connected apps (toolkit slugs): " +
                composioLive.map { "`\($0.id)` (\($0.name))" }.joined(separator: ", ") +
                ". Use it first for work in those apps. Write with exact schema keys (COMPOSIO_GET_TOOL_SCHEMAS once when unsure) and read every write back before you call it done.")
        } else if composioEnabled {
            lines.append("- No Composio apps are connected. Awan can connect Slack, Notion, LinkedIn, HubSpot and hundreds more: tell the user to connect the app in Awan → Settings → Integrations.")
        }
        if live.isEmpty && composioLive.isEmpty {
            lines.append("- No app connectors are connected. For account data (mail, calendar, docs, CRMs…) tell the user to connect the app in Awan → Settings → Integrations.")
        } else if !live.isEmpty {
            lines.append("- Connected MCP servers: " + live.map { "`\($0.id)` (\($0.name))" }.joined(separator: ", ") +
                ". Each is its own MCP server: list its tools before using them. Credentials are already set up — never ask the user for tokens or keys.")
        }
        let signIn = connectors.filter { $0.status == "needsSignIn" }
        if !signIn.isEmpty {
            lines.append("- Waiting for sign-in: " + signIn.map(\.name).joined(separator: ", ") + ". If one is needed, tell the user to press Sign in next to it in Awan → Settings → Integrations.")
        }
        lines.append("- A 401 / unauthorized from a connector means its sign-in or key expired: tell the user to reconnect it in Awan → Settings → Integrations.")
        if let v = obsidianVaultPath {
            lines.append("- Obsidian is configured locally. Obsidian vault path: \(v) (also $OBSIDIAN_VAULT_PATH). Use the obsidian skill; that folder is the only vault root.")
        } else {
            lines.append("- Obsidian isn't configured. For vault work, tell the user to choose their vault in Awan → Settings → Integrations → Obsidian.")
        }
        lines.append("- Never run OAuth, browser sign-in, or any CLI login yourself as a fallback, and don't use computer use on Awan's own Settings.")
        lines.append("- Confirm before sending email or messages to other people, deleting data, spending money or changing ad budgets.")
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    nonisolated static func envVar(for id: String) -> String {
        "AWAN_MCP_" + id.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined() + "_TOKEN"
    }

    private func secretAccount(_ id: String) -> String { "connector.\(id)" }

    private static func headerName(_ auth: String) -> String? {
        guard auth.lowercased().hasPrefix("header:") else { return nil }
        let name = auth.dropFirst("header:".count).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private func authHeaders(id: String, auth: String) -> [String: String] {
        guard let key = secretGet(secretAccount(id)) else { return [:] }
        if let h = Self.headerName(auth) { return [h: key] }
        return ["Authorization": "Bearer \(key)"]
    }

    private func apply(_ outcome: MCPProbe.Outcome, to id: String, sentKey: Bool) {
        switch outcome {
        case let .ok(server):
            setStatus(id, "connected", detail: server.map { "Connected (\($0))" } ?? "Connected")
        case .needsAuth:
            if sentKey { setStatus(id, "rejected", detail: "Token rejected") }
            else { setStatus(id, "needsSignIn", detail: "Needs sign-in") }
        case let .rejected(status, message):
            setStatus(id, "rejected", detail: status == 403 && sentKey ? "Token rejected" : message)
        case let .unreachable(message):
            setStatus(id, "rejected", detail: "Can't reach it: \(message)")
        }
    }

    private func upsert(_ c: Connector, detail: String?) {
        if let i = connectors.firstIndex(where: { $0.id == c.id }) {
            var merged = c
            merged.addedAt = connectors[i].addedAt
            connectors[i] = merged
        } else {
            connectors.append(c)
        }
        if let detail { details[c.id] = detail }
        save()
    }

    /// A TOML-safe id: the catalogue id when the name matches one, else a slug; never a reserved name.
    private func uniqueID(for name: String) -> String {
        if let hit = catalog.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id == name.lowercased() }) { return hit.id }
        var slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        slug = String(slug.unicodeScalars.filter { $0.isASCII }.map(Character.init))
        if slug.isEmpty { slug = "connector" }
        if Self.reservedIDs.contains(slug) { slug += "-connector" }
        return slug
    }

    nonisolated static func tomlString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 || ch.value == 0x7F { out += String(format: "\\u%04X", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    /// Shell-like split that honours single/double quotes and backslash escapes.
    nonisolated static func splitCommand(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var escaping = false
        var hasToken = false
        for ch in s {
            if escaping { cur.append(ch); escaping = false; continue }
            if ch == "\\" && quote != "'" { escaping = true; hasToken = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; hasToken = true; continue }
            if ch.isWhitespace {
                if hasToken { out.append(cur); cur = ""; hasToken = false }
                continue
            }
            cur.append(ch)
            hasToken = true
        }
        if hasToken { out.append(cur) }
        return out
    }

    // MARK: Persistence

    private func load() {
        if let url = connectorsURL, let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            connectors = (try? dec.decode([Connector].self, from: data)) ?? []
        }
        if let url = catalogURL, let data = try? Data(contentsOf: url) {
            catalog = (try? JSONDecoder().decode([IntegrationDTO].self, from: data)) ?? []
        }
        if directory != nil, let v = defaults.string(forKey: Self.vaultDefaultsKey), FileManager.default.fileExists(atPath: v) {
            obsidianVaultPath = v
        }
        // A probe interrupted by quitting leaves "checking" behind.
        for i in connectors.indices where connectors[i].status == "checking" { connectors[i].status = "rejected" }
    }

    private func save() {
        guard let url = connectorsURL else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(connectors) { try? data.write(to: url, options: .atomic) }
    }
}
