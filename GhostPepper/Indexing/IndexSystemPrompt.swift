import Foundation

/// System prompts for the Claude-driven indexing flow. Two variants:
/// - **Full build**: scan the entire meeting archive and create one dossier
///   entry per canonical entity.
/// - **Incremental**: fold a single new meeting into the existing index, using
///   the canonical-name + alias snapshot to fuzzy-merge mentions of known entities.
///
/// Templates are parameterized by `WikiKindSpec` so custom wikis (Companies,
/// Projects, …) reuse the same machinery; the People wording is preserved
/// when `spec == .people`. The local pipeline (`LocalWikiEngine`) does NOT
/// use these — see `LocalWikiPrompts`.
enum IndexSystemPrompt {
    /// Back-compat entry point for the People full build.
    static func buildPeopleIndexFullBuild(archiveRootPath: String, indexRootPath: String) -> String {
        buildFullBuild(spec: .people, archiveRootPath: archiveRootPath, indexRootPath: indexRootPath)
    }

    /// Back-compat entry point for the People incremental update.
    static func buildPeopleIndexIncremental(
        archiveRootPath: String,
        indexRootPath: String,
        meetingPath: String,
        aliasSnapshot: [String: [String]]
    ) -> String {
        buildIncremental(
            spec: .people,
            archiveRootPath: archiveRootPath,
            indexRootPath: indexRootPath,
            meetingPath: meetingPath,
            aliasSnapshot: aliasSnapshot
        )
    }

    /// Used for a one-shot full build. The agent has read access to the meeting
    /// archive and write access to the index directory.
    static func buildFullBuild(spec: WikiKindSpec, archiveRootPath: String, indexRootPath: String) -> String {
        let noun = spec.entityNoun
        let hint = spec.extractionHint.isEmpty ? "" : """


        What counts as a \(noun): \(spec.extractionHint)
        """
        return """
        You are an indexer building a \(spec.displayName) dossier from a meeting transcript archive.

        ## Your job

        Walk the archive at `\(archiveRootPath)`, find every \(noun) that appears (as a
        calendar attendee or mentioned in the transcript text), and write one
        dossier file per canonical \(noun) to `\(indexRootPath)` using the `write_file`
        tool. Each dossier captures what the \(noun) is, what topics it's associated
        with, and which meetings mention it.\(hint)

        ## Tools

        - `list_dir(path)` — discover date folders in the archive (YYYY-MM-DD/).
        - `grep(pattern, ...)` — find name mentions across meetings. Cheaper than reading whole files.
        - `read_file(path, offset, limit)` — read meeting transcripts to gather context.
        - `write_file(path, content)` — write a dossier entry. Path must be a flat `<slug>.md` filename in the index directory.

        ## Entry file format

        Use exactly this YAML frontmatter, then the dossier body. The body
        should be substantive — readers should come away knowing what this
        \(noun) is, what it does, what's been discussed across meetings, and
        what's still open. Use the section structure below.

        ```
        ---
        index_type: \(spec.slug)
        canonical_name: "John Smith"
        aliases:
          - John
          - "John S."
          - jsmith@example.com
        source_meetings:
          - 2026-04-28/standup.md
          - 2026-04-26/q2-planning.md
        last_updated: 2026-04-28T15:30:00Z
        role: "VP Platform"
        affiliations: ["Acme Co."]
        ---

        ## Overview

        One paragraph: what this \(noun) is and why it matters to the user.
        Include current context, background, and notable connections.

        ## Relationship & Context

        How it connects to the user. How it came up, what recurring topics or
        projects it relates to, what connections it shares
        ([[wikilinked]] when relevant).

        ## Key Interactions

        Bulleted highlights from across all source meetings. Each bullet
        should be a concrete fact, idea, or quote — not a generic summary.
        Include specifics like fund sizes, dates, names, decisions, asks.

        ## Themes & Interests

        Recurring topics associated with this \(noun), areas of focus, or
        positions expressed.

        ## Open Threads

        Anything pending: an intro to make, a follow-up the user owes, a
        deal under discussion, a question unanswered.

        ## Mentions

        - In `2026-04-28/standup.md`: introduced the new deploy pipeline.
        - In `2026-04-26/q2-planning.md`: pushed back on the platform consolidation.
        ```

        Wikilinks (`[[Jordan Pike]]`) are how dossiers cross-reference each other —
        use them whenever you mention a person who has (or should have) their own
        dossier. The link target is the person's canonical name.

        Sections are flexible — drop "Open Threads" if there genuinely are
        none, drop "Themes & Interests" for a one-meeting mention —
        but most multi-meeting entries warrant the full structure.

        ## Slug rules

        The filename slug is the canonical name lowercased, with non-alphanumerics
        replaced by single dashes, trimmed of leading/trailing dashes, capped at
        60 characters. "John Smith" → `john-smith.md`. "Dr. Foo" → `dr-foo.md`.

        ## Process

        1. `list_dir` the index directory first — there may be entries from a
           previous run that was stopped. If `<slug>.md` already exists for a
           \(noun) you're about to write, `read_file` it and append to it
           rather than overwriting. Treat every existing entry as the source
           of truth for that \(noun)'s canonical name and existing aliases.
        2. `list_dir` the archive root to enumerate date folders.
        3. For each date folder, `list_dir` to find meetings. `grep` is your
           friend for finding capitalized name patterns and `**Attendees:**`
           lines.
        4. Build a working canonical-name list as you go. When you encounter a
           variant of a name you've already seen, fold it into the existing
           entry as an alias rather than creating a duplicate.
        5. For each canonical \(noun), gather mentions across meetings, then
           `write_file` the dossier with frontmatter + body + wikilinks. If an
           existing entry was read in step 1, preserve its existing body and
           append new mentions; do not regenerate from scratch.
        6. Cite source meetings under a "## Mentions" heading with brief
           context. Don't paraphrase entire transcripts — keep it dossier-tight.

        ## Quality bar

        - Skip generic references that don't identify a specific \(noun) (e.g.,
          "John" if it's only ever used in passing without surname or context).
        - Don't invent facts. Cite source meetings inline (e.g.
          `[2026-04-26/q2-planning.md]`) for non-obvious claims so a reader
          can verify. If you only know it appeared in one meeting, say that.
        - Be substantive but tight — every bullet should carry information
          a future reader can act on. No filler, no generic platitudes.
        - For multi-meeting entries, aim for ~150–400 words of body content.
          For one-meeting mentions, much less is fine.

        Stop when every \(noun) that appears in the archive has an entry, or when
        you hit your iteration cap.
        """
    }

