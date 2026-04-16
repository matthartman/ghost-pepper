import Foundation

/// Scans the meetings directory and rewrites `.md` files that (a) the user has flagged
/// for auto-delete via `auto_delete: true` in YAML frontmatter and (b) are in a folder
/// older than the user's retention window. The `## Transcript` section is stripped and
/// replaced with a placeholder + machine-readable marker; title, notes, summary, and
/// any sections that appear after the transcript are preserved.
///
/// Opt-in by design: unflagged meetings are never touched, regardless of age. The
/// retention window controls timing; the per-meeting flag controls scope.
///
/// This is not secure erasure. `String.write(atomically:)` does an atomic rename-replace,
/// so the original file's blocks linger in APFS free space until reused; Time Machine
/// snapshots may retain earlier versions; FileVault encrypts all of this at rest but
/// does not prevent recovery once the disk is unlocked. The UI copy reflects this.
enum TranscriptExpirySweeper {

    /// Result of a sweep run. All values are Sendable so the result can be returned
    /// across actor boundaries without isolation gymnastics.
    struct Result: Sendable {
        /// Number of files whose transcripts were stripped in this run.
        var expiredCount: Int = 0
        /// Non-fatal per-file errors (read/write failures). Empty on a clean run.
        var errors: [String] = []
    }

    /// Runs the sweep once.
    /// - Parameters:
    ///   - baseDirectory: The meetings root (e.g. `~/Documents/Ghost Pepper Meetings/`).
    ///   - daysToKeep: Retention window in days. `0` (or negative) disables the sweep.
    ///   - now: Current time, injectable for testing.
    /// - Returns: A `Result` with the expired count and any non-fatal error messages.
    static func run(
        baseDirectory: URL,
        daysToKeep: Int,
        now: Date = Date()
    ) -> Result {
        var result = Result()
        guard daysToKeep > 0 else { return result }

        let fm = FileManager.default

        // Missing base directory is normal first-launch state — silent no-op.
        // A scan failure on an existing path is an anomaly that must surface to the user.
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: baseDirectory.path, isDirectory: &isDir) else { return result }
        guard isDir.boolValue else {
            result.errors.append("Transcript expiry: base path is not a directory: \(baseDirectory.path)")
            return result
        }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: baseDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            result.errors.append("Transcript expiry: failed to scan \(baseDirectory.path): \(error.localizedDescription)")
            return result
        }

        for folder in entries {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let folderDate = parseDateFolder(folder.lastPathComponent) else { continue }
            guard daysBetween(folderDate, now) >= daysToKeep else { continue }

            sweepFolder(folder, now: now, into: &result)
        }
        return result
    }

    // MARK: - Per-folder sweep

    private static func sweepFolder(_ folder: URL, now: Date, into result: inout Result) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return
        }

        for file in files where file.pathExtension.lowercased() == "md" {
            expireTranscriptFile(at: file, now: now, into: &result)
        }
    }

    /// Rewrites a single markdown file if it has a `## Transcript` section that
    /// hasn't already been expired. Increments `result.expiredCount` on success,
    /// appends to `result.errors` on failure. Files that haven't been flagged for
    /// auto-delete (`auto_delete: true` in YAML frontmatter) are skipped silently.
    static func expireTranscriptFile(at url: URL, now: Date, into result: inout Result) {
        let original: String
        do {
            original = try String(contentsOf: url, encoding: .utf8)
        } catch {
            result.errors.append("Transcript expiry: failed to read \(url.lastPathComponent): \(error.localizedDescription)")
            return
        }
        guard hasAutoDeleteFlag(in: original) else { return }
        guard let rewritten = rewrite(markdown: original, expiredOn: now) else { return }
        guard rewritten != original else { return }
        do {
            try rewritten.write(to: url, atomically: true, encoding: .utf8)
            result.expiredCount += 1
        } catch {
            result.errors.append("Transcript expiry: failed to write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Returns true if the markdown has `auto_delete: true` in a leading YAML
    /// frontmatter block. Anything outside the first `---` fence is ignored.
    static func hasAutoDeleteFlag(in markdown: String) -> Bool {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var inFrontmatter = false
        var frontmatterSeen = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !frontmatterSeen {
                    inFrontmatter = true
                    frontmatterSeen = true
                    continue
                } else if inFrontmatter {
                    return false
                }
            }
            if inFrontmatter {
                if trimmed == "auto_delete: true" { return true }
                continue
            }
            // First non-frontmatter line before any fence — no flag.
            if !trimmed.isEmpty { return false }
        }
        return false
    }

    /// Returns the rewritten markdown, or nil if the file has no `## Transcript`
    /// section, has already been expired, or has no transcript content to strip.
    static func rewrite(markdown: String, expiredOn now: Date) -> String? {
        // Normalize CRLF and lone CR to LF so imported files (e.g. from tools that
        // emit Windows line endings) still match the "## Transcript" header.
        // Output is always LF-terminated, matching what MeetingMarkdownWriter writes.
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        guard let transcriptIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "## Transcript"
        }) else {
            return nil
        }

        // Find the end of the transcript section: the next `## ` heading, or EOF.
        // Everything after that boundary (e.g. `## Chapters` from Granola imports)
        // is preserved verbatim. Matching is whitespace-tolerant for the same reason
        // as the header lookup above.
        let tailStart = lines[(transcriptIndex + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("## ")
        })
        let bodyRange = (transcriptIndex + 1)..<(tailStart ?? lines.endIndex)
        let body = lines[bodyRange]
        let tail: ArraySlice<String> = tailStart.map { lines[$0...] } ?? []

        // Idempotency: already contains our marker.
        if body.contains(where: { MeetingMarkdownWriter.expiredMarkerDate(in: $0) != nil }) {
            return nil
        }

        // Nothing-to-delete guard: a meeting that was auto-detected but never
        // transcribed contains only "*No transcript yet.*" (or nothing). Don't
        // stamp it as "auto-deleted" — there was no transcript to delete.
        let hasRealContent = body.contains { line in
            !line.isEmpty && line != "*No transcript yet.*"
        }
        guard hasRealContent else { return nil }

        let ymd = folderDateFormatter.string(from: now)
        var rebuilt = Array(lines[..<transcriptIndex])
        rebuilt.append("## Transcript")
        rebuilt.append("")
        rebuilt.append("*Transcript was automatically deleted on \(ymd) per your privacy settings.*")
        rebuilt.append("")
        rebuilt.append("\(MeetingMarkdownWriter.expiredMarkerPrefix)\(ymd) -->")
        rebuilt.append("")
        rebuilt += tail

        return rebuilt.joined(separator: "\n")
    }

    // MARK: - Date helpers

    private static let folderDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parseDateFolder(_ name: String) -> Date? {
        folderDateFormatter.date(from: name)
    }

    static func daysBetween(_ from: Date, _ to: Date) -> Int {
        let calendar = Calendar.current
        let fromMidnight = calendar.startOfDay(for: from)
        let toMidnight = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: fromMidnight, to: toMidnight).day ?? 0
    }
}
