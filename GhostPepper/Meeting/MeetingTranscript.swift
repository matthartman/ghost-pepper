import Foundation

/// Identifies who is speaking in a transcript segment.
enum SpeakerLabel: Codable, Equatable {
    case me
    case remote(name: String?)

    var displayName: String {
        switch self {
        case .me:
            return "Me"
        case .remote(let name):
            return name ?? "Others"
        }
    }
}

/// A single timestamped segment of transcribed speech.
struct TranscriptSegment: Codable, Identifiable {
    let id: UUID
    let speaker: SpeakerLabel
    let startTime: TimeInterval // seconds since meeting start
    let endTime: TimeInterval
    var text: String

    /// Formatted timestamp string like "02:15" or "1:02:15".
    var formattedTimestamp: String {
        let total = Int(startTime)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Observable model for a meeting transcript with notes and metadata.
@MainActor
final class MeetingTranscript: ObservableObject {
    @Published var meetingName: String
    @Published var startDate: Date
    @Published var endDate: Date?
    @Published var notes: String
    @Published var segments: [TranscriptSegment]
    @Published var attendees: [String]
    @Published var summary: String?
    @Published var isGeneratingSummary = false
    /// Set when the transcript has been auto-deleted by the expiry sweeper.
    /// Non-nil means `segments` is intentionally empty and the UI should show the deletion notice.
    @Published var transcriptExpiredDate: Date?
    /// User-controlled flag: when true, this meeting's transcript is eligible for the
    /// expiry sweeper (which still gates on the global retention window). Persisted as
    /// `auto_delete: true` in the markdown's YAML frontmatter.
    @Published var autoDeleteFlagged: Bool = false

    let sessionID: UUID

    init(
        meetingName: String,
        startDate: Date = Date(),
        sessionID: UUID = UUID()
    ) {
        self.meetingName = meetingName
        self.startDate = startDate
        self.sessionID = sessionID
        self.notes = ""
        self.segments = []
        self.attendees = []
    }

    func appendSegment(_ segment: TranscriptSegment) {
        segments.append(segment)
    }

    /// Duration of the meeting so far, in seconds.
    var duration: TimeInterval {
        let end = endDate ?? Date()
        return end.timeIntervalSince(startDate)
    }

    /// Formatted duration like "45m" or "1h 12m".
    var formattedDuration: String {
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
