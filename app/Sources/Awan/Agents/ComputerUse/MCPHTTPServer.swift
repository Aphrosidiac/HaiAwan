import Foundation
import Network

/// A small MCP server speaking the Streamable HTTP transport: JSON-RPC 2.0 over `POST /mcp` on 127.0.0.1,
/// bearer-token auth, JSON responses (or a single SSE event when the client only accepts event streams).
/// `GET /mcp` (server-initiated stream) is answered 405, which the spec allows. No third-party dependencies.
final class MCPHTTPServer: @unchecked Sendable {
    /// What a JSON-RPC request resolves to.
    enum RPCOutcome {
        case result([String: Any])
        case error(code: Int, message: String)
    }

    /// Handles one JSON-RPC request (method, params, lower-cased HTTP headers). Runs on the server's serial work queue.
    typealias Handler = (_ method: String, _ params: [String: Any], _ headers: [String: String]) -> RPCOutcome

    let token: String
    let path: String
    private(set) var port: UInt16 = 0
    private(set) var sessionID = UUID().uuidString
    private var listener: NWListener?
    private let ioQueue = DispatchQueue(label: "awan.mcp.io")
    private let workQueue: DispatchQueue
    private let handler: Handler
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private let lock = NSLock()

    /// Counters for health reports.
    private(set) var requestCount = 0
    private(set) var rejectedAuthCount = 0

    init(token: String, path: String = "/mcp", workQueue: DispatchQueue, handler: @escaping Handler) {
        self.token = token
        self.path = path
        self.workQueue = workQueue
        self.handler = handler
    }

    /// Binds 127.0.0.1 on a random free port. Returns the port, or nil if the listener failed.
    func start() async -> UInt16? {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: params) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        return await withCheckedContinuation { (cont: CheckedContinuation<UInt16?, Never>) in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let p = listener.port?.rawValue ?? 0
                    self?.port = p
                    if !once.done { once.done = true; cont.resume(returning: p) }
                case .failed, .cancelled:
                    if !once.done { once.done = true; cont.resume(returning: nil) }
                default: break
                }
            }
            listener.start(queue: ioQueue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock(); let all = connections.values; connections.removeAll(); lock.unlock()
        all.forEach { $0.close() }
    }

    private func accept(_ conn: NWConnection) {
        let c = HTTPConnection(conn: conn, queue: ioQueue) { [weak self] req, reply in self?.route(req, reply) }
        let key = ObjectIdentifier(c)
        c.onClose = { [weak self] in
            self?.lock.lock(); self?.connections.removeValue(forKey: key); self?.lock.unlock()
        }
        lock.lock(); connections[key] = c; lock.unlock()
        c.start()
    }

    // MARK: Routing

    private func route(_ req: HTTPRequest, _ reply: @escaping (HTTPResponse) -> Void) {
        let pathOnly = req.target.split(separator: "?").first.map(String.init) ?? req.target
        if req.method == "GET", pathOnly == "/healthz" {
            return reply(.text(200, "ok"))
        }
        guard pathOnly == path else { return reply(.json(404, ["error": "not found"])) }

        // DNS-rebinding guard: a browser page on another origin must never reach this server.
        if let origin = req.headers["origin"], !origin.isEmpty,
           let host = URL(string: origin)?.host, !["127.0.0.1", "localhost", "::1"].contains(host) {
            return reply(.json(403, ["error": "origin not allowed"]))
        }
        if let host = req.headers["host"], !host.isEmpty {
            let name = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }.dropFirst()) : String(host.split(separator: ":").first ?? "")
            guard ["127.0.0.1", "localhost", "::1"].contains(name.lowercased()) else { return reply(.json(403, ["error": "host not allowed"])) }
        }
        guard req.headers["authorization"] == "Bearer \(token)" else {
            lock.lock(); rejectedAuthCount += 1; lock.unlock()
            var r = HTTPResponse.json(401, ["error": "missing or invalid bearer token"])
            r.headers["WWW-Authenticate"] = "Bearer realm=\"awan-computer-use\""
            return reply(r)
        }

        switch req.method {
        case "GET":
            var r = HTTPResponse.text(405, "this server does not open a server-initiated stream")
            r.headers["Allow"] = "POST, DELETE"
            return reply(r)
        case "DELETE":
            sessionID = UUID().uuidString
            return reply(.text(200, ""))
        case "POST":
            break
        default:
            return reply(.text(405, "method not allowed"))
        }

        lock.lock(); requestCount += 1; lock.unlock()
        let parsed = try? JSONSerialization.jsonObject(with: req.body)
        let messages: [[String: Any]]
        let isBatch: Bool
        if let obj = parsed as? [String: Any] { messages = [obj]; isBatch = false }
        else if let arr = parsed as? [[String: Any]] { messages = arr; isBatch = true }
        else {
            return reply(.jsonAny(400, ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]]))
        }

        let acceptsJSON = (req.headers["accept"] ?? "application/json").contains("application/json") || (req.headers["accept"] ?? "").contains("*/*")
        let headers = req.headers
        workQueue.async { [weak self] in
            guard let self else { return }
            var responses: [[String: Any]] = []
            var sawInitialize = false
            for msg in messages {
                guard let method = msg["method"] as? String else { continue } // a client-side response; nothing to do
                let params = msg["params"] as? [String: Any] ?? [:]
                let outcome = self.handler(method, params, headers)
                guard msg.keys.contains("id"), let id = msg["id"] else { continue } // a notification gets no reply
                if method == "initialize" { sawInitialize = true }
                switch outcome {
                case let .result(r): responses.append(["jsonrpc": "2.0", "id": id, "result": r])
                case let .error(code, message): responses.append(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
                }
            }
            if responses.isEmpty { return reply(.text(202, "")) }
            let payload: Any = isBatch ? responses : responses[0]
            var r: HTTPResponse
            if acceptsJSON {
                r = .jsonAny(200, payload)
            } else {
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                r = HTTPResponse(status: 200, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"],
                                 body: Data("event: message\ndata: ".utf8) + data + Data("\n\n".utf8), close: true)
            }
            if sawInitialize { r.headers["Mcp-Session-Id"] = self.sessionID }
            reply(r)
        }
    }
}

