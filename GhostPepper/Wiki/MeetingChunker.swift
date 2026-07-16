import Foundation

/// One contiguous slice of a meeting file, with 1-indexed line bounds so
/// downstream quote citations can reference real `path:line` positions.
struct MeetingChunk: Equatable {
    let startLine: Int
    let endLine: Int
    let text: String
}

/// Deterministic chunker for meeting markdown. Splits on structural
/// boundaries (headings, `**[HH:MM] Speaker:**` transcript lines) so each
/// chunk fits comfortably in a small local model's context.
enum MeetingChunker {
    /// Splits `content` into chunks of roughly `targetChars` characters,
    /// never mid-line, preferring to break just before a heading or a
    /// timestamped speaker line. Chunks concatenate back to the original
    /// line sequence with no overlap and no gaps.
    static func chunk(_ content: String, targetChars: Int = 6000) -> [MeetingChunk] {
        let lines = content.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }

        var chunks: [MeetingChunk] = []
        var currentStart = 0
        var currentLength = 0
        var lastBoundary: Int? = nil  // index of a good split line ahead of the current position

        func flush(upTo endExclusive: Int) {
            guard endExclusive > currentStart else { return }
            let slice = lines[currentStart..<endExclusive]
            chunks.append(MeetingChunk(
                startLine: currentStart + 1,
                endLine: endExclusive,
                text: slice.joined(separator: "\n")
            ))
            currentStart = endExclusive
            currentLength = 0
            lastBoundary = nil
        }

        for (i, line) in lines.enumerated() {
            if i > currentStart, isBoundary(line) {
                lastBoundary = i
            }
            currentLength += line.count + 1
            if currentLength >= targetChars {
                // Prefer the most recent structural boundary if it's not too
                // far back; otherwise split right after this line.
                if let boundary = lastBoundary, boundary > currentStart {
                    flush(upTo: boundary)
                    // Re-account the lines between boundary and i inclusive.
                    currentLength = lines[currentStart...i].reduce(0) { $0 + $1.count + 1 }
                } else {
                    flush(upTo: i + 1)
                }
            }
        }
        flush(upTo: lines.count)
        return chunks
    }

    /// Lines we prefer to split before: markdown headings and timestamped
    /// speaker lines (the two structures both archive formats share).
    static func isBoundary(_ line: String) -> Bool {
        if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") {
            return true
        }
        if line.hasPrefix("**[") {
            // "**[HH:MM] Speaker:** ..." — cheap shape check, no regex needed.
            let after = line.dropFirst(3)
            if after.count >= 6 {
                let chars = Array(after.prefix(6))
                if chars[0].isNumber && chars[1].isNumber && chars[2] == ":" && chars[3].isNumber && chars[4].isNumber && chars[5] == "]" {
                    return true
                }
            }
        }
        return false
    }

    /// Renders a chunk with `L<n>: ` line-number prefixes so the extraction
    /// model can cite quote line numbers that map back to the real file.
    static func numberedText(for chunk: MeetingChunk) -> String {
        let lines = chunk.text.components(separatedBy: "\n")
        return lines.enumerated().map { (i, line) in
            "L\(chunk.startLine + i): \(line)"
        }.joined(separator: "\n")
    }
}
