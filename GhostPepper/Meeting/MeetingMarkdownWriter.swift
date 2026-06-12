import Foundation

/// Writes a MeetingTranscript to a markdown file in a date-organized directory.
struct MeetingMarkdownWriter {

    /// Writes the transcript to a markdown file, creating date subdirectories as needed.
    /// If `existingFileURL` is provided, overwrites that file instead of creating a new one.
    /// Returns the URL of the written file.
    @MainActor
    static func write(transcript: MeetingTranscript, to baseDirectory: URL, existingFileURL: URL? = nil) throws -> URL {
        let fileURL: URL
        if let existing = existingFileURL {
            fileURL = existing
        } else {
            let dateFolder = dateFolderName(for: transcript.startDate)
            let directory = baseDirectory.appendingPathComponent(dateFolder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let fileName = slugify(transcript.meetingName) + ".md"
            fileURL = deduplicatedFileURL(directory: directory, fileName: fileName)
        }

        let markdown = renderMarkdown(transcript: transcript)
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)

        return fileURL
    }

    // MARK: - Rendering

    @MainActor
    static func renderMarkdown(transcript: MeetingTranscript) -> String {
        if let articleBody = transcript.articleBody {
            return renderReaderMarkdown(transcript: transcript, articleBody: articleBody)
        }
        if transcript.importedFrom?.lowercased() == "granola" {
            return renderImportedGranolaMarkdown(transcript: transcript)
        }
        return renderMeetingMarkdown(transcript: transcript)
    }

    @MainActor
    private static func renderMeetingMarkdown(transcript: MeetingTranscript) -> String {
        var lines: [String] = []

        // Title
        lines.append("# \(transcript.meetingName)")
        lines.append("")

        // Metadata
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let startStr = dateFormatter.string(from: transcript.startDate)
        if let endDate = transcript.endDate {
            let endTimeFormatter = DateFormatter()
            endTimeFormatter.timeStyle = .short
            let endStr = endTimeFormatter.string(from: endDate)
            lines.append("**Date:** \(startStr) — \(endStr)")
        } else {
            lines.append("**Date:** \(startStr) (in progress)")
        }
        if !transcript.attendees.isEmpty {
            let formatted = transcript.attendees.map { $0.declined ? "\($0.name) (declined)" : $0.name }
            lines.append("**Attendees:** \(formatted.joined(separator: ", "))")
        }
        lines.append("")

        // Notes
        lines.append("## Notes")
        lines.append("")
        if transcript.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("*No notes.*")
        } else {
            lines.append(transcript.notes)
        }
        lines.append("")

