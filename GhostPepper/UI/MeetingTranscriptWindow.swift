import AppKit
import Combine
import SwiftUI
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
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var isFinished: Bool = false
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
    @Published var failedSourceSummaries: [String] = []

    private var completedInputTokens: Int = 0
    private var completedOutputTokens: Int = 0
    private var currentInputTokenEstimate: Int = 0

    init(meetingURL: URL, archiveRoot: URL, modelCallTotal: Int = 2) {
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
        return selectedFunction.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? 0
            : max(1, selectedFunction.output.count / 4)
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
        guard let selectedFunction else {
            return """
            [status] Preparing 2nd Brain run
            [sources] \(completedSourceCount)/\(totalSourceCount) complete
            [model] Waiting for the local model...
            """
        }
        let output = selectedFunction.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            return """
            [status] \(status)
            [source] \(currentSourceTitle)
            [sources] \(completedSourceCount)/\(totalSourceCount) complete
            [step] \(selectedFunction.name)
            [input] ~\(selectedFunction.inputTokens) input tokens prepared
            [model] Prompt sent; waiting for the first output token...
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

    func sourceFailed(_ url: URL, error: Error) {
        completedSourceCount += 1
        failedSourceSummaries.append("\(url.lastPathComponent): \(error.localizedDescription)")
        status = "Skipped \(url.deletingPathExtension().lastPathComponent): \(error.localizedDescription)"
    }

    func handle(_ progress: GeneratedWikiProgress) {
        switch progress {
        case .status(let message):
            status = message
        case .functionStarted(let name, let system, let user):
            status = name
            currentInputTokenEstimate = max(1, (system.count + user.count) / 4)
            estimatedInputTokens = completedInputTokens + currentInputTokenEstimate
            estimatedOutputTokens = completedOutputTokens
            let run = WikiGenerationFunctionRun(
                name: name,
                system: system,
                user: user,
                inputTokens: currentInputTokenEstimate,
                outputTokens: 0,
                isFinished: false
            )
            functions.append(run)
            selectedFunctionID = run.id
        case .token(let token):
            guard let idx = functions.indices.last else { return }
            functions[idx].output += token
            estimatedOutputTokens = completedOutputTokens + max(1, functions[idx].output.count / 4)
        case .functionFinished(let name, let output, let inputTokens, let outputTokens):
            status = "\(name) complete"
            if let idx = functions.lastIndex(where: { $0.name == name && !$0.isFinished }) ?? functions.indices.last {
                functions[idx].output = output
                functions[idx].inputTokens = inputTokens
                functions[idx].outputTokens = outputTokens
                functions[idx].isFinished = true
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

// MARK: - Window Controller

@MainActor
final class MeetingTranscriptWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onOpenSettings: (() -> Void)?
    var onStartRecording: ((_ name: String, _ detectedMeeting: DetectedMeeting?) -> MeetingSession?)?
    var onStopRecording: ((MeetingSession) -> Void)?
    var onGenerateSummary: ((MeetingTranscript) -> Void)?
    var onLoadSpeakerReviewItems: ((MeetingTranscript) -> [MeetingSpeakerReviewItem])?
    var onUpdateSpeakerLabel: ((_ transcript: MeetingTranscript, _ currentDisplayName: String, _ newDisplayName: String) throws -> Void)?
    var onAskQuestion: ((_ question: String, _ history: [QAHistoryTurn]) -> AsyncThrowingStream<QAEvent, Error>)?
    var onMakeIndexBuilder: ((IndexKind) -> (any IndexBuilding)?)?
    var onGenerateWikiProposals: (() async throws -> [WikiKindProposal])?
    var onApproveWikiKind: ((WikiKindSpec) -> Void)?
    var onGenerateMeetingWiki: ((_ meetingURL: URL, _ onProgress: @MainActor @escaping (GeneratedWikiProgress) -> Void) async throws -> GeneratedWikiResult)?
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
        state.pendingSourceURL = sourceURL
        state.pendingDetectedMeeting = detectedMeeting
        if skipConsent || UserDefaults.standard.bool(forKey: "skipConsentDialog") {
            guard let session = state.onStartRecording?(name, detectedMeeting) else { return }
            state.addRecordingTab(session: session)
            // Add URL to notes if provided
            if let url = sourceURL {
                session.transcript.notes = "Source: \(url)\n\n"
            }
            state.pendingSourceURL = nil
            state.pendingDetectedMeeting = nil
        } else {
            state.pendingRecordingName = name
            state.showConsentDialog = true
        }
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
    var pendingRecordingName: String?
    var pendingSourceURL: String?
    var pendingDetectedMeeting: DetectedMeeting?
    var pendingCalendarEvent: CalendarEvent?
    var onRecordingStateChanged: (() -> Void)?

    var onOpenSettings: (() -> Void)?
    var onStartRecording: ((_ name: String, _ detectedMeeting: DetectedMeeting?) -> MeetingSession?)?
    var onStopRecording: ((MeetingSession) -> Void)?
    var onGenerateSummary: ((MeetingTranscript) -> Void)?
    var onLoadSpeakerReviewItems: ((MeetingTranscript) -> [MeetingSpeakerReviewItem])?
    var onUpdateSpeakerLabel: ((_ transcript: MeetingTranscript, _ currentDisplayName: String, _ newDisplayName: String) throws -> Void)?
    var onMakeIndexBuilder: ((IndexKind) -> (any IndexBuilding)?)?
    var onGenerateWikiProposals: (() async throws -> [WikiKindProposal])?
    var onApproveWikiKind: ((WikiKindSpec) -> Void)?
    var onGenerateMeetingWiki: ((_ meetingURL: URL, _ onProgress: @MainActor @escaping (GeneratedWikiProgress) -> Void) async throws -> GeneratedWikiResult)?

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

    func resolveGeneratedWikilink(slug: String) -> URL? {
        for archiveRoot in generatedWikiArchiveCandidates() {
            if let url = GeneratedWikiPaths.findPage(in: archiveRoot, slug: slug) {
                return url
            }
        }
        return nil
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
        startWithGeneratedName(prefix: "Ad Hoc Call")
    }

    private func startWithGeneratedName(prefix: String) {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let name = "\(prefix) — \(formatter.string(from: Date()))"

        if UserDefaults.standard.bool(forKey: "skipConsentDialog") {
            guard let session = onStartRecording?(name, nil) else { return }
            addRecordingTab(session: session)
        } else {
            pendingRecordingName = name
            showConsentDialog = true
        }
    }

    func startCalendarMeeting(_ event: CalendarEvent) {
        if UserDefaults.standard.bool(forKey: "skipConsentDialog") {
            guard let session = onStartRecording?(event.title, nil) else { return }
            session.applyCalendarEvent(event)
            addRecordingTab(session: session)
            openMeetingLink(for: event)
        } else {
            pendingRecordingName = event.title
            pendingCalendarEvent = event
            showConsentDialog = true
        }
    }

    private func openMeetingLink(for event: CalendarEvent) {
        guard let link = event.meetLink, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    func confirmRecording() {
        showConsentDialog = false
        guard let name = pendingRecordingName else { return }
        let url = pendingSourceURL
        let detectedMeeting = pendingDetectedMeeting
        let calendarEvent = pendingCalendarEvent
        pendingRecordingName = nil
        pendingSourceURL = nil
        pendingDetectedMeeting = nil
        pendingCalendarEvent = nil
        guard let session = onStartRecording?(name, detectedMeeting) else { return }
        if let calendarEvent = calendarEvent {
            session.applyCalendarEvent(calendarEvent)
        }
        if let url = url {
            session.transcript.notes = "Source: \(url)\n\n"
        }
        addRecordingTab(session: session)
        if let calendarEvent = calendarEvent {
            openMeetingLink(for: calendarEvent)
        }
    }

    func cancelRecording() {
        showConsentDialog = false
        pendingRecordingName = nil
        pendingSourceURL = nil
        pendingDetectedMeeting = nil
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

    private func generatedWikiArchiveCandidates() -> [URL] {
        var candidates = [saveDirectory]
        if let containerArchive = MeetingTranscriptSettings.appContainerArchiveIfPresent(),
           containerArchive.standardizedFileURL.path != saveDirectory.standardizedFileURL.path {
            candidates.append(containerArchive)
        }
        return candidates
    }

    private static func makeGeneratedWikiFolders(in archiveRoot: URL) -> [GeneratedWikiSidebarFolder] {
        let root = GeneratedWikiPaths.root(in: archiveRoot)
        let specs: [(slug: String, title: String, icon: String)] = [
            ("meetings", "Meeting Overviews", "rectangle.stack.badge.person.crop"),
            ("people", "People", "person.2"),
            ("companies", "Companies", "building.2"),
            ("concepts", "Concepts", "lightbulb")
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
    @State private var isApplyingDossier: Bool = false
    @AppStorage("agentBackend") private var qaAgentBackendStorage: String = "claude:\(ClaudeAPIModel.sonnet.rawValue)"
    @State private var showCommandKSearch: Bool = false
    @State private var showQAMentionSheet: Bool = false
    @State private var qaAttachments: [QAAttachment] = []

    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 0) {
            if state.showSidebar {
                MeetingSidebarView(state: state)
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading))

                // Draggable divider
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
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
                    if let tab = state.indexTabs.first(where: { $0.id == id }) {
                        NavTabContentView(tab: tab, state: state)
                    } else {
                        Text("Tab not found")
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))

            if state.showModelsSidebar {
                // Draggable divider on the panel's leading edge.
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
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
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            if state.showSidebar { state.loadHistory() }
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
        .sheet(item: $wikiGenerationRun) { run in
            WikiGenerationConsoleSheet(
                run: run,
                onCancel: {
                    wikiGenerationTask?.cancel()
                    run.fail("Cancelled")
                    state.isGeneratingMeetingWiki = false
                    wikiGenerationTask = nil
                },
                onOpenOverview: {
                    if let url = run.result?.overviewURL {
                        state.openGeneratedWikiPage(url)
                        wikiGenerationRun = nil
                    }
                },
                onClose: {
                    guard !run.isRunning else { return }
                    wikiGenerationRun = nil
                }
            )
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

    private func runMeetingWikiGeneration(fileURL: URL) {
        guard !state.isGeneratingMeetingWiki else { return }
        guard let runner = state.onGenerateMeetingWiki else {
            let run = WikiGenerationRun(meetingURL: fileURL, archiveRoot: state.saveDirectory)
            run.fail("2nd Brain generation is not wired up.")
            wikiGenerationRun = run
            return
        }

        state.isGeneratingMeetingWiki = true
        state.pendingDossierApply = nil

        let run = WikiGenerationRun(meetingURL: fileURL, archiveRoot: state.saveDirectory)
        wikiGenerationRun = run

        wikiGenerationTask = Task { @MainActor in
            do {
                let result = try await runner(fileURL) { progress in
                    run.handle(progress)
                }

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

    private func runWikiBatchGeneration(limit: Int = 50) {
        guard !state.isGeneratingMeetingWiki else { return }
        guard let runner = state.onGenerateMeetingWiki else {
            let run = WikiGenerationRun(batchTitle: "Next 2nd Brain batch", archiveRoot: state.saveDirectory, sourceCount: 0, modelCallTotal: 0)
            run.fail("2nd Brain generation is not wired up.")
            wikiGenerationRun = run
            return
        }

        state.openSecondBrain()
        let sourceURLs = Self.pendingSecondBrainSourceURLs(in: state.saveDirectory, limit: limit)
        let run = WikiGenerationRun(
            batchTitle: sourceURLs.isEmpty ? "2nd Brain is up to date" : "Next \(sourceURLs.count) sources",
            archiveRoot: state.saveDirectory,
            sourceCount: max(1, sourceURLs.count),
            modelCallTotal: max(0, sourceURLs.count * 2 + 1)
        )
        wikiGenerationRun = run

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

            do {
                for (offset, sourceURL) in sourceURLs.enumerated() {
                    try Task.checkCancellation()
                    run.beginSource(sourceURL, index: offset + 1, total: sourceURLs.count)
                    do {
                        let result = try await runner(sourceURL) { progress in
                            run.handle(progress)
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
                    }
                }

                try Task.checkCancellation()
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
                    .foregroundColor(state.showSidebar ? .orange : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .help(state.showSidebar ? "Hide sidebar" : "Show sidebar")

            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.7))
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
                    .foregroundColor(state.showModelsSidebar ? .orange : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .help(state.showModelsSidebar ? "Hide models" : "Show models")
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
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
        var archiveRoots = [saveDir]
        if let containerArchive = MeetingTranscriptSettings.appContainerArchiveIfPresent(),
           containerArchive.standardizedFileURL.path != saveDir.standardizedFileURL.path {
            archiveRoots.append(containerArchive)
        }
        return archiveRoots
            .map { generatedBrainPageCount(at: GeneratedWikiPaths.root(in: $0)) }
            .max() ?? 0
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
                        Task { await loadTodayEvents() }
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
                            Task { await loadTodayEvents() }
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

    private func loadTodayEvents() async {
        guard GoogleCalendarService.shared.isSignedIn else {
            todayEvents = []
            todayEventsError = nil
            todayEventsLoaded = false
            return
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
                        let displayQuestion = """
                        Lint my local 2nd Brain. Look for likely duplicate entities, stale or contradictory claims, missing backlinks, orphan pages, unsupported claims without evidence, missing aliases, and important entities/concepts that should have pages. Return a concise prioritized report with source page paths.
                        """
                        state.pendingScopedQAPrompt = ScopedQAPrompt(
                            displayQuestion: displayQuestion,
                            agentQuestion: """
                            __2ND_BRAIN_LINT_ONLY__
                            \(displayQuestion)
                            """
                        )
                    },
                    onOpenPage: { url in
                        if let content = state.loadGeneratedWikiPageContent(url) {
                            tab.navigate(to: content)
                        }
                    },
                    onOpenPageInNewTab: { url in
                        state.openGeneratedWikiPage(url)
                    }
                )
            case .generatedWikiPage(let page):
                GeneratedWikiPageView(
                    page: page,
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
    }
}

private struct WikiGenerationConsoleSheet: View {
    @ObservedObject var run: WikiGenerationRun
    let onCancel: () -> Void
    let onOpenOverview: () -> Void
    let onClose: () -> Void
    @State private var showPrompt: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                leftRail
                    .frame(width: 300)
                Divider()
                detailPane
            }
        }
        .frame(width: 980, height: 720)
        .interactiveDismissDisabled(run.isRunning)
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
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    Text(tokenCounterText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
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

            terminalView

            if let error = run.errorMessage {
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

    private var openOverviewButtonTitle: String {
        run.isBatch ? "Open first overview" : "Open meeting overview"
    }

    private var activeProcessingText: String {
        if run.isBatch {
            let index = max(1, run.currentSourceIndex)
            return "Processing source \(index) of \(run.totalSourceCount): \(run.currentSourceTitle)"
        }
        return "Processing \(run.currentSourceTitle)"
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

    private func functionStatusText(_ selected: WikiGenerationFunctionRun) -> String {
        if selected.isFinished {
            return "\(selected.inputTokens) in / \(selected.outputTokens) out"
        }
        if selected.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Waiting for first output token"
        }
        return "Streaming local model output"
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
            Text(function.isFinished ? "\(function.inputTokens) in / \(function.outputTokens) out" : function.output.isEmpty ? "waiting..." : "streaming...")
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
    var onOpenWikilink: (String) -> Void
    var onOpenWikilinkInNewTab: (String) -> Void
    var onOpenSourceMeeting: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let source = page.sourceMeetingPath, !source.isEmpty {
                    sourceCallout(source)
                }
                bodyRendered
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(page.title)
                .font(.system(size: 24, weight: .semibold))
            HStack(spacing: 12) {
                Label(page.type.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: page.type == "meeting_overview" ? "rectangle.stack.badge.person.crop" : "link")
                Text(page.url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
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
        let blocks = MarkdownBlockParser.parse(page.body)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(for: level))
                .padding(.top, level <= 2 ? 8 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        inlineText(item)
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
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

    private func inlineText(_ text: String) -> Text {
        let transformed = Self.transformWikilinks(text)
        if let attributed = try? AttributedString(
            markdown: transformed,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
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
}

private struct SecondBrainDashboardView: View {
    @ObservedObject var state: MeetingWindowState
    var onBuildNextBatch: () -> Void
    var onLint: () -> Void
    var onOpenPage: (URL) -> Void
    var onOpenPageInNewTab: (URL) -> Void

    @State private var graph = SecondBrainGraph(nodes: [], edges: [])

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
}

private struct SecondBrainGraphView: View {
    let graph: SecondBrainGraph
    var onOpenPage: (URL) -> Void
    var onOpenPageInNewTab: (URL) -> Void

    var body: some View {
        GeometryReader { proxy in
            let positions = graph.positions(in: proxy.size)
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
                }

                ForEach(graph.edges) { edge in
                    if let start = positions[edge.sourceID], let end = positions[edge.targetID] {
                        Path { path in
                            path.move(to: start)
                            path.addLine(to: end)
                        }
                        .stroke(Color.secondary.opacity(0.18), lineWidth: edge.weight > 1 ? 1.4 : 0.8)
                    }
                }

                ForEach(graph.nodes) { node in
                    let point = positions[node.id] ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    SecondBrainGraphNodeView(node: node)
                        .position(point)
                        .onTapGesture { onOpenPageInNewTab(node.url) }
                        .contextMenu {
                            Button("Open") { onOpenPage(node.url) }
                            Button("Open in New Tab") { onOpenPageInNewTab(node.url) }
                            Button("Show in Finder") {
                                NSWorkspace.shared.selectFile(
                                    node.url.path,
                                    inFileViewerRootedAtPath: node.url.deletingLastPathComponent().path
                                )
                            }
                        }
                }
            }
        }
    }
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
        let hubs = nodes.filter(\.isHub)
        let others = nodes.filter { !$0.isHub }
        var out: [String: CGPoint] = [:]

        if hubs.isEmpty {
            place(nodes: Array(nodes.prefix(1)), radius: 0, center: center, phase: 0, into: &out)
            place(nodes: Array(nodes.dropFirst()), radius: min(width, height) * 0.38, center: center, phase: -CGFloat.pi / 2, into: &out)
        } else {
            place(nodes: hubs, radius: min(width, height) * 0.18, center: center, phase: -CGFloat.pi / 2, into: &out)
            place(nodes: others, radius: min(width, height) * 0.39, center: center, phase: -CGFloat.pi / 2, into: &out)
        }
        return out
    }

    private func place(nodes: [Node], radius: CGFloat, center: CGPoint, phase: CGFloat, into out: inout [String: CGPoint]) {
        guard !nodes.isEmpty else { return }
        if nodes.count == 1 || radius == 0 {
            out[nodes[0].id] = center
            return
        }
        for (idx, node) in nodes.enumerated() {
            let angle = phase + CGFloat(idx) / CGFloat(nodes.count) * CGFloat.pi * 2
            out[node.id] = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
        }
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
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

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
                                        .foregroundColor(isOpen ? .orange : (entry.isGranola ? .green.opacity(0.7) : .secondary))
                                    Text(entry.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(isOpen ? .orange : .primary)
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
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
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
        newWikiRow
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
                Text("(\(folder.items.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
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
                Spacer()
            }
            .padding(.leading, 34)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
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
                Text("(\(group.entries.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
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
                Spacer()
            }
            .padding(.leading, 34)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
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
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private var newWikiRow: some View {
        Button(action: { state.showNewWikiSheet = true }) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("New 2nd Brain…")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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
                Text("(\(count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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
