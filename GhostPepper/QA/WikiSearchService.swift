import Foundation

struct WikiSearchHit: Equatable {
    enum SourceKind: String, Hashable {
        case wiki
        case meeting
    }

    let title: String
    let relativePath: String
    let lineStart: Int
    let lineEnd: Int
    let text: String
    let sourceKind: SourceKind
    let score: Double

    var citation: String {
        lineStart == lineEnd ? "\(relativePath):\(lineStart)" : "\(relativePath):\(lineStart)-\(lineEnd)"
    }
}

final class WikiSearchService {
    private struct DocumentChunk {
        let title: String
        let relativePath: String
        let lineStart: Int
        let lineEnd: Int
        let text: String
        let sourceKind: WikiSearchHit.SourceKind
        let tokenCounts: [String: Int]
    }

    private struct CacheEntry {
        let fingerprint: String
        let chunks: [DocumentChunk]
    }

    private static var cache: [String: CacheEntry] = [:]
    private static let cacheLock = NSLock()

    let archiveRoot: URL

    init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot.standardizedFileURL
    }

    func search(query: String, limit: Int = 10) throws -> [WikiSearchHit] {
        try search(query: query, limit: limit, sourceKinds: [.wiki, .meeting], allowedRelativePaths: nil)
    }

    func searchWiki(query: String, limit: Int = 8) throws -> [WikiSearchHit] {
        try search(query: query, limit: limit, sourceKinds: [.wiki], allowedRelativePaths: nil)
    }

    func allWikiPages(limit: Int = 80) throws -> [WikiSearchHit] {
        try indexedChunks()
            .filter { $0.sourceKind == .wiki }
            .sorted {
                if $0.relativePath == $1.relativePath {
                    return $0.lineStart < $1.lineStart
                }
                return $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
            }
            .prefix(max(1, limit))
            .map { chunk in
                WikiSearchHit(
                    title: chunk.title,
                    relativePath: chunk.relativePath,
                    lineStart: chunk.lineStart,
                    lineEnd: chunk.lineEnd,
                    text: chunk.text,
                    sourceKind: chunk.sourceKind,
                    score: 0
                )
            }
    }

    func searchMeetings(query: String, sourcePaths: Set<String>? = nil, limit: Int = 8) throws -> [WikiSearchHit] {
        try search(query: query, limit: limit, sourceKinds: [.meeting], allowedRelativePaths: sourcePaths)
    }

    func sourceMeetingPaths(from wikiHits: [WikiSearchHit]) -> Set<String> {
        var paths = Set<String>()
        let pattern = #"\b\d{4}-\d{2}-\d{2}/[A-Za-z0-9_\-\.]+\.md\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for hit in wikiHits {
            let text = "\(hit.relativePath)\n\(hit.text)"
            let ns = text as NSString
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match else { return }
                paths.insert(ns.substring(with: match.range))
            }
        }
        return paths
    }

    func sourceSeedQuery(question: String, wikiHits: [WikiSearchHit]) -> String {
        let titles = wikiHits.prefix(5).map(\.title).joined(separator: " ")
        return "\(question) \(titles)"
    }

    private func search(
        query: String,
        limit: Int,
        sourceKinds: Set<WikiSearchHit.SourceKind>,
        allowedRelativePaths: Set<String>?
    ) throws -> [WikiSearchHit] {
        let chunks = try indexedChunks()
        let queryTokens = Self.tokens(in: query)
        let queryPhrase = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !queryTokens.isEmpty || !queryPhrase.isEmpty else { return [] }

        let scored = chunks.compactMap { chunk -> WikiSearchHit? in
            guard sourceKinds.contains(chunk.sourceKind) else { return nil }
            if let allowedRelativePaths, !allowedRelativePaths.contains(chunk.relativePath) {
                return nil
            }
            let title = chunk.title.lowercased()
            let path = chunk.relativePath.lowercased()
            let text = chunk.text.lowercased()
            var score = 0.0

            if !queryPhrase.isEmpty && text.contains(queryPhrase) {
                score += 24
            }
            if !queryPhrase.isEmpty && title.contains(queryPhrase) {
                score += 18
            }

            for token in queryTokens {
                let count = chunk.tokenCounts[token] ?? 0
                guard count > 0 || title.contains(token) || path.contains(token) else { continue }
                score += min(Double(count), 8)
                if title.contains(token) { score += 8 }
                if path.contains(token) { score += 3 }
            }

            if chunk.sourceKind == .wiki {
                score += 4
                if chunk.relativePath.contains("/meetings/") { score += 2 }
            }
            guard score > 0 else { return nil }
            return WikiSearchHit(
                title: chunk.title,
                relativePath: chunk.relativePath,
                lineStart: chunk.lineStart,
                lineEnd: chunk.lineEnd,
                text: chunk.text,
                sourceKind: chunk.sourceKind,
                score: score
            )
        }

        return scored
            .sorted {
                if $0.score == $1.score {
                    return $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
                }
                return $0.score > $1.score
            }
            .prefix(max(1, limit))
            .map { $0 }
    }

    func formattedContext(for hits: [WikiSearchHit], characterLimit: Int = 16_000) -> String {
        var remaining = characterLimit
        var blocks: [String] = []
        for (index, hit) in hits.enumerated() {
            var snippet = hit.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if snippet.count > 1600 {
                snippet = String(snippet.prefix(1600)) + "\n...[truncated]"
            }
            let block = """
            [\(index + 1)] \(hit.title)
            Source: \(hit.citation)
            Type: \(hit.sourceKind.rawValue)
            \(snippet)
            """
            guard block.count <= remaining else { break }
            blocks.append(block)
            remaining -= block.count
        }
        return blocks.joined(separator: "\n\n---\n\n")
    }

    func formattedTrace(for hits: [WikiSearchHit]) -> String {
        guard !hits.isEmpty else { return "No local 2nd Brain/meeting search results." }
        return hits.enumerated().map { index, hit in
            let score = String(format: "%.1f", hit.score)
            return "\(index + 1). \(hit.citation) · \(hit.sourceKind.rawValue) · score \(score)\n   \(hit.title)"
        }.joined(separator: "\n")
    }

    private func indexedChunks() throws -> [DocumentChunk] {
        let files = try markdownFiles()
        let fingerprint = files.map { item in
            "\(item.url.path):\(Int(item.modified.timeIntervalSince1970)):\(item.size)"
        }.joined(separator: "|")
        let cacheKey = archiveRoot.path

        Self.cacheLock.lock()
        if let cached = Self.cache[cacheKey], cached.fingerprint == fingerprint {
            Self.cacheLock.unlock()
            return cached.chunks
        }
        Self.cacheLock.unlock()

        let chunks = files.flatMap { item -> [DocumentChunk] in
            guard let text = try? String(contentsOf: item.url, encoding: .utf8) else { return [] }
            return Self.chunks(for: text, url: item.url, archiveRoot: archiveRoot)
        }

        Self.cacheLock.lock()
        Self.cache[cacheKey] = CacheEntry(fingerprint: fingerprint, chunks: chunks)
        Self.cacheLock.unlock()
        return chunks
    }

    private func markdownFiles() throws -> [(url: URL, modified: Date, size: Int64)] {
        guard let enumerator = FileManager.default.enumerator(
            at: archiveRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var out: [(URL, Date, Int64)] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name == ".git" || name == "node_modules" {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "md" else { continue }
            let relative = Self.relativePath(for: url, root: archiveRoot)
            guard Self.shouldIndex(relativePath: relative) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            out.append((url, values.contentModificationDate ?? .distantPast, Int64(values.fileSize ?? 0)))
        }
        return out
    }

    private static func shouldIndex(relativePath: String) -> Bool {
        if relativePath.hasPrefix("wikis/") { return true }
        if relativePath.hasPrefix(".indexes/") { return false }
        if relativePath.hasPrefix("Airtable/") { return false }
        guard relativePath.count >= 11 else { return false }
        let prefix = String(relativePath.prefix(11))
        return prefix.range(of: #"^\d{4}-\d{2}-\d{2}/"#, options: .regularExpression) != nil
    }

    private static func chunks(for text: String, url: URL, archiveRoot: URL) -> [DocumentChunk] {
        let relative = relativePath(for: url, root: archiveRoot)
        let kind: WikiSearchHit.SourceKind = relative.hasPrefix("wikis/") ? .wiki : .meeting
        let lines = text.components(separatedBy: "\n")
        let title = title(in: lines) ?? url.deletingPathExtension().lastPathComponent

        if kind == .wiki || lines.count <= 120 {
            let body = numberedExcerpt(lines: lines, startLine: 1, endLine: lines.count)
            return [
                DocumentChunk(
                    title: title,
                    relativePath: relative,
                    lineStart: 1,
                    lineEnd: max(1, lines.count),
                    text: body,
                    sourceKind: kind,
                    tokenCounts: tokenCounts(in: "\(title)\n\(relative)\n\(body)")
                )
            ]
        }

        var chunks: [DocumentChunk] = []
        let chunkSize = 90
        let overlap = 18
        var start = 0
        while start < lines.count {
            let end = min(lines.count, start + chunkSize)
            let body = numberedExcerpt(lines: lines, startLine: start + 1, endLine: end)
            chunks.append(DocumentChunk(
                title: title,
                relativePath: relative,
                lineStart: start + 1,
                lineEnd: end,
                text: body,
                sourceKind: kind,
                tokenCounts: tokenCounts(in: "\(title)\n\(relative)\n\(body)")
            ))
            if end == lines.count { break }
            start = max(start + 1, end - overlap)
        }
        return chunks
    }

    private static func numberedExcerpt(lines: [String], startLine: Int, endLine: Int) -> String {
        guard !lines.isEmpty else { return "" }
        let safeStart = max(1, startLine)
        let safeEnd = min(lines.count, max(safeStart, endLine))
        return lines[(safeStart - 1)..<safeEnd].enumerated().map { index, line in
            "L\(safeStart + index): \(line)"
        }.joined(separator: "\n")
    }

    private static func title(in lines: [String]) -> String? {
        for line in lines.prefix(80) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("title:") {
                return trimmed
                    .dropFirst("title:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func tokenCounts(in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in tokens(in: text) {
            counts[token, default: 0] += 1
        }
        return counts
    }

    private static func tokens(in text: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "and", "for", "with", "that", "this", "from", "what", "when", "where",
            "which", "about", "into", "onto", "their", "there", "then", "than", "have",
            "has", "had", "was", "were", "are", "who", "how", "why", "did", "does",
            "can", "could", "would", "should", "you", "your", "they", "them", "our"
        ]
        return text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }
}
