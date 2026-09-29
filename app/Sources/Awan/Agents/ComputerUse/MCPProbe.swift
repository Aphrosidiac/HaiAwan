import Foundation

/// Checks whether an MCP server answers a real `initialize` — over Streamable HTTP or a stdio child process.
/// Used by ConnectorStore to decide Connected / Sign in / Token rejected.
enum MCPProbe {
    enum Outcome: Equatable {
        case ok(server: String?)
        /// 401: the server wants credentials (OAuth sign-in, or the key we sent was refused).
        case needsAuth(challenge: String?)
        case rejected(status: Int, message: String)
        case unreachable(String)
    }

    static let initializeBody: [String: Any] = [
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
                   "clientInfo": ["name": "awan-connector-check", "version": "1.0"]],
    ]

    static func http(url: URL, headers: [String: String] = [:], timeout: TimeInterval = 12) async -> Outcome {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try? JSONSerialization.data(withJSONObject: initializeBody)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 3
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        do {
            // bytes(for:) so an SSE reply doesn't have to finish streaming: the first `data:` line is enough.
            let (bytes, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse else { return .unreachable("no HTTP response") }
            switch http.statusCode {
            case 200 ..< 300:
                var text = ""
                for try await line in bytes.lines {
                    text += line + "\n"
                    if let obj = parseMessage(line), obj["result"] != nil || obj["error"] != nil {
                        return outcome(obj)
                    }
                    if text.count > 1 << 20 { break }
                }
                if let obj = parseMessage(text) { return outcome(obj) }
                return .rejected(status: http.statusCode, message: "answered, but not with an MCP initialize result")
            case 401:
                return .needsAuth(challenge: http.value(forHTTPHeaderField: "WWW-Authenticate"))
            case 403:
                return .rejected(status: 403, message: "the server refused these credentials")
            case 404, 405:
                return .rejected(status: http.statusCode, message: "no Streamable HTTP MCP endpoint at this URL (older SSE-only servers aren't supported)")
            default:
                var body = ""
                for try await line in bytes.lines { body += line; if body.count > 300 { break } }
                return .rejected(status: http.statusCode, message: body.isEmpty ? "HTTP \(http.statusCode)" : String(body.prefix(300)))
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    private static func parseMessage(_ s: String) -> [String: Any]? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("data:") { t = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        guard t.hasPrefix("{"), let d = t.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func outcome(_ obj: [String: Any]) -> Outcome {
        if let r = obj["result"] as? [String: Any] {
            return .ok(server: (r["serverInfo"] as? [String: Any])?["name"] as? String)
        }
        let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "initialize failed"
        return .rejected(status: 200, message: msg)
    }

    /// Spawns a stdio MCP server, sends `initialize` and waits for the reply. The child is always terminated.
    static func stdio(command: String, args: [String], env: [String: String], timeout: TimeInterval = 30) async -> Outcome {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var buffer = Data()
            var done = false
            var cont: CheckedContinuation<Outcome, Never>?
            func finish(_ o: Outcome) {
                lock.lock()
                guard !done, let c = cont else { lock.unlock(); return }
                done = true
                cont = nil
                lock.unlock()
                c.resume(returning: o)
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [command] + args
        var environment = ProcessInfo.processInfo.environment
        // Apps launched from Finder get a bare PATH; add the usual tool locations.
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        env.forEach { environment[$0.key] = $0.value }
        p.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        let state = State()
        let result: Outcome = await withCheckedContinuation { cont in
            state.cont = cont
            stdout.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty { state.finish(.unreachable("the server exited before answering")); return }
                state.lock.lock()
                state.buffer.append(chunk)
                let text = String(decoding: state.buffer, as: UTF8.self)
                state.lock.unlock()
                for line in text.split(separator: "\n") {
                    if let obj = parseMessage(String(line)), obj["id"] as? Int == 1 { state.finish(outcome(obj)); return }
                }
            }
            do {
                try p.run()
            } catch {
                state.finish(.unreachable("couldn't start \(command): \(error.localizedDescription)"))
                return
            }
            if var data = try? JSONSerialization.data(withJSONObject: initializeBody) {
                data.append(0x0A)
                try? stdin.fileHandleForWriting.write(contentsOf: data)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                state.finish(.unreachable("no initialize reply within \(Int(timeout)) s"))
            }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        if p.isRunning { p.terminate() }
        return result
    }
}
