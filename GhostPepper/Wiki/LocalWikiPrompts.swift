import Foundation

/// Prompts for the local wiki pipeline. Every prompt is single-purpose,
/// context-bounded, and demands a strict output shape — the opposite of the
/// open-ended agentic prompts in `IndexSystemPrompt`, which small models
/// can't drive. Prompt text changes should be treated as version bumps:
/// `IndexBuilder.hashPrompt` of each system string is stored on generated
/// artifacts so staleness is detectable.
enum LocalWikiPrompts {

    // MARK: - Card extraction (map stage)

    static let cardMarkdownSystem = """
    You create a constrained markdown wiki card from a slice of a meeting transcript. \
    Reply with ONLY markdown in the exact section structure below. Do not use JSON.

    ## Summary
    2-4 concrete sentences.

    ## Participants
    - [[Full Name]] — role/title; affiliation

    ## Mentioned People
    - [[Full Name]] — why they came up; possible role: role/title/type; confidence: low|medium|high

    ## Topics
    - short topic phrase

    ## Decisions
    - decision or ask agreed in this slice

    ## Open Threads
    - follow-up, intro to make, or unanswered question

    Rules:
    - Participants are people listed as attendees/participants, or speakers only \
      when the transcript explicitly labels a real human speaker. Do not infer \
      who spoke from context.
    - Mentioned people are named human beings discussed inside the meeting who \
      are not already participants. Include context and any possible job/title/type \
      only when supported by the text.
    - Transcripts are voice-to-text and contain artifacts; summarize likely \
      intended meaning without inventing facts.
    - Use [[wikilinks]] for every person name.
    - If a section has nothing useful, write exactly: (none)
    """

    static let cardMarkdownUserTemplate = """
    Meeting file: {{meeting_path}}
    Title: {{title}}
    Known participants from the title/attendee metadata:
    {{known_participants}}

    Slice {{chunk_number}} of {{chunk_count}}. Lines are prefixed "L<n>: ".

    {{transcript}}

    Now write the markdown wiki card for this slice. Include the known participants in the Participants section unless the transcript contradicts the metadata.
    """

    static func cardMarkdownUser(
        meetingPath: String,
        title: String,
        chunkIndex: Int,
        chunkCount: Int,
        numberedText: String,
        titleParticipants: [String] = [],
        template: String = LocalWikiPrompts.cardMarkdownUserTemplate
    ) -> String {
        let knownParticipants = titleParticipants.isEmpty
            ? "(none)"
            : titleParticipants.map { "- [[\($0)]]" }.joined(separator: "\n")
        return template
            .replacingOccurrences(of: "{{meeting_path}}", with: meetingPath)
            .replacingOccurrences(of: "{{title}}", with: title)
            .replacingOccurrences(of: "{{known_participants}}", with: knownParticipants)
            .replacingOccurrences(of: "{{chunk_index}}", with: "\(chunkIndex)")
            .replacingOccurrences(of: "{{chunk_number}}", with: "\(chunkIndex + 1)")
            .replacingOccurrences(of: "{{chunk_count}}", with: "\(chunkCount)")
            .replacingOccurrences(of: "{{transcript}}", with: numberedText)
    }

    static let cardMergeMarkdownSystem = """
    You merge several markdown wiki cards for slices of the SAME meeting into one \
    markdown wiki card. Reply with ONLY markdown using this exact section structure:

    ## Summary
    ## Participants
    ## Mentioned People
    ## Topics
    ## Decisions
    ## Open Threads

    - "summary": 3-5 sentences covering the whole meeting, synthesized from all parts.
    - Union the people/topic/decision/open-thread bullets.
    - Merge duplicate people, keeping the most complete concrete context.
    - Deduplicate near-identical topics/decisions/open_threads.
    - Use [[wikilinks]] for every person name.
    - If a section has nothing useful, write exactly: (none)
    """

    static func cardMergeMarkdownUser(meetingPath: String, title: String, partialCards: [String]) -> String {
        var out = "Meeting file: \(meetingPath)\nTitle: \(title)\n\n"
        for (i, partial) in partialCards.enumerated() {
            out += "# Slice card \(i + 1)\n\(partial)\n\n"
        }
        out += "Now reply with the single merged markdown wiki card."
        return out
    }