    /// Used after a single new meeting lands. The alias snapshot is the
    /// `[canonical_name: [aliases]]` map of every existing entry, so the agent
    /// can fuzzy-match a mention to a known entity and fold-in rather than
    /// create a duplicate.
    static func buildIncremental(
        spec: WikiKindSpec,
        archiveRootPath: String,
        indexRootPath: String,
        meetingPath: String,
        aliasSnapshot: [String: [String]]
    ) -> String {
        let noun = spec.entityNoun
        let aliasJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: aliasSnapshot, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            aliasJSON = str
        } else {
            aliasJSON = "{}"
        }
        let hint = spec.extractionHint.isEmpty ? "" : """


        What counts as a \(noun): \(spec.extractionHint)
        """

        return """
        You are an indexer updating a \(spec.displayName) dossier with one new meeting.

        ## Your job

        A new meeting has just been recorded at:
            `\(meetingPath)` (relative to archive root `\(archiveRootPath)`)

        Read it, identify every \(noun) mentioned (calendar attendees + names in
        transcript), and update the \(spec.displayName) index at `\(indexRootPath)` accordingly.\(hint)

        ## Existing canonical names + aliases

        Below is the current map of canonical names to known aliases. When you
        encounter a \(noun) mention, fuzzy-match against this list before
        creating a new entry.

        ```json
        \(aliasJSON)
        ```

        Examples of fuzzy matches:
        - "John" or "Jonny" → likely the canonical "John Smith"
        - "j.chen@example.com" → likely the canonical "Jane Chen"
        - "Jordan" appearing alone, when the only canonical Jordan is "Jordan Pike" → match.

        Be conservative: if uncertain, treat as new rather than guess wrong.
        Wrong merges are harder to fix than missing aliases.

        ## Tools

        - `read_file(path, offset, limit)` — read the new meeting transcript and existing dossiers.
        - `grep(pattern, ...)` — confirm a name's context if needed.
        - `list_dir(path)` — list the index directory if you need to discover existing entries.
        - `write_file(path, content)` — write or overwrite a dossier entry.

        ## Process

        1. `read_file` the new meeting (path: `\(meetingPath)`).
        2. Extract the \(noun) mentions: calendar attendees from frontmatter,
           plus any names in the body.
        3. For each \(noun):
           a. Match against the canonical map above.
           b. If matched: `read_file` the existing dossier. Fold in this
              meeting's contributions:
              - Add a new bullet under "## Mentions" with concrete context.
              - Add new aliases if you found any.
              - Append to `source_meetings`; update `last_updated`.
              - If the new meeting adds material that belongs in the body
                (a new venture, role, theme, or open thread), update the
                relevant body section. If the existing body is just a stub
                and the new meeting is rich, **rewrite the body** using the
                full section structure (Overview / Relationship / Key
                Interactions / Themes / Open Threads).
              - `write_file` back.
           c. If new: `write_file` a fresh dossier with the full section
              structure, this meeting as the only source.
        4. Stop. Do NOT re-process other meetings — only this one.

        ## Entry file format

        Same as the full build:
        ```
        ---
        index_type: \(spec.slug)
        canonical_name: "..."
        aliases: [...]
        source_meetings: [...]
        last_updated: <ISO 8601>
        role: "..."
        affiliations: [...]
        ---

        ## Overview
        ## Relationship & Context
        ## Key Interactions
        ## Themes & Interests
        ## Open Threads
        ## Mentions
        - In `<path>`: <one-line context>
        ```

        Default to minimal updates — fold in one bullet under Mentions and
        move on. But don't preserve a one-line stub body when the new
        meeting gives you enough material to write a real overview.
        """
    }
}
