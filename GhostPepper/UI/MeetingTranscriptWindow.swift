import AppKit
import Combine
import SwiftUI
import WebKit
import os.log

/// A single turn in the bottom-bar Q&A thread. Created when the user hits
/// send; the answer streams in over the lifetime of the agent run.
struct QATurn: Identifiable, Equatable {
    let id = UUID()
    let question: String
    var answer: String = ""
    var usage: QAUsage? = nil
    var isStreaming: Bool = true
}

/// What we hand back to AppState's onAskQuestion so the agent can use it as
/// conversation history. Kept UI-friendly (plain strings) — the backend
/// converts to LLMMessage.
struct QAHistoryTurn: Equatable {
    let question: String
    let answer: String
}

struct ScopedQAPrompt: Equatable {
    let displayQuestion: String
    let agentQuestion: String
}

private struct WikiGenerationFunctionRun: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var system: String
    var user: String
    var output: String = ""
    var modelStatus: String = "Preparing local model"
    var modelStatusInputTokens: Int? = nil
    var modelStatusStartedAt: Date? = nil
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var startedAt: Date = Date()
    var firstTokenAt: Date? = nil
    var finishedAt: Date? = nil
    var isFinished: Bool = false
}

private struct SecondBrainLintProposal: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case merge = "Merge"
    }

    let id = UUID()
    var kind: Kind
    var category: String
    var sourceTitle: String
    var sourceURL: URL
    var targetTitle: String
    var targetURL: URL
    var reason: String
    var confidence: String
    var accepted: Bool = true

    var categoryLabel: String {
        switch category {
        case "people": return "People"
        case "companies": return "Companies"
        case "concepts": return "Concepts"
        case "topics": return "Topics"
        case "claims": return "Claims"
        case "meetings": return "Meeting Overviews"
        default: return category.capitalized
        }
    }
}

@MainActor
private final class SecondBrainLintRun: ObservableObject, Identifiable {
    let id = UUID()
    let archiveRoot: URL

    @Published var status: String = "Preparing lint pass"
    @Published var trace: String = ""
    @Published var proposals: [SecondBrainLintProposal] = []
    @Published var scannedPages: Int = 0
    @Published var totalPages: Int = 0
    @Published var appliedChanges: Int = 0
    @Published var isRunning: Bool = true
    @Published var errorMessage: String? = nil
    @Published var resultMessage: String? = nil

    init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot
    }

    var progressFraction: Double {
        if !isRunning { return errorMessage == nil ? 1 : 0 }
        guard totalPages > 0 else { return 0.05 }
        return min(0.98, Double(scannedPages) / Double(totalPages))
    }

    var acceptedCount: Int {
        proposals.filter(\.accepted).count
    }

    func appendTrace(_ line: String) {
        trace += trace.isEmpty ? line : "\n\(line)"
    }

    func setProposalAccepted(_ proposal: SecondBrainLintProposal, accepted: Bool) {
        guard let index = proposals.firstIndex(where: { $0.id == proposal.id }) else { return }
        proposals[index].accepted = accepted
    }

    func finish(result: String) {
        resultMessage = result
        status = result
        isRunning = false
    }

    func fail(_ message: String) {
        errorMessage = message
        status = message
        isRunning = false
    }
}

private enum SecondBrainLintEngine {
    private struct LintPage {
        var url: URL
        var relativePath: String
        var category: String
        var title: String
        var body: String
        var userEdited: Bool
        var updatedAt: Date?
    }

    static func collectProposals(
        archiveRoot: URL,
        onProgress: @MainActor @escaping (_ status: String, _ scanned: Int, _ total: Int, _ traceLine: String?) -> Void
    ) async -> [SecondBrainLintProposal] {
        let pages = generatedPages(in: archiveRoot)
        await onProgress("Scanning generated 2nd Brain pages", 0, pages.count, "[scope] generated pages only; source meetings excluded")

        var proposals: [SecondBrainLintProposal] = []
        let grouped = Dictionary(grouping: pages, by: \.category)
        var scanned = 0
        for category in ["people", "companies", "concepts", "topics", "claims", "meetings"] {
            let categoryPages = grouped[category] ?? []
            for page in categoryPages {
                scanned += 1
                await onProgress(
                    "Checking \(displayCategory(category))",
                    scanned,
                    pages.count,
                    "[scan] \(page.relativePath)"
                )
            }

            for proposal in mergeProposals(for: categoryPages, category: category) {
                if !proposals.contains(where: { existing in
                    existing.sourceURL == proposal.sourceURL && existing.targetURL == proposal.targetURL
                }) {
                    proposals.append(proposal)
                    await onProgress(
                        "Found possible \(displayCategory(category).lowercased()) merge",
                        scanned,
                        pages.count,
                        "[proposal] \(proposal.sourceTitle) -> \(proposal.targetTitle): \(proposal.reason)"
                    )
                }
            }
        }

        await onProgress(
            proposals.isEmpty ? "No merge proposals found" : "Review \(proposals.count) proposed change\(proposals.count == 1 ? "" : "s")",
            pages.count,
            pages.count,
            "[result] \(proposals.count) proposed lint change\(proposals.count == 1 ? "" : "s")"
        )
        return proposals
    }

    static func applyAcceptedProposals(_ proposals: [SecondBrainLintProposal], archiveRoot: URL) throws -> Int {
        var applied = 0
        for proposal in proposals where proposal.accepted {
            guard FileManager.default.fileExists(atPath: proposal.sourceURL.path),
                  FileManager.default.fileExists(atPath: proposal.targetURL.path) else {
                continue
            }
            try merge(proposal, archiveRoot: archiveRoot)
            applied += 1
        }
        return applied
    }

    private static func generatedPages(in archiveRoot: URL) -> [LintPage] {
        let root = GeneratedWikiPaths.root(in: archiveRoot)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var pages: [LintPage] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let page = try? GeneratedWikiPaths.readPage(from: url),
                  let relativePath = relativePath(of: url, in: archiveRoot) else {
                continue
            }
            let category = url.deletingLastPathComponent().lastPathComponent
            pages.append(LintPage(
                url: url,
                relativePath: relativePath,
                category: category,
                title: page.title,
                body: page.body,
                userEdited: page.userEdited,
                updatedAt: page.updatedAt
            ))
        }
        return pages.sorted {
            if $0.category == $1.category { return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return $0.category < $1.category
        }
    }

    private static func mergeProposals(for pages: [LintPage], category: String) -> [SecondBrainLintProposal] {
        guard pages.count > 1 else { return [] }
        var proposals: [SecondBrainLintProposal] = []
        for i in pages.indices {
            for j in pages.indices where j > i {
                guard let match = matchReason(lhs: pages[i], rhs: pages[j], category: category) else { continue }
                let target = preferredTarget(pages[i], pages[j])
                let source = target.url == pages[i].url ? pages[j] : pages[i]
                proposals.append(SecondBrainLintProposal(
                    kind: .merge,
                    category: category,
                    sourceTitle: source.title,
                    sourceURL: source.url,
                    targetTitle: target.title,
                    targetURL: target.url,
                    reason: match.reason,
                    confidence: match.confidence,
                    accepted: match.confidence != "low"
                ))
            }
        }
        return proposals
            .sorted {
                if confidenceRank($0.confidence) == confidenceRank($1.confidence) {
                    return $0.sourceTitle.localizedCaseInsensitiveCompare($1.sourceTitle) == .orderedAscending
                }
                return confidenceRank($0.confidence) > confidenceRank($1.confidence)
            }
    }

    private static func matchReason(lhs: LintPage, rhs: LintPage, category: String) -> (reason: String, confidence: String)? {
        let left = WikiEntityResolver.normalize(lhs.title)
        let right = WikiEntityResolver.normalize(rhs.title)
        guard !left.isEmpty, !right.isEmpty, left != right || lhs.url != rhs.url else { return nil }

        let leftTokens = Set(tokens(left))
        let rightTokens = Set(tokens(right))
        let overlap = leftTokens.intersection(rightTokens)
        let shorterCount = max(1, min(leftTokens.count, rightTokens.count))
        let overlapRatio = Double(overlap.count) / Double(shorterCount)

        if left == right {
            return ("Exact normalized title match.", "high")
        }

        if category == "meetings", overlap.count >= 3, overlapRatio >= 0.75 {
            return ("Meeting titles share \(overlap.count) meaningful tokens.", overlapRatio >= 0.9 ? "high" : "medium")
        }

        if leftTokens.count == 1 || rightTokens.count == 1 {
            let longer = left.count >= right.count ? left : right
            let shorter = left.count < right.count ? left : right
            if shorter.count >= 6, longer.contains(shorter) {
                return ("One title contains the other title.", "medium")
            }
            if shorter.count >= 6, abs(left.count - right.count) <= 2, WikiEntityResolver.editDistance(left, right) <= 2 {
                return ("Close spelling match: edit distance \(WikiEntityResolver.editDistance(left, right)).", "medium")
            }
            return nil
        }

        if overlap.count >= 2, overlapRatio >= 0.75 {
            return ("Shares \(overlap.count) meaningful title tokens: \(overlap.sorted().joined(separator: ", ")).", overlapRatio >= 0.95 ? "high" : "medium")
        }

        let distance = WikiEntityResolver.editDistance(left, right)
        if min(left.count, right.count) >= 8, abs(left.count - right.count) <= 3, distance <= 2 {
            return ("Close spelling match: edit distance \(distance).", "medium")
        }

        return nil
    }

    private static func preferredTarget(_ lhs: LintPage, _ rhs: LintPage) -> LintPage {
        if lhs.userEdited != rhs.userEdited { return lhs.userEdited ? lhs : rhs }
        let lhsTokens = tokens(WikiEntityResolver.normalize(lhs.title)).count
        let rhsTokens = tokens(WikiEntityResolver.normalize(rhs.title)).count
        if lhsTokens != rhsTokens { return lhsTokens > rhsTokens ? lhs : rhs }
        if lhs.body.count != rhs.body.count { return lhs.body.count > rhs.body.count ? lhs : rhs }
        return (lhs.updatedAt ?? .distantPast) >= (rhs.updatedAt ?? .distantPast) ? lhs : rhs
    }

    private static func merge(_ proposal: SecondBrainLintProposal, archiveRoot: URL) throws {
        let sourceBefore = try String(contentsOf: proposal.sourceURL, encoding: .utf8)
        let targetBefore = try String(contentsOf: proposal.targetURL, encoding: .utf8)
        let sourcePage = try GeneratedWikiPaths.readPage(from: proposal.sourceURL)
        let targetPage = try GeneratedWikiPaths.readPage(from: proposal.targetURL)
        let mergedBody = mergedBody(target: targetPage.body, source: sourcePage.body, sourceTitle: sourcePage.title)
        let targetAfter = replaceBody(in: targetBefore, with: mergedBody)
        try targetAfter.write(to: proposal.targetURL, atomically: true, encoding: .utf8)
        GhostPepperHistoryStore.recordFileChange(
            archiveRoot: archiveRoot,
            fileURL: proposal.targetURL,
            actor: .user,
            operation: "lint_merge_target_update",
            summary: "Merged \(proposal.sourceTitle) into \(proposal.targetTitle).",
            before: targetBefore,
            after: targetAfter,
            metadata: metadata(for: proposal)
        )

        let wikiURLs = generatedPages(in: archiveRoot).map(\.url)
        for url in wikiURLs where url != proposal.sourceURL {
            guard let before = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let after = rewriteLinks(in: before, from: proposal.sourceTitle, to: proposal.targetTitle)
            guard before != after else { continue }
            try after.write(to: url, atomically: true, encoding: .utf8)
            GhostPepperHistoryStore.recordFileChange(
                archiveRoot: archiveRoot,
                fileURL: url,
                actor: .user,
                operation: "lint_rewrite_wikilinks",
                summary: "Rewrote links from \(proposal.sourceTitle) to \(proposal.targetTitle).",
                before: before,
                after: after,
                metadata: metadata(for: proposal)
            )
        }

        try FileManager.default.removeItem(at: proposal.sourceURL)
        GhostPepperHistoryStore.recordFileChange(
            archiveRoot: archiveRoot,
            fileURL: proposal.sourceURL,
            actor: .user,
            operation: "lint_remove_merged_page",
            summary: "Removed merged duplicate page \(proposal.sourceTitle).",
            before: sourceBefore,
            after: nil,
            metadata: metadata(for: proposal)
        )
        GhostPepperHistoryStore.recordEvent(
            archiveRoot: archiveRoot,
            actor: .user,
            operation: "lint_merge_decision",
            summary: "Accepted lint merge: \(proposal.sourceTitle) -> \(proposal.targetTitle).",
            relativePath: relativePath(of: proposal.targetURL, in: archiveRoot) ?? "wikis",
            metadata: metadata(for: proposal)
        )
    }

    private static func mergedBody(target: String, source: String, sourceTitle: String) -> String {
        var body = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceBody = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceBody.isEmpty, !body.contains("Merged from \(sourceTitle)") else {
            return body + "\n"
        }
        body += "\n\n## Merged From\n\n"
        body += "- \(sourceTitle)\n\n"
        body += sourceBody
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("# ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        body += "\n"
        return body
    }

    private static func replaceBody(in frontmatterText: String, with body: String) -> String {
        guard frontmatterText.hasPrefix("---\n"),
              let close = frontmatterText.dropFirst(4).range(of: "\n---\n") else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        let frontmatter = String(frontmatterText[..<close.upperBound])
        return frontmatter + "\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func rewriteLinks(in text: String, from sourceTitle: String, to targetTitle: String) -> String {
        let sourceSlug = MarkdownArchivePaths.slugForIndexEntry(sourceTitle)
        let targetSlug = MarkdownArchivePaths.slugForIndexEntry(targetTitle)
        return text
            .replacingOccurrences(of: "[[\(sourceTitle)]]", with: "[[\(targetTitle)]]")
            .replacingOccurrences(of: "(\(sourceSlug).md)", with: "(\(targetSlug).md)")
            .replacingOccurrences(of: "](\(sourceSlug).md)", with: "](\(targetSlug).md)")
    }

    private static func tokens(_ normalized: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "and", "for", "with", "from", "into", "call", "meeting", "overview",
            "brain", "note", "notes", "matt", "hartman"
        ]
        return normalized
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    private static func displayCategory(_ category: String) -> String {
        switch category {
        case "people": return "people"
        case "companies": return "companies"
        case "concepts": return "concepts"
        case "topics": return "topics"
        case "claims": return "claims"
        case "meetings": return "meeting overviews"
        default: return category
        }
    }

    private static func confidenceRank(_ confidence: String) -> Int {
        switch confidence {
        case "high": return 3
        case "medium": return 2
        default: return 1
        }
    }

    private static func metadata(for proposal: SecondBrainLintProposal) -> [String: String] {
        [
            "category": proposal.category,
            "source_title": proposal.sourceTitle,
            "target_title": proposal.targetTitle,
            "reason": proposal.reason,
            "confidence": proposal.confidence,
            "proposed_action": "merge",
            "final_action": "merge"
        ]
    }

    private static func relativePath(of url: URL, in root: URL) -> String? {
        let base = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(base) else { return nil }
        var rel = String(full.dropFirst(base.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }
}

@MainActor
private final class WikiGenerationRun: ObservableObject, Identifiable {
    let id = UUID()
    let meetingURL: URL
    let archiveRoot: URL
    let meetingTitle: String
    let modelCallTotal: Int
    let isBatch: Bool

    @Published var status: String = "Adding to 2nd Brain..."
    @Published var functions: [WikiGenerationFunctionRun] = []
    @Published var selectedFunctionID: UUID? = nil
    @Published var savedRelativePaths: [String] = []
    @Published var result: GeneratedWikiResult? = nil
    @Published var errorMessage: String? = nil
    @Published var isRunning: Bool = true
    @Published var modelCallsCompleted: Int = 0
    @Published var estimatedInputTokens: Int = 0
    @Published var estimatedOutputTokens: Int = 0
    @Published var totalSourceCount: Int = 1
    @Published var completedSourceCount: Int = 0
    @Published var currentSourceIndex: Int = 0
    @Published var currentSourceTitle: String = ""
    @Published var nextSourceTitle: String? = nil
    @Published var nextSourceStatus: String? = nil
    @Published var nextSourceInputTokens: Int? = nil
    @Published var nextSourceTerminalText: String = ""
    @Published var nextSourceReviewDraft: GeneratedWikiReviewDraft? = nil
    @Published var nextSourceFailed: Bool = false
    @Published var isWaitingForPreparedSource: Bool = false
    @Published var failedSourceSummaries: [String] = []
    @Published var reviewDraft: GeneratedWikiReviewDraft? = nil
    @Published var reviewEntityDecisions: [UUID: GeneratedWikiEntityReviewDecision] = [:]
    @Published var reviewTopicDecisions: [UUID: GeneratedWikiTopicReviewDecision] = [:]
    @Published var reviewClaimDecisions: [UUID: GeneratedWikiClaimReviewDecision] = [:]

    private var completedInputTokens: Int = 0
    private var completedOutputTokens: Int = 0
    private var currentInputTokenEstimate: Int = 0
    private var reviewContinuation: CheckedContinuation<GeneratedWikiReviewDecision, Never>?
    private var nextSourcePreloadTask: Task<Void, Never>? = nil
    private var nextSourcePreloadURL: URL? = nil
    private var nextSourceReviewContinuation: CheckedContinuation<GeneratedWikiReviewDecision, Never>?

    init(meetingURL: URL, archiveRoot: URL, modelCallTotal: Int = 1) {
        self.meetingURL = meetingURL
        self.archiveRoot = archiveRoot
        self.meetingTitle = meetingURL.deletingPathExtension().lastPathComponent
        self.modelCallTotal = modelCallTotal
        self.isBatch = false
        self.currentSourceTitle = self.meetingTitle
    }

    init(batchTitle: String, archiveRoot: URL, sourceCount: Int, modelCallTotal: Int) {
        self.meetingURL = archiveRoot
        self.archiveRoot = archiveRoot
        self.meetingTitle = batchTitle
        self.modelCallTotal = modelCallTotal
        self.isBatch = true
        self.totalSourceCount = max(1, sourceCount)
        self.currentSourceTitle = batchTitle
    }

    var isFinished: Bool {
        result != nil || errorMessage != nil || !isRunning
    }

    var progressFraction: Double {
        if result != nil { return 1 }
        guard isRunning else { return errorMessage == nil ? 1 : 0 }
        if isBatch {
            let sourceBase = Double(completedSourceCount) / Double(max(1, totalSourceCount))
            let activeSourceSpan = 1.0 / Double(max(1, totalSourceCount))
            return min(0.98, sourceBase + activeSourceSpan * currentSourceProgressFraction)
        }
        guard modelCallTotal > 0 else { return 0.1 }
        return min(0.98, (Double(modelCallsCompleted) + currentCallProgressFraction) / Double(modelCallTotal))
    }

    var selectedFunction: WikiGenerationFunctionRun? {
        if let selectedFunctionID,
           let selected = functions.first(where: { $0.id == selectedFunctionID }) {
            return selected
        }
        return functions.last
    }

    var activeOutputTokenEstimate: Int {
        guard let selectedFunction else { return 0 }
        if selectedFunction.isFinished { return selectedFunction.outputTokens }
        let output = selectedFunction.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty
            ? 0
            : LocalStructuredLLM.estimatedTokenCount(output)
    }

    var currentCallProgressFraction: Double {
        guard let selectedFunction else { return 0.08 }
        if selectedFunction.isFinished { return 1 }
        if selectedFunction.output.isEmpty { return 0.12 }
        return min(0.85, 0.18 + Double(activeOutputTokenEstimate) / 1200.0)
    }

    var currentSourceProgressFraction: Double {
        guard isRunning else { return 1 }
        guard modelCallTotal > 0 else { return currentCallProgressFraction }
        let callsPerSource = max(1, modelCallTotal / max(1, totalSourceCount))
        let completedCallsForCurrentSource = modelCallsCompleted % callsPerSource
        return min(0.95, (Double(completedCallsForCurrentSource) + currentCallProgressFraction) / Double(callsPerSource))
    }

    var terminalText: String {
        if isWaitingForPreparedSource,
           !nextSourceTerminalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nextSourceTerminalText
        }
        guard let selectedFunction else {
            return """
            [status] Preparing 2nd Brain run
            [sources] \(completedSourceCount)/\(totalSourceCount) complete
            [model] Waiting for the local model...
            """
        }
        let output = selectedFunction.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            let modelLine = selectedFunction.modelStatus.isEmpty
                ? "Prompt sent; waiting for the first output token..."
                : selectedFunction.modelStatus
            let activeInputTokens = max(selectedFunction.inputTokens, selectedFunction.modelStatusInputTokens ?? 0)
            return """
            [status] \(status)
            [source] \(currentSourceTitle)
            [sources] \(completedSourceCount)/\(totalSourceCount) complete
            [step] \(selectedFunction.name)
            [input] ~\(activeInputTokens) input tokens prepared
            [model] \(modelLine)
            """
        }
        return output
    }

    func beginSource(_ url: URL, index: Int, total: Int) {
        totalSourceCount = max(1, total)
        currentSourceIndex = index
        currentSourceTitle = url.deletingPathExtension().lastPathComponent
        status = "Adding \(index) of \(total): \(currentSourceTitle)"
    }

    func sourceFinished() {
        completedSourceCount += 1
    }

    func prepareNextSource(_ url: URL?) {
        nextSourcePreloadTask?.cancel()
        nextSourcePreloadTask = nil
        nextSourcePreloadURL = url
        guard let url else {
            nextSourceTitle = nil
            nextSourceStatus = nil
            nextSourceInputTokens = nil
            nextSourceTerminalText = ""
            nextSourceReviewDraft = nil
            nextSourceFailed = false
            isWaitingForPreparedSource = false
            nextSourceReviewContinuation = nil
            return
        }

        nextSourceTitle = url.deletingPathExtension().lastPathComponent
        nextSourceStatus = "Queued for background model run"
        nextSourceInputTokens = nil
        nextSourceTerminalText = "[queue] waiting for model slot"
        nextSourceReviewDraft = nil
        nextSourceFailed = false
        isWaitingForPreparedSource = false

        let expectedURL = url
        nextSourcePreloadTask = Task.detached(priority: .utility) { [weak self] in
            await MainActor.run {
                guard self?.nextSourcePreloadURL == expectedURL else { return }
                self?.nextSourceStatus = "Reading source file"
            }
            guard !Task.isCancelled else { return }
            let text = (try? String(contentsOf: expectedURL, encoding: .utf8)) ?? ""
            let tokens = max(1, text.count / 4)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.nextSourcePreloadURL == expectedURL else { return }
                self?.nextSourceInputTokens = tokens
                self?.nextSourceStatus = "Source loaded: ~\(tokens.formatted()) input tokens"
                self?.nextSourceTerminalText = """
                [load] source file read
                [input] ~\(tokens.formatted()) tokens prepared
                [model] queued for extraction
                """
            }
        }
    }

    func handleNextProgress(_ progress: GeneratedWikiProgress, for url: URL) {
        guard nextSourcePreloadURL == url else { return }
        switch progress {
        case .status(let message):
            nextSourceStatus = message
            appendNextTerminal("[status] \(message)")
        case .modelStatus(let message):
            nextSourceStatus = message
            if let tokens = Self.inputTokenCount(fromModelStatus: message) {
                nextSourceInputTokens = max(nextSourceInputTokens ?? 0, tokens)
            }
            appendNextTerminal("[model] \(message)")
        case .functionStarted(let name, let system, let user):
            let tokens = max(1, (system.count + user.count) / 4)
            nextSourceInputTokens = max(nextSourceInputTokens ?? 0, tokens)
            nextSourceStatus = "Running \(name)"
            nextSourceTerminalText = """
            [next] \(url.deletingPathExtension().lastPathComponent)
            [step] \(name)
            [input] ~\(tokens.formatted()) tokens prepared
            [model] loading prompt context
            """
        case .token(let token):
            nextSourceStatus = "Streaming extraction"
            appendNextTerminal(token, trimTo: 900)
        case .functionFinished(let name, let output, let inputTokens, let outputTokens):
            nextSourceInputTokens = max(nextSourceInputTokens ?? 0, inputTokens)
            nextSourceStatus = "\(name) complete"
            nextSourceTerminalText = """
            [done] \(name)
            [usage] \(inputTokens.formatted()) in / \(outputTokens.formatted()) out

            \(String(output.suffix(650)))
            """
        case .saved(let url):
            nextSourceStatus = "Saved \(url.lastPathComponent)"
            appendNextTerminal("[saved] \(url.lastPathComponent)")
        }
    }

    func requestNextReview(_ draft: GeneratedWikiReviewDraft, for url: URL) async -> GeneratedWikiReviewDecision {
        await withCheckedContinuation { continuation in
            guard nextSourcePreloadURL == url else {
                continuation.resume(returning: .discardAll(for: draft))
                return
            }
            nextSourceReviewDraft = draft
            nextSourceStatus = "Ready for entity approval"
            appendNextTerminal("[ready] \(draft.entities.count) entities, \(draft.topics.count) topics, \(draft.claimCount) claims")
            nextSourceReviewContinuation = continuation
        }
    }

    func failNextSource(_ url: URL, error: Error) {
        guard nextSourcePreloadURL == url else { return }
        nextSourceFailed = true
        nextSourceStatus = "Failed: \(error.localizedDescription)"
        appendNextTerminal("[failed] \(error.localizedDescription)")
    }

    func promoteNextReviewToCurrent(url: URL, index: Int, total: Int) -> Bool {
        guard nextSourcePreloadURL == url,
              let draft = nextSourceReviewDraft,
              let continuation = nextSourceReviewContinuation else {
            return false
        }
        beginSource(url, index: index, total: total)
        installReviewDraft(draft, continuation: continuation)
        nextSourceTitle = nil
        nextSourceStatus = nil
        nextSourceInputTokens = nil
        nextSourceTerminalText = ""
        nextSourceReviewDraft = nil
        nextSourceFailed = false
        isWaitingForPreparedSource = false
        nextSourceReviewContinuation = nil
        nextSourcePreloadURL = nil
        nextSourcePreloadTask?.cancel()
        nextSourcePreloadTask = nil
        return true
    }

    func waitForPreparedSourceReview(_ isWaiting: Bool) {
        isWaitingForPreparedSource = isWaiting
    }

    private func appendNextTerminal(_ text: String, trimTo limit: Int = 1200) {
        if nextSourceTerminalText.isEmpty {
            nextSourceTerminalText = text
        } else {
            nextSourceTerminalText += text.hasPrefix("[") ? "\n\(text)" : text
        }
        if nextSourceTerminalText.count > limit {
            nextSourceTerminalText = "...\n" + String(nextSourceTerminalText.suffix(limit))
        }
    }

    func sourceFailed(_ url: URL, error: Error) {
        completedSourceCount += 1
        failedSourceSummaries.append("\(url.lastPathComponent): \(error.localizedDescription)")
        status = "Skipped \(url.deletingPathExtension().lastPathComponent): \(error.localizedDescription)"
    }

    func handle(_ progress: GeneratedWikiProgress) {
        switch progress {
        case .status(let message):
            status = message
        case .modelStatus(let message):
            status = message
            if let idx = functions.indices.last, !functions[idx].isFinished {
                functions[idx].modelStatus = message
                if functions[idx].modelStatusStartedAt == nil {
                    functions[idx].modelStatusStartedAt = Date()
                }
                if let statusInputTokens = Self.inputTokenCount(fromModelStatus: message) {
                    functions[idx].modelStatusInputTokens = max(functions[idx].modelStatusInputTokens ?? 0, statusInputTokens)
                }
            }
        case .functionStarted(let name, let system, let user):
            status = name
            currentInputTokenEstimate = max(1, (system.count + user.count) / 4)
            estimatedInputTokens = completedInputTokens + currentInputTokenEstimate
            estimatedOutputTokens = completedOutputTokens
            let run = WikiGenerationFunctionRun(
                name: name,
                system: system,
                user: user,
                modelStatus: "Preparing local model",
                modelStatusStartedAt: Date(),
                inputTokens: currentInputTokenEstimate,
                outputTokens: 0,
                startedAt: Date(),
                isFinished: false
            )
            functions.append(run)
            selectedFunctionID = run.id
        case .token(let token):
            guard let idx = functions.indices.last else { return }
            if functions[idx].firstTokenAt == nil {
                functions[idx].firstTokenAt = Date()
                functions[idx].modelStatus = "Streaming local model output"
            }
            functions[idx].output += token
            estimatedOutputTokens = completedOutputTokens + LocalStructuredLLM.estimatedTokenCount(functions[idx].output)
        case .functionFinished(let name, let output, let inputTokens, let outputTokens):
            status = "\(name) complete"
            if let idx = functions.lastIndex(where: { $0.name == name && !$0.isFinished }) ?? functions.indices.last {
                functions[idx].output = output
                functions[idx].inputTokens = inputTokens
                functions[idx].outputTokens = outputTokens
                functions[idx].isFinished = true
                functions[idx].finishedAt = Date()
                selectedFunctionID = functions[idx].id
            }
            completedInputTokens += inputTokens
            completedOutputTokens += outputTokens
            currentInputTokenEstimate = 0
            estimatedInputTokens = completedInputTokens
            estimatedOutputTokens = completedOutputTokens
            modelCallsCompleted += 1
        case .saved(let url):
            let relative = url.path.replacingOccurrences(of: archiveRoot.path + "/", with: "")
            if !savedRelativePaths.contains(relative) {
                savedRelativePaths.append(relative)
            }
            status = "Saved \(relative)"
        }
    }

    func requestReview(_ draft: GeneratedWikiReviewDraft) async -> GeneratedWikiReviewDecision {
        await withCheckedContinuation { continuation in
            installReviewDraft(draft, continuation: continuation)
        }
    }

    private func installReviewDraft(
        _ draft: GeneratedWikiReviewDraft,
        continuation: CheckedContinuation<GeneratedWikiReviewDecision, Never>
    ) {
        reviewDraft = draft
        reviewEntityDecisions = Dictionary(
            uniqueKeysWithValues: draft.entities.map {
                ($0.id, GeneratedWikiEntityReviewDecision(keep: true, canonicalName: $0.defaultCanonicalName, proposedName: $0.name, type: $0.type))
            }
        )
        reviewClaimDecisions = Dictionary(
            uniqueKeysWithValues: draft.claims.map {
                ($0.id, GeneratedWikiClaimReviewDecision(
                    keep: true,
                    canonicalClaim: $0.indexCandidate ? ($0.suggestedCanonicalClaim ?? $0.suggestedMatches.first ?? $0.text) : nil,
                    text: $0.text
                ))
            }
        )
        reviewTopicDecisions = Self.defaultTopicDecisions(for: draft)
        reviewContinuation = continuation
        status = "Reviewing extracted entities, topics, and claims"
    }

    func setEntityDecision(_ entity: GeneratedWikiReviewEntityDraft, keep: Bool, canonicalName: String?) {
        let current = reviewEntityDecisions[entity.id]
        reviewEntityDecisions[entity.id] = GeneratedWikiEntityReviewDecision(
            keep: keep,
            canonicalName: canonicalName,
            proposedName: current?.proposedName ?? entity.name,
            type: current?.type ?? entity.type
        )
    }

    func setEntityProposedName(_ entity: GeneratedWikiReviewEntityDraft, proposedName: String) {
        let current = reviewEntityDecisions[entity.id]
        reviewEntityDecisions[entity.id] = GeneratedWikiEntityReviewDecision(
            keep: current?.keep ?? true,
            canonicalName: current?.canonicalName,
            proposedName: proposedName,
            type: current?.type ?? entity.type
        )
    }

    func setEntityType(_ entity: GeneratedWikiReviewEntityDraft, type: String) {
        let current = reviewEntityDecisions[entity.id]
        let oldType = current?.type ?? entity.type
        reviewEntityDecisions[entity.id] = GeneratedWikiEntityReviewDecision(
            keep: current?.keep ?? true,
            canonicalName: oldType == type ? (current?.canonicalName ?? entity.defaultCanonicalName) : nil,
            proposedName: current?.proposedName ?? entity.name,
            type: type
        )
    }

    func setTopicDecision(_ topic: GeneratedWikiReviewTopicDraft, keep: Bool, canonicalTopic: String?) {
        let current = reviewTopicDecisions[topic.id]
        reviewTopicDecisions[topic.id] = GeneratedWikiTopicReviewDecision(
            keep: keep,
            canonicalTopic: canonicalTopic,
            topic: current?.topic ?? topic.topic
        )
    }

    func setTopicTitle(_ topic: GeneratedWikiReviewTopicDraft, title: String) {
        let current = reviewTopicDecisions[topic.id]
        reviewTopicDecisions[topic.id] = GeneratedWikiTopicReviewDecision(
            keep: current?.keep ?? true,
            canonicalTopic: current?.canonicalTopic,
            topic: title
        )
    }

    func setClaimDecision(_ claim: GeneratedWikiReviewClaimDraft, keep: Bool, canonicalClaim: String?) {
        let current = reviewClaimDecisions[claim.id]
        reviewClaimDecisions[claim.id] = GeneratedWikiClaimReviewDecision(
            keep: keep,
            canonicalClaim: canonicalClaim,
            text: current?.text ?? claim.text
        )
    }

    func setClaimText(_ claim: GeneratedWikiReviewClaimDraft, text: String) {
        let current = reviewClaimDecisions[claim.id]
        reviewClaimDecisions[claim.id] = GeneratedWikiClaimReviewDecision(
            keep: current?.keep ?? true,
            canonicalClaim: current?.canonicalClaim,
            text: text
        )
    }

    func keepAllReviewItems() {
        guard let draft = reviewDraft else { return }
        reviewEntityDecisions = Dictionary(
            uniqueKeysWithValues: draft.entities.map {
                ($0.id, GeneratedWikiEntityReviewDecision(keep: true, canonicalName: $0.defaultCanonicalName, proposedName: $0.name, type: $0.type))
            }
        )
        reviewClaimDecisions = Dictionary(
            uniqueKeysWithValues: draft.claims.map {
                ($0.id, GeneratedWikiClaimReviewDecision(
                    keep: true,
                    canonicalClaim: $0.indexCandidate ? ($0.suggestedCanonicalClaim ?? $0.suggestedMatches.first ?? $0.text) : nil,
                    text: $0.text
                ))
            }
        )
        reviewTopicDecisions = Self.defaultTopicDecisions(for: draft)
    }

