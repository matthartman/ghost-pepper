import Foundation

@MainActor
final class TranscriptionLabController: ObservableObject {
    typealias StageTimingsLoader = () throws -> [UUID: TranscriptionLabStageTimings]
    typealias EntryLoader = () throws -> [TranscriptionLabEntry]
    typealias AudioURLProvider = (TranscriptionLabEntry) -> URL
    typealias TranscriptionRunner = (
        _ entry: TranscriptionLabEntry,
        _ speechModelID: String,
        _ speakerTaggingEnabled: Bool
    ) async throws -> TranscriptionLabTranscriptionResult
    typealias CleanupRunner = (
        _ entry: TranscriptionLabEntry,
        _ rawTranscription: String,
        _ cleanupModelKind: LocalCleanupModelKind,
        _ prompt: String,
        _ includeWindowContext: Bool
    ) async throws -> TranscriptionLabCleanupResult
    typealias SelectedSpeechModelSynchronizer = (_ speechModelID: String) -> Void
    typealias SpeakerTaggingSynchronizer = (_ speakerTaggingEnabled: Bool) -> Void
    typealias SelectedCleanupModelSynchronizer = (_ cleanupModelKind: LocalCleanupModelKind) -> Void

    enum RunningStage {
        case transcription
        case cleanup
    }

    struct DiarizationVisualization: Equatable {
        struct Span: Equatable {
            let speakerID: String
            let startTime: TimeInterval
            let endTime: TimeInterval
            let isKept: Bool
        }

        let audioDuration: TimeInterval
        let targetSpeakerID: String?
        let keptAudioDuration: TimeInterval
        let usedFallback: Bool
        let fallbackReason: DiarizationSummary.FallbackReason?
        let spans: [Span]

        var speakerIDsInDisplayOrder: [String] {
            var speakerIDs: [String] = []
            var seenSpeakerIDs: Set<String> = []

            for span in spans where seenSpeakerIDs.insert(span.speakerID).inserted {
                speakerIDs.append(span.speakerID)
            }

            return speakerIDs
        }
    }

    @Published private(set) var entries: [TranscriptionLabEntry] = []
    @Published var searchText: String = ""
    @Published var selectedEntryID: UUID?
    @Published var selectedSpeechModelID: String {
        didSet {
            synchronizeSelectedSpeechModelIDIfNeeded()
        }
    }
    @Published var usesSpeakerTagging: Bool {
        didSet {
            synchronizeSpeakerTaggingIfNeeded()
        }
    }
    @Published var selectedCleanupModelKind: LocalCleanupModelKind {
        didSet {
            synchronizeSelectedCleanupModelKindIfNeeded()
        }
    }
    @Published var usesCapturedOCR = true
    @Published private(set) var experimentRawTranscription: String = ""
    @Published private(set) var experimentCorrectedTranscription: String = ""
    @Published private(set) var experimentTranscriptionDuration: TimeInterval?
    @Published private(set) var experimentCleanupDuration: TimeInterval?
    @Published private(set) var experimentDiarizationSummary: DiarizationSummary?
    @Published private(set) var experimentSpeakerTaggedTranscript: SpeakerTaggedTranscript?
    @Published private(set) var latestCleanupTranscript: TranscriptionLabCleanupTranscript?
    @Published private(set) var runningStage: RunningStage?
    @Published private(set) var errorMessage: String?

    private let loadStageTimings: StageTimingsLoader
    private let loadEntries: EntryLoader
    private let audioURLForEntry: AudioURLProvider
    private let runTranscription: TranscriptionRunner
    private let runCleanup: CleanupRunner
    private let syncSelectedSpeechModelID: SelectedSpeechModelSynchronizer
    private let syncSpeakerTaggingEnabled: SpeakerTaggingSynchronizer
    private let syncSelectedCleanupModelKind: SelectedCleanupModelSynchronizer
    private var originalStageTimingsByEntryID: [UUID: TranscriptionLabStageTimings] = [:]
    private var suppressSelectionSynchronization = false

    init(
        defaultSpeechModelID: String,
        defaultSpeakerTaggingEnabled: Bool,
        defaultCleanupModelKind: LocalCleanupModelKind = .qwen35_4b_q4_k_m,
        loadStageTimings: @escaping StageTimingsLoader = { [:] },
        loadEntries: @escaping EntryLoader,
        audioURLForEntry: @escaping AudioURLProvider,
        runTranscription: @escaping TranscriptionRunner,
        runCleanup: @escaping CleanupRunner,
        syncSelectedSpeechModelID: @escaping SelectedSpeechModelSynchronizer = { _ in },
        syncSpeakerTaggingEnabled: @escaping SpeakerTaggingSynchronizer = { _ in },
        syncSelectedCleanupModelKind: @escaping SelectedCleanupModelSynchronizer = { _ in }
    ) {
        self.selectedSpeechModelID = defaultSpeechModelID
        self.usesSpeakerTagging = defaultSpeakerTaggingEnabled
        self.selectedCleanupModelKind = defaultCleanupModelKind
        self.loadStageTimings = loadStageTimings
        self.loadEntries = loadEntries
        self.audioURLForEntry = audioURLForEntry
        self.runTranscription = runTranscription
        self.runCleanup = runCleanup
        self.syncSelectedSpeechModelID = syncSelectedSpeechModelID
        self.syncSpeakerTaggingEnabled = syncSpeakerTaggingEnabled
        self.syncSelectedCleanupModelKind = syncSelectedCleanupModelKind
    }

