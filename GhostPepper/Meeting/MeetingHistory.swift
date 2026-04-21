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
}
