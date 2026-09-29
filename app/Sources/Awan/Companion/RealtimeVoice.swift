import AVFoundation
import Foundation

// Realtime voice (optional path). When GET /v1/config says features.realtime, push-to-talk turns go to
// OpenAI Realtime over a WebSocket instead of STT → chat → TTS:
//   POST /v1/realtime/session → ephemeral client secret → wss://api.openai.com/v1/realtime
//   mic PCM16 24 kHz streamed while the key is held → commit → screenshots as input_image items → response.create
//   output audio deltas play as they arrive; the transcript + `show_on_screen` tool calls carry the same tags.
// The wire format lives in `RealtimeCodec` (pure, covered by --selftest); the socket sits behind
// `RealtimeTransport` so the session logic can be driven by a fake. NOT exercised live in dev (no OpenAI key).

// MARK: - Transport

protocol RealtimeTransport: AnyObject {
    /// Server messages (JSON text), delivered on the main actor.
    var onMessage: ((String) -> Void)? { get set }
    /// The socket closed (nil = closed by us).
    var onClose: ((Error?) -> Void)? { get set }
    func connect(url: URL, headers: [String: String])
    /// Thread-safe.
    func send(_ text: String)
    func close()
}

final class WebSocketRealtimeTransport: NSObject, RealtimeTransport, @unchecked Sendable {
    var onMessage: ((String) -> Void)?
    var onClose: ((Error?) -> Void)?
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default)

    func connect(url: URL, headers: [String: String]) {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 16 * 1024 * 1024
        task = t
        t.resume()
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case let .success(message):
                let text: String?
                switch message {
                case let .string(s): text = s
                case let .data(d): text = String(data: d, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text { DispatchQueue.main.async { self.onMessage?(text) } }
                self.receive(t)
            case let .failure(error):
                DispatchQueue.main.async { self.onClose?(error) }
            }
        }
    }

    func send(_ text: String) {
        task?.send(.string(text)) { error in
            if let error { Log.error("realtime send: \(error.localizedDescription)") }
        }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}

// MARK: - Wire format

enum RealtimeServerEvent: Equatable {
    case sessionCreated
    case sessionUpdated
    case audioDelta(Data)
    case transcriptDelta(String)
    case transcriptDone(String)
    case inputTranscript(String)
    case functionCall(name: String, callId: String, arguments: String)
    case responseDone
    case speechStarted
    case error(String)
    case other(String)
}

struct RealtimeSecret: Equatable {
    var value: String
    var model: String
}

enum RealtimeCodec {
    static let sampleRate: Double = 24_000
    static let defaultModel = "gpt-realtime"
    static let toolName = "show_on_screen"

    static func url(model: String) -> URL {
        var c = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        c.queryItems = [URLQueryItem(name: "model", value: model)]
        return c.url!
    }

