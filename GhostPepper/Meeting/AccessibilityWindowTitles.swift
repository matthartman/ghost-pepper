import AppKit
import Foundation

enum AccessibilityWindowTitles {
    static func all(for app: NSRunningApplication) -> [String] {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return []
        }

        return windows.compactMap { window in
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String, !title.isEmpty else {
                return nil
            }
            return title
        }
    }
}
