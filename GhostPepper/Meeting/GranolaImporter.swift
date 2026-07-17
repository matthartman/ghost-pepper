import Foundation

/// Imports meeting notes from Granola's public API into Ghost Pepper's markdown format.
@MainActor
final class GranolaImporter: ObservableObject {
    enum ImportState: Equatable {
        case idle
        case needsApiKey
        case fetchingNotes(current: Int, total: Int)
        case done(imported: Int, transcripts: Int, enriched: Int)
        case error(String)

        static func == (lhs: ImportState, rhs: ImportState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.needsApiKey, .needsApiKey): return true
            case (.fetchingNotes(let a1, let a2), .fetchingNotes(let b1, let b2)): return a1 == b1 && a2 == b2
            case (.done(let a1, let a2, let a3), .done(let b1, let b2, let b3)): return a1 == b1 && a2 == b2 && a3 == b3
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    @Published var state: ImportState = .idle
    static let granolaApiKeyKeychainKey = "granolaApiKey"
    @Published var granolaApiKey: String = KeychainHelper.migrateUserDefaultsString(
        defaultsKey: GranolaImporter.granolaApiKeyKeychainKey,
        keychainKey: GranolaImporter.granolaApiKeyKeychainKey
    ) ?? "" {
        didSet { _ = KeychainHelper.set(granolaApiKey, for: Self.granolaApiKeyKeychainKey) }
    }

    private static func debugLog(_ msg: @autoclosure () -> String) {
        #if DEBUG
        let message = msg()
        if message.contains("HTTP") || message.contains("Total notes") {
            print(message)
        }
        #endif
    }

