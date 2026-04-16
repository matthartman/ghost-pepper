import AppKit
import Foundation

/// Orchestrates a single meeting transcription session.
/// Owns DualStreamCapture + ChunkedTranscriptionPipeline + MeetingTranscript.
@MainActor
final class MeetingSession: ObservableObject {
    @Published var isActive = false
    @Published var fileURL: URL?
    @Published var noAudioDetected = false

    @Published var transcript: MeetingTranscript

    private let capture = DualStreamCapture()
    private var pipeline: ChunkedTranscriptionPipeline?
    private let transcriber: SpeechTranscriber
    private let saveDirectory: URL

    /// How often to auto-save the markdown file (matches chunk interval).
    private var autoSaveTimer: Timer?
    private var silenceCheckTimer: Timer?
    private var hasReceivedAudio = false
    private var hasAutoUpdatedTitle = false
    private let originalName: String
    private let ocrService: FrontmostWindowOCRService

    init(
        meetingName: String,
        transcriber: SpeechTranscriber,
        saveDirectory: URL,
        ocrService: FrontmostWindowOCRService = FrontmostWindowOCRService()
    ) {
        self.transcript = MeetingTranscript(meetingName: meetingName)
        self.transcriber = transcriber
        self.saveDirectory = saveDirectory
        self.originalName = meetingName
        self.ocrService = ocrService
    }

