import Foundation

enum MarkdownArchivePaths {
    static let indexesFolderName = ".indexes"

    static func indexesRoot(in saveDir: URL) -> URL {
        saveDir.appendingPathComponent(indexesFolderName, isDirectory: true)
    }

    static func indexRoot(in saveDir: URL, kind: IndexKind) -> URL {
        indexesRoot(in: saveDir).appendingPathComponent(kind.subdirectory, isDirectory: true)
    }

    static func manifestURL(in saveDir: URL, kind: IndexKind) -> URL {
        indexRoot(in: saveDir, kind: kind).appendingPathComponent("_manifest.json")
    }

    static func entryURL(in saveDir: URL, kind: IndexKind, slug: String) -> URL {
        indexRoot(in: saveDir, kind: kind).appendingPathComponent("\(slug).md")
    }

    /// File-safe slug for an index entry's canonical name. Lowercased,
    /// non-alphanumeric collapsed to dashes, trimmed, capped at 60 chars.
    /// "John Smith" → "john-smith"; "Jordan Pike (eng)" → "jordan-pike-eng".
    static func slugForIndexEntry(_ canonicalName: String) -> String {
        let lowered = canonicalName.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let mapped = lowered.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let collapsed = mapped.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let capped = trimmed.count > 60 ? String(trimmed.prefix(60)) : trimmed
        return capped.isEmpty ? "untitled" : capped
    }
}
