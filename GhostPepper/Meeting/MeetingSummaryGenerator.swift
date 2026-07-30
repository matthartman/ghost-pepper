import Foundation

/// Generates meeting summaries using the local LLM via chunked summarization.
///
/// Strategy: The transcript is split into chunks that fit the model's context window.
/// Each chunk is summarized into bullet points. Then the bullet points are combined
/// into a final summary with key topics, action items, and a TL;DR.
@MainActor
final class MeetingSummaryGenerator {
    private let cleanupManager: TextCleanupManager
    var debugLogger: ((DebugLogCategory, String) -> Void)?

    /// Maximum characters per chunk sent to the LLM (~1500 tokens ≈ 6000 chars).
    private let chunkCharLimit = 5000

    static let defaultPrompt = """
    Summarize the following meeting excerpt. Output concise bullet points organized by topic. \
    Include key facts, decisions, numbers, names, and dates. Be brief.
    """

    static let finalSummaryPrompt = """
    You are summarizing a meeting. You will receive a transcript and optionally the user's own notes \
    taken during the meeting. Read both carefully, then produce a structured summary organized by topic.

    Rules:
    - If the user wrote notes, treat them as a guide — they highlight what mattered most. Ensure those topics are covered prominently and expand on them with details from the transcript.
    - Use ### headings for each major topic discussed (e.g., "### Product Update", "### Hiring Plan", "### Q3 Budget")
    - Under each topic, use concise bullet points capturing key facts, decisions, numbers, names, and dates
    - Include a "### Next Steps" section at the end with any action items or follow-ups mentioned, using checkbox format: - [ ] Task — Owner
    - If the meeting is a 1:1 or introductory call, organize by the person/company discussed and what was learned
    - If the meeting is a group discussion or brainstorm, organize by the themes that emerged
    - Do NOT use generic headings like "Discussion Points" or "Key Takeaways" — use specific topic names from the actual conversation
    - Do NOT include filler, pleasantries, or off-topic chatter
    - Keep bullets factual and specific
    - Write in present tense for facts, past tense for what happened
    """

    init(cleanupManager: TextCleanupManager) {
        self.cleanupManager = cleanupManager
    }

    /// Generate a full summary for a completed meeting transcript.
    /// Returns the summary as markdown text, or nil if generation fails.
    func generateSummary(
        transcript: MeetingTranscript,
        chunkPrompt: String = MeetingSummaryGenerator.defaultPrompt,
        finalPrompt: String = MeetingSummaryGenerator.finalSummaryPrompt
    ) async -> String? {
        let segments = transcript.segments
        guard !segments.isEmpty else { return nil }

        // Build the full transcript text
        let fullText = segments.map { segment in
            "[\(segment.formattedTimestamp)] \(segment.speaker.displayName): \(segment.text)"
        }.joined(separator: "\n")

        // Split into chunks
        let chunks = splitIntoChunks(fullText)

        debugLogger?(
            .model,
            "Meeting summary: starting for \(transcript.meetingName) (\(segments.count) segments, \(chunks.count) chunk(s))."
        )

        // Include user notes if available
        let notesText = transcript.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesPrefix = notesText.isEmpty ? "" : "User's notes during the meeting:\n\n\(notesText)\n\n"

        if chunks.count == 1 {
            // Short meeting — summarize directly with the final prompt
            let input = "\(notesPrefix)Meeting transcript:\n\n\(chunks[0])"
            do {
                return try await runLLM(text: input, prompt: finalPrompt)
            } catch {
                debugLogger?(
                    .model,
                    "Meeting summary: final combine step failed (\(error.localizedDescription))."
                )
                return nil
            }
        }

        // Multi-chunk: summarize each chunk, then combine
        var chunkSummaries: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let input = "Meeting transcript (part \(i + 1) of \(chunks.count)):\n\n\(chunk)"
            do {
                let summary = try await runLLM(text: input, prompt: chunkPrompt)
                chunkSummaries.append(summary)
            } catch {
                debugLogger?(
                    .model,
                    "Meeting summary: chunk \(i + 1)/\(chunks.count) failed (\(error.localizedDescription)) — dropped from summary."
                )
            }
        }

        debugLogger?(
            .model,
            "Meeting summary: chunk summarization complete — \(chunkSummaries.count)/\(chunks.count) chunks succeeded."
        )

        guard !chunkSummaries.isEmpty else { return nil }

        // Combine chunk summaries into final summary
        let combined = chunkSummaries.enumerated().map { i, s in
            "Part \(i + 1):\n\(s)"
        }.joined(separator: "\n\n")

        let finalInput = "\(notesPrefix)Combined meeting notes:\n\n\(combined)"
        do {
            return try await runLLM(text: finalInput, prompt: finalPrompt)
        } catch {
            debugLogger?(
                .model,
                "Meeting summary: final combine step failed (\(error.localizedDescription)) — \(chunkSummaries.count)/\(chunks.count) chunk summaries discarded."
            )
            return nil
        }
    }

    // MARK: - Private

    private func splitIntoChunks(_ text: String) -> [String] {
        guard text.count > chunkCharLimit else { return [text] }

        var chunks: [String] = []
        let lines = text.components(separatedBy: "\n")
        var current = ""

        for line in lines {
            if current.count + line.count + 1 > chunkCharLimit && !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    private func runLLM(text: String, prompt: String) async throws -> String {
        let result = try await cleanupManager.clean(text: text, prompt: prompt)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
