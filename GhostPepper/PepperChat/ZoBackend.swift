import Foundation

struct ZoBackend: PepperChatBackend {
    let host: String
    let apiKey: String

    func send(prompt: String, screenContext: String?, onChunk: @escaping @MainActor (String) -> Void) async throws {
        guard !host.isEmpty, !apiKey.isEmpty else {
            throw PepperChatBackendError.notConfigured
        }

        let fullPrompt: String
        if let screenContext, !screenContext.isEmpty {
            fullPrompt = "\(prompt)\n\n[Screen context from frontmost window]\n\(screenContext)"
        } else {
            fullPrompt = prompt
        }

        // Try non-streaming first — simpler and more reliable
        guard let url = URL(string: "\(host)/zo/ask"),
              Self.isAllowedCredentialDestination(url) else {
            throw PepperChatBackendError.serverError("Zo host must use HTTPS unless it is localhost.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "input": fullPrompt,
            "model_name": "vercel:moonshotai/kimi-k2.5"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PepperChatBackendError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PepperChatBackendError.serverError("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = parsed["output"] as? String else {
            throw PepperChatBackendError.invalidResponse
        }

        await onChunk(output)
    }

    private static func isAllowedCredentialDestination(_ url: URL) -> Bool {
        if url.scheme == "https" { return true }
        guard url.scheme == "http", let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
