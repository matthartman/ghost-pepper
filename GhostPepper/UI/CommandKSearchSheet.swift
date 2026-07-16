import SwiftUI

/// Cmd+K command palette. Live-filters across generated wiki entities, People
/// (index entries), Meetings (recorded / imported markdown), and Notes
/// (quick-note files). ↑/↓ moves the highlight; Enter opens the highlighted
/// result or asks the local wiki when no exact destination is selected.
struct CommandKSearchSheet: View {
    @ObservedObject var state: MeetingWindowState
    @Binding var isPresented: Bool
    /// When provided, selecting a result calls this instead of opening the
    /// item as a tab. Used by the Q&A `@`-mention picker to attach context.
    var onAttach: ((CommandKHaystackEntry) -> Void)? = nil
    var onAskQuestion: ((String) -> Void)? = nil

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var results: CommandKResults = CommandKResults(wiki: [], people: [], meetings: [], notes: [], askQuestion: nil)
    @State private var flatItems: [CommandKItem] = []
    /// Pre-flattened, pre-lowercased haystack snapshotted when the sheet
    /// opens — keeps each keystroke O(N) on raw strings instead of
    /// re-walking dictionaries and re-lowercasing every iteration.
    @State private var haystack: [CommandKHaystackEntry] = []
    @FocusState private var fieldFocused: Bool

