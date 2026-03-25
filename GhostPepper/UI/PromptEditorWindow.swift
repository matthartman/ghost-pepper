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
                .font(.system(.body, design: .monospaced))
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
