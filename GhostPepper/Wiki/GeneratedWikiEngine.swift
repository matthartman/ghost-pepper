import Foundation

struct GeneratedWikiPage: Identifiable, Equatable {
    var id: String { url.path }
    var url: URL
    var title: String
    var type: String
    var pageID: String?
    var entityID: String?
    var sourceMeetingPath: String?
    var body: String
    var updatedAt: Date?
    var userEdited: Bool = false
    var pendingGeneratedUpdate: Bool = false
}

struct GeneratedWikiResult: Equatable {
    var overviewURL: URL
    var touchedURLs: [URL]
    var gitMessage: String
    var usage: QAUsage
}

struct GeneratedWikiReviewEntityDraft: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var type: String
    var category: String
    var description: String
    var context: String
    var sourceSnippet: String
    var confidence: String
    var suggestedMatches: [String]
    var suggestedMatchReasons: [String: String]
    var mergeOptions: [String]
    var mergeOptionsByType: [String: [String]]
    var defaultCanonicalName: String?
    var resolutionLabel: String
}

struct GeneratedWikiReviewClaimDraft: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var sourceContext: String
    var relatedTopics: [String]
    var relatedEntities: [String]
    var confidence: String
    var indexCandidate: Bool
    var indexReason: String
    var suggestedCanonicalClaim: String?
    var suggestedMatches: [String]
    var suggestedMatchReasons: [String: String]
    var mergeOptions: [String]
}

struct GeneratedWikiReviewTopicDraft: Identifiable, Equatable {
    var id = UUID()
    var topic: String
    var description: String
    var indexCandidate: Bool
    var indexReason: String
    var suggestedCanonicalTopic: String?
    var relatedEntities: [String]
    var mergeOptions: [String]
    var suggestedMatches: [String]
    var suggestedMatchReasons: [String: String]
}

struct GeneratedWikiReviewDraft: Identifiable, Equatable {
    var id = UUID()
    var meetingTitle: String
    var meetingPath: String
    var entities: [GeneratedWikiReviewEntityDraft]
    var topics: [GeneratedWikiReviewTopicDraft]
    var claims: [GeneratedWikiReviewClaimDraft]

    var claimCount: Int {
        claims.count
    }

    var entityReviewCount: Int {
        entities.filter { $0.defaultCanonicalName == nil || !$0.suggestedMatches.isEmpty }.count
    }
}

struct GeneratedWikiEntityReviewDecision: Equatable {
    var keep: Bool
    var canonicalName: String?
    var proposedName: String?
    var type: String?
}

struct GeneratedWikiTopicReviewDecision: Equatable {
    var keep: Bool
    var canonicalTopic: String?
    var topic: String?
}

struct GeneratedWikiClaimReviewDecision: Equatable {
    var keep: Bool
    var canonicalClaim: String?
    var text: String?
}

struct GeneratedWikiReviewDecision: Equatable {
    var entityDecisions: [UUID: GeneratedWikiEntityReviewDecision]
    var topicDecisions: [UUID: GeneratedWikiTopicReviewDecision]
    var claimDecisions: [UUID: GeneratedWikiClaimReviewDecision]

    static func keepAll(for draft: GeneratedWikiReviewDraft) -> GeneratedWikiReviewDecision {
        GeneratedWikiReviewDecision(
            entityDecisions: Dictionary(
                uniqueKeysWithValues: draft.entities.map {
                    ($0.id, GeneratedWikiEntityReviewDecision(keep: true, canonicalName: $0.defaultCanonicalName, proposedName: $0.name, type: $0.type))
                }
            ),
            topicDecisions: Dictionary(
                uniqueKeysWithValues: draft.topics.map {
                    ($0.id, GeneratedWikiTopicReviewDecision(keep: true, canonicalTopic: $0.indexCandidate ? ($0.suggestedCanonicalTopic ?? $0.suggestedMatches.first ?? $0.topic) : nil, topic: $0.topic))
                }
            ),
            claimDecisions: Dictionary(
                uniqueKeysWithValues: draft.claims.map {
                    ($0.id, GeneratedWikiClaimReviewDecision(
                        keep: true,
                        canonicalClaim: $0.indexCandidate ? ($0.suggestedCanonicalClaim ?? $0.suggestedMatches.first ?? $0.text) : nil,
                        text: $0.text
                    ))
                }
            )
        )
    }

    static func discardAll(for draft: GeneratedWikiReviewDraft) -> GeneratedWikiReviewDecision {
        GeneratedWikiReviewDecision(
            entityDecisions: Dictionary(
                uniqueKeysWithValues: draft.entities.map {
                    ($0.id, GeneratedWikiEntityReviewDecision(keep: false, canonicalName: nil, proposedName: $0.name, type: $0.type))
                }
            ),
            topicDecisions: Dictionary(
                uniqueKeysWithValues: draft.topics.map {
                    ($0.id, GeneratedWikiTopicReviewDecision(keep: false, canonicalTopic: nil, topic: $0.topic))
                }
            ),
            claimDecisions: Dictionary(
                uniqueKeysWithValues: draft.claims.map {
                    ($0.id, GeneratedWikiClaimReviewDecision(keep: false, canonicalClaim: nil, text: $0.text))
                }
            )
        )
    }
}

enum GeneratedWikiProgress {
    case status(String)
    case modelStatus(String)
    case functionStarted(name: String, system: String, user: String)
    case token(String)
    case functionFinished(name: String, output: String, inputTokens: Int, outputTokens: Int)
    case saved(URL)
}

enum GeneratedWikiPaths {
    static let rootFolderName = "wikis"

    static func root(in archiveRoot: URL) -> URL {
        archiveRoot.appendingPathComponent(rootFolderName, isDirectory: true)
    }

    static func pageURL(in archiveRoot: URL, category: String, name: String) -> URL {
        root(in: archiveRoot)
            .appendingPathComponent(category, isDirectory: true)
            .appendingPathComponent("\(MarkdownArchivePaths.slugForIndexEntry(name)).md")
    }

    static func meetingOverviewURL(in archiveRoot: URL, meetingPath: String, title: String) -> URL {
        meetingOverviewURL(in: archiveRoot, meetingPath: meetingPath)
    }

    static func meetingOverviewURL(in archiveRoot: URL, meetingPath: String) -> URL {
        let datedSlug = meetingPath
            .replacingOccurrences(of: "/", with: "--")
            .replacingOccurrences(of: ".md", with: "")
        let slug = MarkdownArchivePaths.slugForIndexEntry(datedSlug)
        return root(in: archiveRoot)
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("\(slug).md")
    }

    static func readPage(from url: URL) throws -> GeneratedWikiPage {
        let text = try String(contentsOf: url, encoding: .utf8)
        return parsePage(text, url: url)
    }

    static func parsePage(_ text: String, url: URL) -> GeneratedWikiPage {
        var frontmatter: [String: String] = [:]
        var body = text
        if text.hasPrefix("---\n"),
           let close = text.dropFirst(4).range(of: "\n---\n") {
            let fm = String(text.dropFirst(4)[..<close.lowerBound])
            body = String(text[close.upperBound...])
            for line in fm.split(separator: "\n").map(String.init) {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon])
                let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                frontmatter[key] = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        let title = body.split(separator: "\n")
            .first(where: { $0.hasPrefix("# ") })
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? frontmatter["name"]
            ?? url.deletingPathExtension().lastPathComponent
        let updatedAt = frontmatter["updated_at"].flatMap { ISO8601DateFormatter().date(from: $0) }
        return GeneratedWikiPage(
            url: url,
            title: title,
            type: frontmatter["type"] ?? "wiki_page",
            pageID: frontmatter["page_id"],
            entityID: frontmatter["entity_id"],
            sourceMeetingPath: frontmatter["source_meeting_path"],
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            updatedAt: updatedAt,
            userEdited: frontmatter["user_edited"] == "true",
            pendingGeneratedUpdate: frontmatter["pending_generated_update"] == "true"
        )
    }

