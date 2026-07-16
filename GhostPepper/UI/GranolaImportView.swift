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
            case .localDone(let count):
                localDoneView(count: count)
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
            case .done(let imported, let transcripts):
                doneView(imported: imported, transcripts: transcripts)
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
        let localCount = await importer.importFromLocalCache(to: dir)
        state.loadHistory()
        if localCount > 0 {
            NotificationCenter.default.post(name: .granolaImported, object: localCount)
        }

        let hasApiKey = !importer.granolaApiKey.isEmpty
        if hasApiKey {
            // Override any local error state — we're going to try the API
            // regardless. Errors from the API path itself are surfaced by
            // `fetchTranscripts` and end up in `.error`.
            importer.state = .fetchingNotes(current: 0, total: 0)
            let transcripts = await importer.fetchTranscripts(apiKey: importer.granolaApiKey, to: dir)
            state.loadHistory()
            if transcripts > 0 {
                NotificationCenter.default.post(name: .granolaImported, object: transcripts)
            }
            // If `fetchTranscripts` already routed to `.error` (e.g. HTTP
            // failure), leave that in place so the user sees what went
            // wrong. Otherwise summarize.
            if case .error = importer.state {
                // keep the API error state
            } else {
                importer.state = .done(imported: localCount, transcripts: transcripts)
            }
            return
        }

        // No API key. If local succeeded, show its summary; otherwise prompt
        // for a key so the user can pivot in one click instead of bouncing
        // off "Try Again."
        if localCount > 0 {
            importer.state = .localDone(count: localCount)
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
                    let count = await importer.importFromLocalCache(to: dir)
                    state.loadHistory()
                    if count > 0 {
                        NotificationCenter.default.post(name: .granolaImported, object: count)
                        importer.state = .localDone(count: count)
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

    private func localDoneView(count: Int) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.green)

            Text("Imported \(count) meetings!")
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
                        let transcripts = await importer.fetchTranscripts(apiKey: importer.granolaApiKey, to: dir)
                        state.loadHistory()
                        if transcripts > 0 {
                            NotificationCenter.default.post(name: .granolaImported, object: transcripts)
                        }
                        importer.state = .done(imported: count, transcripts: transcripts)
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
                    let transcripts = await importer.fetchTranscripts(apiKey: importer.granolaApiKey, to: dir)
                    state.loadHistory()
                    if transcripts > 0 {
                        NotificationCenter.default.post(name: .granolaImported, object: transcripts)
                    }
                    importer.state = .done(imported: 0, transcripts: transcripts)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(importer.granolaApiKey.isEmpty)
        }
    }

    private func doneView(imported: Int, transcripts: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.green)

            if imported > 0 {
                Text("\(imported) meetings imported, \(transcripts) notes enriched from API!")
                    .font(.callout.weight(.medium))
            } else {
                Text("\(transcripts) notes enriched from API!")
                    .font(.callout.weight(.medium))
            }

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
