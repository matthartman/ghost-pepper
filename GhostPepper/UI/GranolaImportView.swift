import SwiftUI

/// Sheet view for importing Granola meetings into Ghost Pepper.
struct GranolaImportView: View {
    @ObservedObject var importer: GranolaImporter
    @ObservedObject var state: MeetingWindowState
    @Environment(\.dismiss) private var dismiss

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
            case .importingLocal:
                ProgressView("Importing meetings from local cache...")
            case .localDone(let count, let enriched):
                localDoneView(count: count, enriched: enriched)
            case .needsApiKey:
                apiKeyView
            case .fetchingNotes(let current, let total):
                VStack(spacing: 8) {
                    if total == 0 {
                        ProgressView("Fetching note list from Granola...")
                    } else {
                        ProgressView("Enriching notes... \(current)/\(total)")
                    }
                    Text("This may take a few minutes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .done(let imported, let transcripts, let enriched):
                doneView(imported: imported, transcripts: transcripts, enriched: enriched)
            case .error(let message):
                errorView(message: message)
            }
        }
        .padding(32)
        .frame(width: 420)
        .task {
            // Every sheet open kicks off a fresh import — try local first
            // (silent if Granola's v6 encrypted cache is in use), then API
            // if a key is configured. Avoids the "Start Import → fail →
            // Try Again" dance the user used to have to do.
            if case .fetchingNotes = importer.state { return }
            if case .importingLocal = importer.state { return }
            importer.state = .idle
            await runAutoImport()
        }
    }

    /// Single-shot orchestrator that runs on sheet open. Calls the local-
    /// cache importer (which now fails fast and quietly when Granola's v6
    /// encrypted store is in use), then the API path if a key is configured.
    /// Routes to the right end-state without making the user click "Start
    /// Import" or "Try Again".
    private func runAutoImport() async {
        let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
        let localSummary = await importer.importFromLocalCache(to: dir)
        state.loadHistory()
        let localChanged = localSummary.imported + localSummary.enriched
        if localChanged > 0 {
            NotificationCenter.default.post(name: .granolaImported, object: localChanged)
        }

        let hasApiKey = !importer.granolaApiKey.isEmpty
        if hasApiKey {
            // Override any local error state — we're going to try the API
            // regardless. Errors from the API path itself are surfaced by
            // `fetchTranscripts` and end up in `.error`.
            importer.state = .fetchingNotes(current: 0, total: 0)
            let apiSummary = await importer.fetchTranscripts(apiKey: importer.granolaApiKey, to: dir)
            state.loadHistory()
            let apiChanged = apiSummary.imported + apiSummary.enriched
            if apiChanged > 0 {
                NotificationCenter.default.post(name: .granolaImported, object: apiChanged)
            }
            // If `fetchTranscripts` already routed to `.error` (e.g. HTTP
            // failure), leave that in place so the user sees what went
            // wrong. Otherwise summarize.
            if case .error = importer.state {
                // keep the API error state
            } else {
                importer.state = .done(
                    imported: localSummary.imported + apiSummary.imported,
                    transcripts: apiSummary.transcripts,
                    enriched: localSummary.enriched + apiSummary.enriched
                )
            }
            return
        }

        // No API key. If local succeeded, show its summary; otherwise prompt
        // for a key so the user can pivot in one click instead of bouncing
        // off "Try Again."
        if localChanged > 0 {
            importer.state = .localDone(count: localSummary.imported, enriched: localSummary.enriched)
        } else {
            importer.state = .needsApiKey
        }
    }

    // MARK: - States

    private var idleView: some View {
        VStack(spacing: 12) {
            Text("Import your meeting notes, summaries, and chapters from Granola's local cache.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Start Import") {
                Task {
                    let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
                    let summary = await importer.importFromLocalCache(to: dir)
                    state.loadHistory()
                    let changed = summary.imported + summary.enriched
                    if changed > 0 {
                        NotificationCenter.default.post(name: .granolaImported, object: changed)
                        importer.state = .localDone(count: summary.imported, enriched: summary.enriched)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
        }
    }

    private func localDoneView(count: Int, enriched: Int) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.green)

            importSummaryText(imported: count, transcripts: 0, enriched: enriched)
                .font(.callout.weight(.medium))

            Divider()

            Text("Want to fetch full notes & transcripts from the Granola API?")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Open **Granola** → **Settings** → **API Key** → **Create new key** and paste it below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField("Granola API key", text: $importer.granolaApiKey)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

            Link("How to get an API key", destination: URL(string: "https://docs.granola.ai/introduction#obtaining-an-api-key")!)
                .font(.caption)

            HStack(spacing: 12) {
                Button("Fetch Notes & Transcripts") {
                    Task {
                        let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
                        let apiSummary = await importer.fetchTranscripts(apiKey: importer.granolaApiKey, to: dir)
                        state.loadHistory()
                        let changed = apiSummary.imported + apiSummary.enriched
                        if changed > 0 {
                            NotificationCenter.default.post(name: .granolaImported, object: changed)
                        }
                        importer.state = .done(
                            imported: count + apiSummary.imported,
                            transcripts: apiSummary.transcripts,
                            enriched: enriched + apiSummary.enriched
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(importer.granolaApiKey.isEmpty)

                Button("Skip") {
                    dismiss()
                    state.loadHistory()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
    }

    private var apiKeyView: some View {
        VStack(spacing: 12) {
            Text("Enter your Granola API key to fetch transcripts.")
                .font(.callout)
                .foregroundStyle(.secondary)

            SecureField("Granola API key", text: $importer.granolaApiKey)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

            Link("How to get an API key", destination: URL(string: "https://docs.granola.ai/introduction#obtaining-an-api-key")!)
                .font(.caption)

            Button("Fetch Transcripts") {
                Task {
                    let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
                    let apiSummary = await importer.fetchTranscripts(apiKey: importer.granolaApiKey, to: dir)
                    state.loadHistory()
                    let changed = apiSummary.imported + apiSummary.enriched
                    if changed > 0 {
                        NotificationCenter.default.post(name: .granolaImported, object: changed)
                    }
                    importer.state = .done(imported: apiSummary.imported, transcripts: apiSummary.transcripts, enriched: apiSummary.enriched)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(importer.granolaApiKey.isEmpty)
        }
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

            // If the local-cache path failed (and an encrypted cache file
            // exists, which is the post-v6 reality), surface the API path as
            // the primary recovery action rather than just "Try Again".
            let mentionsApi = message.contains("API-key") || message.contains("encrypts")

            HStack(spacing: 12) {
                if mentionsApi {
                    Button("Enter API key") {
                        importer.state = .needsApiKey
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                } else {
                    Button("Try Again") {
                        importer.state = .idle
                    }
                    .buttonStyle(.bordered)
                }

                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
        }
    }
}
