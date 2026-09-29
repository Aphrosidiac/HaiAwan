import Foundation

/// Writes the Codex runtime's `config.toml` and model-instructions file into CodexHome.
/// Rewritten on every runtime start so Settings (model lane, effort, connectors, skills) take effect.
///
/// Note: `model_instructions_file` is a TOP-LEVEL key. (The reference wrote it after its
/// `[model_providers.…]` header, which scoped it into that table and silently disabled it.)
@MainActor
enum CodexConfig {
    static let instructionsFileName = "awan-model-instructions.md"
    static let providerID = "awan"
    static let tokenEnvKey = "AWAN_AGENT_TOKEN"
    static var computerUseTokenEnvKey: String { ComputerUseServer.tokenEnvVar }

    struct Inputs {
        var home: URL
        var apiBaseURL: String
        var model: String
        var effort: String
        var agentsRoot: URL
        var computerUse: (url: URL, tools: [String])?
        var skills: [URL]
        var connectorsTOML: String
        var obsidianEnabled: Bool = false
        /// SKILL.md files of the user's active library skills (Skills page), from `SkillLibrary.installUserSkills`.
        var userSkillFiles: [URL] = []
        /// `[mcp_servers.composio]`: present only while the user has at least one Composio connection.
        var composio: ComposioServer? = nil
    }

    /// The single runtime server behind every Composio toolkit. Secrets are named, never written: the bearer
    /// is the env var holding the user's Awan token, and each extra header maps to its own env var.
    struct ComposioServer: Equatable {
        var url: String
        var bearerTokenEnvVar: String?
        var headerEnvVars: [String: String] = [:]
    }

    /// Gathers everything (instructions from the server, skills, computer use, connectors) and writes the files.
    /// Returns the env additions the process needs (computer-use bearer).
    static func prepare(home: URL) async -> [String: String] {
        await refreshInstructions(home: home)
        let skillsDir = Paths.ensure(home.appendingPathComponent("skills", isDirectory: true))
        let skills = SkillLibrary.install(into: skillsDir)
        let userSkillFiles = SkillLibrary.installUserSkills(await SkillsStore.activeForAgents(), into: skillsDir)
        var env: [String: String] = [:]
        var cu: (URL, [String])?
        if await ComputerUseServer.shared.ensureRunning(), let url = ComputerUseServer.shared.endpoint {
            cu = (url, ComputerUseServer.shared.enabledTools)
            env.merge(ComputerUseServer.shared.environment) { _, new in new }
        }
        // Composio: one session for all connected toolkits (Awan's proxy URL), refreshed on every start.
        await ConnectorStore.shared.prepareComposioSession()
        // Connector secrets travel as env vars, never inside config.toml.
        env.merge(ConnectorStore.shared.mcpEnvironment()) { _, new in new }
        if let vault = ConnectorStore.shared.obsidianVaultPath { env["OBSIDIAN_VAULT_PATH"] = vault }
        let prefs = Prefs.shared
        let inputs = Inputs(
            home: home, apiBaseURL: prefs.apiBaseURL, model: prefs.modelLane.isEmpty ? "awan-agent" : prefs.modelLane,
            effort: codexEffort(prefs.reasoningEffort), agentsRoot: Paths.agentsRoot,
            computerUse: cu, skills: skills, connectorsTOML: ConnectorStore.shared.mcpServersTOML(),
            obsidianEnabled: ConnectorStore.shared.obsidianVaultPath != nil,
            userSkillFiles: userSkillFiles,
            composio: ConnectorStore.shared.composioServerConfig
        )
        do {
            try render(inputs).write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        } catch {
            Log.error("codex config write failed: \(error.localizedDescription)")
        }
        return env
    }

    /// Codex accepts minimal | low | medium | high | xhigh.
    static func codexEffort(_ pref: String) -> String {
        switch pref.lowercased().replacingOccurrences(of: " ", with: "") {
        case "minimal", "none": return "minimal"
        case "low": return "low"
        case "high": return "high"
        case "extrahigh", "xhigh", "max": return "xhigh"
        default: return "medium"
        }
    }

