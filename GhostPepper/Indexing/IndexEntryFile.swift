import Foundation

/// Reads and writes `IndexEntry` to disk as markdown with YAML frontmatter.
///
/// File format:
/// ```
/// ---
/// index_type: people
/// canonical_name: "John Smith"
/// aliases:
///   - John
///   - "John S."
/// source_meetings:
///   - 2026-04-28/standup.md
/// last_updated: 2026-04-28T15:30:00Z
/// ---
///
/// <body markdown>
/// ```
///
/// We hand-roll a minimal YAML reader/writer rather than pulling in a dependency
/// because the schema is fixed and small.
enum IndexEntryFile {
    enum ParseError: Error {
        case missingFrontmatter
        case malformedFrontmatter(String)
        case unknownIndexType(String)
    }

    static func read(from url: URL) throws -> IndexEntry {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text)
    }

    static func write(_ entry: IndexEntry, to url: URL) throws {
        let text = render(entry)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func parse(_ text: String) throws -> IndexEntry {
        guard text.hasPrefix("---\n") else {
            throw ParseError.missingFrontmatter
        }
        let afterOpen = text.dropFirst("---\n".count)
        guard let closeRange = afterOpen.range(of: "\n---\n") else {
            throw ParseError.missingFrontmatter
        }
        let frontmatter = String(afterOpen[..<closeRange.lowerBound])
        let body = String(afterOpen[closeRange.upperBound...])

        var indexTypeRaw: String?
        var canonicalName: String?
        var aliases: [String] = []
        var sourceMeetings: [String] = []
        var lastUpdated: Date?

        var generationModel: String?
        var generationPromptKind: String?
        var generationPromptHash: String?
        var generationAt: Date?

        let lines = frontmatter.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.isEmpty { i += 1; continue }

            if let value = scalarValue(line: line, key: "index_type") {
                indexTypeRaw = value
            } else if let value = scalarValue(line: line, key: "canonical_name") {
                canonicalName = value
            } else if let value = scalarValue(line: line, key: "last_updated") {
                lastUpdated = isoDate(from: value)
            } else if let value = scalarValue(line: line, key: "generated_by_model") {
                generationModel = value
            } else if let value = scalarValue(line: line, key: "generated_by_prompt") {
                generationPromptKind = value
            } else if let value = scalarValue(line: line, key: "generated_by_hash") {
                generationPromptHash = value
            } else if let value = scalarValue(line: line, key: "generated_at") {
                generationAt = isoDate(from: value)
            } else if line == "aliases:" || line == "aliases: []" {
                if line == "aliases: []" { i += 1; continue }
                let (collected, consumed) = collectListItems(lines, startingAfter: i)
                aliases = collected
                i += consumed
            } else if line == "source_meetings:" || line == "source_meetings: []" {
                if line == "source_meetings: []" { i += 1; continue }
                let (collected, consumed) = collectListItems(lines, startingAfter: i)
                sourceMeetings = collected
                i += consumed
            }
            i += 1
        }

        guard let indexTypeRaw, !indexTypeRaw.isEmpty else {
            throw ParseError.unknownIndexType(indexTypeRaw ?? "<missing>")
        }
        // IndexKind is registry-backed now, so any non-empty slug parses —
        // entries from since-removed custom wikis still render via the
        // fallback spec.
        let kind = IndexKind(rawValue: indexTypeRaw)
        guard let canonicalName, !canonicalName.isEmpty else {
            throw ParseError.malformedFrontmatter("canonical_name missing")
        }

        let generation: GenerationMetadata?
        if let model = generationModel,
           let promptKind = generationPromptKind,
           let promptHash = generationPromptHash,
           let at = generationAt {
            generation = GenerationMetadata(
                model: model,
                promptKind: promptKind,
                promptHash: promptHash,
                generatedAt: at
            )
        } else {
            generation = nil
        }

        return IndexEntry(
            kind: kind,
            canonicalName: canonicalName,
            aliases: aliases,
            sourceMeetings: sourceMeetings,
            lastUpdated: lastUpdated ?? Date(),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            generation: generation
        )
    }

    static func render(_ entry: IndexEntry) -> String {
        var out = "---\n"
        out += "index_type: \(entry.kind.rawValue)\n"
        out += "canonical_name: \(yamlScalar(entry.canonicalName))\n"
        if entry.aliases.isEmpty {
            out += "aliases: []\n"
        } else {
            out += "aliases:\n"
            for alias in entry.aliases {
                out += "  - \(yamlScalar(alias))\n"
            }
        }
        if entry.sourceMeetings.isEmpty {
            out += "source_meetings: []\n"
        } else {
            out += "source_meetings:\n"
            for meeting in entry.sourceMeetings {
                out += "  - \(yamlScalar(meeting))\n"
            }
        }
        out += "last_updated: \(isoString(from: entry.lastUpdated))\n"
        if let gen = entry.generation {
            out += "generated_by_model: \(yamlScalar(gen.model))\n"
            out += "generated_by_prompt: \(yamlScalar(gen.promptKind))\n"
            out += "generated_by_hash: \(yamlScalar(gen.promptHash))\n"
            out += "generated_at: \(isoString(from: gen.generatedAt))\n"
        }
        out += "---\n\n"
        out += entry.body
        if !entry.body.hasSuffix("\n") { out += "\n" }
        return out
    }

    // MARK: - Tiny YAML helpers

    private static func scalarValue(line: String, key: String) -> String? {
        let prefix = "\(key):"
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return unquote(rest)
    }

    private static func collectListItems(_ lines: [String], startingAfter index: Int) -> (items: [String], consumed: Int) {
        var items: [String] = []
        var i = index + 1
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                items.append(unquote(String(trimmed.dropFirst(2))))
                i += 1
            } else if trimmed.isEmpty {
                i += 1
            } else {
                break
            }
        }
        return (items, i - index - 1)
    }

    private static func unquote(_ s: String) -> String {
        var v = s
        if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
            v = String(v.dropFirst().dropLast())
            v = v.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return v
    }

    /// Quote a YAML scalar if it contains characters that would confuse the parser.
    private static func yamlScalar(_ s: String) -> String {
        let needsQuotes = s.contains(":") || s.contains("#") || s.contains("\"") || s.contains("'") || s.hasPrefix(" ") || s.hasSuffix(" ") || s.isEmpty
        if needsQuotes {
            let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return s
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func isoString(from date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static func isoDate(from string: String) -> Date? {
        isoFormatter.date(from: string)
    }
}
