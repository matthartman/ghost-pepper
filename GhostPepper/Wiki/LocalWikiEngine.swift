import Foundation

/// On-device wiki builder. Drives the map → resolve → reduce pipeline:
///
///   1. **Cards** — each meeting is distilled once into a `MeetingCard`
///      (chunked extraction + merge, all JSON-validated).
///   2. **Entity resolution** — names resolve to canonical entries
///      deterministically (`WikiEntityResolver`); only genuine ambiguity
///      spends a multiple-choice LLM call.
///   3. **Pages** — dossiers are *assembled*: frontmatter, Mentions, and
///      Timeline are pure Swift from the card set; only the narrative
///      sections are model-written, and they're regenerated from cards
///      (never merged) so nothing silently drops.
///
/// Conforms to `IndexBuilding`, so the build sheet, incremental updates, and
/// dossier apply work identically to the Claude-driven `IndexBuilder` — at
/// zero token cost.
@MainActor
final class LocalWikiEngine: IndexBuilding {
    private let cleanupManager: TextCleanupManager
    private let saveDir: URL
    private let modelKind: LocalCleanupModelKind
    private let llm: LocalStructuredLLM
    private var perKindChain: [IndexKind: Task<Void, Never>] = [:]

    /// Long transcripts are capped at this many chunks per card so one
    /// pathological file can't stall a build. The tail is skipped, not lost —
    /// grep/search still covers it.
    static let maxChunksPerMeeting = 12
    /// Regenerate an entity's narrative after this many new meetings accrue.
    private static let narrativeRefreshInterval = 3

    var modelDisplayName: String {
        AgentBackend.local(modelKind).shortDisplayName + " (local)"
    }

    init(cleanupManager: TextCleanupManager, saveDir: URL, modelKind: LocalCleanupModelKind) {
        self.cleanupManager = cleanupManager
        self.saveDir = saveDir
        self.modelKind = modelKind
        self.llm = LocalStructuredLLM(cleanupManager: cleanupManager, modelKind: modelKind)
    }

    // MARK: - IndexBuilding: estimate

    func estimateBuildCost(kind: IndexKind) async throws -> IndexBuildEstimate {
        let allMeetings = IndexBuilder.allMeetingPaths(in: saveDir)
        let manifestURL = MarkdownArchivePaths.manifestURL(in: saveDir, kind: kind)
        let manifest = IndexManifest.loadOrEmpty(at: manifestURL, kind: kind)
        let processed = allMeetings.filter { manifest.isProcessed(meetingPath: $0) }.count
        return IndexBuildEstimate(
            totalMeetingCount: allMeetings.count,
            alreadyProcessedCount: processed,
            existingEntryCount: IndexBuilder.countExistingEntries(in: saveDir, kind: kind),
            likelyLowUSD: 0,
            likelyHighUSD: 0,
            modelDisplayName: modelDisplayName
        )
    }

    // MARK: - IndexBuilding: full build

