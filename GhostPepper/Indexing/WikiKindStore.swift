import Foundation

/// Describes one wiki kind: the built-in People wiki or a user-approved
/// custom wiki ("Companies", "Projects", …). The `extractionHint` is fed to
/// the local card-extraction and page prompts so the model knows what counts
/// as an entity of this kind.
struct WikiKindSpec: Codable, Equatable, Identifiable {
    var slug: String
    var displayName: String
    /// Singular noun, lowercase: "person", "company", "project".
    var entityNoun: String
    var iconSystemName: String
    var extractionHint: String
    var createdAt: Date

    var id: String { slug }
    var isBuiltIn: Bool { slug == WikiKindSpec.people.slug }

    static let people = WikiKindSpec(
        slug: "people",
        displayName: "People",
        entityNoun: "person",
        iconSystemName: "person.3",
        extractionHint: "A specific human being: a calendar attendee, a meeting participant, or a person mentioned by name in the discussion. Not generic roles (\"the lawyer\") unless a name is attached.",
        createdAt: .distantPast
    )

    /// Rendering fallback for entries whose kind is no longer registered.
    static func fallback(slug: String) -> WikiKindSpec {
        WikiKindSpec(
            slug: slug,
            displayName: slug.split(separator: "-").map { $0.capitalized }.joined(separator: " "),
            entityNoun: "entry",
            iconSystemName: "folder",
            extractionHint: "",
            createdAt: .distantPast
        )
    }

    /// SF Symbols the proposer/custom-wiki UI is allowed to pick from. The
    /// model's icon suggestion is coerced into this set so a hallucinated
    /// symbol name can't produce a blank icon.
    static let allowedIcons: [String] = [
        "building.2", "briefcase", "folder", "lightbulb", "cpu",
        "banknote", "chart.line.uptrend.xyaxis", "person.2.wave.2",
        "shippingbox", "tag", "globe", "book",
    ]

    static func coercedIcon(_ raw: String) -> String {
        allowedIcons.contains(raw) ? raw : "folder"
    }
}

/// A wiki kind the local model has proposed but the user hasn't approved yet.
struct WikiKindProposal: Codable, Equatable, Identifiable {
    var spec: WikiKindSpec
    var rationale: String
    var proposedAt: Date

    var id: String { spec.slug }
}

/// Registry of wiki kinds for the current archive. People is always present;
/// custom kinds persist at `<save dir>/.indexes/_kinds.json` and pending
/// proposals at `<save dir>/.indexes/_wiki_proposals.json`.
///
/// Thread-safe (used from UI on main and from the wiki engine's tasks).
/// Reads are cached and invalidated by file mtime, so `IndexKind.allCases`
/// stays cheap enough for SwiftUI body evaluation.
final class WikiKindStore {
    static let shared = WikiKindStore()

    private let lock = NSLock()
    private let saveDirResolver: () -> URL
    private var cachedKinds: [WikiKindSpec]?
    private var cachedKindsMtime: Date?
    private var cachedKindsDir: String?

    /// Production singleton resolves the archive directory each access so a
    /// mid-session save-directory change picks up that archive's wikis.
    /// Tests inject a temp directory.
    init(saveDirResolver: @escaping () -> URL = { MeetingTranscriptSettings.effectiveSaveDirectory() }) {
        self.saveDirResolver = saveDirResolver
    }

    // MARK: - Paths

    private func kindsURL() -> URL {
        MarkdownArchivePaths.indexesRoot(in: saveDirResolver())
            .appendingPathComponent("_kinds.json")
    }

    private func proposalsURL() -> URL {
        MarkdownArchivePaths.indexesRoot(in: saveDirResolver())
            .appendingPathComponent("_wiki_proposals.json")
    }

    // MARK: - Kinds

    /// All kinds, People first, custom kinds in creation order.
    var allKinds: [WikiKindSpec] {
        [.people] + customKinds()
    }

    func spec(for slug: String) -> WikiKindSpec {
        if slug == WikiKindSpec.people.slug { return .people }
        if let match = customKinds().first(where: { $0.slug == slug }) { return match }
        return .fallback(slug: slug)
    }

    func kindExists(_ slug: String) -> Bool {
        allKinds.contains { $0.slug == slug }
    }

    enum StoreError: LocalizedError {
        case invalidSlug(String)
        case duplicateSlug(String)

        var errorDescription: String? {
            switch self {
            case .invalidSlug(let s): return "'\(s)' isn't a usable wiki name."
            case .duplicateSlug(let s): return "A wiki named '\(s)' already exists."
            }
        }
    }

