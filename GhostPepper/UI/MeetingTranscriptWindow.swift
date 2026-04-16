import AppKit
import Combine
import SwiftUI

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
    var onRequestTranscriptSweep: (() -> Void)?
    var shouldFloatWhileRecording: () -> Bool = { false }

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
        state.onRequestTranscriptSweep = onRequestTranscriptSweep
        state.onRecordingStateChanged = { [weak self] in
            self?.updateWindowLevel()
        }
        windowState = state

        if let session = session {
            state.addRecordingTab(session: session)
        }

        let view = MeetingRootView(state: state)

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 720, height: 900)
        let windowHeight = screenFrame.height
        let windowWidth: CGFloat = 720

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

@MainActor
final class MeetingWindowState: ObservableObject {
    @Published var tabs: [OpenMeetingTab] = []
    @Published var activeTabID: UUID?
    @Published var showSidebar = false
    @Published var showNewTabView = false
    @Published var historyGroups: [(date: String, entries: [MeetingHistoryEntry])] = []
    @Published var showConsentDialog = false
    var pendingRecordingName: String?
    var pendingSourceURL: String?
    var pendingDetectedMeeting: DetectedMeeting?
    var onRecordingStateChanged: (() -> Void)?

    var onOpenSettings: (() -> Void)?
    var onStartRecording: ((_ name: String, _ detectedMeeting: DetectedMeeting?) -> MeetingSession?)?
    var onStopRecording: ((MeetingSession) -> Void)?
    var onGenerateSummary: ((MeetingTranscript) -> Void)?
    var onRequestTranscriptSweep: (() -> Void)?

    var activeTab: OpenMeetingTab? {
        tabs.first { $0.id == activeTabID }
    }

    var hasActiveRecording: Bool {
        tabs.contains { $0.isRecording }
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
        activeTabID = tab.id
        onRecordingStateChanged?()
    }

    func openFile(_ url: URL) {
        // Already open? Switch to it.
        if let existing = tabs.first(where: { $0.fileURL == url }) {
            activeTabID = existing.id
            return
        }

        // Parse and open in new tab
        do {
            let transcript = try MeetingMarkdownWriter.parse(from: url)
            let tab = OpenMeetingTab(transcript: transcript, fileURL: url)
            tabs.append(tab)
            activeTabID = tab.id
            onRecordingStateChanged?()
        } catch {
            print("MeetingWindowState: failed to load \(url.lastPathComponent): \(error)")
        }
    }

    func closeTab(_ tabID: UUID) {
        // Stop recording if this is a live tab
        if let tab = tabs.first(where: { $0.id == tabID }), let session = tab.session {
            onStopRecording?(session)
        }

        tabs.removeAll { $0.id == tabID }
        onRecordingStateChanged?()

        // Switch to adjacent tab
        if activeTabID == tabID {
            activeTabID = tabs.last?.id
        }
    }

    func startNewNote() {
        showNewTabView = false
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let name = "Quick Note — \(formatter.string(from: Date()))"

        if UserDefaults.standard.bool(forKey: "skipConsentDialog") {
            guard let session = onStartRecording?(name, nil) else { return }
            addRecordingTab(session: session)
        } else {
            pendingRecordingName = name
            showConsentDialog = true
        }
    }

    func confirmRecording() {
        showConsentDialog = false
        guard let name = pendingRecordingName else { return }
        let url = pendingSourceURL
        let detectedMeeting = pendingDetectedMeeting
        pendingRecordingName = nil
        pendingSourceURL = nil
        pendingDetectedMeeting = nil
        guard let session = onStartRecording?(name, detectedMeeting) else { return }
        if let url = url {
            session.transcript.notes = "Source: \(url)\n\n"
        }
        addRecordingTab(session: session)
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
        // Route through MeetingMarkdownWriter.write so the sweep/open-tab guard
        // applies: if the file was swept while this tab was open, the in-memory
        // segments won't clobber the on-disk expiry marker.
        _ = try? MeetingMarkdownWriter.write(
            transcript: tab.transcript,
            to: url.deletingLastPathComponent(),
            existingFileURL: url
        )
    }
}

// MARK: - Root View

struct MeetingRootView: View {
    @ObservedObject var state: MeetingWindowState

