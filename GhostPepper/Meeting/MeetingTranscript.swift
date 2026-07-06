import Foundation

/// A person attending a meeting (from calendar invite or OCR-detected).
struct MeetingAttendee: Hashable, Codable {
    let name: String
    let declined: Bool

    init(name: String, declined: Bool = false) {
        self.name = name
        self.declined = declined
    }
}

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
    @Published var attendees: [MeetingAttendee]
    @Published var summary: String?
    @Published var isGeneratingSummary = false
    /// Saved article body for Reader entries. When non-nil, this entry is treated
    /// as a reader (Article + Notes tabs) instead of a meeting (Notes + Transcript + Summary).
    @Published var articleBody: String?
    var importedFrom: String?
    /// Optional source URL — used by Reader entries.
    var sourceURL: String?

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

    /// The transcript as flat, timestamped text: `[MM:SS] Speaker: text`, one line per segment.
    var plainText: String {
        segments
            .map { "[\($0.formattedTimestamp)] \($0.speaker.displayName): \($0.text)" }
            .joined(separator: "\n")
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
