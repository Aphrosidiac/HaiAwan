import Foundation
import CoreGraphics

// The companion's visual tag protocol, parsed app-side from the raw reply text (the server's `done.text`).
//
//   [POINT:x,y:label]            fly the buddy to a spot (tag goes at the END of the sentence it belongs to)
//   [POINT:x,y:label:screen2]    …on another display (screen number from the image label)
//   [POINT:none]                 nothing to point at
//   [HIGHLIGHT:x,y,w,h:label]    box a work area (tag-first: it goes BEFORE its sentence)
//   [SHAPE:kind:x1,y1;x2,y2…:label]  kind = circle | arrow | line | curve | polygon
//                                circle = centre;point-on-ring, arrow/line/curve = from;(via;)to, polygon = corners
//   [TARGET:x,y,r:label]         arm a click target for a guided walkthrough (tag-first)
//   [HOVER:x,y,r:label]          same, completes when the pointer rests on it
//   [AGENT:task]                 hand the request to an Awan
//   [IMAGES:query]               show an image strip under the notch
//   [TYPE]text[/TYPE]            type text into the focused field ([TYPE:x,y:label]…[/TYPE] focuses the field at x,y first)
//
// Every coordinate is in the screenshot's own pixel space (top-left origin). Every visual tag may end with
// `:screenN`. `CaptureGeometry` maps pixels back to global AppKit points.

/// One visual instruction in screenshot pixel space.
enum CompanionVisual: Equatable {
    case point(x: Double, y: Double, label: String?)
    case highlight(x: Double, y: Double, width: Double, height: Double, label: String?)
    case shape(kind: AnnotationShapeKind, points: [CGPoint], label: String?)
    case target(x: Double, y: Double, radius: Double, label: String?, isHover: Bool)

    var label: String? {
        switch self {
        case let .point(_, _, l), let .highlight(_, _, _, _, l), let .shape(_, _, l), let .target(_, _, _, l, _): return l
        }
    }
    var isTarget: Bool { if case .target = self { return true } else { return false } }
    var isPoint: Bool { if case .point = self { return true } else { return false } }
}

struct CompanionTag: Equatable {
    var visual: CompanionVisual
    /// 1-based display number from the image labels; nil = the cursor's screen.
    var screen: Int?
    /// How many characters of `spokenText` come before the tag (used to sync visuals with speech).
    var spokenOffset: Int

    /// The spoken-text character this tag belongs to: POINT tags trail their sentence, the others lead it.
    var anchorOffset: Int { visual.isPoint ? max(0, spokenOffset - 1) : spokenOffset }
}

/// Text the companion wants typed for the user (`[TYPE]…[/TYPE]`), optionally into the field at a spot.
struct CompanionTypeRequest: Equatable {
    var text: String
    /// Screenshot-pixel spot of the field to focus first (nil = whatever has focus).
    var x: Double?
    var y: Double?
    var label: String?
    var screen: Int?
}

struct ParsedReply: Equatable {
    var spokenText: String
    var tags: [CompanionTag]
    var agentTask: String?
    var saidPointNone = false
    var imagesQuery: String?
    var typeRequest: CompanionTypeRequest?

    var points: [CompanionTag] { tags.filter { $0.visual.isPoint } }
    var annotations: [CompanionTag] { tags.filter { !$0.visual.isPoint } }
    /// The (first) armed click/hover target of a guided step.
    var target: CompanionTag? { tags.first { $0.visual.isTarget } }
}

