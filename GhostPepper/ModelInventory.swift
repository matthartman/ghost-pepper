import Foundation

enum RuntimeModelStatus: Equatable {
    case notLoaded
    case loading
    case downloading(progress: Double?)
    case loaded
}

struct RuntimeModelRow: Identifiable, Equatable {
    let id: String
    let name: String
    let sizeDescription: String
    let isSelected: Bool
    let status: RuntimeModelStatus
}

enum RuntimeModelInventory {
    static func rows(
        selectedSpeechModelName: String,
        activeSpeechModelName: String,
        speechModelState: ModelManagerState,
        cachedSpeechModelNames: Set<String>,
        cleanupState: CleanupModelState,
        loadedCleanupKinds: Set<LocalCleanupModelKind>
    ) -> [RuntimeModelRow] {
        let speechRows = ModelManager.availableModels.map { model in
            RuntimeModelRow(
                id: model.name,
                name: model.statusName,
                sizeDescription: model.sizeDescription,
                isSelected: model.name == selectedSpeechModelName,
                status: statusForSpeechModel(
                    named: model.name,
                    activeSpeechModelName: activeSpeechModelName,
                    speechModelState: speechModelState,
                    cachedSpeechModelNames: cachedSpeechModelNames
                )
            )
        }

        let cleanupRows = TextCleanupManager.cleanupModels.map { model in
            RuntimeModelRow(
                id: "cleanup-\(model.fileName)",
                name: model.displayName,
                sizeDescription: model.sizeDescription,
                isSelected: false,
                status: statusForCleanupModel(
                    kind: model.kind,
                    cleanupState: cleanupState,
                    loadedCleanupKinds: loadedCleanupKinds
                )
            )
        }

        return speechRows + cleanupRows
    }

    static func activeDownloadText(rows: [RuntimeModelRow]) -> String? {
        guard let row = rows.first(where: \.isDownloading) else {
            return nil
        }

        switch row.status {
        case .downloading(let progress?):
            let pct = Int(progress * 100)
            return "Downloading \(row.name) (\(pct)%)..."
        case .downloading(nil):
            return "Preparing \(row.name)..."
        case .loading, .loaded, .notLoaded:
            return nil
        }
    }

    static func hasMissingModels(rows: [RuntimeModelRow]) -> Bool {
        rows.contains { $0.status != .loaded }
    }

    private static func statusForSpeechModel(
        named modelName: String,
        activeSpeechModelName: String,
        speechModelState: ModelManagerState,
        cachedSpeechModelNames: Set<String>
    ) -> RuntimeModelStatus {
        if speechModelState == .loading && modelName == activeSpeechModelName {
            return cachedSpeechModelNames.contains(modelName) ? .loading : .downloading(progress: nil)
        }

        return cachedSpeechModelNames.contains(modelName) ? .loaded : .notLoaded
    }

    private static func statusForCleanupModel(
        kind: LocalCleanupModelKind,
        cleanupState: CleanupModelState,
        loadedCleanupKinds: Set<LocalCleanupModelKind>
    ) -> RuntimeModelStatus {
        if case let .downloading(activeKind, progress) = cleanupState, activeKind == kind {
            return .downloading(progress: progress)
        }

        if cleanupState == .loadingModel, let loadingKind = loadingCleanupKind(loadedCleanupKinds: loadedCleanupKinds), loadingKind == kind {
            return .downloading(progress: nil)
        }

        if loadedCleanupKinds.contains(kind) {
            return .loaded
        }

        return .notLoaded
    }

    private static func loadingCleanupKind(loadedCleanupKinds: Set<LocalCleanupModelKind>) -> LocalCleanupModelKind? {
        if !loadedCleanupKinds.contains(.fast) {
            return .fast
        }

        if !loadedCleanupKinds.contains(.full) {
            return .full
        }

        return nil
    }
}

private extension RuntimeModelRow {
    var isDownloading: Bool {
        if case .downloading = status {
            return true
        }
        return false
    }
}
