import AppKit
import Foundation

/// One entry of the live voice conversation, kept in the server's chat wire shape.
struct ConversationItem {
    enum Role: String { case user, assistant, tool }
    enum Kind { case utterance, note, reply, toolResult }

    var role: Role
    var kind: Kind
    var text: String?
    var images: [ScreenCaptureFrame] = []
    var toolCalls: [ToolCallItem] = []
    var toolCallID: String?
    var at = Date()

    static func note(_ text: String) -> ConversationItem { ConversationItem(role: .user, kind: .note, text: text) }
    static func utterance(_ text: String, images: [ScreenCaptureFrame] = []) -> ConversationItem {
        ConversationItem(role: .user, kind: .utterance, text: text, images: images)
    }

    /// `{role, content, tool_calls?, tool_call_id?}` for POST /v1/companion/turn. Images older than `keepImages`
    /// are sent as a one-line placeholder (the caller decides which items still carry pixels).
    func wire(includeImages: Bool) -> JSON {
        switch role {
        case .user:
            guard !images.isEmpty else { return ["role": "user", "content": .string(text ?? "")] }
            var parts: [JSON] = []
            for f in images {
                if includeImages {
                    parts.append(["type": "text", "text": .string(f.label)])
                    parts.append(["type": "image_url", "image_url": ["url": .string("data:image/jpeg;base64," + f.jpeg.base64EncodedString())]])
                } else {
                    parts.append(["type": "text", "text": .string("(\(f.label) — an earlier screenshot, no longer attached)")])
                }
            }
            if let text, !text.isEmpty { parts.append(["type": "text", "text": .string(text)]) }
            return ["role": "user", "content": .array(parts)]
        case .assistant:
            var o: [String: JSON] = ["role": "assistant", "content": text.map { .string($0) } ?? .null]
            if !toolCalls.isEmpty {
                o["tool_calls"] = .array(toolCalls.map { ["id": .string($0.id), "type": "function", "function": ["name": .string($0.name), "arguments": .string($0.arguments)]] })
            }
            return .object(o)
        case .tool:
            return ["role": "tool", "tool_call_id": .string(toolCallID ?? ""), "content": .string(text ?? "")]
        }
    }
}

struct ToolCallItem: Equatable {
    var id: String
    var name: String
    var arguments: String
    var args: [String: JSON] {
        guard let data = arguments.data(using: .utf8), let j = try? JSONDecoder().decode(JSON.self, from: data), case let .object(o) = j else { return [:] }
        return o
    }
}

/// A line of the plain transcript that survives session rebuilds and relaunches.
struct TranscriptLine: Codable, Equatable {
    var role: String        // "user" | "awan" | "event"
    var text: String
    var at: Date
}

/// The voice companion's memory of the conversation.
///
/// Like the reference, one session holds the full live conversation (utterances, replies, tool calls, tool results,
/// screenshots and silent context notes). After a stretch of idleness the session is torn down and the next turn opens
/// a fresh one seeded with the plain transcript of what was said, so Awan keeps the thread without dragging old
/// screenshots and tool chatter along. The transcript is also kept on disk, so a relaunch doesn't wipe it.
@MainActor
final class CompanionConversation {
    /// Replaceable before first use (self-tests use a throwaway, unpersisted one).
    static var shared = CompanionConversation()

    /// A session idle this long is rebuilt on the next turn.
    static var idleTeardown: TimeInterval = 20 * 60
    /// Transcript lines carried into a new session (and kept on disk).
    static let transcriptLimit = 40
    /// Screenshots that still carry pixels in a request (newest first); older ones become a placeholder line.
    static let liveImageSubmissions = 2
    /// Items kept in a live session before the oldest are folded away.
    static let itemLimit = 140

    private(set) var items: [ConversationItem] = []
    private(set) var transcript: [TranscriptLine] = []
    private(set) var sessionStartedAt: Date?
    private var lastActivity = Date.distantPast
    /// How many transcript lines were replayed into this session (the server mentions it in the instructions).
    private(set) var priorMessageCount = 0

    // What the model already knows, so notes are only sent when something changed (the reference dedupes the same way).
    var lastScreenFingerprints: [[UInt8]] = []
    var lastScreenAt: Date?
    var lastNotes: [String: String] = [:]

    private let fileURL: URL
    private let persist: Bool

    init(fileURL: URL? = nil, persist: Bool = !CommandLine.arguments.contains("--snapshot")) {
        self.fileURL = fileURL ?? Paths.homeCache.appendingPathComponent("companion-transcript.json")
        self.persist = persist
        if persist { load() }
    }

    var isLive: Bool { sessionStartedAt != nil }

