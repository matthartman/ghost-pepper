import SwiftUI

/// Block-level markdown renderer for Q&A answers. Handles the subset the
/// agent actually emits: H1–H3, bulleted/numbered lists, paragraphs, fenced
/// code blocks, blockquotes, and inline `**bold** *italic* `code` [label](url)`.
///
/// Citations like `[path.md:line]` and wikilinks `[[Name]]` are pre-rewritten
/// into `gp://`-scheme links by `QAAnswerCitations`, so they survive markdown
/// parsing and route through `onLink`.
struct QAAnswerView: View {
    let source: String
    let onLink: (URL) -> OpenURLAction.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .environment(\.openURL, OpenURLAction { onLink($0) })
    }

    @ViewBuilder
    private func blockView(_ block: QAMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, level == 1 ? 8 : 4)
                .padding(.bottom, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(inline(text))
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 6)
        case .ordered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(inline(text))
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 6)
        case .blockquote(let text):
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(Color.orange.opacity(0.6))
                    .frame(width: 3)
                Text(inline(text))
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .codeBlock(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        let processed = QAAnswerCitations.preprocess(text)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: processed, options: options) {
            return attributed
        }
        return AttributedString(processed)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 18
        case 2: return 15
        default: return 13
        }
    }

    private var blocks: [QAMarkdownBlock] {
        QAMarkdownBlock.parse(source)
    }
}

// MARK: - Block model

enum QAMarkdownBlock {
    case heading(Int, String)
    case bullet(String)
    case ordered(Int, String)
    case blockquote(String)
    case codeBlock(String)
    case paragraph(String)

    static func parse(_ source: String) -> [QAMarkdownBlock] {
        var out: [QAMarkdownBlock] = []
        let lines = source.components(separatedBy: "\n")
        var paragraphBuffer: [String] = []
        var codeBuffer: [String]? = nil

        func flushParagraph() {
            if !paragraphBuffer.isEmpty {
                out.append(.paragraph(paragraphBuffer.joined(separator: " ")))
                paragraphBuffer.removeAll()
            }
        }

        for raw in lines {
            // Inside a fenced code block, capture verbatim until the closing fence.
            if codeBuffer != nil {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    out.append(.codeBlock(codeBuffer!.joined(separator: "\n")))
                    codeBuffer = nil
                } else {
                    codeBuffer!.append(raw)
                }
                continue
            }

            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph()
                codeBuffer = []
                continue
            }
            if let (level, text) = matchHeading(trimmed) {
                flushParagraph()
                out.append(.heading(level, text))
                continue
            }
            if let text = matchBullet(trimmed) {
                flushParagraph()
                out.append(.bullet(text))
                continue
            }
            if let (n, text) = matchOrdered(trimmed) {
                flushParagraph()
                out.append(.ordered(n, text))
                continue
            }
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                out.append(.blockquote(String(trimmed.dropFirst(2))))
                continue
            }
            paragraphBuffer.append(trimmed)
        }
        flushParagraph()
        // Unterminated code fence: render what we have.
        if let buf = codeBuffer {
            out.append(.codeBlock(buf.joined(separator: "\n")))
        }
        return out
    }

    private static func matchHeading(_ line: String) -> (Int, String)? {
        for level in (1...6).reversed() {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) {
                return (level, String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func matchBullet(_ line: String) -> String? {
        if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("* ") { return String(line.dropFirst(2)) }
        return nil
    }

    private static func matchOrdered(_ line: String) -> (Int, String)? {
        // "1. text" or "12. text"
        guard let regex = try? NSRegularExpression(pattern: #"^(\d+)\.\s+(.*)$"#) else { return nil }
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 3,
              let n = Int(ns.substring(with: m.range(at: 1))) else { return nil }
        return (n, ns.substring(with: m.range(at: 2)))
    }
}

// MARK: - Citation preprocessing (shared)

enum QAAnswerCitations {
    /// Rewrites `[path.md:line]` and `[[Name]]` citations into proper markdown
    /// links with `gp://` scheme so they survive AttributedString markdown
    /// parsing and route through the openURL handler.
    @MainActor
    static func preprocess(_ source: String) -> String {
        var s = source
        // Path citations — match the path itself anywhere it appears, regardless
        // of surrounding wrappers ([], (), backticks). Anchored on a known
        // archive prefix (date folder, .indexes, or Reads) to avoid matching
        // unrelated `.md` mentions like URLs. Line spec supports single line
        // and ranges (e.g. :71-72).
        let pathPattern = #"`?((?:\d{4}-\d{2}-\d{2}|\.indexes|Reads|wikis)/[^\s,()\[\]`]+\.md)`?(?::(\d+(?:-\d+)?))?"#
        s = replaceMatches(in: s, pattern: pathPattern) { groups in
            let path = groups[1]
            let lineSpec = groups[2]
            let label = lineSpec.isEmpty ? path : "\(path):\(lineSpec)"
            // Use the first number of a range (e.g. "71-72" → 71) for the
            // future line-jump feature; full spec stays in the label.
            let firstLine = lineSpec.split(separator: "-").first.map(String.init) ?? ""
            let host = path.hasPrefix("wikis/") ? "wiki" : "meeting"
            let url = "gp://\(host)/" + path + (firstLine.isEmpty ? "" : "?line=\(firstLine)")
            return "[\(label)](\(url))"
        }
        // Wikilinks: [[Name]]
        let wikiPattern = #"\[\[([^\]]+)\]\]"#
        s = replaceMatches(in: s, pattern: wikiPattern) { groups in
            let name = groups[1]
            let slug = MarkdownArchivePaths.slugForIndexEntry(name)
            return "[\(name)](gp://person/people/\(slug))"
        }
        return s
    }

    private static func replaceMatches(in source: String, pattern: String, transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let ns = source as NSString
        var result = ""
        var lastEnd = 0
        regex.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match else { return }
            result += ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(groups)
            lastEnd = m.range.location + m.range.length
        }
        result += ns.substring(from: lastEnd)
        return result
    }
}
