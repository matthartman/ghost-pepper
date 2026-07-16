import Foundation

/// The distilled, reusable digest of one meeting — the "map" stage output of
/// the local wiki pipeline. Cards are small (1–2 KB), so entity pages can be
/// regenerated from a person's full card set without ever re-reading raw
/// transcripts. Persisted as JSON sidecars under `.indexes/_cards/`.
struct MeetingCard: Codable, Equatable {
    struct Participant: Codable, Equatable {
        var name: String
        var role: String
        var affiliation: String
    }

    /// A human mentioned in the meeting, even if they were not an attendee
    /// and we do not know whether they spoke.
    struct MentionedPerson: Codable, Equatable {
        var name: String
        var context: String
        var possibleRole: String
        var confidence: String
    }

    /// A mention of a non-people wiki entity ("companies" → "Acme Co.").
    struct Mention: Codable, Equatable {
        var kind: String
        var name: String
        var context: String
    }

    struct Quote: Codable, Equatable {
        var text: String
        var line: Int
    }

    static let currentVersion = 2

    var version: Int
    var meetingPath: String
    var title: String
    var date: String
    var summary: String
    var participants: [Participant]
    var mentionedPeople: [MentionedPerson]
    var mentions: [Mention]
    var topics: [String]
    var decisions: [String]
    var openThreads: [String]
    var quotes: [Quote]
    /// Wiki-kind slugs whose mention scan has run over this card. Lets a
    /// newly approved kind backfill only the cards it hasn't scanned yet.
    var scannedKinds: [String]
    /// Modification date of the source meeting file when this card was
    /// extracted; a mismatch means the card is stale.
    var sourceModifiedAt: Date
    var generatedByModel: String
    var promptHash: String
    var generatedAt: Date

    enum CodingKeys: String, CodingKey {
        case version
        case meetingPath
        case title
        case date
        case summary
        case participants
        case mentionedPeople
        case mentions
        case topics
        case decisions
        case openThreads
        case quotes
        case scannedKinds
        case sourceModifiedAt
        case generatedByModel
        case promptHash
        case generatedAt
    }

    init(
        version: Int,
        meetingPath: String,
        title: String,
        date: String,
        summary: String,
        participants: [Participant],
        mentionedPeople: [MentionedPerson] = [],
        mentions: [Mention],
        topics: [String],
        decisions: [String],
        openThreads: [String],
        quotes: [Quote],
        scannedKinds: [String],
        sourceModifiedAt: Date,
        generatedByModel: String,
        promptHash: String,
        generatedAt: Date
    ) {
        self.version = version
        self.meetingPath = meetingPath
        self.title = title
        self.date = date
        self.summary = summary
        self.participants = participants
        self.mentionedPeople = mentionedPeople
        self.mentions = mentions
        self.topics = topics
        self.decisions = decisions
        self.openThreads = openThreads
        self.quotes = quotes
        self.scannedKinds = scannedKinds
        self.sourceModifiedAt = sourceModifiedAt
        self.generatedByModel = generatedByModel
        self.promptHash = promptHash
        self.generatedAt = generatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        meetingPath = try c.decode(String.self, forKey: .meetingPath)
        title = try c.decode(String.self, forKey: .title)
        date = try c.decode(String.self, forKey: .date)
        summary = try c.decode(String.self, forKey: .summary)
        participants = try c.decode([Participant].self, forKey: .participants)
        mentionedPeople = try c.decodeIfPresent([MentionedPerson].self, forKey: .mentionedPeople) ?? []
        mentions = try c.decode([Mention].self, forKey: .mentions)
        topics = try c.decode([String].self, forKey: .topics)
        decisions = try c.decode([String].self, forKey: .decisions)
        openThreads = try c.decode([String].self, forKey: .openThreads)
        quotes = try c.decodeIfPresent([Quote].self, forKey: .quotes) ?? []
        scannedKinds = try c.decode([String].self, forKey: .scannedKinds)
        sourceModifiedAt = try c.decode(Date.self, forKey: .sourceModifiedAt)
        generatedByModel = try c.decode(String.self, forKey: .generatedByModel)
        promptHash = try c.decode(String.self, forKey: .promptHash)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
    }

    /// Names that should resolve to People entities: participants plus any
    /// explicit "people" mentions.
    var peopleNames: [String] {
        var names = participants.map { $0.name }
        names.append(contentsOf: mentionedPeople.map { $0.name })
        names.append(contentsOf: mentions.filter { $0.kind == "people" }.map { $0.name })
        return names
    }

    func entityNames(forKind slug: String) -> [String] {
        if slug == "people" { return peopleNames }
        return mentions.filter { $0.kind == slug }.map { $0.name }
    }

    /// One-line context shown in a dossier's Mentions/Timeline sections.
    var oneLineSummary: String {
        let first = summary.split(separator: "\n").first.map(String.init) ?? summary
        if first.count > 220 {
            return String(first.prefix(220)) + "…"
        }
        return first
    }
}

/// Disk IO for cards. Cards live in `.indexes/_cards/` — the underscore
/// prefix keeps them out of entry listings, which skip `_`-prefixed names.
enum MeetingCardStore {
    static func cardsRoot(in saveDir: URL) -> URL {
        MarkdownArchivePaths.indexesRoot(in: saveDir).appendingPathComponent("_cards", isDirectory: true)
    }