    func completeReview() {
        guard let draft = reviewDraft else { return }
        let decision = GeneratedWikiReviewDecision(
            entityDecisions: reviewEntityDecisions,
            topicDecisions: reviewTopicDecisions,
            claimDecisions: reviewClaimDecisions
        )
        reviewDraft = nil
        reviewEntityDecisions = [:]
        reviewTopicDecisions = [:]
        reviewClaimDecisions = [:]
        status = "Writing approved 2nd Brain pages"
        let continuation = reviewContinuation
        reviewContinuation = nil
        continuation?.resume(returning: decision)
        _ = draft
    }

    func cancelReviewIfNeeded() {
        guard let draft = reviewDraft else { return }
        reviewDraft = nil
        reviewEntityDecisions = [:]
        reviewTopicDecisions = [:]
        reviewClaimDecisions = [:]
        let continuation = reviewContinuation
        reviewContinuation = nil
        continuation?.resume(returning: .discardAll(for: draft))
    }

    private static func defaultTopicDecisions(for draft: GeneratedWikiReviewDraft) -> [UUID: GeneratedWikiTopicReviewDecision] {
        Dictionary(
            uniqueKeysWithValues: draft.topics.map {
                ($0.id, GeneratedWikiTopicReviewDecision(
                    keep: true,
                    canonicalTopic: $0.indexCandidate ? ($0.suggestedCanonicalTopic ?? $0.suggestedMatches.first ?? $0.topic) : nil,
                    topic: $0.topic
                ))
            }
        )
    }

    private static func inputTokenCount(fromModelStatus message: String) -> Int? {
        guard let range = message.range(of: #"~([0-9,]+) input tokens"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(message[range])
        let digits = matched.filter(\.isNumber)
        return Int(digits)
    }

    func finish(_ result: GeneratedWikiResult) {
        self.result = result
        if isBatch {
            let failed = failedSourceSummaries.isEmpty ? "" : " (\(failedSourceSummaries.count) failed)"
            self.status = "Added \(completedSourceCount) sources to 2nd Brain\(failed)"
        } else {
            self.status = "Added to 2nd Brain"
        }
        self.isRunning = false
        self.estimatedInputTokens = result.usage.inputTokens
        self.estimatedOutputTokens = result.usage.outputTokens
    }

    func fail(_ message: String) {
        self.errorMessage = message
        self.status = "Add to 2nd Brain failed"
        self.isRunning = false
        self.nextSourcePreloadTask?.cancel()
        self.nextSourcePreloadTask = nil
    }

    func fullDebugText() -> String {
        var lines: [String] = [
            "2nd Brain generation",
            isBatch ? "Batch: \(meetingTitle)" : "Meeting: \(meetingURL.path)",
            "Status: \(status)",
            "Sources: \(completedSourceCount)/\(totalSourceCount)",
            "Tokens: \(estimatedInputTokens) in / \(estimatedOutputTokens) out",
            ""
        ]
        if !failedSourceSummaries.isEmpty {
            lines.append("--- FAILURES ---")
            lines.append(contentsOf: failedSourceSummaries)
            lines.append("")
        }
        for function in functions {
            lines.append("## \(function.name)")
            lines.append("")
            lines.append("### System")
            lines.append(function.system)
            lines.append("")
            lines.append("### User")
            lines.append(function.user)
            lines.append("")
            lines.append("### Output")
            lines.append(function.output)
            lines.append("")
            lines.append("\(function.inputTokens) input tokens / \(function.outputTokens) output tokens")
            lines.append("")
        }
        if !savedRelativePaths.isEmpty {
            lines.append("## Saved")
            lines.append(contentsOf: savedRelativePaths)
        }
        if let result {
            lines.append("")
            lines.append(result.gitMessage)
        }
        if let errorMessage {
            lines.append("")
            lines.append("Error: \(errorMessage)")
        }
        return lines.joined(separator: "\n")
    }
}

enum MeetingTranscriptWindowPresentation {
    static func windowLevel(
        shouldFloatWhileRecording: Bool,
        hasActiveRecording: Bool
    ) -> NSWindow.Level {
        shouldFloatWhileRecording && hasActiveRecording ? .floating : .normal
    }
}

enum MeetingRecordingStartError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        }
    }
}

// MARK: - Window Controller

@MainActor
final class MeetingTranscriptWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onOpenSettings: (() -> Void)?
    var onStartRecording: ((_ name: String, _ detectedMeeting: DetectedMeeting?) throws -> MeetingSession)?
    var onStopRecording: ((MeetingSession) -> Void)?
    var onGenerateSummary: ((MeetingTranscript) -> Void)?
    var onLoadSpeakerReviewItems: ((MeetingTranscript) -> [MeetingSpeakerReviewItem])?
    var onUpdateSpeakerLabel: ((_ transcript: MeetingTranscript, _ currentDisplayName: String, _ newDisplayName: String) throws -> Void)?
    var onAskQuestion: ((_ question: String, _ history: [QAHistoryTurn]) -> AsyncThrowingStream<QAEvent, Error>)?
    var onMakeIndexBuilder: ((IndexKind) -> (any IndexBuilding)?)?
    var onGenerateWikiProposals: (() async throws -> [WikiKindProposal])?
    var onApproveWikiKind: ((WikiKindSpec) -> Void)?
    var onGenerateMeetingWiki: ((_ meetingURL: URL, _ onProgress: @MainActor @escaping (GeneratedWikiProgress) -> Void, _ review: @MainActor @escaping (GeneratedWikiReviewDraft) async -> GeneratedWikiReviewDecision) async throws -> GeneratedWikiResult)?
    var shouldFloatWhileRecording: () -> Bool = { false }
    var pushToTalkDisplayProvider: () -> String = { "" }

    /// Managers + download wrappers that the right-side Models panel needs to
    /// drive download/delete affordances. Set by AppState during controller
    /// construction; nil-tolerant so the panel still renders read-only if a
    /// caller forgets to wire them.
    var cleanupManager: TextCleanupManager?
    var modelManager: ModelManager?
    var usageStats: UsageStatsStore?
    var onDownloadSpeechModel: ((String) -> Void)?

    private(set) var windowState: MeetingWindowState?

    func show(session: MeetingSession? = nil) {
        if let window = window {
            // Add session as a tab if provided
            if let session = session, let state = windowState {
                state.addRecordingTab(session: session)
            }
            updateWindowLevel()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let state = MeetingWindowState()
        state.onOpenSettings = onOpenSettings
        state.onStartRecording = onStartRecording
        state.onStopRecording = onStopRecording
        state.onGenerateSummary = onGenerateSummary
        state.onLoadSpeakerReviewItems = onLoadSpeakerReviewItems
        state.onUpdateSpeakerLabel = onUpdateSpeakerLabel
        state.onAskQuestion = onAskQuestion
        state.onMakeIndexBuilder = onMakeIndexBuilder
        state.onGenerateWikiProposals = onGenerateWikiProposals
        state.onApproveWikiKind = onApproveWikiKind
        state.onGenerateMeetingWiki = onGenerateMeetingWiki
        state.pushToTalkDisplay = pushToTalkDisplayProvider()
        state.onRecordingStateChanged = { [weak self] in
            self?.updateWindowLevel()
        }
        windowState = state

        if let session = session {
            state.addRecordingTab(session: session)
        }

        guard let cleanupManager, let modelManager, let usageStats, let onDownloadSpeechModel else {
            assertionFailure("MeetingTranscriptWindowController missing manager dependencies")
            return
        }
        let view = MeetingRootView(
            state: state,
            cleanupManager: cleanupManager,
            modelManager: modelManager,
            usageStats: usageStats,
            onDownloadSpeechModel: onDownloadSpeechModel
        )

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 720, height: 900)
        let windowHeight = screenFrame.height
        // Default fits left sidebar (~220) + home content (~500) + right Models panel (~240) + dividers.
        let windowWidth: CGFloat = 960

        let window = NSWindow(
            contentRect: NSRect(x: screenFrame.midX - windowWidth / 2, y: screenFrame.minY, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .textBackgroundColor
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 400)
        window.contentViewController = NSHostingController(rootView: view)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        NSApp.setActivationPolicy(.regular)
        window.setFrame(NSRect(x: screenFrame.midX - windowWidth / 2, y: screenFrame.minY, width: windowWidth, height: windowHeight), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        updateWindowLevel()
    }

    func close() {
        guard let window = window else { return }
        window.orderOut(nil)
        self.window = nil
        windowState?.onRecordingStateChanged = nil
        windowState = nil
        NSApp.setActivationPolicy(.accessory)
    }

    /// Request a recording — shows consent dialog first (or starts immediately if user opted out).
    func requestRecording(name: String, skipConsent: Bool = false, sourceURL: String? = nil, detectedMeeting: DetectedMeeting? = nil) {
        guard let state = windowState else { return }
        state.requestRecording(
            name: name,
            skipConsent: skipConsent,
            sourceURL: sourceURL,
            detectedMeeting: detectedMeeting
        )
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func refreshPresentation() {
        updateWindowLevel()
    }

    private func updateWindowLevel() {
        guard let window, let windowState else { return }
        window.level = MeetingTranscriptWindowPresentation.windowLevel(
            shouldFloatWhileRecording: shouldFloatWhileRecording(),
            hasActiveRecording: windowState.hasActiveRecording
        )
    }
}

// MARK: - Tab Model

@MainActor
final class OpenMeetingTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var transcript: MeetingTranscript
    @Published var fileURL: URL?
    @Published var isRecording = false
    var session: MeetingSession? // nil = loaded from disk
    private var sessionObserver: Any?
    private let onRecordingStateChanged: (() -> Void)?

    private var fileURLObserver: Any?

    init(
        transcript: MeetingTranscript,
        fileURL: URL? = nil,
        session: MeetingSession? = nil,
        onRecordingStateChanged: (() -> Void)? = nil
    ) {
        self.transcript = transcript
        self.fileURL = fileURL
        self.session = session
        self.onRecordingStateChanged = onRecordingStateChanged
        if let session = session {
            isRecording = session.isActive
            sessionObserver = session.$isActive.sink { [weak self] active in
                self?.isRecording = active
                self?.onRecordingStateChanged?()
            }
            // Sync fileURL from session when it gets created
            fileURLObserver = session.$fileURL.sink { [weak self] url in
                if let url = url {
                    self?.fileURL = url
                }
            }
        }
    }
}

// MARK: - Window State

enum MeetingSurface: Equatable {
    case home
    case tab(UUID)
    case indexTab(UUID)
}

/// What's currently displayed in a navigable tab. The same tab can hold
/// either a dossier or a meeting and flip between them via in-app links.
enum NavTabContent {
    case indexEntry(kind: IndexKind, slug: String, entry: IndexEntry)
    case meeting(OpenMeetingTab)
    case indexList(kind: IndexKind)
    case secondBrain
    case generatedWikiPage(GeneratedWikiPage)
    case airtableTable(AirtableTablePreview)

    @MainActor
    var title: String {
        switch self {
        case .indexEntry(_, _, let entry): return entry.canonicalName
        case .meeting(let tab): return tab.transcript.meetingName
        case .indexList(let kind): return kind.displayName
        case .secondBrain: return "2nd Brain"
        case .generatedWikiPage(let page): return page.title
        case .airtableTable(let table): return table.name
        }
    }

    var iconSystemName: String {
        switch self {
        case .indexEntry(let kind, _, _): return kind.iconSystemName
        case .meeting: return "doc.text"
        case .indexList(let kind): return kind.iconSystemName
        case .secondBrain: return "brain.head.profile"
        case .generatedWikiPage(let page): return page.type == "meeting_overview" ? "rectangle.stack.badge.person.crop" : "link"
        case .airtableTable: return "tablecells"
        }
    }
}

struct AirtableTablePreview: Equatable {
    let name: String
    let fileURL: URL
    let headers: [String]
    let rows: [[String]]
}

/// One open document shown as a tab in the file tab bar. Holds a nav stack
/// so links inside the document navigate-in-place; right-click "Open in
/// new tab" creates a sibling instead.
@MainActor
final class OpenIndexTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var content: NavTabContent
    @Published var history: [NavTabContent] = []

    init(content: NavTabContent) {
        self.content = content
    }

    func navigate(to newContent: NavTabContent) {
        history.append(content)
        content = newContent
    }

    func goBack() {
        guard let prev = history.popLast() else { return }
        content = prev
    }

    var canGoBack: Bool { !history.isEmpty }
}

/// One entry shown in the sidebar's Indexes section.
struct IndexHistoryItem: Identifiable, Hashable {
    let kind: IndexKind
    let slug: String
    let canonicalName: String
    let fileURL: URL
    var id: String { "\(kind.rawValue)/\(slug)" }
}

struct GeneratedWikiSidebarItem: Identifiable, Hashable {
    let title: String
    let type: String
    let fileURL: URL
    var id: String { fileURL.path }
}

struct GeneratedWikiSidebarFolder: Identifiable, Hashable {
    let slug: String
    let title: String
    let iconSystemName: String
    let items: [GeneratedWikiSidebarItem]
    var id: String { slug }
}

@MainActor
final class MeetingWindowState: ObservableObject {
    var onAskQuestion: ((_ question: String, _ history: [QAHistoryTurn]) -> AsyncThrowingStream<QAEvent, Error>)?
    @Published var pushToTalkDisplay: String = ""
    @Published var tabs: [OpenMeetingTab] = []
    @Published var selectedSurface: MeetingSurface = .home
    @Published var showSidebar = true
    @Published var historyGroups: [(date: String, entries: [MeetingHistoryEntry])] = []
    @Published var showConsentDialog = false
    @Published var recordingStartError: String?
    var pendingRecordingName: String?
    var pendingSourceURL: String?
    var pendingDetectedMeeting: DetectedMeeting?
    var pendingCalendarEvent: CalendarEvent?
    var onRecordingStateChanged: (() -> Void)?

    var onOpenSettings: (() -> Void)?
    var onStartRecording: ((_ name: String, _ detectedMeeting: DetectedMeeting?) throws -> MeetingSession)?
    var onStopRecording: ((MeetingSession) -> Void)?
    var onGenerateSummary: ((MeetingTranscript) -> Void)?
    var onLoadSpeakerReviewItems: ((MeetingTranscript) -> [MeetingSpeakerReviewItem])?
    var onUpdateSpeakerLabel: ((_ transcript: MeetingTranscript, _ currentDisplayName: String, _ newDisplayName: String) throws -> Void)?
    var onMakeIndexBuilder: ((IndexKind) -> (any IndexBuilding)?)?
    var onGenerateWikiProposals: (() async throws -> [WikiKindProposal])?
    var onApproveWikiKind: ((WikiKindSpec) -> Void)?
    var onGenerateMeetingWiki: ((_ meetingURL: URL, _ onProgress: @MainActor @escaping (GeneratedWikiProgress) -> Void, _ review: @MainActor @escaping (GeneratedWikiReviewDraft) async -> GeneratedWikiReviewDecision) async throws -> GeneratedWikiResult)?

    @Published var indexItems: [IndexKind: [IndexHistoryItem]] = [:]
    @Published var indexTabs: [OpenIndexTab] = []
    @Published var showBuildIndexSheet: Bool = false
    @Published var pendingBuildIndexKind: IndexKind = .people
    @Published var wikiProposals: [WikiKindProposal] = []
    @Published var generatedWikiFolders: [GeneratedWikiSidebarFolder] = []
    @Published var generatedWikiArchiveRoot: URL? = nil
    @Published var showNewWikiSheet: Bool = false
    @Published var pendingGenerateWikiURL: URL? = nil
    @Published var pendingGenerateWikiBatch: Bool = false
    @Published var pendingSecondBrainLint: Bool = false
    @Published var isGeneratingMeetingWiki: Bool = false

    /// Right-side Models panel toggle.
    @Published var showModelsSidebar: Bool = false

    /// Set by deep views (e.g. per-entry "↻" button) to ask MeetingRootView
    /// to drop a prompt into the bottom Q&A bar and fire it. The root view
    /// consumes this on `.onChange` and clears it back to nil.
    @Published var pendingQAPrompt: String? = nil
    @Published var pendingScopedQAPrompt: ScopedQAPrompt? = nil

    /// When the Q&A run was triggered by a per-entry refresh, this holds the
    /// dossier we should offer to write the answer back into. Cleared when
    /// the user manually submits a different question or hits the Apply
    /// button.
    @Published var pendingDossierApply: PendingDossierApply? = nil

    struct PendingDossierApply: Equatable {
        let kind: IndexKind
        let slug: String
        let canonicalName: String
    }

    var activeTabID: UUID? {
        if case let .tab(id) = selectedSurface { return id }
        return nil
    }

    var saveDirectory: URL { MeetingTranscriptSettings.effectiveSaveDirectory() }

