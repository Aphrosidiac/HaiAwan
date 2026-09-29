import AppKit
import Combine

/// Glue between integrations (ConnectorStore) and the Codex runtime:
/// - "Sign in" for an OAuth connector restarts the runtime with the new config, then asks Codex for the
///   MCP authorization URL (`mcpServer/oauth/login`) and opens it in the browser.
/// - Any change to the connector list rewrites the config on the next runtime start (restart when idle).
@MainActor
enum ConnectorRuntimeBridge {
    private static var cancellables = Set<AnyCancellable>()

    static func install() {
        ConnectorStore.shared.oauthLoginHandler = { id in
            do {
                CodexAppServer.shared.stop()
                try await CodexAppServer.shared.ensureStarted()
                let r = try await CodexAppServer.shared.call("mcpServer/oauth/login", ["name": .string(id)], timeout: 60)
                guard let s = r["authorizationUrl"]?.string, let url = URL(string: s) else { return false }
                NSWorkspace.shared.open(url)
                return true
            } catch {
                Log.error("connector sign-in failed for \(id): \(error.localizedDescription)")
                return false
            }
        }
        ConnectorStore.shared.$connectors
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { _ in
                // Pick up new MCP servers without interrupting work: restart only when no Awan is running.
                if AgentStore.shared.runningAgents.isEmpty { CodexAppServer.shared.stop() }
            }
            .store(in: &cancellables)
    }
}