    static var isInstalled: Bool {
        [
            "/Applications/Granola.app",
            NSHomeDirectory() + "/Applications/Granola.app"
        ].contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Local Granola cache reads are intentionally disabled. Import uses only
    /// Granola's public API after the user provides an API key.
    nonisolated static func pendingImportCount(savedTo directory: URL) -> Int? {
        nil
    }

    // MARK: - API Transcript Fetching

    func fetchTranscripts(apiKey: String, to directory: URL) async -> (imported: Int, transcripts: Int, enriched: Int) {
        guard !apiKey.isEmpty else {
            state = .error("API key is required.")
            return (0, 0, 0)
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
                return (0, 0, 0)
            }
            let (data, response) = result
            let httpResp = response as? HTTPURLResponse
            Self.debugLog("[GranolaImporter] Notes list response: HTTP \(httpResp?.statusCode ?? -1), \(data.count) bytes")

            guard let statusCode = httpResp?.statusCode, statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Self.debugLog("[GranolaImporter] Failed notes list response: HTTP \(httpResp?.statusCode ?? -1), \(data.count) bytes")
                state = .error("Failed to fetch notes from Granola API (HTTP \(httpResp?.statusCode ?? -1)).")
                return (0, 0, 0)
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
        // Log structural metadata only; note titles and values can contain private content.
        if let first = allNotes.first {
            Self.debugLog("[GranolaImporter] First note keys: \(first.keys.sorted())")
        }
        var imported = 0
        var transcriptCount = 0
        var enriched = 0

        for (i, note) in allNotes.enumerated() {
            state = .fetchingNotes(current: i + 1, total: total)

            guard let noteId = note["id"] as? String else { continue }
            let title = (note["title"] as? String) ?? "Untitled"
            let createdAt = note["created_at"] as? String ?? ""

            let dateFolder = Self.dateFolder(from: createdAt)
            let slug = Self.slugify(title)
            let filePath = directory.appendingPathComponent(dateFolder).appendingPathComponent("\(slug).md")

            let fileExists = FileManager.default.fileExists(atPath: filePath.path)
            let existingBeforeFetch = fileExists ? (try? String(contentsOf: filePath, encoding: .utf8)) : nil
            if fileExists {
                if let existing = existingBeforeFetch,
                   Self.hasRealTranscriptSection(existing),
                   existing.contains("## Summary"),
                   Self.hasGranolaEnrichment(existing) {
                    continue
                }
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

            Self.debugLog("[GranolaImporter] API keys for note: \(fullNote.keys.sorted())")

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
                ? existingBeforeFetch
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
                chaptersMarkdown: mergedChaptersMarkdown,
                rawGranolaPayload: [
                    "source": "public-api",
                    "list_note": note,
                    "detail_note": fullNote
                ]
            )

            let dir = directory.appendingPathComponent(dateFolder)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let existingMarkdown,
               Self.hasRealTranscriptSection(existingMarkdown),
               existingMarkdown.contains("## Summary"),
               !Self.hasGranolaEnrichment(existingMarkdown) {
                let merged = Self.mergeGranolaEnrichment(from: markdown, into: existingMarkdown)
                try? merged.write(to: filePath, atomically: true, encoding: .utf8)
                enriched += 1
            } else {
                try? markdown.write(to: filePath, atomically: true, encoding: .utf8)
                if fileExists {
                    enriched += 1
                } else {
                    imported += 1
                }
            }
            if !mergedTranscript.isEmpty {
                transcriptCount += 1
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        state = .done(imported: imported, transcripts: transcriptCount, enriched: enriched)
        return (imported, transcriptCount, enriched)
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
        var attendees: [String] = []

        func append(_ name: String?) {
            guard let name = sanitizedPersonName(name),
                  attendees.contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) == false else {
                return
            }
            attendees.append(name)
        }

        func appendPerson(from value: Any?) {
            if let string = value as? String {
                append(string)
                return
            }

            guard let dict = value as? [String: Any] else {
                return
            }

            if let details = dict["details"] as? [String: Any] {
                appendPerson(from: details["person"] ?? details["user"] ?? details)
            }
            if let person = dict["person"] as? [String: Any] {
                appendPerson(from: person)
            }
            if let user = dict["user"] as? [String: Any] {
                appendPerson(from: user)
            }
            if let nestedName = dict["name"] as? [String: Any] {
                append(firstNonEmptyString(in: nestedName, keys: ["fullName", "full_name", "displayName", "display_name", "value"]))
            }
            append(firstNonEmptyString(
                in: dict,
                keys: ["name", "fullName", "full_name", "displayName", "display_name", "email", "emailAddress", "email_address"]
            ))
        }

        guard let people = people else { return [] }

        if let dict = people as? [String: Any] {
            for key in ["attendees", "participants", "people", "invitees", "users"] {
                if let list = dict[key] as? [Any] {
                    list.forEach(appendPerson)
                }
            }
            appendPerson(from: dict)
            return attendees
        }

        if let list = people as? [Any] {
            list.forEach(appendPerson)
            return attendees
        }

        return attendees
    }

    private struct GranolaAttendeeMetadata: Hashable {
        var name: String
        var email: String
        var domain: String?
    }

    private static func extractAttendeeMetadata(from values: [Any?]) -> [GranolaAttendeeMetadata] {
        var attendees: [GranolaAttendeeMetadata] = []

        func append(name: String?, email: String?) {
            let cleanedEmail = sanitizedEmail(email)
            let cleanedName = sanitizedPersonName(name) ?? cleanedEmail
            guard let display = cleanedName, !display.isEmpty else { return }
            let domain = cleanedEmail.flatMap(emailDomain)
            let identity = (cleanedEmail ?? display).lowercased()
            guard attendees.contains(where: { existing in
                let existingIdentity = (existing.email.isEmpty ? existing.name : existing.email).lowercased()
                return existingIdentity == identity
            }) == false else {
                return
            }
            attendees.append(GranolaAttendeeMetadata(name: display, email: cleanedEmail ?? "", domain: domain))
        }

        func visit(_ value: Any?) {
            if let string = value as? String {
                if sanitizedEmail(string) != nil {
                    append(name: nil, email: string)
                } else {
                    append(name: string, email: nil)
                }
                return
            }
            if let list = value as? [Any] {
                list.forEach(visit)
                return
            }
            guard let dict = value as? [String: Any] else { return }

            let nestedName = (dict["name"] as? [String: Any]).flatMap {
                firstNonEmptyString(in: $0, keys: ["fullName", "full_name", "displayName", "display_name", "value"])
            }
            let name = nestedName ?? firstNonEmptyString(
                in: dict,
                keys: ["name", "fullName", "full_name", "displayName", "display_name"]
            )
            let email = firstNonEmptyString(
                in: dict,
                keys: ["email", "emailAddress", "email_address", "mail", "primaryEmail", "primary_email"]
            )
            if name != nil || email != nil {
                append(name: name, email: email)
            }

            for key in ["attendees", "participants", "people", "invitees", "users", "members"] {
                visit(dict[key])
            }
            for key in ["details", "person", "user", "profile", "author", "speaker"] {
                visit(dict[key])
            }
            for key in ["document", "list_note", "detail_note", "metadata"] {
                visit(dict[key])
            }
        }

        values.forEach(visit)
        return attendees
    }

    private static func sanitizedEmail(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>,; "))
            .lowercased()
        guard trimmed.range(of: #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        return trimmed
    }

    private static func emailDomain(_ email: String) -> String? {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let domain = parts[1].lowercased()
        return domain.isEmpty ? nil : domain
    }

    private static func sanitizedPersonName(_ name: String?) -> String? {
        guard let name else {
            return nil
        }

        let trimmed = name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        return joined.isEmpty ? nil : joined
    }

    private static func hasGranolaEnrichment(_ markdown: String) -> Bool {
        markdown.contains("## Granola Import Data")
            || markdown.contains("granola_created_at:")
            || markdown.contains("attendee_emails:")
            || markdown.contains("attendee_domains:")
            || markdown.contains("granola_attendees:")
    }

    private static func hasRealTranscriptSection(_ markdown: String) -> Bool {
        guard let body = extractSectionBody(from: markdown, header: "Transcript") else {
            return false
        }
        let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleaned.isEmpty && cleaned != "*No transcript yet.*"
    }

    private static func mergeGranolaEnrichment(from enrichedMarkdown: String, into existingMarkdown: String) -> String {
        let selectedKeys = [
            "granola_created_at",
            "granola_id",
            "attendee_emails",
            "attendee_domains",
            "granola_attendees",
            "source_type",
            "imported_from"
        ]
        let enrichedParts = splitFrontmatter(enrichedMarkdown)
        let existingParts = splitFrontmatter(existingMarkdown)
        let selectedFrontmatter = selectedFrontmatterLines(from: enrichedParts.frontmatter, keys: selectedKeys)

        let mergedFrontmatter: String?
        if let existingFrontmatter = existingParts.frontmatter {
            let cleaned = removingFrontmatterLines(from: existingFrontmatter, keys: selectedKeys)
            mergedFrontmatter = (cleaned + selectedFrontmatter).joined(separator: "\n")
        } else if !selectedFrontmatter.isEmpty {
            mergedFrontmatter = selectedFrontmatter.joined(separator: "\n")
        } else {
            mergedFrontmatter = nil
        }

        var body = removingGranolaImportDataSection(from: existingParts.body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawSection = granolaImportDataSection(from: enrichedMarkdown) {
            if !body.isEmpty {
                body += "\n\n"
            }
            body += rawSection.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let mergedFrontmatter, !mergedFrontmatter.isEmpty {
            return "---\n\(mergedFrontmatter)\n---\n\n\(body)\n"
        }
        return body + "\n"
    }

    private static func splitFrontmatter(_ markdown: String) -> (frontmatter: String?, body: String) {
        guard markdown.hasPrefix("---\n"),
              let closingRange = markdown.range(of: "\n---\n", range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex) else {
            return (nil, markdown)
        }
        let frontmatter = String(markdown[markdown.index(markdown.startIndex, offsetBy: 4)..<closingRange.lowerBound])
        let body = String(markdown[closingRange.upperBound...])
        return (frontmatter, body)
    }

    private static func selectedFrontmatterLines(from frontmatter: String?, keys: [String]) -> [String] {
        guard let frontmatter else { return [] }
        return frontmatterLines(from: frontmatter, matching: Set(keys), includeMatches: true)
    }

    private static func removingFrontmatterLines(from frontmatter: String, keys: [String]) -> [String] {
        frontmatterLines(from: frontmatter, matching: Set(keys), includeMatches: false)
    }

    private static func frontmatterLines(from frontmatter: String, matching keys: Set<String>, includeMatches: Bool) -> [String] {
        let lines = frontmatter.components(separatedBy: "\n")
        var output: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let key = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            let isMatch = keys.contains(key)
            if isMatch {
                if includeMatches {
                    output.append(line)
                }
                index += 1
                while index < lines.count, lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") {
                    if includeMatches {
                        output.append(lines[index])
                    }
                    index += 1
                }
            } else {
                if !includeMatches {
                    output.append(line)
                }
                index += 1
            }
        }
        return output.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func granolaImportDataSection(from markdown: String) -> String? {
        guard let range = markdown.range(of: "## Granola Import Data") else { return nil }
        return String(markdown[range.lowerBound...])
    }

    private static func removingGranolaImportDataSection(from markdown: String) -> String {
        guard let range = markdown.range(of: "## Granola Import Data") else { return markdown }
        return String(markdown[..<range.lowerBound])
    }

    nonisolated static func extractTranscript(from transcriptData: Any?) -> String {
        guard let data = transcriptData else { return "" }

        if let list = data as? [Any] {
            return list.compactMap { entry -> String? in
                if let text = entry as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                guard let dict = entry as? [String: Any] else {
                    return nil
                }
                return formattedTranscriptEntry(from: dict)
            }.joined(separator: "\n\n")
        }

        if let str = data as? String { return str }

        return ""
    }

    nonisolated private static func formattedTranscriptEntry(from entry: [String: Any]) -> String? {
        guard let text = transcriptText(from: entry) else {
            return nil
        }

        let speaker = transcriptSpeaker(from: entry)
        let timestamp = transcriptStartTime(from: entry).map(formatTranscriptTimestamp)
        switch (timestamp, speaker) {
        case (.some(let timestamp), .some(let speaker)):
            return "**[\(timestamp)] \(speaker):** \(text)"
        case (.some(let timestamp), .none):
            return "[\(timestamp)] \(text)"
        case (.none, .some(let speaker)):
            return "**\(speaker):** \(text)"
        case (.none, .none):
            return text
        }
    }

    nonisolated private static func transcriptText(from entry: [String: Any]) -> String? {
        if let text = firstNonEmptyString(
            in: entry,
            keys: ["text", "content", "transcript", "utterance", "sentence"]
        ) {
            return text
        }

        if let words = entry["words"] as? [Any] {
            let text = words.compactMap { word -> String? in
                if let word = word as? String {
                    return word
                }
                guard let dict = word as? [String: Any] else {
                    return nil
                }
                return firstNonEmptyString(in: dict, keys: ["word", "text", "content"])
            }.joined(separator: " ")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false {
                return trimmed
            }
        }

        if let segments = entry["segments"] as? [Any] {
            let text = segments.compactMap { segment -> String? in
                if let string = segment as? String {
                    return string
                }
                guard let dict = segment as? [String: Any] else {
                    return nil
                }
                return transcriptText(from: dict)
            }.joined(separator: " ")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false {
                return trimmed
            }
        }

        return nil
    }

    nonisolated private static func transcriptSpeaker(from entry: [String: Any]) -> String? {
        if let speaker = firstNonEmptyString(
            in: entry,
            keys: [
                "speaker",
                "speaker_name",
                "speakerName",
                "speaker_label",
                "speakerLabel",
                "name",
                "display_name",
                "displayName",
                "author"
            ]
        ) {
            return sanitizedSpeakerName(speaker)
        }

        for key in ["speaker", "participant", "person", "user", "author"] {
            if let dict = entry[key] as? [String: Any],
               let name = personName(from: dict) {
                return sanitizedSpeakerName(name)
            }
        }

        if let speakerID = firstNonEmptyString(
            in: entry,
            keys: ["speaker_id", "speakerId", "participant_id", "participantId"]
        ) {
            return sanitizedSpeakerName(fallbackSpeakerName(from: speakerID))
        }

        return nil
    }

    nonisolated private static func personName(from dict: [String: Any]) -> String? {
        if let name = firstNonEmptyString(
            in: dict,
            keys: ["name", "fullName", "full_name", "displayName", "display_name", "email"]
        ) {
            return name
        }
        if let nestedName = dict["name"] as? [String: Any] {
            return firstNonEmptyString(in: nestedName, keys: ["fullName", "displayName", "value"])
        }
        return nil
    }

    nonisolated private static func transcriptStartTime(from entry: [String: Any]) -> TimeInterval? {
        let keys = [
            "start",
            "start_time",
            "startTime",
            "start_seconds",
            "startSeconds",
            "timestamp",
            "time",
            "offset",
            "offset_seconds",
            "offsetSeconds"
        ]
        for key in keys {
            guard let seconds = numericTimeInterval(entry[key]) else {
                continue
            }
            return seconds
        }

        for key in ["start_ms", "startMs", "timestamp_ms", "timestampMs", "offset_ms", "offsetMs"] {
            guard let milliseconds = numericTimeInterval(entry[key]) else {
                continue
            }
            return milliseconds / 1000
        }

        return nil
    }

    nonisolated private static func numericTimeInterval(_ value: Any?) -> TimeInterval? {
        switch value {
        case let value as Double:
            return normalizedTranscriptOffset(value)
        case let value as Float:
            return normalizedTranscriptOffset(Double(value))
        case let value as Int:
            return normalizedTranscriptOffset(Double(value))
        case let value as NSNumber:
            return normalizedTranscriptOffset(value.doubleValue)
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let numericValue = Double(trimmed) {
                return normalizedTranscriptOffset(numericValue)
            }
            return parseTimestampString(trimmed)
        default:
            return nil
        }
    }

    nonisolated private static func normalizedTranscriptOffset(_ value: Double) -> TimeInterval? {
        guard value.isFinite, value >= 0 else {
            return nil
        }
        // Granola-like transcript offsets are usually seconds, but some APIs
        // return milliseconds. Treat very large offsets as millisecond values.
        if value > 24 * 60 * 60 {
            return value / 1000
        }
        return value
    }

    nonisolated private static func parseTimestampString(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":")
        if parts.count == 3,
           let hours = Double(parts[0]),
           let minutes = Double(parts[1]),
           let seconds = Double(parts[2]) {
            return hours * 3600 + minutes * 60 + seconds
        }
        if parts.count == 2,
           let minutes = Double(parts[0]),
           let seconds = Double(parts[1]) {
            return minutes * 60 + seconds
        }
        return nil
    }

    nonisolated private static func formatTranscriptTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    nonisolated private static func firstNonEmptyString(
        in dict: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = dict[key] else {
                continue
            }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false {
                    return trimmed
                }
            } else if let number = value as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    nonisolated private static func sanitizedSpeakerName(_ name: String) -> String? {
        let singleLine = name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "**", with: "")
        let trimmed = singleLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func fallbackSpeakerName(from speakerID: String) -> String {
        let cleaned = speakerID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        if cleaned.lowercased().hasPrefix("speaker ") {
            return cleaned
        }
        return "Speaker \(cleaned)"
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
        chaptersMarkdown: String? = nil,
        rawGranolaPayload: Any? = nil
    ) -> String {
        let attendeeMetadata = extractAttendeeMetadata(from: [people, rawGranolaPayload])
        let metadataNames = attendeeMetadata.map(\.name)
        let fallbackNames = extractAttendees(from: people)
        let attendees = uniqueStrings(metadataNames + fallbackNames)
        let attendeeEmails = uniqueStrings(attendeeMetadata.map(\.email).filter { !$0.isEmpty })
        let attendeeDomains = uniqueStrings(attendeeMetadata.compactMap(\.domain))

        var lines: [String] = []

        // Frontmatter
        lines.append("---")
        lines.append("title: \"\(title.replacingOccurrences(of: "\"", with: "\\\""))\"")
        if !createdAt.isEmpty { lines.append("date: \"\(createdAt)\"") }
        if !createdAt.isEmpty { lines.append("granola_created_at: \"\(escapedYAMLString(createdAt))\"") }
        lines.append("granola_id: \"\(docId)\"")
        if !attendees.isEmpty {
            lines.append("attendees: [\(attendees.map { "\"\(escapedYAMLString($0))\"" }.joined(separator: ", "))]")
        }
        if !attendeeEmails.isEmpty {
            lines.append("attendee_emails: [\(attendeeEmails.map { "\"\(escapedYAMLString($0))\"" }.joined(separator: ", "))]")
        }
        if !attendeeDomains.isEmpty {
            lines.append("attendee_domains: [\(attendeeDomains.map { "\"\(escapedYAMLString($0))\"" }.joined(separator: ", "))]")
        }
        if !attendeeMetadata.isEmpty {
            lines.append("granola_attendees:")
            for attendee in attendeeMetadata {
                lines.append("  - name: \"\(escapedYAMLString(attendee.name))\"")
                if !attendee.email.isEmpty {
                    lines.append("    email: \"\(escapedYAMLString(attendee.email))\"")
                }
                if let domain = attendee.domain {
                    lines.append("    domain: \"\(escapedYAMLString(domain))\"")
                }
            }
        }
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

        if let rawJSON = prettyJSONString(rawGranolaPayload) {
            lines.append("## Granola Import Data")
            lines.append("")
            lines.append("```json")
            lines.append(rawJSON)
            lines.append("```")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(cleaned)
        }
        return out
    }

    private static func prettyJSONString(_ value: Any?) -> String? {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func escapedYAMLString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