        // Summary (if present — e.g., from Granola import or AI generation)
        if let summary = transcript.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("## Summary")
            lines.append("")
            lines.append(summary)
            lines.append("")
        }

        // Transcript
        lines.append("## Transcript")
        lines.append("")

        if transcript.segments.isEmpty {
            lines.append("*No transcript yet.*")
        } else {
            for segment in transcript.segments {
                let timestamp = segment.formattedTimestamp
                let speaker = segment.speaker.displayName
                lines.append("**[\(timestamp)] \(speaker):** \(segment.text)  ")
            }
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    @MainActor
    private static func renderImportedGranolaMarkdown(transcript: MeetingTranscript) -> String {
        var lines: [String] = []

        lines.append("---")
        lines.append("title: \"\(escapeYAMLString(transcript.meetingName))\"")
        if let importedDateString = transcript.importedDateString, !importedDateString.isEmpty {
            lines.append("date: \"\(escapeYAMLString(importedDateString))\"")
        } else {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            lines.append("date: \"\(iso.string(from: transcript.startDate))\"")
        }
        if let granolaId = transcript.granolaId, !granolaId.isEmpty {
            lines.append("granola_id: \"\(escapeYAMLString(granolaId))\"")
        }
        lines.append("source_type: meeting")
        lines.append("imported_from: granola")
        lines.append("---")
        lines.append("")

        lines.append("# \(transcript.meetingName)")
        lines.append("")

        if let summary = transcript.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("## Summary")
            lines.append("")
            lines.append(summary)
            lines.append("")
        }

        if !transcript.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("## Notes")
            lines.append("")
            lines.append(transcript.notes)
            lines.append("")
        }

        let rawTranscript = transcript.rawTranscriptMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawTranscript.isEmpty || !transcript.segments.isEmpty {
            lines.append("## Transcript")
            lines.append("")
            if !rawTranscript.isEmpty {
                lines.append(rawTranscript)
            } else {
                appendRenderedTranscriptSegments(transcript.segments, to: &lines)
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    @MainActor
    private static func renderReaderMarkdown(transcript: MeetingTranscript, articleBody: String) -> String {
        var lines: [String] = []

        lines.append("---")
        lines.append("type: reader")
        if let source = transcript.sourceURL, !source.isEmpty {
            lines.append("source: \(source)")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        lines.append("fetched: \(iso.string(from: transcript.startDate))")
        lines.append("---")
        lines.append("")
        lines.append("# \(transcript.meetingName)")
        lines.append("")

        if let source = transcript.sourceURL, let url = URL(string: source), let host = url.host {
            let dateFmt = DateFormatter()
            dateFmt.dateStyle = .medium
            dateFmt.timeStyle = .short
            lines.append("*From [\(host)](\(source)) · saved \(dateFmt.string(from: transcript.startDate))*")
            lines.append("")
        }

        lines.append("## Article")
        lines.append("")
        lines.append(articleBody)
        lines.append("")

        lines.append("## Notes")
        lines.append("")
        if transcript.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("*No notes yet.*")
        } else {
            lines.append(transcript.notes)
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - Parse markdown back into a transcript

    /// Parse a meeting markdown file back into a MeetingTranscript for viewing/editing.
    @MainActor
    static func parse(from fileURL: URL) throws -> MeetingTranscript {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        // Extract title from first "# " line
        var title = fileURL.deletingPathExtension().lastPathComponent
        var notes = ""
        var summary = ""
        var article = ""
        var importedFrom: String?
        var sourceURL: String?
        var granolaId: String?
        var importedDateString: String?
        var inFrontmatter = false
        var frontmatterSeen = false
        var inNotes = false
        var inTranscript = false
        var inSummary = false
        var inChapters = false
        var inArticle = false
        var transcriptLines: [String] = []
        var transcriptSectionLines: [String] = []

        for line in lines {
            // Parse YAML frontmatter (--- blocks)
            if line == "---" {
                if !frontmatterSeen {
                    inFrontmatter = true
                    frontmatterSeen = true
                    continue
                } else if inFrontmatter {
                    inFrontmatter = false
                    continue
                }
            }
            if inFrontmatter {
                if let value = frontmatterValue(from: line, key: "title"), title == fileURL.deletingPathExtension().lastPathComponent {
                    title = value
                } else if let value = frontmatterValue(from: line, key: "date") {
                    importedDateString = value
                } else if let value = frontmatterValue(from: line, key: "granola_id") {
                    granolaId = value
                } else if let value = frontmatterValue(from: line, key: "imported_from") {
                    importedFrom = value
                } else if let value = frontmatterValue(from: line, key: "source") {
                    sourceURL = value
                }
                continue
            }

            if line.hasPrefix("# ") && title == fileURL.deletingPathExtension().lastPathComponent {
                title = String(line.dropFirst(2))
                continue
            }

            if line == "## Notes" {
                inNotes = true; inTranscript = false; inSummary = false; inChapters = false; inArticle = false
                continue
            }
            if line == "## Transcript" {
                inNotes = false; inTranscript = true; inSummary = false; inChapters = false; inArticle = false
                continue
            }
            if line == "## Summary" {
                inNotes = false; inTranscript = false; inSummary = true; inChapters = false; inArticle = false
                continue
            }
            if line == "## Chapters" {
                inNotes = false; inTranscript = false; inSummary = false; inChapters = true; inArticle = false
                continue
            }
            if line == "## Article" {
                inNotes = false; inTranscript = false; inSummary = false; inChapters = false; inArticle = true
                continue
            }
            if line.hasPrefix("## ") {
                inNotes = false; inTranscript = false; inSummary = false; inChapters = false; inArticle = false
                continue
            }

            if inNotes {
                if line == "*No notes.*" { continue }
                if line == "*No notes yet.*" { continue }
                notes += (notes.isEmpty ? "" : "\n") + line
            }
            if inTranscript {
                transcriptSectionLines.append(line)
                if line == "*No transcript yet.*" { continue }
                if !line.isEmpty {
                    transcriptLines.append(line)
                }
            }
            if inSummary || inChapters {
                summary += (summary.isEmpty ? "" : "\n") + line
            }
            if inArticle {
                article += (article.isEmpty ? "" : "\n") + line
            }
        }

        let startDate = importedDateString.flatMap(parseImportedDate) ?? Date()
        let transcript = MeetingTranscript(meetingName: title, startDate: startDate)
        transcript.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.summary = trimmedSummary.isEmpty ? nil : trimmedSummary
        let trimmedArticle = article.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.articleBody = trimmedArticle.isEmpty ? nil : trimmedArticle
        transcript.importedFrom = importedFrom
        transcript.sourceURL = sourceURL
        transcript.granolaId = granolaId
        transcript.importedDateString = importedDateString
        let rawTranscript = transcriptSectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawTranscript.isEmpty && rawTranscript != "*No transcript yet.*" {
            transcript.rawTranscriptMarkdown = rawTranscript
        }

        // Parse transcript lines: **[00:00] Me:** text
        for line in transcriptLines {
            guard line.hasPrefix("**[") else { continue }
            // Extract timestamp
            guard let closeBracket = line.range(of: "]") else { continue }
            let timestamp = String(line[line.index(line.startIndex, offsetBy: 3)..<closeBracket.lowerBound])
            let parts = timestamp.split(separator: ":")
            let seconds: TimeInterval
            if parts.count == 3 {
                let h = Double(parts[0]) ?? 0
                let m = Double(parts[1]) ?? 0
                let s = Double(parts[2]) ?? 0
                seconds = h * 3600 + m * 60 + s
            } else if parts.count == 2 {
                let m = Double(parts[0]) ?? 0
                let s = Double(parts[1]) ?? 0
                seconds = m * 60 + s
            } else {
                seconds = 0
            }

            // Extract speaker and text: "Me:** text  " or "Others:** text  "
            let afterBracket = String(line[closeBracket.upperBound...])
            let speakerText = afterBracket.trimmingCharacters(in: .whitespaces)
            guard speakerText.hasPrefix(" ") || speakerText.hasPrefix("") else { continue }
            let cleaned = speakerText.hasPrefix(" ") ? String(speakerText.dropFirst()) : speakerText

            let speaker: SpeakerLabel
            let text: String
            if cleaned.hasPrefix("Me:**") {
                speaker = .me
                text = String(cleaned.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if cleaned.hasPrefix("Others:**") {
                speaker = .remote(name: nil)
                text = String(cleaned.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else if let colonStar = cleaned.range(of: ":**") {
                let name = String(cleaned[..<colonStar.lowerBound])
                speaker = .remote(name: name)
                text = String(cleaned[colonStar.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                continue
            }

            let segment = TranscriptSegment(
                id: UUID(),
                speaker: speaker,
                startTime: seconds,
                endTime: seconds + 30,
                text: text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "  $", with: "", options: .regularExpression)
            )
            transcript.segments.append(segment)
        }

        // Fallback: parse Granola-format transcripts (plain text or **Speaker:** text, no timestamps)
        if transcript.segments.isEmpty && !transcriptLines.isEmpty {
            for (i, line) in transcriptLines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }

                let speaker: SpeakerLabel
                let text: String
                if trimmed.hasPrefix("**"), let colonStar = trimmed.range(of: ":**") {
                    let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<colonStar.lowerBound])
                    speaker = .remote(name: name)
                    text = String(trimmed[colonStar.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    speaker = .remote(name: nil)
                    text = trimmed
                }

                let segment = TranscriptSegment(
                    id: UUID(),
                    speaker: speaker,
                    startTime: Double(i) * 5,
                    endTime: Double(i) * 5 + 5,
                    text: text
                )
                transcript.segments.append(segment)
            }
        }

        return transcript
    }

    // MARK: - Helpers

    private static func appendRenderedTranscriptSegments(_ segments: [TranscriptSegment], to lines: inout [String]) {
        for segment in segments {
            let timestamp = segment.formattedTimestamp
            let speaker = segment.speaker.displayName
            lines.append("**[\(timestamp)] \(speaker):** \(segment.text)  ")
        }
    }

    private static func frontmatterValue(from line: String, key: String) -> String? {
        let prefix = "\(key):"
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func escapeYAMLString(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func parseImportedDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value)
    }

    /// Formats a date as "2026-04-07" for folder names.
    private static func dateFolderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Converts a meeting name to a file-safe slug.
    /// "Design Review @ 10am" → "design-review-at-10am"
    static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let replaced = lowered.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()

        // Collapse multiple dashes, trim edges.
        let collapsed = replaced.replacingOccurrences(
            of: "-{2,}",
            with: "-",
            options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return trimmed.isEmpty ? "meeting" : trimmed
    }

    /// If "design-review.md" already exists, returns "design-review-2.md", etc.
    private static func deduplicatedFileURL(directory: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        var candidate = directory.appendingPathComponent(fileName)
        var counter = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = "\(base)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        }

        return candidate
    }
}
