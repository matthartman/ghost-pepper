import SwiftUI

struct AirtableImportView: View {
    @ObservedObject var importer: AirtableImporter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "tablecells")
                .font(.system(size: 36))
                .foregroundColor(.orange)

            Text("Sync Airtable")
                .font(.title2.bold())

            switch importer.state {
            case .idle:
                formView
            case .syncing(let table, let completed, let total):
                syncingView(table: table, completed: completed, total: total)
            case .done(let tables, let records, let directory):
                doneView(tables: tables, records: records, directory: directory)
            case .error(let message):
                errorView(message: message)
            }
        }
        .padding(32)
        .frame(width: 460)
        .onAppear {
            if case .done = importer.state {
                importer.state = .idle
            }
        }
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export each Airtable table as a CSV into your meetings folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 6) {
                Text("Personal access token")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                SecureField("pat...", text: $importer.apiToken)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Base ID")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("app...", text: $importer.baseID)
                    .textFieldStyle(.roundedBorder)
            }

            Text("The token is stored in Keychain. The base ID is stored locally in app preferences.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Token scopes needed: schema.bases:read and data.records:read. The token must also be granted access to the selected base.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Link("Create Airtable token", destination: URL(string: "https://airtable.com/create/tokens")!)
                    .font(.caption)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Sync CSVs") {
                    Task {
                        _ = await importer.sync(to: MeetingTranscriptSettings.effectiveSaveDirectory())
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!importer.isConfigured)
            }
        }
    }

    private func syncingView(table: String?, completed: Int, total: Int) -> some View {
        VStack(spacing: 10) {
            if total == 0 {
                ProgressView("Reading Airtable schema...")
            } else {
                ProgressView("Exporting \(table ?? "table")... \(completed)/\(total)")
            }
            Text("Writing one CSV per table")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func doneView(tables: Int, records: Int, directory: URL) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.green)

            Text("Exported \(tables) tables and \(records) records.")
                .font(.callout.weight(.medium))

            Text(directory.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Open Folder") {
                    NSWorkspace.shared.open(directory)
                }
                .buttonStyle(.bordered)

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
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

            HStack(spacing: 12) {
                Button("Edit Settings") {
                    importer.state = .idle
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