    var body: some View {
        HStack(spacing: 0) {
            if state.showSidebar {
                MeetingSidebarView(state: state)
                    .transition(.move(edge: .leading))
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }

            VStack(spacing: 0) {
                // File tabs (always show — includes "+" tab)
                fileTabBar

                // Active tab content or new tab view
                if state.showNewTabView || state.tabs.isEmpty {
                    newTabView
                } else if let tab = state.activeTab {
                    MeetingTabContentView(tab: tab, state: state)
                } else {
                    newTabView
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 500, minHeight: 400)
        .animation(.easeInOut(duration: 0.2), value: state.showSidebar)
        .onAppear { state.loadHistory() }
        .onChange(of: state.showSidebar) { _, visible in
            if visible { state.loadHistory() }
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            if state.showSidebar { state.loadHistory() }
        }
        .sheet(isPresented: $state.showConsentDialog) {
            ConsentDialogView(state: state)
        }
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
                    ForEach(state.tabs) { tab in
                        FileTabView(tab: tab, isActive: state.activeTabID == tab.id && !state.showNewTabView) {
                            state.saveActiveTab()
                            state.showNewTabView = false
                            state.activeTabID = tab.id
                        } onClose: {
                            state.closeTab(tab.id)
                        }
                    }

                    // "+" tab
                    Button(action: { state.showNewTabView = true }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(state.showNewTabView ? .orange : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(state.showNewTabView ? Color(nsColor: .textBackgroundColor) : Color.clear)
                            .overlay(alignment: .bottom) {
                                if state.showNewTabView {
                                    Rectangle().fill(Color.orange).frame(height: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
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

    private var newTabView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.4))
            Text("Open a meeting from the sidebar or start a new one")
                .font(.callout)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button("New Quick Note") {
                    state.startNewNote()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                if GranolaImporter.isCacheAvailable {
                    Button("Import from Granola") {
                        showGranolaImport = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showGranolaImport) {
            GranolaImportView(importer: granolaImporter, state: state)
        }
    }
}

// MARK: - Content View for a Single Tab

// MARK: - File Tab View (observes individual tab)

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
    @FocusState private var searchFocused: Bool
    @AppStorage("transcriptExpirationDays") private var transcriptExpirationDays: Int = 0
    @AppStorage("transcriptAutoDeleteAllMeetings") private var transcriptAutoDeleteAllMeetings: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title + date
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Untitled", text: $tab.transcript.meetingName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.primary)
                            .onSubmit { state.renameActiveTab() }

                        Text(dateSubtitle)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .padding(.bottom, tab.transcript.attendees.isEmpty ? 20 : 8)

                        if !tab.transcript.attendees.isEmpty {
                            Text("**Attendees:** \(tab.transcript.attendees.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ActiveTabRecordingIndicator(tab: tab)
                        .padding(.top, 4)
                }

                if transcriptExpirationDays > 0 && !transcriptAutoDeleteAllMeetings {
                    autoDeleteToggle
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

    private var contentTabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(MeetingContentTab.allCases, id: \.self) { ct in
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
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.caption)
            TextField("Search...", text: $searchText)
                .textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
            if !searchText.isEmpty {
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
        case .notes: notesContent
        case .transcript: transcriptContent
        case .summary: summaryContent
        }
    }

    private static let notesFont = Font.custom("Georgia", size: 15)

    private var notesContent: some View {
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

    private var filteredSegments: [TranscriptSegment] {
        guard !searchText.isEmpty else { return tab.transcript.segments }
        return tab.transcript.segments.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let expiredDate = tab.transcript.transcriptExpiredDate {
                transcriptExpiredBanner(expiredDate: expiredDate)
            } else if tab.transcript.segments.isEmpty {
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

    private var autoDeleteToggle: some View {
        let days = transcriptExpirationDays
        let label = days == 1 ? "1 day" : "\(days) days"
        return Toggle(isOn: Binding(
            get: { tab.transcript.autoDeleteFlagged },
            set: { newValue in
                tab.transcript.autoDeleteFlagged = newValue
                state.saveActiveTab()
                // Fire a sweep immediately so users see the effect without waiting for
                // the 6h timer or a settings toggle.
                if newValue {
                    state.onRequestTranscriptSweep?()
                }
            }
        )) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.xmark")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text("Auto-delete transcript after \(label)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.bottom, 8)
    }

    private func transcriptExpiredBanner(expiredDate: Date) -> some View {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let dateString = formatter.string(from: expiredDate)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.xmark")
                .foregroundColor(.secondary)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 3) {
                Text("Transcript auto-deleted")
                    .font(.callout.weight(.medium))
                Text("Removed on \(dateString) per your privacy settings. The summary and notes above are preserved.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .padding(.vertical, 4)
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
            // Regenerate / Generate button
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
            }

            // Editable summary (same style as notes)
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
    case notes, transcript, summary
    var label: String {
        switch self {
        case .notes: "📝 Notes"
        case .transcript: "📜 Transcript"
        case .summary: "✨ Summary"
        }
    }
}

// MARK: - Sidebar

struct MeetingSidebarView: View {
    @ObservedObject var state: MeetingWindowState
    @StateObject private var granolaImporter = GranolaImporter()
    @State private var showGranolaSync = false
    @State private var searchText = ""

    private var showGranolaSyncButton: Bool {
        GranolaImporter.isCacheAvailable || UserDefaults.standard.string(forKey: "granolaApiKey") != nil
    }

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

                if showGranolaSyncButton {
                    Button(action: { showGranolaSync = true }) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Sync with Granola")
                }

                Button(action: { state.startNewNote() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("New quick note")

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
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 10))
                                        .foregroundColor(isOpen ? .orange : .secondary)
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
        .frame(width: 200)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showGranolaSync) {
            GranolaImportView(importer: granolaImporter, state: state)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(segment.formattedTimestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)
            Text(segment.speaker.displayName)
                .font(.caption2.weight(.semibold)).foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(speakerColor))
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
