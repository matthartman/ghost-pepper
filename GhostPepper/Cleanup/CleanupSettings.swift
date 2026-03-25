import Foundation

enum CleanupBackendOption: String, CaseIterable, Identifiable {
    case localModels

    var id: String { rawValue }

    var title: String {
        "Local Models"
    }
}

enum LocalCleanupModelPolicy: String, CaseIterable, Identifiable {
    case automatic
    case fastOnly
    case fullOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .fastOnly:
            return "Fast model only"
        case .fullOnly:
            return "Full model only"
        }
    }
}
