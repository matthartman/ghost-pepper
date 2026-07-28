import Foundation

enum ChordAction: String, CaseIterable, Codable {
    case pushToTalk
    case toggleToTalk
    case pepperChat
    case copyLastVocalRecording
    case openHistory

    /// One-shot actions fire once on key-down rather than tracking a hold (start/stop).
    var isSimpleAction: Bool {
        switch self {
        case .copyLastVocalRecording, .openHistory:
            return true
        case .pushToTalk, .toggleToTalk, .pepperChat:
            return false
        }
    }
}