    static func findPage(in archiveRoot: URL, slug: String) -> URL? {
        let root = root(in: archiveRoot)
        for category in ["people", "companies", "concepts", "meetings"] {
            let url = root.appendingPathComponent(category, isDirectory: true).appendingPathComponent("\(slug).md")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

@MainActor
final class GeneratedWikiEngine {
    private static let generationSchemaVersion = "2nd-brain.v2"
    private static let meetingIntelligencePromptName = "Extract meeting intelligence"
    private static let meetingIntelligencePromptVersion = "2026-07-16.entities-topics-claims.v8"
    private static let meetingIntelligencePromptFingerprint = """
    entities: people/companies/concepts with descriptions roles relationships context
    topics: concrete meeting-local bullets with nested claim strings
    claims: generated as meeting-local claims and elevated only when index_candidate is yes
    safeguards: person-company title typing, concrete product/topic descriptions, no generic topic prose
    """

    private let cleanupManager: TextCleanupManager
    private let archiveRoot: URL
    private let modelKind: LocalCleanupModelKind
    private let llm: LocalStructuredLLM

    init(cleanupManager: TextCleanupManager, archiveRoot: URL, modelKind: LocalCleanupModelKind) {
        self.cleanupManager = cleanupManager
        self.archiveRoot = archiveRoot
        self.modelKind = modelKind
        self.llm = LocalStructuredLLM(cleanupManager: cleanupManager, modelKind: modelKind)
    }

    func generate(
        for meetingURL: URL,
        onProgress: @MainActor @escaping (GeneratedWikiProgress) -> Void = { _ in },
        review: (@MainActor (GeneratedWikiReviewDraft) async -> GeneratedWikiReviewDecision)? = nil
    ) async throws -> GeneratedWikiResult {
        guard let meetingPath = Self.relativePath(of: meetingURL, in: archiveRoot) else {
            throw NSError(domain: "GeneratedWikiEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Meeting is outside the archive root."])
        }

        var totalInputTokens = 0
        var totalOutputTokens = 0

        onProgress(.status("Reading source meeting"))
        let meetingText = try String(contentsOf: meetingURL, encoding: .utf8)
        let lines = meetingText.components(separatedBy: "\n")
        let title = LocalWikiEngine.extractTitle(from: lines) ?? meetingURL.deletingPathExtension().lastPathComponent
        let date = LocalWikiEngine.extractDate(from: lines, meetingPath: meetingPath)

        onProgress(.status("Extracting meeting intelligence"))
        let intelligence = try await extractMeetingIntelligence(title: title, meetingText: meetingText, onProgress: onProgress)
        totalInputTokens += intelligence.inputTokens
        totalOutputTokens += intelligence.outputTokens

        var entities = intelligence.entities
        var topics = intelligence.topics
        var claims = intelligence.claims
        if let review {
            onProgress(.status("Reviewing extracted entities, topics, and claims"))
            let draft = makeReviewDraft(title: title, meetingPath: meetingPath, meetingText: meetingText, entities: entities, topics: topics, claims: claims)
            let decision = await review(draft)
            try Task.checkCancellation()
            recordFilingDecisions(draft: draft, decision: decision)
            let reviewed = applyReview(decision, toEntities: entities, topics: topics, claims: claims, draft: draft)
            entities = reviewed.entities
            topics = reviewed.topics
            claims = reviewed.claims
        }

        onProgress(.status("Writing 2nd Brain pages"))
        try ensureWikiRoot()
        entities = entities.map { canonicalizedEntity($0) }
        let connectorTopics = connectorTopicNames(for: topics, currentMeetingPath: meetingPath)
        var touched: [URL] = []
        let overview = try writeMeetingOverview(
            title: title,
            date: date,
            meetingPath: meetingPath,
            entities: entities,
            topics: topics,
            claims: claims,
            connectorTopicNames: connectorTopics
        )
        touched.append(overview)
        onProgress(.saved(overview))
        for entity in entities {
            let url = try writeEntityPage(entity, meetingTitle: title, meetingOverviewTitle: title, meetingPath: meetingPath)
            touched.append(url)
            onProgress(.saved(url))
        }
        for topic in topics where connectorTopics.contains(WikiEntityResolver.normalize(topic.topic)) {
            let url = try writeTopicPage(topic, meetingTitle: title, meetingOverviewTitle: title, meetingPath: meetingPath)
            touched.append(url)
            onProgress(.saved(url))
        }
        for claim in claims where claim.indexCandidate {
            let url = try writeClaimPage(claim, meetingTitle: title, meetingOverviewTitle: title, meetingPath: meetingPath)
            touched.append(url)
            onProgress(.saved(url))
        }

        onProgress(.status("Saving Git history"))
        let gitMessage = commitWiki(touched: touched, title: title)
        return GeneratedWikiResult(
            overviewURL: overview,
            touchedURLs: uniqueURLs(touched),
            gitMessage: gitMessage,
            usage: .local(
                modelDisplayName: AgentBackend.local(modelKind).shortDisplayName + " (local)",
                inputTokens: totalInputTokens,
                outputTokens: totalOutputTokens
            )
        )
    }

    private struct Entity: Hashable {
        var name: String
        var type: String
        var description: String
        var roles: [String]
        var relationships: [String]
        var context: String
        var confidence: String

        var category: String {
            switch type.lowercased() {
            case "person", "people": return "people"
            case "company", "companies": return "companies"
            default: return "concepts"
            }
        }

        var pageType: String {
            switch category {
            case "people": return "person"
            case "companies": return "company"
            default: return "concept"
            }
        }
    }

    private static func normalizedEntityType(_ rawType: String) -> String {
        switch rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "person", "people":
            return "Person"
        case "company", "companies", "organization", "organisation", "fund", "firm", "institution", "product":
            return "Company"
        case "concept", "topic", "idea":
            return "Concept"
        default:
            return rawType
        }
    }

    private struct Topic: Hashable {
        var topic: String
        var description: String
        var indexCandidate: Bool
        var indexReason: String
        var suggestedCanonicalTopic: String?
        var relatedEntities: [String]
    }

    private struct Claim: Hashable {
        var text: String
        var sourceContext: String
        var relatedTopics: [String]
        var relatedEntities: [String]
        var confidence: String
        var indexCandidate: Bool
        var indexReason: String
        var suggestedCanonicalClaim: String?
    }

    private func makeReviewDraft(title: String, meetingPath: String, meetingText: String, entities: [Entity], topics: [Topic], claims: [Claim]) -> GeneratedWikiReviewDraft {
        let entityDrafts = entities.map { entity -> GeneratedWikiReviewEntityDraft in
            let snapshot = existingNameSnapshot(category: entity.category)
            let resolution = WikiEntityResolver.resolve(name: entity.name, snapshot: snapshot)
            let suggestedMatches: [String]
            let suggestedMatchReasons: [String: String]
            let defaultCanonicalName: String?
            let label: String
            switch resolution {
            case .matched(let canonical):
                suggestedMatches = [canonical]
                suggestedMatchReasons = [canonical: matchReason(rawName: entity.name, canonical: canonical, aliases: snapshot[canonical] ?? [])]
                defaultCanonicalName = canonical
                label = "existing match"
            case .ambiguous(let candidates):
                suggestedMatches = candidates
                suggestedMatchReasons = Dictionary(uniqueKeysWithValues: candidates.map {
                    ($0, matchReason(rawName: entity.name, canonical: $0, aliases: snapshot[$0] ?? []))
                })
                defaultCanonicalName = nil
                label = "similar entities found"
            case .new:
                let nearest = nearestExistingNameCandidates(to: entity.name, category: entity.category, limit: 3)
                suggestedMatches = nearest.map(\.name)
                suggestedMatchReasons = Dictionary(uniqueKeysWithValues: nearest.map { ($0.name, $0.reason) })
                defaultCanonicalName = nil
                label = suggestedMatches.isEmpty ? "new entity" : "possible duplicate"
            }
            let mergeOptions = existingNameSnapshot(category: entity.category).keys.sorted()

            return GeneratedWikiReviewEntityDraft(
                name: entity.name,
                type: entity.type,
                category: entity.category,
                description: entity.description,
                context: entity.context,
                sourceSnippet: sourceSnippet(for: entity, in: meetingText),
                confidence: entity.confidence,
                suggestedMatches: suggestedMatches,
                suggestedMatchReasons: suggestedMatchReasons,
                mergeOptions: mergeOptions,
                mergeOptionsByType: [
                    "Person": existingNameSnapshot(category: "people").keys.sorted(),
                    "Company": existingNameSnapshot(category: "companies").keys.sorted(),
                    "Concept": existingNameSnapshot(category: "concepts").keys.sorted()
                ],
                defaultCanonicalName: defaultCanonicalName,
                resolutionLabel: label
            )
        }

        let topicOptions = existingNameSnapshot(category: "topics").keys.sorted()
        let topicDrafts = topics.map { topic in
            let nearest = nearestExistingNameCandidates(to: topic.topic, category: "topics", limit: 3)
            let modelSuggestion = topic.suggestedCanonicalTopic?.trimmingCharacters(in: .whitespacesAndNewlines)
            let suggestedMatches = ([modelSuggestion].compactMap { $0 } + nearest.map(\.name))
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .uniqued(by: { WikiEntityResolver.normalize($0) })
            var suggestedReasons = Dictionary(uniqueKeysWithValues: nearest.map { ($0.name, $0.reason) })
            if let modelSuggestion, !modelSuggestion.isEmpty {
                suggestedReasons[modelSuggestion] = topic.indexReason.isEmpty
                    ? "Suggested by the extraction model as the canonical topic."
                    : topic.indexReason
            }
            return GeneratedWikiReviewTopicDraft(
                topic: topic.topic,
                description: topic.description,
                indexCandidate: topic.indexCandidate,
                indexReason: topic.indexReason,
                suggestedCanonicalTopic: modelSuggestion,
                relatedEntities: topic.relatedEntities,
                mergeOptions: topicOptions,
                suggestedMatches: suggestedMatches,
                suggestedMatchReasons: suggestedReasons
            )
        }
        let claimOptions = existingNameSnapshot(category: "claims").keys.sorted()
        let claimDrafts = claims.map { claim in
            let nearest = nearestExistingNameCandidates(to: claim.text, category: "claims", limit: 3)
            let modelSuggestion = claim.suggestedCanonicalClaim?.trimmingCharacters(in: .whitespacesAndNewlines)
            let suggestedMatches = ([modelSuggestion].compactMap { $0 } + nearest.map(\.name))
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .uniqued(by: { WikiEntityResolver.normalize($0) })
            var suggestedReasons = Dictionary(uniqueKeysWithValues: nearest.map { ($0.name, $0.reason) })
            if let modelSuggestion, !modelSuggestion.isEmpty {
                suggestedReasons[modelSuggestion] = claim.indexReason.isEmpty
                    ? "Suggested by the extraction model as the canonical claim."
                    : claim.indexReason
            }
            return GeneratedWikiReviewClaimDraft(
                text: claim.text,
                sourceContext: claim.sourceContext,
                relatedTopics: claim.relatedTopics,
                relatedEntities: claim.relatedEntities,
                confidence: claim.confidence,
                indexCandidate: claim.indexCandidate,
                indexReason: claim.indexReason,
                suggestedCanonicalClaim: modelSuggestion,
                suggestedMatches: suggestedMatches,
                suggestedMatchReasons: suggestedReasons,
                mergeOptions: claimOptions
            )
        }

        return GeneratedWikiReviewDraft(
            meetingTitle: title,
            meetingPath: meetingPath,
            entities: entityDrafts,
            topics: topicDrafts,
            claims: claimDrafts
        )
    }

    private func sourceSnippet(for entity: Entity, in meetingText: String) -> String {
        let name = entity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }

        let normalizedName = WikiEntityResolver.normalize(name)
        let nameTokens = normalizedName.split(separator: " ").map(String.init)
        guard !nameTokens.isEmpty else { return "" }

        let lines = meetingText.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, lineMentionsEntity(trimmed, normalizedName: normalizedName, nameTokens: nameTokens) else {
                continue
            }

            var contextLines: [String] = []
            if index > 0 {
                let previous = lines[index - 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if shouldIncludeAdjacentSourceLine(previous) {
                    contextLines.append(clippedSourceLine(previous, around: nameTokens))
                }
            }
            contextLines.append(clippedSourceLine(trimmed, around: nameTokens))
            if index + 1 < lines.count {
                let next = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if contextLines.joined(separator: " ").count < 360, shouldIncludeAdjacentSourceLine(next) {
                    contextLines.append(clippedSourceLine(next, around: nameTokens))
                }
            }
            return contextLines.joined(separator: "\n")
        }

        return ""
    }

    private func lineMentionsEntity(_ line: String, normalizedName: String, nameTokens: [String]) -> Bool {
        let normalizedLine = WikiEntityResolver.normalize(line)
        if nameTokens.count == 1 {
            return normalizedLine
                .split(separator: " ")
                .contains { $0 == nameTokens[0] }
        }
        return normalizedLine.contains(normalizedName)
    }

    private func shouldIncludeAdjacentSourceLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        if line.hasPrefix("---") || line.hasPrefix("title:") || line.hasPrefix("date:") {
            return false
        }
        return true
    }

    private func clippedSourceLine(_ line: String, around nameTokens: [String], limit: Int = 520) -> String {
        guard line.count > limit else { return line }

        let lowercased = line.lowercased()
        let matchIndex = nameTokens.compactMap { token -> String.Index? in
            lowercased.range(of: token.lowercased())?.lowerBound
        }.min()
        guard let matchIndex else {
            return String(line.prefix(limit - 1)) + "..."
        }

        let halfWindow = max(80, limit / 2)
        let start = line.index(matchIndex, offsetBy: -halfWindow, limitedBy: line.startIndex) ?? line.startIndex
        let end = line.index(matchIndex, offsetBy: halfWindow, limitedBy: line.endIndex) ?? line.endIndex
        let prefix = start == line.startIndex ? "" : "..."
        let suffix = end == line.endIndex ? "" : "..."
        return prefix + String(line[start..<end]) + suffix
    }

    private func applyReview(
        _ decision: GeneratedWikiReviewDecision,
        toEntities entities: [Entity],
        topics: [Topic],
        claims: [Claim],
        draft: GeneratedWikiReviewDraft
    ) -> (entities: [Entity], topics: [Topic], claims: [Claim]) {
        var reviewedEntities: [Entity] = []
        for (entity, entityDraft) in zip(entities, draft.entities) {
            let entityDecision = decision.entityDecisions[entityDraft.id]
                ?? GeneratedWikiEntityReviewDecision(keep: true, canonicalName: entityDraft.defaultCanonicalName, proposedName: entityDraft.name, type: entityDraft.type)
            guard entityDecision.keep else { continue }
            var updated = entity
            if let canonical = entityDecision.canonicalName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !canonical.isEmpty {
                updated.name = canonical
            } else if let proposed = entityDecision.proposedName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !proposed.isEmpty {
                updated.name = proposed
            }
            if let type = entityDecision.type?.trimmingCharacters(in: .whitespacesAndNewlines),
               !type.isEmpty {
                updated.type = Self.normalizedEntityType(type)
            }
            reviewedEntities.append(updated)
        }

        var reviewedTopics: [Topic] = []
        for (topic, topicDraft) in zip(topics, draft.topics) {
            let topicDecision = decision.topicDecisions[topicDraft.id]
                ?? GeneratedWikiTopicReviewDecision(keep: true, canonicalTopic: topic.indexCandidate ? topic.topic : nil, topic: topic.topic)
            guard topicDecision.keep else { continue }
            var updated = topic
            if let reviewedTitle = topicDecision.topic?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reviewedTitle.isEmpty {
                updated.topic = reviewedTitle
            }
            if let canonical = topicDecision.canonicalTopic?.trimmingCharacters(in: .whitespacesAndNewlines),
               !canonical.isEmpty {
                updated.topic = canonical
                updated.indexCandidate = true
                if updated.indexReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    updated.indexReason = "Connected during 2nd Brain review."
                }
            } else {
                updated.indexCandidate = false
            }
            guard !updated.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !updated.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            reviewedTopics.append(updated)
        }

        var reviewedClaims: [Claim] = []
        for (claim, claimDraft) in zip(claims, draft.claims) {
            let claimDecision = decision.claimDecisions[claimDraft.id]
                ?? GeneratedWikiClaimReviewDecision(
                    keep: true,
                    canonicalClaim: claimDraft.indexCandidate ? (claimDraft.suggestedCanonicalClaim ?? claimDraft.suggestedMatches.first ?? claimDraft.text) : nil,
                    text: claimDraft.text
                )
            guard claimDecision.keep else { continue }
            let reviewedText = claimDecision.canonicalClaim?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? claimDecision.canonicalClaim!.trimmingCharacters(in: .whitespacesAndNewlines)
                : (claimDecision.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                   ? claimDecision.text!.trimmingCharacters(in: .whitespacesAndNewlines)
                   : claim.text)
            guard !reviewedText.isEmpty else { continue }
            var updated = claim
            updated.text = reviewedText
            updated.indexCandidate = claimDecision.canonicalClaim?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            if updated.indexCandidate, updated.indexReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.indexReason = "Connected during 2nd Brain review."
            }
            reviewedClaims.append(updated)
        }

        return (reviewedEntities, reviewedTopics, reviewedClaims.uniqued(by: { WikiEntityResolver.normalize($0.text) }))
    }

    private func recordFilingDecisions(draft: GeneratedWikiReviewDraft, decision: GeneratedWikiReviewDecision) {
        for entity in draft.entities {
            let final = decision.entityDecisions[entity.id]
                ?? GeneratedWikiEntityReviewDecision(keep: true, canonicalName: entity.defaultCanonicalName, proposedName: entity.name, type: entity.type)
            let proposedAction = entity.defaultCanonicalName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? "merge_existing_entity"
                : "add_entity"
            let finalAction: String
            if !final.keep {
                finalAction = "discard_entity"
            } else if final.canonicalName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                finalAction = "merge_existing_entity"
            } else {
                finalAction = "add_entity"
            }
            recordFilingDecision(
                meetingPath: draft.meetingPath,
                meetingTitle: draft.meetingTitle,
                itemKind: "entity",
                proposedAction: proposedAction,
                finalAction: finalAction,
                itemName: entity.name,
                metadata: [
                    "draft_id": entity.id.uuidString,
                    "entity_name": entity.name,
                    "entity_type_suggested": entity.type,
                    "entity_type_final": final.type ?? entity.type,
                    "entity_category": entity.category,
                    "entity_description": entity.description,
                    "entity_context": entity.context,
                    "confidence": entity.confidence,
                    "resolution_label": entity.resolutionLabel,
                    "suggested_canonical_name": entity.defaultCanonicalName ?? "",
                    "final_canonical_name": final.canonicalName ?? "",
                    "final_proposed_name": final.proposedName ?? entity.name,
                    "suggested_matches": Self.jsonString(entity.suggestedMatches),
                    "suggested_match_reasons": Self.jsonString(entity.suggestedMatchReasons)
                ]
            )
        }

        for topic in draft.topics {
            let final = decision.topicDecisions[topic.id]
                ?? GeneratedWikiTopicReviewDecision(keep: true, canonicalTopic: topic.indexCandidate ? (topic.suggestedCanonicalTopic ?? topic.suggestedMatches.first ?? topic.topic) : nil, topic: topic.topic)
            let proposedAction = proposedTopicAction(topic)
            let finalAction = finalTopicAction(topic: topic, decision: final)
            recordFilingDecision(
                meetingPath: draft.meetingPath,
                meetingTitle: draft.meetingTitle,
                itemKind: "topic",
                proposedAction: proposedAction,
                finalAction: finalAction,
                itemName: topic.topic,
                metadata: [
                    "draft_id": topic.id.uuidString,
                    "topic": topic.topic,
                    "final_topic": final.topic ?? topic.topic,
                    "description": topic.description,
                    "index_candidate_suggested": topic.indexCandidate ? "true" : "false",
                    "index_reason": topic.indexReason,
                    "suggested_canonical_topic": topic.suggestedCanonicalTopic ?? "",
                    "final_canonical_topic": final.canonicalTopic ?? "",
                    "related_entities": Self.jsonString(topic.relatedEntities),
                    "suggested_matches": Self.jsonString(topic.suggestedMatches),
                    "suggested_match_reasons": Self.jsonString(topic.suggestedMatchReasons)
                ]
            )
        }

        for claim in draft.claims {
            let final = decision.claimDecisions[claim.id]
                ?? GeneratedWikiClaimReviewDecision(
                    keep: true,
                    canonicalClaim: claim.indexCandidate ? (claim.suggestedCanonicalClaim ?? claim.suggestedMatches.first ?? claim.text) : nil,
                    text: claim.text
                )
            let proposedAction = claim.indexCandidate
                ? (claim.suggestedMatches.isEmpty ? "add_claim_index" : "connect_claim_index")
                : "just_this_meeting"
            let finalAction: String
            if !final.keep {
                finalAction = "discard_claim"
            } else if final.canonicalClaim?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                finalAction = claim.mergeOptions.contains(where: { WikiEntityResolver.normalize($0) == WikiEntityResolver.normalize(final.canonicalClaim ?? "") })
                    ? "connect_existing_claim"
                    : "add_claim_index"
            } else {
                finalAction = "just_this_meeting"
            }
            recordFilingDecision(
                meetingPath: draft.meetingPath,
                meetingTitle: draft.meetingTitle,
                itemKind: "claim",
                proposedAction: proposedAction,
                finalAction: finalAction,
                itemName: String(claim.text.prefix(96)),
                metadata: [
                    "draft_id": claim.id.uuidString,
                    "claim_text_suggested": claim.text,
                    "claim_text_final": final.text ?? claim.text,
                    "source_context": claim.sourceContext,
                    "confidence": claim.confidence,
                    "index_candidate_suggested": claim.indexCandidate ? "true" : "false",
                    "index_reason": claim.indexReason,
                    "final_canonical_claim": final.canonicalClaim ?? "",
                    "related_topics": Self.jsonString(claim.relatedTopics),
                    "related_entities": Self.jsonString(claim.relatedEntities),
                    "suggested_matches": Self.jsonString(claim.suggestedMatches),
                    "suggested_match_reasons": Self.jsonString(claim.suggestedMatchReasons)
                ]
            )
        }
    }

    private func recordFilingDecision(
        meetingPath: String,
        meetingTitle: String,
        itemKind: String,
        proposedAction: String,
        finalAction: String,
        itemName: String,
        metadata: [String: String]
    ) {
        var eventMetadata = historyMetadata(
            type: "filing_decision",
            name: itemName,
            extra: [
                "meeting_title": meetingTitle,
                "source_meeting_path": meetingPath,
                "item_kind": itemKind,
                "proposed_action": proposedAction,
                "final_action": finalAction,
                "changed_by_user": proposedAction == finalAction ? "false" : "true"
            ]
        )
        for (key, value) in metadata {
            eventMetadata[key] = value
        }
        GhostPepperHistoryStore.recordEvent(
            archiveRoot: archiveRoot,
            actor: .user,
            operation: "file_2nd_brain_item",
            summary: "Filed \(itemKind) '\(itemName)' as \(finalAction).",
            relativePath: meetingPath,
            metadata: eventMetadata
        )
    }

    private func proposedTopicAction(_ topic: GeneratedWikiReviewTopicDraft) -> String {
        guard topic.indexCandidate else { return "just_this_meeting" }
        let suggested = topic.suggestedCanonicalTopic?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let suggested, !suggested.isEmpty else { return "add_topic_index" }
        return topic.mergeOptions.contains(where: { WikiEntityResolver.normalize($0) == WikiEntityResolver.normalize(suggested) })
            ? "connect_existing_topic"
            : "add_topic_index"
    }

    private func finalTopicAction(topic: GeneratedWikiReviewTopicDraft, decision: GeneratedWikiTopicReviewDecision) -> String {
        guard decision.keep else { return "discard_topic" }
        guard let canonical = decision.canonicalTopic?.trimmingCharacters(in: .whitespacesAndNewlines),
              !canonical.isEmpty else {
            return "just_this_meeting"
        }
        return topic.mergeOptions.contains(where: { WikiEntityResolver.normalize($0) == WikiEntityResolver.normalize(canonical) })
            ? "connect_existing_topic"
            : "add_topic_index"
    }

    private func extractMeetingIntelligence(
        title: String,
        meetingText: String,
        onProgress: @MainActor @escaping (GeneratedWikiProgress) -> Void
    ) async throws -> (entities: [Entity], topics: [Topic], claims: [Claim], inputTokens: Int, outputTokens: Int) {
        let system = """
        /no_think
        You create structured 2nd Brain meeting intelligence. Output only valid JSON. Do not explain. Do not include markdown. Do not include thinking text.

        Extract meeting-local topics with claims, plus entities, from the same meeting text in one pass.

        Entity types:
        - Person: named human beings
        - Company: companies, funds, firms, institutions, products, named organizations
        - Concept: named reusable ideas, market categories, strategies, memes, trends, or important phrases that may deserve a durable page

        Topics are meeting-local outline bullets: what was discussed in this meeting, with one sentence of context. Topics are not automatically durable wiki entities.
        Claims are atomic, debatable, source-grounded statements that could recur across meetings.
        """
        func makeUserPrompt(meetingText: String) -> String {
            let existingTopics = existingNameSnapshot(category: "topics").keys.sorted()
            let existingTopicText = existingTopics.isEmpty
                ? "(none yet)"
                : existingTopics.prefix(120).map { "- \($0)" }.joined(separator: "\n")
            let existingClaims = existingNameSnapshot(category: "claims").keys.sorted()
            let existingClaimText = existingClaims.isEmpty
                ? "(none yet)"
                : existingClaims.prefix(120).map { "- \($0)" }.joined(separator: "\n")
            return """
        Return one JSON object with exactly these top-level keys: "topics", "claims", and "entities".
        Produce topics first. Do not omit topics when the meeting has a Summary section.

        {
          "topics": [
            {
              "topic": "",
              "description": "",
              "claims": ["", ""],
              "related_entities": [""],
              "index_candidate": "yes|no",
              "suggested_canonical_topic": "",
              "index_reason": ""
            }
          ],
          "claims": [
            {
              "claim": "",
              "source_context": "",
              "related_topics": [""],
              "related_entities": [""],
              "confidence": "low|medium|high",
              "index_candidate": "yes|no",
              "suggested_canonical_claim": "",
              "index_reason": ""
            }
          ],
          "entities": [
            {
              "entity_name": "",
              "entity_type": "Person|Company|Concept",
              "one_sentence_description": "",
              "roles": [""],
              "relationships": [""],
              "relevant_context": "",
              "confidence": "low|medium|high"
            }
          ]
        }

        Rules:
        Entity rules:
        - Prefer canonical/full names. Before emitting an entity, look for the fullest supported name in frontmatter, title, attendee metadata, summary, notes, transcript, and embedded import JSON. Use "Benjamin Zenou" instead of "Benjamin" when the fuller name appears anywhere in the meeting text.
        - Avoid first-name-only Person entities unless no fuller name is available anywhere in the meeting text. If only a first name is available, keep entity_type as Person and say what is unknown in relevant_context.
        - If a title uses a nickname or shortened form but metadata contains a fuller attendee name, use the metadata name as entity_name.
        - Include meeting participants from the title as Person entities only when the title side is a human name.
        - If a meeting-title participant side contains two likely human names joined by "and", "&", comma, or "/", emit them as separate Person entities. Never emit a combined person name like "Alex Example and Jordan Example".
        - In titles like "Person <> Company", type the organization side as Company, not Person.
        - Do not label a single-word capitalized organization as Person solely because it appears in the title.
        - Classify the real-world thing, not the title fragment. A founder, CEO, investor, partner, or operator is a Person even when associated with a company or product. A product, startup, fund, firm, institution, or website is a Company.
        - Never classify a named human as Company because their company appears near their name. Example: "Benjamin from Suits.ai" means Benjamin is Person and Suits.ai is Company.
        - For shorthand title fragments like "Ben, Suits", create separate entities only when supported: the human as Person using the fullest available name, and Suits.ai/Suits as Company if the product/company is discussed.
        - Include entities from the summary and transcript.
        - Include concepts like "SaaS apocalypse", "physical AI", and similar named reusable ideas only when they are distinctive enough to become durable 2nd Brain pages.
        - one_sentence_description is required for every Person, Company, and Concept. It should be one durable sentence suitable for that entity's wiki page.
        - For people, include role, affiliation, or what they are known for only when supported by the text.
        - roles should capture supported durable roles/types, especially fund-ecosystem roles such as "LP", "fund investor", "VC", "founder", "operator", "manager", "allocator", "candidate", or "advisor".
        - relationships should capture supported graph-like facts as short evidence-backed phrases, such as "LP in funds", "works at Fundora", "introduced by X", "invests in Y", or "discussed with Z". Include the evidence phrase in the relationship text when possible.
        - For companies, describe what the company/fund/institution/product is or why it mattered in the meeting.
        - For concepts, define the theme or idea in the meeting's own context.
        - Relevant context should be one concrete sentence about how the entity came up.
        - confidence is about whether this entity should become or update a durable 2nd Brain page: high for full-name metadata/title/transcript support, medium for clear mentions with some uncertainty, low for first-name-only, acronym-only, or weak context.
        - If a role or relationship is only implied, include "possible:" in the string, e.g. "possible: LP / fund investor".
        - Do not include generic words unless they are discussed as a theme.
        - Do not invent entities.

        Topic rules:
        - Extract 4-8 major topics discussed in the meeting.
        - A topic should be a concise title plus a single-sentence description for the meeting overview.
        - The description must say what the thing is, what was said about it, or what decision/question was attached to it.
        - Never write generic descriptions like "Overview of product features discussed in the meeting", "Mentioned as a feature", "Discussion of fundraising", or "Talked about AI".
        - If the topic is "Product", the description must identify the product or category and the concrete capability, workflow, or user problem discussed.
        - If the source text is too thin to describe the topic concretely, either omit that topic or write the specific limitation, e.g. "The meeting title identifies Factorial, but the transcript excerpt does not describe the product."
        - Treat topics as meeting-outline sections, not as requests to create concept/entity pages.
        - Do not make topics a list of people or companies.
        - Do not duplicate durable Concept entities unless the meeting also uses that concept as a major discussion thread.
        - Include people/companies only in related_entities when they help explain the topic.
        - index_candidate should be "yes" only when the topic is broad/reusable enough to connect multiple meetings, such as "Series A Fundraising", "Local AI", or "Fund Strategy".
        - index_candidate should be "no" for one-off agenda items, logistics, or topics too specific to this single call.
        - When index_candidate is "yes", compare the topic to the existing topic index below.
        - If it should merge with an existing topic, put that exact existing topic name in suggested_canonical_topic.
        - If it is reusable but not a match for any existing topic, put the best canonical name for the new topic in suggested_canonical_topic.
        - If index_candidate is "no", leave suggested_canonical_topic as an empty string.
        - index_reason should briefly explain why the topic is reusable, new, or a merge with the suggested canonical topic.
        - Bad topic: {"topic":"Product","description":"Overview of product features discussed in the meeting."}
        - Better topic: {"topic":"Product","description":"Factorial's product was discussed as a speech-to-text workflow for turning conversations into structured notes."}
        - Bad topic: {"topic":"Speech to text","description":"Mentioned as a feature in the summary."}
        - Better topic: {"topic":"Speech to text","description":"Speech-to-text came up as the product capability used to capture spoken meetings and convert them into written meeting intelligence."}
        - claims should be 1-3 specific takeaways, opinions, predictions, arguments, or judgments for that topic.
        - Each claim should be a complete sentence, not a label.
        - Do not turn every fact into a claim. Prefer claims someone could agree or disagree with.
        - Good claim examples: "Local AI models are still too slow for high-quality meeting intelligence." or "Large multi-stage firms are aggressively capturing the AI opportunity."
        - Also include the best claims in the top-level "claims" array with index_candidate metadata.
        - Claim index_candidate should be "yes" only when the claim is durable, reusable, and likely to recur across meetings, or when it clearly updates/contradicts an existing claim.
        - Claim index_candidate should be "no" for one-off facts, meeting-specific observations, personal preferences, logistics, or claims too thin to track globally.
        - When claim index_candidate is "yes", compare it to the existing claim index below.
        - If it should merge with an existing claim, put that exact existing claim in suggested_canonical_claim.
        - If it is reusable but not a match for any existing claim, put the best canonical wording for the new claim in suggested_canonical_claim.
        - If claim index_candidate is "no", leave suggested_canonical_claim as an empty string.
        - Claim index_reason should briefly explain why the claim is reusable, new, or a merge with the suggested canonical claim.
        - Use the Summary section when present, then use the transcript for additional nuance.
        - Preserve distinctive phrases from the meeting.
        - Output only the JSON object.

        Existing topic index:
        \(existingTopicText)

        Existing claim index:
        \(existingClaimText)

        Meeting text:
        \(meetingText)
        """
        }
        let user = makeUserPrompt(meetingText: meetingText)
        onProgress(.functionStarted(name: "Extract meeting intelligence", system: system, user: user))
        var result = try await llm.completeJSONObjectWithTrace(
            system: system,
            user: user,
            onToken: { token in
                onProgress(.token(token))
            },
            onStatus: { status in
                onProgress(.modelStatus(status))
            }
        )
        var inputTokens = result.trace.estimatedInputTokens
        var outputTokens = result.trace.estimatedOutputTokens
        var traceOutput = result.trace.text

        if Self.isEmptyMeetingIntelligenceObject(result.object) {
            onProgress(.modelStatus("Empty extraction; retrying with compact source view"))
            let compactMeetingText = Self.compactMeetingTextForIntelligence(meetingText)
            if compactMeetingText != meetingText {
                let retryUser = makeUserPrompt(meetingText: compactMeetingText)
                if let retry = try? await llm.completeJSONObjectWithTrace(
                    system: system,
                    user: retryUser,
                    onToken: { token in
                        onProgress(.token(token))
                    },
                    onStatus: { status in
                        onProgress(.modelStatus(status))
                    }
                ) {
                    inputTokens += retry.trace.estimatedInputTokens
                    outputTokens += retry.trace.estimatedOutputTokens
                    traceOutput += "\n\n--- Compact source retry ---\n\n\(retry.trace.text)"
                    if !Self.isEmptyMeetingIntelligenceObject(retry.object) {
                        result = retry
                    }
                }
            }
        }

        var deterministicFallback: (entities: [Entity], topics: [Topic], claims: [Claim])?
        if Self.isEmptyMeetingIntelligenceObject(result.object) {
            onProgress(.modelStatus("Empty model extraction; using title and summary fallback"))
            deterministicFallback = fallbackMeetingIntelligence(title: title, meetingText: meetingText)
            traceOutput += "\n\n--- Deterministic fallback from title and summary ---\n"
            traceOutput += "entities: \(deterministicFallback?.entities.count ?? 0), topics: \(deterministicFallback?.topics.count ?? 0), claims: \(deterministicFallback?.claims.count ?? 0)"
        }

        onProgress(.functionFinished(
            name: "Extract meeting intelligence",
            output: traceOutput,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        ))
        if let deterministicFallback {
            return (deterministicFallback.entities, deterministicFallback.topics, deterministicFallback.claims, inputTokens, outputTokens)
        }
        let entityItems = result.object["entities"] as? [[String: Any]] ?? []
        var entities: [Entity] = entityItems.compactMap { (item: [String: Any]) -> Entity? in
            let name = MeetingCardJSON.string(item["entity_name"] ?? item["Entity Name"])
            guard !name.isEmpty else { return nil }
            let rawType = MeetingCardJSON.string(item["entity_type"] ?? item["Entity Type"])
            let extractedType = rawType.isEmpty ? "Concept" : rawType
            return Entity(
                name: name,
                type: correctedEntityType(
                    extractedType,
                    name: name,
                    description: MeetingCardJSON.string(item["one_sentence_description"] ?? item["description"] ?? item["Description"]),
                    context: MeetingCardJSON.string(item["relevant_context"] ?? item["Relevant Context"])
                ),
                description: MeetingCardJSON.string(item["one_sentence_description"] ?? item["description"] ?? item["Description"]),
                roles: MeetingCardJSON.stringList(item["roles"] ?? item["Roles"]),
                relationships: MeetingCardJSON.stringList(item["relationships"] ?? item["Relationships"]),
                context: MeetingCardJSON.string(item["relevant_context"] ?? item["Relevant Context"]),
                confidence: MeetingCardJSON.string(item["confidence"] ?? item["Confidence"])
            )
        }
        .flatMap(splitCompoundPersonEntity)
        .uniqued(by: { WikiEntityResolver.normalize($0.name) + "|" + $0.category })
        let topicItems = result.object["topics"] as? [[String: Any]]
            ?? result.object["topics_discussed"] as? [[String: Any]]
            ?? result.object["Topics Discussed"] as? [[String: Any]]
            ?? []
        var topics: [Topic] = topicItems.compactMap { (item: [String: Any]) -> Topic? in
            let topic = MeetingCardJSON.string(item["topic"] ?? item["Topic"])
            guard !topic.isEmpty else { return nil }
            let indexCandidateText = MeetingCardJSON.string(item["index_candidate"] ?? item["Index Candidate"]).lowercased()
            return Topic(
                topic: topic,
                description: MeetingCardJSON.string(item["description"] ?? item["Topic Description"]),
                indexCandidate: ["yes", "true", "1"].contains(indexCandidateText),
                indexReason: MeetingCardJSON.string(item["index_reason"] ?? item["Index Reason"]),
                suggestedCanonicalTopic: MeetingCardJSON.string(item["suggested_canonical_topic"] ?? item["Suggested Canonical Topic"] ?? item["canonical_topic"] ?? item["Canonical Topic"]),
                relatedEntities: MeetingCardJSON.stringList(item["related_entities"] ?? item["Related Entities"])
            )
        }.uniqued(by: { WikiEntityResolver.normalize($0.topic) })
        if topics.isEmpty {
            topics = fallbackTopics(fromSummary: Self.markdownSection(named: "Summary", in: meetingText))
        }
        let claimItems = result.object["claims"] as? [[String: Any]]
            ?? result.object["Claims"] as? [[String: Any]]
            ?? result.object["insights"] as? [[String: Any]]
            ?? result.object["Insights"] as? [[String: Any]]
            ?? []
        var claims: [Claim] = claimItems.compactMap { (item: [String: Any]) -> Claim? in
            let text = MeetingCardJSON.string(item["claim"] ?? item["Claim"])
            guard !text.isEmpty else { return nil }
            let indexCandidateText = MeetingCardJSON.string(item["index_candidate"] ?? item["Index Candidate"]).lowercased()
            return Claim(
                text: text,
                sourceContext: MeetingCardJSON.string(item["source_context"] ?? item["Source Context"]),
                relatedTopics: MeetingCardJSON.stringList(item["related_topics"] ?? item["Related Topics"]),
                relatedEntities: MeetingCardJSON.stringList(item["related_entities"] ?? item["Related Entities"]),
                confidence: MeetingCardJSON.string(item["confidence"] ?? item["Confidence"]),
                indexCandidate: ["yes", "true", "1"].contains(indexCandidateText),
                indexReason: MeetingCardJSON.string(item["index_reason"] ?? item["Index Reason"]),
                suggestedCanonicalClaim: MeetingCardJSON.string(item["suggested_canonical_claim"] ?? item["Suggested Canonical Claim"] ?? item["canonical_claim"] ?? item["Canonical Claim"])
            )
        }
        if claims.isEmpty {
            claims = topicItems.flatMap { item -> [Claim] in
                let topic = MeetingCardJSON.string(item["topic"] ?? item["Topic"])
                return MeetingCardJSON.stringList(item["claims"] ?? item["Claims"] ?? item["insights"] ?? item["Insights"]).map {
                    Claim(
                        text: $0,
                        sourceContext: topic,
                        relatedTopics: topic.isEmpty ? [] : [topic],
                        relatedEntities: MeetingCardJSON.stringList(item["related_entities"] ?? item["Related Entities"]),
                        confidence: "medium",
                        indexCandidate: false,
                        indexReason: "",
                        suggestedCanonicalClaim: nil
                    )
                }
            }
        }
        if claims.isEmpty {
            claims = fallbackClaims(
                fromSummary: Self.markdownSection(named: "Summary", in: meetingText),
                topics: topics,
                entities: entities
            )
        }
        claims = claims.uniqued(by: { WikiEntityResolver.normalize($0.text) })
        return (entities, topics, claims, inputTokens, outputTokens)
    }

    private static func isEmptyMeetingIntelligenceObject(_ object: [String: Any]) -> Bool {
        let entities = object["entities"] as? [Any] ?? []
        let topics = object["topics"] as? [Any] ?? []
        let claims = object["claims"] as? [Any] ?? []
        return entities.isEmpty && topics.isEmpty && claims.isEmpty
    }

    private static func compactMeetingTextForIntelligence(_ meetingText: String) -> String {
        let lines = meetingText.components(separatedBy: "\n")
        let title = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ") }) ?? ""
        let date = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("**Date:**") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("date:") }) ?? ""
        let notes = markdownSection(named: "Notes", in: meetingText)
        let summary = markdownSection(named: "Summary", in: meetingText)
        let transcript = markdownSection(named: "Transcript", in: meetingText)
        let transcriptLines = transcript.components(separatedBy: "\n")
        let transcriptExcerpt = transcriptLines.prefix(140).joined(separator: "\n")

        var compact = [title, date].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            compact += "\n\n## Notes\n\(notes)"
        }
        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            compact += "\n\n## Summary\n\(summary)"
        }
        if !transcriptExcerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            compact += "\n\n## Transcript excerpt\n\(transcriptExcerpt)"
        }
        let trimmed = compact.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(meetingText.prefix(20000))
        }
        return trimmed
    }

    private static func markdownSection(named sectionName: String, in markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        let heading = "## \(sectionName)"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }) else {
            return ""
        }
        var collected: [String] = []
        for line in lines.dropFirst(start + 1) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("## ") {
                break
            }
            collected.append(line)
        }
        return collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fallbackMeetingIntelligence(title: String, meetingText: String) -> (entities: [Entity], topics: [Topic], claims: [Claim]) {
        let entities = fallbackEntities(fromTitle: title)
        let summary = Self.markdownSection(named: "Summary", in: meetingText)
        let topics = fallbackTopics(fromSummary: summary)
        let claims = fallbackClaims(fromSummary: summary, topics: topics, entities: entities)
        return (entities, topics, claims)
    }

    private func fallbackEntities(fromTitle title: String) -> [Entity] {
        let cleanedTitle = title.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = cleanedTitle.components(separatedBy: "<>").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return pieces.compactMap { rawName -> Entity? in
            guard !rawName.isEmpty else { return nil }
            let name = rawName.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            let type = correctedEntityType(
                organizationNameSignals(in: name) ? "Company" : "Person",
                name: name,
                description: "Participant or organization identified by the meeting title.",
                context: "Identified from the meeting title."
            )
            return Entity(
                name: name,
                type: type,
                description: "\(name) was identified from the meeting title.",
                roles: [],
                relationships: [],
                context: "Identified from the meeting title.",
                confidence: name.contains(" ") ? "medium" : "low"
            )
        }
        .uniqued(by: { WikiEntityResolver.normalize($0.name) + "|" + $0.category })
    }

    private func fallbackTopics(fromSummary summary: String) -> [Topic] {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let lines = summary.components(separatedBy: "\n")
        var topics: [Topic] = []
        var currentHeading: String?
        var currentBullets: [String] = []

        func flush() {
            guard let heading = currentHeading?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !heading.isEmpty else { return }
            let description = currentBullets.first(where: { !$0.isEmpty && !Self.isClaimLikeSummaryBullet($0) }) ??
                currentBullets.first(where: { !$0.isEmpty }).map(Self.descriptionFromClaimLikeSummaryBullet) ??
                "The source summary discusses \(heading)."
            topics.append(Topic(
                topic: heading,
                description: description,
                indexCandidate: false,
                indexReason: "Created from the source summary because the model returned an empty extraction.",
                suggestedCanonicalTopic: nil,
                relatedEntities: []
            ))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("### ") {
                flush()
                currentHeading = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentBullets = []
            } else if trimmed.hasPrefix("-") {
                let bullet = trimmed
                    .replacingOccurrences(of: #"^\-\s+"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !bullet.isEmpty {
                    currentBullets.append(bullet)
                }
            }
        }
        flush()

        if topics.isEmpty {
            let bullets = lines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.hasPrefix("-") }
                .prefix(6)
            topics = bullets.map { bullet in
                let description = bullet
                    .replacingOccurrences(of: #"^\-\s+"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Topic(topic: String(description.prefix(60)), description: description, indexCandidate: false, indexReason: "Created from source summary fallback.", suggestedCanonicalTopic: nil, relatedEntities: [])
            }
        }

        return topics.uniqued(by: { WikiEntityResolver.normalize($0.topic) })
    }

    private func fallbackClaims(fromSummary summary: String, topics: [Topic], entities: [Entity]) -> [Claim] {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let topicTitles = topics.map(\.topic)
        let entityNames = entities.map(\.name)
        let signalWords = [
            "risk", "concern", "question", "prediction", "predict", "expects", "expected",
            "likely", "unlikely", "should", "could", "would", "harder", "easier",
            "different", "key", "appeal", "moat", "fastest", "best", "rare", "strong",
            "weak", "bullish", "excited", "worry", "thesis", "framed", "view"
        ]
        var currentTopic = ""
        var claims: [Claim] = []

        for rawLine in summary.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("### ") {
                currentTopic = line.replacingOccurrences(of: #"^#+\s+"#, with: "", options: .regularExpression)
                continue
            }
            guard line.hasPrefix("-") else { continue }
            let cleaned = Self.cleanSummaryBullet(line)
            guard cleaned.count >= 24 else { continue }
            let lowered = cleaned.lowercased()
            guard Self.isClaimLikeSummaryBullet(cleaned) || signalWords.contains(where: { lowered.contains($0) }) else { continue }
            guard !lowered.hasPrefix("ping "),
                  !lowered.hasPrefix("reach out"),
                  !lowered.hasPrefix("connect with"),
                  !lowered.hasPrefix("text "),
                  !lowered.hasPrefix("sync with") else {
                continue
            }

            let relatedTopic = topicTitles.first(where: { topic in
                WikiEntityResolver.normalize(currentTopic).contains(WikiEntityResolver.normalize(topic)) ||
                WikiEntityResolver.normalize(topic).contains(WikiEntityResolver.normalize(currentTopic))
            }) ?? currentTopic
            let relatedEntities = entityNames.filter { name in
                lowered.contains(name.lowercased())
            }
            var claimText = Self.claimText(fromSummaryBullet: cleaned)
            if !claimText.hasSuffix(".") && !claimText.hasSuffix("?") && !claimText.hasSuffix("!") {
                claimText += "."
            }
            claims.append(Claim(
                text: claimText,
                sourceContext: currentTopic.isEmpty ? "Summary bullet" : currentTopic,
                relatedTopics: relatedTopic.isEmpty ? [] : [relatedTopic],
                relatedEntities: relatedEntities,
                confidence: "medium",
                indexCandidate: false,
                indexReason: "",
                suggestedCanonicalClaim: nil
            ))
            if claims.count >= 8 { break }
        }

        return claims.uniqued(by: { WikiEntityResolver.normalize($0.text) })
    }

    private static func isClaimLikeSummaryBullet(_ bullet: String) -> Bool {
        let lowered = cleanSummaryBullet(bullet).lowercased()
        let prefixes = [
            "core thesis:",
            "thesis:",
            "key thesis:",
            "takeaway:",
            "key takeaway:",
            "view:",
            "point of view:",
            "argument:",
            "claim:"
        ]
        return prefixes.contains(where: { lowered.hasPrefix($0) })
    }

    private static func claimText(fromSummaryBullet bullet: String) -> String {
        cleanSummaryBullet(bullet)
            .replacingOccurrences(of: #"(?i)^(core thesis|key thesis|thesis|key takeaway|takeaway|point of view|view|argument|claim):\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func descriptionFromClaimLikeSummaryBullet(_ bullet: String) -> String {
        claimText(fromSummaryBullet: bullet)
    }

    private static func cleanSummaryBullet(_ line: String) -> String {
        line
            .replacingOccurrences(of: #"^\-\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\*\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\*\*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func organizationNameSignals(in name: String) -> Bool {
        let lowered = name.lowercased()
        let signals = [" inc", " llc", " capital", " ventures", " partners", " fund", " labs", " ai", " co", " company", " studio", " studios", " media"]
        return signals.contains(where: { lowered.contains($0) })
    }

    private func correctedEntityType(_ rawType: String, name: String, description: String, context: String) -> String {
        let normalizedType = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedName = WikiEntityResolver.normalize(name)
        guard !normalizedName.isEmpty else { return rawType.isEmpty ? "Concept" : rawType }

        if let existing = existingEntityMatch(for: name) {
            return Self.displayEntityType(forCategory: existing.category)
        }

        if normalizedType == "person" || normalizedType == "people" {
            if existingNameSnapshot(category: "companies").keys.contains(where: { WikiEntityResolver.normalize($0) == normalizedName }) {
                return "Company"
            }
            if existingNameSnapshot(category: "concepts").keys.contains(where: { WikiEntityResolver.normalize($0) == normalizedName }) {
                return "Concept"
            }
            let evidence = "\(name) \(description) \(context)".lowercased()
            let companySignals = [
                "company", "firm", "fund", "institution", "product", "platform",
                "startup", "organization", "capital", "ventures", "labs", "ai"
            ]
            if name.split(separator: " ").count == 1,
               companySignals.contains(where: { evidence.contains($0) }) {
                return "Company"
            }
        }

        switch normalizedType {
        case "person", "people":
            return "Person"
        case "company", "companies", "organization", "organisation", "fund", "firm", "product":
            return "Company"
        case "concept", "concepts":
            return "Concept"
        default:
            return rawType.isEmpty ? "Concept" : rawType
        }
    }

    private func splitCompoundPersonEntity(_ entity: Entity) -> [Entity] {
        guard entity.category == "people" else { return [entity] }
        let normalized = WikiEntityResolver.normalize(entity.name)
        guard normalized.contains(" and ") || normalized.contains(" & ") else { return [entity] }

        let pieces = entity.name
            .replacingOccurrences(of: " & ", with: " and ")
            .components(separatedBy: " and ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard pieces.count == 2,
              pieces.allSatisfy({ piece in
                  let tokenCount = piece.split(separator: " ").count
                  return tokenCount >= 2 && tokenCount <= 4 && !organizationNameSignals(in: piece)
              }) else {
            return [entity]
        }

        return pieces.map { name in
            var split = entity
            split.name = name
            split.description = entity.description
                .replacingOccurrences(of: entity.name, with: name)
            split.context = entity.context.isEmpty
                ? "Split from combined meeting-title participant '\(entity.name)'."
                : entity.context.replacingOccurrences(of: entity.name, with: name)
            split.confidence = entity.confidence.isEmpty ? "medium" : entity.confidence
            return split
        }
    }

    private func existingEntityMatch(for rawName: String) -> (category: String, canonical: String)? {
        let normalized = WikiEntityResolver.normalize(rawName)
        guard !normalized.isEmpty else { return nil }

        var matches: [(category: String, canonical: String)] = []
        for category in ["people", "companies", "concepts"] {
            let snapshot = existingNameSnapshot(category: category)
            switch WikiEntityResolver.resolve(name: rawName, snapshot: snapshot) {
            case .matched(let canonical):
                matches.append((category, canonical))
            case .ambiguous, .new:
                continue
            }
        }

        if matches.count == 1 {
            return matches[0]
        }

        let exactMatches = matches.filter { match in
            WikiEntityResolver.normalize(match.canonical) == normalized ||
            (existingNameSnapshot(category: match.category)[match.canonical] ?? []).contains {
                WikiEntityResolver.normalize($0) == normalized
            }
        }
        return exactMatches.count == 1 ? exactMatches[0] : nil
    }

    private static func displayEntityType(forCategory category: String) -> String {
        switch category {
        case "people": return "Person"
        case "companies": return "Company"
        default: return "Concept"
        }
    }

    private func ensureWikiRoot() throws {
        let root = GeneratedWikiPaths.root(in: archiveRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for dir in ["meetings", "people", "companies", "concepts", "topics", "claims", ".wiki"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir, isDirectory: true), withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
            _ = runGit(["init"], in: root)
            _ = runGit(["config", "user.name", "GhostPepper Wiki"], in: root)
            _ = runGit(["config", "user.email", "wiki@ghostpepper.local"], in: root)
        }
    }

    private func writeMeetingOverview(
        title: String,
        date: String,
        meetingPath: String,
        entities: [Entity],
        topics: [Topic],
        claims: [Claim],
        connectorTopicNames: Set<String>
    ) throws -> URL {
        let url = GeneratedWikiPaths.meetingOverviewURL(in: archiveRoot, meetingPath: meetingPath, title: title)
        var body = "# \(title)\n\n"
        body += "> Generated meeting overview. Source of truth: `\(meetingPath)`.\n\n"
        body += "## Topics Discussed\n\n"
        body += topics.isEmpty ? "(none)\n\n" : topics.map { topic in
            let topicTitle = connectorTopicNames.contains(WikiEntityResolver.normalize(topic.topic))
                ? "[[\(topic.topic)]]"
                : "**\(topic.topic)**"
            return "- \(topicTitle) — \(topic.description)"
        }.joined(separator: "\n") + "\n\n"
        body += "## Entities\n\n"
        body += entities.isEmpty ? "(none)\n\n" : entities.map { entity in
            let roleText = entity.roles.isEmpty ? "" : "; roles: \(entity.roles.joined(separator: ", "))"
            return "- [[\(entity.name)]] — \(entity.type)\(roleText); \(entity.context)"
        }.joined(separator: "\n") + "\n\n"
        body += "## Claims\n\n"
        body += claims.isEmpty ? "(none)\n" : claims.map { claim in
            let claimText = claim.indexCandidate ? "[[\(claim.text)]]" : claim.text
            if let topic = claim.relatedTopics.first, !topic.isEmpty {
                let topicText = connectorTopicNames.contains(WikiEntityResolver.normalize(topic))
                    ? "[[\(topic)]]"
                    : topic
                return "- **\(topicText):** \(claimText)"
            }
            return "- \(claimText)"
        }.joined(separator: "\n") + "\n"
        try writePage(url: url, type: "meeting_overview", name: title, extraFrontmatter: [
            "source_meeting_path": meetingPath,
            "meeting_date": date
        ], body: body)
        return url
    }

    private func writeEntityPage(_ entity: Entity, meetingTitle: String, meetingOverviewTitle: String, meetingPath: String) throws -> URL {
        let canonicalName = canonicalName(for: entity.name, category: entity.category) ?? entity.name
        let url = GeneratedWikiPaths.pageURL(in: archiveRoot, category: entity.category, name: canonicalName)
        var observations = existingBullets(in: url, section: "Observations")
        observations.insert("- [[\(meetingOverviewTitle)]] — \(entity.context.isEmpty ? "Discussed in \(meetingTitle)." : entity.context)")
        var roles = existingBullets(in: url, section: "Roles")
        for role in entity.roles {
            roles.insert("- \(role)")
        }
        var relationships = existingBullets(in: url, section: "Relationships")
        for relationship in entity.relationships {
            relationships.insert("- [[\(meetingOverviewTitle)]] — \(relationship)")
        }
        var discussed = existingBullets(in: url, section: "Discussed In")
        discussed.insert("- [[\(meetingOverviewTitle)]]")
        let summary = evolvingSummary(
            existing: existingSection(in: url, section: "Summary"),
            extracted: entity.description,
            fallback: "\(canonicalName) was discussed in relation to [[\(meetingOverviewTitle)]].",
            entityName: canonicalName
        )

        var body = "# \(canonicalName)\n\n"
        body += "## Summary\n\n"
        body += summary + "\n"
        var aliases = existingBullets(in: url, section: "Aliases")
        if canonicalName != entity.name {
            aliases.insert("- \(entity.name)")
        }
        if !aliases.isEmpty {
            body += "\n## Aliases\n\n\(aliases.sorted().joined(separator: "\n"))\n"
        }
        body += "\n## Roles\n\n\(roles.isEmpty ? "(none)" : roles.sorted().joined(separator: "\n"))\n\n"
        body += "## Relationships\n\n\(relationships.isEmpty ? "(none)" : relationships.sorted().joined(separator: "\n"))\n\n"
        body += "\n## Observations\n\n\(observations.sorted().joined(separator: "\n"))\n\n"
        body += "## Discussed In\n\n\(discussed.sorted().joined(separator: "\n"))\n\n"
        body += "## Source Meetings\n\n"
        var sources = existingBullets(in: url, section: "Source Meetings")
        sources.insert("- `\(meetingPath)`")
        body += sources.sorted().joined(separator: "\n") + "\n"
        try writePage(url: url, type: entity.pageType, name: canonicalName, extraFrontmatter: [
            "description": summary,
            "roles": entity.roles.joined(separator: ", ")
        ], body: body)
        return url
    }

    private func writeTopicPage(_ topic: Topic, meetingTitle: String, meetingOverviewTitle: String, meetingPath: String) throws -> URL {
        let canonicalTopic = canonicalName(for: topic.topic, category: "topics") ?? topic.topic
        let url = GeneratedWikiPaths.pageURL(in: archiveRoot, category: "topics", name: canonicalTopic)
        let priorOccurrences = existingMeetingOccurrences(forTopic: topic.topic, excludingMeetingPath: meetingPath)
        var related = existingBullets(in: url, section: "Related Entities")
        for entity in topic.relatedEntities where !entity.isEmpty {
            related.insert("- [[\(entity)]]")
        }
        var discussed = existingBullets(in: url, section: "Discussed In")
        discussed.insert("- [[\(meetingOverviewTitle)]]")
        for occurrence in priorOccurrences {
            discussed.insert("- [[\(occurrence.title)]]")
        }

        var body = "# \(canonicalTopic)\n\n"
        body += "## Summary\n\n"
        body += topic.description.isEmpty ? (existingSection(in: url, section: "Summary") ?? "\(canonicalTopic) was discussed in [[\(meetingOverviewTitle)]].\n") : topic.description + "\n"
        if !topic.indexReason.isEmpty {
            body += "\n## Index Reason\n\n\(topic.indexReason)\n"
        }
        var aliases = existingBullets(in: url, section: "Aliases")
        if canonicalTopic != topic.topic {
            aliases.insert("- \(topic.topic)")
        }
        if !aliases.isEmpty {
            body += "\n## Aliases\n\n\(aliases.sorted().joined(separator: "\n"))\n"
        }
        body += "\n## Related Entities\n\n\(related.isEmpty ? "(none)" : related.sorted().joined(separator: "\n"))\n\n"
        body += "## Discussed In\n\n\(discussed.sorted().joined(separator: "\n"))\n\n"
        body += "## Source Meetings\n\n"
        var sources = existingBullets(in: url, section: "Source Meetings")
        sources.insert("- `\(meetingPath)`")
        for occurrence in priorOccurrences {
            sources.insert("- `\(occurrence.meetingPath)`")
        }
        body += sources.sorted().joined(separator: "\n") + "\n"
        try writePage(url: url, type: "topic", name: topic.topic, extraFrontmatter: [:], body: body)
        return url
    }

    private func writeClaimPage(_ claim: Claim, meetingTitle: String, meetingOverviewTitle: String, meetingPath: String) throws -> URL {
        let canonicalClaim = canonicalName(for: claim.text, category: "claims") ?? claim.text
        let url = GeneratedWikiPaths.pageURL(in: archiveRoot, category: "claims", name: canonicalClaim)
        var contexts = existingBullets(in: url, section: "Source Context")
        contexts.insert("- [[\(meetingOverviewTitle)]] — \(claim.sourceContext.isEmpty ? "Claim discussed in \(meetingTitle)." : claim.sourceContext)")
        var topics = existingBullets(in: url, section: "Related Topics")
        for topic in claim.relatedTopics where !topic.isEmpty {
            topics.insert("- [[\(topic)]]")
        }
        var entities = existingBullets(in: url, section: "Related Entities")
        for entity in claim.relatedEntities where !entity.isEmpty {
            entities.insert("- [[\(entity)]]")
        }
        var discussed = existingBullets(in: url, section: "Discussed In")
        discussed.insert("- [[\(meetingOverviewTitle)]]")
        var sources = existingBullets(in: url, section: "Source Meetings")
        sources.insert("- `\(meetingPath)`")

        var body = "# \(canonicalClaim)\n\n"
        body += "## Claim\n\n\(canonicalClaim)\n\n"
        body += "## Confidence\n\n\(claim.confidence.isEmpty ? "unknown" : claim.confidence)\n\n"
        if !claim.indexReason.isEmpty {
            body += "## Index Reason\n\n\(claim.indexReason)\n\n"
        }
        body += "## Source Context\n\n\(contexts.sorted().joined(separator: "\n"))\n\n"
        body += "## Related Topics\n\n\(topics.isEmpty ? "(none)" : topics.sorted().joined(separator: "\n"))\n\n"
        body += "## Related Entities\n\n\(entities.isEmpty ? "(none)" : entities.sorted().joined(separator: "\n"))\n\n"
        body += "## Discussed In\n\n\(discussed.sorted().joined(separator: "\n"))\n\n"
        body += "## Source Meetings\n\n\(sources.sorted().joined(separator: "\n"))\n"
        try writePage(url: url, type: "claim", name: canonicalClaim, extraFrontmatter: [
            "confidence": claim.confidence
        ], body: body)
        return url
    }

    private func canonicalizedEntity(_ entity: Entity) -> Entity {
        guard let canonical = canonicalName(for: entity.name, category: entity.category),
              canonical != entity.name else {
            return entity
        }
        var updated = entity
        updated.name = canonical
        return updated
    }

    private func canonicalizedTopic(_ topic: Topic) -> Topic {
        guard let canonical = canonicalName(for: topic.topic, category: "topics"),
              canonical != topic.topic else {
            return topic
        }
        var updated = topic
        updated.topic = canonical
        return updated
    }

    private struct TopicOccurrence: Hashable {
        var title: String
        var meetingPath: String
    }

    private func connectorTopicNames(for topics: [Topic], currentMeetingPath: String) -> Set<String> {
        let existingTopicNames = Set(existingNameSnapshot(category: "topics").keys.map(WikiEntityResolver.normalize))
        var connectors = Set<String>()
        for topic in topics {
            let normalized = WikiEntityResolver.normalize(topic.topic)
            guard !normalized.isEmpty else { continue }
            if topic.indexCandidate ||
                existingTopicNames.contains(normalized) ||
                !existingMeetingOccurrences(forTopic: topic.topic, excludingMeetingPath: currentMeetingPath).isEmpty {
                connectors.insert(normalized)
            }
        }
        return connectors
    }

    private func existingMeetingOccurrences(forTopic topic: String, excludingMeetingPath: String) -> [TopicOccurrence] {
        let needle = WikiEntityResolver.normalize(topic)
        guard !needle.isEmpty else { return [] }
        let folder = GeneratedWikiPaths.root(in: archiveRoot).appendingPathComponent("meetings", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var occurrences: [TopicOccurrence] = []
        for url in urls where url.pathExtension.lowercased() == "md" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let page = try? GeneratedWikiPaths.readPage(from: url) else {
                continue
            }
            let pageMeetingPath = page.sourceMeetingPath ?? ""
            guard pageMeetingPath != excludingMeetingPath else { continue }
            let topicsSection = sectionText(page.body, section: "Topics Discussed") ?? ""
            guard WikiEntityResolver.normalize(topicsSection).contains(needle) else { continue }
            occurrences.append(TopicOccurrence(title: page.title, meetingPath: pageMeetingPath.isEmpty ? url.lastPathComponent : pageMeetingPath))
        }
        return Array(Set(occurrences)).sorted { lhs, rhs in
            if lhs.title == rhs.title { return lhs.meetingPath < rhs.meetingPath }
            return lhs.title < rhs.title
        }
    }

    private func canonicalName(for rawName: String, category: String) -> String? {
        let snapshot = existingNameSnapshot(category: category)
        switch WikiEntityResolver.resolve(name: rawName, snapshot: snapshot) {
        case .matched(let canonical):
            return canonical
        case .ambiguous, .new:
            return nil
        }
    }

    private func existingNameSnapshot(category: String) -> [String: [String]] {
        let folder = GeneratedWikiPaths.root(in: archiveRoot).appendingPathComponent(category, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var snapshot: [String: [String]] = [:]
        for url in urls where url.pathExtension.lowercased() == "md" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let page = try? GeneratedWikiPaths.readPage(from: url) else {
                continue
            }
            let slugAlias = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
            let aliases = sectionText(page.body, section: "Aliases")?
                .split(separator: "\n")
                .map(String.init)
                .filter { $0.hasPrefix("- ") }
                .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
            snapshot[page.title, default: []].append(contentsOf: [slugAlias] + aliases)
        }
        return snapshot
    }

    private struct NearestNameCandidate {
        var name: String
        var reason: String
        var score: Int
    }

    private func nearestExistingNameCandidates(to rawName: String, category: String, limit: Int) -> [NearestNameCandidate] {
        let needle = WikiEntityResolver.normalize(rawName)
        guard !needle.isEmpty else { return [] }
        let needleTokens = Set(needle.split(separator: " ").map(String.init))
        let isShortSingleToken = needleTokens.count == 1 && needle.count <= 6
        return existingNameSnapshot(category: category).keys
            .compactMap { canonical -> NearestNameCandidate? in
                let candidate = WikiEntityResolver.normalize(canonical)
                guard !candidate.isEmpty else { return nil }
                let candidateTokens = Set(candidate.split(separator: " ").map(String.init))
                let distance = WikiEntityResolver.editDistance(needle, candidate)
                let tokenOverlap = needleTokens.intersection(candidateTokens).count
                if isShortSingleToken, tokenOverlap == 0 {
                    return nil
                }
                let score = distance - tokenOverlap
                let threshold = isShortSingleToken ? 1 : max(3, needle.count / 3)
                guard score <= threshold else { return nil }
                let reason: String
                if tokenOverlap > 0 {
                    reason = "Shares \(tokenOverlap) normalized name token\(tokenOverlap == 1 ? "" : "s")."
                } else {
                    reason = "Close spelling match: edit distance \(distance)."
                }
                return NearestNameCandidate(name: canonical, reason: reason, score: score)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.name < rhs.name }
                return lhs.score < rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    private func matchReason(rawName: String, canonical: String, aliases: [String]) -> String {
        let needle = WikiEntityResolver.normalize(rawName)
        let normalizedCanonical = WikiEntityResolver.normalize(canonical)
        if needle == normalizedCanonical {
            return "Exact normalized name match."
        }
        if let alias = aliases.first(where: { WikiEntityResolver.normalize($0) == needle }) {
            return "Exact alias match: \(alias)."
        }
        let needleTokens = Set(needle.split(separator: " ").map(String.init))
        let canonicalTokens = Set(normalizedCanonical.split(separator: " ").map(String.init))
        let overlap = needleTokens.intersection(canonicalTokens).count
        if overlap > 0 {
            return "Shares \(overlap) normalized name token\(overlap == 1 ? "" : "s")."
        }
        let distance = WikiEntityResolver.editDistance(needle, normalizedCanonical)
        return "Close spelling match: edit distance \(distance)."
    }

    private func writePage(url: URL, type: String, name: String, extraFrontmatter: [String: String], body: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let incomingBody = body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let incomingBodyHash = GhostPepperHistoryStore.stableHash(incomingBody)
        let existingText = try? String(contentsOf: url, encoding: .utf8)
        let existingPage = (try? GeneratedWikiPaths.readPage(from: url))
        let existingFrontmatter = existingText.map(frontmatterDictionary) ?? [:]
        let pageID = existingFrontmatter["page_id"] ?? "gpw_\(Self.stableHash("\(type)|\(name)|\(url.deletingLastPathComponent().lastPathComponent)"))"
        let entityID = existingFrontmatter["entity_id"] ?? pageID
        let lastGeneratedBodyHash = existingFrontmatter["last_generated_body_hash"]
        let existingBody = existingPage.map { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" }
        let existingBodyHash = existingBody.map(GhostPepperHistoryStore.stableHash)
        let userEditedSinceGeneration = lastGeneratedBodyHash != nil &&
            existingBodyHash != nil &&
            lastGeneratedBodyHash != existingBodyHash
        let finalBody = userEditedSinceGeneration ? (existingBody ?? incomingBody) : incomingBody
        let finalBodyHash = GhostPepperHistoryStore.stableHash(finalBody)

        var text = "---\n"
        text += "type: \(type)\n"
        text += "page_id: \(yaml(pageID))\n"
        if Self.isEntityPageType(type) {
            text += "entity_id: \(yaml(entityID))\n"
        }
        text += "name: \(yaml(name))\n"
        text += "updated_at: \(now)\n"
        text += "user_edited: \(userEditedSinceGeneration ? "true" : "false")\n"
        text += "pending_generated_update: \(userEditedSinceGeneration ? "true" : "false")\n"
        text += "last_generated_body_hash: \(yaml(userEditedSinceGeneration ? (existingBodyHash ?? finalBodyHash) : incomingBodyHash))\n"
        if userEditedSinceGeneration {
            text += "pending_generated_body_hash: \(yaml(incomingBodyHash))\n"
        }
        text += "generated_by_model: \(yaml(modelKind.rawValue))\n"
        text += "generation_model_kind: \(yaml(modelKind.rawValue))\n"
        text += "generation_model_display: \(yaml(AgentBackend.local(modelKind).shortDisplayName))\n"
        text += "generation_schema_version: \(yaml(Self.generationSchemaVersion))\n"
        text += "generation_prompt_name: \(yaml(Self.meetingIntelligencePromptName))\n"
        text += "generation_prompt_version: \(yaml(Self.meetingIntelligencePromptVersion))\n"
        text += "generation_prompt_hash: \(yaml(Self.stableHash(Self.meetingIntelligencePromptFingerprint)))\n"
        text += "generation_prompt_hash_scope: \"template_only_no_source_text\"\n"
        for (key, value) in extraFrontmatter.sorted(by: { $0.key < $1.key }) {
            text += "\(key): \(yaml(value))\n"
        }
        text += "---\n\n"
        text += finalBody
        if userEditedSinceGeneration {
            let proposalText = frontmatterWrappedText(
                type: type,
                name: name,
                extraFrontmatter: extraFrontmatter,
                body: incomingBody,
                now: now,
                generatedBodyHash: incomingBodyHash
            )
            GhostPepperHistoryStore.recordFileChange(
                archiveRoot: archiveRoot,
                fileURL: url,
                actor: .ghostPepper,
                operation: "generated_proposal_preserved_user_edit",
                summary: "Generated an update for \(name), but preserved the existing user-edited 2nd Brain page.",
                before: existingText,
                after: proposalText,
                metadata: historyMetadata(
                    type: type,
                    name: name,
                    extra: [
                        "preserved_user_edit": "true",
                        "pending_generated_body_hash": incomingBodyHash
                    ]
                )
            )
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        GhostPepperHistoryStore.recordFileChange(
            archiveRoot: archiveRoot,
            fileURL: url,
            actor: .ghostPepper,
            operation: userEditedSinceGeneration ? "preserve_user_edited_2nd_brain_page" : "generate_2nd_brain_page",
            summary: userEditedSinceGeneration
                ? "Preserved user-edited 2nd Brain page for \(name)."
                : "Generated 2nd Brain page for \(name).",
            before: existingText,
            after: text,
            metadata: historyMetadata(
                type: type,
                name: name,
                extra: [
                    "user_edited": userEditedSinceGeneration ? "true" : "false",
                    "body_hash": finalBodyHash
                ]
            )
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func frontmatterWrappedText(
        type: String,
        name: String,
        extraFrontmatter: [String: String],
        body: String,
        now: String,
        generatedBodyHash: String
    ) -> String {
        var text = "---\n"
        text += "type: \(type)\n"
        text += "page_id: \(yaml("gpw_\(Self.stableHash("\(type)|\(name)"))"))\n"
        if Self.isEntityPageType(type) {
            text += "entity_id: \(yaml("gpw_\(Self.stableHash("\(type)|\(name)"))"))\n"
        }
        text += "name: \(yaml(name))\n"
        text += "updated_at: \(now)\n"
        text += "user_edited: false\n"
        text += "pending_generated_update: false\n"
        text += "last_generated_body_hash: \(yaml(generatedBodyHash))\n"
        text += "generated_by_model: \(yaml(modelKind.rawValue))\n"
        text += "generation_model_kind: \(yaml(modelKind.rawValue))\n"
        text += "generation_model_display: \(yaml(AgentBackend.local(modelKind).shortDisplayName))\n"
        text += "generation_schema_version: \(yaml(Self.generationSchemaVersion))\n"
        text += "generation_prompt_name: \(yaml(Self.meetingIntelligencePromptName))\n"
        text += "generation_prompt_version: \(yaml(Self.meetingIntelligencePromptVersion))\n"
        text += "generation_prompt_hash: \(yaml(Self.stableHash(Self.meetingIntelligencePromptFingerprint)))\n"
        text += "generation_prompt_hash_scope: \"template_only_no_source_text\"\n"
        for (key, value) in extraFrontmatter.sorted(by: { $0.key < $1.key }) {
            text += "\(key): \(yaml(value))\n"
        }
        text += "---\n\n"
        text += body
        return text
    }

    private func historyMetadata(type: String, name: String, extra: [String: String] = [:]) -> [String: String] {
        var metadata = [
            "page_type": type,
            "page_name": name,
            "model_kind": modelKind.rawValue,
            "model_display": AgentBackend.local(modelKind).shortDisplayName,
            "generation_schema_version": Self.generationSchemaVersion,
            "generation_prompt_name": Self.meetingIntelligencePromptName,
            "generation_prompt_version": Self.meetingIntelligencePromptVersion,
            "generation_prompt_hash": Self.stableHash(Self.meetingIntelligencePromptFingerprint),
            "generation_prompt_hash_scope": "template_only_no_source_text"
        ]
        for (key, value) in extra {
            metadata[key] = value
        }
        return metadata
    }

    private static func isEntityPageType(_ type: String) -> Bool {
        ["person", "company", "concept"].contains(type)
    }

    private func frontmatterDictionary(_ text: String) -> [String: String] {
        guard text.hasPrefix("---\n"),
              let close = text.dropFirst(4).range(of: "\n---\n") else {
            return [:]
        }
        let fm = String(text.dropFirst(4)[..<close.lowerBound])
        var out: [String: String] = [:]
        for line in fm.split(separator: "\n").map(String.init) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            out[key] = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return out
    }

    private func existingBullets(in url: URL, section: String) -> Set<String> {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let body = try? GeneratedWikiPaths.readPage(from: url).body else {
            return []
        }
        _ = text
        return Set(sectionText(body, section: section)?.split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") } ?? [])
    }

    private func existingSection(in url: URL, section: String) -> String? {
        guard let page = try? GeneratedWikiPaths.readPage(from: url) else { return nil }
        let text = sectionText(page.body, section: section)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty, text != "(none)" else { return nil }
        return text
    }

    private func evolvingSummary(existing: String?, extracted: String, fallback: String, entityName: String) -> String {
        let cleanExisting = oneLine(existing ?? "")
        let cleanExtracted = oneLine(extracted)
        guard !cleanExtracted.isEmpty else {
            return cleanExisting.isEmpty ? fallback : cleanExisting
        }
        guard !cleanExisting.isEmpty else {
            return cleanExtracted
        }
        if isGenericSummary(cleanExisting, entityName: entityName) {
            return cleanExtracted
        }
        if cleanExisting.localizedCaseInsensitiveContains(cleanExtracted) {
            return cleanExisting
        }
        if cleanExtracted.count > cleanExisting.count + 24 {
            return cleanExtracted
        }
        return cleanExisting
    }

    private func oneLine(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func isGenericSummary(_ text: String, entityName: String) -> Bool {
        let normalized = text.lowercased()
        return normalized == "\(entityName.lowercased()) was discussed." ||
            normalized.contains("was discussed in relation to")
    }

    private func sectionText(_ body: String, section: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## \(section)" }) else { return nil }
        var collected: [String] = []
        for line in lines.dropFirst(start + 1) {
            if line.hasPrefix("## ") { break }
            collected.append(line)
        }
        return collected.joined(separator: "\n")
    }

    private func commitWiki(touched: [URL], title: String) -> String {
        let root = GeneratedWikiPaths.root(in: archiveRoot)
        _ = runGit(["add", "."], in: root)
        let result = runGit(["commit", "-m", "Update 2nd Brain for \(title)"], in: root)
        if result.exitCode == 0 { return "Committed 2nd Brain changes." }
        if result.output.contains("nothing to commit") { return "No Git changes to commit." }
        return "2nd Brain files saved; Git commit skipped: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private func runGit(_ args: [String], in directory: URL) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (1, error.localizedDescription)
        }
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.path).inserted }
    }

    private func yaml(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func jsonString(_ value: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private static func jsonString(_ value: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func relativePath(of url: URL, in root: URL) -> String? {
        let base = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(base) else { return nil }
        var rel = String(full.dropFirst(base.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel.isEmpty ? nil : rel
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen: Set<Key> = []
        return filter { seen.insert(key($0)).inserted }
    }
}
