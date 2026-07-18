import Foundation

@MainActor
final class AirtableImporter: ObservableObject {
    enum SyncState: Equatable {
        case idle
        case syncing(currentTable: String?, completed: Int, total: Int)
        case done(tables: Int, records: Int, directory: URL)
        case error(String)
    }

    struct SyncSummary: Equatable {
        let tables: Int
        let records: Int
        let directory: URL
    }

    private struct TableSchema {
        let id: String
        let name: String
        let fields: [String]
    }

    @Published var state: SyncState = .idle

    static let apiTokenKeychainKey = "airtablePersonalAccessToken"
    private static let baseIDDefaultsKey = "airtableBaseID"

    @Published var apiToken: String = "" {
        didSet {
            guard !isLoadingStoredKey else { return }
            _ = KeychainHelper.set(apiToken, for: Self.apiTokenKeychainKey)
        }
    }

    private var didLoadStoredKey = false
    private var isLoadingStoredKey = false

    func loadStoredAPIKeyIfNeeded() {
        guard !didLoadStoredKey else { return }
        didLoadStoredKey = true
        isLoadingStoredKey = true
        apiToken = KeychainHelper.migrateUserDefaultsString(
            defaultsKey: Self.apiTokenKeychainKey,
            keychainKey: Self.apiTokenKeychainKey
        ) ?? ""
        isLoadingStoredKey = false
    }

    @Published var baseID: String = UserDefaults.standard.string(forKey: AirtableImporter.baseIDDefaultsKey) ?? "" {
        didSet { UserDefaults.standard.set(baseID, forKey: Self.baseIDDefaultsKey) }
    }

    var isConfigured: Bool {
        !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func sync(to rootDirectory: URL) async -> SyncSummary? {
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = baseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            state = .error("Airtable personal access token is required.")
            return nil
        }
        guard !base.isEmpty else {
            state = .error("Airtable base ID is required.")
            return nil
        }

        state = .syncing(currentTable: nil, completed: 0, total: 0)

        do {
            let (baseName, tables) = try await fetchBaseSchema(baseID: base, token: token)
            let directory = rootDirectory
                .appendingPathComponent("Airtable")
                .appendingPathComponent(Self.safeFilename(baseName.isEmpty ? base : baseName))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            var recordCount = 0
            for (index, table) in tables.enumerated() {
                state = .syncing(currentTable: table.name, completed: index, total: tables.count)
                let records = try await fetchRecords(baseID: base, tableID: table.id, token: token)
                recordCount += records.count

                let csv = Self.csv(records: records, preferredFields: table.fields)
                let fileURL = directory.appendingPathComponent("\(Self.safeFilename(table.name)).csv")
                try csv.write(to: fileURL, atomically: true, encoding: .utf8)
            }

            let summary = SyncSummary(tables: tables.count, records: recordCount, directory: directory)
            state = .done(tables: summary.tables, records: summary.records, directory: summary.directory)
            return summary
        } catch {
            state = .error(error.localizedDescription)
            return nil
        }
    }

    private func fetchBaseSchema(baseID: String, token: String) async throws -> (String, [TableSchema]) {
        guard let url = URL(string: "https://api.airtable.com/v0/meta/bases/\(baseID)/tables") else {
            throw AirtableError.invalidURL
        }

        let json = try await airtableJSON(url: url, token: token)
        let baseName = json["name"] as? String ?? baseID
        guard let tableItems = json["tables"] as? [[String: Any]] else {
            throw AirtableError.invalidResponse("Base schema did not include tables.")
        }

        let tables = tableItems.compactMap { item -> TableSchema? in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            let fields = (item["fields"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            return TableSchema(id: id, name: name, fields: fields)
        }
        return (baseName, tables)
    }

    private func fetchRecords(baseID: String, tableID: String, token: String) async throws -> [[String: Any]] {
        var records: [[String: Any]] = []
        var offset: String?

        repeat {
            var components = URLComponents(string: "https://api.airtable.com/v0/\(baseID)/\(tableID)")!
            var queryItems = [URLQueryItem(name: "pageSize", value: "100")]
            if let offset {
                queryItems.append(URLQueryItem(name: "offset", value: offset))
            }
            components.queryItems = queryItems

            guard let url = components.url else { throw AirtableError.invalidURL }
            let json = try await airtableJSON(url: url, token: token)
            records.append(contentsOf: (json["records"] as? [[String: Any]]) ?? [])
            offset = json["offset"] as? String
        } while offset != nil

        return records
    }

    private func airtableJSON(url: URL, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AirtableError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AirtableError.invalidResponse("Airtable returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AirtableError.api(Self.apiErrorMessage(statusCode: http.statusCode, data: data, url: url))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AirtableError.invalidResponse("Airtable returned malformed JSON.")
        }
        return json
    }

    private static func apiErrorMessage(statusCode: Int, data: Data, url: URL) -> String {
        let body = String(data: data, encoding: .utf8) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        let type = error?["type"] as? String
        let message = error?["message"] as? String

        if statusCode == 403, type == "INVALID_PERMISSIONS_OR_MODEL_NOT_FOUND" {
            if url.path.contains("/meta/bases/") {
                return "Airtable rejected the base schema request. Check that the base ID starts with app, the token has access to that base, and the token includes the schema.bases:read scope."
            }
            return "Airtable rejected the records request. Check that the token has access to this base and includes the data.records:read scope."
        }

        if statusCode == 401 {
            return "Airtable rejected the token. Check that your personal access token is copied correctly and has not been revoked."
        }

        if let type, let message {
            return "Airtable API returned HTTP \(statusCode): \(type). \(message)"
        }
        return "Airtable API returned HTTP \(statusCode). \(body.prefix(240))"
    }

    private static func csv(records: [[String: Any]], preferredFields: [String]) -> String {
        var columns = ["id", "createdTime"] + preferredFields
        var seen = Set(columns)

        for record in records {
            guard let fields = record["fields"] as? [String: Any] else { continue }
            for key in fields.keys.sorted() where !seen.contains(key) {
                columns.append(key)
                seen.insert(key)
            }
        }

        var lines = [columns.map(escapeCSV).joined(separator: ",")]
        for record in records {
            let fields = record["fields"] as? [String: Any] ?? [:]
            let values = columns.map { column -> String in
                if column == "id" {
                    return escapeCSV(record["id"] as? String ?? "")
                }
                if column == "createdTime" {
                    return escapeCSV(record["createdTime"] as? String ?? "")
                }
                return escapeCSV(csvValue(fields[column]))
            }
            lines.append(values.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvValue(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if JSONSerialization.isValidJSONObject([value]),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "\(value)"
    }

    private static func escapeCSV(_ value: String) -> String {
        let needsQuotes = value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return needsQuotes ? "\"\(escaped)\"" : escaped
    }

    private static func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Airtable" : cleaned
    }
}

enum AirtableError: LocalizedError {
    case invalidURL
    case network(String)
    case api(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Could not build the Airtable API URL."
        case .network(let message):
            return "Airtable network error: \(message)"
        case .api(let message):
            return message
        case .invalidResponse(let message):
            return message
        }
    }
}
