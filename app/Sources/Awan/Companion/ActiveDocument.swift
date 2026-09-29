import AppKit
import ApplicationServices
import PDFKit

/// Whole-document understanding: when the user asks about "this pdf / this page / this file", Awan reads
/// the document open in the front window and sends its text with the turn (`document` in the request).
///
/// Sources, in order: the focused window's `AXDocument` file (PDF via PDFKit, first 40 pages; plain
/// text / markdown / code directly; .docx .doc .rtf .odt .html via `textutil`), a browser's web area
/// text via Accessibility (≤ 30k chars), then an editor's text area (TextEdit, Xcode, Notes…).
/// Never for password managers or Awan itself. Only runs when the question plausibly refers to it.
struct ActiveDocument: Equatable {
    var name: String
    /// "PDF", "web page", "document", "code file"…
    var kind: String
    var text: String
    /// Where the text came from (logs + tests): "file", "web", "editor".
    var source: String

    var requestBody: [String: String] { ["name": name, "text": text, "kind": kind] }
}

enum ActiveDocumentReader {
    static let maxChars = 80_000
    static let maxWebChars = 30_000
    static let maxPDFPages = 40

    /// Apps whose front window is usually a document (read even without the trigger words' "this").
    static let documentApps: Set<String> = [
        "com.apple.Preview", "com.apple.iWork.Pages", "com.microsoft.Word", "com.apple.TextEdit", "com.apple.dt.Xcode",
        "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.beta", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "com.brave.Browser", "org.mozilla.firefox", "com.adobe.Reader", "com.readdle.PDFExpert-Mac", "com.microsoft.VSCode",
        "com.sublimetext.4", "md.obsidian", "com.apple.Notes",
    ]
    static let chromiumBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    private static let referRegex = try! NSRegularExpression(pattern: #"\b(this|that|the|my)\s+(document|doc|file|pdf|page|article|paper|essay|report|chapter|post|story|contract|thesis|readme|script|code|manuscript|draft|website|site|blog|note|notes|spec|proposal|slides?)\b|\bsummar(y|ize|ise|ising|izing)\b|\btl;?dr\b|\bwhat does (it|this) say\b|\bwhat('s| is) (this|it) about\b|\bread (this|it)\b|\bin (this|the) (text|document|pdf|page)\b|\bkey (points|takeaways)\b"#, options: [.caseInsensitive])

    /// True when the question plausibly refers to the open document (keeps latency down otherwise).
    static func refersToDocument(_ question: String) -> Bool {
        let ns = question as NSString
        return referRegex.firstMatch(in: question, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// Reads the front window's document for `app` (the app that was frontmost when the user started talking).
    @MainActor
    static func read(app: NSRunningApplication?) async -> ActiveDocument? {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        if CompanionTyper.isPrivateApp(app.bundleIdentifier) { return nil }
        guard AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.5)
        guard let window = element(axApp, kAXFocusedWindowAttribute) ?? element(axApp, kAXMainWindowAttribute) else { return nil }
        let title = string(window, kAXTitleAttribute) ?? app.localizedName ?? "document"

        // 1. A file behind the window.
        if let doc = string(window, kAXDocumentAttribute), let url = fileURL(doc), url.isFileURL {
            let result = await Task.detached(priority: .userInitiated) { extractText(url: url) }.value
            if let (text, kind) = result, !text.isEmpty {
                return ActiveDocument(name: url.lastPathComponent, kind: kind, text: String(text.prefix(maxChars)), source: "file")
            }
        }
        // 2. A browser page.
        if let id = app.bundleIdentifier, CompanionTyper.browserBundles.contains(id) || chromiumBundles.contains(id) {
            if chromiumBundles.contains(id) {
                // Chromium only builds its accessibility tree for assistive apps that ask for it.
                AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            if let web = findFirst(in: window, role: "AXWebArea", maxDepth: 14) {
                var budget = WalkBudget(chars: maxWebChars, nodes: 8000, deadline: Date().addingTimeInterval(2.0))
                var parts: [String] = []
                collectText(web, into: &parts, budget: &budget, depth: 0)
                let text = normalise(parts.joined(separator: " "))
                if text.count > 200 {
                    let url = string(web, kAXURLAttribute)
                    let name = string(web, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? title
                    return ActiveDocument(name: name + (url.map { " (\($0))" } ?? ""), kind: "web page", text: String(text.prefix(maxWebChars)), source: "web")
                }
            }
        }
        // 3. An editor's text area (document apps only — a random app's text box isn't "the document").
        if let id = app.bundleIdentifier, documentApps.contains(id), let area = findFirst(in: window, role: kAXTextAreaRole as String, maxDepth: 10), let value = string(area, kAXValueAttribute) {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 80 { return ActiveDocument(name: title, kind: "document", text: String(text.prefix(maxChars)), source: "editor") }
        }
        return nil
    }

    // MARK: - Files

    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "mdx", "text", "csv", "tsv", "json", "yaml", "yml", "toml", "xml", "ini", "log", "tex",
        "swift", "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "rb", "go", "rs", "java", "kt", "kts", "c", "h", "cpp", "hpp", "cc", "m", "mm",
        "cs", "php", "sh", "zsh", "bash", "sql", "css", "scss", "less", "vue", "svelte", "astro", "lua", "dart", "r", "scala", "ex", "exs", "gradle",
    ]
    static let textutilExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "wordml"]

    /// (text, kind) for a file on disk, or nil when it isn't a kind Awan can read.
    static func extractText(url: URL) -> (String, String)? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let pdf = PDFDocument(url: url) else { return nil }
            var out = ""
            for i in 0 ..< min(pdf.pageCount, maxPDFPages) {
                guard let s = pdf.page(at: i)?.string else { continue }
                out += "\n\n[page \(i + 1)]\n" + s
                if out.count > maxChars { break }
            }
            if pdf.pageCount > maxPDFPages { out += "\n\n[only the first \(maxPDFPages) of \(pdf.pageCount) pages were read]" }
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (text, "PDF")
        }
        if textExtensions.contains(ext) || ext.isEmpty {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), (attrs[.size] as? Int ?? 0) < 8_000_000,
                  let data = FileManager.default.contents(atPath: url.path) else { return nil }
            guard let s = String(data: data.prefix(maxChars * 4), encoding: .utf8) ?? String(data: data.prefix(maxChars * 4), encoding: .isoLatin1) else { return nil }
            let kind = ["md", "markdown", "mdx", "txt", "text"].contains(ext) ? "document" : ext.isEmpty ? "file" : "code file"
            return (s, kind)
        }
        if textutilExtensions.contains(ext) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            p.arguments = ["-convert", "txt", "-stdout", url.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, let s = String(data: data, encoding: .utf8) else { return nil }
            return (s.trimmingCharacters(in: .whitespacesAndNewlines), ext.hasPrefix("htm") || ext == "webarchive" ? "web page" : "document")
        }
        return nil
    }

    static func fileURL(_ s: String) -> URL? {
        if s.hasPrefix("file://") { return URL(string: s) }
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        return nil
    }

    // MARK: - Accessibility walking

    struct WalkBudget {
        var chars: Int
        var nodes: Int
        var deadline: Date
        var exhausted: Bool { chars <= 0 || nodes <= 0 || Date() > deadline }
    }

    private static let skipRoles: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXImage", "AXTextField", "AXSearchField", "AXCheckBox", "AXRadioButton", "AXSlider"]

    static func collectText(_ el: AXUIElement, into parts: inout [String], budget: inout WalkBudget, depth: Int) {
        guard depth < 40, !budget.exhausted else { return }
        budget.nodes -= 1
        let role = string(el, kAXRoleAttribute) ?? ""
        if skipRoles.contains(role) { return }
        if role == (kAXStaticTextRole as String), let v = string(el, kAXValueAttribute), !v.isEmpty {
            parts.append(v)
            budget.chars -= v.count + 1
            return
        }
        for child in children(el) { collectText(child, into: &parts, budget: &budget, depth: depth + 1) }
    }

    static func findFirst(in root: AXUIElement, role: String, maxDepth: Int) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let (el, d) = queue.removeFirst()
            visited += 1
            if string(el, kAXRoleAttribute) == role { return el }
            if d < maxDepth { queue += children(el).map { ($0, d + 1) } }
        }
        return nil
    }

    static func normalise(_ s: String) -> String {
        s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let value = v, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let value = v else { return nil }
        if let s = value as? String { return s }
        if let u = value as? URL { return u.absoluteString }
        return nil
    }
}