    func applyCurrentRerunDefaults(
        speechModelID: String,
        speakerTaggingEnabled: Bool,
        cleanupModelKind: LocalCleanupModelKind
    ) {
        suppressSelectionSynchronization = true
        selectedSpeechModelID = speechModelID
        usesSpeakerTagging = speakerTaggingEnabled
        selectedCleanupModelKind = cleanupModelKind
        suppressSelectionSynchronization = false
    }

    var selectedEntry: TranscriptionLabEntry? {
        guard let selectedEntryID else {
            return nil
        }

        return entries.first { $0.id == selectedEntryID }
    }

    var filteredEntries: [TranscriptionLabEntry] {
        guard !searchText.isEmpty else { return entries }
        let query = searchText.lowercased()
        return entries.filter { entry in
            (entry.correctedTranscription ?? "").lowercased().contains(query) ||
                (entry.rawTranscription ?? "").lowercased().contains(query)
        }
    }

    var isRunningTranscription: Bool {
        runningStage == .transcription
    }

    var isRunningCleanup: Bool {
        runningStage == .cleanup
    }

    var activeRawTranscriptionForCleanup: String {
        if !experimentRawTranscription.isEmpty {
            return experimentRawTranscription
        }

        return selectedEntry?.rawTranscription ?? ""
    }

    var displayedExperimentRawTranscription: String {
        if !experimentRawTranscription.isEmpty {
            return experimentRawTranscription
        }

        return selectedEntry?.rawTranscription ?? ""
    }

    var displayedExperimentCorrectedTranscription: String {
        if !experimentCorrectedTranscription.isEmpty {
            return experimentCorrectedTranscription
        }

        return selectedEntry?.correctedTranscription ?? ""
    }

    var displayedSpeakerTaggedTranscriptText: String? {
        guard let experimentSpeakerTaggedTranscript else {
            return nil
        }

        return experimentSpeakerTaggedTranscript.segments
            .map { segment in
                """
                [\(segment.speakerID) | \(formattedDuration(segment.startTime))-\(formattedDuration(segment.endTime))]
                \(segment.text)
                """
            }
            .joined(separator: "\n\n")
    }

    var originalTranscriptionDuration: TimeInterval? {
        guard let selectedEntryID else {
            return nil
        }

        return originalStageTimingsByEntryID[selectedEntryID]?.transcriptionDuration
    }

    var originalCleanupDuration: TimeInterval? {
        guard let selectedEntryID else {
            return nil
        }

        return originalStageTimingsByEntryID[selectedEntryID]?.cleanupDuration
    }

    var diarizationVisualization: DiarizationVisualization? {
        guard let entry = selectedEntry else {
            return nil
        }

        let summary = experimentDiarizationSummary ?? entry.diarizationSummary
        guard let summary else {
            return nil
        }

        return DiarizationVisualization(
            audioDuration: entry.audioDuration,
            targetSpeakerID: summary.targetSpeakerID,
            keptAudioDuration: summary.keptAudioDuration,
            usedFallback: summary.usedFallback,
            fallbackReason: summary.fallbackReason,
            spans: summary.spans.map {
                DiarizationVisualization.Span(
                    speakerID: $0.speakerID,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    isKept: $0.isKept
                )
            }
        )
    }

    func audioURL(for entry: TranscriptionLabEntry) -> URL {
        audioURLForEntry(entry)
    }

    func reloadEntries() {
        do {
            let loadedEntries = try loadEntries().sorted { $0.createdAt > $1.createdAt }
            originalStageTimingsByEntryID = try loadStageTimings()
            entries = loadedEntries

            if let selectedEntryID,
               loadedEntries.contains(where: { $0.id == selectedEntryID }) {
                return
            }

            selectedEntryID = nil
            usesCapturedOCR = true
            experimentRawTranscription = ""
            experimentCorrectedTranscription = ""
            experimentTranscriptionDuration = nil
            experimentCleanupDuration = nil
            experimentDiarizationSummary = nil
            experimentSpeakerTaggedTranscript = nil
            latestCleanupTranscript = nil
            errorMessage = nil
        } catch {
            entries = []
            selectedEntryID = nil
            usesCapturedOCR = true
            experimentRawTranscription = ""
            experimentCorrectedTranscription = ""
            experimentTranscriptionDuration = nil
            experimentCleanupDuration = nil
            experimentDiarizationSummary = nil
            experimentSpeakerTaggedTranscript = nil
            latestCleanupTranscript = nil
            originalStageTimingsByEntryID = [:]
            errorMessage = "Could not load saved recordings."
        }
    }

