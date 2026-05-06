import Foundation

struct RecordingOCRPrefetchResult {
    let context: OCRContext?
    let elapsed: TimeInterval
}

@MainActor
final class RecordingOCRPrefetch {
    typealias Capture = @Sendable ([String]) async -> OCRContext?

    private let capture: Capture
    private var task: Task<RecordingOCRPrefetchResult, Never>?
    private var activeTaskID: UUID?
    private var completedResult: RecordingOCRPrefetchResult?

    init(capture: @escaping Capture) {
        self.capture = capture
    }

    func start(customWords: [String]) {
        cancel()
        let taskID = UUID()
        activeTaskID = taskID
        task = Task { [capture] in
            let start = Date()
            let context = await capture(customWords)
            let result = RecordingOCRPrefetchResult(
                context: context,
                elapsed: Date().timeIntervalSince(start)
            )
            await MainActor.run { [weak self] in
                guard self?.activeTaskID == taskID else {
                    return
                }

                self?.completedResult = result
            }
            return result
        }
    }

    func resolve() async -> RecordingOCRPrefetchResult? {
        guard let task else {
            return nil
        }

        let result = await task.value
        clearResolvedTask()
        return result
    }

    func resolveIfCompleted() -> RecordingOCRPrefetchResult? {
        guard let completedResult else {
            cancel()
            return nil
        }

        clearResolvedTask()
        return completedResult
    }

    func cancel() {
        task?.cancel()
        clearResolvedTask()
    }

    private func clearResolvedTask() {
        task = nil
        activeTaskID = nil
        completedResult = nil
    }
}
