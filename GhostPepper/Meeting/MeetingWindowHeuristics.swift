import Foundation

enum MeetingWindowHeuristics {
    static func bestAutoUpdateTitle(
        in titles: [String],
        appName: String,
        observedBundleIdentifier: String?,
        monitoredBundleIdentifier: String?
    ) -> String? {
        guard let monitoredBundleIdentifier else {
            return bestMeetingTitle(in: titles, appName: appName)
        }
        guard monitoredBundleIdentifier == observedBundleIdentifier else {
            return nil
        }
        return bestMeetingTitle(in: titles, appName: appName)
    }

    static func bestMeetingTitle(in titles: [String], appName: String) -> String? {
        for title in titles {
            let assessment = assess(title: title, appName: appName)
            if let title = assessment.title {
                return title
            }
        }
        return nil
    }

    static func indicatesActiveMeeting(in titles: [String], appName: String) -> Bool {
        titles.contains { assess(title: $0, appName: appName).isActive }
    }

    private static func assess(title rawTitle: String, appName: String) -> (isActive: Bool, title: String?) {
        let cleaned = cleanedTitle(from: rawTitle)
        let lowered = cleaned.lowercased()
        let appNameLowered = appName.lowercased()

        let inactiveTitles: Set<String> = [
            "",
            appNameLowered,
            "\(appNameLowered) workplace",
            "settings",
            "preferences",
            "home",
            "calendar",
            "chat",
            "mail",
            "contacts",
            "docs",
            "notes",
            "whiteboard",
            "phone",
            "voicemail",
            "tasks",
            "general",
            "audio",
            "video",
            "recording",
            "profile",
        ]

        if inactiveTitles.contains(lowered) {
            return (false, nil)
        }

        if lowered == "\(appNameLowered) meeting" || lowered == "meeting" {
            return (true, nil)
        }

        if appName == "Zoom" &&
            lowered.contains("participants") &&
            (lowered.contains("zoom") || rawTitle.contains("Participants")) {
            return (true, nil)
        }

        if cleaned.isEmpty {
            return (false, nil)
        }

        return (true, cleaned)
    }

    private static func cleanedTitle(from title: String) -> String {
        var result = title
            .replacingOccurrences(of: " | Microsoft Teams", with: "")
            .replacingOccurrences(of: " - Microsoft Teams", with: "")
            .replacingOccurrences(of: " – Microsoft Teams", with: "")
            .replacingOccurrences(of: " - Zoom", with: "")
            .replacingOccurrences(of: " | Zoom", with: "")
            .replacingOccurrences(of: " - Cisco Webex", with: "")
            .replacingOccurrences(of: " | Slack", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Clean Zoom-specific patterns: "Person's Zoom Meeting" → "Person's Meeting"
        if result.contains("Zoom Meeting") {
            result = result.replacingOccurrences(of: "'s Zoom Meeting", with: "'s Meeting")
                .replacingOccurrences(of: "Zoom Meeting", with: "Meeting")
        }

        return result
    }
}