enum CompanionTagParser {
    /// Any tag we strip from speech, whether or not we act on it.
    static let tagPattern = #"\[(POINT|HIGHLIGHT|SHAPE|TARGET|HOVER|AGENT|IMAGES|TYPE)\s*:([^\]]*)\]"#
    private static let tagRegex = try! NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive])
    /// `[TYPE]…[/TYPE]` / `[TYPE:x,y:label]…[/TYPE]`; an unterminated block runs to the end.
    static let typeBlockPattern = #"\[TYPE(?:\s*:([^\]]*))?\]([\s\S]*?)(?:\[/TYPE\]|$)"#
    private static let typeRegex = try! NSRegularExpression(pattern: typeBlockPattern, options: [.caseInsensitive])
    /// An opened TYPE block (to hold streamed text back from speech).
    private static let typeOpenRegex = try! NSRegularExpression(pattern: #"\[TYPE(?:\s*:[^\]]*)?\]"#, options: [.caseInsensitive])
    private static let screenRegex = try! NSRegularExpression(pattern: #"^\s*screen\s*(\d+)\s*$"#, options: [.caseInsensitive])

    static func parse(_ input: String) -> ParsedReply {
        var reply = ParsedReply(spokenText: "", tags: [])
        let (raw, typeRequest) = extractTypeBlock(input)
        reply.typeRequest = typeRequest
        var spoken = ""
        let ns = raw as NSString
        var cursor = 0
        for m in tagRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            appendSpoken(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), to: &spoken)
            cursor = m.range.location + m.range.length
            let kind = ns.substring(with: m.range(at: 1)).uppercased()
            let body = ns.substring(with: m.range(at: 2))
            let offset = spoken.trimmingTrailingSpaces().count
            switch kind {
            case "AGENT":
                let task = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !task.isEmpty, reply.agentTask == nil { reply.agentTask = task }
            case "POINT":
                if body.trimmingCharacters(in: .whitespaces).lowercased() == "none" { reply.saidPointNone = true; continue }
                if let tag = parseVisual(kind: kind, body: body, offset: offset) { reply.tags.append(tag) }
            case "HIGHLIGHT", "SHAPE", "TARGET", "HOVER":
                if let tag = parseVisual(kind: kind, body: body, offset: offset) { reply.tags.append(tag) }
            case "IMAGES":
                let q = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !q.isEmpty, reply.imagesQuery == nil { reply.imagesQuery = String(q.prefix(200)) }
            default:
                break
            }
        }
        appendSpoken(ns.substring(from: cursor), to: &spoken)

        // Trim, and shift offsets by whatever leading whitespace went.
        let leading = spoken.prefix { $0 == " " || $0 == "\n" }.count
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        reply.spokenText = trimmed
        for i in reply.tags.indices {
            reply.tags[i].spokenOffset = max(0, min(trimmed.count, reply.tags[i].spokenOffset - leading))
        }
        return reply
    }

    /// Removes every tag (complete ones) from a text fragment — defensive, for streamed deltas.
    /// A TYPE block's text is never spoken: finished blocks go, and an open one hides everything after it.
    static func stripTags(_ text: String) -> String {
        var t = text
        if t.range(of: "[TYPE", options: .caseInsensitive) != nil {
            let closed = try! NSRegularExpression(pattern: #"\[TYPE(?:\s*:[^\]]*)?\][\s\S]*?\[/TYPE\]"#, options: [.caseInsensitive])
            t = closed.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
            if let open = typeOpenRegex.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) {
                t = (t as NSString).substring(to: open.range.location)
            }
        }
        let ns = t as NSString
        return tagRegex.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    /// Pulls the first TYPE block out of a reply (every block is removed from the text).
    static func extractTypeBlock(_ raw: String) -> (String, CompanionTypeRequest?) {
        let ns = raw as NSString
        let matches = typeRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard let first = matches.first else { return (raw, nil) }
        var text = ns.substring(with: first.range(at: 2))
        if text.hasPrefix("\n") { text.removeFirst() }
        if text.hasSuffix("\n") { text.removeLast() }
        var request: CompanionTypeRequest?
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request = CompanionTypeRequest(text: text)
            if first.range(at: 1).location != NSNotFound {
                let head = ns.substring(with: first.range(at: 1))
                if let tag = parseVisual(kind: "POINT", body: head, offset: 0), case let .point(x, y, label) = tag.visual {
                    request?.x = x; request?.y = y; request?.label = label; request?.screen = tag.screen
                }
            }
        }
        var out = raw
        for m in matches.reversed() { out = (out as NSString).replacingCharacters(in: m.range, with: " ") }
        return (out, request)
    }

    // MARK: - Pieces

    /// Collapses whitespace: runs containing a newline become one newline (a sentence break for speech), others one space.
    private static func appendSpoken(_ segment: String, to spoken: inout String) {
        var out = ""
        var pendingSpace: Character?
        for ch in segment {
            if ch.isWhitespace {
                if ch.isNewline { pendingSpace = "\n" } else if pendingSpace == nil { pendingSpace = " " }
            } else {
                if let s = pendingSpace { out.append(s); pendingSpace = nil }
                out.append(ch)
            }
        }
        if let s = pendingSpace { out.append(s) }
        guard !out.isEmpty else { return }
        if let last = spoken.last, last.isWhitespace, let first = out.first, first.isWhitespace {
            if first.isNewline, !last.isNewline { spoken.removeLast(); spoken.append("\n") }
            out.removeFirst()
        }
        spoken += out
    }

    private static func parseVisual(kind: String, body: String, offset: Int) -> CompanionTag? {
        var parts = body.components(separatedBy: ":")
        var screen: Int?
        if parts.count > 1, let last = parts.last {
            let ns = last as NSString
            if let m = screenRegex.firstMatch(in: last, range: NSRange(location: 0, length: ns.length)) {
                screen = Int(ns.substring(with: m.range(at: 1)))
                parts.removeLast()
            }
        }
        func label(from index: Int) -> String? {
            guard parts.count > index else { return nil }
            let l = parts[index...].joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)
            return l.isEmpty ? nil : l
        }
        let visual: CompanionVisual
        switch kind {
        case "POINT":
            let n = numbers(parts.first)
            guard n.count >= 2 else { return nil }
            visual = .point(x: n[0], y: n[1], label: label(from: 1))
        case "HIGHLIGHT":
            let n = numbers(parts.first)
            guard n.count >= 4, n[2] > 0, n[3] > 0 else { return nil }
            visual = .highlight(x: n[0], y: n[1], width: n[2], height: n[3], label: label(from: 1))
        case "SHAPE":
            guard parts.count >= 2, let shapeKind = AnnotationShapeKind(rawValue: parts[0].trimmingCharacters(in: .whitespaces).lowercased()) else { return nil }
            let pts: [CGPoint] = parts[1].components(separatedBy: ";").compactMap { pair in
                let n = numbers(pair)
                return n.count >= 2 ? CGPoint(x: n[0], y: n[1]) : nil
            }
            let minimum = shapeKind == .polygon ? 3 : 2
            guard pts.count >= minimum else { return nil }
            visual = .shape(kind: shapeKind, points: pts, label: label(from: 2))
        case "TARGET", "HOVER":
            let n = numbers(parts.first)
            guard n.count >= 2 else { return nil }
            let r = n.count >= 3 ? max(8, n[2]) : 36
            visual = .target(x: n[0], y: n[1], radius: r, label: label(from: 1), isHover: kind == "HOVER")
        default:
            return nil
        }
        return CompanionTag(visual: visual, screen: screen, spokenOffset: offset)
    }

    private static func numbers(_ s: String?) -> [Double] {
        guard let s else { return [] }
        return s.components(separatedBy: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }
}

