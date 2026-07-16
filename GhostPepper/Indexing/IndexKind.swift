import Foundation

/// Identifies a wiki/index kind ("people", "companies", …).
///
/// Formerly a one-case enum; now a string-backed struct so wiki kinds can be
/// created at runtime and persisted in `WikiKindStore` (`.indexes/_kinds.json`).
/// On-disk encodings are unchanged from the enum days: dossier frontmatter
/// still says `index_type: people` and manifests still say `"kind": "people"`
/// — the custom Codable below encodes the bare raw string, exactly like
/// `String`-backed enums do.
struct IndexKind: RawRepresentable, Hashable, Identifiable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var id: String { rawValue }

    /// The built-in People wiki. Always present in the registry.
    static let people = IndexKind(rawValue: "people")

    /// Display metadata comes from the registry; unknown slugs get a
    /// capitalized-slug fallback so entries from removed kinds still render.
    var spec: WikiKindSpec { WikiKindStore.shared.spec(for: rawValue) }

    var displayName: String { spec.displayName }

    var iconSystemName: String { spec.iconSystemName }

    /// Subdirectory name under `<save dir>/.indexes/`.
    var subdirectory: String { rawValue }
}

extension IndexKind: CaseIterable {
    /// All kinds known to the registry, People first. Dynamic — reflects
    /// custom wikis the user has approved in the current archive.
    static var allCases: [IndexKind] {
        WikiKindStore.shared.allKinds.map { IndexKind(rawValue: $0.slug) }
    }
}

extension IndexKind: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
