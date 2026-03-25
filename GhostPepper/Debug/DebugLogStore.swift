import Foundation
import Combine

enum DebugLogCategory: String {
    case hotkey = "Hotkey"
    case ocr = "OCR"
    case cleanup = "Cleanup"
    case model = "Model"
}

struct DebugLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let category: DebugLogCategory
    let message: String
}

final class DebugLogStore: ObservableObject {
    @Published private(set) var entries: [DebugLogEntry] = []

    private let maxEntries: Int
    private let formatter: DateFormatter
    private var liveViewerCount = 0

    init(maxEntries: Int = 250) {
        self.maxEntries = maxEntries
        self.formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
    }

    var formattedText: String {
        entries.map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.category.rawValue)] \(entry.message)"
        }
        .joined(separator: "\n\n")
    }

    func record(category: DebugLogCategory, message: String) {
        entries.append(
            DebugLogEntry(
                timestamp: Date(),
                category: category,
                message: message
            )
        )

        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func beginLiveViewing() {
        liveViewerCount += 1
    }

    func endLiveViewing() {
        liveViewerCount = max(0, liveViewerCount - 1)
    }

    func recordSensitive(category: DebugLogCategory, message: String) {
        guard liveViewerCount > 0 else {
            return
        }

        record(category: category, message: message)
    }

    func clear() {
        entries.removeAll()
    }
}
