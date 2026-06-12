import Foundation

/// Imports meeting notes from Granola's local cache and API into Ghost Pepper's markdown format.
@MainActor
final class GranolaImporter: ObservableObject {
    enum ImportState: Equatable {
        case idle
        case importingLocal
        case localDone(count: Int)
        case needsApiKey
        case fetchingNotes(current: Int, total: Int)
        case done(imported: Int, transcripts: Int)
        case error(String)

        static func == (lhs: ImportState, rhs: ImportState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.importingLocal, .importingLocal): return true
            case (.localDone(let a), .localDone(let b)): return a == b
            case (.needsApiKey, .needsApiKey): return true
            case (.fetchingNotes(let a1, let a2), .fetchingNotes(let b1, let b2)): return a1 == b1 && a2 == b2
            case (.done(let a1, let a2), .done(let b1, let b2)): return a1 == b1 && a2 == b2
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    @Published var state: ImportState = .idle
    @Published var granolaApiKey: String = UserDefaults.standard.string(forKey: "granolaApiKey") ?? "" {
        didSet { UserDefaults.standard.set(granolaApiKey, forKey: "granolaApiKey") }
    }

    nonisolated private static let cachePath = NSHomeDirectory() + "/Library/Application Support/Granola/cache-v6.json"
    private static let debugLogPath = "/tmp/granola_import_debug.log"
    /// Suffix appended to every local-cache failure message so the user
    /// knows the API path is still a live option.
    private static let apiPivotHint = "Use the API-key path below — get a key from Granola Settings → API Key → Create new key."