    static func render(_ i: Inputs) -> String {
        let h = i.home.path
        var lines: [String] = []
        func kv(_ k: String, _ v: String) { lines.append("\(k) = \(toml(v))") }

        // ── top-level keys (must precede every table) ──
        kv("model", i.model)
        kv("model_reasoning_effort", i.effort)
        lines.append("model_reasoning_summary = \"auto\"")
        // "awan-agent" is unknown to Codex's model table (it logs "fallback model metadata"), so give it
        // a context window; that also keeps auto-compaction working on long-lived Awan threads.
        lines.append("model_context_window = 200000")
        lines.append("model_auto_compact_token_limit = 160000")
        kv("model_provider", providerID)
        kv("model_instructions_file", i.home.appendingPathComponent(instructionsFileName).path)
        lines.append("approval_policy = \"never\"")
        lines.append("sandbox_mode = \"danger-full-access\"")
        lines.append("cli_auth_credentials_store = \"file\"")
        lines.append("mcp_oauth_credentials_store = \"file\"")
        lines.append("check_for_update_on_startup = false")
        kv("log_dir", h + "/log")
        kv("sqlite_home", h + "/sqlite")
        lines.append("")
        lines.append("[history]")
        lines.append("persistence = \"save-all\"")
        lines.append("")
        lines.append("[model_providers.\(providerID)]")
        lines.append("name = \"Awan\"")
        kv("base_url", i.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/agent/openai/v1")
        kv("env_key", tokenEnvKey)
        lines.append("wire_api = \"responses\"")
        lines.append("")
        lines.append("[projects.\(toml(i.agentsRoot.path))]")
        lines.append("trust_level = \"trusted\"")
        lines.append("")
        lines.append("[notice]")
        lines.append("hide_full_access_warning = true")
        lines.append("")
        lines.append("[analytics]")
        lines.append("enabled = false")
        lines.append("")
        // Codex's own ChatGPT-account surfaces are off: Awan brings its own computer use (MCP),
        // integrations (MCP connectors) and has no hosted image tool behind the proxy.
        lines.append("[features]")
        lines.append("multi_agent = true")
        lines.append("apps = false")
        lines.append("plugins = false")
        lines.append("remote_plugin = false")
        lines.append("tool_suggest = false")
        lines.append("computer_use = false")
        lines.append("browser_use = false")
        lines.append("image_generation = false")
        lines.append("memories = false")
        lines.append("fast_mode = false")
        lines.append("")

        if let cu = i.computerUse {
            lines.append("[mcp_servers.computer-use]")
            kv("url", cu.url.absoluteString)
            kv("bearer_token_env_var", computerUseTokenEnvKey)
            lines.append("startup_timeout_sec = 20.0")
            lines.append("tool_timeout_sec = 120.0")
            if !cu.tools.isEmpty { lines.append("enabled_tools = [\(cu.tools.map(toml).joined(separator: ", "))]") }
            lines.append("")
        }
        let connectors = i.connectorsTOML.trimmingCharacters(in: .whitespacesAndNewlines)
        if !connectors.isEmpty {
            lines.append(connectors)
            lines.append("")
        }
        if let c = i.composio {
            lines.append("[mcp_servers.\(ConnectorStore.composioServerName)]")
            kv("url", c.url)
            if let bearer = c.bearerTokenEnvVar, !bearer.isEmpty { kv("bearer_token_env_var", bearer) }
            if !c.headerEnvVars.isEmpty {
                let pairs = c.headerEnvVars.sorted { $0.key < $1.key }.map { "\(toml($0.key)) = \(toml($0.value))" }
                lines.append("env_http_headers = { \(pairs.joined(separator: ", ")) }")
            }
            lines.append("startup_timeout_sec = 30.0")
            lines.append("tool_timeout_sec = 180.0")
            lines.append("")
        }
        // Codex matches skills by their SKILL.md file (a folder path is silently ignored).
        if let dir = i.skills.first?.deletingLastPathComponent() {
            lines.append(SkillLibrary.configTOML(skillsDirectory: dir, obsidianEnabled: i.obsidianEnabled))
            // Codex seeds its own system skills (image generation, plugin tooling…) that have no backend behind
            // Awan's proxy — switch them off so agents never plan around them.
            let system = dir.appendingPathComponent(".system")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: system.path)) ?? [] where !name.hasPrefix(".") {
                let file = system.appendingPathComponent(name).appendingPathComponent("SKILL.md")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                lines.append("[[skills.config]]")
                kv("path", file.path)
                lines.append("enabled = false")
                lines.append("")
            }
        }
        // The user's active library skills (at most 3), by SKILL.md path.
        if !i.userSkillFiles.isEmpty {
            lines.append(SkillLibrary.userSkillsConfigTOML(i.userSkillFiles))
        }
        return lines.joined(separator: "\n")
    }

    /// TOML basic string.
    static func toml(_ s: String) -> String {
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

    // MARK: - Model instructions

    /// Fetches the live instructions (server/src/prompts.ts); keeps the last good copy; falls back to the bundled one.
    static func refreshInstructions(home: URL) async {
        let url = home.appendingPathComponent(instructionsFileName)
        struct R: Decodable { var instructions: String }
        if let r: R = try? await AgentAPI.send("v1/agents/instructions", method: "GET", timeout: 8), !r.instructions.isEmpty {
            try? r.instructions.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? fallbackInstructions.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Bundled copy used only when the server has never been reachable. Keep it in step with the server's.
    static let fallbackInstructions = """
    You are an Awan: a persistent agent inside Awan, FF Dev Studio's Mac companion, running on the user's Mac with a shell, apply_patch for file edits, and any MCP servers the runtime exposes.

    - The developer message names you and your role; stay that agent and speak in the first person. Read AGENTS.md in your workspace first and keep its Notes current (dated lines, no secrets).
    - Files you make go in your workspace: deliverables in output/, scratch in tmp/. Verify your work before you call it done.
    - Use the narrowest route: shell and web first, connected MCP integrations for account-backed apps, the computer-use MCP server only for real GUI work.
    - Confirm before deleting data, sending messages, posting publicly or spending money. If the task hinges on something only the user knows, ask one bundled question and stop.
    - While working, post one-sentence milestone commentary updates.

    End every turn with ONE final message: the answer first (markdown, sized to the deliverable, chat over files), then these metadata blocks, never mentioned in the prose:
    <SUMMARY>One plain spoken sentence under 200 characters.</SUMMARY>
    <NEXT_ACTIONS>
    - One to four input-free follow-up offers under 40 characters
    </NEXT_ACTIONS>
    <DONE_TITLE>Two To Five Words</DONE_TITLE>
    <ARTIFACTS>
    - /absolute/path/of/each/user-facing/file/you/made (omit the block if none; verify each exists)
    </ARTIFACTS>
    For repeating requests add <ROUTINE>{"action":"create","every_minutes":1440,"title":"Two To Four Words","task":"standing instruction without the cadence"}</ROUTINE> (also update/pause/resume/delete by title; minimum 2 minutes).
    When you need computer-use input tools and they are not approved, do everything else, then end with <COMPUTER_USE_REQUEST>first-person ask ending in a question</COMPUTER_USE_REQUEST> and make the SUMMARY the same ask.
    """
}

/// Minimal authenticated calls for the agent runtime. Uses `tokenOverride` (the `--agent-selftest`
/// token) before the Keychain session, and never writes the Keychain.
enum AgentAPI {
    nonisolated(unsafe) static var tokenOverride: String?
    static var token: String? { tokenOverride ?? APIClient.shared.token }

    static func send<T: Decodable>(_ path: String, method: String = "POST", body: Encodable? = nil, timeout: TimeInterval = 60) async throws -> T {
        var req = URLRequest(url: APIClient.shared.baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch {
            throw APIError.transport("Can't reach Awan's server (\(APIClient.shared.baseURL.host ?? "")). \(error.localizedDescription)")
        }
        try APIClient.shared.check(resp, data)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
