import AppKit
import SwiftUI

final class HistoryWindowController: NSObject, NSWindowDelegate {
    private var window: NSPanel?

    func show(historyStore: HistoryStore, appState: AppState) {
        let rootView = HistoryWindowView(historyStore: historyStore, appState: appState)

        if let window {
            if let hostingController = window.contentViewController as? NSHostingController<HistoryWindowView> {
                hostingController.rootView = rootView
            } else {
                window.contentViewController = NSHostingController(rootView: rootView)
            }

            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ghost Pepper History"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.minSize = NSSize(width: 720, height: 540)
        window.contentViewController = NSHostingController(rootView: rootView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private struct HistoryWindowView: View {
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var appState: AppState

    @State private var searchText = ""
    @State private var selectedEntryID: UUID?
    @State private var entryPendingDeletion: HistoryEntry?
    @FocusState private var focusedField: FocusField?

    private enum FocusField {
        case search
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private var displayedEntries: [HistoryEntry] {
        guard appState.historyEnabled else {
            return []
        }

        let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSearchText.isEmpty else {
            return historyStore.entries
        }

        return historyStore.entries.filter { entry in
            entry.rawTranscription.localizedCaseInsensitiveContains(normalizedSearchText)
                || (entry.cleanedText?.localizedCaseInsensitiveContains(normalizedSearchText) ?? false)
        }
    }

    private var selectedEntry: HistoryEntry? {
        guard let selectedEntryID else {
            return displayedEntries.first
        }

        return displayedEntries.first(where: { $0.id == selectedEntryID })
    }

    var body: some View {
        HSplitView {
            sidebar
            detailPane
        }
        .frame(minWidth: 720, minHeight: 540)
        .background(
            HistoryKeyboardShortcuts(
                onCopy: { copyPreferredText(from: selectedEntry) },
                onDelete: { requestDelete(for: selectedEntry) },
                onFocusSearch: { focusedField = .search }
            )
        )
        .onAppear {
            normalizeSelection()
        }
        .onChange(of: appState.historyEnabled) { _, _ in
            normalizeSelection()
        }
        .onChange(of: historyStore.entries.map(\.id)) { _, _ in
            normalizeSelection()
        }
        .onChange(of: searchText) { _, _ in
            normalizeSelection()
        }
        .alert(
            "Delete History Entry?",
            isPresented: Binding(
                get: { entryPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        entryPendingDeletion = nil
                    }
                }
            ),
            presenting: entryPendingDeletion
        ) { entry in
            Button("Delete Entry", role: .destructive) {
                historyStore.deleteEntry(id: entry.id)
                entryPendingDeletion = nil
                normalizeSelection()
            }
            Button("Cancel", role: .cancel) {
                entryPendingDeletion = nil
            }
        } message: { entry in
            Text("This removes the saved transcript and any recording attached to "\(previewText(for: entry))".")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search history", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .search)
                    .disabled(!appState.historyEnabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            List(selection: $selectedEntryID) {
                ForEach(displayedEntries) { entry in
                    HistorySidebarRow(
                        preview: previewText(for: entry),
                        relativeTimestamp: relativeTimestamp(for: entry.completedAt),
                        durationText: durationLabel(for: entry.durationSeconds)
                    )
                    .tag(Optional(entry.id))
                }
            }
            .listStyle(.sidebar)
            .animation(.default, value: displayedEntries.map(\.id))
            .overlay {
                if !appState.historyEnabled {
                    HistoryDisabledState(onEnable: { appState.historyEnabled = true })
                        .padding(24)
                } else if displayedEntries.isEmpty {
                    HistoryEmptyState(
                        title: "No history yet",
                        subtitle: emptyStateSubtitle
                    )
                    .padding(24)
                }
            }
        }
        .frame(minWidth: 260, idealWidth: 280, maxWidth: 320, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selectedEntry, appState.historyEnabled {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHeader(for: selectedEntry)
                    HistoryTextSection(
                        title: "Original Transcription",
                        text: selectedEntry.rawTranscription,
                        copyButtonTitle: "Copy",
                        copyAccessibilityLabel: "Copy original transcription",
                        onCopy: { copyToPasteboard(selectedEntry.rawTranscription) },
                        pasteButtonTitle: "Paste",
                        pasteAccessibilityLabel: "Paste original transcription into focused app",
                        onPaste: { pasteIntoFocusedApp(selectedEntry.rawTranscription) }
                    )

                    if let cleanedText = selectedEntry.cleanedText, cleanedText != selectedEntry.rawTranscription {
                        HistoryTextSection(
                            title: "Cleaned Text",
                            text: cleanedText,
                            copyButtonTitle: "Copy",
                            copyAccessibilityLabel: "Copy cleaned transcription",
                            onCopy: { copyToPasteboard(cleanedText) },
                            pasteButtonTitle: "Paste",
                            pasteAccessibilityLabel: "Paste cleaned transcription into focused app",
                            onPaste: { pasteIntoFocusedApp(cleanedText) }
                        )
                    }

                    HistoryMetadataCard(
                        speechModelName: speechModelName(for: selectedEntry),
                        cleanupModelName: selectedEntry.cleanupModelName,
                        cleanupBackend: selectedEntry.cleanupBackend,
                        cleanupAttempted: selectedEntry.cleanupAttempted,
                        createdAt: selectedEntry.createdAt,
                        completedAt: selectedEntry.completedAt,
                        durationText: durationLabel(for: selectedEntry.durationSeconds),
                        audioSaved: selectedEntry.audioFileURL != nil
                    )

                    HStack {
                        Spacer()

                        Button("Delete Entry", role: .destructive) {
                            requestDelete(for: selectedEntry)
                        }
                        .keyboardShortcut(.delete, modifiers: [])
                        .accessibilityLabel("Delete selected history entry")
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if !appState.historyEnabled {
            HistoryDisabledState(onEnable: { appState.historyEnabled = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
        } else if appState.historyEnabled, displayedEntries.isEmpty {
            HistoryEmptyState(
                title: "No history yet",
                subtitle: emptyStateSubtitle
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else {
            HistoryEmptyState(
                title: "Select an entry",
                subtitle: "Choose a transcription from the list."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        }
    }

    private func detailHeader(for entry: HistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.absoluteFormatter.string(from: entry.completedAt))
                    .font(.title3.weight(.semibold))

                HStack(spacing: 8) {
                    Label(durationLabel(for: entry.durationSeconds), systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(relativeTimestamp(for: entry.completedAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Copy All") {
                let text = preferredFullText(for: entry)
                copyToPasteboard(text)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Copy full transcription text")
        }
    }

    private var emptyStateSubtitle: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Try a different search term. Filters match both the original transcription and the cleaned text."
        }

        return "Your transcriptions will appear here after you finish dictating."
    }

    private func normalizeSelection() {
        guard appState.historyEnabled else {
            selectedEntryID = nil
            return
        }

        if let selectedEntryID, displayedEntries.contains(where: { $0.id == selectedEntryID }) {
            return
        }

        selectedEntryID = displayedEntries.first?.id
    }

    private func requestDelete(for entry: HistoryEntry?) {
        guard let entry else {
            return
        }

        entryPendingDeletion = entry
    }

    private func copyPreferredText(from entry: HistoryEntry?) {
        guard let entry else {
            return
        }

        copyToPasteboard(entry.cleanedText ?? entry.rawTranscription)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func pasteIntoFocusedApp(_ text: String) {
        appState.textPaster.paste(text: text)
    }

    private func preferredFullText(for entry: HistoryEntry) -> String {
        if let cleanedText = entry.cleanedText, cleanedText != entry.rawTranscription {
            return cleanedText + "\n\n---\n\n" + entry.rawTranscription
        }

        return entry.rawTranscription
    }

    private func previewText(for entry: HistoryEntry) -> String {
        let sourceText = (entry.cleanedText?.isEmpty == false ? entry.cleanedText : nil) ?? entry.rawTranscription
        let singleLineText = sourceText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard singleLineText.count > 60 else {
            return singleLineText
        }

        return String(singleLineText.prefix(60)) + "..."
    }

    private func relativeTimestamp(for date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func speechModelName(for entry: HistoryEntry) -> String {
        SpeechModelCatalog.model(named: entry.speechModelID)?.statusName ?? entry.speechModelID
    }

    private func durationLabel(for duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }

        return "\(seconds)s"
    }
}

private struct HistorySidebarRow: View {
    let preview: String
    let relativeTimestamp: String
    let durationText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preview.isEmpty ? "Untitled transcription" : preview)
                .font(.body)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(relativeTimestamp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(durationText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor))
                    )
            }
        }
        .padding(.vertical, 4)
    }
}

private struct HistoryTextSection: View {
    let title: String
    let text: String
    let copyButtonTitle: String
    let copyAccessibilityLabel: String
    let onCopy: () -> Void
    let pasteButtonTitle: String
    let pasteAccessibilityLabel: String
    let onPaste: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)

                Spacer()

                Button(pasteButtonTitle, action: onPaste)
                    .buttonStyle(.bordered)
                    .accessibilityLabel(pasteAccessibilityLabel)

                Button(copyButtonTitle, action: onCopy)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(copyAccessibilityLabel)
            }

            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct HistoryMetadataCard: View {
    let speechModelName: String
    let cleanupModelName: String?
    let cleanupBackend: String?
    let cleanupAttempted: Bool
    let createdAt: Date
    let completedAt: Date
    let durationText: String
    let audioSaved: Bool

    @State private var isExpanded = false

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                metadataRow(label: "Speech model", value: speechModelName)
                metadataRow(label: "Cleanup model", value: cleanupModelName ?? (cleanupAttempted ? "Unavailable" : "Not used"))
                metadataRow(label: "Cleanup backend", value: cleanupBackend ?? (cleanupAttempted ? "Unavailable" : "Not used"))
                metadataRow(label: "Recording started", value: Self.formatter.string(from: createdAt))
                metadataRow(label: "Processing finished", value: Self.formatter.string(from: completedAt))
                metadataRow(label: "Duration", value: durationText)
                metadataRow(label: "Saved recording", value: audioSaved ? "Available" : "Not saved")
            }
            .padding(.top, 8)
        } label: {
            Text("Metadata")
                .font(.headline)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

private struct HistoryDisabledState: View {
    let onEnable: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("History is off")
                .font(.title3.weight(.semibold))

            Text("Enable history to save your transcriptions and browse them here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Enable History") {
                onEnable()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HistoryEmptyState: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HistoryKeyboardShortcuts: View {
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onFocusSearch: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button("", action: onCopy)
                .keyboardShortcut("c")
            Button("", action: onDelete)
                .keyboardShortcut(.delete, modifiers: [])
            Button("", action: onFocusSearch)
                .keyboardShortcut("f")
        }
        .frame(width: 0, height: 0)
        .opacity(0.001)
        .accessibilityHidden(true)
    }
}
