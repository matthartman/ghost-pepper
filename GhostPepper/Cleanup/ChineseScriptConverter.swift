import Foundation

/// User preference for Chinese-character output. Default `auto` is a no-op
/// so existing behavior is unchanged.
enum ChineseScriptPreference: String, CaseIterable, Identifiable {
    case auto
    case simplified
    case traditional

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto (no conversion)"
        case .simplified: "Simplified (简体)"
        case .traditional: "Traditional (繁體)"
        }
    }
}

/// Converts Chinese characters between Simplified and Traditional variants
/// using Apple's ICU-backed `CFStringTransform`.
enum ChineseScriptConverter {
    /// Returns `text` converted to the target script, or `text` unchanged when
    /// the preference is `.auto` or the transform fails.
    static func convert(_ text: String, to preference: ChineseScriptPreference) -> String {
        guard preference != .auto else { return text }
        let mutable = NSMutableString(string: text)
        let identifier: CFString = preference == .simplified
            ? "Traditional-Simplified" as CFString
            : "Simplified-Traditional" as CFString
        let didTransform = CFStringTransform(mutable, nil, identifier, false)
        return didTransform ? String(mutable) : text
    }
}