    /// Push-to-talk session: PCM16 24 kHz both ways, no server VAD, input transcription on, the tag tool.
    static func sessionUpdate(voice: String?) -> String {
        var output: [String: Any] = ["format": ["type": "audio/pcm", "rate": Int(sampleRate)]]
        if let voice { output["voice"] = voice }
        let session: [String: Any] = [
            "type": "realtime",
            "output_modalities": ["audio"],
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": Int(sampleRate)],
                    "turn_detection": NSNull(),
                    "transcription": ["model": "gpt-4o-mini-transcribe"],
                ],
                "output": output,
            ],
            "tools": [[
                "type": "function",
                "name": toolName,
                "description": "Point at, draw on, or act on the user's screen. Pass the exact Awan tags you would otherwise have written, e.g. [POINT:1100,42:color inspector] or [IMAGES:quokka] or [TYPE]text[/TYPE]. Never speak tags aloud.",
                "parameters": [
                    "type": "object",
                    "properties": ["tags": ["type": "string", "description": "One or more Awan tags."]],
                    "required": ["tags"],
                ],
            ]],
            "tool_choice": "auto",
        ]
        return encode(["type": "session.update", "session": session])
    }

    static func appendAudio(_ pcm16: Data) -> String {
        encode(["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()])
    }

    static func commit() -> String { encode(["type": "input_audio_buffer.commit"]) }
    static func clearInput() -> String { encode(["type": "input_audio_buffer.clear"]) }
    static func responseCreate() -> String { encode(["type": "response.create"]) }
    static func responseCancel() -> String { encode(["type": "response.cancel"]) }

    /// The screenshots (and any document/context text) for this push-to-talk turn, as one user message.
    static func userTurn(images: [(label: String, jpeg: Data)], texts: [String]) -> String {
        var content: [[String: Any]] = []
        for t in texts where !t.isEmpty { content.append(["type": "input_text", "text": t]) }
        for img in images {
            content.append(["type": "input_text", "text": img.label])
            content.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(img.jpeg.base64EncodedString())"])
        }
        return encode(["type": "conversation.item.create", "item": ["type": "message", "role": "user", "content": content]])
    }

    static func functionOutput(callId: String, output: String) -> String {
        encode(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callId, "output": output]])
    }

    /// The `tags` argument of a show_on_screen call.
    static func tagsArgument(_ arguments: String) -> String? {
        guard let d = arguments.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (o["tags"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// POST /v1/realtime/session's body is OpenAI's client-secret response (GA `value`, or beta `client_secret.value`).
    static func decodeSecret(_ data: Data) -> RealtimeSecret? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let value = (o["value"] as? String) ?? ((o["client_secret"] as? [String: Any])?["value"] as? String)
        guard let value, !value.isEmpty else { return nil }
        let model = ((o["session"] as? [String: Any])?["model"] as? String) ?? (o["model"] as? String) ?? defaultModel
        return RealtimeSecret(value: value, model: model)
    }

    /// Server event → our enum. Accepts both the GA names and the older beta names.
    static func decode(_ text: String) -> RealtimeServerEvent {
        guard let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let type = o["type"] as? String else {
            return .other("unparseable")
        }
        switch type {
        case "session.created": return .sessionCreated
        case "session.updated": return .sessionUpdated
        case "response.output_audio.delta", "response.audio.delta":
            return .audioDelta(Data(base64Encoded: o["delta"] as? String ?? "") ?? Data())
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta", "response.output_text.delta", "response.text.delta":
            return .transcriptDelta(o["delta"] as? String ?? "")
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            return .transcriptDone(o["transcript"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .inputTranscript(o["transcript"] as? String ?? "")
        case "response.function_call_arguments.done":
            return .functionCall(name: o["name"] as? String ?? "", callId: o["call_id"] as? String ?? "", arguments: o["arguments"] as? String ?? "{}")
        case "response.done": return .responseDone
        case "input_audio_buffer.speech_started": return .speechStarted
        case "error":
            let e = o["error"] as? [String: Any]
            return .error((e?["message"] as? String) ?? (e?["code"] as? String) ?? "realtime error")
        default: return .other(type)
        }
    }

    private static func encode(_ o: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Mic → socket

/// Converts mic buffers to PCM16 24 kHz on the audio thread and forwards them (buffering until the socket is up).
final class RealtimeAudioFeeder: @unchecked Sendable {
    private let lock = NSLock()
    private let converter = PCM16Converter(targetSampleRate: RealtimeCodec.sampleRate)
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var sink: ((String) -> Void)?
    private(set) var sentBytes = 0

    /// Audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let pcm = converter.convert(buffer) else { return }
        append(pcm16: pcm)
    }

    func append(pcm16: Data) {
        lock.lock()
        if let sink {
            sentBytes += pcm16.count
            lock.unlock()
            sink(RealtimeCodec.appendAudio(pcm16))
            return
        }
        pending.append(pcm16)
        pendingBytes += pcm16.count
        while pendingBytes > Int(RealtimeCodec.sampleRate) * 2 * 20, !pending.isEmpty { pendingBytes -= pending.removeFirst().count } // keep ≤ 20 s
        lock.unlock()
    }

    /// The socket is ready: flush what was said while connecting, then stream live.
    func attach(_ send: @escaping (String) -> Void) {
        lock.lock()
        let backlog = pending
        pending = []
        pendingBytes = 0
        sink = send
        sentBytes += backlog.reduce(0) { $0 + $1.count }
        lock.unlock()
        for chunk in backlog { send(RealtimeCodec.appendAudio(chunk)) }
    }

    func detach() {
        lock.lock(); sink = nil; pending = []; pendingBytes = 0; lock.unlock()
    }

    func resetCount() { lock.lock(); sentBytes = 0; lock.unlock() }
}

// MARK: - Session

@MainActor
final class RealtimeVoiceSession {
    static let shared = RealtimeVoiceSession()

    /// Realtime is used when the server offers it (and it hasn't failed this launch).
    static var isEnabled: Bool { AppState.shared.serverFeatures.realtime && !shared.failedThisLaunch }

    var transportFactory: () -> RealtimeTransport = { WebSocketRealtimeTransport() }
    var minter: () async throws -> RealtimeSecret = RealtimeVoiceSession.mintFromServer

    let feeder = RealtimeAudioFeeder()
    private(set) var isConnected = false
    private(set) var failedThisLaunch = false
    private var transport: RealtimeTransport?
    private var connecting: Task<Void, Error>?
    private var turn: AsyncThrowingStream<RealtimeServerEvent, Error>.Continuation?
    private var sentContext = false
    private(set) var lastInputTranscript = ""

    static func mintFromServer() async throws -> RealtimeSecret {
        let body: [String: JSON] = ["voice": .string(Prefs.shared.voiceID), "requestId": .string(UUID().uuidString)]
        let data = try await APIClient.shared.sendRaw("v1/realtime/session", body: body)
        guard let s = RealtimeCodec.decodeSecret(data) else { throw APIError.transport("realtime: no client secret") }
        return s
    }

    /// Connect (once) and configure the session. Safe to call repeatedly.
    func prepare() async throws {
        if isConnected { return }
        if let connecting { return try await connecting.value }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let secret = try await self.minter()
            let t = self.transportFactory()
            t.onMessage = { [weak self] text in self?.handle(text) }
            t.onClose = { [weak self] error in self?.closed(error) }
            t.connect(url: RealtimeCodec.url(model: secret.model), headers: ["Authorization": "Bearer \(secret.value)"])
            t.send(RealtimeCodec.sessionUpdate(voice: Prefs.shared.voiceID))
            self.transport = t
            self.isConnected = true
            self.sentContext = false
        }
        connecting = task
        defer { connecting = nil }
        do { try await task.value } catch {
            Log.error("realtime: \(error.localizedDescription) — using the voice pipeline")
            failedThisLaunch = true
            throw error
        }
    }

    /// The talk key went down: start a fresh input buffer and stream the mic into it.
    func beginTurn() {
        feeder.detach()
        feeder.resetCount()
        cancelResponse()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepare()
                self.transport?.send(RealtimeCodec.clearInput())
                if let t = self.transport { self.feeder.attach { [weak t] in t?.send($0) } }
            } catch {}
        }
    }

    /// The talk key came up: commit the audio, attach the screenshots, ask for the answer. Events until response.done.
    func finishTurn(images: [(label: String, jpeg: Data)], texts: [String], context: String?) -> AsyncThrowingStream<RealtimeServerEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor [weak self] in
                guard let self else { return continuation.finish() }
                do { try await self.prepare() } catch { return continuation.finish(throwing: error) }
                guard let t = self.transport else { return continuation.finish(throwing: APIError.transport("realtime: not connected")) }
                self.feeder.detach()
                self.turn?.finish()
                self.turn = continuation
                var extra = texts
                if !self.sentContext, let context { extra.insert("context about the user:\n\(context)", at: 0); self.sentContext = true }
                t.send(RealtimeCodec.commit())
                t.send(RealtimeCodec.userTurn(images: images, texts: extra))
                t.send(RealtimeCodec.responseCreate())
            }
        }
    }

    func cancelResponse() {
        guard isConnected, turn != nil else { return }
        transport?.send(RealtimeCodec.responseCancel())
        turn?.finish()
        turn = nil
    }

    func disconnect() {
        feeder.detach()
        transport?.close()
        transport = nil
        isConnected = false
        turn?.finish()
        turn = nil
    }

    // MARK: Incoming

    func handle(_ text: String) {
        let event = RealtimeCodec.decode(text)
        switch event {
        case let .functionCall(name, callId, _):
            // Acknowledge so the conversation stays well-formed; no new response (Awan keeps talking).
            transport?.send(RealtimeCodec.functionOutput(callId: callId, output: name == RealtimeCodec.toolName ? "shown" : "unknown tool"))
        case let .inputTranscript(t):
            lastInputTranscript = t
        case let .error(message):
            Log.error("realtime: \(message)")
        default:
            break
        }
        guard let turn else { return }
        switch event {
        case .responseDone:
            turn.yield(event)
            turn.finish()
            self.turn = nil
        case let .error(message) where message.contains("session") || message.contains("expired"):
            turn.finish(throwing: APIError.transport(message))
            self.turn = nil
            disconnect()
        default:
            turn.yield(event)
        }
    }

    private func closed(_ error: Error?) {
        isConnected = false
        transport = nil
        feeder.detach()
        if let turn { turn.finish(throwing: error ?? APIError.transport("connection dropped mid-response — try again.")) }
        turn = nil
    }
}
