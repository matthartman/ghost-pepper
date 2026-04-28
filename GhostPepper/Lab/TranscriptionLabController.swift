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
    typealias SpeakerProfileLoader = (_ entryID: UUID) throws -> [TranscriptionLabSpeakerProfile]
    typealias SpeakerProfileSaver = (_ profile: TranscriptionLabSpeakerProfile) throws -> Void
    typealias RecognizedVoiceLoader = () throws -> [RecognizedVoiceProfile]
    typealias GlobalVoiceProfileUpdater = (_ localProfile: TranscriptionLabSpeakerProfile) throws -> RecognizedVoiceProfile?
    typealias RecognizedVoicesChangeObserver = () -> Void
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
            let displayName: String
            let startTime: TimeInterval
            let endTime: TimeInterval
            let isKept: Bool
            let isIncludedInTranscript: Bool

            init(
                speakerID: String,
                displayName: String? = nil,
                startTime: TimeInterval,
                endTime: TimeInterval,
                isKept: Bool,
                isIncludedInTranscript: Bool? = nil
            ) {
                self.speakerID = speakerID
                self.displayName = displayName ?? speakerID
                self.startTime = startTime
                self.endTime = endTime
                self.isKept = isKept
                self.isIncludedInTranscript = isIncludedInTranscript ?? isKept
            }
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

        var includedSpeakerIDsInDisplayOrder: [String] {
            var speakerIDs: [String] = []
            var seenSpeakerIDs: Set<String> = []

            for span in spans where span.isIncludedInTranscript && seenSpeakerIDs.insert(span.speakerID).inserted {
                speakerIDs.append(span.speakerID)
            }

            return speakerIDs
        }

        var includedTranscriptDuration: TimeInterval {
            spans.reduce(0) { totalDuration, span in
                guard span.isIncludedInTranscript else {
                    return totalDuration
                }

                return totalDuration + max(0, span.endTime - span.startTime)
            }
        }

        func displayName(for speakerID: String) -> String {
            spans.first(where: { $0.speakerID == speakerID })?.displayName ?? speakerID
        }

        var targetDisplayName: String? {
            guard let targetSpeakerID else {
                return nil
            }

            return displayName(for: targetSpeakerID)
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
    @Published private(set) var speakerProfiles: [TranscriptionLabSpeakerProfile] = []
    @Published private(set) var latestCleanupTranscript: TranscriptionLabCleanupTranscript?
    @Published private(set) var runningStage: RunningStage?
    @Published private(set) var errorMessage: String?

    private let loadStageTimings: StageTimingsLoader
    private let loadEntries: EntryLoader
    private let audioURLForEntry: AudioURLProvider
    private let runTranscription: TranscriptionRunner
    private let runCleanup: CleanupRunner
    private let loadSpeakerProfiles: SpeakerProfileLoader
    private let saveSpeakerProfile: SpeakerProfileSaver
    private let loadRecognizedVoices: RecognizedVoiceLoader
    private let updateGlobalVoiceProfile: GlobalVoiceProfileUpdater
    private let notifyRecognizedVoicesDidChange: RecognizedVoicesChangeObserver
    private let syncSelectedSpeechModelID: SelectedSpeechModelSynchronizer
    private let syncSpeakerTaggingEnabled: SpeakerTaggingSynchronizer
    private let syncSelectedCleanupModelKind: SelectedCleanupModelSynchronizer
    private var originalStageTimingsByEntryID: [UUID: TranscriptionLabStageTimings] = [:]
    private var recognizedVoicesByID: [UUID: RecognizedVoiceProfile] = [:]
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
        loadSpeakerProfiles: @escaping SpeakerProfileLoader = { _ in [] },
        saveSpeakerProfile: @escaping SpeakerProfileSaver = { _ in },
        loadRecognizedVoices: @escaping RecognizedVoiceLoader = { [] },
        updateGlobalVoiceProfile: @escaping GlobalVoiceProfileUpdater = { _ in nil },
        notifyRecognizedVoicesDidChange: @escaping RecognizedVoicesChangeObserver = {},
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
        self.loadSpeakerProfiles = loadSpeakerProfiles
        self.saveSpeakerProfile = saveSpeakerProfile
        self.loadRecognizedVoices = loadRecognizedVoices
        self.updateGlobalVoiceProfile = updateGlobalVoiceProfile
        self.notifyRecognizedVoicesDidChange = notifyRecognizedVoicesDidChange
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

    var speakerProfilesInDisplayOrder: [TranscriptionLabSpeakerProfile] {
        let orderedSpeakerIDs = diarizationVisualization?.speakerIDsInDisplayOrder ?? speakerProfiles.map(\.speakerID)

        var orderedProfiles = orderedSpeakerIDs.compactMap { effectiveSpeakerProfile(for: $0) }
        let remainingProfiles = speakerProfiles
            .filter { orderedSpeakerIDs.contains($0.speakerID) == false }
            .map(mergedSpeakerProfile)
        orderedProfiles.append(contentsOf: remainingProfiles)
        return orderedProfiles
    }

    var displayedSpeakerTaggedTranscriptText: String? {
        guard let experimentSpeakerTaggedTranscript else {
            return nil
        }

        return experimentSpeakerTaggedTranscript.segments
            .map { segment in
                """
                [\(displayName(for: segment.speakerID) ?? segment.speakerID) | \(formattedDuration(segment.startTime))-\(formattedDuration(segment.endTime))]
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

    var originalDiarizationVisualization: DiarizationVisualization? {
        guard let entry = selectedEntry else {
            return nil
        }

        guard let summary = entry.diarizationSummary else {
            return nil
        }

        return diarizationVisualization(for: entry, summary: summary)
    }

    var experimentDiarizationVisualization: DiarizationVisualization? {
        guard let entry = selectedEntry,
              let experimentDiarizationSummary else {
            return nil
        }

        return diarizationVisualization(for: entry, summary: experimentDiarizationSummary)
    }

    var diarizationVisualization: DiarizationVisualization? {
        experimentDiarizationVisualization ?? originalDiarizationVisualization
    }

    private func diarizationVisualization(
        for entry: TranscriptionLabEntry,
        summary: DiarizationSummary
    ) -> DiarizationVisualization {
        let includedSpeakerIDs = transcriptIncludedSpeakerIDs(for: summary)

        return DiarizationVisualization(
            audioDuration: entry.audioDuration,
            targetSpeakerID: summary.targetSpeakerID,
            keptAudioDuration: summary.keptAudioDuration,
            usedFallback: summary.usedFallback,
            fallbackReason: summary.fallbackReason,
            spans: summary.spans.map {
                DiarizationVisualization.Span(
                    speakerID: $0.speakerID,
                    displayName: displayName(for: $0.speakerID) ?? $0.speakerID,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    isKept: $0.isKept,
                    isIncludedInTranscript: includedSpeakerIDs.contains($0.speakerID)
                )
            }
        )
    }

    var recognizedVoiceOptions: [RecognizedVoiceProfile] {
        recognizedVoicesByID.values.sorted { lhs, rhs in
            let lhsName = normalizedDisplayName(lhs.displayName)
            let rhsName = normalizedDisplayName(rhs.displayName)

            if lhsName != rhsName {
                return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
            }

            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func displayName(for speakerID: String) -> String? {
        if let profile = effectiveSpeakerProfile(for: speakerID) {
            let normalizedName = normalizedDisplayName(profile.displayName)
            if normalizedName.isEmpty == false {
                return normalizedName
            }
        }

        return nil
    }

    private func storedSpeakerProfile(for speakerID: String) -> TranscriptionLabSpeakerProfile? {
        speakerProfiles.first { $0.speakerID == speakerID }
    }

    private func effectiveSpeakerProfile(for speakerID: String) -> TranscriptionLabSpeakerProfile? {
        guard let localProfile = storedSpeakerProfile(for: speakerID) else {
            return nil
        }

        return mergedSpeakerProfile(localProfile)
    }

    func hasPendingGlobalVoiceUpdate(for speakerID: String) -> Bool {
        guard
            let localProfile = storedSpeakerProfile(for: speakerID),
            let recognizedVoice = recognizedVoice(for: localProfile)
        else {
            return false
        }

        let normalizedLocalName = normalizedDisplayName(localProfile.displayName)
        let normalizedGlobalName = normalizedDisplayName(recognizedVoice.displayName)

        if normalizedLocalName.isEmpty == false, normalizedLocalName != normalizedGlobalName {
            return true
        }

        return localProfile.isMe != recognizedVoice.isMe
    }

    func updateSpeakerDisplayName(_ displayName: String, for speakerID: String) {
        guard var profile = storedSpeakerProfile(for: speakerID) else {
            return
        }

        profile.displayName = displayName
        persistSpeakerProfile(profile, syncGlobalVoice: true)
    }

    func setSpeakerIsMe(_ isMe: Bool, for speakerID: String) {
        guard var profile = storedSpeakerProfile(for: speakerID) else {
            return
        }

        profile.isMe = isMe
        persistSpeakerProfile(profile, syncGlobalVoice: true)
    }

    func setSpeakerRecognizedVoiceID(_ recognizedVoiceID: UUID?, for speakerID: String) {
        guard var profile = storedSpeakerProfile(for: speakerID) else {
            return
        }

        profile.recognizedVoiceID = recognizedVoiceID

        if let recognizedVoiceID,
           let recognizedVoice = recognizedVoicesByID[recognizedVoiceID] {
            let recognizedVoiceName = normalizedDisplayName(recognizedVoice.displayName)
            if recognizedVoiceName.isEmpty == false {
                profile.displayName = recognizedVoiceName
            }
            profile.isMe = recognizedVoice.isMe
        }

        persistSpeakerProfile(profile)
    }

    func pushSpeakerProfileToGlobalVoice(for speakerID: String) {
        guard let profile = storedSpeakerProfile(for: speakerID) else {
            return
        }

        do {
            guard let updatedRecognizedVoice = try updateGlobalVoiceProfile(
                globalVoiceUpdateProfile(for: profile)
            ) else {
                return
            }

            recognizedVoicesByID[updatedRecognizedVoice.id] = updatedRecognizedVoice
            notifyRecognizedVoicesDidChange()
        } catch {
            errorMessage = "Could not update the global voice print."
        }
    }

    func audioURL(for entry: TranscriptionLabEntry) -> URL {
        audioURLForEntry(entry)
    }

    func reloadEntries() {
        do {
            let loadedEntries = try loadEntries().sorted { $0.createdAt > $1.createdAt }
            originalStageTimingsByEntryID = try loadStageTimings()
            recognizedVoicesByID = Dictionary(
                uniqueKeysWithValues: try loadRecognizedVoices().map { ($0.id, $0) }
            )
            entries = loadedEntries

            if let selectedEntryID,
               loadedEntries.contains(where: { $0.id == selectedEntryID }) {
                loadSelectedEntrySpeakerProfiles()
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
            speakerProfiles = []
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
            speakerProfiles = []
            latestCleanupTranscript = nil
            originalStageTimingsByEntryID = [:]
            recognizedVoicesByID = [:]
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
        loadSelectedEntrySpeakerProfiles()
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
        speakerProfiles = []
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
        speakerProfiles = []
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
            speakerProfiles = result.speakerProfiles
            reloadRecognizedVoices()
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

    func rerunDiarization() async {
        guard selectedEntry != nil else {
            errorMessage = "Choose a saved recording first."
            return
        }

        guard selectedSpeechModelSupportsSpeakerTagging else {
            errorMessage = "Speaker tagging is available only for FluidAudio models."
            return
        }

        if !usesSpeakerTagging {
            usesSpeakerTagging = true
        }

        await rerunTranscription()
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

    private func loadSelectedEntrySpeakerProfiles() {
        guard let selectedEntryID else {
            speakerProfiles = []
            return
        }

        reloadRecognizedVoices()

        do {
            speakerProfiles = try loadSpeakerProfiles(selectedEntryID)
        } catch {
            speakerProfiles = []
            errorMessage = "Could not load speaker identities for this recording."
        }
    }

    private func reloadRecognizedVoices() {
        do {
            recognizedVoicesByID = Dictionary(
                uniqueKeysWithValues: try loadRecognizedVoices().map { ($0.id, $0) }
            )
        } catch {
            recognizedVoicesByID = [:]
        }
    }

    private func persistSpeakerProfile(
        _ profile: TranscriptionLabSpeakerProfile,
        syncGlobalVoice: Bool = false
    ) {
        do {
            try saveSpeakerProfile(profile)
            speakerProfiles = replacingSpeakerProfile(profile)
        } catch {
            errorMessage = "Could not save the speaker identity."
            return
        }

        guard syncGlobalVoice else {
            return
        }

        do {
            guard let updatedRecognizedVoice = try updateGlobalVoiceProfile(
                globalVoiceUpdateProfile(for: profile)
            ) else {
                return
            }

            recognizedVoicesByID[updatedRecognizedVoice.id] = updatedRecognizedVoice
            notifyRecognizedVoicesDidChange()
        } catch {
            errorMessage = "Could not update the global voice print."
        }
    }

    private func replacingSpeakerProfile(
        _ updatedProfile: TranscriptionLabSpeakerProfile
    ) -> [TranscriptionLabSpeakerProfile] {
        var updatedProfiles = speakerProfiles.filter { $0.speakerID != updatedProfile.speakerID }
        updatedProfiles.append(updatedProfile)

        let orderedSpeakerIDs = diarizationVisualization?.speakerIDsInDisplayOrder ?? speakerProfiles.map(\.speakerID)
        return updatedProfiles.sorted { lhs, rhs in
            let lhsIndex = orderedSpeakerIDs.firstIndex(of: lhs.speakerID) ?? Int.max
            let rhsIndex = orderedSpeakerIDs.firstIndex(of: rhs.speakerID) ?? Int.max

            if lhsIndex == rhsIndex {
                return lhs.speakerID.localizedStandardCompare(rhs.speakerID) == .orderedAscending
            }

            return lhsIndex < rhsIndex
        }
    }

    private func recognizedVoice(
        for localProfile: TranscriptionLabSpeakerProfile
    ) -> RecognizedVoiceProfile? {
        guard let recognizedVoiceID = localProfile.recognizedVoiceID else {
            return nil
        }

        return recognizedVoicesByID[recognizedVoiceID]
    }

    private func transcriptIncludedSpeakerIDs(for summary: DiarizationSummary) -> Set<String> {
        let allSpeakerIDs = Set(summary.spans.map(\.speakerID))

        guard summary.usedFallback == false else {
            return allSpeakerIDs
        }

        let keptSpeakerIDs = Set(summary.spans.filter(\.isKept).map(\.speakerID))
        guard
            let targetSpeakerID = summary.targetSpeakerID,
            let targetProfile = effectiveSpeakerProfile(for: targetSpeakerID)
        else {
            return keptSpeakerIDs
        }

        let matchingSpeakerIDs = allSpeakerIDs.filter { speakerID in
            guard let profile = effectiveSpeakerProfile(for: speakerID) else {
                return speakerID == targetSpeakerID
            }

            return speakerProfile(profile, matchesTranscriptIdentityOf: targetProfile)
        }

        return keptSpeakerIDs.union(matchingSpeakerIDs)
    }

    private func speakerProfile(
        _ profile: TranscriptionLabSpeakerProfile,
        matchesTranscriptIdentityOf targetProfile: TranscriptionLabSpeakerProfile
    ) -> Bool {
        if profile.speakerID == targetProfile.speakerID {
            return true
        }

        if let targetRecognizedVoiceID = targetProfile.recognizedVoiceID,
           profile.recognizedVoiceID == targetRecognizedVoiceID {
            return true
        }

        return targetProfile.isMe && profile.isMe
    }

    private func mergedSpeakerProfile(
        _ localProfile: TranscriptionLabSpeakerProfile
    ) -> TranscriptionLabSpeakerProfile {
        guard let recognizedVoice = recognizedVoice(for: localProfile) else {
            return localProfile
        }

        var mergedProfile = localProfile
        let normalizedGlobalName = normalizedDisplayName(recognizedVoice.displayName)
        if normalizedGlobalName.isEmpty == false {
            mergedProfile.displayName = normalizedGlobalName
        }

        mergedProfile.isMe = recognizedVoice.isMe

        return mergedProfile
    }

    private func globalVoiceUpdateProfile(
        for localProfile: TranscriptionLabSpeakerProfile
    ) -> TranscriptionLabSpeakerProfile {
        var updateProfile = localProfile

        if let recognizedVoice = recognizedVoice(for: localProfile) {
            let normalizedEvidenceTranscript = recognizedVoice.evidenceTranscript.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if normalizedEvidenceTranscript.isEmpty == false {
                updateProfile.evidenceTranscript = normalizedEvidenceTranscript
            }
        }

        return updateProfile
    }

    private func normalizedDisplayName(_ displayName: String) -> String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.1fs", duration)
    }
}
