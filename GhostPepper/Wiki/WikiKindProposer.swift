import Foundation

/// Proposes new wiki kinds ("Companies", "Projects", …) from what the
/// archive's meeting cards actually contain. The signal digest is built
/// deterministically (topic/affiliation tallies); the local model only
/// names categories — and every proposal still requires the user's
/// explicit approval before a wiki is created.
@MainActor
final class WikiKindProposer {
    private let llm: LocalStructuredLLM
    private let saveDir: URL

    init(cleanupManager: TextCleanupManager, saveDir: URL, modelKind: LocalCleanupModelKind) {
        self.llm = LocalStructuredLLM(cleanupManager: cleanupManager, modelKind: modelKind)
        self.saveDir = saveDir
    }

    /// Minimum cards before proposing — below this the signal is noise.
    static let minimumCards = 8

    func propose(maxProposals: Int = 3) async throws -> [WikiKindProposal] {
        let cards = MeetingCardStore.allCards(in: saveDir)
        guard cards.count >= Self.minimumCards else { return [] }

        let existing = WikiKindStore.shared.allKinds
        let digest = Self.signalDigest(cards: cards)

        let object = try await llm.completeJSONObject(
            system: LocalWikiPrompts.proposeKindsSystem,
            user: LocalWikiPrompts.proposeKindsUser(existingKinds: existing, digest: digest)
        )

        let existingSlugs = Set(existing.map { $0.slug })
        var proposals: [WikiKindProposal] = []
        for item in (object["proposals"] as? [Any]) ?? [] {
            guard let dict = item as? [String: Any] else { continue }
            let name = MeetingCardJSON.string(dict["name"])
            guard !name.isEmpty else { continue }
            let slug = MarkdownArchivePaths.slugForIndexEntry(name)
            guard !slug.isEmpty, slug != "untitled", !existingSlugs.contains(slug) else { continue }
            guard !proposals.contains(where: { $0.spec.slug == slug }) else { continue }

            let noun = MeetingCardJSON.string(dict["entity_noun"] ?? dict["entityNoun"])
            let spec = WikiKindSpec(
                slug: slug,
                displayName: name,
                entityNoun: noun.isEmpty ? "entry" : noun.lowercased(),
                iconSystemName: WikiKindSpec.coercedIcon(MeetingCardJSON.string(dict["icon"])),
                extractionHint: MeetingCardJSON.string(dict["hint"] ?? dict["extraction_hint"]),
                createdAt: Date()
            )
            proposals.append(WikiKindProposal(
                spec: spec,
                rationale: MeetingCardJSON.string(dict["rationale"]),
                proposedAt: Date()
            ))
            if proposals.count >= maxProposals { break }
        }
        return proposals
    }

    /// Deterministic tallies of the archive's recurring signals. Top topics
    /// and affiliations with counts — enough for the model to see what
    /// categories would actually fill up.
    static func signalDigest(cards: [MeetingCard], maxItems: Int = 40) -> String {
        var topicCounts: [String: Int] = [:]
        var affiliationCounts: [String: Int] = [:]
        for card in cards {
            for topic in card.topics {
                let key = topic.lowercased().trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                topicCounts[key, default: 0] += 1
            }
            for participant in card.participants where !participant.affiliation.isEmpty {
                let key = participant.affiliation.trimmingCharacters(in: .whitespaces)
                affiliationCounts[key, default: 0] += 1
            }
        }

        func top(_ counts: [String: Int], _ n: Int) -> [String] {
            counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .prefix(n)
                .map { "\($0.key) (×\($0.value))" }
        }

        var out = "Meetings digested: \(cards.count)\n\n"
        out += "Recurring topics:\n"
        for line in top(topicCounts, maxItems) { out += "- \(line)\n" }
        out += "\nAffiliations seen on participants:\n"
        for line in top(affiliationCounts, maxItems / 2) { out += "- \(line)\n" }
        return out
    }
}