// MARK: - HTTP/1.1 plumbing

struct HTTPRequest {
    var method: String
    var target: String
    var headers: [String: String] // lower-cased names
    var body: Data
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
    var close = false

    static func text(_ status: Int, _ s: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(s.utf8))
    }
    static func json(_ status: Int, _ obj: [String: Any]) -> HTTPResponse { jsonAny(status, obj) }
    static func jsonAny(_ status: Int, _ obj: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    func serialized() -> Data {
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                       404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\n"
        var h = headers
        h["Content-Length"] = String(body.count)
        if close { h["Connection"] = "close" }
        for (k, v) in h.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

final class HTTPConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let onRequest: (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void
    private var buffer = Data()
    private var busy = false
    private var closed = false
    var onClose: (() -> Void)?
    static let maxBody = 8 << 20

    init(conn: NWConnection, queue: DispatchQueue, onRequest: @escaping (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void) {
        self.conn = conn
        self.queue = queue
        self.onRequest = onRequest
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    func close() { conn.cancel() }

    private func finish() {
        guard !closed else { return }
        closed = true
        onClose?()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            self.drain()
            if isComplete || error != nil {
                if !self.busy { self.conn.cancel() }
                return
            }
            self.receive()
        }
    }

    /// Parses as many complete requests as the buffer holds, one at a time (responses stay in order).
    private func drain() {
        guard !busy, let req = parseOne() else { return }
        busy = true
        onRequest(req) { [weak self] response in
            guard let self else { return }
            self.queue.async {
                var r = response
                if req.headers["connection"]?.lowercased() == "close" { r.close = true }
                self.conn.send(content: r.serialized(), completion: .contentProcessed { _ in
                    if r.close { self.conn.cancel() }
                })
                self.busy = false
                if !r.close { self.drain() }
            }
        }
    }

    private func parseOne() -> HTTPRequest? {
        let sep = Data("\r\n\r\n".utf8)
        guard let headEnd = buffer.range(of: sep) else { return nil }
        let headData = buffer.subdata(in: buffer.startIndex ..< headEnd.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) else { buffer.removeAll(); return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { buffer.removeAll(); return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let bodyStart = headEnd.upperBound
        var body = Data()
        var consumedTo = bodyStart
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            var idx = bodyStart
            while true {
                guard let lineEnd = buffer.range(of: Data("\r\n".utf8), in: idx ..< buffer.endIndex) else { return nil }
                let sizeLine = String(data: buffer.subdata(in: idx ..< lineEnd.lowerBound), encoding: .utf8) ?? ""
                guard let size = Int(sizeLine.split(separator: ";").first.map(String.init) ?? "", radix: 16) else { buffer.removeAll(); return nil }
                let chunkStart = lineEnd.upperBound
                if size == 0 {
                    // Skip optional trailers up to the final CRLF.
                    guard let end = buffer.range(of: Data("\r\n".utf8), in: chunkStart ..< buffer.endIndex) else { return nil }
                    consumedTo = end.upperBound
                    break
                }
                guard buffer.endIndex >= chunkStart + size + 2 else { return nil }
                body.append(buffer.subdata(in: chunkStart ..< chunkStart + size))
                idx = chunkStart + size + 2
                if body.count > Self.maxBody { buffer.removeAll(); return nil }
            }
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? 0
            if length > Self.maxBody { buffer.removeAll(); conn.cancel(); return nil }
            guard buffer.endIndex - bodyStart >= length else { return nil }
            body = buffer.subdata(in: bodyStart ..< bodyStart + length)
            consumedTo = bodyStart + length
        }
        buffer = buffer.subdata(in: consumedTo ..< buffer.endIndex)
        return HTTPRequest(method: String(requestLine[0]).uppercased(), target: String(requestLine[1]), headers: headers, body: body)
    }
}
