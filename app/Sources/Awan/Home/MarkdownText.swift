import SwiftUI

/// Renders an agent's final answer: paragraphs, headings, bullet and numbered lists, quotes,
/// fenced code and pipe tables, with inline bold/italic/code/links. Plain text, not a bubble.
struct MarkdownText: View {
    let source: String
    var fontSize: CGFloat = 14
    var color: Color = Theme.text
    var lineSpacing: CGFloat = 3
    var paragraphSpacing: CGFloat = 9

    var body: some View {
        VStack(alignment: .leading, spacing: paragraphSpacing) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            inline(text).font(.awan(fontSize)).lineSpacing(lineSpacing)
        case let .heading(level, text):
            inline(text).font(.awan(level == 1 ? fontSize + 4 : level == 2 ? fontSize + 2 : fontSize + 0.5, .semibold))
                .padding(.top, 4)
        case let .list(items, ordered):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(i + 1)." : "•")
                            .font(.awan(fontSize, ordered ? .medium : .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(minWidth: ordered ? 16 : 8, alignment: .trailing)
                        inline(item.text).font(.awan(fontSize)).lineSpacing(lineSpacing)
                            .padding(.leading, CGFloat(item.indent) * 14)
                    }
                }
            }
        case let .quote(text):
            HStack(spacing: 10) {
                Capsule().fill(Theme.strokeStrong).frame(width: 3)
                inline(text).font(.awan(fontSize)).foregroundStyle(Theme.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .code(text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.awanMono(fontSize - 1.5, .regular)).foregroundStyle(Theme.text)
                    .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke, lineWidth: 1))
        case let .table(header, rows):
            table(header: header, rows: rows)
        case .rule:
            Rectangle().fill(Theme.stroke).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func table(header: [String], rows: [[String]]) -> some View {
        let cols = max(header.count, rows.map(\.count).max() ?? 0)
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<cols, id: \.self) { c in
                        inline(c < header.count ? header[c] : "").font(.awan(fontSize - 1, .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: 260, alignment: .leading)
                    }
                }
                .background(Color.white.opacity(0.06))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().overlay(Theme.stroke)
                    GridRow {
                        ForEach(0..<cols, id: \.self) { c in
                            inline(c < row.count ? row[c] : "").font(.awan(fontSize - 1))
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .frame(maxWidth: 260, alignment: .leading)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.strokeStrong, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func inline(_ text: String) -> Text {
        Text(Self.attributed(text, color: color))
    }

    static func attributed(_ text: String, color: Color = Theme.text) -> AttributedString {
        var a = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in a.runs {
            if run.link != nil {
                a[run.range].foregroundColor = Theme.bone
                a[run.range].underlineStyle = .single
            } else if run.inlinePresentationIntent?.contains(.code) == true {
                a[run.range].font = .awanMono(13, .medium)
                a[run.range].backgroundColor = Color.white.opacity(0.08)
            }
        }
        return a
    }
}

enum MarkdownBlock: Equatable {
    struct Item: Equatable { var text: String; var indent: Int }
    case paragraph(String)
    case heading(Int, String)
    case list([Item], ordered: Bool)
    case quote(String)
    case code(String)
    case table(header: [String], rows: [[String]])
    case rule

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var para: [String] = []
        var items: [Item] = []
        var ordered = false
        var table: [[String]] = []
        var code: [String]? = nil
        var quote: [String] = []

        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !items.isEmpty { blocks.append(.list(items, ordered: ordered)); items = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty {
                let header = table[0]
                blocks.append(.table(header: header, rows: Array(table.dropFirst())))
                table = []
            }
        }

        for raw in source.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var c = code {
                if trimmed.hasPrefix("```") { blocks.append(.code(c.joined(separator: "\n"))); code = nil } else { c.append(line); code = c }
                continue
            }
            if trimmed.hasPrefix("```") { flush(); code = []; continue }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("|") {
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) { continue } // |---|---|
                if table.isEmpty { flush() }
                table.append(cells)
                continue
            } else if !table.isEmpty { flush() }
            if trimmed == "---" || trimmed == "***" { flush(); blocks.append(.rule); continue }
            if let h = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"), trimmed[h] == " " {
                flush()
                let level = trimmed.distance(from: trimmed.startIndex, to: h)
                blocks.append(.heading(min(level, 3), String(trimmed[h...]).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix("> ") { if !para.isEmpty || !items.isEmpty { flush() }; quote.append(String(trimmed.dropFirst(2))); continue }
            let indent = (line.count - line.drop(while: { $0 == " " }).count) / 2
            if let bullet = ["- ", "* ", "• "].first(where: { trimmed.hasPrefix($0) }) {
                if !para.isEmpty || (!items.isEmpty && ordered) { flush() }
                ordered = false
                items.append(Item(text: String(trimmed.dropFirst(bullet.count)), indent: min(indent, 3)))
                continue
            }
            if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
               trimmed.index(after: dot) < trimmed.endIndex, trimmed[trimmed.index(after: dot)] == " " {
                if !para.isEmpty || (!items.isEmpty && !ordered) { flush() }
                ordered = true
                items.append(Item(text: String(trimmed[trimmed.index(dot, offsetBy: 2)...]), indent: min(indent, 3)))
                continue
            }
            if !items.isEmpty || !quote.isEmpty { flush() }
            para.append(trimmed)
        }
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