    func buildFullIndex(kind: IndexKind) -> AsyncThrowingStream<IndexBuildEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.runFullBuild(kind: kind, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runFullBuild(kind: IndexKind, continuation: AsyncThrowingStream<IndexBuildEvent, Error>.Continuation) async {
        let indexRoot = MarkdownArchivePaths.indexRoot(in: saveDir, kind: kind)
        do {
            try FileManager.default.createDirectory(at: indexRoot, withIntermediateDirectories: true)
        } catch {
            continuation.yield(.error("Couldn't create index directory: \(error.localizedDescription)"))
            continuation.finish()
            return
        }

        let allMeetings = IndexBuilder.allMeetingPaths(in: saveDir)
        let manifestURL = MarkdownArchivePaths.manifestURL(in: saveDir, kind: kind)
        var manifest = IndexManifest.loadOrEmpty(at: manifestURL, kind: kind)
        let unprocessed = allMeetings.filter { !manifest.isProcessed(meetingPath: $0) }
        let totalCount = allMeetings.count

        if unprocessed.isEmpty {
            continuation.yield(.status("Index is up to date — nothing to process."))
            continuation.yield(.completed)
            continuation.finish()
            return
        }

        continuation.yield(.meetingsProcessed(processed: totalCount - unprocessed.count, total: totalCount))

        // Phase 1: ensure a card exists for every unprocessed meeting.
        var freshCards: [MeetingCard] = []
        var processedCount = totalCount - unprocessed.count
        for meetingPath in unprocessed {
            if Task.isCancelled { continuation.finish(); return }
            continuation.yield(.status("Digesting \(meetingPath)"))
            do {
                var card = try await ensureCard(meetingPath: meetingPath)
                card = await ensureMentionScan(card: card, kind: kind, continuation: continuation)
                freshCards.append(card)
            } catch {
                continuation.yield(.status("Skipped \(meetingPath): \(error.localizedDescription)"))
            }
            processedCount += 1
            continuation.yield(.meetingsProcessed(processed: processedCount, total: totalCount))
        }

        if Task.isCancelled { continuation.finish(); return }

        // Phase 2: resolve entities across ALL current cards (fresh + prior),
        // so returning entities accumulate onto their existing pages.
        continuation.yield(.status("Resolving \(kind.displayName.lowercased()) across meetings…"))
        let allCards = MeetingCardStore.allCards(in: saveDir)
        let groups = await groupEntities(kind: kind, cards: allCards)

        // Phase 3: write pages for entities touched by the fresh cards.
        let freshPaths = Set(freshCards.map { $0.meetingPath })
        let touched = groups.filter { !$0.meetingPaths.isDisjoint(with: freshPaths) }
        for group in touched.sorted(by: { $0.canonicalName < $1.canonicalName }) {
            if Task.isCancelled { continuation.finish(); return }
            continuation.yield(.status("Writing \(group.canonicalName)"))
            do {
                let slug = try await updateEntityPage(kind: kind, group: group, cards: allCards)
                continuation.yield(.entryWritten(slug: slug, canonicalName: group.canonicalName))
            } catch {
                continuation.yield(.status("Failed \(group.canonicalName): \(error.localizedDescription)"))
            }
        }

        // Only mark meetings whose card actually landed; failures retry next run.
        let now = Date()
        manifest.builtAt = now
        let landed = Set(freshCards.map { $0.meetingPath })
        for meeting in unprocessed where landed.contains(meeting) {
            manifest.markProcessed(meetingPath: meeting, entriesTouched: [], at: now)
        }
        do {
            try manifest.save(to: manifestURL)
        } catch {
            continuation.yield(.error("Built, but failed to save manifest: \(error.localizedDescription)"))
            continuation.finish()
            return
        }

        continuation.yield(.usage(QAUsage.local(modelDisplayName: modelDisplayName, inputTokens: 0, outputTokens: 0)))
        continuation.yield(.completed)
        continuation.finish()
        NotificationCenter.default.post(name: .indexUpdated, object: kind)
    }

    // MARK: - IndexBuilding: incremental

    func updateForMeeting(_ meetingURL: URL, kind: IndexKind) {
        let previous = perKindChain[kind]
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.runIncremental(meetingURL: meetingURL, kind: kind)
        }
        perKindChain[kind] = task
    }

    private func runIncremental(meetingURL: URL, kind: IndexKind) async {
        let indexRoot = MarkdownArchivePaths.indexRoot(in: saveDir, kind: kind)
        guard FileManager.default.fileExists(atPath: indexRoot.path) else { return }

        guard let meetingPath = Self.relativePath(of: meetingURL, in: saveDir) else { return }
        let manifestURL = MarkdownArchivePaths.manifestURL(in: saveDir, kind: kind)
        var manifest = IndexManifest.loadOrEmpty(at: manifestURL, kind: kind)
        guard !manifest.isProcessed(meetingPath: meetingPath) else { return }

        do {
            var card = try await ensureCard(meetingPath: meetingPath)
            card = await ensureMentionScan(card: card, kind: kind, continuation: nil)

            let names = card.entityNames(forKind: kind.rawValue)
            guard !names.isEmpty else {
                manifest.markProcessed(meetingPath: meetingPath, entriesTouched: [])
                try? manifest.save(to: manifestURL)
                return
            }

            let allCards = MeetingCardStore.allCards(in: saveDir)
            let groups = await groupEntities(kind: kind, cards: allCards)
            var entriesTouched: [String] = []
            for group in groups where group.meetingPaths.contains(meetingPath) {
                if let slug = try? await updateEntityPage(kind: kind, group: group, cards: allCards) {
                    entriesTouched.append(slug)
                }
            }
            manifest.markProcessed(meetingPath: meetingPath, entriesTouched: entriesTouched.sorted())
            try? manifest.save(to: manifestURL)
            NotificationCenter.default.post(name: .indexUpdated, object: kind)
        } catch {
            // Silent on failure, like IndexBuilder.runIncremental — the
            // manifest stays unchanged so the meeting retries next time.
        }
    }

