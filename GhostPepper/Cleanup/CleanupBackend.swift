import Foundation

protocol CleanupBackend: AnyObject {
    func clean(text: String, prompt: String, modelKind: LocalCleanupModelKind?) async throws -> String
}

enum CleanupBackendError: Error, Equatable {
    case unavailable
    case unsupportedRuntime(String)
    case unusableOutput(rawOutput: String)
    case timedOut(seconds: TimeInterval)
}

extension CleanupBackendError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The selected local model is not available."
        case .unsupportedRuntime(let message):
            return message
        case .unusableOutput:
            return "The selected local model returned unusable output."
        case .timedOut(let seconds):
            return "The local model timed out after \(Int(seconds))s."
        }
    }
}
