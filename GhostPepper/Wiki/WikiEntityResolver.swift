import Foundation

/// Deterministic entity resolution: maps a raw name mention to an existing
/// canonical entry, flags genuine ambiguity for LLM adjudication, or calls
/// it new. Pure functions — no IO, no model — so the rules are unit-testable
/// and auditable. The engine only spends an LLM call on `.ambiguous`.
enum WikiEntityResolver {
    enum Resolution: Equatable {
        case matched(String)
        case ambiguous([String])
        case new
    }

    /// `snapshot` is `[canonicalName: [aliases]]` (the same shape
    /// `IndexManifest.aliasSnapshot` produces).
    static func resolve(name: String, snapshot: [String: [String]]) -> Resolution {
        let needle = normalize(name)
        guard !needle.isEmpty else { return .new }

        // 1. Exact canonical or alias match.
        var exact: [String] = []
        for (canonical, aliases) in snapshot {
            if normalize(canonical) == needle || aliases.contains(where: { normalize($0) == needle }) {
                exact.append(canonical)
            }
        }
        if exact.count == 1 { return .matched(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact.sorted()) }

        // 2. Token containment: "Alpha" ⊂ "Alpha Person", "Alpha Person" ⊃ "Alpha".
        let needleTokens = Set(needle.split(separator: " ").map(String.init))
        var containment: [String] = []
        for (canonical, aliases) in snapshot {
            let canonicalTokens = Set(normalize(canonical).split(separator: " ").map(String.init))
            let aliasTokenSets = aliases.map { Set(normalize($0).split(separator: " ").map(String.init)) }
            let allSets = [canonicalTokens] + aliasTokenSets
            let hit = allSets.contains { tokens in
                !tokens.isEmpty && !needleTokens.isEmpty &&
                (needleTokens.isSubset(of: tokens) || tokens.isSubset(of: needleTokens))
            }
            if hit { containment.append(canonical) }
        }
        if containment.count == 1 { return .matched(containment[0]) }
        if containment.count > 1 { return .ambiguous(containment.sorted()) }

        // 3. Small typos: full-string edit distance ≤ 2 on names long enough
        //    for that to be meaningful.
        if needle.count >= 6 {
            var close: [String] = []
            for canonical in snapshot.keys {
                let candidate = normalize(canonical)
                if abs(candidate.count - needle.count) <= 2, editDistance(needle, candidate) <= 2 {
                    close.append(canonical)
                }
            }
            if close.count == 1 { return .matched(close[0]) }
            if close.count > 1 { return .ambiguous(close.sorted()) }
        }

        return .new
    }

    /// Lowercase, diacritics stripped, punctuation removed, whitespace collapsed.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let filtered = folded.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        let collapsed = String(filtered)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed
    }

    /// Classic Levenshtein distance.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }
}