    // MARK: - IndexBuilding: dossier merge (Q&A "Apply" path)

    func mergeDossierBody(
        kind: IndexKind,
        slug: String,
        canonicalName: String,
        newContent: String
    ) async throws -> MergeDossierResult {
        let url = MarkdownArchivePaths.entryURL(in: saveDir, kind: kind, slug: slug)
        let existingBody = (try? IndexEntryFile.read(from: url).body) ?? ""
        let merged = try await llm.complete(
            system: LocalWikiPrompts.mergeDossierSystem,
            user: LocalWikiPrompts.mergeDossierUser(
                canonicalName: canonicalName,
                existingBody: existingBody,
                newContent: newContent
            )
        )
        let generation = GenerationMetadata(
            model: modelDisplayName,
            promptKind: "merge-dossier-body-local",
            promptHash: IndexBuilder.hashPrompt(LocalWikiPrompts.mergeDossierSystem),
            generatedAt: Date()
        )
        return MergeDossierResult(body: merged, generation: generation)
    }

    // MARK: - Cards (map stage)

    /// Returns the current card for a meeting, extracting one if it's
    /// missing or stale.
    func ensureCard(meetingPath: String) async throws -> MeetingCard {
        let fileURL = saveDir.appendingPathComponent(meetingPath)
        if let existing = MeetingCardStore.read(in: saveDir, meetingPath: meetingPath),
           MeetingCardStore.isCurrent(existing, sourceURL: fileURL) {
            return existing
        }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let fileLines = content.components(separatedBy: "\n")
        let title = Self.extractTitle(from: fileLines) ?? fileURL.deletingPathExtension().lastPathComponent
        let date = Self.extractDate(from: fileLines, meetingPath: meetingPath)

        var chunks = MeetingChunker.chunk(content)
        if chunks.count > Self.maxChunksPerMeeting {
            chunks = Array(chunks.prefix(Self.maxChunksPerMeeting))
        }

        var partials: [[String: Any]] = []
        for (i, chunk) in chunks.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let notes = try await llm.complete(
                system: LocalWikiPrompts.cardObservationSystem,
                user: LocalWikiPrompts.cardObservationUser(
                    meetingPath: meetingPath,
                    title: title,
                    chunkIndex: i,
                    chunkCount: chunks.count,
                    numberedText: MeetingChunker.numberedText(for: chunk)
                )
            )
            let object = try await llm.completeJSONObject(
                system: LocalWikiPrompts.cardExtractionSystem,
                user: LocalWikiPrompts.cardExtractionUser(
                    meetingPath: meetingPath,
                    title: title,
                    chunkIndex: i,
                    chunkCount: chunks.count,
                    extractionNotes: notes
                )
            )
            partials.append(object)
        }

