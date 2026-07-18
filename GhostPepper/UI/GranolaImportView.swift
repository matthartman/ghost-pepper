import SwiftUI

/// Sheet view for importing Granola meetings into Ghost Pepper.
struct GranolaImportView: View {
    @ObservedObject var importer: GranolaImporter
    @ObservedObject var state: MeetingWindowState
    @Environment(\.dismiss) private var dismiss
    @State private var importStarted = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 36))
                .foregroundColor(.orange)

            Text("Import from Granola")
                .font(.title2.bold())

            // State-dependent content
            switch importer.state {
            case .idle:
                idleView
            case .needsApiKey:
                apiKeyView
            case .fetchingNotes(let current, let total):
                progressView(current: current, total: total)
            case .done(let imported, let transcripts, let enriched):
                doneView(imported: imported, transcripts: transcripts, enriched: enriched)
            case .error(let message):
                errorView(message: message)
            }
        }
        .padding(32)
        .frame(width: 420)
        .onAppear {
            guard !importStarted else { return }
            importStarted = true
            if case .fetchingNotes = importer.state { return }
            importer.state = .needsApiKey
        }
    }

    /// Single-shot orchestrator that runs on sheet open. Uses only Granola's
    /// public API, and prompts for an API key if one is not configured.
    private func runAutoImport() async {
        let dir = MeetingTranscriptSettings.effectiveSaveDirectory()

        let hasApiKey = !importer.granolaApiKey.isEmpty
        if hasApiKey {
            importer.state = .fetchingNotes(current: 0, total: 0)
            let apiSummary = await importer.fetchTranscripts(apiKey: importer.granolaApiKey, to: dir)
            state.loadHistory()
            let apiChanged = apiSummary.imported + apiSummary.enriched
            if apiChanged > 0 {
                NotificationCenter.default.post(name: .granolaImported, object: apiChanged)
            }
            if case .error = importer.state {
                // Keep the API error state.
            } else {
                importer.state = .done(
                    imported: apiSummary.imported,
                    transcripts: apiSummary.transcripts,
                    enriched: apiSummary.enriched
                )
            }
            return
        }

        importer.state = .needsApiKey
    }

    // MARK: - States

    private var idleView: some View {
        VStack(spacing: 12) {
            Text("Import your meeting notes, summaries, and transcripts from the Granola API.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Enter API Key") {
                importer.state = .needsApiKey
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
        }
    }

    private var apiKeyView: some View {
        VStack(spacing: 12) {
            Text("Enter your Granola API key to fetch transcripts.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("In Granola, go to Account → Settings → Connectors → Personal API Key.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField("Granola API key", text: $importer.granolaApiKey)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

            Button("Fetch Transcripts") {
                Task { await runAPIImport() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(importer.granolaApiKey.isEmpty)
        }
    }

    private func progressView(current: Int, total: Int) -> some View {
        VStack(spacing: 12) {
            if total == 0 {
                ProgressView("Fetching note list from Granola...")
            } else {
                ProgressView("Enriching notes... \(current)/\(total)")
            }

            Text("This may take a few minutes")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Continue in Background") {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
    }

    private func runAPIImport() async {
        let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
        let apiSummary = await importer.fetchTranscripts(apiKey: importer.granolaApiKey, to: dir)
        state.loadHistory()
        let changed = apiSummary.imported + apiSummary.enriched
        if changed > 0 {
            NotificationCenter.default.post(name: .granolaImported, object: changed)
        }
        importer.state = .done(imported: apiSummary.imported, transcripts: apiSummary.transcripts, enriched: apiSummary.enriched)
    }

    private func doneView(imported: Int, transcripts: Int, enriched: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.green)

            importSummaryText(imported: imported, transcripts: transcripts, enriched: enriched)
                .font(.callout.weight(.medium))

            Text("Your Granola meetings are now in the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Done") {
                dismiss()
                state.loadHistory()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
    }

    private func importSummaryText(imported: Int, transcripts: Int, enriched: Int) -> Text {
        var parts: [String] = []
        if imported > 0 {
            parts.append("\(imported) new \(imported == 1 ? "meeting" : "meetings") imported")
        }
        if enriched > 0 {
            parts.append("\(enriched) existing \(enriched == 1 ? "record was" : "records were") re-imported with enriched info")
        }
        if transcripts > 0 {
            parts.append("\(transcripts) \(transcripts == 1 ? "transcript" : "transcripts") fetched")
        }
        if parts.isEmpty {
            parts.append("Granola is up to date")
        }
        return Text(parts.joined(separator: ", ") + "!")
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundColor(.orange)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Enter API Key") {
                    importer.state = .needsApiKey
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
        }
    }
}
