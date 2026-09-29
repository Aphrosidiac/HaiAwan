import Foundation
import Security

// MARK: - Secret storage (session token, connector keys)

/// Keychain for properly signed builds. Ad-hoc signed builds (every dev rebuild gets a new code signature)
/// would make macOS ask for the login password each launch to read an item the previous build wrote, so
/// those builds keep secrets in a 0600 file in Application Support instead (the reference also falls back
/// off the Keychain). Same API either way.
enum Keychain {
    static let service = "studio.ffdev.awan"

    /// True when the running binary has a real Team ID (Developer ID / App Store signing).
    static let useKeychain: Bool = {
        if ProcessInfo.processInfo.environment["AWAN_FORCE_KEYCHAIN"] == "1" { return true }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return (dict[kSecCodeInfoTeamIdentifier as String] as? String)?.isEmpty == false
    }()

    private static var fileURL: URL { Paths.support.appendingPathComponent(".secrets.json") }
    private static let lock = NSLock()

    static func set(_ value: String?, for account: String) {
        if useKeychain { keychainSet(value, account); return }
        lock.lock(); defer { lock.unlock() }
        var all = readFile()
        all[account] = value
        if let data = try? JSONSerialization.data(withJSONObject: all) {
            FileManager.default.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    static func get(_ account: String) -> String? {
        if useKeychain { return keychainGet(account) }
        lock.lock(); defer { lock.unlock() }
        return readFile()[account]
    }

    private static func readFile() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return obj
    }

    private static func keychainSet(_ value: String?, _ account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func keychainGet(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case unauthorized
    case quotaExceeded(kind: String, cap: Int)
    case server(Int, String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "You're signed out. Sign in to keep going."
        case let .quotaExceeded(kind, cap):
            return kind == "agent_message"
                ? "You've used all \(cap) agent messages this month. Upgrade Awan to keep going."
                : "You've used all \(cap) talks this month. Upgrade Awan to keep going."
        case let .server(code, msg): return "Awan's server said \(code): \(msg)"
        case let .transport(msg): return msg
        }
    }
}

// MARK: - Client

/// Talks to the Awan API (server/). Every model call goes through here — the app never holds a provider key.
final class APIClient: @unchecked Sendable {
    static let shared = APIClient()

    var baseURL: URL { URL(string: baseURLOverride ?? UserDefaults.standard.string(forKey: Prefs.Key.apiBaseURL) ?? "http://127.0.0.1:8787")! }
    /// Self-tests: talk to this server with this token instead of the signed-in session.
    var baseURLOverride: String?
    var tokenOverride: String?
    var token: String? {
        get { tokenOverride ?? Keychain.get("session") }
        set { Keychain.set(newValue, for: "session") }
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 3600
        return URLSession(configuration: c)
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    func request(_ path: String, method: String = "GET", body: Encodable? = nil, auth: Bool = true) throws -> URLRequest {
        // Build from the string so a query ("library?filter=all") isn't escaped into the path.
        let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        let url = URL(string: base + "/" + (path.hasPrefix("/") ? String(path.dropFirst()) : path)) ?? baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        if auth, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    func send<T: Decodable>(_ path: String, method: String = "GET", body: Encodable? = nil, auth: Bool = true, as: T.Type = T.self) async throws -> T {
        let req = try request(path, method: method, body: body, auth: auth)
        let (data, resp) = try await perform(req)
        try check(resp, data)
        return try decoder.decode(T.self, from: data)
    }

    @discardableResult
    func sendRaw(_ path: String, method: String = "POST", body: Encodable? = nil) async throws -> Data {
        let req = try request(path, method: method, body: body)
        let (data, resp) = try await perform(req)
        try check(resp, data)
        return data
    }

    private func perform(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: req) } catch {
            throw APIError.transport("Can't reach Awan's server (\(baseURL.host ?? "")). \(error.localizedDescription)")
        }
    }

    func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200 ..< 300: return
        case 401: throw APIError.unauthorized
        case 402:
            let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw APIError.quotaExceeded(kind: j?["kind"] as? String ?? "talk", cap: j?["cap"] as? Int ?? 0)
        default:
            let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw APIError.server(http.statusCode, (j?["error"] as? String) ?? String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: Streaming

    /// Server-sent events: yields (event, data-json-string).
    func events(_ path: String, body: Encodable) -> AsyncThrowingStream<(String, String), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try request(path, method: "POST", body: body)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, resp) = try await session.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        try check(resp, data)
                    }
                    var event = "message"
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            continuation.yield((event, line.dropFirst(5).trimmingCharacters(in: .whitespaces)))
                            event = "message"
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Raw byte stream (used for PCM speech).
    func byteStream(_ path: String, body: Encodable) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try request(path, method: "POST", body: body)
                    let (bytes, resp) = try await session.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        try check(resp, data)
                    }
                    var buffer = Data()
                    buffer.reserveCapacity(9600)
                    for try await b in bytes {
                        buffer.append(b)
                        if buffer.count >= 4800 { // 100 ms of 24 kHz PCM16
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Type-erased Encodable so request bodies can be heterogeneous dictionaries or structs.
struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeFn = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}

/// Loose JSON value for bodies built on the fly.
enum JSON: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSON]), array([JSON]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(s): try c.encode(s)
        case let .number(n): try c.encode(n)
        case let .bool(b): try c.encode(b)
        case let .object(o): try c.encode(o)
        case let .array(a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSON? { if case let .object(o) = self { return o[key] } else { return nil } }
    var string: String? { if case let .string(s) = self { return s } else { return nil } }
    var double: Double? { if case let .number(n) = self { return n } else { return nil } }
    var bool: Bool? { if case let .bool(b) = self { return b } else { return nil } }
    var array: [JSON]? { if case let .array(a) = self { return a } else { return nil } }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
}
