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
        var inFrontmatter = false
        var frontmatterSeen = false
        var inNotes = false
        var inTranscript = false
        var inSummary = false
        var inChapters = false
        var inArticle = false
        var transcriptLines: [String] = []

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
                if line.hasPrefix("imported_from:") {
                    importedFrom = line.replacingOccurrences(of: "imported_from:", with: "").trimmingCharacters(in: .whitespaces)
                }
                if line.hasPrefix("source:") {
                    sourceURL = line.replacingOccurrences(of: "source:", with: "").trimmingCharacters(in: .whitespaces)
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

        let transcript = MeetingTranscript(meetingName: title)
        transcript.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.summary = trimmedSummary.isEmpty ? nil : trimmedSummary
        let trimmedArticle = article.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.articleBody = trimmedArticle.isEmpty ? nil : trimmedArticle
        transcript.importedFrom = importedFrom
        transcript.sourceURL = sourceURL

        transcript.segments = parseTranscriptSegments(from: transcriptLines)

        return transcript
    }

    private struct ParsedSpeakerLine {
        let speaker: SpeakerLabel
        let startTime: TimeInterval?
        let text: String
    }

    /// Parse Ghost Pepper, Granola, and pasted transcript speaker turns.
    /// Supports timestamped lines, bold speaker labels, plain `Speaker: text`
    /// lines, and wrapped continuation lines after a speaker turn.
    private static func parseTranscriptSegments(from lines: [String]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var sawSpeakerLine = false

        for line in lines {
            let trimmed = trimMarkdownLineBreak(from: line.trimmingCharacters(in: .whitespaces))
            guard !trimmed.isEmpty else { continue }

            if let parsed = parseSpeakerLine(trimmed) {
                sawSpeakerLine = true
                let startTime = parsed.startTime ?? Double(segments.count) * 5
                segments.append(
                    TranscriptSegment(
                        id: UUID(),
                        speaker: parsed.speaker,
                        startTime: startTime,
                        endTime: startTime + (parsed.startTime == nil ? 5 : 30),
                        text: parsed.text
                    )
                )
                continue
            }

            if sawSpeakerLine, !segments.isEmpty {
                let separator = segments[segments.count - 1].text.isEmpty ? "" : "\n"
                segments[segments.count - 1].text += separator + trimmed
            } else {
                let startTime = Double(segments.count) * 5
                segments.append(
                    TranscriptSegment(
                        id: UUID(),
                        speaker: .remote(name: nil),
                        startTime: startTime,
                        endTime: startTime + 5,
                        text: trimmed
                    )
                )
            }
        }

        return segments
    }

    private static func parseSpeakerLine(_ line: String) -> ParsedSpeakerLine? {
        let withoutListMarker = stripListMarker(from: line)
        if let (startTime, remainder) = parseTimestampPrefix(from: withoutListMarker),
           let speakerText = parseSpeakerAndText(from: remainder, allowsPlainColon: true) {
            return ParsedSpeakerLine(
                speaker: speakerLabel(from: speakerText.speakerName),
                startTime: startTime,
                text: speakerText.text
            )
        }

        if let speakerText = parseSpeakerAndText(
            from: withoutListMarker,
            allowsPlainColon: false
        ) {
            return ParsedSpeakerLine(
                speaker: speakerLabel(from: speakerText.speakerName),
                startTime: nil,
                text: speakerText.text
            )
        }

        if let speakerText = parseSpeakerAndText(
            from: withoutListMarker,
            allowsPlainColon: true
        ) {
            return ParsedSpeakerLine(
                speaker: speakerLabel(from: speakerText.speakerName),
                startTime: nil,
                text: speakerText.text
            )
        }

        return nil
    }

    private static func parseTimestampPrefix(from line: String) -> (TimeInterval, String)? {
        let timestampStartOffset: String.Index
        if line.hasPrefix("**[") {
            timestampStartOffset = line.index(line.startIndex, offsetBy: 3)
        } else if line.hasPrefix("[") {
            timestampStartOffset = line.index(after: line.startIndex)
        } else {
            return nil
        }

        guard let closeBracket = line[timestampStartOffset...].firstIndex(of: "]") else {
            return nil
        }
        let timestamp = String(line[timestampStartOffset..<closeBracket])
        guard let seconds = parseTimestamp(timestamp) else {
            return nil
        }
        let remainder = String(line[closeBracket...].dropFirst())
            .trimmingCharacters(in: .whitespaces)
        return (seconds, remainder)
    }

    private static func parseTimestamp(_ timestamp: String) -> TimeInterval? {
        let parts = timestamp.split(separator: ":")
        if parts.count == 3 {
            guard let hours = Double(parts[0]),
                  let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else {
                return nil
            }
            return hours * 3600 + minutes * 60 + seconds
        }
        if parts.count == 2 {
            guard let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else {
                return nil
            }
            return minutes * 60 + seconds
        }
        return nil
    }

    private static func parseSpeakerAndText(
        from line: String,
        allowsPlainColon: Bool
    ) -> (speakerName: String, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("**") {
            let withoutOpeningBold = String(trimmed.dropFirst(2))
            guard let marker = withoutOpeningBold.range(of: ":**") else {
                return nil
            }
            let speakerName = String(withoutOpeningBold[..<marker.lowerBound])
            let text = String(withoutOpeningBold[marker.upperBound...])
            return normalizedSpeakerAndText(speakerName: speakerName, text: text)
        }

        if let marker = trimmed.range(of: ":**") {
            let speakerName = String(trimmed[..<marker.lowerBound])
            let text = String(trimmed[marker.upperBound...])
            return normalizedSpeakerAndText(speakerName: speakerName, text: text)
        }

        guard allowsPlainColon,
              let marker = trimmed.firstIndex(of: ":") else {
            return nil
        }
        let speakerName = String(trimmed[..<marker])
        let text = String(trimmed[trimmed.index(after: marker)...])
        guard isPlausibleSpeakerName(speakerName) else {
            return nil
        }
        return normalizedSpeakerAndText(speakerName: speakerName, text: text)
    }

    private static func normalizedSpeakerAndText(
        speakerName: String,
        text: String
    ) -> (speakerName: String, text: String)? {
        let cleanedSpeaker = speakerName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        let cleanedText = trimMarkdownLineBreak(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleanedSpeaker.isEmpty, !cleanedText.isEmpty else {
            return nil
        }
        return (cleanedSpeaker, cleanedText)
    }

    private static func speakerLabel(from name: String) -> SpeakerLabel {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = cleaned.lowercased()
        if lowercased == "me" || lowercased == "you" {
            return .me
        }
        if lowercased == "others" || lowercased == "other" {
            return .remote(name: nil)
        }
        return .remote(name: cleaned)
    }

    private static func stripListMarker(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private static func trimMarkdownLineBreak(from text: String) -> String {
        text.replacingOccurrences(
            of: #"\s{2,}$"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func isPlausibleSpeakerName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else {
            return false
        }
        if trimmed.contains(where: { character in
            character.isNewline || "{}[]()<>/\\|".contains(character)
        }) {
            return false
        }
        let words = trimmed.split(separator: " ")
        guard words.count <= 6 else {
            return false
        }
        return words.contains { word in
            word.contains { $0.isLetter || $0.isNumber }
        }
    }

    // MARK: - Helpers

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
