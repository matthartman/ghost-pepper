import Foundation

final class LocalLLMCleanupBackend: CleanupBackend {
    private let cleanupManager: TextCleaningManaging

    init(cleanupManager: TextCleaningManaging) {
        self.cleanupManager = cleanupManager
    }

    func clean(text: String, prompt: String) async throws -> String {
        guard let cleaned = await cleanupManager.clean(text: text, prompt: prompt) else {
            throw CleanupBackendError.unavailable
        }

        return cleaned
    }
}
