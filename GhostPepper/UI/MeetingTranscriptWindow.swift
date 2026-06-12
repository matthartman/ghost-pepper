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
    var onAskQuestion: ((_ question: String, _ history: [QAHistoryTurn]) -> AsyncThrowingStream<QAEvent, Error>)?
    var onMakeIndexBuilder: ((IndexKind) -> IndexBuilder?)?
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
        state.onAskQuestion = onAskQuestion
        state.onMakeIndexBuilder = onMakeIndexBuilder
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

    @MainActor
    var title: String {
        switch self {
        case .indexEntry(_, _, let entry): return entry.canonicalName
        case .meeting(let tab): return tab.transcript.meetingName
        case .indexList(let kind): return kind.displayName
        }
    }

    var iconSystemName: String {
        switch self {
        case .indexEntry(let kind, _, _): return kind.iconSystemName
        case .meeting: return "doc.text"
        case .indexList(let kind): return kind.iconSystemName
        }
    }
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
    var onMakeIndexBuilder: ((IndexKind) -> IndexBuilder?)?

    @Published var indexItems: [IndexKind: [IndexHistoryItem]] = [:]
    @Published var indexTabs: [OpenIndexTab] = []
    @Published var showBuildIndexSheet: Bool = false
    @Published var pendingBuildIndexKind: IndexKind = .people

    /// Right-side Models panel toggle.
    @Published var showModelsSidebar: Bool = false

    /// Set by deep views (e.g. per-entry "↻" button) to ask MeetingRootView
    /// to drop a prompt into the bottom Q&A bar and fire it. The root view
    /// consumes this on `.onChange` and clears it back to nil.
    @Published var pendingQAPrompt: String? = nil

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
    @State private var isApplyingDossier: Bool = false
    @State private var copiedQATurnID: UUID? = nil
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
            Button(action: { state.startNewNote() }) { EmptyView() }
                .keyboardShortcut("n", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        )
        .sheet(isPresented: $showCommandKSearch) {
            CommandKSearchSheet(state: state, isPresented: $showCommandKSearch)
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
            if qaIsLoading || !qaTranscript.events.isEmpty {
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
                Picker("", selection: $qaAgentBackendStorage) {
                    Section("Cloud") {
                        ForEach(ClaudeAPIModel.allCases) { model in
                            Text(model.shortDisplayName).tag("claude:\(model.rawValue)")
                        }
                    }
                    Section("Local") {
                        ForEach(LocalCleanupModelKind.allCases) { kind in
                            Text(localPickerLabel(for: kind)).tag("local:\(kind.rawValue)")
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 160)
                .help("Model used for this conversation. Local models run on-device — slower, free, and best on 8B+ for tool use.")

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
                HStack(alignment: .top, spacing: 6) {
                    QAAnswerView(source: turn.answer, onLink: handleAnswerLink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { copyQAAnswer(turn) }) {
                        Image(systemName: copiedQATurnID == turn.id ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(copiedQATurnID == turn.id ? .green : .secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(copiedQATurnID == turn.id ? "Copied" : "Copy full answer")
                    .disabled(turn.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let usage = turn.usage {
                    Text(usageFooterText(usage))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func copyQAAnswer(_ turn: QATurn) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(turn.answer, forType: .string)
        copiedQATurnID = turn.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedQATurnID == turn.id {
                copiedQATurnID = nil
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
        if u.isLocal { return "free" }
        return String(format: "~$%.4f", u.estimatedCostUSD)
    }

    private var qaPlaceholder: String {
        "Run agent across meeting data..."
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
        case "person":
            // path looks like "people/<slug>" (kind subdirectory + slug)
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let kind = IndexKind(rawValue: parts[0]) else { return .discarded }
            state.openIndexEntry(kind: kind, slug: parts[1])
            return .handled
        default:
            return .discarded
        }
    }

    private func localPickerLabel(for kind: LocalCleanupModelKind) -> String {
        "\(kind.qaPickerDisplayName) local"
    }

    private func formatTraceLine(_ event: QAEvent) -> String {
        switch event {
        case .status(let s):
            return "[status]    \(s)"
        case .toolCall(_, let name, let summary, _):
            return "[\(name)]    \(summary)"
        case .toolResult(_, let summary, _, let isError):
            return isError ? "[result]    ERROR: \(summary)" : "[result]    \(summary)"
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
        case "qmd_search", "grep": return "Searching: \(summary)"
        case "read_file": return "Reading \(summary)"
        case "list_dir": return "Listing \(summary)"
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
            appendErrorToActiveTurn("apply failed: Claude API key not configured")
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

    private func askAcrossMeetings() {
        let userQuestion = qaQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userQuestion.isEmpty, !qaIsLoading else { return }
        qaIsLoading = true
        qaStatusLine = ""
        qaTranscript.clear()
        qaTraceExpanded = false

        // If the user attached context refs via @-mention, prefix them so the
        // agent reads those files first.
        let question: String
        if !qaAttachments.isEmpty {
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
                $0.answer = "Could not answer — open Settings → Meeting Transcript → Cross-Meeting Q&A to configure."
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
    @State private var showGranolaImport = false
    @State private var showReaderCapture = false
    @State private var todayEvents: [CalendarEvent] = []
    @State private var todayEventsLoaded = false
    @State private var todayEventsError: String?
    @State private var whitelistEmail: String = ""
    @State private var granolaPendingCount: Int? = nil
    @State private var peopleIndexStatus: PeopleIndexStatus? = nil

    enum PeopleIndexStatus: Equatable {
        case notBuilt(meetingCount: Int)
        case upToDate(entryCount: Int)
        case pending(newCount: Int, entryCount: Int)
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

                if GranolaImporter.isCacheAvailable {
                    granolaSyncRow
                        .padding(.top, GoogleCalendarService.shared.isSignedIn ? 8 : 0)
                }

                peopleIndexRow
                    .padding(.top, 4)

                todayCalendarSection
                    .padding(.top, (GoogleCalendarService.shared.isSignedIn && !GranolaImporter.isCacheAvailable) ? 8 : 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showGranolaImport, onDismiss: { refreshGranolaPendingCount() }) {
            GranolaImportView(importer: granolaImporter, state: state)
        }
        .task {
            await loadTodayEvents()
            refreshGranolaPendingCount()
            refreshPeopleIndexStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await loadTodayEvents() }
            refreshGranolaPendingCount()
            refreshPeopleIndexStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingRecordingStopped)) { _ in
            GoogleCalendarService.shared.invalidateTodayCache()
            Task { await loadTodayEvents() }
            refreshPeopleIndexStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .indexUpdated)) { _ in
            refreshPeopleIndexStatus()
        }
    }

    @ViewBuilder
    private var peopleIndexRow: some View {
        HStack(spacing: 8) {
            Image(systemName: IndexKind.people.iconSystemName)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            switch peopleIndexStatus {
            case .pending(let newCount, _):
                Button {
                    state.presentBuildIndexSheet(for: .people)
                } label: {
                    HStack(spacing: 6) {
                        Text("Sync \(newCount) new into People index")
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
            case .upToDate:
                Text("People index up to date")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Button {
                    state.presentBuildIndexSheet(for: .people)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Re-sync People index")
            case .notBuilt(let meetings) where meetings > 0:
                Button {
                    state.presentBuildIndexSheet(for: .people)
                } label: {
                    HStack(spacing: 6) {
                        Text("Build People index from \(meetings) meetings")
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
            case .notBuilt, .none:
                EmptyView()
            }
            Spacer()
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 24)
    }

    private func refreshPeopleIndexStatus() {
        let saveDir = MeetingTranscriptSettings.effectiveSaveDirectory()
        Task.detached(priority: .background) {
            let allMeetings = IndexBuilder.allMeetingPaths(in: saveDir)
            let entryCount = IndexBuilder.countExistingEntries(in: saveDir, kind: .people)
            let covered = IndexBuilder.coveredMeetings(in: saveDir, kind: .people)
            let unprocessed = allMeetings.filter { !covered.contains($0) }.count
            let status: PeopleIndexStatus
            if entryCount == 0 {
                status = .notBuilt(meetingCount: allMeetings.count)
            } else if unprocessed == 0 {
                status = .upToDate(entryCount: entryCount)
            } else {
                status = .pending(newCount: unprocessed, entryCount: entryCount)
            }
            await MainActor.run { self.peopleIndexStatus = status }
        }
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
                        Text("Sync Granola")
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
                .help("Open the Granola sync sheet")
            }
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
                        Text("BETA")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange))
                        Spacer()
                    }

                    Divider()

                    Text("Calendar access is invite-only while in beta. Send Matt your email and he'll allow-list you.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

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
        let to = "ghostpepper@factorial.cc"
        let subject = "Whitelist request for Ghost Pepper"
        let body = "Hey Matt, can you white list my email address for ghost pepper calendar integration: \(email)"
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

                    ActiveTabRecordingIndicator(tab: tab)
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

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                            ForEach(TextCleanupManager.cleanupModels, id: \.kind) { model in
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

// MARK: - Content Tab Enum

enum MeetingContentTab: String, CaseIterable {
    case article, notes, transcript, summary
    var label: String {
        switch self {
        case .article: "📰 Article"
        case .notes: "📝 Notes"
        case .transcript: "📜 Transcript"
        case .summary: "✨ Summary"
        }
    }
}

// MARK: - Sidebar

struct MeetingSidebarView: View {
    @ObservedObject var state: MeetingWindowState
    @State private var searchText = ""

    private var filteredGroups: [(date: String, entries: [MeetingHistoryEntry])] {
        guard !searchText.isEmpty else { return state.historyGroups }
        let query = searchText.lowercased()
        return state.historyGroups.compactMap { group in
            let filtered = group.entries.filter { $0.name.lowercased().contains(query) }
            return filtered.isEmpty ? nil : (date: group.date, entries: filtered)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Meetings")
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
                TextField("Search meetings", text: $searchText)
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

                    if filteredGroups.isEmpty {
                        Text(searchText.isEmpty ? "No past meetings" : "No matches")
                            .font(.caption).foregroundColor(.secondary)
                            .padding(.horizontal, 16).padding(.top, 8)
                    }

                    ForEach(filteredGroups, id: \.date) { group in
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

    @ViewBuilder
    private var indexesSection: some View {
        ForEach(IndexKind.allCases) { kind in
            if let items = state.indexItems[kind], !items.isEmpty {
                indexFolderRow(kind: kind, count: items.count)
            }
        }
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
            Text("Index building uses Claude (Anthropic API). Add your API key in Settings → Meeting Transcript → Cross-Meeting Q&A.")
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
