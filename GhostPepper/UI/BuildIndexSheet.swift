import SwiftUI

/// Modal sheet that estimates the cost of building an index, then streams
/// progress while the agent builds it. Closes on completion or cancel.
struct BuildIndexSheet: View {
    let kind: IndexKind
    let fetchBuilder: () -> IndexBuilder?
    let onClose: () -> Void

    @AppStorage("agentBackend") private var storedBackend: String = "claude:\(ClaudeAPIModel.sonnet.rawValue)"
    @State private var phase: Phase = .estimating
    @State private var estimate: IndexBuildEstimate?
    @State private var statusLine: String = ""
    @State private var entriesWritten: Int = 0
    @State private var meetingsProcessed: Int = 0
    @State private var totalMeetings: Int = 0
    @State private var runningCost: Double = 0
    @State private var errorMessage: String?
    @State private var buildTask: Task<Void, Never>?

    private var selectedBackend: AgentBackend {
        AgentBackend.decode(storedBackend) ?? .claude(.sonnet)
    }

    private func localLabel(for kind: LocalCleanupModelKind) -> String {
        AgentBackend.local(kind).shortDisplayName + " (local)"
    }

    enum Phase {
        case estimating
        case readyToBuild
        case building
        case completed
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: kind.iconSystemName)
                    .font(.system(size: 16))
                Text("Build \(kind.displayName) index")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }

            switch phase {
            case .estimating:
                estimatingView
            case .readyToBuild:
                readyView
            case .building:
                buildingView
            case .completed:
                completedView
            case .failed:
                failedView
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            await runEstimate()
        }
    }

    private var estimatingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Estimating cost…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder
    private var readyView: some View {
        if let estimate {
            VStack(alignment: .leading, spacing: 12) {
                if estimate.nothingToDo {
                    Text("**Index is up to date** — every meeting is already covered by an existing entry. Nothing to do.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(6)
                } else if estimate.isResume {
                    Text("**Resuming existing index**: \(estimate.existingEntryCount) entries on disk, \(estimate.alreadyProcessedCount) of \(estimate.totalMeetingCount) meetings already covered. This run will only process the remaining \(estimate.unprocessedCount).")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                }

                if !estimate.nothingToDo {
                    HStack(spacing: 8) {
                        Text("**\(estimate.unprocessedCount)** meetings to process using")
                            .font(.system(size: 13))
                        Picker("", selection: $storedBackend) {
                            Section("Cloud") {
                                ForEach(ClaudeAPIModel.allCases) { model in
                                    Text(model.shortDisplayName).tag("claude:\(model.rawValue)")
                                }
                            }
                            Section("Local") {
                                ForEach(LocalCleanupModelKind.allCases) { kind in
                                    Text(localLabel(for: kind)).tag("local:\(kind.rawValue)")
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 180)
                    }

                    switch selectedBackend {
                    case .claude(let model):
                        let range = ClaudePricing.estimateBuildCostRange(model: model, meetingCount: estimate.unprocessedCount)
                        Text("Likely cost: \(formatCost(range.low)) – \(formatCost(range.high))")
                            .font(.system(size: 13, weight: .medium))
                        Text("Estimate is order-of-magnitude; running cost is shown during the build, and you can hit Stop at any time.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    case .local:
                        Text("Free — runs on-device")
                            .font(.system(size: 13, weight: .medium))
                        Text("Local models are slower and less reliable for a long multi-step build than Claude — best on a 9B+ model. You can hit Stop at any time.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Spacer()
                    Button(estimate.nothingToDo ? "Done" : "Cancel", action: onClose)
                        .keyboardShortcut(.cancelAction)
                    if !estimate.nothingToDo {
                        Button(estimate.isResume ? "Resume" : "Build") {
                            runBuild()
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }
            }
        }
    }

    private var buildingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text(statusLine.isEmpty ? "Building…" : statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if totalMeetings > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(meetingsProcessed) of \(totalMeetings) meetings")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(progressFraction * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: progressFraction)
                        .progressViewStyle(.linear)
                        .tint(.orange)
                }
            }

            HStack(spacing: 16) {
                Label("\(entriesWritten) entries written", systemImage: "doc.text")
                Label(formatCost(runningCost), systemImage: "dollarsign.circle")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Stop") {
                    buildTask?.cancel()
                }
            }
        }
    }

    private var progressFraction: Double {
        guard totalMeetings > 0 else { return 0 }
        return min(1, Double(meetingsProcessed) / Double(totalMeetings))
    }

    private var completedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Built \(entriesWritten) entries")
                    .font(.system(size: 13, weight: .medium))
            }
            if totalMeetings > 0 {
                Text("\(meetingsProcessed) of \(totalMeetings) meetings covered")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text("Total cost: \(formatCost(runningCost))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
    }

    private var failedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Build failed")
                    .font(.system(size: 13, weight: .medium))
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - Actions

    private func runEstimate() async {
        guard let builder = fetchBuilder() else {
            self.errorMessage = "Couldn't construct an index builder. Check your Claude API key in Settings."
            self.phase = .failed
            return
        }
        do {
            let est = try await builder.estimateBuildCost(kind: kind)
            self.estimate = est
            self.totalMeetings = est.totalMeetingCount
            self.meetingsProcessed = est.alreadyProcessedCount
            self.phase = .readyToBuild
        } catch {
            self.errorMessage = "Couldn't estimate cost: \(error.localizedDescription)"
            self.phase = .failed
        }
    }

    private func runBuild() {
        // Fetched at click time so the picker's current model selection is
        // honored — AppState's builder cache invalidates when the model
        // setting changes.
        guard let activeBuilder = fetchBuilder() else {
            errorMessage = "Couldn't construct an index builder. Check your Claude API key in Settings."
            phase = .failed
            return
        }
        phase = .building
        statusLine = "Starting…"
        entriesWritten = 0
        runningCost = 0
        let task = Task { @MainActor in
            do {
                for try await event in activeBuilder.buildFullIndex(kind: kind) {
                    if Task.isCancelled { break }
                    switch event {
                    case .estimating, .estimated:
                        break
                    case .status(let s):
                        statusLine = s
                    case .entryWritten:
                        entriesWritten += 1
                    case .meetingsProcessed(let processed, let total):
                        meetingsProcessed = processed
                        totalMeetings = total
                    case .usage(let u):
                        runningCost = u.estimatedCostUSD
                    case .completed:
                        phase = .completed
                        return
                    case .error(let msg):
                        errorMessage = msg
                        phase = .failed
                        return
                    }
                }
                if Task.isCancelled {
                    phase = .completed
                }
            } catch {
                errorMessage = error.localizedDescription
                phase = .failed
            }
        }
        buildTask = task
    }

    private func formatCost(_ cost: Double) -> String {
        String(format: "$%.4f", cost)
    }
}
