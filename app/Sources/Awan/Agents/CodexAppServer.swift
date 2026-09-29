import Foundation

struct CodexRPCError: LocalizedError {
    var code: Int
    var message: String
    var errorDescription: String? { message }
    static func runtime(_ m: String) -> CodexRPCError { .init(code: -32000, message: m) }
}

/// One `codex app-server` process shared by every Awan: newline-delimited JSON-RPC over stdio
/// (method/params/id without a "jsonrpc" field, as the app-server speaks it).
/// Methods verified against the reference captures (ClientRequest / ServerNotification / ServerRequest).
@MainActor
final class CodexAppServer {
    static let shared = CodexAppServer()

    enum State: Equatable { case stopped, starting, ready }
    private(set) var state: State = .stopped
    /// Bumps on every launch — Codex threads must be `thread/resume`d once per process.
    private(set) var generation = 0

    /// CodexHome (overridable for the self-test).
    var home: URL { homeOverride ?? Paths.codexHome }
    var homeOverride: URL?
    /// Notifications (method, params).
    var onNotification: ((String, JSON) -> Void)?
    /// Server → client requests. Reply exactly once.
    var onServerRequest: ((_ method: String, _ params: JSON, _ reply: @escaping (Result<JSON, CodexRPCError>) -> Void) -> Void)?
    /// The process went away while we still wanted it.
    var onCrash: ((String) -> Void)?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var startWaiters: [CheckedContinuation<Void, Error>] = []
    private var crashTimes: [Date] = []
    private var stopping = false
    private var stderrTail = ""
    private(set) var launchedToken: String?

    // MARK: - Lifecycle