        let merged: [String: Any]
        if partials.count <= 1 {
            merged = partials.first ?? [:]
        } else {
            let partialJSONs = partials.compactMap { dict -> String? in
                guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            merged = try await llm.completeJSONObject(
                system: LocalWikiPrompts.cardMergeSystem,
                user: LocalWikiPrompts.cardMergeUser(meetingPath: meetingPath, title: title, partialJSONs: partialJSONs)
            )
        }

        let mtime = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date) ?? Date()
        let rawQuotes = MeetingCardJSON.quotes(merged["quotes"])
        let card = MeetingCard(
            version: MeetingCard.currentVersion,
            meetingPath: meetingPath,
            title: title,
            date: date,
            summary: MeetingCardJSON.string(merged["summary"]),
            participants: MeetingCardJSON.participants(merged["participants"]),
            mentionedPeople: MeetingCardJSON.mentionedPeople(merged["mentioned_people"] ?? merged["mentionedPeople"]),
            mentions: [],
            topics: MeetingCardJSON.stringList(merged["topics"]),
            decisions: MeetingCardJSON.stringList(merged["decisions"]),
            openThreads: MeetingCardJSON.stringList(merged["open_threads"] ?? merged["openThreads"]),
            quotes: MeetingCardJSON.validatedQuotes(rawQuotes, fileLines: fileLines),
            scannedKinds: ["people"],
            sourceModifiedAt: mtime,
            generatedByModel: modelKind.rawValue,
            promptHash: IndexBuilder.hashPrompt(LocalWikiPrompts.cardExtractionSystem),
            generatedAt: Date()
        )
        try MeetingCardStore.write(card, in: saveDir)
        return card
    }

    /// For custom kinds, runs the per-card mention scan if this card hasn't
    /// been scanned for `kind` yet. People needs no scan (participants).
    private func ensureMentionScan(
        card: MeetingCard,
        kind: IndexKind,
        continuation: AsyncThrowingStream<IndexBuildEvent, Error>.Continuation?
    ) async -> MeetingCard {
        guard kind != .people, !card.scannedKinds.contains(kind.rawValue) else { return card }
        let spec = kind.spec
        var updated = card
        do {
            var digest = card
            digest.quotes = []  // keep the scan input small
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let cardJSON = String(data: (try? encoder.encode(digest)) ?? Data(), encoding: .utf8) ?? "{}"

            let object = try await llm.completeJSONObject(
                system: LocalWikiPrompts.mentionScanSystem(spec: spec),
                user: LocalWikiPrompts.mentionScanUser(cardDigest: cardJSON)
            )
            let found = MeetingCardJSON.mentions(object["mentions"], defaultKind: kind.rawValue)
            let existingNames = Set(updated.mentions.filter { $0.kind == kind.rawValue }.map { WikiEntityResolver.normalize($0.name) })
            for mention in found where !existingNames.contains(WikiEntityResolver.normalize(mention.name)) {
                updated.mentions.append(mention)
            }
            updated.scannedKinds.append(kind.rawValue)
            try? MeetingCardStore.write(updated, in: saveDir)
        } catch {
            continuation?.yield(.status("Mention scan failed for \(card.meetingPath): \(error.localizedDescription)"))
        }
        return updated
    }

    // MARK: - Entity grouping (resolve stage)

    struct EntityGroup {
        var canonicalName: String
        var aliases: Set<String>
        var meetingPaths: Set<String>
        var contexts: [String]
    }

    /// Walks cards chronologically, resolving each name against the existing
    /// entries plus everything grouped so far. Deterministic rules first;
    /// one multiple-choice LLM call only for genuine ambiguity.
    private func groupEntities(kind: IndexKind, cards: [MeetingCard]) async -> [EntityGroup] {
        var snapshot = IndexManifest.aliasSnapshot(in: saveDir, kind: kind)
        var groups: [String: EntityGroup] = [:]

        // Seed groups from names already on disk so their pages accumulate.
        for (canonical, aliases) in snapshot {
            groups[canonical] = EntityGroup(
                canonicalName: canonical,
                aliases: Set(aliases),
                meetingPaths: [],
                contexts: []
            )
        }

        for card in cards.sorted(by: { $0.meetingPath < $1.meetingPath }) {
            for rawName in card.entityNames(forKind: kind.rawValue) {
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.count >= 2 else { continue }

                let canonical: String
                switch WikiEntityResolver.resolve(name: name, snapshot: snapshot) {
                case .matched(let match):
                    canonical = match
                case .new:
                    canonical = name
                case .ambiguous(let candidates):
                    canonical = await adjudicate(name: name, context: card.title, candidates: candidates) ?? name
                }

                var group = groups[canonical] ?? EntityGroup(
                    canonicalName: canonical,
                    aliases: [],
                    meetingPaths: [],
                    contexts: []
                )
                if WikiEntityResolver.normalize(name) != WikiEntityResolver.normalize(canonical) {
                    group.aliases.insert(name)
                }
                group.meetingPaths.insert(card.meetingPath)
                groups[canonical] = group

                var aliases = snapshot[canonical] ?? []
                if canonical != name, !aliases.contains(name) { aliases.append(name) }
                snapshot[canonical] = aliases
            }
        }

        return groups.values.filter { !$0.meetingPaths.isEmpty }
    }

    /// Multiple-choice disambiguation — the one judgment format small models
    /// handle reliably. Returns nil for "someone new / can't tell".
    private func adjudicate(name: String, context: String, candidates: [String]) async -> String? {
        do {
            let object = try await llm.completeJSONObject(
                system: LocalWikiPrompts.adjudicationSystem,
                user: LocalWikiPrompts.adjudicationUser(name: name, context: context, candidates: candidates)
            )
            let answer = MeetingCardJSON.string(object["answer"]).uppercased()
            let letters = ["A", "B", "C", "D", "E", "F"]
            guard let index = letters.firstIndex(of: answer), index < candidates.count else {
                return nil  // "someone new" or unparseable → conservative: don't merge
            }
            return candidates[index]
        } catch {
            return nil
        }
    }

    // MARK: - Pages (reduce stage)

    private struct NarrativeState: Codable {
        var sections: [String: String]
        var atMeetingCount: Int
        var model: String
        var promptHash: String
        var generatedAt: Date
    }

    private func narrativeURL(kind: IndexKind, slug: String) -> URL {
        MarkdownArchivePaths.indexRoot(in: saveDir, kind: kind)
            .appendingPathComponent("_narratives", isDirectory: true)
            .appendingPathComponent("\(slug).json")
    }

    /// Writes (or rewrites) one entity's dossier. Returns the slug.
    private func updateEntityPage(kind: IndexKind, group: EntityGroup, cards: [MeetingCard]) async throws -> String {
        let slug = MarkdownArchivePaths.slugForIndexEntry(group.canonicalName)
        let entryURL = MarkdownArchivePaths.entryURL(in: saveDir, kind: kind, slug: slug)
        let existing = try? IndexEntryFile.read(from: entryURL)

        let entityCards = cards
            .filter { group.meetingPaths.contains($0.meetingPath) }
            .sorted { $0.meetingPath < $1.meetingPath }
        let meetingCount = entityCards.count

        // Narrative: regenerate from the card set when missing or stale.
        let narrativeFile = narrativeURL(kind: kind, slug: slug)
        var narrative = Self.loadNarrative(at: narrativeFile)
        let promptHash = IndexBuilder.hashPrompt(LocalWikiPrompts.narrativeSystem(section: .overview, spec: kind.spec))
        let needsNarrative = narrative == nil
            || narrative!.promptHash != promptHash
            || meetingCount - narrative!.atMeetingCount >= Self.narrativeRefreshInterval
        if needsNarrative {
            let digest = Self.cardsDigest(entityCards, subjectName: group.canonicalName)
            var sections: [String: String] = [:]
            for section in LocalWikiPrompts.NarrativeSection.allCases {
                if Task.isCancelled { throw CancellationError() }
                let text = try await llm.complete(
                    system: LocalWikiPrompts.narrativeSystem(section: section, spec: kind.spec),
                    user: LocalWikiPrompts.narrativeUser(canonicalName: group.canonicalName, spec: kind.spec, cardsDigest: digest)
                )
                sections[section.rawValue] = text
            }
            narrative = NarrativeState(
                sections: sections,
                atMeetingCount: meetingCount,
                model: modelKind.rawValue,
                promptHash: promptHash,
                generatedAt: Date()
            )
            Self.saveNarrative(narrative!, at: narrativeFile)
        }

        // Assemble the body: narrative sections + deterministic Timeline + Mentions.
        var body = ""
        for section in LocalWikiPrompts.NarrativeSection.allCases {
            let text = (narrative?.sections[section.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != "(none)" else { continue }
            body += "## \(section.rawValue)\n\n\(text)\n\n"
        }
        body += "## Timeline\n\n"
        for card in entityCards {
            body += "- \(card.date) — **\(card.title)** — \(card.meetingPath)\n"
        }
        body += "\n## Mentions\n\n"
        for card in entityCards {
            body += "- In `\(card.meetingPath)`: \(card.oneLineSummary)\n"
        }

        var aliases = Set(existing?.aliases ?? [])
        aliases.formUnion(group.aliases)
        var sourceMeetings = Set(existing?.sourceMeetings ?? [])
        sourceMeetings.formUnion(group.meetingPaths)

        let entry = IndexEntry(
            kind: kind,
            canonicalName: existing?.canonicalName ?? group.canonicalName,
            aliases: aliases.sorted(),
            sourceMeetings: sourceMeetings.sorted(),
            lastUpdated: Date(),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            generation: GenerationMetadata(
                model: modelDisplayName,
                promptKind: "local-wiki-page",
                promptHash: promptHash,
                generatedAt: Date()
            )
        )
        try IndexEntryFile.write(entry, to: entryURL)
        NotificationCenter.default.post(name: .indexEntryWritten, object: kind)
        return slug
    }

    /// Compact chronological digest of an entity's cards for the narrative
    /// prompts. Capped so even a 100-meeting relationship fits a 32K window.
    static func cardsDigest(_ cards: [MeetingCard], subjectName: String? = nil, maxChars: Int = 9000) -> String {
        var out = ""
        let subjectNeedle = subjectName.map { WikiEntityResolver.normalize($0) }
        for card in cards {
            var block = "### \(card.date) — \(card.title) (\(card.meetingPath))\n"
            if !card.summary.isEmpty { block += "Summary: \(card.summary)\n" }
            let participantContext = card.participants
                .filter { participant in
                    guard let subjectNeedle else { return false }
                    return WikiEntityResolver.normalize(participant.name) == subjectNeedle
                }
                .map { participant in
                    var bits: [String] = []
                    if !participant.role.isEmpty { bits.append(participant.role) }
                    if !participant.affiliation.isEmpty { bits.append(participant.affiliation) }
                    return bits.isEmpty ? "\(participant.name) was listed as a participant" : "\(participant.name) (\(bits.joined(separator: "; ")))"
                }
            if !participantContext.isEmpty { block += "Participant context: \(participantContext.joined(separator: "; "))\n" }
            let peopleContext = card.mentionedPeople
                .filter { person in
                    guard !person.context.isEmpty || !person.possibleRole.isEmpty else { return false }
                    guard let subjectNeedle else { return true }
                    return WikiEntityResolver.normalize(person.name) == subjectNeedle
                }
                .prefix(subjectNeedle == nil ? 12 : 4)
                .map { person in
                    var bits: [String] = []
                    if !person.context.isEmpty { bits.append(person.context) }
                    if !person.possibleRole.isEmpty { bits.append("possible role: \(person.possibleRole)") }
                    return "\(person.name) (\(bits.joined(separator: "; ")))"
                }
            if !peopleContext.isEmpty { block += "Mentioned-person context: \(peopleContext.joined(separator: "; "))\n" }
            if !card.decisions.isEmpty { block += "Decisions: \(card.decisions.joined(separator: "; "))\n" }
            if !card.openThreads.isEmpty { block += "Open threads: \(card.openThreads.joined(separator: "; "))\n" }
            for quote in card.quotes.prefix(2) {
                block += "Quote (line \(quote.line)): \"\(quote.text)\"\n"
            }
            block += "\n"
            out += block
        }
        if out.count > maxChars {
            // Keep the most recent material: trim from the front on a block boundary.
            let overflow = out.count - maxChars
            let trimmed = String(out.dropFirst(overflow))
            if let boundary = trimmed.range(of: "### ") {
                out = "(earlier meetings omitted)\n\n" + String(trimmed[boundary.lowerBound...])
            } else {
                out = String(trimmed)
            }
        }
        return out
    }

    private static func loadNarrative(at url: URL) -> NarrativeState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(NarrativeState.self, from: data)
    }

    private static func saveNarrative(_ state: NarrativeState, at url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Helpers

    static func extractTitle(from lines: [String]) -> String? {
        for line in lines.prefix(30) {
            if line.hasPrefix("title:") {
                let raw = line.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
                let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !unquoted.isEmpty { return unquoted }
            }
            if line.hasPrefix("# ") {
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Date string for timeline rows: frontmatter `date:` (first 10 chars)
    /// or the meeting's YYYY-MM-DD folder name.
    static func extractDate(from lines: [String], meetingPath: String) -> String {
        for line in lines.prefix(15) where line.hasPrefix("date:") {
            let raw = line.dropFirst("date:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if raw.count >= 10 { return String(raw.prefix(10)) }
        }
        if let folder = meetingPath.split(separator: "/").first, folder.count == 10 {
            return String(folder)
        }
        return ""
    }

    private static func relativePath(of url: URL, in saveDir: URL) -> String? {
        let fullPath = url.standardizedFileURL.path
        let rootPath = saveDir.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard fullPath.hasPrefix(prefix) else { return nil }
        return String(fullPath.dropFirst(prefix.count))
    }
}
