import Foundation

protocol PepperChatBackend {
    func send(prompt: String, screenContext: String?, onChunk: @escaping @MainActor (String) -> Void) async throws
}

enum PepperChatBackendError: LocalizedError {
    case notConfigured
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Context Bundler requires a Zo API key. Add one in Settings > Context Bundler."
        case .invalidResponse: "Received an invalid response from Zo."
        case .serverError(let message): "Zo error: \(message)"
        }
    }
}
