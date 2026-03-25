import Cocoa
import CoreGraphics

/// Represents a saved clipboard state, preserving all pasteboard items with all type representations.
struct ClipboardState {
    let data: [[(NSPasteboard.PasteboardType, Data)]]
}

/// Pastes transcribed text into the focused text field by simulating Cmd+V.
/// Saves and restores the clipboard around the paste operation to avoid clobbering user data.
/// Requires Accessibility permission for CGEvent posting.
final class TextPaster {
    typealias PasteSessionProvider = @Sendable (String, Date) -> PasteSession?

    // MARK: - Timing Constants

    /// Delay after writing text to clipboard before simulating Cmd+V.
    static let preKeystrokeDelay: TimeInterval = 0.05

    /// Delay after simulating Cmd+V before restoring the original clipboard.
    static let postKeystrokeDelay: TimeInterval = 0.1

    // MARK: - Virtual Key Codes

    private static let vKeyCode: CGKeyCode = 0x09
    var onPaste: ((PasteSession) -> Void)?

    private let pasteSessionProvider: PasteSessionProvider

    init(
        pasteSessionProvider: @escaping PasteSessionProvider = { text, date in
            FocusedElementLocator().capturePasteSession(for: text, at: date)
        }
    ) {
        self.pasteSessionProvider = pasteSessionProvider
    }

    // MARK: - Clipboard Operations

    /// Saves all pasteboard items with all their type representations.
    /// - Returns: A `ClipboardState` capturing the full clipboard contents, or `nil` if the clipboard is empty.
    func saveClipboard() -> ClipboardState? {
        let pasteboard = NSPasteboard.general
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return nil
        }

        var allItems: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in items {
            var itemData: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemData.append((type, data))
                }
            }
            if !itemData.isEmpty {
                allItems.append(itemData)
            }
        }

        return allItems.isEmpty ? nil : ClipboardState(data: allItems)
    }

    /// Restores a previously saved clipboard state.
    /// All `NSPasteboardItem` objects are collected first, then written in a single `writeObjects` call.
    /// - Parameter state: The clipboard state to restore.
    func restoreClipboard(_ state: ClipboardState) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var pasteboardItems: [NSPasteboardItem] = []
        for itemData in state.data {
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            pasteboardItems.append(item)
        }

        pasteboard.writeObjects(pasteboardItems)
    }

    // MARK: - Paste Flow

    /// Pastes the given text into the currently focused text field.
    ///
    /// Flow:
    /// 1. Save current clipboard
    /// 2. Write text to clipboard
    /// 3. After a short delay, simulate Cmd+V
    /// 4. After another delay, restore the original clipboard
    ///
    /// - Parameter text: The text to paste.
    func paste(text: String) {
        let savedState = saveClipboard()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.preKeystrokeDelay) { [weak self] in
            self?.simulateCmdV()

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.postKeystrokeDelay) { [weak self] in
                if let pasteSession = self?.pasteSessionProvider(text, Date()) {
                    self?.onPaste?(pasteSession)
                }

                if let savedState = savedState {
                    self?.restoreClipboard(savedState)
                }
            }
        }
    }

    // MARK: - Key Simulation

    /// Simulates a Cmd+V keystroke using CGEvent.
    private func simulateCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