    // MARK: - Compatibility JSON extraction path
    //
    // Kept while the app still has JSON-card parsing in LocalWikiEngine.
    // The durable card format is being moved to markdown,
    // but this keeps the current test build runnable.

    static let cardObservationSystem = cardMarkdownSystem

    static func cardObservationUser(meetingPath: String, title: String, chunkIndex: Int, chunkCount: Int, numberedText: String) -> String {
        cardMarkdownUser(
            meetingPath: meetingPath,
            title: title,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            numberedText: numberedText
        )
    }

    static let cardExtractionSystem = """
    You convert meeting extraction notes into a strict JSON object. \
    Reply with ONLY a JSON object — no prose, no markdown fences.

    The JSON shape:
    {
      "summary": "2-4 sentences on what this slice covers, concrete and specific",
      "participants": [{"name": "", "role": "", "affiliation": ""}],
      "mentioned_people": [{"name": "", "context": "why they came up", "possible_role": "", "confidence": "low|medium|high"}],
      "topics": ["short topic phrases"],
      "decisions": ["decisions made or asks agreed in this slice"],
      "open_threads": ["follow-ups, intros to make, unanswered questions"]
    }

    Rules:
    - "participants": people listed as attendees/participants, or speakers only \
      when the transcript explicitly labels a real human speaker. Do not infer \
      who spoke from context. Use the fullest form of the name that appears. \
      role/affiliation empty string if unknown.
    - "mentioned_people": named human beings discussed inside the meeting who \
      are not already participants. Include people mentioned in notes, summaries, \
      attendee context, and transcript text. "context" should be one short phrase. \
      "possible_role" is optional: job/title/type such as "venture capitalist", \
      "founder", "candidate", or empty string when unclear.
    - Transcripts are voice-to-text and contain artifacts; summarize the likely \
      intended meaning, don't transcribe the garble.
    - Empty arrays are fine. Never invent names or facts not in the input.
    """

    static func cardExtractionUser(meetingPath: String, title: String, chunkIndex: Int, chunkCount: Int, extractionNotes: String) -> String {
        """
        Meeting file: \(meetingPath)
        Title: \(title)
        Slice \(chunkIndex + 1) of \(chunkCount).

        Extraction notes:

        \(extractionNotes)

        Now reply with the JSON object.
        """
    }

    static let cardMergeSystem = """
    You merge several partial JSON digests of the SAME meeting into one. \
    Reply with ONLY a JSON object of the same shape:
    {"summary": "", "participants": [], "mentioned_people": [], "topics": [], "decisions": [], "open_threads": []}

    Rules:
    - "summary": 3-5 sentences covering the whole meeting, synthesized from all parts.
    - Union the arrays. Merge duplicate participants (same person, different \
      detail) into one entry keeping the most complete role/affiliation.
    - Merge duplicate mentioned_people by name, keeping the most concrete context, \
      possible_role, and confidence.
    - Deduplicate near-identical topics/decisions/open_threads.
    """

    static func cardMergeUser(meetingPath: String, title: String, partialJSONs: [String]) -> String {
        var out = "Meeting file: \(meetingPath)\nTitle: \(title)\n\n"
        for (i, partial) in partialJSONs.enumerated() {
            out += "## Part \(i + 1)\n\(partial)\n\n"
        }
        out += "Now reply with the single merged JSON object."
        return out
    }

    // MARK: - Mention scan (per non-people wiki kind)

    static func mentionScanSystem(spec: WikiKindSpec) -> String {
        """
        You scan a meeting digest for every \(spec.entityNoun) it references. \
        What counts as a \(spec.entityNoun): \(spec.extractionHint)

        Reply with ONLY a JSON object:
        {"mentions": [{"name": "", "context": "one short phrase on how it came up"}]}

        Rules:
        - "name": the canonical-looking form of the \(spec.entityNoun)'s name as it \
          appears in the digest.
        - Only include entities actually present in the digest. Empty array is fine.
        - No duplicates.
        """
    }

    static func mentionScanUser(cardDigest: String) -> String {
        """
        Meeting digest:

        \(cardDigest)

        Now reply with the JSON object of mentions.
        """
    }

    // MARK: - Alias adjudication (multiple choice)

    static let adjudicationSystem = """
    You disambiguate a name mention against known entries. Reply with ONLY a \
    JSON object: {"answer": "A"} — a single capital letter, nothing else.
    """

