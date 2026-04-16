import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct FrontmostWindowReference: Equatable, Sendable {
    let windowID: UInt32
    let frame: CGRect
}

final class FocusedElementLocator {
    struct PasteTargetObservation: Equatable {
        enum Status: Equatable {
            case editable
            case nonEditable
        }

        let processID: pid_t
        let windowID: UInt32?
        let status: Status
    }

    fileprivate final class PasteTargetMonitor {
        private var activationObserver: NSObjectProtocol?
        private var axObserver: AXObserver?
        private var observedProcessID: pid_t?
        private var observation: PasteTargetObservation?
        private var isStarted = false

        func start() {
            guard !isStarted else {
                return
            }

            isStarted = true
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.syncFrontmostApplication()
            }
            syncFrontmostApplication()
        }

        func stop() {
            guard isStarted else {
                return
            }

            isStarted = false
            if let activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
                self.activationObserver = nil
            }
            uninstallObserver()
            clearObservation()
        }

        func syncFrontmostApplication() {
            guard let application = NSWorkspace.shared.frontmostApplication else {
                clearObservation()
                return
            }

            guard observedProcessID != application.processIdentifier else {
                return
            }

            uninstallObserver()
            observedProcessID = application.processIdentifier
            clearObservation()
            installObserver(for: application.processIdentifier)
        }

        func currentObservation() -> PasteTargetObservation? {
            observation
        }

        func recordDirectFocusedTarget(processID: pid_t, windowID: UInt32?) {
            observation = PasteTargetObservation(
                processID: processID,
                windowID: windowID,
                status: .editable
            )
        }

        fileprivate func handle(notification: CFString, element: AXUIElement) {
            guard let processID = observedProcessID else {
                return
            }

            let locator = FocusedElementLocator()
            let windowID = locator.frontmostWindowReference(for: processID)?.windowID
            let status: PasteTargetObservation.Status
            if locator.isObservedPasteTarget(element) {
                status = .editable
            } else if notification as String == kAXFocusedUIElementChangedNotification as String
                        || notification as String == kAXFocusedWindowChangedNotification as String {
                status = .nonEditable
            } else {
                return
            }

            observation = PasteTargetObservation(
                processID: processID,
                windowID: windowID,
                status: status
            )
        }

        private func clearObservation() {
            observation = nil
        }

        private func installObserver(for processID: pid_t) {
            let applicationElement = AXUIElementCreateApplication(processID)
            _ = AXUIElementSetAttributeValue(
                applicationElement,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            )

            var observer: AXObserver?
            let callback: AXObserverCallback = focusedElementObserverCallback
            guard AXObserverCreate(processID, callback, &observer) == .success,
                  let observer else {
                return
            }

            let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            let notifications = [
                kAXFocusedUIElementChangedNotification as CFString,
                kAXFocusedWindowChangedNotification as CFString
            ]

            for notification in notifications {
                _ = AXObserverAddNotification(observer, applicationElement, notification, context)
            }

            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
            axObserver = observer
        }

        private func uninstallObserver() {
            guard let axObserver else {
                observedProcessID = nil
                return
            }

            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(axObserver),
                .commonModes
            )
            self.axObserver = nil
            observedProcessID = nil
        }
    }

    private static let pasteTargetMonitor = PasteTargetMonitor()

    static func startPasteTargetTracking() {
        pasteTargetMonitor.start()
    }

    static func stopPasteTargetTracking() {
        pasteTargetMonitor.stop()
    }

    static func canPasteIntoObservedTarget(
        directFocusedTargetAvailable: Bool,
        hasDirectFocusedElement: Bool,
        observation: PasteTargetObservation?,
        processID: pid_t,
        windowID: UInt32?
    ) -> Bool {
        if directFocusedTargetAvailable {
            return true
        }

        if hasDirectFocusedElement {
            return false
        }

        guard let observation,
              observation.processID == processID,
              observation.windowID == windowID else {
            return false
        }

        return observation.status == .editable
    }

    static func firstAvailableText<Element>(
        startingAt element: Element,
        maxAncestorDepth: Int = 8,
        valueProvider: (Element) -> String?,
        fallbackTextProvider: (Element) -> String? = { _ in nil },
        parentProvider: (Element) -> Element?
    ) -> String? {
        var currentElement: Element? = element
        var remainingDepth = maxAncestorDepth

        while let element = currentElement {
            if let text = valueProvider(element)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }

            if let text = fallbackTextProvider(element)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }

            guard remainingDepth > 0 else {
                return nil
            }

            currentElement = parentProvider(element)
            remainingDepth -= 1
        }

        return nil
    }

    static func firstFocusedDescendant<Element>(
        startingAt element: Element,
        maxDepth: Int = 12,
        focusedProvider: (Element) -> Bool,
        childrenProvider: (Element) -> [Element]
    ) -> Element? {
        guard maxDepth >= 0 else {
            return nil
        }

        if focusedProvider(element) {
            return element
        }

        guard maxDepth > 0 else {
            return nil
        }

        for child in childrenProvider(element) {
            if let focusedElement = firstFocusedDescendant(
                startingAt: child,
                maxDepth: maxDepth - 1,
                focusedProvider: focusedProvider,
                childrenProvider: childrenProvider
            ) {
                return focusedElement
            }
        }

        return nil
    }

    func canPasteIntoFocusedElement() -> Bool {
        guard PermissionChecker.checkAccessibility(),
              let application = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        Self.pasteTargetMonitor.start()
        Self.pasteTargetMonitor.syncFrontmostApplication()

        let processID = application.processIdentifier
        let windowID = frontmostWindowReference(for: processID)?.windowID
        let directFocusedElement = focusedElement(for: processID)
        let directFocusedTargetAvailable = directFocusedElement
            .map(isObservedPasteTarget(_:)) ?? false

        if directFocusedTargetAvailable {
            Self.pasteTargetMonitor.recordDirectFocusedTarget(
                processID: processID,
                windowID: windowID
            )
        }

        return Self.canPasteIntoObservedTarget(
            directFocusedTargetAvailable: directFocusedTargetAvailable,
            hasDirectFocusedElement: directFocusedElement != nil,
            observation: Self.pasteTargetMonitor.currentObservation(),
            processID: processID,
            windowID: windowID
        )
    }

    func capturePasteSession(for text: String, at date: Date = Date()) -> PasteSession? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let windowReference = frontmostWindowReference(for: application.processIdentifier)
        let focusedElement = focusedElement(for: application.processIdentifier)
        return PasteSession(
            pastedText: text,
            pastedAt: date,
            frontmostAppBundleIdentifier: application.bundleIdentifier,
            frontmostWindowID: windowReference?.windowID,
            frontmostWindowFrame: windowReference?.frame,
            focusedElementFrame: focusedElement.flatMap(frame(for:)),
            focusedElementText: focusedElement.flatMap(text(for:))
        )
    }

    func frontmostApplicationBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func frontmostWindowReference() -> FrontmostWindowReference? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return frontmostWindowReference(for: application.processIdentifier)
    }

    func focusedElementFrame() -> CGRect? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return focusedElement(for: application.processIdentifier).flatMap(frame(for:))
    }

    func focusedElementText() -> String? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return focusedElement(for: application.processIdentifier).flatMap(text(for:))
    }

    private func focusedElement(for processID: pid_t) -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(processID)
        var focusedElementValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        ) == .success,
        let focusedElementValue,
        CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() {
            return unsafeBitCast(focusedElementValue, to: AXUIElement.self)
        }

        guard let focusedWindow = focusedWindow(for: applicationElement) else {
            return nil
        }

        return Self.firstFocusedDescendant(
            startingAt: focusedWindow,
            focusedProvider: { [weak self] in
                self?.isFocused($0) ?? false
            },
            childrenProvider: { [weak self] in
                self?.children(of: $0) ?? []
            }
        )
    }

    private func isObservedPasteTarget(_ element: AXUIElement) -> Bool {
        TextPaster.containsLikelyPasteTarget(
            startingAt: TextPaster.AccessibilitySnapshot(
                role: attributeValue(named: kAXRoleAttribute as String, of: element) as? String,
                isEnabled: attributeValue(named: kAXEnabledAttribute as String, of: element) as? Bool,
                isEditable: attributeValue(named: "AXEditable", of: element) as? Bool,
                isFocused: true,
                hasSelectedTextRange: attributeValue(
                    named: kAXSelectedTextRangeAttribute as String,
                    of: element
                ) != nil,
                valueIsSettable: isAttributeSettable(
                    named: kAXValueAttribute as String,
                    of: element
                )
            )
        )
    }

    private func frame(for element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionAXValue) == .cgPoint,
              AXValueGetValue(positionAXValue, .cgPoint, &origin),
              AXValueGetType(sizeAXValue) == .cgSize,
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: origin, size: size)
    }

    private func text(for element: AXUIElement) -> String? {
        Self.firstAvailableText(
            startingAt: element,
            valueProvider: { [weak self] in
                self?.directText(for: $0)
            },
            fallbackTextProvider: { [weak self] in
                self?.textMarkerText(for: $0)
            },
            parentProvider: { [weak self] in
                self?.parent(of: $0)
            }
        )
    }

    private func directText(for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        ) == .success,
        let value else {
            return nil
        }

        if let text = value as? String {
            return text
        }

        if let attributedText = value as? NSAttributedString {
            return attributedText.string
        }

        return nil
    }

    private func textMarkerText(for element: AXUIElement) -> String? {
        guard let startMarker = attributeValue(
                named: "AXStartTextMarker",
                of: element,
                expectedTypeID: AXTextMarkerGetTypeID()
              ),
              let endMarker = attributeValue(
                named: "AXEndTextMarker",
                of: element,
                expectedTypeID: AXTextMarkerGetTypeID()
              ) else {
            return nil
        }

        let range = AXTextMarkerRangeCreate(
            kCFAllocatorDefault,
            unsafeBitCast(startMarker, to: AXTextMarker.self),
            unsafeBitCast(endMarker, to: AXTextMarker.self)
        )
        var textValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element,
                "AXStringForTextMarkerRange" as CFString,
                range,
                &textValue
              ) == .success,
              let text = textValue as? String else {
            return nil
        }

        return text
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        attributeElement(named: kAXParentAttribute as String, of: element)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let childValues = attributeValue(named: kAXChildrenAttribute as String, of: element) as? [Any] else {
            return []
        }

        return childValues.compactMap {
            let value = $0 as CFTypeRef
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }

            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    private func isFocused(_ element: AXUIElement) -> Bool {
        (attributeValue(named: kAXFocusedAttribute as String, of: element) as? Bool) == true
    }

    private func focusedWindow(for applicationElement: AXUIElement) -> AXUIElement? {
        attributeElement(named: kAXFocusedWindowAttribute as String, of: applicationElement)
    }

    private func attributeElement(named name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attributeValue(named: name, of: element, expectedTypeID: AXUIElementGetTypeID()) else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func attributeValue(
        named name: String,
        of element: AXUIElement,
        expectedTypeID: CFTypeID? = nil
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value else {
            return nil
        }

        if let expectedTypeID, CFGetTypeID(value) != expectedTypeID {
            return nil
        }

        return value
    }

    private func isAttributeSettable(named name: String, of element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, name as CFString, &isSettable) == .success else {
            return false
        }

        return isSettable.boolValue
    }

    private func frontmostWindowReference(for processID: pid_t) -> FrontmostWindowReference? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        return windowReference(in: windowList, for: processID)
    }

    func windowReference(in windowList: [[String: Any]], for processID: pid_t) -> FrontmostWindowReference? {
        for windowInfo in windowList {
            let ownerProcessID = (windowInfo[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            guard ownerProcessID == processID else {
                continue
            }

            let layer = (windowInfo[kCGWindowLayer as String] as? NSNumber)?.intValue
                ?? (windowInfo[kCGWindowLayer as String] as? Int)
                ?? 0
            let alpha = (windowInfo[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
                ?? (windowInfo[kCGWindowAlpha as String] as? Double)
                ?? 1
            guard layer == 0, alpha > 0,
                  let windowNumber = windowInfo[kCGWindowNumber as String] as? NSNumber,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDictionary) else {
                continue
            }

            return FrontmostWindowReference(
                windowID: windowNumber.uint32Value,
                frame: frame
            )
        }

        return nil
    }
}

private func focusedElementObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else {
        return
    }

    let monitor = Unmanaged<FocusedElementLocator.PasteTargetMonitor>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    monitor.handle(notification: notification, element: element)
}