    var activeTab: OpenMeetingTab? {
        guard let id = activeTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    var hasActiveRecording: Bool {
        tabs.contains { $0.isRecording }
    }

    func selectHome() {
        selectedSurface = .home
    }

    func selectTab(_ id: UUID) {
        selectedSurface = .tab(id)
    }

    func addRecordingTab(session: MeetingSession) {
        let tab = OpenMeetingTab(
            transcript: session.transcript,
            fileURL: session.fileURL,
            session: session,
            onRecordingStateChanged: { [weak self] in
                self?.onRecordingStateChanged?()
            }
        )
        tabs.append(tab)
        selectedSurface = .tab(tab.id)
        onRecordingStateChanged?()
    }

    func openFile(_ url: URL) {
        if url.pathExtension.lowercased() == "csv" {
            openAirtableTable(url)
            return
        }

        // Already open? Switch to it.
        if let existing = tabs.first(where: { $0.fileURL == url }) {
            selectedSurface = .tab(existing.id)
            return
        }

        // Parse and open in new tab
        do {
            let transcript = try MeetingMarkdownWriter.parse(from: url)
            let tab = OpenMeetingTab(transcript: transcript, fileURL: url)
            tabs.append(tab)
            selectedSurface = .tab(tab.id)
            onRecordingStateChanged?()
        } catch {
            print("MeetingWindowState: failed to load \(url.lastPathComponent): \(error)")
        }
    }

    func openAirtableTable(_ url: URL) {
        if let existing = indexTabs.first(where: { tab in
            if case let .airtableTable(table) = tab.content { return table.fileURL == url }
            return false
        }) {
            selectedSurface = .indexTab(existing.id)
            return
        }
        do {
            let table = try Self.loadAirtableTablePreview(from: url)
            let tab = OpenIndexTab(content: .airtableTable(table))
            indexTabs.append(tab)
            selectedSurface = .indexTab(tab.id)
        } catch {
            print("MeetingWindowState: failed to load Airtable CSV \(url.lastPathComponent): \(error)")
        }
    }

    func openGeneratedWikiPage(_ url: URL) {
        if let existing = indexTabs.first(where: { tab in
            if case let .generatedWikiPage(page) = tab.content { return page.url == url }
            return false
        }) {
            selectedSurface = .indexTab(existing.id)
            return
        }
        guard let content = loadGeneratedWikiPageContent(url) else { return }
        let tab = OpenIndexTab(content: content)
        indexTabs.append(tab)
        selectedSurface = .indexTab(tab.id)
    }

    func loadGeneratedWikiPageContent(_ url: URL) -> NavTabContent? {
        do {
            return .generatedWikiPage(try GeneratedWikiPaths.readPage(from: url))
        } catch {
            print("MeetingWindowState: failed to load generated wiki page \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    func saveGeneratedWikiPage(_ page: GeneratedWikiPage, body: String) throws -> GeneratedWikiPage {
        let existing = try String(contentsOf: page.url, encoding: .utf8)
        let bodyForSave = Self.bodyPreservingOldTitleAlias(body, oldTitle: page.title)
        let updated = Self.replaceBodyAndMarkUserEdited(in: existing, body: bodyForSave)
        GhostPepperHistoryStore.recordFileChange(
            archiveRoot: saveDirectory,
            fileURL: page.url,
            actor: .user,
            operation: "edit_2nd_brain_page",
            summary: "Saved user edits for 2nd Brain page \(page.title).",
            before: existing,
            after: updated,
            metadata: [
                "page_title": page.title,
                "page_type": page.type,
                "source": "2nd_brain_editor",
                "diff_summary": Self.diffSummary(before: page.body, after: bodyForSave)
            ]
        )
        try updated.write(to: page.url, atomically: true, encoding: .utf8)
        loadGeneratedWikiFolders()
        return try GeneratedWikiPaths.readPage(from: page.url)
    }

    private static func bodyPreservingOldTitleAlias(_ body: String, oldTitle: String) -> String {
        guard let newTitle = firstMarkdownHeading(in: body),
              !oldTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              MarkdownArchivePaths.slugForIndexEntry(newTitle) != MarkdownArchivePaths.slugForIndexEntry(oldTitle) else {
            return body
        }
        return addAlias(oldTitle, to: body)
    }

    private static func firstMarkdownHeading(in body: String) -> String? {
        body.components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("# ") })
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func renameGeneratedWikiPage(_ page: GeneratedWikiPage, to rawName: String) throws -> GeneratedWikiPage {
        let newName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            throw NSError(domain: "MeetingWindowState", code: 20, userInfo: [NSLocalizedDescriptionKey: "Name cannot be empty."])
        }
        guard Self.canRenameGeneratedWikiPage(page) else {
            throw NSError(domain: "MeetingWindowState", code: 21, userInfo: [NSLocalizedDescriptionKey: "Meeting overviews are derived from source meetings and cannot be renamed here."])
        }
        guard newName != page.title else {
            return page
        }

        let existing = try String(contentsOf: page.url, encoding: .utf8)
        let updated = Self.renameGeneratedWikiText(existing, page: page, newName: newName)
        let newSlug = MarkdownArchivePaths.slugForIndexEntry(newName)
        let targetURL = page.url.deletingLastPathComponent().appendingPathComponent("\(newSlug).md")
        let sameFile = targetURL.standardizedFileURL == page.url.standardizedFileURL
        if !sameFile && FileManager.default.fileExists(atPath: targetURL.path) {
            throw NSError(domain: "MeetingWindowState", code: 22, userInfo: [NSLocalizedDescriptionKey: "A 2nd Brain page named \(newName) already exists."])
        }

        GhostPepperHistoryStore.recordFileChange(
            archiveRoot: saveDirectory,
            fileURL: sameFile ? page.url : targetURL,
            actor: .user,
            operation: "rename_2nd_brain_page",
            summary: "Renamed 2nd Brain page from \(page.title) to \(newName).",
            before: sameFile ? existing : nil,
            after: updated,
            metadata: [
                "old_name": page.title,
                "new_name": newName,
                "old_path": Self.relativePath(of: page.url, in: saveDirectory) ?? page.url.path,
                "new_path": Self.relativePath(of: targetURL, in: saveDirectory) ?? targetURL.path,
                "page_type": page.type,
                "page_id": page.pageID ?? "",
                "entity_id": page.entityID ?? ""
            ]
        )
        if !sameFile {
            GhostPepperHistoryStore.recordFileChange(
                archiveRoot: saveDirectory,
                fileURL: page.url,
                actor: .user,
                operation: "rename_2nd_brain_page_old_path",
                summary: "Moved old 2nd Brain page path for \(page.title).",
                before: existing,
                after: nil,
                metadata: [
                    "old_name": page.title,
                    "new_name": newName,
                    "new_path": Self.relativePath(of: targetURL, in: saveDirectory) ?? targetURL.path,
                    "page_type": page.type,
                    "page_id": page.pageID ?? "",
                    "entity_id": page.entityID ?? ""
                ]
            )
        }

        try updated.write(to: targetURL, atomically: true, encoding: .utf8)
        if !sameFile {
            try FileManager.default.removeItem(at: page.url)
        }
        loadGeneratedWikiFolders()
        return try GeneratedWikiPaths.readPage(from: targetURL)
    }

    func changeGeneratedWikiPageType(_ page: GeneratedWikiPage, to rawType: String) throws -> GeneratedWikiPage {
        let newType = Self.normalizedGeneratedWikiEntityType(rawType)
        guard Self.canChangeGeneratedWikiPageType(page), Self.isEntityPageType(newType) else {
            throw NSError(domain: "MeetingWindowState", code: 24, userInfo: [NSLocalizedDescriptionKey: "Only Person, Company, and Concept pages can change type here."])
        }
        guard newType != page.type else { return page }

        let existing = try String(contentsOf: page.url, encoding: .utf8)
        let updated = Self.changeGeneratedWikiTypeText(existing, page: page, newType: newType)
        let targetFolder = saveDirectory
            .appendingPathComponent("wikis", isDirectory: true)
            .appendingPathComponent(Self.generatedWikiCategory(forPageType: newType), isDirectory: true)
        let targetURL = targetFolder.appendingPathComponent(page.url.lastPathComponent)
        let sameFile = targetURL.standardizedFileURL == page.url.standardizedFileURL
        if !sameFile && FileManager.default.fileExists(atPath: targetURL.path) {
            throw NSError(domain: "MeetingWindowState", code: 25, userInfo: [NSLocalizedDescriptionKey: "A \(Self.displayName(forPageType: newType)) page named \(page.title) already exists."])
        }

        GhostPepperHistoryStore.recordFileChange(
            archiveRoot: saveDirectory,
            fileURL: sameFile ? page.url : targetURL,
            actor: .user,
            operation: "change_2nd_brain_page_type",
            summary: "Changed 2nd Brain page \(page.title) from \(Self.displayName(forPageType: page.type)) to \(Self.displayName(forPageType: newType)).",
            before: sameFile ? existing : nil,
            after: updated,
            metadata: [
                "page_title": page.title,
                "old_type": page.type,
                "new_type": newType,
                "old_path": Self.relativePath(of: page.url, in: saveDirectory) ?? page.url.path,
                "new_path": Self.relativePath(of: targetURL, in: saveDirectory) ?? targetURL.path,
                "page_id": page.pageID ?? "",
                "entity_id": page.entityID ?? ""
            ]
        )
        if !sameFile {
            GhostPepperHistoryStore.recordFileChange(
                archiveRoot: saveDirectory,
                fileURL: page.url,
                actor: .user,
                operation: "change_2nd_brain_page_type_old_path",
                summary: "Moved old 2nd Brain page path for \(page.title).",
                before: existing,
                after: nil,
                metadata: [
                    "page_title": page.title,
                    "old_type": page.type,
                    "new_type": newType,
                    "new_path": Self.relativePath(of: targetURL, in: saveDirectory) ?? targetURL.path,
                    "page_id": page.pageID ?? "",
                    "entity_id": page.entityID ?? ""
                ]
            )
        }

        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        try updated.write(to: targetURL, atomically: true, encoding: .utf8)
        if !sameFile {
            try FileManager.default.removeItem(at: page.url)
        }
        loadGeneratedWikiFolders()
        return try GeneratedWikiPaths.readPage(from: targetURL)
    }

    private static func replaceBodyAndMarkUserEdited(in text: String, body: String) -> String {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard text.hasPrefix("---\n"),
              let close = text.dropFirst(4).range(of: "\n---\n") else {
            return normalizedBody
        }
        var frontmatter = String(text.dropFirst(4)[..<close.lowerBound])
        frontmatter = setFrontmatterValue("updated_at", value: ISO8601DateFormatter().string(from: Date()), in: frontmatter)
        frontmatter = setFrontmatterValue("user_edited", value: "true", in: frontmatter)
        return "---\n\(frontmatter)\n---\n\n\(normalizedBody)"
    }

    private static func canRenameGeneratedWikiPage(_ page: GeneratedWikiPage) -> Bool {
        ["person", "company", "concept", "topic", "claim"].contains(page.type)
    }

    private static func canChangeGeneratedWikiPageType(_ page: GeneratedWikiPage) -> Bool {
        isEntityPageType(page.type)
    }

    private static func normalizedGeneratedWikiEntityType(_ rawType: String) -> String {
        switch rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "person", "people":
            return "person"
        case "company", "companies", "organization", "organisation", "fund", "firm", "institution", "product":
            return "company"
        case "concept", "topic", "idea":
            return "concept"
        default:
            return rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private static func generatedWikiCategory(forPageType type: String) -> String {
        switch normalizedGeneratedWikiEntityType(type) {
        case "person": return "people"
        case "company": return "companies"
        default: return "concepts"
        }
    }

    private static func displayName(forPageType type: String) -> String {
        switch normalizedGeneratedWikiEntityType(type) {
        case "person": return "Person"
        case "company": return "Company"
        case "concept": return "Concept"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func changeGeneratedWikiTypeText(_ text: String, page: GeneratedWikiPage, newType: String) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let fallbackPageID = page.pageID ?? "gpw_\(GhostPepperHistoryStore.stableHash("\(page.type)|\(page.url.path)"))"
        let fallbackEntityID = page.entityID ?? fallbackPageID
        if text.hasPrefix("---\n"),
           let close = text.dropFirst(4).range(of: "\n---\n") {
            var fm = String(text.dropFirst(4)[..<close.lowerBound])
            let body = String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            fm = setFrontmatterValue("type", value: newType, in: fm)
            fm = setFrontmatterValue("updated_at", value: now, in: fm)
            fm = setFrontmatterValue("user_edited", value: "true", in: fm)
            if !frontmatterContains("page_id", in: fm) {
                fm = setFrontmatterValue("page_id", value: yamlScalar(fallbackPageID), in: fm)
            }
            if !frontmatterContains("entity_id", in: fm) {
                fm = setFrontmatterValue("entity_id", value: yamlScalar(fallbackEntityID), in: fm)
            }
            return "---\n\(fm.trimmingCharacters(in: .whitespacesAndNewlines))\n---\n\n\(body)"
        }

        let body = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let frontmatter = [
            "type: \(newType)",
            "page_id: \(yamlScalar(fallbackPageID))",
            "entity_id: \(yamlScalar(fallbackEntityID))",
            "name: \(yamlScalar(page.title))",
            "updated_at: \(now)",
            "user_edited: true"
        ].joined(separator: "\n")
        return "---\n\(frontmatter)\n---\n\n\(body)"
    }

    private static func renameGeneratedWikiText(_ text: String, page: GeneratedWikiPage, newName: String) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let fallbackPageID = page.pageID ?? "gpw_\(GhostPepperHistoryStore.stableHash("\(page.type)|\(page.url.path)"))"
        let fallbackEntityID = page.entityID ?? fallbackPageID
        let newBody: String
        let frontmatter: String

        if text.hasPrefix("---\n"),
           let close = text.dropFirst(4).range(of: "\n---\n") {
            var fm = String(text.dropFirst(4)[..<close.lowerBound])
            var body = String(text[close.upperBound...])
            fm = setFrontmatterValue("name", value: yamlScalar(newName), in: fm)
            fm = setFrontmatterValue("updated_at", value: now, in: fm)
            fm = setFrontmatterValue("user_edited", value: "true", in: fm)
            if !frontmatterContains("page_id", in: fm) {
                fm = setFrontmatterValue("page_id", value: yamlScalar(fallbackPageID), in: fm)
            }
            if isEntityPageType(page.type), !frontmatterContains("entity_id", in: fm) {
                fm = setFrontmatterValue("entity_id", value: yamlScalar(fallbackEntityID), in: fm)
            }
            body = replaceFirstMarkdownHeading(in: body, with: newName)
            body = addAlias(page.title, to: body)
            frontmatter = fm
            newBody = body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        } else {
            frontmatter = [
                "type: \(page.type)",
                "page_id: \(yamlScalar(fallbackPageID))",
                isEntityPageType(page.type) ? "entity_id: \(yamlScalar(fallbackEntityID))" : nil,
                "name: \(yamlScalar(newName))",
                "updated_at: \(now)",
                "user_edited: true"
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            newBody = addAlias(page.title, to: replaceFirstMarkdownHeading(in: text, with: newName))
                .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }

        return "---\n\(frontmatter.trimmingCharacters(in: .whitespacesAndNewlines))\n---\n\n\(newBody)"
    }

    private static func setFrontmatterValue(_ key: String, value: String, in frontmatter: String) -> String {
        var lines = frontmatter.components(separatedBy: "\n")
        if let idx = lines.firstIndex(where: { line in
            line.split(separator: ":", maxSplits: 1).first.map(String.init) == key
        }) {
            lines[idx] = "\(key): \(value)"
        } else {
            lines.append("\(key): \(value)")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func frontmatterContains(_ key: String, in frontmatter: String) -> Bool {
        frontmatter.components(separatedBy: "\n").contains { line in
            line.split(separator: ":", maxSplits: 1).first.map(String.init) == key
        }
    }

    private static func yamlScalar(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func isEntityPageType(_ type: String) -> Bool {
        ["person", "company", "concept"].contains(type)
    }

    private static func replaceFirstMarkdownHeading(in body: String, with title: String) -> String {
        var lines = body.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            lines[index] = "# \(title)"
        } else {
            lines.insert("# \(title)", at: 0)
            lines.insert("", at: min(1, lines.count))
        }
        return lines.joined(separator: "\n")
    }

    private static func addAlias(_ alias: String, to body: String) -> String {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlias.isEmpty else { return body }
        let aliasBullet = "- \(trimmedAlias)"
        var lines = body.components(separatedBy: "\n")
        guard let headingIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Aliases" }) else {
            var insertAt = lines.count
            if let nextHeading = lines.dropFirst().firstIndex(where: { $0.hasPrefix("## ") }) {
                insertAt = nextHeading
            }
            lines.insert(contentsOf: ["", "## Aliases", "", aliasBullet], at: insertAt)
            return lines.joined(separator: "\n")
        }
        var sectionEnd = lines.count
        if let nextHeading = lines[(headingIndex + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) {
            sectionEnd = nextHeading
        }
        let existing = Set(lines[(headingIndex + 1)..<sectionEnd].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        if !existing.contains(aliasBullet) {
            lines.insert(aliasBullet, at: sectionEnd)
        }
        return lines.joined(separator: "\n")
    }

    private static func diffSummary(before: String, after: String) -> String {
        let beforeLines = before.components(separatedBy: "\n")
        let afterLines = after.components(separatedBy: "\n")
        let beforeSet = Set(beforeLines)
        let afterSet = Set(afterLines)
        let added = afterSet.subtracting(beforeSet).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let removed = beforeSet.subtracting(afterSet).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        return "+\(added) lines, -\(removed) lines"
    }

    private static func relativePath(of url: URL, in root: URL) -> String? {
        let base = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(base) else { return nil }
        var rel = String(full.dropFirst(base.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel.isEmpty ? nil : rel
    }

    func resolveGeneratedWikilink(slug: String) -> URL? {
        for archiveRoot in generatedWikiArchiveCandidates() {
            if let url = GeneratedWikiPaths.findPage(in: archiveRoot, slug: slug) {
                return url
            }
            if let url = Self.findGeneratedWikiPageByMetadata(in: archiveRoot, slug: slug) {
                return url
            }
        }
        return nil
    }

    private static func findGeneratedWikiPageByMetadata(in archiveRoot: URL, slug: String) -> URL? {
        let root = GeneratedWikiPaths.root(in: archiveRoot)
        let normalizedNeedle = MarkdownArchivePaths.slugForIndexEntry(slug)
        let categories = ["meetings", "people", "companies", "concepts", "topics", "claims"]
        for category in categories {
            let folder = root.appendingPathComponent(category, isDirectory: true)
            guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
                continue
            }
            for url in urls where url.pathExtension == "md" && !url.lastPathComponent.hasPrefix("_") {
                guard let page = try? GeneratedWikiPaths.readPage(from: url) else { continue }
                var candidates = [
                    url.deletingPathExtension().lastPathComponent,
                    page.title
                ]
                if let sourceMeetingPath = page.sourceMeetingPath {
                    candidates.append(contentsOf: sourcePathCandidates(sourceMeetingPath))
                }
                candidates.append(contentsOf: aliases(in: page.body))
                candidates.append(contentsOf: sourceMeetingPaths(in: page.body).flatMap(sourcePathCandidates))
                if candidates.contains(where: { MarkdownArchivePaths.slugForIndexEntry($0) == normalizedNeedle }) {
                    return url
                }
            }
        }
        return nil
    }

    private static func sourcePathCandidates(_ path: String) -> [String] {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "` ").union(.whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return [] }
        let filename = (trimmed as NSString).lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        return [trimmed, filename, stem]
    }

    private static func aliases(in body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Aliases" }) else {
            return []
        }
        var aliases: [String] = []
        for line in lines.dropFirst(start + 1) {
            if line.hasPrefix("## ") { break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("- ") else { continue }
            aliases.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return aliases
    }

    private static func sourceMeetingPaths(in body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Source Meetings" }) else {
            return []
        }
        var paths: [String] = []
        for line in lines.dropFirst(start + 1) {
            if line.hasPrefix("## ") { break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("- ") else { continue }
            paths.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "` ").union(.whitespacesAndNewlines)))
        }
        return paths
    }

    func openIndexEntry(kind: IndexKind, slug: String) {
        // Already open as the *current* content of some tab? Switch to it.
        if let existing = indexTabs.first(where: { tab in
            if case let .indexEntry(k, s, _) = tab.content { return k == kind && s == slug }
            return false
        }) {
            selectedSurface = .indexTab(existing.id)
            return
        }
        guard let content = loadIndexEntryContent(kind: kind, slug: slug) else { return }
        let tab = OpenIndexTab(content: content)
        indexTabs.append(tab)
        selectedSurface = .indexTab(tab.id)
    }

    /// Opens the searchable list view of an index kind as its own tab.
    func openIndexList(kind: IndexKind) {
        if let existing = indexTabs.first(where: { tab in
            if case let .indexList(k) = tab.content { return k == kind }
            return false
        }) {
            selectedSurface = .indexTab(existing.id)
            return
        }
        let tab = OpenIndexTab(content: .indexList(kind: kind))
        indexTabs.append(tab)
        selectedSurface = .indexTab(tab.id)
    }

    func openSecondBrain() {
        if let existing = indexTabs.first(where: { tab in
            if case .secondBrain = tab.content { return true }
            return false
        }) {
            selectedSurface = .indexTab(existing.id)
            return
        }
        loadGeneratedWikiFolders()
        let tab = OpenIndexTab(content: .secondBrain)
        indexTabs.append(tab)
        selectedSurface = .indexTab(tab.id)
    }

    /// Loads an index-entry payload from disk, returning nil if the file is
    /// missing or malformed.
    func loadIndexEntryContent(kind: IndexKind, slug: String) -> NavTabContent? {
        let url = MarkdownArchivePaths.entryURL(in: saveDirectory, kind: kind, slug: slug)
        do {
            let entry = try IndexEntryFile.read(from: url)
            return .indexEntry(kind: kind, slug: slug, entry: entry)
        } catch {
            print("MeetingWindowState: failed to load index entry \(slug): \(error)")
            return nil
        }
    }

    /// Loads a meeting payload (read-only) from disk, returning nil if missing.
    func loadMeetingContent(relativePath: String) -> NavTabContent? {
        let url = saveDirectory.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let transcript = try MeetingMarkdownWriter.parse(from: url)
            let synth = OpenMeetingTab(transcript: transcript, fileURL: url)
            return .meeting(synth)
        } catch {
            print("MeetingWindowState: failed to load meeting \(relativePath): \(error)")
            return nil
        }
    }

    /// Opens a meeting (by relative archive path) inside a new browsable tab.
    /// Used by right-click "Open in new tab" on a source-meeting link.
    func openMeetingInNewIndexTab(relativePath: String) {
        guard let content = loadMeetingContent(relativePath: relativePath) else { return }
        let tab = OpenIndexTab(content: content)
        indexTabs.append(tab)
        selectedSurface = .indexTab(tab.id)
    }

    func closeIndexTab(_ tabID: UUID) {
        indexTabs.removeAll { $0.id == tabID }
        if case .indexTab(let id) = selectedSurface, id == tabID {
            if let last = indexTabs.last {
                selectedSurface = .indexTab(last.id)
            } else if let lastMeeting = tabs.last {
                selectedSurface = .tab(lastMeeting.id)
            } else {
                selectedSurface = .home
            }
        }
    }

    func openMeetingByRelativePath(_ relativePath: String) {
        let url = saveDirectory.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("MeetingWindowState: meeting file missing at \(relativePath)")
            return
        }
        openFile(url)
    }

    func loadIndexes() {
        var byKind: [IndexKind: [IndexHistoryItem]] = [:]
        for kind in IndexKind.allCases {
            let root = MarkdownArchivePaths.indexRoot(in: saveDirectory, kind: kind)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            var items: [IndexHistoryItem] = []
            for url in urls where url.pathExtension == "md" && !url.lastPathComponent.hasPrefix("_") {
                let slug = String(url.lastPathComponent.dropLast(3))
                let canonical = (try? IndexEntryFile.read(from: url).canonicalName) ?? slug
                items.append(IndexHistoryItem(kind: kind, slug: slug, canonicalName: canonical, fileURL: url))
            }
            items.sort { $0.canonicalName.lowercased() < $1.canonicalName.lowercased() }
            byKind[kind] = items
        }
        indexItems = byKind
        wikiProposals = WikiKindStore.shared.proposals
    }

    func presentBuildIndexSheet(for kind: IndexKind) {
        pendingBuildIndexKind = kind
        showBuildIndexSheet = true
    }

    func closeTab(_ tabID: UUID) {
        // Stop recording if this is a live tab
        if let tab = tabs.first(where: { $0.id == tabID }), let session = tab.session {
            onStopRecording?(session)
        }

        tabs.removeAll { $0.id == tabID }
        onRecordingStateChanged?()

        // If the closed tab was active, fall back to last remaining tab, else Home.
        if case .tab(let activeID) = selectedSurface, activeID == tabID {
            if let last = tabs.last {
                selectedSurface = .tab(last.id)
            } else {
                selectedSurface = .home
            }
        }
    }

    func startNewNote() {
        startWithGeneratedName(prefix: "Quick Note")
    }

    func startAdHocCall() {
        startWithGeneratedName(prefix: "Ad Hoc Meeting")
    }

    private func startWithGeneratedName(prefix: String) {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let name = "\(prefix) — \(formatter.string(from: Date()))"

        requestRecording(name: name)
    }

    func startCalendarMeeting(_ event: CalendarEvent) {
        requestRecording(name: event.title, calendarEvent: event)
    }

    private func openMeetingLink(for event: CalendarEvent) {
        guard let link = event.meetLink, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    func requestRecording(
        name: String,
        skipConsent: Bool = false,
        sourceURL: String? = nil,
        detectedMeeting: DetectedMeeting? = nil,
        calendarEvent: CalendarEvent? = nil
    ) {
        clearPendingRecording()
        recordingStartError = nil

        if skipConsent || UserDefaults.standard.bool(forKey: "skipConsentDialog") {
            startRecording(
                name: name,
                sourceURL: sourceURL,
                detectedMeeting: detectedMeeting,
                calendarEvent: calendarEvent
            )
            return
        }

        pendingRecordingName = name
        pendingSourceURL = sourceURL
        pendingDetectedMeeting = detectedMeeting
        pendingCalendarEvent = calendarEvent
        showConsentDialog = true
    }

    func confirmRecording() {
        guard let name = pendingRecordingName else { return }
        startRecording(
            name: name,
            sourceURL: pendingSourceURL,
            detectedMeeting: pendingDetectedMeeting,
            calendarEvent: pendingCalendarEvent
        )
    }

    func cancelRecording() {
        showConsentDialog = false
        clearPendingRecording()
    }

    private func startRecording(
        name: String,
        sourceURL: String?,
        detectedMeeting: DetectedMeeting?,
        calendarEvent: CalendarEvent?
    ) {
        do {
            guard let onStartRecording else {
                throw MeetingRecordingStartError.unavailable("Meeting recording is not ready yet. Close and reopen the meeting window, then try again.")
            }
            let session = try onStartRecording(name, detectedMeeting)
            clearPendingRecording()
            recordingStartError = nil
            showConsentDialog = false
            applyPendingContext(to: session, sourceURL: sourceURL, calendarEvent: calendarEvent)
            addRecordingTab(session: session)
            if let calendarEvent {
                openMeetingLink(for: calendarEvent)
            }
        } catch {
            pendingRecordingName = name
            pendingSourceURL = sourceURL
            pendingDetectedMeeting = detectedMeeting
            pendingCalendarEvent = calendarEvent
            recordingStartError = error.localizedDescription
            showConsentDialog = true
        }
    }

    private func clearPendingRecording() {
        pendingRecordingName = nil
        pendingSourceURL = nil
        pendingDetectedMeeting = nil
        pendingCalendarEvent = nil
    }

    private func applyPendingContext(to session: MeetingSession, sourceURL: String?, calendarEvent: CalendarEvent?) {
        if let calendarEvent {
            session.applyCalendarEvent(calendarEvent)
        }
        if let sourceURL {
            session.transcript.notes = "Source: \(sourceURL)\n\n"
        }
    }

    func loadHistory() {
        let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
        historyGroups = MeetingHistory.loadEntries(from: dir)
        loadGeneratedWikiFolders()
    }

    func loadGeneratedWikiFolders() {
        var selectedArchiveRoot = saveDirectory
        var selectedFolders = Self.makeGeneratedWikiFolders(in: selectedArchiveRoot)

        if Self.generatedWikiItemCount(in: selectedFolders) == 0 {
            for archiveRoot in generatedWikiArchiveCandidates().dropFirst() {
                let folders = Self.makeGeneratedWikiFolders(in: archiveRoot)
                guard Self.generatedWikiItemCount(in: folders) > 0 else { continue }
                selectedArchiveRoot = archiveRoot
                selectedFolders = folders
                break
            }
        }

        generatedWikiArchiveRoot = selectedArchiveRoot
        generatedWikiFolders = selectedFolders
    }

    func generatedWikiRootForDisplay() -> URL {
        if let generatedWikiArchiveRoot {
            return GeneratedWikiPaths.root(in: generatedWikiArchiveRoot)
        }
        for archiveRoot in generatedWikiArchiveCandidates() {
            let folders = Self.makeGeneratedWikiFolders(in: archiveRoot)
            if Self.generatedWikiItemCount(in: folders) > 0 {
                return GeneratedWikiPaths.root(in: archiveRoot)
            }
        }
        return GeneratedWikiPaths.root(in: saveDirectory)
    }

    func archiveSecondBrain(to destinationFolder: URL) throws -> URL {
        let archiveRoot = generatedWikiArchiveRoot ?? saveDirectory
        let timestamp = Self.archiveTimestampFormatter.string(from: Date())
        let baseName = "Ghost Pepper 2nd Brain Archive \(timestamp)"
        let destination = uniqueArchiveFolder(named: baseName, in: destinationFolder)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let artifacts: [(relativePath: String, label: String)] = [
            ("wikis", "2nd Brain pages"),
            ("\(GhostPepperHistoryStore.metadataFolderName)/\(GhostPepperHistoryStore.historyFolderName)", "Ghost Pepper history"),
            ("\(MarkdownArchivePaths.indexesFolderName)/_cards", "2nd Brain meeting card cache")
        ]

        var moved: [[String: String]] = []
        for artifact in artifacts {
            let source = archiveRoot.appendingPathComponent(artifact.relativePath, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let target = destination.appendingPathComponent(artifact.relativePath, isDirectory: true)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: source, to: target)
            moved.append([
                "label": artifact.label,
                "from": source.path,
                "to": target.path
            ])
        }

        guard !moved.isEmpty else {
            try? fileManager.removeItem(at: destination)
            throw NSError(
                domain: "GhostPepper.SecondBrainArchive",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No 2nd Brain files were found to archive."]
            )
        }

        let manifest: [String: Any] = [
            "archived_at": ISO8601DateFormatter().string(from: Date()),
            "archive_root": archiveRoot.path,
            "source_data_preserved": true,
            "source_data_note": "Dated meeting files, recordings, imports, and source markdown were intentionally not moved.",
            "moved_artifacts": moved
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: destination.appendingPathComponent("archive-manifest.json"))

        generatedWikiArchiveRoot = archiveRoot
        generatedWikiFolders = Self.makeGeneratedWikiFolders(in: archiveRoot)
        return destination
    }

    private func uniqueArchiveFolder(named baseName: String, in destinationFolder: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = destinationFolder.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = destinationFolder.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static let archiveTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter
    }()

    private func generatedWikiArchiveCandidates() -> [URL] {
        [saveDirectory]
    }

    private static func makeGeneratedWikiFolders(in archiveRoot: URL) -> [GeneratedWikiSidebarFolder] {
        let root = GeneratedWikiPaths.root(in: archiveRoot)
        let specs: [(slug: String, title: String, icon: String)] = [
            ("meetings", "Meeting Overviews", "rectangle.stack.badge.person.crop"),
            ("people", "People", "person.2"),
            ("companies", "Companies", "building.2"),
            ("concepts", "Concepts", "lightbulb"),
            ("topics", "Topics", "list.bullet.rectangle"),
            ("claims", "Claims", "quote.bubble")
        ]
        return specs.compactMap { spec in
            let folderURL = root.appendingPathComponent(spec.slug, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folderURL.path) else {
                return GeneratedWikiSidebarFolder(slug: spec.slug, title: spec.title, iconSystemName: spec.icon, items: [])
            }
            let urls = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
            let items = urls
                .filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasPrefix("_") }
                .compactMap { url -> GeneratedWikiSidebarItem? in
                    let page = try? GeneratedWikiPaths.readPage(from: url)
                    return GeneratedWikiSidebarItem(
                        title: page?.title ?? url.deletingPathExtension().lastPathComponent,
                        type: page?.type ?? spec.slug,
                        fileURL: url
                    )
                }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return GeneratedWikiSidebarFolder(slug: spec.slug, title: spec.title, iconSystemName: spec.icon, items: items)
        }
    }

    private static func generatedWikiItemCount(in folders: [GeneratedWikiSidebarFolder]) -> Int {
        folders.reduce(0) { $0 + $1.items.count }
    }

    private static func loadAirtableTablePreview(from url: URL) throws -> AirtableTablePreview {
        let text = try String(contentsOf: url, encoding: .utf8)
        let records = parseCSV(text)
        let headers = records.first ?? []
        let rows = Array(records.dropFirst())
        return AirtableTablePreview(
            name: url.deletingPathExtension().lastPathComponent,
            fileURL: url,
            headers: headers,
            rows: rows
        )
    }

    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex

        while index < text.endIndex {
            let char = text[index]
            if char == "\"" {
                let next = text.index(after: index)
                if inQuotes, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    inQuotes.toggle()
                }
            } else if char == ",", !inQuotes {
                row.append(field)
                field = ""
            } else if (char == "\n" || char == "\r"), !inQuotes {
                row.append(field)
                field = ""
                if !row.allSatisfy({ $0.isEmpty }) {
                    rows.append(row)
                }
                row = []
                let next = text.index(after: index)
                if char == "\r", next < text.endIndex, text[next] == "\n" {
                    index = next
                }
            } else {
                field.append(char)
            }
            index = text.index(after: index)
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    func renameActiveTab() {
        guard let tab = activeTab, let oldURL = tab.fileURL else { return }
        let newSlug = MeetingMarkdownWriter.slugify(tab.transcript.meetingName)
        let dir = oldURL.deletingLastPathComponent()
        let newURL = dir.appendingPathComponent(newSlug + ".md")

        // Don't rename if slug didn't change or target already exists
        guard newURL != oldURL, !FileManager.default.fileExists(atPath: newURL.path) else {
            saveActiveTab()
            return
        }

        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            tab.fileURL = newURL
            // Also update the session's fileURL so auto-save goes to the new path
            if let session = tab.session {
                session.fileURL = newURL
            }
            saveActiveTab()
            print("Renamed \(oldURL.lastPathComponent) → \(newURL.lastPathComponent)")
        } catch {
            print("Failed to rename: \(error)")
            saveActiveTab() // Still save content even if rename fails
        }
    }

    func saveActiveTab() {
        guard let tab = activeTab, let url = tab.fileURL else { return }
        let markdown = MeetingMarkdownWriter.renderMarkdown(transcript: tab.transcript)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        GhostPepperHistoryStore.recordFileChange(
            archiveRoot: saveDirectory,
            fileURL: url,
            actor: .user,
            operation: "edit_meeting_note",
            summary: "Saved meeting note edits for \(tab.transcript.meetingName).",
            before: existing,
            after: markdown,
            metadata: [
                "meeting_name": tab.transcript.meetingName,
                "source": "meeting_editor"
            ]
        )
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Root View

struct MeetingRootView: View {
    @ObservedObject var state: MeetingWindowState
    let cleanupManager: TextCleanupManager
    let modelManager: ModelManager
    let usageStats: UsageStatsStore
    let onDownloadSpeechModel: (String) -> Void
    @State private var sidebarWidth: CGFloat = 220
    @State private var modelsSidebarWidth: CGFloat = 260
    @State private var qaResponseHeight: CGFloat = 360
    @State private var qaQuestion = ""
    @State private var qaThread: [QATurn] = []
    @State private var qaIsLoading = false
    @State private var qaStatusLine: String = ""
    @State private var qaTraceExpanded: Bool = false
    @StateObject private var qaTranscript: QATranscript = QATranscript()
    @State private var currentQATask: Task<Void, Never>? = nil
    @State private var wikiGenerationRun: WikiGenerationRun? = nil
    @State private var wikiGenerationTask: Task<Void, Never>? = nil
    @State private var isWikiGenerationMinimized: Bool = false
    @State private var secondBrainLintRun: SecondBrainLintRun? = nil
    @State private var secondBrainLintTask: Task<Void, Never>? = nil
    @State private var isApplyingDossier: Bool = false
    @AppStorage("agentBackend") private var qaAgentBackendStorage: String = "claude:\(ClaudeAPIModel.sonnet.rawValue)"
    @State private var showCommandKSearch: Bool = false
    @State private var showQAMentionSheet: Bool = false
    @State private var qaAttachments: [QAAttachment] = []
    @AppStorage(AppTheme.storageKey) private var selectedThemeID = AppThemeID.current.rawValue

    private var appTheme: AppTheme {
        AppTheme.resolve(selectedThemeID)
    }

    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 0) {
            if state.showSidebar {
                MeetingSidebarView(state: state)
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading))

                // Draggable divider
                Rectangle()
                    .fill(appTheme.separator)
                    .frame(width: 3)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let newWidth = sidebarWidth + value.translation.width
                                sidebarWidth = max(160, min(400, newWidth))
                            }
                    )
            }

            VStack(spacing: 0) {
                // File tabs (always show — includes "+" tab)
                fileTabBar

                // Active tab content or new tab view
                selectedSurfaceContent
            }
            .background(appTheme.textBackground)

            if state.showModelsSidebar {
                // Draggable divider on the panel's leading edge.
                Rectangle()
                    .fill(appTheme.separator)
                    .frame(width: 3)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let newWidth = modelsSidebarWidth - value.translation.width
                                modelsSidebarWidth = max(200, min(420, newWidth))
                            }
                    )

                RightSidebarView(
                    cleanupManager: cleanupManager,
                    modelManager: modelManager,
                    usageStats: usageStats,
                    onDownloadSpeechModel: onDownloadSpeechModel
                )
                    .frame(width: modelsSidebarWidth)
                    .transition(.move(edge: .trailing))
            }
        }

        // App-level Q&A: response area sits above the input row, which is
        // pinned to the bottom via layoutPriority so it never disappears
        // when the thread grows. Main content (newTabView) is wrapped in a
        // ScrollView so it can shrink safely without clipping the tab bar.
        qaResponseArea
        qaInputArea
            .layoutPriority(1)
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(appTheme.windowBackground)
        .tint(appTheme.accent)
        .animation(.easeInOut(duration: 0.2), value: state.showSidebar)
        .animation(.easeInOut(duration: 0.2), value: state.showModelsSidebar)
        .onAppear { state.loadHistory() }
        .onChange(of: state.showSidebar) { _, visible in
            if visible { state.loadHistory() }
        }
        .onChange(of: state.pendingQAPrompt) { _, prompt in
            guard let prompt, !prompt.isEmpty, !qaIsLoading else { return }
            qaQuestion = prompt
            state.pendingQAPrompt = nil
            askAcrossMeetings()
        }
        .onChange(of: state.pendingScopedQAPrompt) { _, prompt in
            guard let prompt, !prompt.displayQuestion.isEmpty, !qaIsLoading else { return }
            state.pendingScopedQAPrompt = nil
            askAcrossMeetings(displayQuestion: prompt.displayQuestion, agentQuestionOverride: prompt.agentQuestion)
        }
        .onChange(of: state.pendingGenerateWikiURL) { _, url in
            guard let url else { return }
            state.pendingGenerateWikiURL = nil
            runMeetingWikiGeneration(fileURL: url)
        }
        .onChange(of: state.pendingGenerateWikiBatch) { _, shouldRun in
            guard shouldRun else { return }
            state.pendingGenerateWikiBatch = false
            runWikiBatchGeneration()
        }
        .onChange(of: state.pendingSecondBrainLint) { _, shouldRun in
            guard shouldRun else { return }
            state.pendingSecondBrainLint = false
            runSecondBrainLint()
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            if state.showSidebar { state.loadHistory() }
        }
        .overlay {
            if let run = wikiGenerationRun {
                if !run.isBatch && isWikiGenerationMinimized {
                    minimizedWikiGenerationStrip(for: run)
                        .padding(.bottom, 18)
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(10)
                } else {
                    GeometryReader { proxy in
                        let maxWidth = max(520, proxy.size.width - 72)
                        let maxHeight = max(420, proxy.size.height - 72)
                        let scale = min(1, maxWidth / 980, maxHeight / 720)
                        WikiGenerationConsoleSheet(
                            run: run,
                            onCancel: {
                                cancelWikiGeneration(run)
                            },
                            onOpenOverview: {
                                if let url = run.result?.overviewURL {
                                    state.openGeneratedWikiPage(url)
                                    isWikiGenerationMinimized = false
                                    wikiGenerationRun = nil
                                }
                            },
                            onClose: {
                                guard !run.isRunning else { return }
                                isWikiGenerationMinimized = false
                                wikiGenerationRun = nil
                            },
                            onMinimize: run.isBatch ? nil : {
                                isWikiGenerationMinimized = true
                            }
                        )
                        .scaleEffect(scale)
                        .frame(width: 980 * scale, height: 720 * scale)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                    .transition(.opacity)
                    .zIndex(10)
                }
            }
        }
        .sheet(isPresented: $state.showConsentDialog) {
            ConsentDialogView(state: state)
        }
        .background(
            Button(action: { showCommandKSearch = true }) { EmptyView() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        )
        .background(
            Button(action: { showCommandKSearch = true }) { EmptyView() }
                .keyboardShortcut("k", modifiers: .control)
                .opacity(0)
                .allowsHitTesting(false)
        )
        .background(
            Button(action: { state.startNewNote() }) { EmptyView() }
                .keyboardShortcut("n", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        )
        .sheet(isPresented: $showCommandKSearch) {
            CommandKSearchSheet(
                state: state,
                isPresented: $showCommandKSearch,
                onAskQuestion: { question in
                    state.pendingQAPrompt = question
                }
            )
        }
        .sheet(isPresented: $showQAMentionSheet) {
            CommandKSearchSheet(
                state: state,
                isPresented: $showQAMentionSheet,
                onAttach: { entry in
                    if let attachment = QAAttachment.from(entry: entry, archiveRoot: state.saveDirectory),
                       !qaAttachments.contains(where: { $0.id == attachment.id }) {
                        qaAttachments.append(attachment)
                    }
                }
            )
        }
        .sheet(isPresented: $state.showBuildIndexSheet) {
            // Check at sheet-present time that an API key exists; the actual
            // builder is fetched on demand inside the sheet so the model
            // picker can swap mid-flight.
            if state.onMakeIndexBuilder?(state.pendingBuildIndexKind) != nil {
                BuildIndexSheet(
                    kind: state.pendingBuildIndexKind,
                    fetchBuilder: { state.onMakeIndexBuilder?(state.pendingBuildIndexKind) },
                    onClose: {
                        state.showBuildIndexSheet = false
                        state.loadIndexes()
                    }
                )
            } else {
                MissingAPIKeyView(onClose: { state.showBuildIndexSheet = false }, onOpenSettings: { state.onOpenSettings?() })
            }
        }
        .sheet(isPresented: $state.showNewWikiSheet) {
            NewWikiSheet(state: state)
        }
        .sheet(item: $secondBrainLintRun) { run in
            secondBrainLintSheet(for: run)
        }
        .onReceive(NotificationCenter.default.publisher(for: .wikiKindsChanged)) { _ in
            state.loadIndexes()
        }
        .sheet(isPresented: $showReaderCapture) {
            ReaderCaptureSheet(
                archiveRoot: state.saveDirectory
            ) { savedURL in
                state.openFile(savedURL)
                state.loadHistory()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .indexUpdated)) { _ in
            state.loadIndexes()
        }
        .onAppear { state.loadIndexes() }
    }

    // MARK: - App-Level Q&A

    @ViewBuilder
    private var selectedSurfaceContent: some View {
        switch state.selectedSurface {
        case .home:
            newTabView
        case .tab:
            if let tab = state.activeTab {
                MeetingTabContentView(tab: tab, state: state)
            } else {
                newTabView
            }
        case .indexTab(let id):
            if let tab = indexTab(with: id) {
                NavTabContentView(tab: tab, state: state)
            } else {
                Text("Tab not found")
            }
        }
    }

    private func indexTab(with id: UUID) -> OpenIndexTab? {
        state.indexTabs.first { $0.id == id }
    }

    private func secondBrainLintSheet(for run: SecondBrainLintRun) -> some View {
        SecondBrainLintSheet(
            run: run,
            onCancel: {
                secondBrainLintTask?.cancel()
                run.fail("Cancelled")
                secondBrainLintTask = nil
            },
            onApply: {
                applySecondBrainLint(run)
            },
            onClose: {
                guard !run.isRunning else { return }
                secondBrainLintRun = nil
            }
        )
    }

    /// True when any of the response-area sections want to render.
    private var hasQAResponseContent: Bool {
        let hasDossierApply = state.pendingDossierApply != nil
            && !(qaThread.last?.answer ?? "").isEmpty
            && !qaIsLoading
        return qaIsLoading
            || !qaTranscript.events.isEmpty
            || !qaThread.isEmpty
            || hasDossierApply
    }

    /// Draggable horizontal handle that resizes `qaResponseHeight`.
    /// Drag up = grow response area (shrinks main content above); drag down =
    /// shrink (grows main content above). Clamped to a reasonable min/max so
    /// the input row is never squeezed out.
    private var qaResizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
            // Grip indicator — short horizontal line in the middle so the
            // drag affordance is discoverable.
            Capsule()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: 36, height: 3)
        }
        .frame(height: 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let newHeight = qaResponseHeight - value.translation.height
                    qaResponseHeight = max(120, min(700, newHeight))
                }
        )
    }

    /// Top portion of the Q&A bar: drag handle + status + trace + conversation
    /// thread + dossier-apply prompt. Outer height is user-adjustable via the
    /// drag handle when there's content; collapses to zero when idle.
    @ViewBuilder
    private var qaResponseArea: some View {
        if hasQAResponseContent {
            VStack(alignment: .leading, spacing: 0) {
                qaResizeHandle
                qaResponseContent
            }
            .frame(height: qaResponseHeight)
        }
    }

    private var qaResponseContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status line + trace toggle + Stop button
            if qaIsLoading || !qaTranscript.events.isEmpty || !qaThread.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    if qaIsLoading {
                        ProgressView().scaleEffect(0.5)
                    }
                    Text(qaStatusLine.isEmpty ? "" : qaStatusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let usage = qaThread.last?.usage {
                        Text(runningCostText(usage))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .help("\(usage.inputTokens) in / \(usage.outputTokens) out · \(usage.cacheReadTokens) cache read / \(usage.cacheWriteTokens) cache write")
                    }
                    if !qaTranscript.events.isEmpty {
                        Button(action: { qaTraceExpanded.toggle() }) {
                            Label(qaTraceExpanded ? "Hide trace" : "Show trace", systemImage: qaTraceExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11))
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderless)
                    }
                    if !qaThread.isEmpty || !qaTranscript.events.isEmpty {
                        CopyButton(text: { fullThreadDebugText() }, label: "Copy thread")
                            .help("Copy the full conversation and trace for debugging")
                    }
                    if qaIsLoading {
                        Button("Stop") {
                            currentQATask?.cancel()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            // Expandable trace
            if qaTraceExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(qaTranscript.events.enumerated()), id: \.offset) { _, event in
                            Text(formatTraceLine(event))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 180)
                .background(Color.secondary.opacity(0.06))
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            // Conversation thread
            if !qaThread.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(qaThread) { turn in
                                qaTurnView(turn)
                                    .id(turn.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                    .onChange(of: qaThread.last?.answer) { _, _ in
                        if let last = qaThread.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Apply-to-dossier action when the run came from a per-entry refresh.
            let latestAnswer = qaThread.last?.answer ?? ""
            if let pending = state.pendingDossierApply, !latestAnswer.isEmpty, !qaIsLoading {
                Divider()
                HStack(spacing: 10) {
                    Button(action: { applyDossier(pending: pending) }) {
                        HStack(spacing: 4) {
                            if isApplyingDossier {
                                ProgressView().scaleEffect(0.5)
                                Text("Merging into \(pending.slug).md…")
                                    .font(.system(size: 12, weight: .medium))
                            } else {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 11))
                                Text("Apply to \(pending.slug).md")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isApplyingDossier)

                    Button("Discard") { state.pendingDossierApply = nil }
                        .font(.system(size: 12))
                        .disabled(isApplyingDossier)

                    Spacer()

                    Text("Merges with existing dossier (LLM call). Aliases & sources stay.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
            }
        }
    }

    /// Bottom portion of the Q&A bar: attachment chips + the input row.
    /// Pinned to the bottom of the window so it stays visible regardless of
    /// thread length.
    private var qaInputArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Attachment chips (above input row)
            if !qaAttachments.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(qaAttachments) { att in
                            AttachmentChip(attachment: att) {
                                qaAttachments.removeAll { $0.id == att.id }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            }

            // Input row
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                TextField(qaPlaceholder, text: $qaQuestion)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { askAcrossMeetings() }
                    .disabled(qaIsLoading)
                    .onChange(of: qaQuestion) { _, newValue in
                        // Trigger the @-mention picker when the field ends with "@".
                        if newValue.hasSuffix("@"), !showQAMentionSheet {
                            qaQuestion = String(newValue.dropLast())
                            showQAMentionSheet = true
                        }
                    }

                if qaIsLoading {
                    ProgressView().scaleEffect(0.6)
                } else if !qaQuestion.isEmpty {
                    Button(action: { askAcrossMeetings() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                }

                if !qaThread.isEmpty {
                    Button(action: { startNewQAConversation() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "plus.message")
                                .font(.system(size: 11))
                            Text("New")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Start a new conversation (clears the thread)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// Renders one Q→A pair in the thread. The question is a short prompt-
    /// looking line; the answer renders below at full text size with the
    /// usage footer.
    @ViewBuilder
    private func qaTurnView(_ turn: QATurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text("›")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(turn.question)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if turn.isStreaming && turn.answer.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5)
                    Text(qaStatusLine.isEmpty ? "Thinking…" : qaStatusLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else if !turn.answer.isEmpty {
                QAAnswerView(source: turn.answer, onLink: handleAnswerLink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let usage = turn.usage {
                    Text(usageFooterText(usage))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func usageFooterText(_ u: QAUsage) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        let fmtIn = nf.string(from: NSNumber(value: u.inputTokens)) ?? "\(u.inputTokens)"
        let fmtOut = nf.string(from: NSNumber(value: u.outputTokens)) ?? "\(u.outputTokens)"
        if u.isLocal {
            return "\(u.modelDisplayName) · ~\(fmtIn) in / ~\(fmtOut) out · free"
        }
        var inputPart = "\(fmtIn) in"
        if u.cacheReadTokens > 0 {
            let fmtCache = nf.string(from: NSNumber(value: u.cacheReadTokens)) ?? "\(u.cacheReadTokens)"
            inputPart += " (\(fmtCache) cached)"
        }
        if u.cacheWriteTokens > 0 {
            let fmtWrite = nf.string(from: NSNumber(value: u.cacheWriteTokens)) ?? "\(u.cacheWriteTokens)"
            inputPart += " (+\(fmtWrite) cache write)"
        }
        let cost = String(format: "$%.4f", u.estimatedCostUSD)
        return "\(u.modelDisplayName) · \(inputPart) / \(fmtOut) out · ~\(cost)"
    }

    private func runningCostText(_ u: QAUsage) -> String {
        if u.isLocal {
            let nf = NumberFormatter()
            nf.numberStyle = .decimal
            let fmtIn = nf.string(from: NSNumber(value: u.inputTokens)) ?? "\(u.inputTokens)"
            let fmtOut = nf.string(from: NSNumber(value: u.outputTokens)) ?? "\(u.outputTokens)"
            return "~\(fmtIn) in / ~\(fmtOut) out · free"
        }
        return String(format: "~$%.4f", u.estimatedCostUSD)
    }

    private var qaPlaceholder: String {
        "Ask the local 2nd Brain..."
    }

    /// Routes clicks on rendered answer links. Custom `gp://` schemes open
    /// archive files / dossiers as tabs; everything else falls through to the
    /// system handler (Safari).
    private func handleAnswerLink(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "gp" else { return .systemAction }

        let host = url.host ?? ""
        // Strip leading "/" to get the path (URL parses /foo/bar.md as path).
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path

        switch host {
        case "meeting":
            let fileURL = state.saveDirectory.appendingPathComponent(path)
            state.openFile(fileURL)
            return .handled
        case "wiki":
            let fileURL = state.saveDirectory.appendingPathComponent(path)
            state.openGeneratedWikiPage(fileURL)
            return .handled
        case "person":
            // path looks like "people/<slug>" (kind subdirectory + slug)
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return .discarded }
            let kind = IndexKind(rawValue: parts[0])
            state.openIndexEntry(kind: kind, slug: parts[1])
            return .handled
        default:
            return .discarded
        }
    }

    private func localPickerLabel(for kind: LocalCleanupModelKind) -> String {
        switch kind {
        case .qwen35_0_8b_q4_k_m: return "Qwen 3.5 0.8B (local)"
        case .qwen35_2b_q4_k_m: return "Qwen 3.5 2B (local)"
        case .qwen35_4b_q4_k_m: return "Qwen 3.5 4B (local)"
        case .deepseek_r1_qwen_7b_q4_k_m: return "DeepSeek R1 7B (local)"
        case .gemma4_12b_it_optiq_4bit_mlx: return "Gemma 4 12B MLX (local)"
        }
    }

    /// Serializes the whole Q&A session — every turn (question, answer, usage
    /// footer) followed by the full event trace — into one plain-text blob for
    /// pasting into a bug report.
    private func fullThreadDebugText() -> String {
        var lines: [String] = []
        for (i, turn) in qaThread.enumerated() {
            lines.append("Q\(i + 1): \(turn.question)")
            lines.append("A\(i + 1): \(turn.answer)")
            if let usage = turn.usage {
                lines.append("    [\(usageFooterText(usage))]")
            }
            lines.append("")
        }
        if !qaTranscript.events.isEmpty {
            lines.append("--- TRACE ---")
            lines.append(contentsOf: qaTranscript.events.map { formatTraceLine($0) })
        }
        return lines.joined(separator: "\n")
    }

    private func formatTraceLine(_ event: QAEvent) -> String {
        switch event {
        case .status(let s):
            return "[status]    \(s)"
        case .toolCall(_, let name, let summary, _):
            return "[\(name)]    \(summary)"
        case .toolResult(_, let summary, let fullOutput, let isError):
            let prefix = isError ? "[result]    ERROR: \(summary)" : "[result]    \(summary)"
            let details = fullOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !details.isEmpty else { return prefix }
            let capped = details.count > 1800 ? String(details.prefix(1800)) + "\n...[trace truncated]" : details
            return prefix + "\n" + capped
        case .text:
            return "[text]      (streaming...)"
        case .usage(let u):
            let cost = String(format: "$%.4f", u.estimatedCostUSD)
            return "[usage]     \(u.modelDisplayName) · \(u.inputTokens) in / \(u.outputTokens) out · \(cost)"
        case .error(let msg):
            return "[error]     \(msg)"
        }
    }

    private func formatToolStatusLine(name: String, summary: String) -> String {
        switch name {
        case "grep": return "Searching: \(summary)"
        case "read_file": return "Reading \(summary)"
        case "list_dir": return "Listing \(summary)"
        case "wiki_route": return "Routing through 2nd Brain: \(summary)"
        case "wiki_lint_scope": return "Linting generated 2nd Brain: \(summary)"
        case "source_links": return "Following source links: \(summary)"
        case "source_search": return "Reading original sources: \(summary)"
        default: return "\(name): \(summary)"
        }
    }

    /// Extract `YYYY-MM-DD/<slug>.md` meeting paths from arbitrary prose.
    /// Tolerates the trailing `:linenumber` form Q&A citations sometimes use.
    private static func extractMeetingPaths(from text: String) -> Set<String> {
        let pattern = #"\b\d{4}-\d{2}-\d{2}/[A-Za-z0-9_\-\.]+\.md\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var found: Set<String> = []
        for match in regex.matches(in: text, range: range) {
            if let r = Range(match.range, in: text) {
                found.insert(String(text[r]))
            }
        }
        return found
    }

    private func applyDossier(pending: MeetingWindowState.PendingDossierApply) {
        let saveDir = state.saveDirectory
        let url = MarkdownArchivePaths.entryURL(in: saveDir, kind: pending.kind, slug: pending.slug)
        // Apply uses the latest answer in the thread — typically the most
        // recent follow-up, which the user just decided was good enough.
        let summary = (qaThread.last?.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, !isApplyingDossier else { return }
        guard let builder = state.onMakeIndexBuilder?(pending.kind) else {
            appendErrorToActiveTurn("apply failed: no index builder available")
            return
        }

        isApplyingDossier = true
        Task { @MainActor in
            defer { isApplyingDossier = false }
            do {
                let result = try await builder.mergeDossierBody(
                    kind: pending.kind,
                    slug: pending.slug,
                    canonicalName: pending.canonicalName,
                    newContent: summary
                )
                guard !result.body.isEmpty else {
                    appendErrorToActiveTurn("apply failed: merge produced empty body")
                    return
                }
                var entry = try IndexEntryFile.read(from: url)
                entry.body = result.body
                entry.lastUpdated = Date()
                entry.generation = result.generation

                // Fold any newly-cited meeting paths into source_meetings.
                // The Q&A answer + the merged body are scanned for date-folder
                // path patterns (e.g. "2026-04-28/standup.md"); any not
                // already in the frontmatter get appended.
                let cited = Self.extractMeetingPaths(from: summary)
                    .union(Self.extractMeetingPaths(from: result.body))
                let existing = Set(entry.sourceMeetings)
                let added = cited.subtracting(existing)
                if !added.isEmpty {
                    entry.sourceMeetings = (existing.union(added)).sorted()
                }

                try IndexEntryFile.write(entry, to: url)
                for tab in state.indexTabs {
                    if case let .indexEntry(k, s, _) = tab.content, k == pending.kind, s == pending.slug {
                        tab.content = .indexEntry(kind: k, slug: s, entry: entry)
                    }
                }
                state.pendingDossierApply = nil
                NotificationCenter.default.post(name: .indexUpdated, object: pending.kind)
            } catch {
                appendErrorToActiveTurn("apply failed: \(error.localizedDescription)")
            }
        }
    }

    /// Append a `[bracketed error]` line to the latest turn's answer so it
    /// shows inline rather than dropping silently.
    private func appendErrorToActiveTurn(_ message: String) {
        guard let lastID = qaThread.last?.id else { return }
        mutateActiveTurn(id: lastID) { turn in
            turn.answer = turn.answer.isEmpty ? "[\(message)]" : turn.answer + "\n\n[\(message)]"
        }
    }

    private func cancelWikiGeneration(_ run: WikiGenerationRun) {
        run.cancelReviewIfNeeded()
        wikiGenerationTask?.cancel()
        run.fail("Cancelled")
        state.isGeneratingMeetingWiki = false
        wikiGenerationTask = nil
        isWikiGenerationMinimized = false
    }

    private func minimizedWikiGenerationStrip(for run: WikiGenerationRun) -> some View {
        HStack(spacing: 12) {
            pepperCharacterForWindow(size: 30)
                .opacity(run.isRunning ? 1 : 0.82)

            VStack(alignment: .leading, spacing: 2) {
                Text(minimizedWikiGenerationTitle(for: run))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(run.status)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if run.isRunning {
                ProgressView(value: run.progressFraction)
                    .tint(.orange)
                    .frame(width: 120)
            }

            Button("Restore") {
                isWikiGenerationMinimized = false
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            if run.isRunning {
                Button("Stop") {
                    cancelWikiGeneration(run)
                }
                .buttonStyle(.bordered)
            } else {
                Button("Close") {
                    isWikiGenerationMinimized = false
                    wikiGenerationRun = nil
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 720)
        .background(Color(red: 0.05, green: 0.06, blue: 0.06).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.32), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.26), radius: 18, x: 0, y: 10)
    }

    private func minimizedWikiGenerationTitle(for run: WikiGenerationRun) -> String {
        if run.reviewDraft != nil {
            return "2nd Brain import ready for review"
        }
        if run.errorMessage != nil {
            return "2nd Brain import stopped"
        }
        if run.result != nil {
            return "2nd Brain import complete"
        }
        return "Adding to 2nd Brain"
    }

    @ViewBuilder
    private func pepperCharacterForWindow(size: CGFloat) -> some View {
        if let image = NSImage(named: "ghost-pepper-character") ?? Bundle.main.image(forResource: "ghost-pepper-character") {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "brain.head.profile")
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: size, height: size)
        }
    }

    private func runMeetingWikiGeneration(fileURL: URL) {
        guard !state.isGeneratingMeetingWiki else { return }
        guard let runner = state.onGenerateMeetingWiki else {
            let run = WikiGenerationRun(meetingURL: fileURL, archiveRoot: state.saveDirectory)
            run.fail("2nd Brain generation is not wired up.")
            wikiGenerationRun = run
            isWikiGenerationMinimized = false
            return
        }

        state.isGeneratingMeetingWiki = true
        state.pendingDossierApply = nil

        let run = WikiGenerationRun(meetingURL: fileURL, archiveRoot: state.saveDirectory)
        wikiGenerationRun = run
        isWikiGenerationMinimized = false

        wikiGenerationTask = Task { @MainActor in
            do {
                let result = try await runner(fileURL, { progress in
                    run.handle(progress)
                }, { draft in
                    await run.requestReview(draft)
                })

                run.finish(result)
                state.loadGeneratedWikiFolders()
                state.openGeneratedWikiPage(result.overviewURL)
            } catch is CancellationError {
                run.fail("Cancelled")
            } catch {
                run.fail(error.localizedDescription)
            }
            state.isGeneratingMeetingWiki = false
            wikiGenerationTask = nil
        }
    }

    private func runSecondBrainLint() {
        guard secondBrainLintRun?.isRunning != true else { return }
        state.openSecondBrain()
        let run = SecondBrainLintRun(archiveRoot: state.saveDirectory)
        secondBrainLintRun = run

        secondBrainLintTask = Task { @MainActor in
            let proposals = await SecondBrainLintEngine.collectProposals(archiveRoot: state.saveDirectory) { status, scanned, total, traceLine in
                run.status = status
                run.scannedPages = scanned
                run.totalPages = total
                if let traceLine {
                    run.appendTrace(traceLine)
                }
            }
            guard !Task.isCancelled else {
                run.fail("Cancelled")
                secondBrainLintTask = nil
                return
            }
            run.proposals = proposals
            run.isRunning = false
            run.status = proposals.isEmpty
                ? "No merge proposals found"
                : "Review \(proposals.count) proposed change\(proposals.count == 1 ? "" : "s")"
            secondBrainLintTask = nil
        }
    }

    private func applySecondBrainLint(_ run: SecondBrainLintRun) {
        guard !run.isRunning else { return }
        do {
            run.status = "Applying accepted changes"
            let applied = try SecondBrainLintEngine.applyAcceptedProposals(run.proposals, archiveRoot: run.archiveRoot)
            run.appliedChanges = applied
            state.loadGeneratedWikiFolders()
            run.finish(result: applied == 0
                ? "No lint changes applied."
                : "Applied \(applied) lint change\(applied == 1 ? "" : "s").")
        } catch {
            run.fail(error.localizedDescription)
        }
    }

    private func runWikiBatchGeneration(limit: Int = 50) {
        guard !state.isGeneratingMeetingWiki else { return }
        guard let runner = state.onGenerateMeetingWiki else {
            let run = WikiGenerationRun(batchTitle: "Next 2nd Brain batch", archiveRoot: state.saveDirectory, sourceCount: 0, modelCallTotal: 0)
            run.fail("2nd Brain generation is not wired up.")
            wikiGenerationRun = run
            isWikiGenerationMinimized = false
            return
        }

        state.openSecondBrain()
        let sourceURLs = Self.pendingSecondBrainSourceURLs(in: state.saveDirectory, limit: limit)
        let run = WikiGenerationRun(
            batchTitle: sourceURLs.isEmpty ? "2nd Brain is up to date" : "Next \(sourceURLs.count) sources",
            archiveRoot: state.saveDirectory,
            sourceCount: max(1, sourceURLs.count),
            modelCallTotal: max(0, sourceURLs.count + 1)
        )
        wikiGenerationRun = run
        isWikiGenerationMinimized = false

        guard !sourceURLs.isEmpty else {
            run.fail("No unprocessed meetings or notes found. Every date-folder markdown file already has a generated 2nd Brain overview.")
            return
        }

        state.isGeneratingMeetingWiki = true
        state.pendingDossierApply = nil

        wikiGenerationTask = Task { @MainActor in
            var touchedURLs: [URL] = []
            var firstOverviewURL: URL?
            var totalInputTokens = 0
            var totalOutputTokens = 0
            struct PreparedSource {
                let index: Int
                let url: URL
                let task: Task<GeneratedWikiResult, Error>
            }
            var preparedSource: PreparedSource?

            @MainActor
            func startPreparingSource(at index: Int) async {
                guard index < sourceURLs.count else {
                    run.prepareNextSource(nil)
                    preparedSource = nil
                    return
                }
                if preparedSource?.index == index { return }
                preparedSource?.task.cancel()
                let nextURL = sourceURLs[index]
                run.prepareNextSource(nextURL)
                let task = Task { @MainActor in
                    do {
                        return try await runner(nextURL, { progress in
                            run.handleNextProgress(progress, for: nextURL)
                        }, { draft in
                            await run.requestNextReview(draft, for: nextURL)
                        })
                    } catch {
                        run.failNextSource(nextURL, error: error)
                        throw error
                    }
                }
                preparedSource = PreparedSource(index: index, url: nextURL, task: task)
            }

            do {
                for (offset, sourceURL) in sourceURLs.enumerated() {
                    try Task.checkCancellation()
                    do {
                        let result: GeneratedWikiResult
                        if let prepared = preparedSource, prepared.index == offset, prepared.url == sourceURL {
                            run.beginSource(sourceURL, index: offset + 1, total: sourceURLs.count)
                            run.status = "Finishing background-prepared source"
                            run.waitForPreparedSourceReview(true)
                            defer { run.waitForPreparedSourceReview(false) }
                            do {
                                while run.nextSourceReviewDraft == nil && !run.nextSourceFailed {
                                    try Task.checkCancellation()
                                    if prepared.task.isCancelled { throw CancellationError() }
                                    try await Task.sleep(nanoseconds: 75_000_000)
                                }
                                if run.nextSourceFailed {
                                    result = try await prepared.task.value
                                } else {
                                    _ = run.promoteNextReviewToCurrent(url: sourceURL, index: offset + 1, total: sourceURLs.count)
                                    preparedSource = nil
                                    await startPreparingSource(at: offset + 1)
                                    result = try await prepared.task.value
                                }
                            } catch {
                                run.waitForPreparedSourceReview(false)
                                throw error
                            }
                            if preparedSource?.index == offset {
                                preparedSource = nil
                            }
                        } else {
                            run.beginSource(sourceURL, index: offset + 1, total: sourceURLs.count)
                            result = try await runner(sourceURL, { progress in
                                run.handle(progress)
                            }, { draft in
                                await startPreparingSource(at: offset + 1)
                                return await run.requestReview(draft)
                            })
                        }
                        firstOverviewURL = firstOverviewURL ?? result.overviewURL
                        touchedURLs.append(contentsOf: result.touchedURLs)
                        totalInputTokens += result.usage.inputTokens
                        totalOutputTokens += result.usage.outputTokens
                        run.sourceFinished()
                        state.loadGeneratedWikiFolders()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        run.sourceFailed(sourceURL, error: error)
                        if preparedSource?.index == offset {
                            preparedSource = nil
                        }
                    }
                }

                try Task.checkCancellation()
                preparedSource?.task.cancel()
                run.prepareNextSource(nil)
                let lintUsage = try await runSecondBrainLintForBatch(run: run)
                totalInputTokens += lintUsage.inputTokens
                totalOutputTokens += lintUsage.outputTokens

                state.loadGeneratedWikiFolders()
                let result = GeneratedWikiResult(
                    overviewURL: firstOverviewURL ?? GeneratedWikiPaths.root(in: state.saveDirectory),
                    touchedURLs: Self.uniqueURLs(touchedURLs),
                    gitMessage: batchGitMessage(run: run, total: sourceURLs.count),
                    usage: .local(
                        modelDisplayName: "Local 2nd Brain batch",
                        inputTokens: totalInputTokens,
                        outputTokens: totalOutputTokens
                    )
                )
                run.finish(result)
                refreshBrainBuildStatus()
            } catch is CancellationError {
                run.fail("Cancelled")
            } catch {
                run.fail(error.localizedDescription)
            }
            state.isGeneratingMeetingWiki = false
            wikiGenerationTask = nil
        }
    }

    private func runSecondBrainLintForBatch(run: WikiGenerationRun) async throws -> QAUsage {
        guard let ask = state.onAskQuestion else {
            run.handle(.status("Skipping lint: local Q&A is not wired up"))
            return .local(modelDisplayName: "Local 2nd Brain lint", inputTokens: 0, outputTokens: 0)
        }

        let displayQuestion = "Lint the generated 2nd Brain pages after this batch. Look for duplicate entities, missing backlinks, unsupported claims, and stale or contradictory generated claims. Use generated `wikis/...` pages only."
        let agentQuestion = """
        __2ND_BRAIN_LINT_ONLY__
        \(displayQuestion)
        """
        let system = "Generated-pages-only lint pass after a 2nd Brain batch."
        run.currentSourceTitle = "Generated 2nd Brain pages"
        run.handle(.status("Linting generated 2nd Brain pages"))
        run.handle(.functionStarted(name: "Lint generated pages", system: system, user: agentQuestion))

        var output = ""
        var usage: QAUsage?
        let stream = ask(agentQuestion, [])
        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .status(let status):
                run.handle(.status("Linting: \(status)"))
            case .toolCall(_, let name, let summary, _):
                run.handle(.status("Linting: \(name) \(summary)"))
            case .toolResult(_, let summary, _, let isError):
                if isError {
                    let line = "\n[lint tool error] \(summary)\n"
                    output += line
                    run.handle(.token(line))
                }
            case .text(let delta):
                output += delta
                run.handle(.token(delta))
            case .usage(let reportedUsage):
                usage = reportedUsage
            case .error(let message):
                let line = "\n[lint error] \(message)\n"
                output += line
                run.handle(.token(line))
            }
        }

        let resolvedUsage = usage ?? .local(
            modelDisplayName: "Local 2nd Brain lint",
            inputTokens: max(1, agentQuestion.count / 4),
            outputTokens: max(1, output.count / 4)
        )
        run.handle(.functionFinished(
            name: "Lint generated pages",
            output: output.trimmingCharacters(in: .whitespacesAndNewlines),
            inputTokens: resolvedUsage.inputTokens,
            outputTokens: resolvedUsage.outputTokens
        ))
        return resolvedUsage
    }

    private func batchGitMessage(run: WikiGenerationRun, total: Int) -> String {
        if run.failedSourceSummaries.isEmpty {
            return "Added \(total) source\(total == 1 ? "" : "s") to 2nd Brain and ran lint."
        }
        return "Added \(total - run.failedSourceSummaries.count) of \(total) sources to 2nd Brain, ran lint, and skipped \(run.failedSourceSummaries.count) with errors."
    }

    private static func pendingSecondBrainSourceURLs(in archiveRoot: URL, limit: Int) -> [URL] {
        IndexBuilder.allMeetingPaths(in: archiveRoot)
            .filter { relativePath in
                let overviewURL = GeneratedWikiPaths.meetingOverviewURL(in: archiveRoot, meetingPath: relativePath)
                return !FileManager.default.fileExists(atPath: overviewURL.path)
            }
            .prefix(limit)
            .map { archiveRoot.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.path).inserted }
    }

    @MainActor
    private func handleWikiProgress(_ progress: GeneratedWikiProgress, activeTurnID: UUID) {
        func appendAnswer(_ text: String) {
            mutateActiveTurn(id: activeTurnID) { $0.answer += text }
        }

        switch progress {
        case .status(let status):
            qaStatusLine = status
            qaTranscript.append(.status(status))
        case .modelStatus(let status):
            qaStatusLine = status
            qaTranscript.append(.status(status))
        case .functionStarted(let name, let system, let user):
            qaStatusLine = name
            qaTranscript.append(.toolCall(
                id: UUID().uuidString,
                name: "wiki_function",
                inputSummary: name,
                fullInput: ["system": system, "user": user]
            ))
            appendAnswer("""


            ## \(name)

            ### System prompt

            ```text
            \(Self.fenceSafe(system))
            ```

            ### User/context prompt

            ```text
            \(Self.fenceSafe(user))
            ```

            ```json
            """)
        case .token(let token):
            qaStatusLine = "Streaming 2nd Brain model output..."
            appendAnswer(token)
            qaTranscript.append(.text(token))
        case .functionFinished(let name, let output, let inputTokens, let outputTokens):
            qaStatusLine = "\(name) complete"
            appendAnswer("""

            ```

            `\(inputTokens)` input tokens · `\(outputTokens)` output tokens

            """)
            qaTranscript.append(.toolResult(
                id: UUID().uuidString,
                summary: "\(name): \(inputTokens) in / \(outputTokens) out",
                fullOutput: output,
                isError: false
            ))
        case .saved(let url):
            let relative = url.path.replacingOccurrences(of: state.saveDirectory.path + "/", with: "")
            qaStatusLine = "Saved \(relative)"
            appendAnswer("\n- saved `\(relative)`")
            qaTranscript.append(.status("Saved \(relative)"))
        }
    }

    private static func fenceSafe(_ text: String) -> String {
        text.replacingOccurrences(of: "```", with: "`\u{200B}``")
    }

    private func askAcrossMeetings(displayQuestion: String? = nil, agentQuestionOverride: String? = nil) {
        let userQuestion = (displayQuestion ?? qaQuestion).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userQuestion.isEmpty, !qaIsLoading else { return }
        qaIsLoading = true
        qaStatusLine = ""
        qaTranscript.clear()
        qaTraceExpanded = false

        // If the user attached context refs via @-mention, prefix them so the
        // agent reads those files first.
        let question: String
        if let agentQuestionOverride {
            question = agentQuestionOverride
        } else if !qaAttachments.isEmpty {
            let pathList = qaAttachments.map { "- \($0.relativePath)" }.joined(separator: "\n")
            question = """
            Context references — please read these as primary sources for the question:
            \(pathList)

            \(userQuestion)
            """
        } else {
            question = userQuestion
        }

        // Conversation history = every prior completed turn in this thread.
        let history: [QAHistoryTurn] = qaThread.compactMap { turn in
            turn.isStreaming ? nil : QAHistoryTurn(question: turn.question, answer: turn.answer)
        }

        // Append a new turn that the stream will fill into. The displayed
        // question stays clean — the context-refs prefix only goes to the agent.
        qaThread.append(QATurn(question: userQuestion))
        qaQuestion = ""
        qaAttachments = []
        let activeTurnID = qaThread.last!.id

        guard let stream = state.onAskQuestion?(question, history) else {
            mutateActiveTurn(id: activeTurnID) {
                $0.answer = "Could not answer — download a wired local model in Settings → Models."
                $0.isStreaming = false
            }
            qaIsLoading = false
            return
        }

        currentQATask = Task { @MainActor in
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .status(let s):
                        qaStatusLine = s
                        qaTranscript.append(event)
                    case .toolCall(_, let name, let summary, _):
                        qaStatusLine = formatToolStatusLine(name: name, summary: summary)
                        qaTranscript.append(event)
                    case .toolResult:
                        qaTranscript.append(event)
                    case .text(let delta):
                        qaStatusLine = "Thinking..."
                        mutateActiveTurn(id: activeTurnID) { $0.answer += delta }
                        qaTranscript.append(event)
                    case .usage(let u):
                        mutateActiveTurn(id: activeTurnID) { $0.usage = u }
                        qaTranscript.append(event)
                    case .error(let msg):
                        mutateActiveTurn(id: activeTurnID) { turn in
                            turn.answer = turn.answer.isEmpty ? "Error: \(msg)" : turn.answer + "\n\n[error: \(msg)]"
                        }
                        qaTranscript.append(event)
                    }
                }
                mutateActiveTurn(id: activeTurnID) { turn in
                    turn.answer = turn.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if turn.answer.isEmpty && qaTranscript.events.isEmpty == false {
                        turn.answer = "No answer returned. Check the trace for what was searched."
                    }
                    turn.isStreaming = false
                }
            } catch {
                mutateActiveTurn(id: activeTurnID) { turn in
                    let msg = error.localizedDescription
                    turn.answer = turn.answer.isEmpty ? "Stream error: \(msg)" : turn.answer + "\n\n[stream interrupted: \(msg)]"
                    turn.isStreaming = false
                }
            }
            qaStatusLine = ""
            qaIsLoading = false
            currentQATask = nil
        }
    }

    /// Mutate the matching turn in qaThread without losing identity tracking.
    private func mutateActiveTurn(id: UUID, _ mutate: (inout QATurn) -> Void) {
        guard let idx = qaThread.firstIndex(where: { $0.id == id }) else { return }
        mutate(&qaThread[idx])
    }

    private func startNewQAConversation() {
        currentQATask?.cancel()
        qaThread.removeAll()
        qaQuestion = ""
        qaIsLoading = false
        qaStatusLine = ""
        qaTranscript.clear()
        qaTraceExpanded = false
        state.pendingDossierApply = nil
    }

    // MARK: - File Tab Bar

    private var fileTabBar: some View {
        HStack(spacing: 0) {
            Button(action: { state.showSidebar.toggle() }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(state.showSidebar ? appTheme.accent : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .help(state.showSidebar ? "Hide sidebar" : "Show sidebar")

            Rectangle()
                .fill(appTheme.separator.opacity(0.7))
                .frame(width: 1, height: 18)
                .padding(.trailing, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    HomeTabView(isActive: state.selectedSurface == .home) {
                        state.saveActiveTab()
                        state.selectHome()
                    }

                    ForEach(state.tabs) { tab in
                        FileTabView(tab: tab, isActive: state.activeTabID == tab.id) {
                            state.saveActiveTab()
                            state.selectTab(tab.id)
                        } onClose: {
                            state.closeTab(tab.id)
                        }
                    }

                    ForEach(state.indexTabs) { indexTab in
                        IndexTabView(
                            tab: indexTab,
                            isActive: {
                                if case .indexTab(let id) = state.selectedSurface { return id == indexTab.id }
                                return false
                            }(),
                            onSelect: {
                                state.saveActiveTab()
                                state.selectedSurface = .indexTab(indexTab.id)
                            },
                            onClose: { state.closeIndexTab(indexTab.id) }
                        )
                    }

                    Menu {
                        Button {
                            state.startNewNote()
                        } label: {
                            Label("New personal note", systemImage: "note.text")
                        }
                        Button {
                            state.startAdHocCall()
                        } label: {
                            Label("New ad hoc meeting", systemImage: "waveform")
                        }
                        Button {
                            showReaderCapture = true
                        } label: {
                            Label("New reader…", systemImage: "newspaper")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }

            Spacer(minLength: 0)

            Button(action: { state.showModelsSidebar.toggle() }) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(state.showModelsSidebar ? appTheme.accent : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .help(state.showModelsSidebar ? "Hide models" : "Show models")
        }
        .background(appTheme.controlBackground.opacity(appTheme.id == .current ? 0.5 : 1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(appTheme.separator).frame(height: 1)
        }
    }

    // MARK: - Empty State

    @StateObject private var granolaImporter = GranolaImporter()
    @StateObject private var airtableImporter = AirtableImporter()
    @State private var showGranolaImport = false
    @State private var showAirtableImport = false
    @State private var showReaderCapture = false
    @State private var todayEvents: [CalendarEvent] = []
    @State private var todayEventsLoaded = false
    @State private var todayEventsError: String?
    @State private var whitelistEmail: String = ""
    @State private var granolaPendingCount: Int? = nil
    @State private var brainBuildStatus: BrainBuildStatus? = nil

    enum BrainBuildStatus: Equatable {
        case notBuilt(meetingCount: Int)
        case built(pageCount: Int)
    }

    private var homeBrandHeader: some View {
        HStack {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .accessibilityLabel("Ghost Pepper")
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private var newTabView: some View {
        ScrollView {
            VStack(spacing: 24) {
                homeBrandHeader
                    .padding(.top, 16)

                if !GoogleCalendarService.shared.isSignedIn {
                    disconnectedQuickActions
                }

                granolaSyncRow
                    .padding(.top, GoogleCalendarService.shared.isSignedIn ? 8 : 0)

                brainBuildRow
                    .padding(.top, 4)

                todayCalendarSection
                    .padding(.top, GoogleCalendarService.shared.isSignedIn ? 8 : 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showGranolaImport, onDismiss: { refreshGranolaPendingCount() }) {
            GranolaImportView(importer: granolaImporter, state: state)
        }
        .sheet(isPresented: $showAirtableImport) {
            AirtableImportView(importer: airtableImporter)
        }
        .task {
            await loadTodayEvents()
            refreshGranolaPendingCount()
            refreshBrainBuildStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await loadTodayEvents() }
            refreshGranolaPendingCount()
            refreshBrainBuildStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingRecordingStopped)) { _ in
            GoogleCalendarService.shared.invalidateTodayCache()
            Task { await loadTodayEvents() }
            refreshBrainBuildStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .indexUpdated)) { _ in
            refreshBrainBuildStatus()
        }
    }

    @ViewBuilder
    private var brainBuildRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            switch brainBuildStatus {
            case .notBuilt(let meetings) where meetings > 0:
                Button {
                    state.openSecondBrain()
                    state.pendingGenerateWikiBatch = true
                } label: {
                    HStack(spacing: 6) {
                        Text("Build 2nd Brain")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.orange))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(state.isGeneratingMeetingWiki)
                .help("Build generated 2nd Brain pages for the next 50 unprocessed meetings or notes.")
                Text("\(meetings) meetings available")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .built(let pageCount):
                Button {
                    state.openSecondBrain()
                    state.pendingGenerateWikiBatch = true
                } label: {
                    HStack(spacing: 6) {
                        Text("Update 2nd Brain")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.orange))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(state.isGeneratingMeetingWiki)
                .help("Update the 2nd Brain by adding the next 50 unprocessed meetings or notes.")
                Text("\(pageCount) pages")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .notBuilt, .none:
                EmptyView()
            }
            Spacer()
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 24)
    }

    private func refreshBrainBuildStatus() {
        let saveDir = MeetingTranscriptSettings.effectiveSaveDirectory()
        Task.detached(priority: .background) {
            let allMeetings = IndexBuilder.allMeetingPaths(in: saveDir)
            let pageCount = Self.generatedBrainPageCount(in: saveDir)
            let status: BrainBuildStatus
            if pageCount == 0 {
                status = .notBuilt(meetingCount: allMeetings.count)
            } else {
                status = .built(pageCount: pageCount)
            }
            await MainActor.run { self.brainBuildStatus = status }
        }
    }

    private nonisolated static func generatedBrainPageCount(in saveDir: URL) -> Int {
        generatedBrainPageCount(at: GeneratedWikiPaths.root(in: saveDir))
    }

    private nonisolated static func generatedBrainPageCount(at root: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var count = 0
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard !url.lastPathComponent.hasPrefix("_") else { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                count += 1
            }
        }
        return count
    }

    private var granolaSyncRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if let pending = granolaPendingCount, pending > 0 {
                Button {
                    showGranolaImport = true
                } label: {
                    HStack(spacing: 6) {
                        Text("Sync \(pending) new from Granola")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.orange))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            } else if granolaPendingCount == 0 {
                Text("Granola up to date")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Button {
                    showGranolaImport = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Sync with Granola")
            } else {
                // Pending count is nil — either we haven't parsed yet, or
                // Granola's cache schema changed under us. Either way, just
                // expose the sync sheet directly and let the user trigger it.
                Button {
                    showGranolaImport = true
                } label: {
                    HStack(spacing: 6) {
                        Text(GranolaImporter.isInstalled ? "Connect Granola" : "Import from Granola")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.orange.opacity(0.85)))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .help("Open the Granola import sheet")
            }

            Button {
                showAirtableImport = true
            } label: {
                HStack(spacing: 6) {
                    Text(airtableImporter.isConfigured ? "Sync Airtable CSVs" : "Connect Airtable")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "tablecells")
                        .font(.system(size: 10, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.orange.opacity(0.85)))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help("Export Airtable tables as CSV files")
            Spacer()
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 24)
    }

    private func refreshGranolaPendingCount() {
        let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
        Task.detached(priority: .background) {
            let count = await GranolaImporter.pendingImportCount(savedTo: dir)
            await MainActor.run {
                self.granolaPendingCount = count
            }
        }
    }

    private var disconnectedQuickActions: some View {
        HStack(spacing: 12) {
            Button("New Personal Note") {
                state.startNewNote()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Button("New Ad Hoc Meeting") {
                state.startAdHocCall()
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var todayCalendarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("Today")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                if GoogleCalendarService.shared.isSignedIn {
                    Button {
                        GoogleCalendarService.shared.invalidateTodayCache()
                        Task { await loadTodayEvents(userInitiated: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh calendar")
                }
            }
            .padding(.horizontal, 4)

            if !GoogleCalendarService.shared.isSignedIn {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button("Connect to Calendar") {
                            GoogleCalendarService.shared.signIn()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!GoogleCalendarService.isConfigured)
                        Text("BETA")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange))
                        Spacer()
                    }

                    Divider()

                    Text("Calendar access is invite-only while in beta. Send your email and it can be allow-listed.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !GoogleCalendarService.isConfigured {
                        Text("Google Calendar OAuth is not configured in this build.")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let authError = GoogleCalendarService.shared.authError {
                        Text(authError)
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        TextField("you@example.com", text: $whitelistEmail)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        Button(primaryWhitelistButtonLabel) {
                            sendWhitelistRequest(via: hasReliableMailClient ? .defaultMail : .gmail)
                        }
                        .disabled(!isLikelyEmail(whitelistEmail))
                    }
                    HStack(spacing: 4) {
                        Text(secondaryWhitelistPrompt)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Button(secondaryWhitelistButtonLabel) {
                            sendWhitelistRequest(via: hasReliableMailClient ? .gmail : .defaultMail)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                        .disabled(!isLikelyEmail(whitelistEmail))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } else if !todayEventsLoaded {
                HStack {
                    ProgressView().scaleEffect(0.6)
                    Text("Loading today's events…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } else if todayEvents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(todayEventsError == nil ? "No events today" : "No events to show")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    if let err = todayEventsError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        Button("Refresh") {
                            GoogleCalendarService.shared.invalidateTodayCache()
                            Task { await loadTodayEvents(userInitiated: true) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Disconnect") {
                            GoogleCalendarService.shared.signOut()
                            todayEventsLoaded = false
                            todayEvents = []
                            todayEventsError = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } else {
                if let err = todayEventsError {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    eventsList(now: context.date)
                }
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func eventsList(now: Date) -> some View {
        let timed = todayEvents.filter { !$0.isAllDay && $0.startDate != nil }
        let allDay = todayEvents.filter { $0.isAllDay }

        // Find the "current" event (start ≤ now ≤ end) and the "next-up" event (first future).
        let current = timed.first { e in
            guard let s = e.startDate, let end = e.endDate else { return false }
            return now >= s && now <= end
        }
        let nextUp = timed.first { ($0.startDate ?? .distantFuture) > now }

        // Decide where to insert the now line. Insert it just before the first event whose
        // start is >= now; if all events are in the past, append it at the end.
        let nowLineInsertIndex: Int? = {
            for (i, e) in timed.enumerated() {
                if (e.startDate ?? .distantFuture) >= now { return i }
            }
            return nil // all in past — append at end
        }()

        VStack(spacing: 0) {
            ForEach(allDay) { event in
                CalendarEventRow(event: event, countdownText: nil) {
                    state.startCalendarMeeting(event)
                }
                Divider()
            }

            ForEach(Array(timed.enumerated()), id: \.element.id) { idx, event in
                if nowLineInsertIndex == idx {
                    NowLineView(time: now)
                    Divider()
                }
                let countdown: String? = {
                    if event.id == current?.id { return countdownText(prefix: "ends in", until: event.endDate, now: now) }
                    if event.id == nextUp?.id, current == nil { return countdownText(prefix: "in", until: event.startDate, now: now) }
                    return nil
                }()
                CalendarEventRow(event: event, countdownText: countdown) {
                    state.startCalendarMeeting(event)
                }
                if idx != timed.count - 1 {
                    Divider()
                }
            }

            if nowLineInsertIndex == nil && !timed.isEmpty {
                Divider()
                NowLineView(time: now)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        .cornerRadius(8)
    }

    private func countdownText(prefix: String, until date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return nil }
        let formatted: String
        if seconds < 60 {
            formatted = "<1m"
        } else if seconds < 3600 {
            formatted = "\(seconds / 60)m"
        } else {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            formatted = m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(prefix) \(formatted)"
    }

    private func isLikelyEmail(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let at = trimmed.firstIndex(of: "@") else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return !domain.isEmpty && domain.contains(".") && trimmed.startIndex < at
    }

    private enum WhitelistTransport {
        case defaultMail
        case gmail
    }

    /// Bundle IDs we trust to actually handle mailto URLs reliably (i.e. real mail
    /// clients with configured accounts in the common case). Apple Mail is intentionally
    /// excluded — it's the system default whether or not the user has ever set up
    /// an account, and we have no way to detect configuration without Full Disk Access.
    /// Browsers are also excluded — they often "handle" mailto by falling back to the
    /// system default mail app, which loops us right back to the Apple Mail problem.
    private static let knownReliableMailClients: Set<String> = [
        "com.readdle.smartemail-Mac",  // Spark
        "it.bloop.airmail",             // Airmail
        "it.bloop.airmail3",
        "com.mimestream.Mimestream",
        "com.microsoft.Outlook",
        "com.flashlightsoft.flashemail", // Newton
        "com.freron.MailMate",
        "com.postbox-inc.postbox",
        "org.mozilla.thunderbird",
        "com.canarymail.macos",         // Canary
        "com.proton.mail",              // Proton Mail desktop
    ]

    /// True iff the system's default mailto handler is in the allow-list.
    /// If false, we route to Gmail web compose instead — which always works and
    /// avoids prompting the user to set up Apple Mail or some browser fallback chain.
    private var hasReliableMailClient: Bool {
        guard let url = URL(string: "mailto:test@example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url),
              let bundleID = Bundle(url: handler)?.bundleIdentifier else {
            return false
        }
        return Self.knownReliableMailClients.contains(bundleID)
    }

    private var primaryWhitelistButtonLabel: String {
        hasReliableMailClient ? "Request whitelist" : "Send via Gmail"
    }

    private var secondaryWhitelistPrompt: String {
        hasReliableMailClient ? "Prefer Gmail?" : "Want to use your mail app instead?"
    }

    private var secondaryWhitelistButtonLabel: String {
        hasReliableMailClient ? "Send via Gmail in browser" : "Try default mail app"
    }

    private func sendWhitelistRequest(via transport: WhitelistTransport) {
        let email = whitelistEmail.trimmingCharacters(in: .whitespaces)
        guard isLikelyEmail(email) else { return }
        let to = "support@example.invalid"
        let subject = "Whitelist request for Ghost Pepper"
        let body = "Please allow-list this email address for Ghost Pepper calendar integration: \(email)"
        let allowed = CharacterSet.urlQueryAllowed
        guard let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: allowed),
              let encodedBody = body.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return
        }
        let urlString: String
        switch transport {
        case .defaultMail:
            urlString = "mailto:\(to)?subject=\(encodedSubject)&body=\(encodedBody)"
        case .gmail:
            urlString = "https://mail.google.com/mail/?view=cm&fs=1&to=\(to)&su=\(encodedSubject)&body=\(encodedBody)"
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func loadTodayEvents(userInitiated: Bool = false) async {
        guard GoogleCalendarService.shared.isSignedIn else {
            todayEvents = []
            todayEventsError = nil
            todayEventsLoaded = false
            return
        }
        if !GoogleCalendarService.shared.hasLoadedStoredTokens {
            if userInitiated {
                GoogleCalendarService.shared.loadStoredConnectionForUserAction()
            } else {
                GoogleCalendarService.shared.loadStoredConnectionSilently()
            }
            guard GoogleCalendarService.shared.isSignedIn else {
                todayEvents = []
                todayEventsError = "Ghost Pepper couldn't access the stored Calendar connection. Reconnect Google Calendar."
                todayEventsLoaded = true
                return
            }
        }
        let result = await GoogleCalendarService.shared.eventsForToday()
        todayEvents = result.events
        todayEventsError = result.errorMessage
        todayEventsLoaded = true
    }
}

private struct NowLineView: View {
    let time: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(timeLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.orange)
                .frame(width: 70, alignment: .leading)
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
            Rectangle()
                .fill(Color.orange)
                .frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var timeLabel: String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: time)
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEvent
    let countdownText: String?
    let onStart: () -> Void

    private var timeText: String {
        if event.isAllDay { return "All day" }
        guard let start = event.startDate else { return "" }
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: start)
    }

    private var attendeeText: String? {
        guard event.attendeeCount > 0 else { return nil }
        if event.attendeeCount == 1 { return "1 person" }
        return "\(event.attendeeCount) people"
    }

    private var isPast: Bool {
        guard let end = event.endDate else { return false }
        return end < Date()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(timeText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)

            Text(event.title)
                .font(.system(size: 13))
                .foregroundColor(isPast ? .secondary : .primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let attendeeText = attendeeText {
                Text(attendeeText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if let countdownText {
                Text(countdownText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay(
                        Capsule().stroke(Color.orange.opacity(0.4), lineWidth: 1)
                    )
            }

            if !event.isAllDay {
                Button(action: onStart) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                        Text(event.meetLink != nil ? "Start & Join" : "Start")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .foregroundColor(.orange)
                    .overlay(
                        Capsule().stroke(Color.orange, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Content View for a Single Tab

// MARK: - File Tab View (observes individual tab)

private struct HomeTabView: View {
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isActive ? "house.fill" : "house")
                .font(.system(size: 11))
                .foregroundColor(isActive ? .orange : .secondary)
            Text("Home")
                .font(.system(size: 12))
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle().fill(Color.orange).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .help("Home")
    }
}

private struct FileTabView: View {
    @ObservedObject var tab: OpenMeetingTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if tab.isRecording {
                Circle().fill(.red).frame(width: 6, height: 6)
            }
            Text(tab.transcript.meetingName)
                .font(.system(size: 12))
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle().fill(Color.orange).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

private struct IndexTabView: View {
    @ObservedObject var tab: OpenIndexTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.content.iconSystemName)
                .font(.system(size: 10))
                .foregroundColor(isActive ? .orange : .secondary)
            Text(tab.content.title)
                .font(.system(size: 12))
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle().fill(Color.orange).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

/// Wraps a navigable tab. Renders the back button (when there's history) and
/// dispatches to either IndexEntryView or MeetingTabContentView depending on
/// what the tab currently holds. Cmd+[ goes back.
struct NavTabContentView: View {
    @ObservedObject var tab: OpenIndexTab
    @ObservedObject var state: MeetingWindowState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: { tab.goBack() }) {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 11))
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!tab.canGoBack)
                .opacity(tab.canGoBack ? 1 : 0.3)
                .help("Back" + (tab.canGoBack ? "" : " (no history)"))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))

            Divider()

            switch tab.content {
            case .indexEntry(_, _, let entry):
                IndexEntryView(
                    entry: entry,
                    saveDir: state.saveDirectory,
                    onOpenEntry: { kind, slug in
                        if let content = state.loadIndexEntryContent(kind: kind, slug: slug) {
                            tab.navigate(to: content)
                        }
                    },
                    onOpenMeeting: { path in
                        if let content = state.loadMeetingContent(relativePath: path) {
                            tab.navigate(to: content)
                        }
                    },
                    onOpenEntryInNewTab: { kind, slug in
                        state.openIndexEntry(kind: kind, slug: slug)
                    },
                    onOpenMeetingInNewTab: { path in
                        state.openMeetingInNewIndexTab(relativePath: path)
                    },
                    onRefresh: {
                        guard case let .indexEntry(kind, slug, e) = tab.content else { return }
                        state.pendingDossierApply = .init(kind: kind, slug: slug, canonicalName: e.canonicalName)
                        state.pendingQAPrompt = "Tell me about \(e.canonicalName)"
                    }
                )
            case .meeting(let meetingTab):
                MeetingTabContentView(tab: meetingTab, state: state)
            case .indexList(let kind):
                IndexListView(
                    kind: kind,
                    items: state.indexItems[kind] ?? [],
                    onOpenEntry: { kind, slug in
                        if let content = state.loadIndexEntryContent(kind: kind, slug: slug) {
                            tab.navigate(to: content)
                        }
                    },
                    onOpenEntryInNewTab: { kind, slug in
                        state.openIndexEntry(kind: kind, slug: slug)
                    },
                    onBuild: { state.presentBuildIndexSheet(for: kind) }
                )
            case .secondBrain:
                SecondBrainDashboardView(
                    state: state,
                    onBuildNextBatch: {
                        state.pendingGenerateWikiBatch = true
                    },
                    onLint: {
                        state.pendingSecondBrainLint = true
                    },
                    onOpenPage: { url in
                        if let content = state.loadGeneratedWikiPageContent(url) {
                            tab.navigate(to: content)
                        }
                    },
                    onOpenPageInNewTab: { url in
                        state.openGeneratedWikiPage(url)
                    },
                    onArchive: {
                        state.loadGeneratedWikiFolders()
                    }
                )
            case .generatedWikiPage(let page):
                GeneratedWikiPageView(
                    page: page,
                    onSave: { page, body in
                        let updated = try state.saveGeneratedWikiPage(page, body: body)
                        tab.content = .generatedWikiPage(updated)
                    },
                    onRename: { page, newName in
                        let updated = try state.renameGeneratedWikiPage(page, to: newName)
                        tab.content = .generatedWikiPage(updated)
                        return updated
                    },
                    onChangeType: { page, newType in
                        let updated = try state.changeGeneratedWikiPageType(page, to: newType)
                        tab.content = .generatedWikiPage(updated)
                        return updated
                    },
                    onOpenWikilink: { slug in
                        if let url = state.resolveGeneratedWikilink(slug: slug),
                           let content = state.loadGeneratedWikiPageContent(url) {
                            tab.navigate(to: content)
                        }
                    },
                    onOpenWikilinkInNewTab: { slug in
                        if let url = state.resolveGeneratedWikilink(slug: slug) {
                            state.openGeneratedWikiPage(url)
                        }
                    },
                    onResolveWikilinkTitle: { slug in
                        guard let url = state.resolveGeneratedWikilink(slug: slug),
                              let page = try? GeneratedWikiPaths.readPage(from: url) else {
                            return nil
                        }
                        return page.title
                    },
                    onOpenSourceMeeting: { path in
                        if let content = state.loadMeetingContent(relativePath: path) {
                            tab.navigate(to: content)
                        }
                    }
                )
            case .airtableTable(let table):
                AirtableTablePreviewView(table: table)
            }
        }
        .background(
            BrowserBackEventBridge(
                canGoBack: tab.canGoBack,
                onBack: { tab.goBack() }
            )
        )
    }
}

private struct BrowserBackEventBridge: NSViewRepresentable {
    var canGoBack: Bool
    var onBack: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> BackEventView {
        let view = BackEventView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.window = window
        }
        return view
    }

    func updateNSView(_ nsView: BackEventView, context: Context) {
        context.coordinator.canGoBack = canGoBack
        context.coordinator.onBack = onBack
        context.coordinator.installMonitorIfNeeded()
    }

    static func dismantleNSView(_ nsView: BackEventView, coordinator: Coordinator) {
        coordinator.uninstallMonitor()
    }

    final class Coordinator {
        weak var window: NSWindow?
        var canGoBack: Bool = false
        var onBack: (() -> Void)?
        private var monitor: Any?
        private var accumulatedHorizontalScroll: CGFloat = 0
        private var accumulatedVerticalScroll: CGFloat = 0
        private var lastBackAt: Date = .distantPast

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.swipe, .scrollWheel]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func uninstallMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard canGoBack,
                  event.window === window,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                return event
            }

            switch event.type {
            case .swipe:
                if event.deltaX > 0.35 {
                    goBack()
                    return nil
                }
            case .scrollWheel:
                return handleScrollWheel(event)
            default:
                break
            }
            return event
        }

        private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
            if event.phase.contains(.began) {
                accumulatedHorizontalScroll = 0
                accumulatedVerticalScroll = 0
            }

            if event.phase.contains(.changed) || event.phase.contains(.mayBegin) {
                accumulatedHorizontalScroll += event.scrollingDeltaX
                accumulatedVerticalScroll += event.scrollingDeltaY
            }

            guard event.phase.contains(.ended) || event.phase.contains(.cancelled) else {
                return event
            }

            defer {
                accumulatedHorizontalScroll = 0
                accumulatedVerticalScroll = 0
            }

            guard abs(accumulatedHorizontalScroll) > abs(accumulatedVerticalScroll) * 1.8,
                  accumulatedHorizontalScroll > 70 else {
                return event
            }

            goBack()
            return nil
        }

        private func goBack() {
            let now = Date()
            guard now.timeIntervalSince(lastBackAt) > 0.35 else { return }
            lastBackAt = now
            onBack?()
        }
    }

    final class BackEventView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }
}

private struct SecondBrainLintSheet: View {
    @ObservedObject var run: SecondBrainLintRun
    let onCancel: () -> Void
    let onApply: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                leftRail
                    .frame(width: 280)
                Divider()
                detailPane
            }
        }
        .frame(width: 960, height: 680)
        .interactiveDismissDisabled(run.isRunning)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: run.errorMessage == nil ? "checklist" : "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(run.errorMessage == nil ? .orange : .red)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Linting 2nd Brain")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Generated pages only")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(run.status)
                        .font(.system(size: 12))
                        .foregroundColor(run.errorMessage == nil ? .secondary : .red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    Text("\(run.scannedPages)/\(max(run.totalPages, run.scannedPages)) pages")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("\(run.proposals.count) proposals · \(run.acceptedCount) accepted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if run.isRunning {
                    Button("Stop", action: onCancel)
                        .buttonStyle(.bordered)
                } else if run.resultMessage == nil, run.errorMessage == nil {
                    Button("Apply accepted", action: onApply)
                        .buttonStyle(.borderedProminent)
                        .disabled(run.acceptedCount == 0)
                } else {
                    Button("Close", action: onClose)
                        .buttonStyle(.borderedProminent)
                }
            }

            ProgressView(value: run.progressFraction)
                .tint(run.errorMessage == nil ? .orange : .red)
        }
        .padding(18)
    }

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lint progress")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            lintProgressRow(title: "Pages", value: "\(run.scannedPages) of \(max(run.totalPages, run.scannedPages))", isActive: run.isRunning)
            lintProgressRow(title: "Proposals", value: "\(run.proposals.count)", isActive: run.isRunning)
            lintProgressRow(title: "Accepted", value: "\(run.acceptedCount)", isActive: !run.isRunning && run.resultMessage == nil)
            lintProgressRow(title: "Applied", value: "\(run.appliedChanges)", isActive: run.resultMessage != nil)

            Divider()

            Text("Checks")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            checkCard(title: "Duplicate entities", status: run.isRunning ? "scanning..." : "complete")
            checkCard(title: "Duplicate topics", status: run.isRunning ? "scanning..." : "complete")
            checkCard(title: "Duplicate claims", status: run.isRunning ? "scanning..." : "complete")

            Spacer()

            CopyButton(text: { run.trace }, label: "Copy trace")
                .help("Copy lint scan trace and proposals")
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if run.isRunning || run.proposals.isEmpty {
                Text(run.isRunning ? "Scanning pages" : "Result")
                    .font(.system(size: 15, weight: .semibold))
                terminalView
            }

            if !run.proposals.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Review proposed changes")
                            .font(.system(size: 16, weight: .semibold))
                        Text("\(run.proposals.count) merge proposal\(run.proposals.count == 1 ? "" : "s") · \(run.acceptedCount) accepted")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Accept all") {
                        for proposal in run.proposals {
                            run.setProposalAccepted(proposal, accepted: true)
                        }
                    }
                    .buttonStyle(.bordered)
                    Button("Skip all") {
                        for proposal in run.proposals {
                            run.setProposalAccepted(proposal, accepted: false)
                        }
                    }
                    .buttonStyle(.bordered)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(run.proposals) { proposal in
                            proposalRow(proposal)
                        }
                    }
                }
            }

            if let error = run.errorMessage {
                resultCard(title: "Error", systemImage: "exclamationmark.triangle", tint: .red) {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } else if let result = run.resultMessage {
                resultCard(title: "Result", systemImage: "checkmark.circle", tint: .green) {
                    Text(result)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(18)
    }

    private var terminalView: some View {
        ScrollView {
            Text(run.trace.isEmpty ? "[status] Preparing lint scan..." : run.trace)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(14)
        }
        .background(Color.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func proposalRow(_ proposal: SecondBrainLintProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(proposal.kind.rawValue): \(proposal.sourceTitle)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(proposal.categoryLabel) · \(proposal.confidence) confidence")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(confidenceColor(proposal.confidence))
                }
                Spacer()
                Button {
                    run.setProposalAccepted(proposal, accepted: true)
                } label: {
                    Label("Accept", systemImage: proposal.accepted ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(proposal.accepted ? .green : nil)

                Button {
                    run.setProposalAccepted(proposal, accepted: false)
                } label: {
                    Label("Skip", systemImage: proposal.accepted ? "circle" : "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .tint(proposal.accepted ? nil : .red)
            }

            Text("Merge into: \(proposal.targetTitle)")
                .font(.system(size: 12, weight: .medium))
            Text(proposal.reason)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("\(relativePath(proposal.sourceURL)) -> \(relativePath(proposal.targetURL))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func lintProgressRow(title: String, value: String, isActive: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "circle.dotted" : "checkmark.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? .orange : .secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func checkCard(title: String, status: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(status)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func resultCard<Content: View>(
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func confidenceColor(_ confidence: String) -> Color {
        switch confidence {
        case "high": return .green
        case "medium": return .orange
        default: return .red
        }
    }

    private func relativePath(_ url: URL) -> String {
        let base = run.archiveRoot.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(base + "/") else { return url.lastPathComponent }
        return String(full.dropFirst(base.count + 1))
    }
}

private struct WikiGenerationConsoleSheet: View {
    @ObservedObject var run: WikiGenerationRun
    let onCancel: () -> Void
    let onOpenOverview: () -> Void
    let onClose: () -> Void
    let onMinimize: (() -> Void)?
    @State private var showPrompt: Bool = false
    @State private var pepperPulse: Bool = false
    @State private var displayNow: Date = Date()

    var body: some View {
        batchWorkbenchOverlay
            .transition(.opacity)
        .frame(
            width: 980,
            height: 720
        )
        .interactiveDismissDisabled(run.isRunning)
        .onAppear {
            pepperPulse = true
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            displayNow = now
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: run.errorMessage == nil ? "brain.head.profile" : "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(run.errorMessage == nil ? .orange : .red)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Adding to 2nd Brain")
                        .font(.system(size: 18, weight: .semibold))
                    Text(run.meetingTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(run.status)
                        .font(.system(size: 12))
                        .foregroundColor(run.errorMessage == nil ? .secondary : .red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if run.isRunning {
                        Text(activeProcessingText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let next = nextSourceSummaryText {
                            Text(next)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.orange.opacity(0.9))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Spacer()

	                VStack(alignment: .trailing, spacing: 5) {
	                    Text(tokenCounterText)
	                        .font(.system(size: 12, design: .monospaced))
	                        .foregroundStyle(.secondary)
	                    if let selected = run.selectedFunction {
	                        Text(throughputText(for: selected))
	                            .font(.system(size: 10, design: .monospaced))
	                            .foregroundStyle(.secondary)
	                    }
	                    Text("\(run.modelCallsCompleted)/\(run.modelCallTotal) model calls")
	                        .font(.system(size: 11, weight: .medium))
	                        .foregroundStyle(.secondary)
                    if run.isRunning, run.activeOutputTokenEstimate > 0 {
                        Text("current call ~\(run.activeOutputTokenEstimate) out")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if run.isRunning {
                    Button("Stop", action: onCancel)
                        .buttonStyle(.bordered)
                } else {
                    Button("Close", action: onClose)
                        .buttonStyle(.borderedProminent)
                }
            }

            ProgressView(value: run.progressFraction)
                .tint(run.errorMessage == nil ? .orange : .red)
        }
        .padding(18)
    }

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(run.isBatch ? "Batch progress" : "Meeting progress")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                progressRow(
                    title: run.isBatch ? "Sources" : "Meeting",
                    value: sourceProgressText,
                    isActive: run.isRunning
                )
                progressRow(
                    title: "Model calls",
                    value: modelCallProgressText,
                    isActive: run.isRunning
                )
	                progressRow(
	                    title: "Current call",
	                    value: currentCallProgressText,
	                    isActive: run.isRunning && run.selectedFunction?.isFinished == false
	                )
	                progressRow(
	                    title: "Throughput",
	                    value: run.selectedFunction.map { throughputText(for: $0) } ?? "waiting",
	                    isActive: run.isRunning && run.selectedFunction?.isFinished == false
	                )
                if run.isBatch, run.nextSourceTitle != nil {
                    progressRow(
                        title: "Next source",
                        value: nextSourceRailText,
                        isActive: run.reviewDraft != nil
                    )
                }
	                progressRow(
	                    title: "Files saved",
	                    value: "\(run.savedRelativePaths.count)",
	                    isActive: run.status.hasPrefix("Saved")
	                )
            }

            Divider()

            Text("Steps")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(run.functions) { function in
                        Button {
                            run.selectedFunctionID = function.id
                        } label: {
                            functionCard(function)
                        }
                        .buttonStyle(.plain)
                    }

                    if run.functions.isEmpty {
                        Text("The first model call will appear here.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                }
            }

            Spacer()

            CopyButton(text: { run.fullDebugText() }, label: "Copy trace")
            .help("Copy prompts, model output, saved files, and token counts")
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let selected = run.selectedFunction {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selected.name)
                            .font(.system(size: 15, weight: .semibold))
                        Text(functionStatusText(selected))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        showPrompt.toggle()
                    } label: {
                        Label(showPrompt ? "Hide prompt" : "Show prompt", systemImage: showPrompt ? "chevron.down" : "chevron.right")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                }

                if showPrompt {
                    promptTrace(selected)
                        .frame(maxHeight: 210)
                }
            } else {
                Text("Starting...")
                    .font(.system(size: 15, weight: .semibold))
            }

            if let draft = run.reviewDraft {
                reviewDeck(draft)
            } else {
                terminalView
            }

	            if run.reviewDraft != nil {
	                EmptyView()
	            } else if let error = run.errorMessage {
	                resultCard(title: "Error", systemImage: "exclamationmark.triangle", tint: .red) {
	                    Text(error)
	                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } else if let result = run.result {
                resultCard(title: "Result", systemImage: "checkmark.circle", tint: .green) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(result.gitMessage)
                            .font(.system(size: 12))
                            .textSelection(.enabled)

                        HStack {
                            Button(openOverviewButtonTitle, action: onOpenOverview)
                                .buttonStyle(.borderedProminent)
                            Text("Saved \(run.savedRelativePaths.count) files")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            } else if !run.savedRelativePaths.isEmpty {
                resultCard(title: "Saved files", systemImage: "doc.text", tint: .orange) {
                    savedFilesList
                }
            }
        }
	        .padding(18)
	    }

    private func reviewDeck(_ draft: GeneratedWikiReviewDraft) -> some View {
        reviewPane(draft)
    }

    private func reviewPane(_ draft: GeneratedWikiReviewDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review before saving")
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(draft.entities.count) entities · \(draft.topics.count) topics · \(draft.claimCount) claims · source \(draft.meetingPath)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Keep all") {
                    run.keepAllReviewItems()
                }
                .buttonStyle(.bordered)
                Button("Save approved") {
                    run.completeReview()
                }
                .buttonStyle(.borderedProminent)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    reviewSection(title: "Entities", systemImage: "link") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(draft.entities) { entity in
                                entityReviewRow(entity)
                            }
                            if draft.entities.isEmpty {
                                Text("(none)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    reviewSection(title: "Topics", systemImage: "list.bullet.rectangle") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(draft.topics) { topic in
                                topicReviewRow(topic)
                            }
                            if draft.topics.isEmpty {
                                Text("(none)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    reviewSection(title: "Claims", systemImage: "quote.bubble") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(draft.claims) { claim in
                                claimReviewRow(claim)
                            }
                            if draft.claimCount == 0 {
                                Text("(none)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.24), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 22, x: 0, y: 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func preloadingWindowBehind(title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                pepperCharacter(size: 18)
                Text("Ghost Pepper Import")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("background")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.84))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(red: 0.04, green: 0.14, blue: 0.48).opacity(0.88))

            HStack(spacing: 10) {
                pepperCharacter(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.nextSourceReviewDraft == nil ? "Pre-loading next meeting" : "Ready for entity approval")
                        .font(.system(size: 13, weight: .semibold))
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .opacity(run.nextSourceReviewDraft == nil ? 1 : 0)
                if run.nextSourceReviewDraft != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Text(run.nextSourceStatus ?? "Queued for background pre-load")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(nextPreloadTerminalText(title: title))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.black.opacity(0.78))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(0)
        .frame(width: 820, height: 430, alignment: .topLeading)
        .background(Color(red: 0.78, green: 0.78, blue: 0.72).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(Color.black.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 10)
        .opacity(0.72)
        .scaleEffect(0.975, anchor: .center)
    }

    private func nextPreloadTerminalText(title: String) -> String {
        if !run.nextSourceTerminalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return run.nextSourceTerminalText
        }
        let tokenLine: String
        if let tokens = run.nextSourceInputTokens {
            tokenLine = "[input] ~\(tokens.formatted()) input tokens loaded"
        } else {
            tokenLine = "[load] reading source file"
        }
        return """
        [next] \(title)
        \(tokenLine)
        [queue] waiting for current approvals
        """
    }

    private func reviewSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func entityReviewRow(_ entity: GeneratedWikiReviewEntityDraft) -> some View {
        let decision = run.reviewEntityDecisions[entity.id] ?? GeneratedWikiEntityReviewDecision(keep: true, canonicalName: entity.defaultCanonicalName, proposedName: entity.name, type: entity.type)
        let isDiscarded = !decision.keep
        let mergeTarget = decision.canonicalName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isMerged = decision.keep && !mergeTarget.isEmpty
        let isKept = decision.keep && mergeTarget.isEmpty
        let selectedType = decision.type ?? entity.type
        let proposedName = Binding<String>(
            get: {
                run.reviewEntityDecisions[entity.id]?.proposedName ?? entity.name
            },
            set: { value in
                run.setEntityProposedName(entity, proposedName: value)
            }
        )
        let entityType = Binding<String>(
            get: {
                run.reviewEntityDecisions[entity.id]?.type ?? entity.type
            },
            set: { value in
                run.setEntityType(entity, type: value)
            }
        )
        let mergeOptions = orderedMergeOptions(for: entity, selectedType: selectedType, selected: mergeTarget)
        let mergeSelection = Binding<String>(
            get: {
                let currentDecision = run.reviewEntityDecisions[entity.id]
                let canonical = currentDecision == nil ? entity.defaultCanonicalName : currentDecision?.canonicalName
                let currentCanonical = canonical ?? ""
                if currentCanonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "__none__"
                }
                return currentCanonical
            },
            set: { value in
                let cleaned = value == "__none__" ? "" : value.trimmingCharacters(in: .whitespacesAndNewlines)
                run.setEntityDecision(entity, keep: true, canonicalName: cleaned.isEmpty ? nil : cleaned)
            }
        )
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(isMerged ? "Merge Entity:" : isDiscarded ? "Discard Entity:" : "New Entity:")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isDiscarded ? .secondary : .primary)
                        TextField("Entity name", text: proposedName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isDiscarded ? .secondary : .primary)
                            .disabled(isDiscarded || isMerged)
                            .frame(minWidth: 120, maxWidth: 260, alignment: .leading)
                    }
                    HStack(spacing: 8) {
                        Picker("Entity type", selection: entityType) {
                            Text("Person").tag("Person")
                            Text("Company").tag("Company")
                            Text("Concept").tag("Concept")
                        }
                        .labelsHidden()
                        .frame(width: 118)
                        .disabled(isDiscarded || isMerged)
                        Text(entity.resolutionLabel)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        confidenceBadge(entity.confidence)
                    }
                }
                Spacer()
                Button {
                    run.setEntityDecision(entity, keep: true, canonicalName: nil)
                } label: {
                    Label("Add", systemImage: isKept ? "checkmark.circle.fill" : "plus.circle")
                }
                .buttonStyle(.bordered)
                .tint(isKept ? .green : nil)
                Button {
                    let target = mergeTarget.isEmpty
                        ? (entity.suggestedMatches.first ?? entity.mergeOptions.first ?? "")
                        : mergeTarget
                    run.setEntityDecision(entity, keep: true, canonicalName: target.isEmpty ? nil : target)
                } label: {
                    Label("Merge", systemImage: isMerged ? "checkmark.circle.fill" : "arrow.triangle.merge")
                }
                .buttonStyle(.bordered)
                .tint(isMerged ? .blue : nil)
                .disabled(entity.suggestedMatches.isEmpty && entity.mergeOptions.isEmpty && mergeTarget.isEmpty)
                Button {
                    run.setEntityDecision(entity, keep: false, canonicalName: nil)
                } label: {
                    Label("Discard", systemImage: isDiscarded ? "checkmark.circle.fill" : "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(isDiscarded ? .red : nil)
            }

            if !entity.context.isEmpty {
                Text(entity.context)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !entity.sourceSnippet.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Source context")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(entity.sourceSnippet)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Merge with")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Picker("Merge with", selection: mergeSelection) {
                        Text("Select existing entity").tag("__none__")
                        if !entity.suggestedMatches.isEmpty {
                            Section("Suggested") {
                                ForEach(entity.suggestedMatches, id: \.self) { match in
                                    Text(match).tag(match)
                                }
                            }
                        }
                        Section("All \(selectedType)") {
                            ForEach(mergeOptions.prefix(80), id: \.self) { match in
                                Text(match).tag(match)
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    .disabled(isDiscarded || mergeOptions.isEmpty)
                    .onChange(of: mergeSelection.wrappedValue) { _, value in
                        let cleaned = value == "__none__" ? "" : value.trimmingCharacters(in: .whitespacesAndNewlines)
                        run.setEntityDecision(entity, keep: true, canonicalName: cleaned.isEmpty ? nil : cleaned)
                    }
                }

                if isMerged {
                    Text("Selected merge target: \(mergeTarget)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if !entity.suggestedMatches.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Suggested matches")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(entity.suggestedMatches, id: \.self) { match in
                            Button {
                                run.setEntityDecision(entity, keep: true, canonicalName: match)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: mergeTarget == match ? "checkmark.circle.fill" : "arrow.triangle.merge")
                                    Text(match)
                                        .fontWeight(.semibold)
                                    Text(entity.suggestedMatchReasons[match] ?? "Possible existing entity.")
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .disabled(isDiscarded)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDiscarded ? Color.red.opacity(0.06) : Color.black.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func orderedMergeOptions(for entity: GeneratedWikiReviewEntityDraft, selectedType: String, selected: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        let typeOptions = entity.mergeOptionsByType[selectedType] ?? entity.mergeOptions
        let suggested = selectedType == entity.type ? entity.suggestedMatches : []
        for value in ([selected] + suggested + typeOptions) {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            ordered.append(cleaned)
        }
        return ordered
    }

    private func topicReviewRow(_ topic: GeneratedWikiReviewTopicDraft) -> some View {
        let decision = run.reviewTopicDecisions[topic.id] ?? GeneratedWikiTopicReviewDecision(keep: true, canonicalTopic: topic.indexCandidate ? (topic.suggestedCanonicalTopic ?? topic.suggestedMatches.first ?? topic.topic) : nil, topic: topic.topic)
        let isDiscarded = !decision.keep
        let connectTarget = decision.canonicalTopic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isConnected = decision.keep && !connectTarget.isEmpty
        let isKept = decision.keep && connectTarget.isEmpty
        let topicTitle = Binding<String>(
            get: { run.reviewTopicDecisions[topic.id]?.topic ?? topic.topic },
            set: { run.setTopicTitle(topic, title: $0) }
        )
        let connectOptions = orderedTopicConnectOptions(for: topic, selected: connectTarget)
        let connectSelection = Binding<String>(
            get: {
                let current = run.reviewTopicDecisions[topic.id]?.canonicalTopic ?? ""
                return current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "__none__" : current
            },
            set: { value in
                let cleaned = value == "__none__" ? "" : value.trimmingCharacters(in: .whitespacesAndNewlines)
                run.setTopicDecision(topic, keep: true, canonicalTopic: cleaned.isEmpty ? nil : cleaned)
            }
        )
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(isConnected ? "Connect Topic:" : isDiscarded ? "Discard Topic:" : "Keep Topic:")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isDiscarded ? .secondary : .primary)
                        TextField("Topic", text: topicTitle)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .disabled(isDiscarded || isConnected)
                            .frame(minWidth: 140, maxWidth: 320, alignment: .leading)
                    }
                    if topic.indexCandidate {
                        Text(topic.suggestedCanonicalTopic?.isEmpty == false ? "suggested reusable topic -> \(topic.suggestedCanonicalTopic!)" : "suggested reusable topic")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    run.setTopicDecision(topic, keep: true, canonicalTopic: nil)
                } label: {
                    Label("Keep", systemImage: isKept ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(isKept ? .green : nil)
                Button {
                    let target = connectTarget.isEmpty
                        ? (topic.suggestedMatches.first ?? topic.mergeOptions.first ?? topicTitle.wrappedValue)
                        : connectTarget
                    run.setTopicDecision(topic, keep: true, canonicalTopic: target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : target)
                } label: {
                    Label("Connect", systemImage: isConnected ? "checkmark.circle.fill" : "link")
                }
                .buttonStyle(.bordered)
                .tint(isConnected ? .blue : nil)
                Button {
                    run.setTopicDecision(topic, keep: false, canonicalTopic: nil)
                } label: {
                    Label("Discard", systemImage: isDiscarded ? "checkmark.circle.fill" : "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(isDiscarded ? .red : nil)
            }
            if !topic.description.isEmpty {
                Text(topic.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text("Connect to")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("Connect topic to", selection: connectSelection) {
                    Text("Just this meeting").tag("__none__")
                    if !topic.suggestedMatches.isEmpty {
                        Section("Suggested") {
                            ForEach(topic.suggestedMatches, id: \.self) { match in
                                Text(match).tag(match)
                            }
                        }
                    }
                    Section("All topics") {
                        ForEach(connectOptions.prefix(80), id: \.self) { match in
                            Text(match).tag(match)
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                .disabled(isDiscarded)
                if isConnected {
                    Text(connectTarget)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !topic.indexReason.isEmpty || (isConnected && topic.indexReason.isEmpty) {
                Text(topic.indexReason.isEmpty ? "Connected during review." : topic.indexReason)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDiscarded ? Color.red.opacity(0.06) : Color.black.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func orderedTopicConnectOptions(for topic: GeneratedWikiReviewTopicDraft, selected: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for value in ([selected] + topic.suggestedMatches + topic.mergeOptions) {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            ordered.append(cleaned)
        }
        return ordered
    }

    private func claimReviewRow(_ claim: GeneratedWikiReviewClaimDraft) -> some View {
        let decision = run.reviewClaimDecisions[claim.id] ?? GeneratedWikiClaimReviewDecision(
            keep: true,
            canonicalClaim: claim.indexCandidate ? (claim.suggestedCanonicalClaim ?? claim.suggestedMatches.first ?? claim.text) : nil,
            text: claim.text
        )
        let isDiscarded = !decision.keep
        let mergeTarget = decision.canonicalClaim?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isConnected = decision.keep && !mergeTarget.isEmpty
        let isMeetingOnly = decision.keep && mergeTarget.isEmpty
        let statusColor: Color = isDiscarded ? .secondary : isConnected ? .blue : .green
        let mergeOptions = orderedClaimMergeOptions(for: claim, selected: mergeTarget)
        let claimText = Binding<String>(
            get: { run.reviewClaimDecisions[claim.id]?.text ?? claim.text },
            set: { run.setClaimText(claim, text: $0) }
        )
        let mergeSelection = Binding<String>(
            get: {
                let current = run.reviewClaimDecisions[claim.id]?.canonicalClaim ?? ""
                if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "__none__"
                }
                return current
            },
            set: { value in
                let cleaned = value == "__none__" ? "" : value.trimmingCharacters(in: .whitespacesAndNewlines)
                run.setClaimDecision(claim, keep: true, canonicalClaim: cleaned.isEmpty ? nil : cleaned)
            }
        )
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isDiscarded ? "xmark.circle" : isConnected ? "link" : "checkmark.circle.fill")
                    .foregroundStyle(statusColor)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(isConnected ? "Connect Claim" : isDiscarded ? "Discard Claim" : "Keep Claim")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isDiscarded ? .secondary : .primary)
                    confidenceBadge(claim.confidence)
                    if claim.indexCandidate, !claim.indexReason.isEmpty {
                        Text(claim.indexReason)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    TextField("Claim", text: claimText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .lineLimit(2...4)
                        .disabled(isDiscarded)
                    if !claim.sourceContext.isEmpty {
                        Text(claim.sourceContext)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    run.setClaimDecision(claim, keep: true, canonicalClaim: nil)
                } label: {
                    Label("Keep", systemImage: isMeetingOnly ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(isMeetingOnly ? .green : nil)

                Button {
                    let target = mergeTarget.isEmpty
                        ? (claim.suggestedCanonicalClaim ?? claim.suggestedMatches.first ?? (run.reviewClaimDecisions[claim.id]?.text ?? claim.text))
                        : mergeTarget
                    run.setClaimDecision(claim, keep: true, canonicalClaim: target.isEmpty ? nil : target)
                } label: {
                    Label("Connect", systemImage: isConnected ? "checkmark.circle.fill" : "link")
                }
                .buttonStyle(.bordered)
                .tint(isConnected ? .blue : nil)

                Button {
                    run.setClaimDecision(claim, keep: false, canonicalClaim: nil)
                } label: {
                    Label("Discard", systemImage: isDiscarded ? "checkmark.circle.fill" : "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(isDiscarded ? .red : nil)
            }

            HStack(spacing: 8) {
                Text("Connect to")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("Merge claim with", selection: mergeSelection) {
                    Text("Just this meeting").tag("__none__")
                    Text("New claim index: \(String((run.reviewClaimDecisions[claim.id]?.text ?? claim.text).prefix(64)))").tag(run.reviewClaimDecisions[claim.id]?.text ?? claim.text)
                    if !claim.suggestedMatches.isEmpty {
                        Section("Suggested") {
                            ForEach(claim.suggestedMatches, id: \.self) { match in
                                Text(match).tag(match)
                            }
                        }
                    }
                    Section("All claims") {
                        ForEach(mergeOptions.prefix(80), id: \.self) { match in
                            Text(match).tag(match)
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                .disabled(isDiscarded)
            }

            if isConnected {
                Text("Selected claim index target: \(mergeTarget)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if !claim.suggestedMatches.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Suggested claims")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(claim.suggestedMatches, id: \.self) { match in
                        Button {
                            run.setClaimDecision(claim, keep: true, canonicalClaim: match)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: mergeTarget == match ? "checkmark.circle.fill" : "link")
                                Text(match)
                                    .fontWeight(.semibold)
                                Text(claim.suggestedMatchReasons[match] ?? "Possible existing claim.")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .disabled(isDiscarded)
                    }
                }
            }
        }
        .padding(8)
        .background(isDiscarded ? Color.red.opacity(0.06) : Color.black.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func orderedClaimMergeOptions(for claim: GeneratedWikiReviewClaimDraft, selected: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for value in ([selected, claim.suggestedCanonicalClaim ?? "", claim.text] + claim.suggestedMatches + claim.mergeOptions) {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            ordered.append(cleaned)
        }
        return ordered
    }

    private var terminalView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(run.terminalText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .id("terminal-bottom")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .onChange(of: run.terminalText) { _, _ in
                proxy.scrollTo("terminal-bottom", anchor: .bottom)
            }
        }
    }

    private var batchWorkbenchOverlay: some View {
        VStack(spacing: 0) {
            windows95TitleBar

            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    pepperCharacter(size: run.reviewDraft == nil ? 92 : 58)
                        .scaleEffect(pepperPulse ? 1.035 : 0.965)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pepperPulse)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(run.reviewDraft == nil ? "Pre-loading..." : "Approve imported entities")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(.black)
                        Text(activeProcessingText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.black.opacity(0.74))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(run.status)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.black.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(tokenCounterText)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.black)
                        Text(sourceProgressText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.black.opacity(0.68))
                        if let selected = run.selectedFunction {
                            Text(throughputText(for: selected))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.black.opacity(0.68))
                        }
                    }
                }

                if let draft = run.reviewDraft {
                    VStack(spacing: 10) {
                        reviewPane(draft)
                            .frame(height: shouldShowNextSourceInlinePanel ? 398 : 516)
                        if shouldShowNextSourceInlinePanel {
                            nextSourceInlinePanel
                                .frame(height: 110)
                        }
                    }
                } else if run.errorMessage != nil {
                    windows95ErrorPanel
                        .frame(height: 518)
                } else {
                    VStack(spacing: 10) {
                        terminalView
                            .frame(height: shouldShowNextSourceInlinePanel ? 416 : 516)
                        if shouldShowNextSourceInlinePanel {
                            nextSourceInlinePanel
                                .frame(height: 90)
                        }
                    }
                }
            }
            .padding(18)
            .background(Color(red: 0.78, green: 0.78, blue: 0.72))

            windows95StatusBar
        }
        .frame(width: 980, height: 720)
        .background(Color(red: 0.78, green: 0.78, blue: 0.72))
        .overlay(
            Rectangle()
                .stroke(Color.black.opacity(0.55), lineWidth: 1)
        )
    }

    private var windows95ErrorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.red)
                Text("Import stopped")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                Spacer()
            }
            Text(run.errorMessage ?? "Unknown error")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
            terminalView
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.72, green: 0.72, blue: 0.67))
        .overlay(Rectangle().stroke(Color.black.opacity(0.42), lineWidth: 1))
    }

    private var nextSourceInlinePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: nextSourceInlineIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(nextSourceInlineTint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(nextSourceInlineTitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                    if let title = run.nextSourceTitle {
                        Text(title)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.black.opacity(0.64))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                if run.nextSourceReviewDraft == nil && !run.nextSourceFailed {
                    ProgressView()
                        .controlSize(.small)
                }
                if let tokens = run.nextSourceInputTokens {
                    Text("~\(tokens.formatted()) in")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.68))
                }
            }

            Text(nextPreloadTerminalText(title: run.nextSourceTitle ?? "next meeting"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.84))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.78))
                .overlay(Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .padding(10)
        .background(Color(red: 0.72, green: 0.72, blue: 0.67))
        .overlay(Rectangle().stroke(Color.black.opacity(0.42), lineWidth: 1))
    }

    private var windows95TitleBar: some View {
        HStack(spacing: 8) {
            pepperCharacter(size: 20)
            Text("Ghost Pepper Import")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Text(run.isBatch ? "next 50" : "meeting")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
            if let onMinimize, !run.isBatch {
                Button(action: onMinimize) {
                    Text("Minimize")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.86, green: 0.86, blue: 0.82))
                        .overlay(Rectangle().stroke(Color.black.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Button(action: run.isRunning ? onCancel : onClose) {
                Text(run.isRunning ? "Stop" : "Close")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.86, green: 0.86, blue: 0.82))
                    .overlay(Rectangle().stroke(Color.black.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(red: 0.04, green: 0.14, blue: 0.48))
    }

    private var windows95StatusBar: some View {
        HStack(spacing: 8) {
            Text(run.reviewDraft == nil ? "Streaming local model output" : "Waiting for approval")
            Spacer()
            if let next = nextSourceSummaryText {
                Text(next)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.black.opacity(0.72))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(red: 0.72, green: 0.72, blue: 0.67))
        .overlay(Rectangle().stroke(Color.white.opacity(0.45), lineWidth: 1))
    }

    @ViewBuilder
    private func pepperCharacter(size: CGFloat) -> some View {
        if let image = NSImage(named: "ghost-pepper-character") ?? Bundle.main.image(forResource: "ghost-pepper-character") {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "brain.head.profile")
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: size, height: size)
        }
    }

    private var openOverviewButtonTitle: String {
        run.isBatch ? "Open first overview" : "Open meeting overview"
    }

    private var activeProcessingText: String {
        if run.isBatch {
            let index = max(1, run.currentSourceIndex)
            if run.isWaitingForPreparedSource {
                return "Finishing source \(index) of \(run.totalSourceCount): \(run.currentSourceTitle)"
            }
            return "Processing source \(index) of \(run.totalSourceCount): \(run.currentSourceTitle)"
        }
        return "Processing \(run.currentSourceTitle)"
    }

    private var nextSourceSummaryText: String? {
        guard run.isBatch, !run.isWaitingForPreparedSource, let title = run.nextSourceTitle else { return nil }
        let status = run.nextSourceStatus ?? "Queued"
        return "Next up: \(title) · \(status)"
    }

    private var shouldShowNextSourceInlinePanel: Bool {
        run.nextSourceTitle != nil && !run.isWaitingForPreparedSource
    }

    private var nextSourceInlineTitle: String {
        if run.nextSourceFailed {
            return "Next meeting failed"
        }
        if run.nextSourceReviewDraft != nil {
            return "Next meeting ready for entity approval"
        }
        if let status = run.nextSourceStatus,
           status.localizedCaseInsensitiveContains("streaming") ||
            status.localizedCaseInsensitiveContains("running") ||
            status.localizedCaseInsensitiveContains("pre-loading") ||
            status.localizedCaseInsensitiveContains("extracting") {
            return "Next meeting running in background"
        }
        return "Next meeting queued"
    }

    private var nextSourceInlineIcon: String {
        if run.nextSourceFailed { return "exclamationmark.triangle.fill" }
        if run.nextSourceReviewDraft != nil { return "checkmark.circle.fill" }
        return "arrow.triangle.2.circlepath"
    }

    private var nextSourceInlineTint: Color {
        if run.nextSourceFailed { return .red }
        if run.nextSourceReviewDraft != nil { return .green }
        return .orange
    }

    private var nextSourceRailText: String {
        if let tokens = run.nextSourceInputTokens {
            return "~\(tokens.formatted()) in"
        }
        return "preparing"
    }

    private var sourceProgressText: String {
        if run.isBatch {
            if run.isRunning {
                let activeIndex = min(max(1, run.currentSourceIndex), run.totalSourceCount)
                return "\(run.completedSourceCount) done · \(activeIndex)/\(run.totalSourceCount) active"
            }
            return "\(run.completedSourceCount) complete"
        }
        return run.result == nil && run.errorMessage == nil ? "processing" : "complete"
    }

    private var modelCallProgressText: String {
        if run.isRunning, run.activeOutputTokenEstimate > 0 {
            return "\(run.modelCallsCompleted) of \(run.modelCallTotal) · +\(run.activeOutputTokenEstimate) out"
        }
        return "\(run.modelCallsCompleted) of \(run.modelCallTotal)"
    }

    private var currentCallProgressText: String {
        guard let selected = run.selectedFunction else { return "waiting" }
        if selected.isFinished { return "complete" }
        if run.activeOutputTokenEstimate == 0 { return "waiting" }
        return "~\(run.activeOutputTokenEstimate) out"
    }

    private func throughputText(for function: WikiGenerationFunctionRun) -> String {
        let now = function.finishedAt ?? Date()
        let inputEnd = function.firstTokenAt ?? function.finishedAt ?? now
        let inputSeconds = max(1.0, inputEnd.timeIntervalSince(function.startedAt))
        let inputTokenCount = max(function.inputTokens, function.modelStatusInputTokens ?? 0)
        let inputRate = Double(inputTokenCount) / inputSeconds

        let outputTokenCount = function.isFinished
            ? function.outputTokens
            : liveOutputTokenEstimate(for: function.output)
        let outputRate: Double
        if let firstTokenAt = function.firstTokenAt {
            let outputSeconds = max(1.0, now.timeIntervalSince(firstTokenAt))
            outputRate = Double(outputTokenCount) / outputSeconds
        } else {
            outputRate = 0
        }

        let inputPrefix = function.firstTokenAt == nil ? "~" : ""
        let outputPrefix = function.isFinished ? "" : "~"
        return "\(inputPrefix)\(formatTokenRate(inputRate)) in/s · \(outputPrefix)\(formatTokenRate(outputRate)) out/s"
    }

    private func liveOutputTokenEstimate(for output: String) -> Int {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? 0 : LocalStructuredLLM.estimatedTokenCount(trimmed)
    }

    private func formatTokenRate(_ rate: Double) -> String {
        if rate < 0.05 { return "0" }
        if rate >= 100 {
            return "\(Int(rate.rounded()))"
        }
        return String(format: "%.1f", rate)
    }

    private func functionStatusText(_ selected: WikiGenerationFunctionRun) -> String {
        if selected.isFinished {
            return "\(selected.inputTokens) in / \(selected.outputTokens) out · \(throughputText(for: selected))"
        }
        if selected.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(selected.modelStatus) · \(throughputText(for: selected))"
        }
        return "Streaming local model output · \(throughputText(for: selected))"
    }

    private func promptTrace(_ function: WikiGenerationFunctionRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                promptBlock(title: "System instruction", text: function.system)
                promptBlock(title: "Context/user prompt", text: function.user)
            }
            .padding(10)
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func confidenceBadge(_ confidence: String) -> some View {
        let cleaned = confidence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !cleaned.isEmpty {
            let color: Color = cleaned == "high" ? .green : cleaned == "medium" ? .orange : .red
            Text("\(cleaned) confidence")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.12))
                .clipShape(Capsule())
        }
    }

    private func promptBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func progressRow(title: String, value: String, isActive: Bool) -> some View {
        let isComplete = !isActive
            && value != "0"
            && value != "waiting"
            && value != "processing"
            && !value.hasPrefix("0 of")
        return HStack {
            Image(systemName: isActive ? "circle.dotted" : (isComplete ? "checkmark.circle" : "circle"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? Color.orange : (isComplete ? Color.secondary : Color.secondary.opacity(0.45)))
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func functionCard(_ function: WikiGenerationFunctionRun) -> some View {
        let selected = run.selectedFunctionID == function.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: function.isFinished ? "checkmark.circle.fill" : "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(function.isFinished ? .green : .orange)
                Text(function.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            Text(function.isFinished ? "\(function.inputTokens) in / \(function.outputTokens) out" : function.output.isEmpty ? function.modelStatus : "streaming...")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.orange.opacity(0.16) : Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func resultCard<Content: View>(
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var savedFilesList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(run.savedRelativePaths, id: \.self) { path in
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: 110)
    }

    private var tokenCounterText: String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        let input = nf.string(from: NSNumber(value: run.estimatedInputTokens)) ?? "\(run.estimatedInputTokens)"
        let output = nf.string(from: NSNumber(value: run.estimatedOutputTokens)) ?? "\(run.estimatedOutputTokens)"
        return "~\(input) in / ~\(output) out · free"
    }
}

private struct GeneratedWikiPageView: View {
    let page: GeneratedWikiPage
    var onSave: (GeneratedWikiPage, String) throws -> Void
    var onRename: (GeneratedWikiPage, String) throws -> GeneratedWikiPage
    var onChangeType: (GeneratedWikiPage, String) throws -> GeneratedWikiPage
    var onOpenWikilink: (String) -> Void
    var onOpenWikilinkInNewTab: (String) -> Void
    var onResolveWikilinkTitle: (String) -> String?
    var onOpenSourceMeeting: (String) -> Void
    @State private var showPreview = true
    @State private var draftBody = ""
    @State private var lastSavedBody = ""
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var editingBlockIndex: Int?
    @State private var editingBlockText = ""
    @State private var linkClickInProgress = false
    @State private var autosaveTask: Task<Void, Never>?
    @State private var isAutosaving = false
    @State private var recentlySavedBlockIndex: Int?
    @State private var savedBadgeTask: Task<Void, Never>?
    @FocusState private var blockEditorFocused: Bool
    @State private var errorMessage: String?

    private var hasUnsavedChanges: Bool {
        draftBody != lastSavedBody
    }

    private var canRename: Bool {
        ["person", "company", "concept", "topic", "claim"].contains(page.type)
    }

    private var canChangeType: Bool {
        ["person", "company", "concept"].contains(page.type)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(errorMessage)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(Color.red.opacity(0.10))
                    .cornerRadius(6)
                }
                if page.userEdited || page.pendingGeneratedUpdate {
                    editHistoryCallout
                }
                if let source = page.sourceMeetingPath, !source.isEmpty {
                    sourceCallout(source)
                }
                if showPreview {
                    bodyRendered
                } else {
                    editor
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if draftBody.isEmpty {
                draftBody = page.body
                lastSavedBody = page.body
            }
            if renameDraft.isEmpty {
                renameDraft = page.title
            }
        }
        .onChange(of: page.url) { _, _ in
            autosaveTask?.cancel()
            savedBadgeTask?.cancel()
            autosaveTask = nil
            savedBadgeTask = nil
            isAutosaving = false
            recentlySavedBlockIndex = nil
            draftBody = page.body
            lastSavedBody = page.body
            renameDraft = page.title
            isRenaming = false
            editingBlockIndex = nil
            editingBlockText = ""
            errorMessage = nil
            showPreview = true
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "generated-wikilink" {
                let slug = url.host ?? url.lastPathComponent
                let cmdHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                if cmdHeld {
                    onOpenWikilinkInNewTab(slug)
                } else {
                    onOpenWikilink(slug)
                }
                return .handled
            }
            return .systemAction
        })
        .onDisappear {
            autosaveTask?.cancel()
            savedBadgeTask?.cancel()
            autosaveTask = nil
            savedBadgeTask = nil
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if isRenaming {
                    HStack(spacing: 8) {
                        TextField("Page name", text: $renameDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 24, weight: .semibold))
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
                            .cornerRadius(6)
                        Button("Save name") {
                            do {
                                let updated = try onRename(page, renameDraft)
                                draftBody = updated.body
                                lastSavedBody = updated.body
                                renameDraft = updated.title
                                isRenaming = false
                                errorMessage = nil
                            } catch {
                                errorMessage = "Could not rename 2nd Brain page: \(error.localizedDescription)"
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renameDraft == page.title)
                        Button("Cancel") {
                            renameDraft = page.title
                            isRenaming = false
                            errorMessage = nil
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text(page.title)
                            .font(.system(size: 24, weight: .semibold))
                        if canRename {
                            Button {
                                renameDraft = page.title
                                isRenaming = true
                            } label: {
                                Label("Rename", systemImage: "pencil.line")
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12, weight: .medium))
                            .help("Rename this 2nd Brain entity and keep the old name as an alias")
                        }
                    }
                }
                HStack(spacing: 12) {
                    if canChangeType {
                        Picker("Entity type", selection: Binding<String>(
                            get: { page.type },
                            set: { newType in
                                do {
                                    let updated = try onChangeType(page, newType)
                                    draftBody = updated.body
                                    lastSavedBody = updated.body
                                    renameDraft = updated.title
                                    errorMessage = nil
                                } catch {
                                    errorMessage = "Could not change entity type: \(error.localizedDescription)"
                                }
                            }
                        )) {
                            Text("Person").tag("person")
                            Text("Company").tag("company")
                            Text("Concept").tag("concept")
                        }
                        .labelsHidden()
                        .frame(width: 118)
                    } else {
                        Label(page.type.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: page.type == "meeting_overview" ? "rectangle.stack.badge.person.crop" : "link")
                    }
                    if let pageID = page.pageID {
                        Text(pageID)
                            .lineLimit(1)
                    }
                    Text(page.url.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Text(isAutosaving || hasUnsavedChanges ? "Saving..." : "Saved")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isAutosaving || hasUnsavedChanges ? .orange : .secondary)
                if hasUnsavedChanges {
                    Button("Revert") {
                        autosaveTask?.cancel()
                        savedBadgeTask?.cancel()
                        autosaveTask = nil
                        savedBadgeTask = nil
                        isAutosaving = false
                        recentlySavedBlockIndex = nil
                        draftBody = lastSavedBody
                        errorMessage = nil
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Page body")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $draftBody)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(14)
                .frame(minHeight: 640)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(hasUnsavedChanges ? Color.orange.opacity(0.35) : Color.secondary.opacity(0.18), lineWidth: 1)
                )
                .cornerRadius(6)
                .onChange(of: draftBody) { _, newValue in
                    scheduleAutosave(for: newValue)
                }
        }
    }

    private var editHistoryCallout: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
            VStack(alignment: .leading, spacing: 2) {
                Text(page.pendingGeneratedUpdate ? "User edits preserved" : "User-edited page")
                    .font(.system(size: 12, weight: .semibold))
                Text(page.pendingGeneratedUpdate
                    ? "Ghost Pepper saved the generated update in local history instead of overwriting this page."
                    : "This 2nd Brain page has been edited since Ghost Pepper last generated it.")
                    .font(.system(size: 11))
            }
            Spacer()
        }
        .padding(10)
        .background(Color.blue.opacity(0.10))
        .cornerRadius(6)
    }

    private func sourceCallout(_ source: String) -> some View {
        Button(action: { onOpenSourceMeeting(source) }) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generated overview")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Source of truth: \(source)")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(10)
            .background(Color.orange.opacity(0.10))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private var bodyRendered: some View {
        let blocks = EditableMarkdownBlock.split(draftBody)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                editableBlock(block, index: index, allBlocks: blocks)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func editableBlock(_ block: EditableMarkdownBlock, index: Int, allBlocks: [EditableMarkdownBlock]) -> some View {
        if editingBlockIndex == index {
            ZStack(alignment: .topLeading) {
                BlockKeyboardTextEditor(
                    text: $editingBlockText,
                    onCommit: { finishEditingBlock(index) },
                    onCancel: { cancelEditingBlock() }
                )
                    .font(.system(size: 14))
                    .padding(10)
                    .frame(minHeight: block.editHeight)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
                    .cornerRadius(6)
                    .onChange(of: editingBlockText) { _, newValue in
                        let currentBlocks = EditableMarkdownBlock.split(draftBody)
                        let nextBody = Self.replacingBlock(at: index, in: currentBlocks, with: newValue)
                        draftBody = nextBody
                        scheduleAutosave(for: nextBody)
                    }
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(Color.orange.opacity(0.85))
                    .allowsHitTesting(false)
                Text("Editing")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(Capsule())
                    .padding(.leading, 10)
                    .offset(y: -10)
            }
            .padding(6)
            .background(Color.orange.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ZStack(alignment: .topTrailing) {
                renderBlock(block.rendered)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if recentlySavedBlockIndex == index {
                    Text("Saved")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !linkClickInProgress else {
                    linkClickInProgress = false
                    return
                }
                startEditingBlock(index, raw: block.raw)
            }
        }
    }

    private func startEditingBlock(_ index: Int, raw: String) {
        editingBlockIndex = index
        editingBlockText = raw
        recentlySavedBlockIndex = nil
        errorMessage = nil
        DispatchQueue.main.async {
            blockEditorFocused = true
        }
    }

    private func finishEditingBlock(_ index: Int) {
        if editingBlockIndex == index {
            let currentBlocks = EditableMarkdownBlock.split(draftBody)
            draftBody = Self.replacingBlock(at: index, in: currentBlocks, with: editingBlockText)
            saveImmediately(for: draftBody)
        }
        editingBlockIndex = nil
        editingBlockText = ""
        errorMessage = nil
        recentlySavedBlockIndex = index
        savedBadgeTask?.cancel()
        savedBadgeTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 1_200_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if recentlySavedBlockIndex == index {
                recentlySavedBlockIndex = nil
            }
        }
    }

    private func cancelEditingBlock() {
        editingBlockIndex = nil
        editingBlockText = ""
        errorMessage = nil
    }

    private func scheduleAutosave(for body: String) {
        autosaveTask?.cancel()
        guard body != lastSavedBody else {
            isAutosaving = false
            return
        }
        isAutosaving = true
        autosaveTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 800_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                try onSave(page, body)
                lastSavedBody = body
                errorMessage = nil
            } catch {
                errorMessage = "Could not autosave 2nd Brain page: \(error.localizedDescription)"
            }
            isAutosaving = false
        }
    }

    private func saveImmediately(for body: String) {
        autosaveTask?.cancel()
        guard body != lastSavedBody else {
            isAutosaving = false
            return
        }
        isAutosaving = true
        do {
            try onSave(page, body)
            lastSavedBody = body
            errorMessage = nil
        } catch {
            errorMessage = "Could not save 2nd Brain page: \(error.localizedDescription)"
        }
        isAutosaving = false
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(for: level))
                .padding(.top, level <= 2 ? 8 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        if let sourceMeeting = Self.sourceMeetingPath(in: item) {
                            Button(action: { onOpenSourceMeeting(sourceMeeting) }) {
                                Text(sourceMeeting)
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundStyle(.blue)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help("Open source meeting")
                        } else {
                            inlineText(item)
                                .font(.system(size: 14))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        case .codeBlock(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(4)
                .textSelection(.enabled)
        }
    }

    private func inlineText(_ text: String) -> some View {
        FlowLayout(spacing: 0) {
            ForEach(Array(Self.inlineTokens(text).enumerated()), id: \.offset) { _, token in
                switch token {
                case .text(let value):
                    markdownText(value)
                case .wikilink(let name, let slug):
                    let displayName = onResolveWikilinkTitle(slug) ?? name
                    Button {
                        linkClickInProgress = true
                        DispatchQueue.main.async {
                            linkClickInProgress = false
                        }
                        let cmdHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                        if cmdHeld {
                            onOpenWikilinkInNewTab(slug)
                        } else {
                            onOpenWikilink(slug)
                        }
                    } label: {
                        Text(displayName)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open") { onOpenWikilink(slug) }
                        Button("Open in New Tab") { onOpenWikilinkInNewTab(slug) }
                    }
                    .help("Open \(displayName). Command-click opens in a new tab.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func markdownText(_ value: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: value,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(value)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .system(size: 20, weight: .bold)
        case 2: return .system(size: 16, weight: .semibold)
        default: return .system(size: 14, weight: .semibold)
        }
    }

    private static func transformWikilinks(_ text: String) -> String {
        let pattern = #"\[\[([^\]]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let nameRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let name = String(result[nameRange])
            let slug = MarkdownArchivePaths.slugForIndexEntry(name)
            result.replaceSubrange(fullRange, with: "[\(name)](generated-wikilink://\(slug))")
        }
        return result
    }

    private enum InlineToken: Equatable {
        case text(String)
        case wikilink(name: String, slug: String)
    }

    private static func inlineTokens(_ text: String) -> [InlineToken] {
        var out: [InlineToken] = []
        let pattern = #"\[\[([^\]]+)\]\]|\[([^\]]+)\]\(generated-wikilink://([^\)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return textWordTokens(text)
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: nsRange) {
            guard let fullRange = Range(match.range, in: text) else { continue }
            if cursor < fullRange.lowerBound {
                out.append(contentsOf: textWordTokens(String(text[cursor..<fullRange.lowerBound])))
            }
            if let wikiNameRange = Range(match.range(at: 1), in: text) {
                let name = String(text[wikiNameRange])
                out.append(.wikilink(name: name, slug: MarkdownArchivePaths.slugForIndexEntry(name)))
            } else if let markdownNameRange = Range(match.range(at: 2), in: text),
                      let markdownSlugRange = Range(match.range(at: 3), in: text) {
                out.append(.wikilink(name: String(text[markdownNameRange]), slug: String(text[markdownSlugRange])))
            }
            cursor = fullRange.upperBound
        }
        if cursor < text.endIndex {
            out.append(contentsOf: textWordTokens(String(text[cursor...])))
        }
        return out.isEmpty ? textWordTokens(text) : out
    }

    private static func textWordTokens(_ text: String) -> [InlineToken] {
        guard !text.isEmpty else { return [] }
        var tokens: [InlineToken] = []
        let pattern = #"\S+\s*|\s+"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: nsRange) {
                guard let range = Range(match.range, in: text) else { continue }
                tokens.append(.text(String(text[range])))
            }
        }
        return tokens.isEmpty ? [.text(text)] : tokens
    }

    private static func sourceMeetingPath(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"^`([^`]+\.md)`$"#,
            #"^([^`]+\.md)$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, range: range),
                  let capture = Range(match.range(at: 1), in: trimmed) else { continue }
            return String(trimmed[capture])
        }
        return nil
    }

    private static func replacingBlock(at index: Int, in blocks: [EditableMarkdownBlock], with text: String) -> String {
        var raws = blocks.map(\.raw)
        guard raws.indices.contains(index) else { return raws.joined(separator: "\n\n") }
        let replacement = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if replacement.isEmpty {
            raws.remove(at: index)
        } else {
            raws[index] = replacement
        }
        return raws
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private struct EditableMarkdownBlock: Identifiable, Equatable {
        let id: Int
        var raw: String

        var rendered: MarkdownBlock {
            MarkdownBlockParser.parse(raw).first ?? .paragraph(raw)
        }

        var editHeight: CGFloat {
            let lineCount = max(2, raw.components(separatedBy: "\n").count)
            return CGFloat(min(240, max(72, lineCount * 24 + 28)))
        }

        static func split(_ body: String) -> [EditableMarkdownBlock] {
            var blocks: [String] = []
            var current: [String] = []
            var inFence = false
            var inList = false

            func flush() {
                let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    blocks.append(text)
                }
                current = []
                inList = false
            }

            for raw in body.components(separatedBy: "\n") {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") {
                    current.append(raw)
                    if inFence {
                        inFence = false
                        flush()
                    } else {
                        inFence = true
                    }
                    continue
                }
                if inFence {
                    current.append(raw)
                    continue
                }
                if trimmed.isEmpty {
                    flush()
                    continue
                }
                if headingLevel(trimmed) != nil {
                    flush()
                    current.append(raw)
                    flush()
                    continue
                }
                if bulletItem(trimmed) != nil {
                    flush()
                    current.append(raw)
                    inList = true
                    continue
                }
                if inList {
                    flush()
                }
                current.append(raw)
            }
            flush()
            return blocks.enumerated().map { EditableMarkdownBlock(id: $0.offset, raw: $0.element) }
        }

        private static func headingLevel(_ line: String) -> Int? {
            var hashes = 0
            for ch in line {
                if ch == "#" { hashes += 1 } else { break }
            }
            guard hashes >= 1 && hashes <= 6 else { return nil }
            let after = line.index(line.startIndex, offsetBy: hashes)
            guard after < line.endIndex, line[after] == " " else { return nil }
            return hashes
        }

        private static func bulletItem(_ line: String) -> String? {
            if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
            if line.hasPrefix("* ") { return String(line.dropFirst(2)) }
            if line.hasPrefix("• ") { return String(line.dropFirst(2)) }
            return nil
        }
    }
}

private struct BlockKeyboardTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> KeyHandlingTextView {
        let textView = KeyHandlingTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.keyHandler = context.coordinator
        return textView
    }

    func updateNSView(_ textView: KeyHandlingTextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        if textView.string != text {
            textView.string = text
        }
        textView.keyHandler = context.coordinator
        if context.coordinator.needsInitialFocus, let window = textView.window {
            context.coordinator.needsInitialFocus = false
            DispatchQueue.main.async {
                window.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, KeyHandlingTextViewDelegate {
        var text: Binding<String>
        var onCommit: () -> Void
        var onCancel: () -> Void
        var needsInitialFocus = true
        var isClosing = false

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textDidEndEditing(_ notification: Notification) {
            guard !isClosing, let textView = notification.object as? NSTextView else { return }
            commitEditing(from: textView)
        }

        func commitEditing(from textView: NSTextView) {
            guard !isClosing else { return }
            isClosing = true
            text.wrappedValue = textView.string
            onCommit()
        }

        func cancelEditing(from textView: NSTextView) {
            guard !isClosing else { return }
            isClosing = true
            text.wrappedValue = textView.string
            onCancel()
        }
    }

    final class KeyHandlingTextView: NSTextView {
        weak var keyHandler: KeyHandlingTextViewDelegate?

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                keyHandler?.cancelEditing(from: self)
                return
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) {
                    insertNewlineIgnoringFieldEditor(self)
                } else {
                    keyHandler?.commitEditing(from: self)
                }
                return
            }
            super.keyDown(with: event)
        }
    }
}

private protocol KeyHandlingTextViewDelegate: AnyObject {
    func commitEditing(from textView: NSTextView)
    func cancelEditing(from textView: NSTextView)
}

private struct SecondBrainDashboardView: View {
    @ObservedObject var state: MeetingWindowState
    var onBuildNextBatch: () -> Void
    var onLint: () -> Void
    var onOpenPage: (URL) -> Void
    var onOpenPageInNewTab: (URL) -> Void
    var onArchive: () -> Void

    @State private var graph = SecondBrainGraph(nodes: [], edges: [])
    @State private var showArchiveConfirmation = false
    @State private var archiveAlertMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("2nd Brain", systemImage: "brain.head.profile")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(graph.nodes.count) pages · \(graph.edges.count) links")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onBuildNextBatch) {
                    Label(state.isGeneratingMeetingWiki ? "Adding..." : "Add next 50", systemImage: "sparkles.rectangle.stack")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
                .disabled(state.isGeneratingMeetingWiki)

                Button(action: rebuildGraph) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: onLint) {
                    Label("Lint", systemImage: "checklist")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive, action: { showArchiveConfirmation = true }) {
                    Label("Archive", systemImage: "archivebox")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.isGeneratingMeetingWiki || graph.nodes.isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Graph")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(graph.nodes.count) nodes")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        SecondBrainGraphView(
                            graph: graph,
                            onOpenPage: onOpenPage,
                            onOpenPageInNewTab: onOpenPageInNewTab
                        )
                        .frame(minHeight: 520)
                    }

                    hubsSection
                }
                .padding(18)
            }
        }
        .onAppear(perform: rebuildGraph)
        .onChange(of: state.generatedWikiFolders) { _, _ in rebuildGraph() }
        .confirmationDialog(
            "Archive 2nd Brain?",
            isPresented: $showArchiveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Choose Archive Location...", role: .destructive) {
                chooseArchiveLocationAndArchive()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves only derived 2nd Brain files, local history, and 2nd Brain cache files into an archive folder. Meeting sources, recordings, Granola imports, and Airtable imports are not moved.")
        }
        .alert(
            "2nd Brain Archive",
            isPresented: Binding(
                get: { archiveAlertMessage != nil },
                set: { if !$0 { archiveAlertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(archiveAlertMessage ?? "")
        }
    }

    @ViewBuilder
    private var hubsSection: some View {
        let hubs = graph.nodes.sorted { lhs, rhs in
            if lhs.degree == rhs.degree { return lhs.title < rhs.title }
            return lhs.degree > rhs.degree
        }.prefix(12)
        VStack(alignment: .leading, spacing: 8) {
            Text("Hubs")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if hubs.isEmpty {
                Text("No 2nd Brain pages yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], spacing: 8) {
                    ForEach(Array(hubs)) { node in
                        Button(action: { onOpenPageInNewTab(node.url) }) {
                            HStack(spacing: 8) {
                                Image(systemName: node.icon)
                                    .font(.system(size: 12))
                                    .foregroundStyle(node.isHub ? .orange : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(node.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text("\(node.degree) links · \(node.folderTitle)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(8)
                            .background(Color.secondary.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func rebuildGraph() {
        state.loadGeneratedWikiFolders()
        graph = SecondBrainGraph.build(from: state.generatedWikiFolders)
    }

    private func chooseArchiveLocationAndArchive() {
        let panel = NSOpenPanel()
        panel.title = "Choose where to archive this 2nd Brain"
        panel.message = "Ghost Pepper will create a dated archive folder here. Source meetings and imports will stay where they are."
        panel.prompt = "Archive Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let archiveURL = try state.archiveSecondBrain(to: destination)
            onArchive()
            rebuildGraph()
            archiveAlertMessage = "Archived 2nd Brain to:\n\(archiveURL.path)\n\nSource meetings and imports were not moved."
        } catch {
            archiveAlertMessage = error.localizedDescription
        }
    }
}

private struct SecondBrainGraphView: View {
    let graph: SecondBrainGraph
    var onOpenPage: (URL) -> Void
    var onOpenPageInNewTab: (URL) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.62))

            if graph.nodes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No 2nd Brain graph yet")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Add meetings to the 2nd Brain to create pages and links.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                SecondBrainGraphWebView(
                    graph: graph,
                    onOpenPage: onOpenPage,
                    onOpenPageInNewTab: onOpenPageInNewTab
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                )
            }
        }
    }
}

private struct SecondBrainGraphWebView: NSViewRepresentable {
    let graph: SecondBrainGraph
    var onOpenPage: (URL) -> Void
    var onOpenPageInNewTab: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenPage: onOpenPage, onOpenPageInNewTab: onOpenPageInNewTab)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "ghostPepperGraph")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(Self.html, baseURL: Bundle.main.resourceURL)
        context.coordinator.update(graph: graph, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpenPage = onOpenPage
        context.coordinator.onOpenPageInNewTab = onOpenPageInNewTab
        context.coordinator.update(graph: graph, in: webView)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "ghostPepperGraph")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onOpenPage: (URL) -> Void
        var onOpenPageInNewTab: (URL) -> Void
        private var graph = SecondBrainGraph(nodes: [], edges: [])
        private var pendingPayload: String?
        private var didFinishLoading = false

        init(onOpenPage: @escaping (URL) -> Void, onOpenPageInNewTab: @escaping (URL) -> Void) {
            self.onOpenPage = onOpenPage
            self.onOpenPageInNewTab = onOpenPageInNewTab
        }

        func update(graph: SecondBrainGraph, in webView: WKWebView) {
            self.graph = graph
            guard let payload = Self.payloadJSONString(for: graph) else { return }
            pendingPayload = payload
            guard didFinishLoading else { return }
            renderPendingPayload(in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didFinishLoading = true
            renderPendingPayload(in: webView)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "ghostPepperGraph",
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String,
                  let id = body["id"] as? String,
                  let node = graph.nodes.first(where: { $0.id == id }) else {
                return
            }

            switch action {
            case "open":
                onOpenPage(node.url)
            case "openInNewTab":
                onOpenPageInNewTab(node.url)
            default:
                break
            }
        }

        private func renderPendingPayload(in webView: WKWebView) {
            guard let payload = pendingPayload else { return }
            let script = "window.renderSecondBrainGraph(\(payload));"
            webView.evaluateJavaScript(script)
        }

        private static func payloadJSONString(for graph: SecondBrainGraph) -> String? {
            let payload = SecondBrainGraphPayload(graph: graph)
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(payload) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private struct SecondBrainGraphPayload: Encodable {
        struct Node: Encodable {
            let id: String
            let label: String
            let type: String
            let folderTitle: String
            let degree: Int
            let isHub: Bool
            let size: CGFloat
        }

        struct Edge: Encodable {
            let id: String
            let source: String
            let target: String
            let weight: Int
        }

        let nodes: [Node]
        let edges: [Edge]

        init(graph: SecondBrainGraph) {
            nodes = graph.nodes.map { node in
                Node(
                    id: node.id,
                    label: node.title,
                    type: node.type,
                    folderTitle: node.folderTitle,
                    degree: node.degree,
                    isHub: node.isHub,
                    size: node.radius * 2
                )
            }
            edges = graph.edges.map { edge in
                Edge(
                    id: edge.id,
                    source: edge.sourceID,
                    target: edge.targetID,
                    weight: edge.weight
                )
            }
        }
    }

    private static let html = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <script src="cytoscape.min.js"></script>
      <style>
        :root {
          color-scheme: light dark;
          --bg: rgba(248, 248, 248, 0.84);
          --panel: rgba(255, 255, 255, 0.88);
          --panel-soft: rgba(118, 118, 128, 0.08);
          --border: rgba(60, 60, 67, 0.16);
          --text: #1d1d1f;
          --muted: rgba(60, 60, 67, 0.68);
          --edge: rgba(60, 60, 67, 0.22);
          --label-outline: rgba(248, 248, 248, 0.92);
          --orange: #e8751a;
          --blue: #4d8fb3;
          --green: #5d9b78;
          --violet: #9b79b8;
          --yellow: #c49a35;
          --neutral: #8e8e93;
        }

        @media (prefers-color-scheme: dark) {
          :root {
            --bg: rgba(28, 28, 30, 0.74);
            --panel: rgba(44, 44, 46, 0.84);
            --panel-soft: rgba(255, 255, 255, 0.07);
            --border: rgba(235, 235, 245, 0.14);
            --text: #f2f2f7;
            --muted: rgba(235, 235, 245, 0.62);
            --edge: rgba(235, 235, 245, 0.20);
            --label-outline: rgba(28, 28, 30, 0.94);
            --neutral: #8e8e93;
          }
        }

        html, body, #app, #cy {
          width: 100%;
          height: 100%;
          margin: 0;
          overflow: hidden;
          background: var(--bg);
          font: 12px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          color: var(--text);
        }

        #cy {
          position: absolute;
          inset: 0;
        }

        .toolbar {
          position: absolute;
          left: 12px;
          top: 12px;
          z-index: 2;
          display: flex;
          align-items: center;
          gap: 6px;
          padding: 6px;
          background: var(--panel);
          border: 1px solid var(--border);
          border-radius: 8px;
          backdrop-filter: blur(12px);
        }

        input {
          width: 190px;
          height: 24px;
          box-sizing: border-box;
          border: 1px solid var(--border);
          border-radius: 6px;
          background: var(--panel-soft);
          color: var(--text);
          outline: none;
          padding: 0 9px;
        }

        button {
          height: 24px;
          border: 1px solid var(--border);
          border-radius: 6px;
          color: var(--text);
          background: var(--panel-soft);
          padding: 0 9px;
          font: inherit;
        }

        button:hover {
          border-color: rgba(232, 117, 26, 0.38);
        }

        .stats {
          color: var(--muted);
          font-variant-numeric: tabular-nums;
          padding: 0 5px;
          white-space: nowrap;
        }

        .inspector {
          position: absolute;
          right: 12px;
          top: 12px;
          z-index: 2;
          width: min(300px, calc(100% - 24px));
          box-sizing: border-box;
          padding: 10px;
          background: var(--panel);
          border: 1px solid var(--border);
          border-radius: 8px;
          backdrop-filter: blur(12px);
        }

        .inspector.hidden {
          display: none;
        }

        .title {
          font-size: 13px;
          font-weight: 650;
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }

        .meta {
          color: var(--muted);
          margin-top: 4px;
          line-height: 1.35;
        }

        .actions {
          display: flex;
          gap: 8px;
          margin-top: 10px;
        }

        .actions button:first-child {
          background: rgba(232, 117, 26, 0.16);
          border-color: rgba(232, 117, 26, 0.32);
        }

        .legend {
          position: absolute;
          left: 12px;
          bottom: 12px;
          z-index: 2;
          display: flex;
          flex-wrap: wrap;
          gap: 9px;
          max-width: calc(100% - 24px);
          padding: 7px 9px;
          background: var(--panel);
          border: 1px solid var(--border);
          border-radius: 8px;
          color: var(--muted);
          backdrop-filter: blur(12px);
        }

        .dot {
          display: inline-block;
          width: 8px;
          height: 8px;
          border-radius: 50%;
          margin-right: 5px;
        }

        .empty {
          position: absolute;
          inset: 0;
          display: grid;
          place-items: center;
          color: var(--muted);
        }
      </style>
    </head>
    <body>
      <div id="app">
        <div id="cy"></div>
        <div class="toolbar">
          <input id="search" placeholder="Search pages..." autocomplete="off">
          <button id="fit">Fit</button>
          <button id="clear">Clear</button>
          <span class="stats" id="stats"></span>
        </div>
        <div class="inspector hidden" id="inspector">
          <div class="title" id="selectedTitle"></div>
          <div class="meta" id="selectedMeta"></div>
          <div class="actions">
            <button id="openTab">Open in Tab</button>
            <button id="openHere">Open</button>
          </div>
        </div>
        <div class="legend">
          <span><span class="dot" style="background: var(--orange)"></span>Hub</span>
          <span><span class="dot" style="background: var(--blue)"></span>Person</span>
          <span><span class="dot" style="background: var(--green)"></span>Company</span>
          <span><span class="dot" style="background: var(--violet)"></span>Concept</span>
          <span><span class="dot" style="background: var(--yellow)"></span>Meeting</span>
        </div>
      </div>

      <script>
        let cy = null;
        let selectedNodeID = null;

        function currentPalette() {
          const dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
          return dark ? {
            hub: '#e8751a',
            meeting_overview: '#b99342',
            person: '#5f9fbd',
            company: '#6ea983',
            concept: '#a184bd',
            default: '#8e8e93',
            edge: 'rgba(235, 235, 245, 0.20)',
            border: 'rgba(235, 235, 245, 0.28)',
            hubBorder: '#efb27d',
            label: '#f2f2f7',
            labelOutline: '#1c1c1e',
            focusedBorder: '#f8d2b2',
            matchedBorder: '#d8b45a'
          } : {
            hub: '#e8751a',
            meeting_overview: '#b98d28',
            person: '#4d8fb3',
            company: '#5d9b78',
            concept: '#9b79b8',
            default: '#8e8e93',
            edge: 'rgba(60, 60, 67, 0.22)',
            border: 'rgba(60, 60, 67, 0.24)',
            hubBorder: '#b95d14',
            label: '#1d1d1f',
            labelOutline: '#f8f8f8',
            focusedBorder: '#ad4f0d',
            matchedBorder: '#9a741c'
          };
        }

        function colorFor(node) {
          const colors = currentPalette();
          if (node.isHub) return colors.hub;
          return colors[node.type] || colors.default;
        }

        function cssEscape(value) {
          if (window.CSS && CSS.escape) return CSS.escape(value);
          return String(value).replace(/["\\\\]/g, '\\\\$&');
        }

        function post(action, id) {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ghostPepperGraph) {
            window.webkit.messageHandlers.ghostPepperGraph.postMessage({ action, id });
          }
        }

        function setInspector(node) {
          const inspector = document.getElementById('inspector');
          if (!node) {
            inspector.classList.add('hidden');
            selectedNodeID = null;
            return;
          }
          selectedNodeID = node.id();
          const data = node.data();
          document.getElementById('selectedTitle').textContent = data.label;
          document.getElementById('selectedMeta').textContent =
            `${data.degree} links · ${data.folderTitle} · ${String(data.type).replaceAll('_', ' ')}`;
          inspector.classList.remove('hidden');
        }

        function focusNode(node) {
          cy.elements().removeClass('dimmed focused neighbor matched');
          if (!node) {
            setInspector(null);
            return;
          }
          const neighborhood = node.closedNeighborhood();
          cy.elements().not(neighborhood).addClass('dimmed');
          neighborhood.addClass('neighbor');
          node.addClass('focused');
          setInspector(node);
        }

        function runSearch(query) {
          if (!cy) return;
          cy.elements().removeClass('matched');
          const cleaned = query.trim().toLowerCase();
          if (!cleaned) return;
          cy.nodes().filter(node => String(node.data('label')).toLowerCase().includes(cleaned)).addClass('matched');
        }

        window.renderSecondBrainGraph = function(payload) {
          const palette = currentPalette();
          const elements = [
            ...payload.nodes.map(node => ({
              group: 'nodes',
              data: {
                id: node.id,
                label: node.label,
                type: node.type,
                folderTitle: node.folderTitle,
                degree: node.degree,
                isHub: node.isHub,
                size: Math.max(18, Math.min(58, node.size)),
                color: colorFor(node),
                borderColor: node.isHub ? palette.hubBorder : palette.border,
                labelColor: palette.label,
                labelOutline: palette.labelOutline,
                labelSize: node.isHub ? 12 : 9,
                labelOpacity: node.isHub || node.degree >= 3 ? 1 : 0
              },
              classes: `${node.isHub ? 'hub ' : ''}${node.type}`
            })),
            ...payload.edges.map(edge => ({
              group: 'edges',
              data: {
                id: edge.id,
                source: edge.source,
                target: edge.target,
                weight: edge.weight,
                width: Math.max(0.8, Math.min(3.2, 0.7 + edge.weight * 0.45)),
                color: palette.edge
              }
            }))
          ];

          if (cy) cy.destroy();
          selectedNodeID = null;
          document.getElementById('inspector').classList.add('hidden');
          document.getElementById('stats').textContent = `${payload.nodes.length} nodes · ${payload.edges.length} links`;

          cy = cytoscape({
            container: document.getElementById('cy'),
            elements,
            wheelSensitivity: 0.22,
            minZoom: 0.12,
            maxZoom: 3.5,
            style: [
              {
                selector: 'node',
                style: {
                  'width': 'data(size)',
                  'height': 'data(size)',
                  'background-color': 'data(color)',
                  'border-width': 1,
                  'border-color': 'data(borderColor)',
                  'label': 'data(label)',
                  'font-family': '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif',
                  'font-size': 'data(labelSize)',
                  'font-weight': 520,
                  'color': 'data(labelColor)',
                  'text-outline-width': 3,
                  'text-outline-color': 'data(labelOutline)',
                  'text-valign': 'bottom',
                  'text-margin-y': 8,
                  'text-opacity': 'data(labelOpacity)',
                  'overlay-padding': 6,
                  'transition-property': 'opacity, border-width, border-color, width, height, text-opacity',
                  'transition-duration': '120ms'
                }
              },
              {
                selector: 'node.hub',
                style: {
                  'border-width': 3,
                  'border-color': palette.hubBorder,
                  'text-opacity': 1,
                  'font-weight': 700
                }
              },
              {
                selector: 'edge',
                style: {
                  'width': 'data(width)',
                  'line-color': 'data(color)',
                  'curve-style': 'bezier',
                  'opacity': 0.70,
                  'transition-property': 'opacity, line-color, width',
                  'transition-duration': '120ms'
                }
              },
              {
                selector: '.focused',
                style: {
                  'border-width': 4,
                  'border-color': palette.focusedBorder,
                  'text-opacity': 1,
                  'z-index': 20
                }
              },
              {
                selector: '.neighbor',
                style: {
                  'text-opacity': 1
                }
              },
              {
                selector: '.dimmed',
                style: {
                  'opacity': 0.20,
                  'text-opacity': 0
                }
              },
              {
                selector: '.matched',
                style: {
                  'border-width': 4,
                  'border-color': palette.matchedBorder,
                  'text-opacity': 1,
                  'z-index': 30
                }
              }
            ],
            layout: {
              name: 'cose',
              animate: true,
              animationDuration: 620,
              randomize: true,
              componentSpacing: 98,
              nodeOverlap: 18,
              nodeRepulsion: 720000,
              idealEdgeLength: 118,
              edgeElasticity: 120,
              nestingFactor: 1.1,
              gravity: 0.16,
              numIter: 1400,
              initialTemp: 220,
              coolingFactor: 0.96,
              minTemp: 1.0,
              fit: true,
              padding: 52
            }
          });

          cy.on('tap', 'node', event => focusNode(event.target));
          cy.on('tap', event => {
            if (event.target === cy) focusNode(null);
          });
          cy.on('mouseover', 'node', event => event.target.addClass('neighbor'));
          cy.on('mouseout', 'node', event => {
            if (!selectedNodeID || event.target.id() !== selectedNodeID) event.target.removeClass('neighbor');
          });

          const query = document.getElementById('search').value || '';
          runSearch(query);
        };

        document.getElementById('fit').addEventListener('click', () => {
          if (cy) cy.fit(undefined, 52);
        });
        document.getElementById('clear').addEventListener('click', () => {
          document.getElementById('search').value = '';
          if (cy) {
            cy.elements().removeClass('dimmed focused neighbor matched');
            setInspector(null);
            cy.fit(undefined, 52);
          }
        });
        document.getElementById('search').addEventListener('input', event => runSearch(event.target.value));
        document.getElementById('openTab').addEventListener('click', () => {
          if (selectedNodeID) post('openInNewTab', selectedNodeID);
        });
        document.getElementById('openHere').addEventListener('click', () => {
          if (selectedNodeID) post('open', selectedNodeID);
        });
      </script>
    </body>
    </html>
    """
}

private struct SecondBrainGraphNodeView: View {
    let node: SecondBrainGraph.Node
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(node.isHub ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.12))
                Circle()
                    .stroke(node.isHub ? Color.orange.opacity(0.9) : Color.secondary.opacity(0.35), lineWidth: node.isHub ? 2 : 1)
                Image(systemName: node.icon)
                    .font(.system(size: max(10, node.radius * 0.42), weight: .semibold))
                    .foregroundStyle(node.isHub ? .orange : .secondary)
            }
            .frame(width: node.radius * 2, height: node.radius * 2)

            Text(node.title)
                .font(.system(size: 10, weight: node.isHub ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 110)
            Text("\(node.degree)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if isHovering {
                nodeHoverLabel
                    .offset(y: -74)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(10)
            }
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("\(node.title) · \(node.folderTitle) · \(node.degree) links")
    }

    private var nodeHoverLabel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(node.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Text("\(node.type.replacingOccurrences(of: "_", with: " ").capitalized) · \(node.folderTitle)")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(node.degree) links")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: 190, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)
    }
}

private struct SecondBrainGraph: Equatable {
    struct Node: Identifiable, Equatable {
        let id: String
        let title: String
        let type: String
        let folderTitle: String
        let url: URL
        let degree: Int
        let index: Int
        let isHub: Bool

        var icon: String {
            switch type {
            case "meeting_overview": return "rectangle.stack.badge.person.crop"
            case "person": return "person.crop.circle"
            case "company": return "building.2"
            case "concept": return "lightbulb"
            default: return "doc.text"
            }
        }

        var radius: CGFloat {
            CGFloat(min(34, max(15, 15 + degree * 2)))
        }
    }

    struct Edge: Identifiable, Equatable {
        let sourceID: String
        let targetID: String
        let weight: Int
        var id: String { "\(sourceID)->\(targetID)" }
    }

    let nodes: [Node]
    let edges: [Edge]

    static func build(from folders: [GeneratedWikiSidebarFolder]) -> SecondBrainGraph {
        var pages: [(item: GeneratedWikiSidebarItem, folderTitle: String, page: GeneratedWikiPage)] = []
        for folder in folders {
            for item in folder.items {
                guard let page = try? GeneratedWikiPaths.readPage(from: item.fileURL) else { continue }
                pages.append((item, folder.title, page))
            }
        }

        var bySlug: [String: GeneratedWikiSidebarItem] = [:]
        for entry in pages {
            bySlug[entry.item.fileURL.deletingPathExtension().lastPathComponent] = entry.item
            bySlug[MarkdownArchivePaths.slugForIndexEntry(entry.item.title)] = entry.item
            bySlug[MarkdownArchivePaths.slugForIndexEntry(entry.page.title)] = entry.item
        }

        var edgeWeights: [String: Int] = [:]
        var degrees: [String: Int] = [:]
        for entry in pages {
            let sourceID = entry.item.fileURL.path
            for link in wikilinks(in: entry.page.body) {
                let slug = MarkdownArchivePaths.slugForIndexEntry(link)
                guard let target = bySlug[slug], target.fileURL.path != sourceID else { continue }
                let key = "\(sourceID)\u{1F}\(target.fileURL.path)"
                edgeWeights[key, default: 0] += 1
            }
        }

        let edges = edgeWeights.map { key, weight -> Edge in
            let parts = key.components(separatedBy: "\u{1F}")
            let source = parts.first ?? key
            let target = parts.dropFirst().first ?? key
            degrees[source, default: 0] += weight
            degrees[target, default: 0] += weight
            return Edge(sourceID: source, targetID: target, weight: weight)
        }

        let maxDegree = degrees.values.max() ?? 0
        let hubThreshold = max(3, Int(ceil(Double(maxDegree) * 0.6)))
        let nodes = pages.enumerated().map { index, entry in
            let degree = degrees[entry.item.fileURL.path, default: 0]
            return Node(
                id: entry.item.fileURL.path,
                title: entry.item.title,
                type: entry.item.type,
                folderTitle: entry.folderTitle,
                url: entry.item.fileURL,
                degree: degree,
                index: index,
                isHub: degree >= hubThreshold && degree > 0
            )
        }.sorted { lhs, rhs in
            if lhs.isHub != rhs.isHub { return lhs.isHub && !rhs.isHub }
            if lhs.degree != rhs.degree { return lhs.degree > rhs.degree }
            return lhs.title < rhs.title
        }

        return SecondBrainGraph(nodes: nodes, edges: edges.sorted { $0.id < $1.id })
    }

    func positions(in size: CGSize) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let width = max(size.width, 320)
        let height = max(size.height, 320)
        let center = CGPoint(x: width / 2, y: height / 2)
        let horizontalRadius = max(120, width * 0.42)
        let verticalRadius = max(120, height * 0.40)
        let maxDegree = max(nodes.map(\.degree).max() ?? 1, 1)
        let nodeByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let edgeNeighborhoods = neighborhoodMap()
        var out = initialPositions(
            center: center,
            horizontalRadius: horizontalRadius,
            verticalRadius: verticalRadius,
            maxDegree: maxDegree
        )

        let iterations: Int
        if nodes.count > 220 {
            iterations = 110
        } else if nodes.count > 80 {
            iterations = 180
        } else {
            iterations = 160
        }
        let repulsion = min(width, height) * 4.8
        let centerPull: CGFloat = 0.018
        let hubCenterPull: CGFloat = 0.045
        let preferredLinkLength = max(64, min(width, height) * 0.16)
        let repulsionPairs = repulsionPairs()

        for step in 0..<iterations {
            var delta = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, CGVector.zero) })
            let cooling = 1 - CGFloat(step) / CGFloat(iterations)
            let stepLimit = max(1.2, 10 * cooling)

            for pair in repulsionPairs {
                let lhs = nodes[pair.0]
                let rhs = nodes[pair.1]
                guard let lhsPoint = out[lhs.id], let rhsPoint = out[rhs.id] else { continue }
                var dx = lhsPoint.x - rhsPoint.x
                var dy = lhsPoint.y - rhsPoint.y
                var distanceSquared = dx * dx + dy * dy
                if distanceSquared < 0.01 {
                    let angle = stableAngle(for: "\(lhs.id)|\(rhs.id)")
                    dx = cos(angle)
                    dy = sin(angle)
                    distanceSquared = 1
                }
                let distance = sqrt(distanceSquared)
                let isLinked = edgeNeighborhoods[lhs.id, default: []].contains(rhs.id)
                let minimumDistance = lhs.radius + rhs.radius + (isLinked ? 16 : 28)
                let force = max(0.5, repulsion / distanceSquared) + max(0, minimumDistance - distance) * 0.24
                let pushX = dx / distance * force
                let pushY = dy / distance * force
                delta[lhs.id, default: .zero].dx += pushX
                delta[lhs.id, default: .zero].dy += pushY
                delta[rhs.id, default: .zero].dx -= pushX
                delta[rhs.id, default: .zero].dy -= pushY
            }

            for edge in edges {
                guard let source = nodeByID[edge.sourceID],
                      let target = nodeByID[edge.targetID],
                      let sourcePoint = out[edge.sourceID],
                      let targetPoint = out[edge.targetID] else { continue }
                let dx = targetPoint.x - sourcePoint.x
                let dy = targetPoint.y - sourcePoint.y
                let distance = max(1, sqrt(dx * dx + dy * dy))
                let degreeBias = CGFloat(source.degree + target.degree) / CGFloat(maxDegree * 2)
                let desired = preferredLinkLength + (1 - degreeBias) * 38 - CGFloat(min(edge.weight, 5)) * 6
                let force = (distance - desired) * (0.020 + CGFloat(min(edge.weight, 6)) * 0.006)
                let pullX = dx / distance * force
                let pullY = dy / distance * force
                delta[edge.sourceID, default: .zero].dx += pullX
                delta[edge.sourceID, default: .zero].dy += pullY
                delta[edge.targetID, default: .zero].dx -= pullX
                delta[edge.targetID, default: .zero].dy -= pullY
            }

            for node in nodes {
                guard let point = out[node.id] else { continue }
                let degreeFraction = CGFloat(node.degree) / CGFloat(maxDegree)
                let pull = node.isHub ? hubCenterPull : centerPull * max(0.25, degreeFraction)
                delta[node.id, default: .zero].dx += (center.x - point.x) * pull
                delta[node.id, default: .zero].dy += (center.y - point.y) * pull

                if node.degree == 0 {
                    let angle = stableAngle(for: node.id)
                    let target = CGPoint(
                        x: center.x + cos(angle) * horizontalRadius * 0.95,
                        y: center.y + sin(angle) * verticalRadius * 0.95
                    )
                    delta[node.id, default: .zero].dx += (target.x - point.x) * 0.035
                    delta[node.id, default: .zero].dy += (target.y - point.y) * 0.035
                }
            }

            for node in nodes {
                guard let point = out[node.id], let movement = delta[node.id] else { continue }
                let movementLength = max(1, sqrt(movement.dx * movement.dx + movement.dy * movement.dy))
                let scale = min(stepLimit, movementLength) / movementLength
                out[node.id] = bounded(
                    CGPoint(x: point.x + movement.dx * scale, y: point.y + movement.dy * scale),
                    in: size,
                    margin: node.radius + 58
                )
            }
        }

        return out
    }

    private func initialPositions(center: CGPoint, horizontalRadius: CGFloat, verticalRadius: CGFloat, maxDegree: Int) -> [String: CGPoint] {
        let count = max(nodes.count, 1)
        var positions: [String: CGPoint] = [:]
        for (idx, node) in nodes.enumerated() {
            let angle = stableAngle(for: node.id) + CGFloat(idx) / CGFloat(count) * 0.33
            let degreeFraction = CGFloat(node.degree) / CGFloat(maxDegree)
            let radiusScale = node.degree == 0 ? 0.98 : max(0.22, 0.92 - degreeFraction * 0.56)
            let jitter = 0.86 + stableUnitValue(for: "\(node.id)-jitter") * 0.22
            positions[node.id] = CGPoint(
                x: center.x + cos(angle) * horizontalRadius * radiusScale * jitter,
                y: center.y + sin(angle) * verticalRadius * radiusScale * jitter
            )
        }
        return positions
    }

    private func neighborhoodMap() -> [String: Set<String>] {
        var neighborhoods: [String: Set<String>] = [:]
        for edge in edges {
            neighborhoods[edge.sourceID, default: []].insert(edge.targetID)
            neighborhoods[edge.targetID, default: []].insert(edge.sourceID)
        }
        return neighborhoods
    }

    private func repulsionPairs() -> [(Int, Int)] {
        if nodes.count <= 220 {
            var pairs: [(Int, Int)] = []
            for lhs in nodes.indices {
                guard lhs + 1 < nodes.count else { continue }
                for rhs in (lhs + 1)..<nodes.count {
                    pairs.append((lhs, rhs))
                }
            }
            return pairs
        }

        let stride = max(7, nodes.count / 37)
        let sampleCount = min(48, max(18, nodes.count / 12))
        var seen: Set<String> = []
        var pairs: [(Int, Int)] = []
        for lhs in nodes.indices {
            for offset in 1...sampleCount {
                let rhs = (lhs + offset * stride) % nodes.count
                guard lhs != rhs else { continue }
                let first = min(lhs, rhs)
                let second = max(lhs, rhs)
                let key = "\(first)-\(second)"
                guard seen.insert(key).inserted else { continue }
                pairs.append((first, second))
            }
        }
        return pairs
    }

    private func bounded(_ point: CGPoint, in size: CGSize, margin: CGFloat) -> CGPoint {
        CGPoint(
            x: min(max(point.x, margin), max(margin, size.width - margin)),
            y: min(max(point.y, margin), max(margin, size.height - margin))
        )
    }

    private func stableAngle(for value: String) -> CGFloat {
        stableUnitValue(for: value) * CGFloat.pi * 2
    }

    private func stableUnitValue(for value: String) -> CGFloat {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return CGFloat(hash % 10_000) / 10_000
    }

    private static func wikilinks(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let raw = ns.substring(with: match.range(at: 1))
            let display = raw.components(separatedBy: "|").first ?? raw
            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

private struct AirtableTablePreviewView: View {
    let table: AirtableTablePreview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "tablecells")
                    .foregroundStyle(.orange)
                Text(table.name)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(table.rows.count) records")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
                            Text(header.isEmpty ? "Untitled" : header)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(minWidth: 140, maxWidth: 240, alignment: .leading)
                                .padding(8)
                                .background(Color(nsColor: .controlBackgroundColor))
                        }
                    }

                    ForEach(Array(table.rows.prefix(500).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(table.headers.indices, id: \.self) { index in
                                Text(index < row.count ? row[index] : "")
                                    .font(.caption)
                                    .lineLimit(3)
                                    .frame(minWidth: 140, maxWidth: 240, alignment: .leading)
                                    .padding(8)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
    }
}

/// Separate view that observes a single tab so isRecording changes trigger re-render.
private struct ActiveTabRecordingIndicator: View {
    @ObservedObject var tab: OpenMeetingTab

    var body: some View {
        if tab.isRecording, let session = tab.session {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    LiveDurationView(startDate: tab.transcript.startDate)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Button(action: { Task { await session.stop() } }) {
                    Text("Stop recording")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.red))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Content View for a Single Tab

private enum MeetingContentTab: Hashable {
    case article
    case notes
    case transcript
    case summary

    var label: String {
        switch self {
        case .article: return "Article"
        case .notes: return "Notes"
        case .transcript: return "Transcript"
        case .summary: return "Summary"
        }
    }
}

struct MeetingTabContentView: View {
    @ObservedObject var tab: OpenMeetingTab
    @ObservedObject var transcript: MeetingTranscript
    @ObservedObject var state: MeetingWindowState

    init(tab: OpenMeetingTab, state: MeetingWindowState) {
        self.tab = tab
        self.transcript = tab.transcript
        self.state = state
    }
    @State private var selectedContentTab: MeetingContentTab = .notes
    @State private var searchText = ""
    @State private var showSearch = false
    @State private var currentMatchIndex: Int = 0
    @State private var matchCount: Int = 0
    @State private var showSummaryPrompt = false
    @State private var speakerLabelDrafts: [String: String] = [:]
    @State private var speakerReviewError: String?
    @AppStorage("meetingSummaryPrompt") private var summaryPrompt: String = MeetingSummaryGenerator.finalSummaryPrompt
    @AppStorage("selectedCleanupModelKind") private var selectedModelKind: String = LocalCleanupModelKind.qwen35_0_8b_q4_k_m.rawValue
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title + date
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            TextField("Untitled", text: $tab.transcript.meetingName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.primary)
                                .onSubmit { state.renameActiveTab() }

                            if tab.isRecording {
                                Button(action: { tab.session?.refreshTitleAndAttendees() }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "sparkle.magnifyingglass")
                                            .font(.system(size: 11))
                                        Text("Detect")
                                            .font(.caption)
                                    }
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                                .help("Grab meeting name and attendee names from the meeting app window")
                            }
                        }

                        HStack(spacing: 8) {
                            Text(dateSubtitle)
                                .font(.callout)
                                .foregroundColor(.secondary)

                            if tab.transcript.importedFrom != nil {
                                Text("Imported from \(tab.transcript.importedFrom!.capitalized)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.1))
                                    .cornerRadius(4)
                            }
                        }
                        .padding(.bottom, tab.transcript.attendees.isEmpty ? 20 : 8)

                        if !tab.transcript.attendees.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "person.2")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                ForEach(tab.transcript.attendees, id: \.self) { attendee in
                                    Text(attendee.name)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(attendee.declined ? .red : .primary)
                                        .strikethrough(attendee.declined)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color(nsColor: .controlBackgroundColor))
                                        .cornerRadius(10)
                                        .help(attendee.declined ? "Declined" : "")
                                }
                                Spacer()
                            }
                            .padding(.bottom, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        Button(action: {
                            generateWiki()
                        }) {
                            Label(state.isGeneratingMeetingWiki ? "Adding…" : "Add to Brain", systemImage: "sparkles.rectangle.stack")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(tab.fileURL == nil || tab.isRecording || state.isGeneratingMeetingWiki)
                        .help(tab.fileURL == nil ? "Save this meeting before adding it to the 2nd Brain" : "Create or update generated 2nd Brain pages for this meeting")

                        ActiveTabRecordingIndicator(tab: tab)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)

            // Content tabs (Notes / Transcript / Summary)
            contentTabBar
                .padding(.horizontal, 48)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)

            // Search
            if showSearch {
                searchBar
            }

            // No audio warning
            if let session = tab.session, session.noAudioDetected {
                noAudioWarning
            }

            // Content
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        contentForTab(proxy: proxy)
                    }
                    .padding(.horizontal, 48)
                    .padding(.top, 24)
                    .padding(.bottom, 60)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: tab.transcript.segments.count) { _, _ in
                    if selectedContentTab == .transcript, let last = tab.transcript.segments.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Status bar
            statusBar
        }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "f" else {
                    if event.keyCode == 53, showSearch { // Escape
                        showSearch = false; searchText = ""
                        return nil
                    }
                    return event
                }
                showSearch.toggle()
                if !showSearch { searchText = "" }
                return nil
            }
        }
    }

    private func generateWiki() {
        guard let fileURL = tab.fileURL else {
            return
        }
        state.saveActiveTab()
        state.pendingGenerateWikiURL = fileURL
    }

    // MARK: - Date subtitle

    private var dateSubtitle: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        if let end = tab.transcript.endDate {
            let endFmt = DateFormatter()
            endFmt.timeStyle = .short
            return "\(fmt.string(from: tab.transcript.startDate)) — \(endFmt.string(from: end))"
        }
        return fmt.string(from: tab.transcript.startDate)
    }

    // MARK: - Content Tab Bar

    private var availableContentTabs: [MeetingContentTab] {
        if tab.transcript.articleBody != nil {
            return [.article, .notes]
        }
        return [.notes, .transcript, .summary]
    }

    private var contentTabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(availableContentTabs, id: \.self) { ct in
                    Button(action: { selectedContentTab = ct }) {
                        Text(ct.label)
                            .font(.system(size: 13, weight: selectedContentTab == ct ? .semibold : .regular))
                            .foregroundColor(selectedContentTab == ct ? .orange : .secondary)
                            .padding(.bottom, 10)
                            .overlay(alignment: .bottom) {
                                if selectedContentTab == ct {
                                    Rectangle().fill(Color.orange).frame(height: 2).offset(y: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
        .onAppear {
            if !availableContentTabs.contains(selectedContentTab) {
                selectedContentTab = availableContentTabs.first ?? .notes
            }
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.caption)
            TextField("Search...", text: $searchText)
                .textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                .onSubmit { advanceMatch(forward: true) }
            if !searchText.isEmpty {
                Text(matchCount == 0 ? "no matches" : "\(currentMatchIndex + 1) / \(matchCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                Button(action: { advanceMatch(forward: false) }) {
                    Image(systemName: "chevron.up").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(matchCount == 0)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                Button(action: { advanceMatch(forward: true) }) {
                    Image(systemName: "chevron.down").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(matchCount == 0)
                .keyboardShortcut("g", modifiers: [.command])
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.caption)
                }.buttonStyle(.plain)
            }
            Button(action: { showSearch = false; searchText = "" }) {
                Text("Done").font(.caption).foregroundColor(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 52).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .onAppear { searchFocused = true }
        .onChange(of: searchText) { _, _ in currentMatchIndex = 0 }
        .onChange(of: selectedContentTab) { _, _ in currentMatchIndex = 0 }
    }

    private func advanceMatch(forward: Bool) {
        guard matchCount > 0 else { return }
        currentMatchIndex = forward
            ? (currentMatchIndex + 1) % matchCount
            : (currentMatchIndex - 1 + matchCount) % matchCount
    }

    // MARK: - No Audio Warning

    private var noAudioWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.caption)
            Text("No audio detected. Check your microphone.").font(.caption)
            Spacer()
            Button("Open Settings") { state.onOpenSettings?() }
                .font(.caption.weight(.medium)).buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func contentForTab(proxy: ScrollViewProxy) -> some View {
        switch selectedContentTab {
        case .article: articleContent
        case .notes: notesContent
        case .transcript: transcriptContent
        case .summary: summaryContent
        }
    }

    private static let notesFont = Font.custom("Georgia", size: 15)
    private static let articleFont = Font.custom("Georgia", size: 16)

    @ViewBuilder
    private var articleContent: some View {
        if let body = tab.transcript.articleBody {
            VStack(alignment: .leading, spacing: 8) {
                if let source = tab.transcript.sourceURL,
                   let url = URL(string: source),
                   let host = url.host {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10))
                            Text(host)
                                .font(.caption)
                        }
                        .foregroundColor(.orange)
                    }
                    .padding(.bottom, 4)
                }
                if !searchText.isEmpty {
                    HighlightedTextView(
                        text: body,
                        query: searchText,
                        currentMatchIndex: currentMatchIndex,
                        font: NSFont(name: "Georgia", size: 16) ?? NSFont.systemFont(ofSize: 16),
                        onMatchCountChange: { matchCount = $0 }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(body)
                        .font(Self.articleFont)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Text("No article saved.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var notesContent: some View {
        if !searchText.isEmpty {
            HighlightedTextView(
                text: tab.transcript.notes,
                query: searchText,
                currentMatchIndex: currentMatchIndex,
                font: NSFont(name: "Georgia", size: 15) ?? NSFont.systemFont(ofSize: 15),
                onMatchCountChange: { matchCount = $0 }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack(alignment: .topLeading) {
                if tab.transcript.notes.isEmpty {
                    Text("Start typing your notes...")
                        .font(Self.notesFont)
                        .foregroundColor(Color(nsColor: .placeholderTextColor))
                        .padding(.top, 1).padding(.leading, 6)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $tab.transcript.notes)
                    .font(Self.notesFont).lineSpacing(6)
                    .scrollContentBackground(.hidden)
                    .frame(maxHeight: .infinity)
                    .onChange(of: tab.transcript.notes) { _, _ in
                        state.saveActiveTab()
                    }
            }
        }
    }

    private func highlightedAttributed(_ source: String, query: String) -> AttributedString {
        var attributed = AttributedString(source)
        let q = query.lowercased()
        guard !q.isEmpty else { return attributed }
        let lower = source.lowercased()
        var searchRange = lower.startIndex..<lower.endIndex
        while let range = lower.range(of: q, range: searchRange) {
            if let aRange = Range(range, in: attributed) {
                attributed[aRange].backgroundColor = .orange.opacity(0.35)
                attributed[aRange].foregroundColor = .primary
            }
            searchRange = range.upperBound..<lower.endIndex
        }
        return attributed
    }

    private var filteredSegments: [TranscriptSegment] {
        guard !searchText.isEmpty else { return tab.transcript.segments }
        return tab.transcript.segments.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    private var speakerReviewItems: [MeetingSpeakerReviewItem] {
        guard !tab.isRecording else {
            return []
        }
        return state.onLoadSpeakerReviewItems?(tab.transcript) ?? []
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !speakerReviewItems.isEmpty, searchText.isEmpty {
                speakerReviewSection
                    .padding(.bottom, 8)
            }

            if tab.transcript.segments.isEmpty {
                if tab.isRecording {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.6)
                        Text("Listening — segments appear every ~30 seconds").font(.callout).foregroundColor(.secondary)
                    }.padding(.vertical, 8)
                } else {
                    Text("No transcript yet.").font(.callout).foregroundColor(.secondary).padding(.vertical, 8)
                }
            }
            ForEach(filteredSegments) { segment in
                TranscriptSegmentRow(segment: segment, highlightText: searchText).id(segment.id)
            }
            if tab.isRecording && !tab.transcript.segments.isEmpty {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.secondary.opacity(0.4)).frame(width: 4, height: 4)
                        Circle().fill(Color.secondary.opacity(0.3)).frame(width: 4, height: 4)
                        Circle().fill(Color.secondary.opacity(0.2)).frame(width: 4, height: 4)
                    }
                    Text("Listening...").font(.caption).foregroundColor(.secondary)
                }.padding(.top, 4)
            }
        }
    }

    private var speakerReviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.wave.2")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                Text("Speakers")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: { state.onOpenSettings?() }) {
                    Label("Voice Library", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            if let speakerReviewError {
                Text(speakerReviewError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ForEach(speakerReviewItems) { item in
                SpeakerReviewRow(
                    item: item,
                    draftName: Binding(
                        get: { speakerLabelDrafts[item.id] ?? item.displayName },
                        set: { speakerLabelDrafts[item.id] = $0 }
                    ),
                    onSave: {
                        commitSpeakerLabel(item)
                    }
                )
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func commitSpeakerLabel(_ item: MeetingSpeakerReviewItem) {
        let draftName = (speakerLabelDrafts[item.id] ?? item.displayName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draftName.isEmpty, draftName != item.displayName else {
            return
        }

        do {
            try state.onUpdateSpeakerLabel?(tab.transcript, item.displayName, draftName)
            speakerReviewError = nil
            speakerLabelDrafts.removeValue(forKey: item.id)
            state.saveActiveTab()
        } catch {
            speakerReviewError = "Could not save speaker label."
        }
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            if tab.isRecording {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 32)).foregroundColor(.orange.opacity(0.4))
                    Text("Summary will be generated when the meeting ends").font(.callout).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 60)
            } else if tab.transcript.isGeneratingSummary {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(0.8)
                    Text("Generating summary...").font(.callout).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 60)
            } else if tab.transcript.summary != nil {
                summaryStats
            } else if tab.transcript.segments.isEmpty {
                Text("No transcript to summarize.").font(.callout).foregroundColor(.secondary).padding(.vertical, 40)
            } else {
                summaryStats
            }
        }
    }

    private var summaryStats: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Generate / Regenerate button row
            HStack {
                if tab.transcript.summary != nil {
                    Button(action: { regenerateSummary() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                            Text("Regenerate")
                                .font(.caption)
                        }
                        .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                    .disabled(tab.transcript.isGeneratingSummary)
                } else {
                    Button(action: { regenerateSummary() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                            Text("Generate Summary")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.orange))
                    }
                    .buttonStyle(.plain)
                    .disabled(tab.transcript.isGeneratingSummary || tab.transcript.segments.isEmpty)
                }

                Spacer()

                // Toggle prompt editor
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showSummaryPrompt.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10))
                        Text("Customize")
                            .font(.caption)
                    }
                    .foregroundColor(showSummaryPrompt ? .orange : .secondary)
                }
                .buttonStyle(.plain)
            }

            // Inline prompt editor (collapsible)
            if showSummaryPrompt {
                VStack(alignment: .leading, spacing: 8) {
                    // Model picker
                    HStack {
                        Text("Model")
                            .font(.caption).foregroundColor(.secondary)
                        Picker("", selection: $selectedModelKind) {
                            ForEach(TextCleanupManager.cleanupGenerationModels, id: \.kind) { model in
                                Text(model.displayName).tag(model.kind.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }

                    // Prompt editor
                    Text("Summary prompt")
                        .font(.caption).foregroundColor(.secondary)

                    TextEditor(text: $summaryPrompt)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                        .frame(height: 120)

                    HStack {
                        Button("Reset to Default") {
                            summaryPrompt = MeetingSummaryGenerator.finalSummaryPrompt
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)

                        Spacer()
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }

            // Editable summary (same style as notes); read-only highlighted while searching.
            if !searchText.isEmpty {
                HighlightedTextView(
                    text: tab.transcript.summary ?? "",
                    query: searchText,
                    currentMatchIndex: currentMatchIndex,
                    font: NSFont(name: "Georgia", size: 15) ?? NSFont.systemFont(ofSize: 15),
                    onMatchCountChange: { matchCount = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .topLeading) {
                    if (tab.transcript.summary ?? "").isEmpty {
                        Text("Summary will appear here after generation...")
                            .font(Self.notesFont)
                            .foregroundColor(Color(nsColor: .placeholderTextColor))
                            .padding(.top, 1).padding(.leading, 6)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: Binding(
                        get: { tab.transcript.summary ?? "" },
                        set: { tab.transcript.summary = $0.isEmpty ? nil : $0 }
                    ))
                    .font(Self.notesFont)
                    .lineSpacing(6)
                    .scrollContentBackground(.hidden)
                    .frame(maxHeight: .infinity)
                    .onChange(of: tab.transcript.summary) { _, _ in
                        state.saveActiveTab()
                    }
                }
            }
        }
    }

    // MARK: - Status Bar

    private func regenerateSummary() {
        state.onGenerateSummary?(tab.transcript)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let url = tab.fileURL {
                Button(action: {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                        Text(url.lastPathComponent)
                    }.font(.caption).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            Spacer()
            if !tab.transcript.segments.isEmpty {
                Text("\(tab.transcript.segments.count) segments").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(height: 1)
        }
    }
}

// MARK: - Sidebar

struct MeetingSidebarView: View {
    @ObservedObject var state: MeetingWindowState
    @State private var searchText = ""
    @State private var expandedLibraryFolders: Set<String> = []
    @State private var expandedWikiFolders: Set<String> = []
    @State private var expandedAirtableFolders: Set<String> = []
    @AppStorage(AppTheme.storageKey) private var selectedThemeID = AppThemeID.current.rawValue

    private var appTheme: AppTheme {
        AppTheme.resolve(selectedThemeID)
    }

    private var meetingGroups: [(date: String, entries: [MeetingHistoryEntry])] {
        let groups = state.historyGroups.compactMap { group in
            let entries = group.entries.filter { !$0.isAirtable }
            return entries.isEmpty ? nil : (date: group.date, entries: entries)
        }
        guard !searchText.isEmpty else { return groups }
        let query = searchText.lowercased()
        return groups.compactMap { group in
            let entries = group.entries.filter { $0.name.lowercased().contains(query) }
            return entries.isEmpty ? nil : (date: group.date, entries: entries)
        }
    }

    private var airtableGroups: [(date: String, entries: [MeetingHistoryEntry])] {
        let groups = state.historyGroups.compactMap { group in
            let entries = group.entries.filter { $0.isAirtable }
            return entries.isEmpty ? nil : (date: group.date, entries: entries)
        }
        guard !searchText.isEmpty else { return groups }
        let query = searchText.lowercased()
        return groups.compactMap { group in
            let entries = group.entries.filter { $0.name.lowercased().contains(query) || group.date.lowercased().contains(query) }
            return entries.isEmpty ? nil : (date: group.date, entries: entries)
        }
    }

    private var filteredWikiFolders: [GeneratedWikiSidebarFolder] {
        guard !searchText.isEmpty else { return state.generatedWikiFolders }
        let query = searchText.lowercased()
        return state.generatedWikiFolders.compactMap { folder in
            let items = folder.items.filter { $0.title.lowercased().contains(query) }
            if items.isEmpty && !folder.title.lowercased().contains(query) { return nil }
            return GeneratedWikiSidebarFolder(
                slug: folder.slug,
                title: folder.title,
                iconSystemName: folder.iconSystemName,
                items: items.isEmpty ? folder.items : items
            )
        }
    }

    private var wikiPageCount: Int {
        filteredWikiFolders.reduce(0) { $0 + $1.items.count }
    }

    private var airtableItemCount: Int {
        airtableGroups.reduce(0) { $0 + $1.entries.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Library")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()

                Button(action: { openMeetingsFolder() }) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().padding(.horizontal, 12).padding(.bottom, 4)

            // Search field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                TextField("Search library", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(appTheme.textBackground.opacity(appTheme.id == .current ? 0.5 : 0.9))
            .cornerRadius(appTheme.id == .windows95 ? 0 : 6)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    indexesSection
                    generatedWikiSection
                    airtableSection

                    if meetingGroups.isEmpty && airtableGroups.isEmpty && filteredWikiFolders.allSatisfy({ $0.items.isEmpty }) && !searchText.isEmpty {
                        Text(searchText.isEmpty ? "No past meetings or 2nd Brain pages" : "No matches")
                            .font(.caption).foregroundColor(.secondary)
                            .padding(.horizontal, 16).padding(.top, 8)
                    }

                    if !meetingGroups.isEmpty {
                        Text("Meetings")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 2)
                    }

                    ForEach(meetingGroups, id: \.date) { group in
                        Text(group.date)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 10).padding(.bottom, 2)

                        ForEach(group.entries) { entry in
                            let isOpen = state.tabs.contains { $0.fileURL == entry.fileURL }
                            Button(action: { state.openFile(entry.fileURL) }) {
                                HStack(spacing: 6) {
                                    Image(systemName: entry.isGranola ? "square.and.arrow.down.on.square" : "doc.text")
                                        .font(.system(size: 10))
                                        .foregroundColor(isOpen ? appTheme.accent : (entry.isGranola ? .green.opacity(0.7) : .secondary))
                                    Text(entry.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(isOpen ? appTheme.accent : .primary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.selectFile(
                                        entry.fileURL.path,
                                        inFileViewerRootedAtPath: entry.fileURL.deletingLastPathComponent().path
                                    )
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    deleteEntry(entry)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(appTheme.controlBackground)
        .onAppear {
            state.loadGeneratedWikiFolders()
        }
    }

    private func deleteEntry(_ entry: MeetingHistoryEntry) {
        // Close the tab if it's open
        if let tab = state.tabs.first(where: { $0.fileURL == entry.fileURL }) {
            state.closeTab(tab.id)
        }
        // Move to trash
        do {
            try FileManager.default.trashItem(at: entry.fileURL, resultingItemURL: nil)
            state.loadHistory()
        } catch {
            print("Failed to delete \(entry.fileURL.lastPathComponent): \(error)")
        }
    }

    private func openMeetingsFolder() {
        let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
        NSWorkspace.shared.open(dir)
    }

    private func openWikiFolder() {
        NSWorkspace.shared.open(state.generatedWikiRootForDisplay())
    }

    private func openAirtableFolder() {
        NSWorkspace.shared.open(state.saveDirectory.appendingPathComponent("Airtable", isDirectory: true))
    }

    @ViewBuilder
    private var indexesSection: some View {
        ForEach(IndexKind.allCases) { kind in
            if let items = state.indexItems[kind] {
                indexFolderRow(kind: kind, count: items.count)
            }
        }
        if !state.wikiProposals.isEmpty {
            wikiSuggestionRow
        }
    }

    @ViewBuilder
    private var generatedWikiSection: some View {
        if !filteredWikiFolders.isEmpty {
            topLevelFolderRow(
                id: "wiki",
                title: "2nd Brain",
                icon: "books.vertical",
                count: wikiPageCount,
                primaryAction: { state.openSecondBrain() },
                openAction: openWikiFolder
            )
            if expandedLibraryFolders.contains("wiki") || !searchText.isEmpty {
                ForEach(filteredWikiFolders) { folder in
                    generatedWikiFolderRow(folder)
                    if expandedWikiFolders.contains(folder.slug) || !searchText.isEmpty {
                        ForEach(folder.items) { item in
                            generatedWikiItemRow(item)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var airtableSection: some View {
        if searchText.isEmpty || !airtableGroups.isEmpty {
            topLevelFolderRow(
                id: "airtable",
                title: "Airtable",
                icon: "tablecells",
                count: airtableItemCount,
                openAction: openAirtableFolder
            )
            if expandedLibraryFolders.contains("airtable") {
                if airtableGroups.isEmpty {
                    Text("No Airtable imports")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 34)
                        .padding(.trailing, 12)
                        .padding(.vertical, 4)
                }
            ForEach(airtableGroups, id: \.date) { group in
                airtableFolderRow(group)
                if expandedAirtableFolders.contains(group.date) {
                    ForEach(group.entries) { entry in
                        airtableItemRow(entry)
                    }
                }
            }
            }
        }
    }

    private func topLevelFolderRow(id: String, title: String, icon: String, count: Int, primaryAction: (() -> Void)? = nil, openAction: @escaping () -> Void) -> some View {
        Button(action: {
            if let primaryAction {
                primaryAction()
            }
            if expandedLibraryFolders.contains(id) {
                expandedLibraryFolders.remove(id)
            } else {
                expandedLibraryFolders.insert(id)
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: expandedLibraryFolders.contains(id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("(\(count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: openAction) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(title) source folder in Finder")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show in Finder", action: openAction)
        }
        .padding(.top, 8)
    }

    private func generatedWikiFolderRow(_ folder: GeneratedWikiSidebarFolder) -> some View {
        Button(action: {
            if expandedWikiFolders.contains(folder.slug) {
                expandedWikiFolders.remove(folder.slug)
            } else {
                expandedWikiFolders.insert(folder.slug)
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: expandedWikiFolders.contains(folder.slug) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Image(systemName: folder.iconSystemName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(folder.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("(\(folder.items.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 12)
    }

    private func generatedWikiItemRow(_ item: GeneratedWikiSidebarItem) -> some View {
        let isOpen = state.indexTabs.contains { tab in
            if case let .generatedWikiPage(page) = tab.content { return page.url == item.fileURL }
            return false
        }
        return Button(action: { state.openGeneratedWikiPage(item.fileURL) }) {
            HStack(spacing: 6) {
                Image(systemName: item.type == "meeting_overview" ? "doc.richtext" : "doc.text")
                    .font(.system(size: 10))
                    .foregroundColor(isOpen ? .orange : .secondary)
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundColor(isOpen ? .orange : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.leading, 34)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 12)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(
                    item.fileURL.path,
                    inFileViewerRootedAtPath: item.fileURL.deletingLastPathComponent().path
                )
            }
        }
    }

    private func airtableFolderRow(_ group: (date: String, entries: [MeetingHistoryEntry])) -> some View {
        let title = group.date.replacingOccurrences(of: "Airtable: ", with: "")
        return Button(action: {
            if expandedAirtableFolders.contains(group.date) {
                expandedAirtableFolders.remove(group.date)
            } else {
                expandedAirtableFolders.insert(group.date)
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: expandedAirtableFolders.contains(group.date) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Image(systemName: "tray.full")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("(\(group.entries.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func airtableItemRow(_ entry: MeetingHistoryEntry) -> some View {
        Button(action: { state.openFile(entry.fileURL) }) {
            HStack(spacing: 6) {
                Image(systemName: "tablecells")
                    .font(.system(size: 10))
                    .foregroundColor(.green.opacity(0.75))
                Text(entry.name)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.leading, 34)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(
                    entry.fileURL.path,
                    inFileViewerRootedAtPath: entry.fileURL.deletingLastPathComponent().path
                )
            }
        }
    }

    /// Surfaces pending model-proposed wikis; clicking opens the approval sheet.
    private var wikiSuggestionRow: some View {
        Button(action: { state.showNewWikiSheet = true }) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text(state.wikiProposals.count == 1
                     ? "Suggested 2nd Brain: \(state.wikiProposals[0].spec.displayName)"
                     : "\(state.wikiProposals.count) suggested 2nd Brains")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private func indexFolderRow(kind: IndexKind, count: Int) -> some View {
        let isOpen: Bool = state.indexTabs.contains { tab in
            if case let .indexList(k) = tab.content { return k == kind }
            return false
        }
        return Button(action: { state.openIndexList(kind: kind) }) {
            HStack(spacing: 6) {
                Image(systemName: kind.iconSystemName)
                    .font(.system(size: 11))
                    .foregroundColor(isOpen ? .orange : .secondary)
                Text(kind.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isOpen ? .orange : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("(\(count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }
}

// MARK: - Missing API Key

private struct MissingAPIKeyView: View {
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "key")
                    .font(.system(size: 16))
                Text("Claude API key required")
                    .font(.system(size: 16, weight: .semibold))
            }
            Text("Index building uses Claude (Anthropic API). Add your API key in Settings → Meeting Transcript → Cloud API.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                Button("Open Settings") {
                    onOpenSettings()
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - Consent Dialog

private struct ConsentDialogView: View {
    @ObservedObject var state: MeetingWindowState
    @State private var copied = false
    @AppStorage("skipConsentDialog") private var skipConsent = false

    private static let consentMessage = "I'm using 🌶️ Ghost Pepper, a completely private AI note taker. Nothing leaves my computer and all AI models are done on device."

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Image(systemName: "mic.badge.xmark")
                .font(.system(size: 36))
                .foregroundColor(.orange)
                .padding(.top, 8)

            Text("Let participants know")
                .font(.title3.bold())

            Text("Before recording, share this with your meeting participants:")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Message to copy
            VStack(spacing: 8) {
                Text(Self.consentMessage)
                    .font(.system(size: 13))
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.consentMessage, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied!" : "Copy to clipboard")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }

            Divider()

            if let recordingStartError = state.recordingStartError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                        .padding(.top, 1)
                    Text(recordingStartError)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            // Buttons
            VStack(spacing: 12) {
                Button(action: { state.confirmRecording() }) {
                    Text("I've informed participants — Start recording")
                        .font(.callout.weight(.medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange))
                }
                .buttonStyle(.plain)

                Button(action: { state.cancelRecording() }) {
                    Text("Cancel")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Don't ask again
            Toggle(isOn: $skipConsent) {
                Text("Don't ask again (my jurisdiction doesn't require consent)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .toggleStyle(.checkbox)
            .padding(.bottom, 4)
        }
        .padding(24)
        .frame(width: 400)
    }
}

// MARK: - Helper Views

/// Small inline button that copies text to the clipboard and briefly shows a
/// confirmation. Manages its own transient "Copied!" state, so it can be reused
/// across multiple rows (e.g. one per Q&A turn) without shared state. The text
/// is supplied as a closure so it's evaluated lazily at click time.
private struct CopyButton: View {
    let text: () -> String
    var label: String = "Copy"
    @State private var copied = false

    var body: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        }) {
            Label(copied ? "Copied!" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
    }
}

private struct SummarySectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.secondary).tracking(0.5)
    }
}

private struct StatBlock: View {
    let value: String
    let label: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold)).foregroundColor(color)
            Text(label).font(.caption).foregroundColor(.secondary)
        }
    }
}

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    var highlightText: String = ""

    private var showSpeakerBadge: Bool {
        switch segment.speaker {
        case .me: return true
        case .remote(let name): return name != nil
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(segment.formattedTimestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)
            if showSpeakerBadge {
                Text(segment.speaker.displayName)
                    .font(.caption2.weight(.semibold)).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(speakerColor))
            }
            highlightedText
                .font(.system(size: 14)).lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var highlightedText: Text {
        guard !highlightText.isEmpty else { return Text(segment.text) }
        var attributed = AttributedString(segment.text)
        let query = highlightText.lowercased()
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let range = attributed[searchRange].range(of: query, options: .caseInsensitive) {
            attributed[range].backgroundColor = .yellow.opacity(0.5)
            attributed[range].foregroundColor = .black
            searchRange = range.upperBound..<attributed.endIndex
        }
        return Text(attributed)
    }

    private var speakerColor: Color {
        switch segment.speaker {
        case .me: return .orange
        case .remote: return .blue
        }
    }
}

private struct SpeakerReviewRow: View {
    let item: MeetingSpeakerReviewItem
    @Binding var draftName: String
    let onSave: () -> Void

    private var normalizedDraftName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !normalizedDraftName.isEmpty && normalizedDraftName != item.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                TextField("Speaker name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(minWidth: 160, maxWidth: 240)
                    .onSubmit {
                        if canSave {
                            onSave()
                        }
                    }

                Text(statusText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(item.isVoicePrintBacked ? .green : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(item.isVoicePrintBacked ? Color.green.opacity(0.12) : Color.secondary.opacity(0.1))
                    )

                Text("\(item.segmentCount) \(item.segmentCount == 1 ? "turn" : "turns")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: onSave) {
                    Label("Save", systemImage: "checkmark")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canSave)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.firstTimestamp)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 42, alignment: .trailing)
                Text(item.sampleText.isEmpty ? "No transcript sample available." : item.sampleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
    }

    private var statusText: String {
        if item.isMe {
            return "You"
        }
        return item.isVoicePrintBacked ? "Voice print" : "Transcript label"
    }
}

struct LiveDurationView: View {
    let startDate: Date
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(formattedDuration).onReceive(timer) { now = $0 }
    }

    private var formattedDuration: String {
        let total = Int(now.timeIntervalSince(startDate))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