    /// Opens a fresh session when there is none or the last one went idle. Returns true when it did.
    @discardableResult
    func ensureSession(now: Date = Date()) -> Bool {
        if sessionStartedAt != nil, now.timeIntervalSince(lastActivity) < Self.idleTeardown { return false }
        items = []
        lastScreenFingerprints = []
        lastScreenAt = nil
        lastNotes = [:]
        sessionStartedAt = now
        lastActivity = now
        let prior = transcript.suffix(24)
        priorMessageCount = prior.count
        if !prior.isEmpty { items.append(.note(Self.earlierConversationNote(Array(prior), now: now))) }
        Log.info("companion: new conversation session (\(prior.count) earlier lines carried over)")
        return true
    }

    func touch(_ now: Date = Date()) { lastActivity = now }

    func append(_ item: ConversationItem) {
        items.append(item)
        touch()
        trim()
    }

    /// Records what was said, for the transcript (and the next session's [earlier conversation] note).
    func record(_ role: String, _ text: String, at: Date = Date()) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        transcript.append(TranscriptLine(role: role, text: String(t.prefix(1200)), at: at))
        if transcript.count > Self.transcriptLimit { transcript.removeFirst(transcript.count - Self.transcriptLimit) }
        save()
    }

    /// The recent back-and-forth for the deeper pass and agent hand-offs (oldest first).
    func recentExchange(limit: Int = 12) -> [TranscriptLine] {
        Array(transcript.filter { $0.role != "event" }.suffix(limit))
    }

    /// The request body's `items`: every item, pixels only on the newest screenshot submissions.
    func wireItems() -> [JSON] {
        var withImages = Set<Int>()
        var budget = Self.liveImageSubmissions
        for i in items.indices.reversed() where !items[i].images.isEmpty && budget > 0 {
            withImages.insert(i)
            budget -= 1
        }
        return items.indices.map { items[$0].wire(includeImages: withImages.contains($0)) }
    }

    /// A turn cut off mid-tool leaves calls without results; answer them so the conversation stays well-formed.
    func closeDanglingToolCalls() {
        guard let i = items.lastIndex(where: { $0.role == .assistant && !$0.toolCalls.isEmpty }) else { return }
        let answered = Set(items[i...].compactMap(\.toolCallID))
        for call in items[i].toolCalls where !answered.contains(call.id) {
            items.append(ConversationItem(role: .tool, kind: .toolResult, text: "cancelled: the user moved on to a new message before this finished. don't mention it; handle their newest message.", toolCallID: call.id))
        }
    }

    /// Forget everything (Settings → reset, sign-out).
    func clear() {
        items = []
        transcript = []
        sessionStartedAt = nil
        lastNotes = [:]
        lastScreenFingerprints = []
        save()
    }

    /// Ends the live session now (the next turn starts fresh from the transcript).
    func endSession() { sessionStartedAt = nil }

    // MARK: - Notes

    static func earlierConversationNote(_ lines: [TranscriptLine], now: Date) -> String {
        let f = DateFormatter()
        let sameDay = Calendar.current.isDate(lines.first?.at ?? now, inSameDayAs: now)
        f.dateFormat = sameDay ? "h:mm a" : "EEE d MMM, h:mm a"
        let body = lines.map { "- \(f.string(from: $0.at)) \($0.role == "user" ? "user" : $0.role == "awan" ? "awan" : "event"): \($0.text.replacingOccurrences(of: "\n", with: " "))" }
        return "[earlier conversation] what you and the user said before this session (oldest first). it's your memory of the conversation; pick up from it naturally.\n" + body.joined(separator: "\n")
    }

    // MARK: - Private

    /// Folds the oldest items into the transcript note once a long session passes the limit, keeping tool calls
    /// paired with their results.
    private func trim() {
        guard items.count > Self.itemLimit else { return }
        var cut = items.count - Self.itemLimit + 20
        // Never start the kept window on a tool result or an assistant tool call.
        while cut < items.count, items[cut].role != .user || items[cut].kind == .toolResult { cut += 1 }
        items.removeFirst(min(cut, items.count))
        let prior = transcript.suffix(16)
        if !prior.isEmpty { items.insert(.note(Self.earlierConversationNote(Array(prior), now: Date())), at: 0) }
    }

    private struct File: Codable { var lines: [TranscriptLine] }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL), let f = try? dec.decode(File.self, from: data) else { return }
        // Anything older than a week is stale context, not memory (durable facts live in Memory/PROFILE.md).
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        transcript = Array(f.lines.filter { $0.at > cutoff }.suffix(Self.transcriptLimit))
    }

    private func save() {
        guard persist else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(File(lines: transcript)) { try? data.write(to: fileURL, options: .atomic) }
    }
}