    /// "2026-04-28/standup.md" → ".indexes/_cards/2026-04-28__standup.md.json"
    static func cardURL(in saveDir: URL, meetingPath: String) -> URL {
        let flat = meetingPath.replacingOccurrences(of: "/", with: "__")
        return cardsRoot(in: saveDir).appendingPathComponent("\(flat).json")
    }

    static func read(in saveDir: URL, meetingPath: String) -> MeetingCard? {
        let url = cardURL(in: saveDir, meetingPath: meetingPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingCard.self, from: data)
    }

    static func write(_ card: MeetingCard, in saveDir: URL) throws {
        let url = cardURL(in: saveDir, meetingPath: card.meetingPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(card)
        try data.write(to: url, options: .atomic)
    }

    static func allCards(in saveDir: URL) -> [MeetingCard] {
        let root = cardsRoot(in: saveDir)
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var cards: [MeetingCard] = []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let card = try? decoder.decode(MeetingCard.self, from: data) {
                cards.append(card)
            }
        }
        return cards.sorted { $0.meetingPath < $1.meetingPath }
    }

    /// A card is current when it exists, matches the schema version, and the
    /// source file hasn't been modified since extraction.
    static func isCurrent(_ card: MeetingCard, sourceURL: URL) -> Bool {
        guard card.version == MeetingCard.currentVersion else { return false }
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.modificationDate]) as? Date else {
            return false
        }
        return abs(mtime.timeIntervalSince(card.sourceModifiedAt)) < 1.0
    }
}

/// Lenient decoding of card fields from small-model output. Small local
/// models produce JSON that is *mostly* right — this coerces the common
/// deviations (numbers where strings belong, plain strings where objects
/// belong, chatter around the JSON) instead of failing.
enum MeetingCardJSON {
    /// Coerce `Any?` into a string array, accepting arrays of strings,
    /// numbers, or objects with a "name"/"text" field.
    static func stringList(_ any: Any?) -> [String] {
        guard let array = any as? [Any] else { return [] }
        return array.compactMap { item in
            if let s = item as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            if let n = item as? NSNumber { return n.stringValue }
            if let d = item as? [String: Any] {
                for key in ["name", "text", "value"] {
                    if let s = d[key] as? String, !s.isEmpty { return s }
                }
            }
            return nil
        }
    }

    static func string(_ any: Any?) -> String {
        if let s = any as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    static func int(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func participants(_ any: Any?) -> [MeetingCard.Participant] {
        guard let array = any as? [Any] else { return [] }
        return array.compactMap { item in
            if let s = item as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : MeetingCard.Participant(name: t, role: "", affiliation: "")
            }
            guard let d = item as? [String: Any] else { return nil }
            let name = string(d["name"])
            guard !name.isEmpty else { return nil }
            return MeetingCard.Participant(
                name: name,
                role: string(d["role"] ?? d["role_hint"]),
                affiliation: string(d["affiliation"] ?? d["company"] ?? d["org"])
            )
        }
    }

    static func mentionedPeople(_ any: Any?) -> [MeetingCard.MentionedPerson] {
        guard let array = any as? [Any] else { return [] }
        return array.compactMap { item in
            if let s = item as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : MeetingCard.MentionedPerson(name: t, context: "", possibleRole: "", confidence: "")
            }
            guard let d = item as? [String: Any] else { return nil }
            let name = string(d["name"])
            guard !name.isEmpty else { return nil }
            return MeetingCard.MentionedPerson(
                name: name,
                context: string(d["context"]),
                possibleRole: string(d["possible_role"] ?? d["possibleRole"] ?? d["role"] ?? d["job"]),
                confidence: string(d["confidence"])
            )
        }
    }

    static func mentions(_ any: Any?, defaultKind: String? = nil) -> [MeetingCard.Mention] {
        guard let array = any as? [Any] else { return [] }
        return array.compactMap { item in
            if let s = item as? String, let kind = defaultKind {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : MeetingCard.Mention(kind: kind, name: t, context: "")
            }
            guard let d = item as? [String: Any] else { return nil }
            let name = string(d["name"])
            let kind = defaultKind ?? string(d["kind"])
            guard !name.isEmpty, !kind.isEmpty else { return nil }
            return MeetingCard.Mention(kind: kind, name: name, context: string(d["context"]))
        }
    }

    static func quotes(_ any: Any?) -> [MeetingCard.Quote] {
        guard let array = any as? [Any] else { return [] }
        return array.compactMap { item in
            guard let d = item as? [String: Any] else { return nil }
            let text = string(d["text"] ?? d["quote"])
            guard !text.isEmpty, let line = int(d["line"]) else { return nil }
            return MeetingCard.Quote(text: text, line: line)
        }
    }

    /// Drops quotes whose line numbers fall outside the source file, and
    /// quotes whose text doesn't loosely appear near the cited line. Keeps
    /// the card honest without failing the whole extraction.
    static func validatedQuotes(_ quotes: [MeetingCard.Quote], fileLines: [String]) -> [MeetingCard.Quote] {
        quotes.filter { quote in
            guard quote.line >= 1, quote.line <= fileLines.count else { return false }
            let lo = max(0, quote.line - 3)
            let hi = min(fileLines.count, quote.line + 2)
            let neighborhood = fileLines[lo..<hi].joined(separator: " ").lowercased()
            let needle = String(quote.text.prefix(40)).lowercased().trimmingCharacters(in: .whitespaces)
            guard needle.count >= 8 else { return true }
            return neighborhood.contains(needle) || neighborhood.contains(String(needle.prefix(16)))
        }
    }
}