    /// Start dual-stream capture and chunked transcription.
    func start() async throws {
        guard !isActive else { return }

        let chunkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostPepper")
            .appendingPathComponent("meeting-\(transcript.sessionID.uuidString)")
            .appendingPathComponent("chunks")

        let newPipeline = ChunkedTranscriptionPipeline(
            transcriber: transcriber,
            chunkDirectory: chunkDir
        )

        newPipeline.onSegmentTranscribed = { [weak self] result in
            guard let self = self else { return }
            let speaker: SpeakerLabel = result.source == .mic ? .me : .remote(name: nil)
            let segment = TranscriptSegment(
                id: UUID(),
                speaker: speaker,
                startTime: result.startTime,
                endTime: result.endTime,
                text: result.text
            )
            self.transcript.appendSegment(segment)
            self.autoSave()
        }

        capture.onAudioChunk = { [weak self, weak newPipeline] chunk in
            newPipeline?.appendAudio(chunk)
            if let self = self, !self.hasReceivedAudio {
                // Check if chunk has actual audio (not silence)
                let rms = sqrt(chunk.samples.map { $0 * $0 }.reduce(0, +) / max(Float(chunk.samples.count), 1))
                if rms > 0.001 {
                    Task { @MainActor in
                        self.hasReceivedAudio = true
                        self.noAudioDetected = false
                        self.silenceCheckTimer?.invalidate()
                    }
                }
            }
        }

        pipeline = newPipeline

        try await capture.start()
        newPipeline.start()
        isActive = true

        // Initial save creates the file immediately.
        autoSave()

        // Check for silence after 10 seconds — if no audio detected, warn the user.
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isActive, !self.hasReceivedAudio else { return }
                self.noAudioDetected = true
                print("MeetingSession: no audio detected after 10 seconds")
            }
        }

        // Try to auto-update title and grab attendees after a short delay
        // (gives the meeting app time to update its window title and show participants)
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.autoUpdateTitleFromFrontmostWindow()
                await self?.captureAttendees()
            }
        }

        print("MeetingSession: started '\(transcript.meetingName)'")
    }

    /// Stop capture, process remaining audio, finalize transcript.
    func stop() async {
        guard isActive else { return }
        isActive = false

        pipeline?.stop()
        _ = await capture.stop()

        transcript.endDate = Date()

        // Final save with end date.
        autoSave()

        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        silenceCheckTimer?.invalidate()
        silenceCheckTimer = nil

        print("MeetingSession: stopped '\(transcript.meetingName)' — \(transcript.segments.count) segments, \(transcript.formattedDuration)")
    }

    /// Cancels capture and timers immediately without processing remaining audio.
    func terminateImmediately() {
        guard isActive else { return }
        isActive = false

        pipeline?.cancel()
        capture.cancelImmediately()
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        silenceCheckTimer?.invalidate()
        silenceCheckTimer = nil
        transcript.endDate = Date()
    }

    /// Elapsed time since meeting started.
    var elapsed: TimeInterval {
        capture.elapsed
    }

    // MARK: - Auto-update title

    /// One-time attempt to update the meeting title from the frontmost window.
    /// Only updates if the user hasn't manually changed the name.
    private func autoUpdateTitleFromFrontmostWindow() {
        guard !hasAutoUpdatedTitle, isActive else { return }
        // Only update if user hasn't edited the name
        guard transcript.meetingName == originalName else { return }
        hasAutoUpdatedTitle = true

        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontmost.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return }

        // Collect all window titles
        var titles: [String] = []
        for window in windows {
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String, !title.isEmpty {
                titles.append(title)
            }
        }

        // Find the best title — skip generic ones
        let generic: Set<String> = [
            "zoom", "zoom meeting", "microsoft teams", "teams",
            "facetime", "webex", "slack", "discord", ""
        ]

        for title in titles {
            let cleaned = title
                .replacingOccurrences(of: " | Microsoft Teams", with: "")
                .replacingOccurrences(of: " - Microsoft Teams", with: "")
                .replacingOccurrences(of: " – Microsoft Teams", with: "")
                .replacingOccurrences(of: " - Zoom", with: "")
                .replacingOccurrences(of: " | Zoom", with: "")
                .replacingOccurrences(of: " - Cisco Webex", with: "")
                .replacingOccurrences(of: " | Slack", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !generic.contains(cleaned.lowercased()) && !cleaned.isEmpty {
                transcript.meetingName = cleaned
                print("MeetingSession: auto-updated title to '\(cleaned)'")
                autoSave()
                return
            }
        }
    }

    // MARK: - Attendee capture

    /// One-time OCR of the meeting window to extract participant names.
    private func captureAttendees() async {
        guard isActive, transcript.attendees.isEmpty else { return }

        guard let context = await ocrService.captureContext(customWords: []) else { return }
        let text = context.windowContents

        let names = Self.extractAttendeeNames(from: text)
        if !names.isEmpty {
            transcript.attendees = names
            print("MeetingSession: captured attendees: \(names.joined(separator: ", "))")
            autoSave()
        }
    }

    /// Parse attendee names from OCR text of a meeting window.
    /// Zoom shows names as labels on video tiles, Teams shows them in participant panels.
    /// Heuristic: look for lines that look like person names (2-3 capitalized words, no special chars).
    static func extractAttendeeNames(from ocrText: String) -> [String] {
        let lines = ocrText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var names: [String] = []
        let namePattern = /^[A-Z][a-zA-Z'-]+(?:\s[A-Z][a-zA-Z'-]+){0,3}$/

        // Words that indicate a line is UI text, not a person's name
        let uiWords: Set<String> = [
            "mute", "unmute", "share", "screen", "chat", "record", "recording",
            "participants", "leave", "end", "meeting", "settings", "audio",
            "video", "gallery", "speaker", "view", "reactions", "more",
            "invite", "security", "breakout", "rooms", "host", "co-host",
            "waiting", "room", "zoom", "teams", "join", "start", "stop",
            "raise", "hand", "rename", "remove", "admit", "close", "minimize",
        ]

        for line in lines {
            // Skip single words (likely UI elements)
            let words = line.split(separator: " ")
            guard words.count >= 2, words.count <= 4 else { continue }

            // Skip lines with UI keywords
            let lower = line.lowercased()
            if uiWords.contains(where: { lower.contains($0) }) { continue }

            // Skip lines with numbers, special chars (timestamps, IDs, etc.)
            if line.contains(where: { $0.isNumber }) { continue }
            if line.contains("@") || line.contains("http") || line.contains("://") { continue }

            // Match name pattern: capitalized words
            if line.wholeMatch(of: namePattern) != nil {
                // Skip "(You)" or "(Host)" suffixes
                let cleaned = line
                    .replacingOccurrences(of: "(You)", with: "")
                    .replacingOccurrences(of: "(Host)", with: "")
                    .replacingOccurrences(of: "(Co-host)", with: "")
                    .replacingOccurrences(of: "(Guest)", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !cleaned.isEmpty && !names.contains(cleaned) {
                    names.append(cleaned)
                }
            }
        }

        return names
    }

    // MARK: - Auto-save

    private func autoSave() {
        do {
            let url = try MeetingMarkdownWriter.write(
                transcript: transcript,
                to: saveDirectory,
                existingFileURL: fileURL
            )
            if fileURL == nil {
                fileURL = url
                print("MeetingSession: transcript file created at \(url.path)")
            }
        } catch {
            print("MeetingSession: failed to save transcript — \(error.localizedDescription)")
        }
    }
}
