import SwiftUI
import AppKit

final class PromptEditorController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(appState: AppState) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let editor = PromptEditorView(appState: appState, onClose: { [weak self] in
            self?.dismiss()
        })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit Cleanup Prompt"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: editor)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func dismiss() {
        if let window {
            hide(window)
        }
    }

    func shutdown() {
        guard let window else { return }
        window.delegate = nil
        window.makeFirstResponder(nil)
        window.contentViewController = nil
        window.orderOut(nil)
        self.window = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide(sender)
        return false
    }

    private func hide(_ window: NSWindow) {
        window.makeFirstResponder(nil)
        window.orderOut(nil)
    }
}

final class CleanupTranscriptWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hostingController: NSHostingController<CleanupTranscriptView>?

    func show(transcript: TranscriptionLabCleanupTranscript) {
        let contentView = CleanupTranscriptView(transcript: transcript, onClose: { [weak self] in
            self?.dismiss()
        })

        if let hostingController {
            hostingController.rootView = contentView
        } else {
            hostingController = NSHostingController(rootView: contentView)
        }

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cleanup Transcript"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func dismiss() {
        if let window {
            hide(window)
        }
    }

    func shutdown() {
        guard let window else { return }
        window.delegate = nil
        window.makeFirstResponder(nil)
        window.contentViewController = nil
        window.orderOut(nil)
        self.window = nil
        hostingController = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide(sender)
        return false
    }

    private func hide(_ window: NSWindow) {
        window.makeFirstResponder(nil)
        window.orderOut(nil)
    }
}

struct PromptEditorView: View {
    @ObservedObject var appState: AppState
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleanup Prompt")
                .font(.headline)

            Text("This prompt is sent to the local LLM to clean up your transcribed speech.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $appState.cleanupPrompt)
                .font(.body)
                .frame(minHeight: 250)

            HStack {
                Button("Reset to Default") {
                    appState.cleanupPrompt = TextCleaner.defaultPrompt
                }

                Spacer()

                Button("Done") {
                    onClose()
                }
                .keyboardShortcut(.return)
            }
        }
        .padding()
        .frame(minWidth: 450, minHeight: 350)
    }
}

private struct CleanupTranscriptView: View {
    let transcript: TranscriptionLabCleanupTranscript
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Cleanup Transcript")
                    .font(.headline)

                Text("This shows the exact content sent to the cleanup model for the current lab rerun and the exact raw text it returned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                transcriptSection(
                    title: "Sent to cleanup model",
                    text: """
                    System prompt:
                    \(transcript.prompt)

                    \(transcript.inputText)
                    """
                )

                transcriptSection(
                    title: "Returned by cleanup model",
                    text: transcript.rawModelOutput ?? "Cleanup fell back because the selected model was unavailable or returned no usable output."
                )

                HStack {
                    Spacer()

                    Button("Done") {
                        onClose()
                    }
                    .keyboardShortcut(.return)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 700, minHeight: 560)
    }

    private func transcriptSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))

            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