    func ensureStarted() async throws {
        switch state {
        case .ready: return
        case .starting:
            try await withCheckedThrowingContinuation { startWaiters.append($0) }
            return
        case .stopped: break
        }
        state = .starting
        do {
            let delay = backoffDelay()
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            let extraEnv = await CodexConfig.prepare(home: home)
            try launch(extraEnv: extraEnv)
            _ = try await send("initialize", [
                "clientInfo": ["name": "awan", "title": "Awan", "version": .string(Bundle.main.shortVersion)],
                "capabilities": ["experimentalApi": true, "requestAttestation": false],
            ], timeout: 30)
            write(["method": "initialized"])
            state = .ready
            let waiters = startWaiters
            startWaiters = []
            waiters.forEach { $0.resume() }
            Log.info("codex app-server ready (gen \(generation))")
        } catch {
            state = .stopped
            terminateProcess()
            let waiters = startWaiters
            startWaiters = []
            waiters.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    /// Stops the process (app quit, token change). Pending calls fail.
    func stop() {
        stopping = true
        terminateProcess()
        failPending(CodexRPCError.runtime("The agent runtime was stopped."))
        state = .stopped
        stopping = false
    }

    /// Restart so a new session token / config takes effect (only when nothing is running).
    func restartIfTokenChanged(current: String?) {
        guard state == .ready, launchedToken != current else { return }
        Log.info("codex: session token changed — restarting runtime")
        stop()
    }

    private func backoffDelay() -> Double {
        crashTimes = crashTimes.filter { Date().timeIntervalSince($0) < 120 }
        guard !crashTimes.isEmpty else { return 0 }
        return min(30, pow(2, Double(crashTimes.count - 1)))
    }

    private func launch(extraEnv: [String: String]) throws {
        guard let bin = Paths.codexBinary else {
            throw CodexRPCError.runtime("The agent runtime isn't installed (CodexRuntime is missing from the app).")
        }
        guard let token = AgentAPI.token, !token.isEmpty else {
            throw CodexRPCError.runtime("You're signed out. Sign in to Awan to run agents.")
        }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["app-server"]
        p.currentDirectoryURL = home
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = home.path
        env[CodexConfig.tokenEnvKey] = token
        for (k, v) in extraEnv { env[k] = v }
        // The runtime ships ripgrep etc. in <runtime>/path.
        let pathDir = bin.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("path").path
        env["PATH"] = [pathDir, env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin", "/opt/homebrew/bin", "/usr/local/bin"].joined(separator: ":")
        env["RUST_LOG"] = env["RUST_LOG"] ?? "warn"
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        generation += 1
        let gen = generation
        let reader = LineReader { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(line, gen: gen) } }
        }
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { reader.feed(d) }
        }
        let errLog = Paths.ensure(home.appendingPathComponent("log", isDirectory: true)).appendingPathComponent("app-server.stderr.log")
        if !FileManager.default.fileExists(atPath: errLog.path) { FileManager.default.createFile(atPath: errLog.path, contents: nil) }
        let errFile = try? FileHandle(forWritingTo: errLog)
        errFile?.seekToEndOfFile()
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; try? errFile?.close(); return }
            errFile?.write(d)
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.appendStderr(s) } }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(gen: gen, status: status) } }
        }
        try p.run()
        process = p
        stdinHandle = inPipe.fileHandleForWriting
        launchedToken = token
        Log.info("codex app-server started pid \(p.processIdentifier) CODEX_HOME=\(home.path)")
    }

    private func terminateProcess() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        try? stdinHandle?.close()
        stdinHandle = nil
    }

    private func appendStderr(_ s: String) {
        stderrTail = String((stderrTail + s).suffix(4000))
    }

    private func exited(gen: Int, status: Int32) {
        guard gen == generation else { return }
        process = nil
        stdinHandle = nil
        let wasWanted = !stopping && state != .stopped
        state = .stopped
        let lastErr = stderrTail.components(separatedBy: .newlines).filter { !$0.isEmpty }.suffix(3).joined(separator: " ")
        let msg = "The agent runtime stopped unexpectedly (exit \(status))." + (lastErr.isEmpty ? "" : " \(lastErr.prefix(300))")
        failPending(CodexRPCError.runtime(msg))
        if wasWanted {
            crashTimes.append(Date())
            Log.error("codex app-server exited: \(msg)")
            onCrash?(msg)
        }
    }

    private func failPending(_ error: Error) {
        let p = pending
        pending = [:]
        p.values.forEach { $0.resume(throwing: error) }
    }

    // MARK: - Calls

    /// A client request; starts the runtime if needed.
    func call(_ method: String, _ params: JSON, timeout: Double = 60) async throws -> JSON {
        try await ensureStarted()
        return try await send(method, params, timeout: timeout)
    }

    private func send(_ method: String, _ params: JSON, timeout: Double) async throws -> JSON {
        guard stdinHandle != nil else { throw CodexRPCError.runtime("The agent runtime isn't running.") }
        let id = nextID
        nextID += 1
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.resolve(id, .failure(CodexRPCError.runtime("The agent runtime didn't answer \(method) in time.")))
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            write(["id": .number(Double(id)), "method": .string(method), "params": params])
        }
    }

    private func resolve(_ id: Int, _ result: Result<JSON, Error>) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(with: result)
    }

    func notify(_ method: String, _ params: JSON? = nil) {
        var o: [String: JSON] = ["method": .string(method)]
        if let params { o["params"] = params }
        write(.object(o))
    }

    private func write(_ message: JSON) {
        guard let h = stdinHandle, var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        do { try h.write(contentsOf: data) } catch { Log.error("codex stdin write failed: \(error.localizedDescription)") }
    }

    // MARK: - Incoming

    private func receive(_ line: Data, gen: Int) {
        guard gen == generation, let any = try? JSONSerialization.jsonObject(with: line), let o = any as? [String: Any] else { return }
        let method = o["method"] as? String
        let rawID = o["id"]
        if let method {
            let params = JSON(any: o["params"] ?? NSNull())
            if let rawID {
                // Server → client request.
                let idJSON = JSON(any: rawID)
                guard let handler = onServerRequest else {
                    write(["id": idJSON, "error": ["code": -32601, "message": .string("Awan doesn't handle \(method)")]])
                    return
                }
                var replied = false
                handler(method, params) { [weak self] result in
                    guard !replied, gen == self?.generation else { return }
                    replied = true
                    switch result {
                    case let .success(v): self?.write(["id": idJSON, "result": v])
                    case let .failure(e): self?.write(["id": idJSON, "error": ["code": .number(Double(e.code)), "message": .string(e.message)]])
                    }
                }
            } else {
                onNotification?(method, params)
            }
            return
        }
        // Response.
        guard let id = (rawID as? NSNumber)?.intValue ?? (rawID as? String).flatMap(Int.init) else { return }
        if let err = o["error"] as? [String: Any] {
            resolve(id, .failure(CodexRPCError(code: (err["code"] as? NSNumber)?.intValue ?? -1, message: err["message"] as? String ?? "Codex error")))
        } else {
            resolve(id, .success(JSON(any: o["result"] ?? NSNull())))
        }
    }
}

/// Splits a byte stream into lines (called on the pipe's background queue).
private final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: (Data) -> Void
    init(onLine: @escaping (Data) -> Void) { self.onLine = onLine }

    func feed(_ d: Data) {
        lock.lock()
        buffer.append(d)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< nl]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex ... nl)
        }
        lock.unlock()
        lines.forEach(onLine)
    }
}

extension JSON {
    /// From JSONSerialization output (faster than decoding through Codable for big Codex payloads).
    init(any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]: self = .array(a.map(JSON.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSON.init(any:)))
        default: self = .null
        }
    }

    var int: Int? { double.map { Int($0) } }
    var object: [String: JSON]? { if case let .object(o) = self { return o } else { return nil } }
}
