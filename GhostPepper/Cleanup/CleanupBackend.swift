import Foundation

protocol CleanupBackend: AnyObject {
    func clean(text: String, prompt: String) async throws -> String
}

enum CleanupBackendError: Error, Equatable {
    case unavailable
}