    private static func debugLog(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: debugLogPath) {
                if let handle = FileHandle(forWritingAtPath: debugLogPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: debugLogPath, contents: data)
            }
        }
    }

    /// Whether the Granola cache file exists on disk.
    static var isCacheAvailable: Bool {
        FileManager.default.fileExists(atPath: cachePath)
    }

    /// Count of valid Granola documents whose target markdown file does not yet exist
    /// in the meetings save directory. Mirrors the dedup logic in `importFromLocalCache`
    /// so the count matches what an actual sync would write. Returns nil if cache is
    /// missing or unreadable.
    nonisolated static func pendingImportCount(savedTo directory: URL) -> Int? {
        guard let data = FileManager.default.contents(atPath: cachePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = json["cache"] as? [String: Any],
              let stateDict = cache["state"] as? [String: Any],
              let documents = stateDict["documents"] as? [String: [String: Any]] else {
            return nil
        }

        var pending = 0
        for (_, doc) in documents {
            if doc["deleted_at"] != nil && !(doc["deleted_at"] is NSNull) { continue }
            if let valid = doc["valid_meeting"] as? Bool, !valid { continue }
            let notesMd = doc["notes_markdown"] as? String
            let notesPlain = doc["notes_plain"] as? String
            let summary = doc["summary"] as? String
            guard (notesMd?.isEmpty == false) || (notesPlain?.isEmpty == false) || (summary?.isEmpty == false) else { continue }

            let title = (doc["title"] as? String) ?? "Untitled"
            let createdAt = doc["created_at"] as? String ?? ""
            let dateFolder = Self.dateFolder(from: createdAt)
            let slug = Self.slugify(title)
            let filePath = directory
                .appendingPathComponent(dateFolder)
                .appendingPathComponent("\(slug).md")
            if !FileManager.default.fileExists(atPath: filePath.path) {
                pending += 1
            }
        }
        return pending
    }

    // MARK: - Local Cache Import

    func importFromLocalCache(to directory: URL) async -> Int {
        state = .importingLocal

        guard let data = FileManager.default.contents(atPath: Self.cachePath) else {
            state = .error("Could not read Granola cache file. \(Self.apiPivotHint)")
            return 0
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = json["cache"] as? [String: Any],
              let stateDict = cache["state"] as? [String: Any],
              let documents = stateDict["documents"] as? [String: [String: Any]] else {
            // Granola v6 ships an encrypted store alongside the plain JSON;
            // when the plain file is just UI state without `documents`, the
            // encrypted sibling is where the actual data lives.
            let encryptedPath = Self.cachePath + ".enc"
            if FileManager.default.fileExists(atPath: encryptedPath) {
                state = .error("Granola v6 encrypts its local cache (cache-v6.json.enc). The local-cache importer can't read it. \(Self.apiPivotHint)")
            } else {
                state = .error("Could not parse Granola cache structure. \(Self.apiPivotHint)")
            }
            return 0
        }

        var written = 0

        for (docId, doc) in documents {
            // Skip deleted
            if doc["deleted_at"] != nil && !(doc["deleted_at"] is NSNull) { continue }

            // Skip invalid meetings
            if let valid = doc["valid_meeting"] as? Bool, !valid { continue }

            // Skip empty
            let notesMd = doc["notes_markdown"] as? String
            let notesPlain = doc["notes_plain"] as? String
            let summary = doc["summary"] as? String
            guard (notesMd != nil && !notesMd!.isEmpty) ||
                  (notesPlain != nil && !notesPlain!.isEmpty) ||
                  (summary != nil && !summary!.isEmpty) else { continue }

            let title = (doc["title"] as? String) ?? "Untitled"
            let createdAt = doc["created_at"] as? String ?? ""

            // Date folder
            let dateFolder = Self.dateFolder(from: createdAt)
            let slug = Self.slugify(title)
            let dir = directory.appendingPathComponent(dateFolder)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let filePath = dir.appendingPathComponent("\(slug).md")

            // Skip existing
            if FileManager.default.fileExists(atPath: filePath.path) { continue }

            // Build markdown
            let markdown = Self.buildMarkdown(
                docId: docId,
                title: title,
                createdAt: createdAt,
                summary: summary,
                notes: notesMd ?? notesPlain,
                chapters: doc["chapters"] as? [[String: Any]],
                people: doc["people"]
            )

            try? markdown.write(to: filePath, atomically: true, encoding: .utf8)
            written += 1
        }

        state = .localDone(count: written)
        return written
    }

    // MARK: - API Transcript Fetching

    func fetchTranscripts(apiKey: String, to directory: URL) async -> Int {
        guard !apiKey.isEmpty else {
            state = .error("API key is required.")
            return 0
        }

        // Fetch all notes — show loading state during pagination
        state = .fetchingNotes(current: 0, total: 0)
        var allNotes: [[String: Any]] = []
        var cursor: String? = nil

        repeat {
            var urlStr = "https://public-api.granola.ai/v1/notes?limit=100"
            if let c = cursor { urlStr += "&cursor=\(c)" }

            guard let url = URL(string: urlStr) else { break }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let result: (Data, URLResponse)
            do {
                result = try await URLSession.shared.data(for: request)
            } catch {
                Self.debugLog("[GranolaImporter] Network error fetching notes list: \(error)")
                state = .error("Network error: \(error.localizedDescription)")
                return 0
            }
            let (data, response) = result
            let httpResp = response as? HTTPURLResponse
            Self.debugLog("[GranolaImporter] Notes list response: HTTP \(httpResp?.statusCode ?? -1), \(data.count) bytes")

            guard let statusCode = httpResp?.statusCode, statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
                Self.debugLog("[GranolaImporter] API error body: \(body)")
                state = .error("Failed to fetch notes from Granola API (HTTP \(httpResp?.statusCode ?? -1)).")
                return 0
            }

            let notes = (json["notes"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) ?? []
            let hasMore = json["hasMore"] as? Bool ?? false
            let nextCursor = json["cursor"] as? String
            Self.debugLog("[GranolaImporter] Got \(notes.count) notes, cursor: \(cursor ?? "nil"), nextCursor: \(nextCursor ?? "nil"), hasMore: \(hasMore)")
            allNotes.append(contentsOf: notes)

            if !hasMore || nextCursor == nil || nextCursor == cursor { break }
            cursor = nextCursor

            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s rate limit
        } while cursor != nil

        let total = allNotes.count
        Self.debugLog("[GranolaImporter] Total notes from API: \(total), saving to: \(directory.path)")
        // Log first note's keys to understand API structure
        if let first = allNotes.first {
            Self.debugLog("[GranolaImporter] First note keys: \(first.keys.sorted())")
            Self.debugLog("[GranolaImporter] First note title: \(first["title"] ?? "nil")")
        }
        // Find the clawdbot note specifically
        for note in allNotes {
            let t = (note["title"] as? String) ?? ""
            if t.lowercased().contains("clawdbot") || t.lowercased().contains("tools for thinking") {
                Self.debugLog("[GranolaImporter] FOUND clawdbot note: id=\(note["id"] ?? "nil") title=\(t)")
                Self.debugLog("[GranolaImporter] clawdbot note keys: \(note.keys.sorted())")
            }
        }
        var enriched = 0

        for (i, note) in allNotes.enumerated() {
            state = .fetchingNotes(current: i + 1, total: total)

            guard let noteId = note["id"] as? String else { continue }
            let title = (note["title"] as? String) ?? "Untitled"
            let createdAt = note["created_at"] as? String ?? ""

            let dateFolder = Self.dateFolder(from: createdAt)
            let slug = Self.slugify(title)
            let filePath = directory.appendingPathComponent(dateFolder).appendingPathComponent("\(slug).md")

            // Skip only if the file already has real transcript and summary
            // content. Placeholder sections from native Ghost Pepper notes
            // should still be eligible for Granola enrichment.
            let fileExists = FileManager.default.fileExists(atPath: filePath.path)
            if fileExists {
                if let existing = try? String(contentsOf: filePath, encoding: .utf8),
                   Self.sectionHasRealContent(in: existing, header: "Transcript"),
                   Self.sectionHasRealContent(in: existing, header: "Summary") { continue }
            }

            // Fetch with transcript
            guard let url = URL(string: "https://public-api.granola.ai/v1/notes/\(noteId)?include=transcript") else { continue }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let noteResult: (Data, URLResponse)
            do {
                noteResult = try await URLSession.shared.data(for: request)
            } catch {
                Self.debugLog("[GranolaImporter] Network error fetching note \(noteId): \(error)")
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            let (noteData, noteResponse) = noteResult
            guard let noteHttpResp = noteResponse as? HTTPURLResponse, noteHttpResp.statusCode == 200,
                  let fullNote = try? JSONSerialization.jsonObject(with: noteData) as? [String: Any] else {
                let statusCode = (noteResponse as? HTTPURLResponse)?.statusCode ?? -1
                Self.debugLog("[GranolaImporter] Failed to fetch note \(noteId) '\(title)': HTTP \(statusCode)")
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }

            if title.lowercased().contains("clawdbot") {
                Self.debugLog("[GranolaImporter] clawdbot full note keys: \(fullNote.keys.sorted())")
                for (k, v) in fullNote {
                    let desc = "\(type(of: v)): \(String(describing: v).prefix(200))"
                    Self.debugLog("[GranolaImporter] clawdbot.\(k) = \(desc)")
                }
            }

            // Diagnostic: log every API response's top-level keys plus a
            // truncated peek at each value. Users (specifically Matt) need
            // this to find where Granola stashes user-typed panel notes.
            // Once we know the field name, this can be removed or gated.
            Self.debugLog("[GranolaImporter] API keys for \(title.prefix(60)): \(fullNote.keys.sorted())")
            for (k, v) in fullNote.sorted(by: { $0.key < $1.key }) {
                let typeDesc = String(describing: type(of: v))
                let valuePeek = String(describing: v).prefix(160).replacingOccurrences(of: "\n", with: " ")
                Self.debugLog("[GranolaImporter]   \(k) (\(typeDesc)): \(valuePeek)")
            }

            // Extract content from API response
            // API uses summary_markdown/summary_text (not "summary") and no separate notes/chapters fields
            let transcript = Self.extractTranscript(from: fullNote["transcript"])
            let apiSummary = (fullNote["summary_markdown"] as? String)
                ?? (fullNote["summary_text"] as? String)
                ?? (fullNote["summary"] as? String)
            let apiNotes = (fullNote["notes_markdown"] as? String) ?? (fullNote["notes"] as? String)
            let apiChapters = fullNote["chapters"] as? [[String: Any]]

            // Skip if note has no content at all
            let hasContent = !transcript.isEmpty
                || (apiSummary != nil && !apiSummary!.isEmpty)
                || (apiNotes != nil && !apiNotes!.isEmpty)
                || (apiChapters != nil && !apiChapters!.isEmpty)

            guard hasContent else {
                Self.debugLog("[GranolaImporter] Skipping \(title) — no content from API")
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }

            // Merge with whatever's already on disk so we don't clobber
            // user-typed Notes (or any other section) when the API response
            // is missing that field.
            let existingMarkdown: String? = fileExists
                ? (try? String(contentsOf: filePath, encoding: .utf8))
                : nil
            let existingNotes = existingMarkdown.flatMap { Self.extractSectionBody(from: $0, header: "Notes") }
            let existingSummary = existingMarkdown.flatMap { Self.extractSectionBody(from: $0, header: "Summary") }
            let existingTranscript = existingMarkdown.flatMap { Self.extractSectionBody(from: $0, header: "Transcript") }
            let existingChapters = existingMarkdown.flatMap { Self.extractSectionBody(from: $0, header: "Chapters") }

            let mergedNotes = (apiNotes?.isEmpty == false ? apiNotes : existingNotes)
            let mergedSummary = (apiSummary?.isEmpty == false ? apiSummary : existingSummary)
            let mergedTranscript = !transcript.isEmpty ? transcript : (existingTranscript ?? "")
            // For chapters: prefer the structured API array; otherwise fall
            // back to whatever was already in the file as preformatted body.
            let mergedChaptersMarkdown: String? = (apiChapters?.isEmpty == false) ? nil : existingChapters

            Self.debugLog("[GranolaImporter] Writing \(title) — transcript:\(!mergedTranscript.isEmpty) summary:\(mergedSummary != nil) notes:\(mergedNotes != nil) chapters:\(apiChapters != nil ? "api" : (existingChapters != nil ? "existing" : "none"))")

            // Build full markdown with all available content
            let markdown = Self.buildMarkdown(
                docId: noteId,
                title: title,
                createdAt: createdAt,
                summary: mergedSummary,
                notes: mergedNotes,
                chapters: apiChapters,
                people: fullNote["people"],
                transcript: mergedTranscript.isEmpty ? nil : mergedTranscript,
                chaptersMarkdown: mergedChaptersMarkdown
            )

            let dir = directory.appendingPathComponent(dateFolder)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? markdown.write(to: filePath, atomically: true, encoding: .utf8)
            enriched += 1

            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        return enriched
    }

    // MARK: - Helpers

    nonisolated private static func dateFolder(from createdAt: String) -> String {
        guard !createdAt.isEmpty else { return "undated" }
        // Parse ISO date: "2026-03-10T14:30:00.000Z"
        let parts = createdAt.prefix(10) // "2026-03-10"
        return parts.count == 10 ? String(parts) : "undated"
    }

    nonisolated static func slugify(_ title: String?) -> String {
        guard let title = title, !title.isEmpty else { return "untitled" }
        var slug = title.lowercased()
        slug = slug.replacingOccurrences(of: "[^\\w\\s-]", with: "", options: .regularExpression)
        slug = slug.replacingOccurrences(of: "[\\s_]+", with: "-", options: .regularExpression)
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > 60 { slug = String(slug.prefix(60)) }
        return slug.isEmpty ? "untitled" : slug
    }

    private static func extractAttendees(from people: Any?) -> [String] {
        guard let people = people else { return [] }

        if let dict = people as? [String: Any],
           let attendees = dict["attendees"] as? [[String: Any]] {
            return attendees.compactMap { a in
                (a["details"] as? [String: Any]).flatMap { d in
                    (d["person"] as? [String: Any]).flatMap { p in
                        (p["name"] as? [String: Any])?["fullName"] as? String
                    }
                }
            }
        }

        if let list = people as? [Any] {
            return list.compactMap { p in
                if let s = p as? String { return s }
                if let d = p as? [String: Any] {
                    return (d["name"] as? String) ?? (d["fullName"] as? String)
                }
                return nil
            }
        }

        return []
    }

    /// Extracts the body of a `## <header>` section from an existing markdown
    /// file. Used during API enrichment to preserve sections the API didn't
    /// re-supply. Returns the section body trimmed of surrounding whitespace,
    /// or nil if the header isn't present.
    private static func extractSectionBody(from markdown: String, header: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        let target = "## \(header)"
        var inSection = false
        var collected: [String] = []
        for line in lines {
            if line == target {
                inSection = true
                continue
            }
            if inSection {
                if line.hasPrefix("## ") { break }
                collected.append(line)
            }
        }
        guard inSection else { return nil }
        let joined = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.isEmpty { return nil }

        switch header {
        case "Notes" where joined == "*No notes.*" || joined == "*No notes yet.*":
            return nil
        case "Transcript" where joined == "*No transcript yet.*":
            return nil
        default:
            return joined
        }
    }

    private static func sectionHasRealContent(in markdown: String, header: String) -> Bool {
        extractSectionBody(from: markdown, header: header) != nil
    }

    private static func extractTranscript(from transcriptData: Any?) -> String {
        guard let data = transcriptData else { return "" }

        if let list = data as? [[String: Any]] {
            return list.compactMap { entry -> String? in
                let speaker = (entry["speaker"] as? String) ?? (entry["name"] as? String) ?? ""
                let text = (entry["text"] as? String) ?? (entry["content"] as? String) ?? ""
                guard !text.isEmpty else { return nil }
                return speaker.isEmpty ? text : "**\(speaker):** \(text)"
            }.joined(separator: "\n\n")
        }

        if let str = data as? String { return str }

        return ""
    }

    private static func buildMarkdown(
        docId: String,
        title: String,
        createdAt: String,
        summary: String?,
        notes: String?,
        chapters: [[String: Any]]?,
        people: Any?,
        transcript: String? = nil,
        chaptersMarkdown: String? = nil
    ) -> String {
        let attendees = extractAttendees(from: people)

        var lines: [String] = []

        // Frontmatter
        lines.append("---")
        lines.append("title: \"\(title.replacingOccurrences(of: "\"", with: "\\\""))\"")
        if !createdAt.isEmpty { lines.append("date: \"\(createdAt)\"") }
        lines.append("granola_id: \"\(docId)\"")
        if !attendees.isEmpty { lines.append("attendees: [\(attendees.map { "\"\($0)\"" }.joined(separator: ", "))]") }
        lines.append("source_type: meeting")
        lines.append("imported_from: granola")
        lines.append("---")
        lines.append("")

        // Title
        lines.append("# \(title)")
        lines.append("")
        if !attendees.isEmpty {
            lines.append("**Attendees:** \(attendees.joined(separator: ", "))")
            lines.append("")
        }

        // Summary
        if let summary = summary, !summary.isEmpty {
            lines.append("## Summary")
            lines.append("")
            lines.append(summary)
            lines.append("")
        }

        // Notes
        if let notes = notes, !notes.isEmpty {
            lines.append("## Notes")
            lines.append("")
            lines.append(notes)
            lines.append("")
        }

        // Chapters — prefer the structured array; fall back to a preformatted
        // body (used when merging from an existing file that the API didn't
        // re-supply chapters for).
        if let chapters = chapters, !chapters.isEmpty {
            lines.append("## Chapters")
            lines.append("")
            for ch in chapters {
                let chTitle = (ch["title"] as? String) ?? (ch["heading"] as? String) ?? ""
                let chContent = (ch["summary"] as? String) ?? (ch["content"] as? String) ?? ""
                if !chTitle.isEmpty {
                    lines.append("### \(chTitle)")
                    lines.append("")
                }
                if !chContent.isEmpty {
                    lines.append(chContent)
                    lines.append("")
                }
            }
        } else if let chaptersMarkdown = chaptersMarkdown, !chaptersMarkdown.isEmpty {
            lines.append("## Chapters")
            lines.append("")
            lines.append(chaptersMarkdown)
            lines.append("")
        }

        // Transcript
        if let transcript = transcript, !transcript.isEmpty {
            lines.append("## Transcript")
            lines.append("")
            lines.append(transcript)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