    static func adjudicationUser(name: String, context: String, candidates: [String]) -> String {
        var out = """
        In this meeting context, who does "\(name)" most likely refer to?

        Context: \(context.isEmpty ? "(no additional context)" : context)

        Options:
        """
        let letters = ["A", "B", "C", "D", "E", "F"]
        for (i, candidate) in candidates.prefix(5).enumerated() {
            out += "\n\(letters[i]). \(candidate)"
        }
        let newLetter = letters[min(candidates.count, 5)]
        out += "\n\(newLetter). Someone new / can't tell — do not merge."
        out += "\n\nReply with the JSON object."
        return out
    }

    // MARK: - Narrative sections (reduce stage)

    enum NarrativeSection: String, CaseIterable {
        case overview = "Overview"
        case relationship = "Relationship & Context"
        case themes = "Themes & Interests"
        case openThreads = "Open Threads"

        var instruction: String {
            switch self {
            case .overview:
                return "One tight paragraph: who/what this is, why it matters to the user. Include concrete roles, ventures, affiliations when known."
            case .relationship:
                return "How this connects to the user: how they met or engage, recurring collaborations, shared connections. Use [[Name]] wikilinks for other people who likely have their own dossier."
            case .themes:
                return "Recurring topics, areas of expertise, or opinions expressed across the meetings. Concrete, not generic."
            case .openThreads:
                return "Anything pending: follow-ups owed, intros to make, deals or questions in flight. If nothing is genuinely open, reply with exactly: (none)"
            }
        }
    }

    static func narrativeSystem(section: NarrativeSection, spec: WikiKindSpec) -> String {
        """
        You write the "\(section.rawValue)" section of a \(spec.entityNoun) dossier, \
        from meeting digests provided by the user. Write 1 short markdown \
        section body — no heading, no preamble, no code fences.

        \(section.instruction)

        Rules:
        - Only state facts present in the digests. Cite meetings inline as \
          their bare path, e.g. 2026-04-28/standup.md, for non-obvious claims.
        - 40-120 words. Plain prose or at most 4 tight bullets.
        - Never invent facts, dates, or names.
        """
    }

    static func narrativeUser(canonicalName: String, spec: WikiKindSpec, cardsDigest: String) -> String {
        """
        Dossier subject (\(spec.entityNoun)): \(canonicalName)

        Meeting digests (chronological):

        \(cardsDigest)

        Now write the section body.
        """
    }

    // MARK: - Dossier merge (local counterpart of IndexBuilder.mergeDossierBody)

    static let mergeDossierSystem = """
    You merge new findings into an existing dossier body. Output ONLY the \
    merged markdown body — no YAML frontmatter, no leading or trailing \
    `---` separators, no code fences.

    Preserve content from the existing body that's still accurate, fold in \
    genuinely new information, and remove redundancy. Keep the existing \
    section structure. Use [[Person Name]] wikilinks when referring to other \
    people who may have their own dossier. Never invent facts.
    """

    static func mergeDossierUser(canonicalName: String, existingBody: String, newContent: String) -> String {
        """
        Subject: \(canonicalName)

        ## Existing dossier body

        \(existingBody.isEmpty ? "(empty — this is the first substantive write)" : existingBody)

        ## New findings to merge in

        \(newContent)

        Now produce the merged body.
        """
    }

    // MARK: - Wiki kind proposals

    static let proposeKindsSystem = """
    You suggest new wiki categories for a personal meeting archive, based on \
    what its meetings actually discuss. Existing categories are listed; never \
    re-propose them or trivial variations of them.

    Reply with ONLY a JSON object:
    {"proposals": [{"name": "Companies", "entity_noun": "company", "hint": "what counts as one, in one sentence", "rationale": "why this archive would benefit, citing the observed data"}]}

    Rules:
    - 0 to 3 proposals. An empty list is a good answer when nothing clears the bar.
    - Only propose a category when the observed topics/affiliations show MANY \
      recurring instances of it (rule of thumb: would 10+ pages get created?).
    - "name" is a short plural display name. "entity_noun" is the singular, lowercase.
    """

    static func proposeKindsUser(existingKinds: [WikiKindSpec], digest: String) -> String {
        """
        Existing wiki categories: \(existingKinds.map { $0.displayName }.joined(separator: ", "))

        Observed archive signals (from meeting digests):

        \(digest)

        Now reply with the JSON object.
        """
    }
}