    func selectEntry(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return
        }

        selectedEntryID = id
        usesCapturedOCR = entry.windowContext != nil
        experimentRawTranscription = ""
        experimentCorrectedTranscription = ""
        experimentTranscriptionDuration = nil
        experimentCleanupDuration = nil
        experimentDiarizationSummary = nil
        experimentSpeakerTaggedTranscript = nil
        latestCleanupTranscript = nil
        errorMessage = nil
    }

    func closeDetail() {
        selectedEntryID = nil
        usesCapturedOCR = true
        experimentRawTranscription = ""
        experimentCorrectedTranscription = ""
        experimentTranscriptionDuration = nil
        experimentCleanupDuration = nil
        experimentDiarizationSummary = nil
        experimentSpeakerTaggedTranscript = nil
        latestCleanupTranscript = nil
        errorMessage = nil
    }

    func deleteEntry(_ id: UUID, using store: TranscriptionLabStore) {
        try? store.deleteEntry(id: id)
        if selectedEntryID == id {
            closeDetail()
        }
        reloadEntries()
    }

    func deleteAllEntries(using store: TranscriptionLabStore) {
        store.deleteAllEntries()
        closeDetail()
        reloadEntries()
    }

    func rerunTranscription() async {
        guard let entry = selectedEntry else {
            errorMessage = "Choose a saved recording first."
            return
        }

        runningStage = .transcription
        errorMessage = nil
        experimentTranscriptionDuration = nil
        experimentDiarizationSummary = nil
        experimentSpeakerTaggedTranscript = nil
        latestCleanupTranscript = nil
        let start = Date()

        do {
            let result = try await runTranscription(
                entry,
                selectedSpeechModelID,
                usesSpeakerTagging && selectedSpeechModelSupportsSpeakerTagging
            )
            experimentRawTranscription = result.rawTranscription
            experimentCorrectedTranscription = ""
            experimentDiarizationSummary = result.diarizationSummary
            experimentSpeakerTaggedTranscript = result.speakerTaggedTranscript
            experimentTranscriptionDuration = Date().timeIntervalSince(start)
            experimentCleanupDuration = nil
        } catch let error as TranscriptionLabRunnerError {
            switch error {
            case .pipelineBusy:
                errorMessage = "Ghost Pepper is busy with another recording or lab run."
            case .missingAudio:
                errorMessage = "This saved recording no longer has playable audio."
            case .transcriptionFailed:
                errorMessage = "That model could not produce a transcription for this recording."
            }
        } catch {
            errorMessage = "The lab rerun failed."
        }

        runningStage = nil
    }

    func rerunCleanup(prompt: String) async {
        guard let entry = selectedEntry else {
            errorMessage = "Choose a saved recording first."
            return
        }

        let rawTranscription = activeRawTranscriptionForCleanup
        guard !rawTranscription.isEmpty else {
            errorMessage = "Run transcription first or choose a recording with a raw transcription."
            return
        }

        runningStage = .cleanup
        errorMessage = nil
        experimentCleanupDuration = nil
        latestCleanupTranscript = nil
        let start = Date()

        do {
            let result = try await runCleanup(
                entry,
                rawTranscription,
                selectedCleanupModelKind,
                prompt,
                usesCapturedOCR
            )
            experimentCorrectedTranscription = result.correctedTranscription
            experimentCleanupDuration = Date().timeIntervalSince(start)
            latestCleanupTranscript = result.transcript
        } catch let error as TranscriptionLabRunnerError {
            switch error {
            case .pipelineBusy:
                errorMessage = "Ghost Pepper is busy with another recording or lab run."
            case .missingAudio:
                errorMessage = "This saved recording no longer has playable audio."
            case .transcriptionFailed:
                errorMessage = "Ghost Pepper could not produce input for cleanup."
            }
        } catch {
            errorMessage = "The cleanup rerun failed."
        }

        runningStage = nil
    }

    private var selectedSpeechModelSupportsSpeakerTagging: Bool {
        SpeechModelCatalog.model(named: selectedSpeechModelID)?.supportsSpeakerFiltering == true
    }

    private func synchronizeSelectedSpeechModelIDIfNeeded() {
        guard !suppressSelectionSynchronization else {
            return
        }

        syncSelectedSpeechModelID(selectedSpeechModelID)
    }

    private func synchronizeSelectedCleanupModelKindIfNeeded() {
        guard !suppressSelectionSynchronization else {
            return
        }

        syncSelectedCleanupModelKind(selectedCleanupModelKind)
    }

    private func synchronizeSpeakerTaggingIfNeeded() {
        guard !suppressSelectionSynchronization else {
            return
        }

        syncSpeakerTaggingEnabled(usesSpeakerTagging)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.1fs", duration)
    }
}