    private var clampedIndex: Int {
        guard !flatItems.isEmpty else { return 0 }
        return max(0, min(selectedIndex, flatItems.count - 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsBody
        }
        .frame(width: 620)
        .onAppear {
            state.loadGeneratedWikiFolders()
            fieldFocused = true
            haystack = CommandKHaystackEntry.snapshot(from: state)
            recomputeResults()
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            recomputeResults()
        }
        .onKeyPress(.upArrow) {
            guard !flatItems.isEmpty else { return .ignored }
            selectedIndex = max(0, clampedIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !flatItems.isEmpty else { return .ignored }
            selectedIndex = min(flatItems.count - 1, clampedIndex + 1)
            return .handled
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            TextField(onAttach == nil ? "Search 2nd Brain, people, meetings, notes…" : "Attach context: search 2nd Brain, people, meetings, notes…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($fieldFocused)
                .onSubmit { activateSelected() }
            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            keyHint("↑↓")
            keyHint("⏎")
            Button(action: { isPresented = false }) {
                Text("ESC")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func keyHint(_ glyph: String) -> some View {
        Text(glyph)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .cornerRadius(3)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var resultsBody: some View {
        if results.totalCount == 0 {
            VStack(spacing: 6) {
                Image(systemName: query.isEmpty ? "magnifyingglass" : "questionmark.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(query.isEmpty ? "Type to search across 2nd Brain, people, meetings, and notes."
                                   : "No matches for \"\(query)\"")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        section(title: "2nd Brain", icon: "books.vertical", items: results.wiki)
                        section(title: "People", icon: "person.3", items: results.people)
                        section(title: "Meetings", icon: "doc.text", items: results.meetings)
                        section(title: "Notes", icon: "note.text", items: results.notes)
                        if let ask = results.askQuestion {
                            section(title: "Ask", icon: "sparkle.magnifyingglass", items: [ask])
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 440)
                .onChange(of: clampedIndex) { _, idx in
                    guard idx < flatItems.count else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(flatItems[idx].id, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section(title: String, icon: String, items: [CommandKItem]) -> some View {
        if !items.isEmpty {
            Text("\(title) (\(items.count))")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(Array(items.enumerated()), id: \.element.id) { _, item in
                resultRow(item: item, icon: icon)
                    .id(item.id)
            }
        }
    }

    private func resultRow(item: CommandKItem, icon: String) -> some View {
        let isSelected = flatItems.indices.contains(clampedIndex) && flatItems[clampedIndex].id == item.id
        return Button(action: { activate(item) }) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13))
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "return")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.orange.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering, let idx = flatItems.firstIndex(where: { $0.id == item.id }) {
                selectedIndex = idx
            }
        }
    }

    private func activate(_ item: CommandKItem) {
        if let onAttach, let entry = haystack.first(where: { $0.id == item.id }) {
            onAttach(entry)
        } else if item.isAskQuestion {
            onAskQuestion?(query.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            item.activate(state)
        }
        isPresented = false
    }

    private func activateSelected() {
        if flatItems.isEmpty {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, onAttach == nil else { return }
            onAskQuestion?(trimmed)
            isPresented = false
            return
        }
        let idx = clampedIndex
        guard flatItems.indices.contains(idx) else { return }
        activate(flatItems[idx])
    }

    private func recomputeResults() {
        let r = CommandKResults.compute(
            haystack: haystack,
            query: query,
            includeAskQuestion: onAttach == nil && onAskQuestion != nil
        )
        results = r
        flatItems = r.wiki + r.people + r.meetings + r.notes + (r.askQuestion.map { [$0] } ?? [])
    }
}

// MARK: - Pre-flattened search index

/// Snapshot of one indexable item with its lowercased haystack precomputed
/// once at sheet-open time. Per-keystroke filtering is then a tight loop of
/// `String.contains` against pre-lowercased fields, with no closure allocation
/// or dictionary traversal until we materialize the (small) result set.
struct CommandKHaystackEntry {
    enum Kind {
        case wiki(GeneratedWikiSidebarItem, folderTitle: String)
        case person(IndexKind, IndexHistoryItem)
        case meeting(MeetingHistoryEntry, dateFolder: String)
        case note(MeetingHistoryEntry, dateFolder: String)
    }
    let title: String
    let titleLower: String
    let subtitle: String?
    let contentLower: String
    let dateFolderLower: String
    let id: String
    let kind: Kind

    @MainActor
    static func snapshot(from state: MeetingWindowState) -> [CommandKHaystackEntry] {
        var out: [CommandKHaystackEntry] = []
        out.reserveCapacity(256)

        for folder in state.generatedWikiFolders {
            for item in folder.items {
                let page = try? GeneratedWikiPaths.readPage(from: item.fileURL)
                out.append(CommandKHaystackEntry(
                    title: item.title,
                    titleLower: item.title.lowercased(),
                    subtitle: folder.title,
                    contentLower: [page?.body, page?.sourceMeetingPath, item.type]
                        .compactMap { $0 }
                        .joined(separator: "\n")
                        .lowercased(),
                    dateFolderLower: "",
                    id: "wiki-\(item.fileURL.path)",
                    kind: .wiki(item, folderTitle: folder.title)
                ))
            }
        }

        for (kind, items) in state.indexItems {
            for item in items {
                out.append(CommandKHaystackEntry(
                    title: item.canonicalName,
                    titleLower: item.canonicalName.lowercased(),
                    subtitle: kind.displayName,
                    contentLower: "",
                    dateFolderLower: "",
                    id: "person-\(kind.rawValue)-\(item.slug)",
                    kind: .person(kind, item)
                ))
            }
        }

        for group in state.historyGroups {
            let dateLower = group.date.lowercased()
            for entry in group.entries {
                let isNote = entry.fileURL.lastPathComponent.hasPrefix("quick-note")
                out.append(CommandKHaystackEntry(
                    title: entry.name,
                    titleLower: entry.name.lowercased(),
                    subtitle: group.date,
                    contentLower: "",
                    dateFolderLower: dateLower,
                    id: "file-\(entry.fileURL.path)",
                    kind: isNote ? .note(entry, dateFolder: group.date) : .meeting(entry, dateFolder: group.date)
                ))
            }
        }

        return out
    }
}

// MARK: - Result types

struct CommandKItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    var isAskQuestion: Bool = false
    let activate: (MeetingWindowState) -> Void
}

struct CommandKResults {
    var wiki: [CommandKItem]
    var people: [CommandKItem]
    var meetings: [CommandKItem]
    var notes: [CommandKItem]
    var askQuestion: CommandKItem?

    var totalCount: Int { wiki.count + people.count + meetings.count + notes.count + (askQuestion == nil ? 0 : 1) }

    private static let perSectionLimit = 12

    /// Filters the pre-built haystack on a fresh query. Only allocates
    /// CommandKItem closures for items that pass the filter, so the per-
    /// keystroke cost is dominated by string contains, not closure setup.
    @MainActor
    static func compute(haystack: [CommandKHaystackEntry], query: String, includeAskQuestion: Bool = false) -> CommandKResults {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return .init(wiki: [], people: [], meetings: [], notes: [], askQuestion: nil)
        }

        var wiki: [CommandKItem] = []
        var people: [CommandKItem] = []
        var meetings: [CommandKItem] = []
        var notes: [CommandKItem] = []

        for entry in haystack {
            let titleHit = entry.titleLower.contains(needle)
            let contentHit = !entry.contentLower.isEmpty && entry.contentLower.contains(needle)
            let dateHit = !entry.dateFolderLower.isEmpty && entry.dateFolderLower.contains(needle)
            guard titleHit || contentHit || dateHit else { continue }

            switch entry.kind {
            case .wiki(let item, _):
                if wiki.count >= perSectionLimit { continue }
                wiki.append(CommandKItem(
                    id: entry.id,
                    title: entry.title,
                    subtitle: entry.subtitle,
                    activate: { st in st.openGeneratedWikiPage(item.fileURL) }
                ))
            case .person(let kind, let item):
                if people.count >= perSectionLimit { continue }
                people.append(CommandKItem(
                    id: entry.id,
                    title: entry.title,
                    subtitle: entry.subtitle,
                    activate: { st in st.openIndexEntry(kind: kind, slug: item.slug) }
                ))
            case .meeting(let history, _):
                if meetings.count >= perSectionLimit { continue }
                meetings.append(CommandKItem(
                    id: entry.id,
                    title: entry.title,
                    subtitle: entry.subtitle,
                    activate: { st in st.openFile(history.fileURL) }
                ))
            case .note(let history, _):
                if notes.count >= perSectionLimit { continue }
                notes.append(CommandKItem(
                    id: entry.id,
                    title: entry.title,
                    subtitle: entry.subtitle,
                    activate: { st in st.openFile(history.fileURL) }
                ))
            }
        }

        let askQuestion = includeAskQuestion ? CommandKItem(
            id: "ask-\(needle)",
            title: "Ask local 2nd Brain: \(query.trimmingCharacters(in: .whitespacesAndNewlines))",
            subtitle: "Runs in the Q&A bar with trace, sources, and token usage",
            isAskQuestion: true,
            activate: { _ in }
        ) : nil

        wiki.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        people.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return .init(wiki: wiki, people: people, meetings: meetings, notes: notes, askQuestion: askQuestion)
    }
}