    /// Adds a custom kind, creates its `.indexes/<slug>/` directory so the
    /// sidebar shows it immediately, and removes any matching proposal.
    func addKind(_ spec: WikiKindSpec) throws {
        var normalized = spec
        normalized.slug = MarkdownArchivePaths.slugForIndexEntry(spec.slug.isEmpty ? spec.displayName : spec.slug)
        normalized.iconSystemName = WikiKindSpec.coercedIcon(spec.iconSystemName)
        if normalized.entityNoun.trimmingCharacters(in: .whitespaces).isEmpty {
            normalized.entityNoun = "entry"
        }
        guard !normalized.slug.isEmpty,
              normalized.slug != "untitled",
              !normalized.slug.hasPrefix("_"),
              !normalized.slug.hasPrefix(".") else {
            throw StoreError.invalidSlug(spec.displayName)
        }
        guard !kindExists(normalized.slug) else {
            throw StoreError.duplicateSlug(normalized.slug)
        }

        lock.lock()
        defer { lock.unlock() }
        var kinds = loadCustomKindsLocked()
        kinds.append(normalized)
        try persistKindsLocked(kinds)

        // Create the kind's directory so it appears in the sidebar right away.
        let root = MarkdownArchivePaths.indexRoot(in: saveDirResolver(), kind: IndexKind(rawValue: normalized.slug))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        removeProposalLocked(slug: normalized.slug)
        postKindsChanged()
    }

    /// Removes a custom kind from the registry. Does NOT delete the kind's
    /// entries on disk — the folder stays and can be re-registered.
    func removeKind(slug: String) throws {
        guard slug != WikiKindSpec.people.slug else { return }
        lock.lock()
        defer { lock.unlock() }
        var kinds = loadCustomKindsLocked()
        kinds.removeAll { $0.slug == slug }
        try persistKindsLocked(kinds)
        postKindsChanged()
    }

    private func customKinds() -> [WikiKindSpec] {
        lock.lock()
        defer { lock.unlock() }
        return loadCustomKindsLocked()
    }

    private func loadCustomKindsLocked() -> [WikiKindSpec] {
        let url = kindsURL()
        let dirKey = url.path
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date

        if let cached = cachedKinds, cachedKindsDir == dirKey, cachedKindsMtime == mtime {
            return cached
        }

        var kinds: [WikiKindSpec] = []
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            kinds = (try? decoder.decode([WikiKindSpec].self, from: data)) ?? []
        }
        kinds.removeAll { $0.slug == WikiKindSpec.people.slug }
        cachedKinds = kinds
        cachedKindsMtime = mtime
        cachedKindsDir = dirKey
        return kinds
    }

    private func persistKindsLocked(_ kinds: [WikiKindSpec]) throws {
        let url = kindsURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(kinds)
        try data.write(to: url, options: .atomic)
        cachedKinds = kinds
        cachedKindsMtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        cachedKindsDir = url.path
    }

    // MARK: - Proposals

    var proposals: [WikiKindProposal] {
        lock.lock()
        defer { lock.unlock() }
        return loadProposalsLocked()
    }

    /// Replaces pending proposals, dropping any whose slug already exists as
    /// a registered kind.
    func saveProposals(_ proposals: [WikiKindProposal]) {
        lock.lock()
        defer { lock.unlock() }
        let kinds = Set(([WikiKindSpec.people] + loadCustomKindsLocked()).map { $0.slug })
        let filtered = proposals.filter { !kinds.contains($0.spec.slug) }
        persistProposalsLocked(filtered)
        postKindsChanged()
    }

    func removeProposal(slug: String) {
        lock.lock()
        defer { lock.unlock() }
        removeProposalLocked(slug: slug)
        postKindsChanged()
    }

    private func removeProposalLocked(slug: String) {
        var proposals = loadProposalsLocked()
        proposals.removeAll { $0.spec.slug == slug }
        persistProposalsLocked(proposals)
    }

    private func loadProposalsLocked() -> [WikiKindProposal] {
        guard let data = try? Data(contentsOf: proposalsURL()) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([WikiKindProposal].self, from: data)) ?? []
    }

    private func persistProposalsLocked(_ proposals: [WikiKindProposal]) {
        let url = proposalsURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(proposals) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func postKindsChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .wikiKindsChanged, object: nil)
        }
    }
}

extension Notification.Name {
    /// Posted when the wiki-kind registry or its pending proposals change.
    static let wikiKindsChanged = Notification.Name("wikiKindsChanged")
}
