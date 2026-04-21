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
            lines.append("**Attendees:** \(transcript.attendees.joined(separator: ", "))")
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
        var importedFrom: String?
        var inFrontmatter = false
        var frontmatterSeen = false
        var inNotes = false
        var inTranscript = false
        var inSummary = false
        var inChapters = false
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
                continue
            }

            if line.hasPrefix("# ") && title == fileURL.deletingPathExtension().lastPathComponent {
                title = String(line.dropFirst(2))
                continue
            }

            if line == "## Notes" {
                inNotes = true; inTranscript = false; inSummary = false; inChapters = false
                continue
            }
            if line == "## Transcript" {
                inNotes = false; inTranscript = true; inSummary = false; inChapters = false
                continue
            }
            if line == "## Summary" {
                inNotes = false; inTranscript = false; inSummary = true; inChapters = false
                continue
            }
            if line == "## Chapters" {
                inNotes = false; inTranscript = false; inSummary = false; inChapters = true
                continue
            }
            if line.hasPrefix("## ") {
                inNotes = false; inTranscript = false; inSummary = false; inChapters = false
                continue
            }

            if inNotes {
                if line == "*No notes.*" { continue }
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
        }

        let transcript = MeetingTranscript(meetingName: title)
        transcript.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.summary = trimmedSummary.isEmpty ? nil : trimmedSummary
        transcript.importedFrom = importedFrom

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
