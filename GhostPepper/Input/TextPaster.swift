import Cocoa
import ApplicationServices
import CoreGraphics

/// Represents a saved clipboard state, preserving all pasteboard items with all type representations.
struct ClipboardState {
    let data: [[(NSPasteboard.PasteboardType, Data)]]
}

enum PasteResult: Equatable {
    case pasted
    case copiedToClipboard
}

/// Pastes transcribed text into the focused text field by simulating Cmd+V.
/// Saves and restores the clipboard around the paste operation to avoid clobbering user data.
/// Requires Accessibility permission for CGEvent posting.
final class TextPaster {
    typealias PasteSessionProvider = @Sendable (String, Date) -> PasteSession?
    typealias PasteScheduler = (TimeInterval, @escaping () -> Void) -> Void

    // MARK: - Timing Constants

    /// Delay after writing text to clipboard before simulating Cmd+V.
    static let preKeystrokeDelay: TimeInterval = 0.05

    /// Delay after simulating Cmd+V before restoring the original clipboard.
    static let postKeystrokeDelay: TimeInterval = 0.1

    // MARK: - Virtual Key Codes

    private static let vKeyCode: CGKeyCode = 0x09
    var onPaste: ((PasteSession) -> Void)?
    var onPasteStart: (() -> Void)?
    var onPasteEnd: (() -> Void)?

    private let pasteSessionProvider: PasteSessionProvider
    private let pasteboard: NSPasteboard
    private let canPasteIntoFocusedElement: () -> Bool
    private let prepareCommandV: () -> (() -> Void)?
    private let schedule: PasteScheduler

    init(
        pasteboard: NSPasteboard = .general,
        canPasteIntoFocusedElement: @escaping () -> Bool = { TextPaster.defaultCanPasteIntoFocusedElement() },
        prepareCommandV: @escaping () -> (() -> Void)? = { TextPaster.defaultCommandVPasteAction() },
        pasteSessionProvider: @escaping PasteSessionProvider = { text, date in
            FocusedElementLocator().capturePasteSession(for: text, at: date)
        },
        schedule: @escaping PasteScheduler = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.pasteboard = pasteboard
        self.canPasteIntoFocusedElement = canPasteIntoFocusedElement
        self.prepareCommandV = prepareCommandV
        self.pasteSessionProvider = pasteSessionProvider
        self.schedule = schedule
    }

    // MARK: - Clipboard Operations

    /// Saves all pasteboard items with all their type representations.
    /// - Returns: A `ClipboardState` capturing the full clipboard contents, or `nil` if the clipboard is empty.
    func saveClipboard() -> ClipboardState? {
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
    func paste(text: String) -> PasteResult {
        onPasteStart?()
        let savedState = saveClipboard()

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard canPasteIntoFocusedElement(), let postCommandV = prepareCommandV() else {
            onPasteEnd?()
            return .copiedToClipboard
        }

        schedule(Self.preKeystrokeDelay) { [weak self] in
            postCommandV()

            self?.schedule(Self.postKeystrokeDelay) { [weak self] in
                guard let self else { return }

                if let pasteSession = self.pasteSessionProvider(text, Date()) {
                    self.onPaste?(pasteSession)
                }

                if let savedState = savedState {
                    self.restoreClipboard(savedState)
                }

                self.onPasteEnd?()
            }
        }

        return .pasted
    }

    // MARK: - Accessibility Preflight

    private static func defaultCanPasteIntoFocusedElement() -> Bool {
        guard PermissionChecker.checkAccessibility() else {
            return false
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        guard let focusedElement = axElementAttribute(kAXFocusedUIElementAttribute as CFString, on: systemWideElement) else {
            return false
        }

        guard boolAttribute(kAXEnabledAttribute as CFString, on: focusedElement) ?? true else {
            return false
        }

        if hasAttribute(kAXSelectedTextRangeAttribute as CFString, on: focusedElement) {
            return true
        }

        if isAttributeSettable(kAXValueAttribute as CFString, on: focusedElement) {
            return true
        }

        guard let role = stringAttribute(kAXRoleAttribute as CFString, on: focusedElement) else {
            return false
        }

        return role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
    }

    private static func axElementAttribute(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(_ attribute: CFString, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private static func boolAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? Bool
    }

    private static func hasAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute, &value) == .success
    }

    private static func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute, &isSettable) == .success else {
            return false
        }

        return isSettable.boolValue
    }

    // MARK: - Key Simulation

    private static func defaultCommandVPasteAction() -> (() -> Void)? {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false) else {
            return nil
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        return {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
