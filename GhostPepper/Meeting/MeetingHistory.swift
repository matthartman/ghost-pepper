import Foundation

/// A past meeting found on disk.
struct MeetingHistoryEntry: Identifiable, Hashable {
    let id: URL
    let name: String
    let dateFolder: String
    let fileURL: URL
    let isGranola: Bool

    var displayDate: String { dateFolder }
}

/// Scans the meeting save directory for past transcript markdown files.
enum MeetingHistory {
    /// Returns all meeting entries grouped by date folder, newest first.
    static func loadEntries(from baseDirectory: URL) -> [(date: String, entries: [MeetingHistoryEntry])] {
        let fm = FileManager.default
        guard let dateFolders = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var groups: [(date: String, entries: [MeetingHistoryEntry])] = []

        let sortedFolders = dateFolders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // newest date first

        for folder in sortedFolders {
            let dateFolder = folder.lastPathComponent
            guard let files = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            let mdFiles = files
                .filter { $0.pathExtension == "md" }
                .sorted {
                    // Sort by filename (contains the time slug) — stable and doesn't change on save
                    $0.lastPathComponent > $1.lastPathComponent
                }

            let entries = mdFiles.map { file in
                let (name, isGranola) = MeetingHistory.readHeader(from: file)
                let displayName = name
                    ?? file.deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: "-", with: " ")
                        .capitalized
                return MeetingHistoryEntry(
                    id: file,
                    name: displayName,
                    dateFolder: dateFolder,
                    fileURL: file,
                    isGranola: isGranola
                )
            }

            if !entries.isEmpty {
                groups.append((date: dateFolder, entries: entries))
            }
        }

        return groups
    }

    /// Read the title and source from a markdown file header without parsing the whole thing.
    private static func readHeader(from fileURL: URL) -> (title: String?, isGranola: Bool) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return (nil, false) }
        var title: String?
        var isGranola = false
        for line in content.components(separatedBy: .newlines) {
            if line.hasPrefix("# ") && title == nil {
                let t = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                title = t.isEmpty ? nil : t
            }
            if line.contains("imported_from: granola") || line.contains("imported_from:granola") {
                isGranola = true
            }
            // Stop after finding both or passing the frontmatter + title
            if title != nil && (isGranola || !line.hasPrefix("---") && !line.hasPrefix("#") && !line.isEmpty && title != nil) {
                break
            }
        }
        return (title, isGranola)
    }

    /// Read the persisted session id from a saved meeting's YAML frontmatter
    /// (`id: <uuid>`), without parsing the whole file. Returns nil for files that
    /// predate id persistence or whose id is missing/invalid.
    static func readSessionID(from fileURL: URL) -> UUID? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        var seenFence = false
        var result: UUID?
        content.enumerateLines { line, stop in
            if line == "---" {
                if seenFence { stop = true } else { seenFence = true }
                return
            }
            guard seenFence else {
                // No frontmatter fence before real content → no id.
                if !line.isEmpty { stop = true }
                return
            }
            if let id = sessionID(fromFrontmatterLine: line) {
                result = id
                stop = true
            }
        }
        return result
    }

    static func sessionID(fromFrontmatterLine line: String) -> UUID? {
        guard line.hasPrefix("id:") else { return nil }
        let raw = line.dropFirst("id:".count).trimmingCharacters(in: .whitespaces)
        return UUID(uuidString: raw)
    }

    /// All `.md` files under the date-foldered archive, without reading their contents.
    static func markdownFileURLs(in baseDirectory: URL) -> [URL] {
        let fm = FileManager.default
        guard let dateFolders = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return dateFolders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .flatMap { folder -> [URL] in
                let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                return files.filter { $0.pathExtension == "md" }
            }
    }

    /// Stat'd once per URL (decorate-max), not per comparison.
    static func newestByModificationDate(_ urls: [URL]) -> URL? {
        urls.map { ($0, modificationDate(of: $0)) }.max { $0.1 < $1.1 }?.0
    }

    static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

/// In-memory `sessionID → fileURL` index for resolving `open-meeting?id=…`.
///
/// Built once at launch by scanning the archive's frontmatter (off the main actor),
/// and a recorded meeting is also registered in-process when it finishes. Avoids an
/// O(n) disk scan on `@MainActor` per call. Files written by other paths (reader
/// captures) or by another process are picked up at the next launch; an unresolved
/// id falls back to `path`, and an active meeting resolves directly from its known
/// file URL. A copied meeting file can yield duplicate ids; those resolve
/// deterministically to the newest by modification time.
actor MeetingSessionIndex {
    private var map: [UUID: [URL]] = [:]
    private var built = false

    /// Build the index once; subsequent calls are no-ops. Use `build(from:)` to rebuild.
    func ensureBuilt(from baseDirectory: URL) {
        guard !built else { return }
        build(from: baseDirectory)
    }

    func build(from baseDirectory: URL) {
        var fresh: [UUID: [URL]] = [:]
        for url in MeetingHistory.markdownFileURLs(in: baseDirectory) {
            guard let id = MeetingHistory.readSessionID(from: url) else { continue }
            fresh[id, default: []].append(url)
        }
        map = fresh
        built = true
    }

    /// Called when a meeting is saved.
    func register(sessionID: UUID, url: URL) {
        var urls = map[sessionID] ?? []
        if !urls.contains(url) { urls.append(url) }
        map[sessionID] = urls
    }

    /// Resolve a session id to a file, preferring the newest existing file by mtime.
    func resolve(_ id: UUID) -> URL? {
        let candidates = (map[id] ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
        return MeetingHistory.newestByModificationDate(candidates)
    }
}
