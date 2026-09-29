import Foundation

/// OWNER: computer-use builder. A localhost MCP server (Streamable HTTP) that lets agents see and
/// operate Mac apps in the background, behind a per-turn consent gate. The runtime builder writes
/// `[mcp_servers.computer-use]` from `endpoint` + `token` and calls `setApproval` per thread.
///
/// Runtime contract:
/// - `await ensureRunning()` before starting Codex; then append `mcpServerTOML()` to config.toml and pass
///   `environment` (the bearer token under `tokenEnvVar`) to the Codex process. The token is never written to disk.
/// - Observation tools always work. Input tools (click, type_text, set_value, press_key, hotkey, scroll,
///   launch_app, page execute_javascript) are refused until `setApproval(threadID:approved: true)` for the thread
///   whose turn the user approved (or Prefs.alwaysAllowComputerUse). Clear it with `approved: false` when that
///   turn ends. Codex (0.158) sends the app-server thread id as `_meta.threadId` on every tools/call, so the
///   gate is per thread; if a call ever arrives without one, any approved thread opens the gate.
/// - Everything runs in-process (Network.framework + AX + CGEvent + ScreenCaptureKit), so macOS attributes
///   Accessibility / Screen Recording to Awan itself. No helper binary.
@MainActor final class ComputerUseServer {
    static let shared = ComputerUseServer()
    private(set) var endpoint: URL?
    let token = UUID().uuidString
    let enabledTools: [String] = CUToolbox.toolNames

    /// Env var the Codex config names in `bearer_token_env_var`.
    static let tokenEnvVar = "AWAN_COMPUTER_USE_MCP_TOKEN"
    static let serverName = "computer-use"

    let gate = CUGate()
    private var http: MCPHTTPServer?
    private(set) var toolbox: CUToolbox?
    private let workQueue = DispatchQueue(label: "awan.computer-use.work", qos: .userInitiated)

    /// Start (or confirm) the server. Returns false if it can't run.
    func ensureRunning() async -> Bool {
        if http != nil, endpoint != nil { return true }
        if let starting { return await starting.value }
        let task = Task { await start() }
        starting = task
        let ok = await task.value
        starting = nil
        return ok
    }

    private var starting: Task<Bool, Never>?

    private func start() async -> Bool {
        let box = CUToolbox(gate: gate)
        let server = MCPHTTPServer(token: token, workQueue: workQueue) { method, params, headers in
            ComputerUseServer.handle(method: method, params: params, headers: headers, toolbox: box)
        }
        guard let port = await server.start(), port != 0 else {
            Log.error("computer-use: MCP server failed to bind 127.0.0.1")
            return false
        }
        http = server
        toolbox = box
        endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")
        Log.info("computer-use: MCP server on 127.0.0.1:\(port)/mcp")
        return true
    }

    /// Input tools are refused until the user approves computer use for that thread.
    func setApproval(threadID: String, approved: Bool) {
        gate.set(threadID: threadID, approved: approved)
        Log.info("computer-use: approve thread=\(threadID) approved=\(approved) serverUp=\(endpoint != nil)")
    }

    func stop() {
        http?.stop()
        http = nil
        toolbox = nil
        endpoint = nil
    }

    /// Environment for the Codex process (the bearer token lives only here and in memory).
    var environment: [String: String] { [Self.tokenEnvVar: token] }

    /// The `[mcp_servers.computer-use]` block for Codex's config.toml, or nil when the server isn't running.
    func mcpServerTOML() -> String? {
        guard let endpoint else { return nil }
        let tools = enabledTools.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        [mcp_servers.\(Self.serverName)]
        url = "\(endpoint.absoluteString)"
        bearer_token_env_var = "\(Self.tokenEnvVar)"
        startup_timeout_sec = 20.0
        tool_timeout_sec = 120.0
        enabled_tools = [\(tools)]

        """
    }

    // MARK: JSON-RPC

    nonisolated static func handle(method: String, params: [String: Any], headers: [String: String], toolbox: CUToolbox) -> MCPHTTPServer.RPCOutcome {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let supported = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            return .result([
                "protocolVersion": requested.flatMap { supported.contains($0) ? $0 : nil } ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "awan-computer-use", "title": "Awan computer use", "version": CUToolbox.version],
                "instructions": "Operate Mac apps in the background: launch_app → get_window_state → act by element token → get_window_state to verify. Input tools need the user's approval for the turn.",
            ])
        case "ping", "logging/setLevel":
            return .result([:])
        case "tools/list":
            return .result(["tools": CUToolbox.toolSchemas])
        case "tools/call":
            guard let name = params["name"] as? String else { return .error(code: -32602, message: "tools/call needs a name") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let meta = params["_meta"] as? [String: Any]
            let thread = threadID(headers: headers, meta: meta)
            Log.info("computer-use: call \(name) thread=\(thread ?? "-")")
            // AX on our own process only answers on the main thread; that's the self-test's probe window.
            if toolbox.gate.allowSelfTargeting && !Thread.isMainThread {
                var out: [String: Any] = [:]
                DispatchQueue.main.sync { out = toolbox.call(name, args, threadID: thread, meta: meta).mcp }
                return .result(out)
            }
            return .result(toolbox.call(name, args, threadID: thread, meta: meta).mcp)
        case "resources/list", "resources/templates/list", "prompts/list":
            return .result([method.hasPrefix("prompts") ? "prompts" : (method.contains("templates") ? "resourceTemplates" : "resources"): []])
        default:
            if method.hasPrefix("notifications/") { return .result([:]) }
            return .error(code: -32601, message: "method not found: \(method)")
        }
    }

    /// Finds the calling thread id in a header or anywhere in the call's `_meta`.
    nonisolated static func threadID(headers: [String: String], meta: [String: Any]?) -> String? {
        for h in ["x-awan-thread-id", "x-codex-thread-id"] { if let v = headers[h], !v.isEmpty { return v } }
        guard let meta else { return nil }
        // Codex 0.158 sends `_meta.threadId` (the app-server thread id) on every tools/call.
        let keys = ["threadId", "thread_id", "x-codex-thread-id", "conversationId", "conversation_id", "sessionId", "session_id"]
        func search(_ any: Any, depth: Int) -> String? {
            guard depth < 5 else { return nil }
            if let d = any as? [String: Any] {
                for k in keys { if let s = d[k] as? String, !s.isEmpty { return s } }
                for v in d.values { if let s = search(v, depth: depth + 1) { return s } }
            } else if let s = any as? String, s.hasPrefix("{"), let data = s.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) {
                return search(obj, depth: depth + 1)
            }
            return nil
        }
        return search(meta, depth: 0)
    }
}