private extension String {
    func trimmingTrailingSpaces() -> Substring {
        var s = self[...]
        while let l = s.last, l.isWhitespace { s = s.dropLast() }
        return s
    }
}

// MARK: - Coordinate mapping

/// Where a screenshot came from, so pixel coordinates in it map back to global AppKit points.
/// Adapted from farzaa/clicky (MIT) — scale to display points, flip Y, add the display origin.
struct CaptureGeometry: Equatable {
    /// The display's frame in AppKit global coordinates (bottom-left origin, points).
    var displayFrame: CGRect
    /// The screenshot's size in pixels.
    var pixelSize: CGSize

    var scaleX: CGFloat { displayFrame.width / max(1, pixelSize.width) }
    var scaleY: CGFloat { displayFrame.height / max(1, pixelSize.height) }

    func globalPoint(fromPixel p: CGPoint) -> CGPoint {
        let x = max(0, min(p.x, pixelSize.width))
        let y = max(0, min(p.y, pixelSize.height))
        return CGPoint(x: displayFrame.minX + x * scaleX, y: displayFrame.minY + (displayFrame.height - y * scaleY))
    }

    /// A pixel-space rect (top-left origin) → global AppKit rect (bottom-left origin).
    func globalRect(fromPixel r: CGRect) -> CGRect {
        let a = globalPoint(fromPixel: CGPoint(x: r.minX, y: r.minY))
        let b = globalPoint(fromPixel: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Inverse of `globalPoint` (used to draw the spatial trail onto the screenshot).
    func pixelPoint(fromGlobal g: CGPoint) -> CGPoint {
        CGPoint(x: (g.x - displayFrame.minX) / scaleX, y: (displayFrame.height - (g.y - displayFrame.minY)) / scaleY)
    }

    func globalLength(fromPixels d: Double) -> CGFloat { CGFloat(d) * (scaleX + scaleY) / 2 }
}

/// A tag resolved to global coordinates.
enum ResolvedVisual: Equatable {
    case point(ScreenPoint)
    case annotation(Annotation)
}

enum CompanionVisualMapper {
    /// Picks the capture a tag refers to: `screenN` (1-based, cursor screen first) or the cursor's screen.
    static func geometry(for tag: CompanionTag, in captures: [CaptureGeometry], cursorIndex: Int = 0) -> CaptureGeometry? {
        guard !captures.isEmpty else { return nil }
        if let s = tag.screen, s >= 1, s <= captures.count { return captures[s - 1] }
        return captures[min(max(0, cursorIndex), captures.count - 1)]
    }

    static func resolve(_ tag: CompanionTag, in captures: [CaptureGeometry], cursorIndex: Int = 0) -> ResolvedVisual? {
        guard let g = geometry(for: tag, in: captures, cursorIndex: cursorIndex) else { return nil }
        switch tag.visual {
        case let .point(x, y, label):
            return .point(ScreenPoint(point: g.globalPoint(fromPixel: CGPoint(x: x, y: y)), label: label))
        case let .highlight(x, y, w, h, label):
            return .annotation(.highlight(rect: g.globalRect(fromPixel: CGRect(x: x, y: y, width: w, height: h)), label: label))
        case let .shape(kind, points, label):
            return .annotation(.shape(kind: kind, points: points.map { g.globalPoint(fromPixel: $0) }, label: label, filled: false))
        case let .target(x, y, r, label, hover):
            return .annotation(.target(center: g.globalPoint(fromPixel: CGPoint(x: x, y: y)), radius: g.globalLength(fromPixels: r), label: label, isHover: hover))
        }
    }
}
