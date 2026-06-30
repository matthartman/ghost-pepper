import Foundation

/// Generates meeting summaries using the local LLM via chunked summarization.
///
/// Strategy: The transcript is split into chunks that fit the model's context window.
/// Each chunk is summarized into bullet points. Then the bullet points are combined
/// into a final summary with key topics, action items, and a TL;DR.
@MainActor
final class MeetingSummaryGenerator {
    private let cleanupManager: TextCleanupManager

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
        guard !transcript.segments.isEmpty else { return nil }

        let fullText = transcript.plainText
        let chunks = splitIntoChunks(fullText)

        // Include user notes if available
        let notesText = transcript.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesPrefix = notesText.isEmpty ? "" : "User's notes during the meeting:\n\n\(notesText)\n\n"

        if chunks.count == 1 {
            // Short meeting — summarize directly with the final prompt
            let input = "\(notesPrefix)Meeting transcript:\n\n\(chunks[0])"
            return await runLLM(text: input, prompt: finalPrompt)
        }

        // Multi-chunk: summarize each chunk, then combine
        var chunkSummaries: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let input = "Meeting transcript (part \(i + 1) of \(chunks.count)):\n\n\(chunk)"
            if let summary = await runLLM(text: input, prompt: chunkPrompt) {
                chunkSummaries.append(summary)
            }
        }

        guard !chunkSummaries.isEmpty else { return nil }

        // Combine chunk summaries into final summary
        let combined = chunkSummaries.enumerated().map { i, s in
            "Part \(i + 1):\n\(s)"
        }.joined(separator: "\n\n")

        let finalInput = "\(notesPrefix)Combined meeting notes:\n\n\(combined)"
        return await runLLM(text: finalInput, prompt: finalPrompt)
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

    private func runLLM(text: String, prompt: String) async -> String? {
        do {
            let fullPrompt = "\(prompt)\n\n\(text)"
            let result = try await cleanupManager.clean(text: fullPrompt, prompt: nil)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            print("MeetingSummaryGenerator: LLM failed — \(error.localizedDescription)")
            return nil
        }
    }
}
