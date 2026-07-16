import Foundation

struct GeneratedWikiPage: Identifiable, Equatable {
    var id: String { url.path }
    var url: URL
    var title: String
    var type: String
    var sourceMeetingPath: String?
    var body: String
    var updatedAt: Date?
}

struct GeneratedWikiResult: Equatable {
    var overviewURL: URL
    var touchedURLs: [URL]
    var gitMessage: String
    var usage: QAUsage
}

enum GeneratedWikiProgress {
    case status(String)
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
            sourceMeetingPath: frontmatter["source_meeting_path"],
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            updatedAt: updatedAt
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

    func generate(for meetingURL: URL, onProgress: @MainActor @escaping (GeneratedWikiProgress) -> Void = { _ in }) async throws -> GeneratedWikiResult {
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

        onProgress(.status("Extracting entities"))
        let entityRun = try await extractEntities(meetingText: meetingText, onProgress: onProgress)
        totalInputTokens += entityRun.inputTokens
        totalOutputTokens += entityRun.outputTokens

        onProgress(.status("Extracting topics and insights"))
        let topicRun = try await extractTopics(meetingText: meetingText, onProgress: onProgress)
        totalInputTokens += topicRun.inputTokens
        totalOutputTokens += topicRun.outputTokens

        let entities = entityRun.entities.map { canonicalizedEntity($0) }
        let topics = topicRun.topics.map { canonicalizedTopic($0) }

        onProgress(.status("Writing 2nd Brain pages"))
        try ensureWikiRoot()
        var touched: [URL] = []
        let overview = try writeMeetingOverview(
            title: title,
            date: date,
            meetingPath: meetingPath,
            entities: entities,
            topics: topics
        )
        touched.append(overview)
        onProgress(.saved(overview))
        for entity in entities {
            let url = try writeEntityPage(entity, meetingTitle: title, meetingOverviewTitle: title, meetingPath: meetingPath)
            touched.append(url)
            onProgress(.saved(url))
        }
        for topic in topics {
            let url = try writeTopicPage(topic, meetingTitle: title, meetingOverviewTitle: title, meetingPath: meetingPath)
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

    private struct Topic: Hashable {
        var topic: String
        var description: String
        var insights: [String]
        var relatedEntities: [String]
    }

    private func extractEntities(
        meetingText: String,
        onProgress: @MainActor @escaping (GeneratedWikiProgress) -> Void
    ) async throws -> (entities: [Entity], inputTokens: Int, outputTokens: Int) {
        let system = """
        /no_think
        You are an entity extraction engine. Output only valid JSON. Do not explain. Do not include markdown. Do not include thinking text.

        Extract entities discussed in the meeting text.

        Entity types:
        - Person: named human beings
        - Company: companies, funds, firms, institutions, products, named organizations
        - Concept: named themes, market categories, strategies, memes, trends, or important phrases
        """
        let user = """
        Return a JSON array. Each item must have exactly these keys:

        [
          {
            "entity_name": "",
            "entity_type": "Person|Company|Concept",
            "one_sentence_description": "",
            "roles": [""],
            "relationships": [""],
            "relevant_context": ""
          }
        ]

        Rules:
        - Include meeting participants from the title as Person entities.
        - Include entities from the summary and transcript.
        - Include concepts like "SaaS apocalypse", "physical AI", and similar discussed themes.
        - one_sentence_description is required for every Person, Company, and Concept. It should be one durable sentence suitable for that entity's wiki page.
        - For people, include role, affiliation, or what they are known for only when supported by the text.
        - roles should capture supported durable roles/types, especially fund-ecosystem roles such as "LP", "fund investor", "VC", "founder", "operator", "manager", "allocator", "candidate", or "advisor".
        - relationships should capture supported graph-like facts as short evidence-backed phrases, such as "LP in funds", "works at Fundora", "introduced by X", "invests in Y", or "discussed with Z". Include the evidence phrase in the relationship text when possible.
        - For companies, describe what the company/fund/institution/product is or why it mattered in the meeting.
        - For concepts, define the theme or idea in the meeting's own context.
        - Relevant context should be one concrete sentence about how the entity came up.
        - If a role or relationship is only implied, include "possible:" in the string, e.g. "possible: LP / fund investor".
        - Do not include generic words unless they are discussed as a theme.
        - Do not invent entities.
        - Output only the JSON array.

        Meeting text:
        \(meetingText)
        """
        onProgress(.functionStarted(name: "Extract entities", system: system, user: user))
        let result = try await llm.completeJSONArrayWithTrace(system: system, user: user) { token in
            onProgress(.token(token))
        }
        onProgress(.functionFinished(
            name: "Extract entities",
            output: result.trace.text,
            inputTokens: result.trace.estimatedInputTokens,
            outputTokens: result.trace.estimatedOutputTokens
        ))
        let entities: [Entity] = result.array.compactMap { (item: [String: Any]) -> Entity? in
            let name = MeetingCardJSON.string(item["entity_name"] ?? item["Entity Name"])
            guard !name.isEmpty else { return nil }
            return Entity(
                name: name,
                type: MeetingCardJSON.string(item["entity_type"] ?? item["Entity Type"]).isEmpty ? "Concept" : MeetingCardJSON.string(item["entity_type"] ?? item["Entity Type"]),
                description: MeetingCardJSON.string(item["one_sentence_description"] ?? item["description"] ?? item["Description"]),
                roles: MeetingCardJSON.stringList(item["roles"] ?? item["Roles"]),
                relationships: MeetingCardJSON.stringList(item["relationships"] ?? item["Relationships"]),
                context: MeetingCardJSON.string(item["relevant_context"] ?? item["Relevant Context"])
            )
        }.uniqued(by: { WikiEntityResolver.normalize($0.name) + "|" + $0.category })
        return (entities, result.trace.estimatedInputTokens, result.trace.estimatedOutputTokens)
    }

    private func extractTopics(
        meetingText: String,
        onProgress: @MainActor @escaping (GeneratedWikiProgress) -> Void
    ) async throws -> (topics: [Topic], inputTokens: Int, outputTokens: Int) {
        let system = """
        /no_think
        You extract meeting topics and insights. Output only valid JSON. No markdown. No prose. No thinking text.

        Focus on what was actually discussed, not named entity extraction.
        Prefer concrete business/investment themes over generic labels.
        """
        let user = """
        Return a JSON array. Each item must have exactly these keys:

        [
          {
            "topic": "",
            "description": "",
            "insights": ["", ""],
            "related_entities": [""]
          }
        ]

        Rules:
        - Extract 4-8 major topics discussed in the meeting.
        - A topic should be a theme, market observation, decision area, strategy, or important discussion thread.
        - Do not make this a list of people or companies.
        - Include people/companies only in related_entities when they help explain the topic.
        - Insights should be specific takeaways, not summaries.
        - Use the Summary section when present, then use the transcript for additional nuance.
        - Preserve distinctive phrases from the meeting.
        - Output only the JSON array.

        Meeting text:
        \(meetingText)
        """
        onProgress(.functionStarted(name: "Extract topics and insights", system: system, user: user))
        let result = try await llm.completeJSONArrayWithTrace(system: system, user: user) { token in
            onProgress(.token(token))
        }
        onProgress(.functionFinished(
            name: "Extract topics and insights",
            output: result.trace.text,
            inputTokens: result.trace.estimatedInputTokens,
            outputTokens: result.trace.estimatedOutputTokens
        ))
        let topics: [Topic] = result.array.compactMap { (item: [String: Any]) -> Topic? in
            let topic = MeetingCardJSON.string(item["topic"] ?? item["Topic"])
            guard !topic.isEmpty else { return nil }
            return Topic(
                topic: topic,
                description: MeetingCardJSON.string(item["description"] ?? item["Topic Description"]),
                insights: MeetingCardJSON.stringList(item["insights"] ?? item["Insights"]),
                relatedEntities: MeetingCardJSON.stringList(item["related_entities"] ?? item["Related Entities"])
            )
        }.uniqued(by: { WikiEntityResolver.normalize($0.topic) })
        return (topics, result.trace.estimatedInputTokens, result.trace.estimatedOutputTokens)
    }

    private func ensureWikiRoot() throws {
        let root = GeneratedWikiPaths.root(in: archiveRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for dir in ["meetings", "people", "companies", "concepts", ".wiki"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir, isDirectory: true), withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
            _ = runGit(["init"], in: root)
            _ = runGit(["config", "user.name", "GhostPepper Wiki"], in: root)
            _ = runGit(["config", "user.email", "wiki@ghostpepper.local"], in: root)
        }
    }

    private func writeMeetingOverview(title: String, date: String, meetingPath: String, entities: [Entity], topics: [Topic]) throws -> URL {
        let url = GeneratedWikiPaths.meetingOverviewURL(in: archiveRoot, meetingPath: meetingPath, title: title)
        var body = "# \(title)\n\n"
        body += "> Generated meeting overview. Source of truth: `\(meetingPath)`.\n\n"
        body += "## Topics Discussed\n\n"
        body += topics.isEmpty ? "(none)\n\n" : topics.map { "- [[\($0.topic)]] — \($0.description)" }.joined(separator: "\n") + "\n\n"
        body += "## Entities\n\n"
        body += entities.isEmpty ? "(none)\n\n" : entities.map { entity in
            let roleText = entity.roles.isEmpty ? "" : "; roles: \(entity.roles.joined(separator: ", "))"
            return "- [[\(entity.name)]] — \(entity.type)\(roleText); \(entity.context)"
        }.joined(separator: "\n") + "\n\n"
        body += "## Insights\n\n"
        let insights = topics.flatMap { topic in topic.insights.map { "- **[[\(topic.topic)]]:** \($0)" } }
        body += insights.isEmpty ? "(none)\n" : insights.joined(separator: "\n") + "\n"
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
        let canonicalTopic = canonicalName(for: topic.topic, category: "concepts") ?? topic.topic
        let url = GeneratedWikiPaths.pageURL(in: archiveRoot, category: "concepts", name: canonicalTopic)
        var insights = existingBullets(in: url, section: "Insights")
        for insight in topic.insights {
            insights.insert("- [[\(meetingOverviewTitle)]] — \(insight)")
        }
        var related = existingBullets(in: url, section: "Related Entities")
        for entity in topic.relatedEntities where !entity.isEmpty {
            related.insert("- [[\(entity)]]")
        }
        var discussed = existingBullets(in: url, section: "Discussed In")
        discussed.insert("- [[\(meetingOverviewTitle)]]")

        var body = "# \(canonicalTopic)\n\n"
        body += "## Summary\n\n"
        body += topic.description.isEmpty ? (existingSection(in: url, section: "Summary") ?? "\(canonicalTopic) was discussed in [[\(meetingOverviewTitle)]].\n") : topic.description + "\n"
        var aliases = existingBullets(in: url, section: "Aliases")
        if canonicalTopic != topic.topic {
            aliases.insert("- \(topic.topic)")
        }
        if !aliases.isEmpty {
            body += "\n## Aliases\n\n\(aliases.sorted().joined(separator: "\n"))\n"
        }
        body += "\n## Insights\n\n\(insights.sorted().joined(separator: "\n"))\n\n"
        body += "## Related Entities\n\n\(related.isEmpty ? "(none)" : related.sorted().joined(separator: "\n"))\n\n"
        body += "## Discussed In\n\n\(discussed.sorted().joined(separator: "\n"))\n\n"
        body += "## Source Meetings\n\n"
        var sources = existingBullets(in: url, section: "Source Meetings")
        sources.insert("- `\(meetingPath)`")
        body += sources.sorted().joined(separator: "\n") + "\n"
        try writePage(url: url, type: "concept", name: topic.topic, extraFrontmatter: [:], body: body)
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
        guard let canonical = canonicalName(for: topic.topic, category: "concepts"),
              canonical != topic.topic else {
            return topic
        }
        var updated = topic
        updated.topic = canonical
        return updated
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

    private func writePage(url: URL, type: String, name: String, extraFrontmatter: [String: String], body: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        var text = "---\n"
        text += "type: \(type)\n"
        text += "name: \(yaml(name))\n"
        text += "updated_at: \(now)\n"
        text += "generated_by_model: \(yaml(modelKind.rawValue))\n"
        for (key, value) in extraFrontmatter.sorted(by: { $0.key < $1.key }) {
            text += "\(key): \(yaml(value))\n"
        }
        text += "---\n\n"
        text += body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
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
