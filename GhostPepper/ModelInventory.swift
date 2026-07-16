import Foundation

enum RuntimeModelStatus: Equatable {
    case notLoaded
    case loading
    case downloading(progress: Double?)
    case loaded
    case systemManaged
}

struct RuntimeModelRow: Identifiable, Equatable {
    let id: String
    let name: String
    let sizeDescription: String
    let isSelected: Bool
    let status: RuntimeModelStatus
    let allowsManualDownload: Bool
    let allowsDeletion: Bool
}

enum RuntimeModelInventory {
    static func rows(
        selectedSpeechModelName: String,
        activeSpeechModelName: String,
        speechModelState: ModelManagerState,
        speechDownloadProgress: Double?,
        cachedSpeechModelNames: Set<String>,
        cleanupState: CleanupModelState,
        selectedCleanupModelKind: LocalCleanupModelKind,
        selectedWikiModelKind: LocalCleanupModelKind? = nil,
        cachedCleanupKinds: Set<LocalCleanupModelKind>
    ) -> [RuntimeModelRow] {
        let speechRows = ModelManager.availableModels.map { model in
            RuntimeModelRow(
                id: model.name,
                name: model.statusName,
                sizeDescription: model.sizeDescription,
                isSelected: model.name == selectedSpeechModelName,
                status: statusForSpeechModel(
                    model: model,
                    activeSpeechModelName: activeSpeechModelName,
                    speechModelState: speechModelState,
                    speechDownloadProgress: speechDownloadProgress,
                    cachedSpeechModelNames: cachedSpeechModelNames
                ),
                allowsManualDownload: model.isSystemManaged == false,
                allowsDeletion: model.isSystemManaged == false
            )
        }

        let cleanupRows = TextCleanupManager.cleanupModels.map { model in
            RuntimeModelRow(
                id: "cleanup-\(model.fileName)",
                name: model.displayName,
                sizeDescription: model.sizeDescription,
                isSelected: model.kind == selectedCleanupModelKind || model.kind == selectedWikiModelKind,
                status: statusForCleanupModel(
                    kind: model.kind,
                    cleanupState: cleanupState,
                    cachedCleanupKinds: cachedCleanupKinds
                ),
                allowsManualDownload: true,
                allowsDeletion: true
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
        case .loading, .loaded, .notLoaded, .systemManaged:
            return nil
        }
    }

    private static func statusForSpeechModel(
        model: SpeechModelDescriptor,
        activeSpeechModelName: String,
        speechModelState: ModelManagerState,
        speechDownloadProgress: Double?,
        cachedSpeechModelNames: Set<String>
    ) -> RuntimeModelStatus {
        if speechModelState == .loading && model.name == activeSpeechModelName {
            if model.isSystemManaged {
                return .downloading(progress: speechDownloadProgress)
            }
            if cachedSpeechModelNames.contains(model.name) {
                return .loading
            }
            return .downloading(progress: speechDownloadProgress)
        }

        if model.isSystemManaged {
            return .systemManaged
        }
        return cachedSpeechModelNames.contains(model.name) ? .loaded : .notLoaded
    }

    private static func statusForCleanupModel(
        kind: LocalCleanupModelKind,
        cleanupState: CleanupModelState,
        cachedCleanupKinds: Set<LocalCleanupModelKind>
    ) -> RuntimeModelStatus {
        if case let .downloading(activeKind, progress) = cleanupState, activeKind == kind {
            return .downloading(progress: progress)
        }

        if case let .loadingModel(activeKind) = cleanupState, activeKind == kind {
            return .loading
        }

        if cachedCleanupKinds.contains(kind) {
            return .loaded
        }

        return .notLoaded
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
