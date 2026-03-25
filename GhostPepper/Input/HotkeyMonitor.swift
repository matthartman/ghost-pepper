import Cocoa
import CoreGraphics
import IOKit.hidsystem

protocol HotkeyMonitoring: AnyObject {
    var onRecordingStart: (() -> Void)? { get set }
    var onRecordingStop: (() -> Void)? { get set }
    var onPushToTalkStart: (() -> Void)? { get set }
    var onPushToTalkStop: (() -> Void)? { get set }
    var onToggleToTalkStart: (() -> Void)? { get set }
    var onToggleToTalkStop: (() -> Void)? { get set }

    func start() -> Bool
    func stop()
    func updateBindings(_ bindings: [ChordAction: KeyChord])
    func setSuspended(_ suspended: Bool)
}

/// Monitors configured key chords for hold-to-talk and toggle-to-talk using a CGEvent tap.
/// Requires Accessibility permission to create the event tap.
final class HotkeyMonitor: NSObject, HotkeyMonitoring {
    typealias EventProcessor = (@escaping @Sendable () -> Void) -> Void

    private struct HandlingResult {
        let logMessage: String?
        let startAction: ChordAction?
        let stopAction: ChordAction?
    }

    fileprivate struct EventSnapshot {
        let type: CGEventType
        let key: PhysicalKey
        let flags: CGEventFlags
    }

    // MARK: - Callbacks

    var onRecordingStart: (() -> Void)?
    var onRecordingStop: (() -> Void)?
    var onPushToTalkStart: (() -> Void)?
    var onPushToTalkStop: (() -> Void)?
    var onToggleToTalkStart: (() -> Void)?
    var onToggleToTalkStop: (() -> Void)?

    // MARK: - State

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventThread: HotkeyMonitorThread?
    private var bindings: [ChordAction: KeyChord]
    private var monitoredKeys: Set<PhysicalKey>
    private var nonModifierBindingPrefixes: [Set<PhysicalKey>]
    private var chordEngine: ChordEngine
    private let keyStateProvider: (PhysicalKey) -> Bool
    private let modifierFlagsProvider: () -> CGEventFlags
    private let eventProcessor: EventProcessor
    private var isSuspended = false
    private var requiresAllKeysReleased = false
    private let stateLock = NSLock()

    var debugLogger: ((DebugLogCategory, String) -> Void)?

    init(
        bindings: [ChordAction: KeyChord] = [:],
        keyStateProvider: @escaping (PhysicalKey) -> Bool = { key in
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key.keyCode))
        },
        modifierFlagsProvider: @escaping () -> CGEventFlags = {
            CGEventSource.flagsState(.combinedSessionState)
        },
        eventProcessor: EventProcessor? = nil
    ) {
        let queue = DispatchQueue(label: "GhostPepper.HotkeyMonitor.events")
        self.bindings = bindings
        monitoredKeys = bindings.values.reduce(into: Set<PhysicalKey>()) { keys, chord in
            keys.formUnion(chord.keys)
        }
        nonModifierBindingPrefixes = Self.nonModifierBindingPrefixes(from: bindings)
        chordEngine = ChordEngine(bindings: bindings)
        self.keyStateProvider = keyStateProvider
        self.modifierFlagsProvider = modifierFlagsProvider
        self.eventProcessor = eventProcessor ?? { work in
            queue.async(execute: work)
        }
    }

    func updateBindings(_ bindings: [ChordAction: KeyChord]) {
        stateLock.lock()
        self.bindings = bindings
        monitoredKeys = bindings.values.reduce(into: Set<PhysicalKey>()) { keys, chord in
            keys.formUnion(chord.keys)
        }
        nonModifierBindingPrefixes = Self.nonModifierBindingPrefixes(from: bindings)
        chordEngine = ChordEngine(bindings: bindings)
        stateLock.unlock()
        let bindingsDescription = bindings
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value.displayString)" }
            .joined(separator: ", ")
        debugLogger?(.hotkey, "Updated bindings: \(bindingsDescription)")
    }

    func setSuspended(_ suspended: Bool) {
        stateLock.lock()
        isSuspended = suspended
        chordEngine.reset()
        requiresAllKeysReleased = !suspended && !currentPressedKeys().isEmpty
        stateLock.unlock()
        debugLogger?(.hotkey, "Shortcut capture suspension changed to \(suspended).")
    }

    // MARK: - Public API

    /// Starts monitoring for key chord events.
    /// - Returns: `false` if Accessibility permission is denied (event tap creation fails).
    func start() -> Bool {
        stateLock.lock()
        if eventTap != nil {
            stateLock.unlock()
            debugLogger?(.hotkey, "Hotkey monitor start skipped because the event tap is already active.")
            return true
        }
        stateLock.unlock()

        let thread = HotkeyMonitorThread()
        thread.name = "GhostPepper Hotkey Monitor"
        thread.start()
        thread.waitUntilReady()

        let request = HotkeyTapInstallRequest()
        perform(#selector(installEventTap(_:)), on: thread, with: request, waitUntilDone: true)

        guard request.succeeded else {
            perform(#selector(uninstallEventTapAndStopRunLoop), on: thread, with: nil, waitUntilDone: true)
            debugLogger?(.hotkey, "Hotkey monitor failed to start because Accessibility permission is unavailable.")
            return false
        }

        stateLock.lock()
        eventThread = thread
        stateLock.unlock()
        debugLogger?(.hotkey, "Hotkey monitor event tap started.")
        return true
    }

    /// Stops monitoring and cleans up the event tap.
    func stop() {
        stateLock.lock()
        let thread = eventThread
        stateLock.unlock()

        if let thread {
            perform(#selector(uninstallEventTapAndStopRunLoop), on: thread, with: nil, waitUntilDone: true)
        }

        stateLock.lock()
        eventThread = nil
        chordEngine.reset()
        isSuspended = false
        requiresAllKeysReleased = false
        stateLock.unlock()
        debugLogger?(.hotkey, "Hotkey monitor stopped.")
    }

    // MARK: - Event Handling

    func handleEvent(_ type: CGEventType, event: CGEvent) {
        guard let snapshot = EventSnapshot(type: type, event: event) else {
            return
        }

        eventProcessor { [weak self] in
            self?.processCapturedEvent(snapshot)
        }
    }

    func handleInput(_ inputEvent: ChordEngine.InputEvent, authoritativePressedKeys: Set<PhysicalKey>? = nil) {
        stateLock.lock()
        let result = handleInputLocked(inputEvent, authoritativePressedKeys: authoritativePressedKeys)
        stateLock.unlock()
        apply(result)
    }

    private func processCapturedEvent(_ snapshot: EventSnapshot) {
        let result: HandlingResult?

        stateLock.lock()
        switch snapshot.type {
        case .flagsChanged:
            let pressedKeys = trackedNonModifierPressedKeys().union(modifierPressedKeys(from: snapshot.flags))
            result = handleInputLocked(.flagsChanged(snapshot.key), authoritativePressedKeys: pressedKeys)
        case .keyDown:
            guard shouldProcessNonModifierEvents(with: snapshot.flags) else {
                stateLock.unlock()
                return
            }
            let pressedKeys = trackedNonModifierPressedKeys()
                .union(modifierPressedKeys(from: snapshot.flags))
                .union([snapshot.key])
            result = handleInputLocked(.keyDown(snapshot.key), authoritativePressedKeys: pressedKeys)
        case .keyUp:
            guard shouldProcessNonModifierEvents(with: snapshot.flags) else {
                stateLock.unlock()
                return
            }
            var pressedKeys = trackedNonModifierPressedKeys()
            pressedKeys.remove(snapshot.key)
            pressedKeys.formUnion(modifierPressedKeys(from: snapshot.flags))
            result = handleInputLocked(.keyUp(snapshot.key), authoritativePressedKeys: pressedKeys)
        default:
            result = nil
        }
        stateLock.unlock()
        apply(result)
    }

    private func handleInputLocked(
        _ inputEvent: ChordEngine.InputEvent,
        authoritativePressedKeys: Set<PhysicalKey>? = nil
    ) -> HandlingResult? {
        let inputKey: PhysicalKey
        switch inputEvent {
        case .flagsChanged(let key), .keyDown(let key), .keyUp(let key):
            inputKey = key
        }

        guard monitoredKeys.contains(inputKey) else {
            return nil
        }

        if isSuspended {
            return HandlingResult(
                logMessage: "Ignored \(describe(inputEvent)) because shortcut capture is active.",
                startAction: nil,
                stopAction: nil
            )
        }

        let physicalPressedKeys = authoritativePressedKeys ?? currentPressedKeys()

        if requiresAllKeysReleased {
            if physicalPressedKeys.isEmpty {
                requiresAllKeysReleased = false
                return HandlingResult(
                    logMessage: "All keys released after shortcut capture; matching re-enabled.",
                    startAction: nil,
                    stopAction: nil
                )
            }

            switch inputEvent {
            case .flagsChanged(let key) where physicalPressedKeys == Set([key]):
                requiresAllKeysReleased = false
                return HandlingResult(
                    logMessage: "Shortcut capture release recovery completed on a fresh modifier press; matching re-enabled.",
                    startAction: nil,
                    stopAction: nil
                )
            case .keyDown(let key) where physicalPressedKeys == Set([key]):
                requiresAllKeysReleased = false
                return HandlingResult(
                    logMessage: "Shortcut capture release recovery completed on a fresh key press; matching re-enabled.",
                    startAction: nil,
                    stopAction: nil
                )
            default:
                return nil
            }
        }

        let previousAction = chordEngine.activeRecordingAction
        let effects: [ChordEngine.Effect]
        if let authoritativePressedKeys {
            effects = chordEngine.syncPressedKeys(authoritativePressedKeys)
        } else {
            var nextEffects = chordEngine.handle(inputEvent)
            let recoveredPressedKeys = chordEngine.pressedKeys.union(physicalPressedKeys)
            if nextEffects.isEmpty,
               recoveredPressedKeys != chordEngine.pressedKeys,
               currentStateReflectsCurrentEvent(inputEvent, pressedKeys: physicalPressedKeys) {
                // Polling is only trusted to recover missing key-down edges. Partial snapshots
                // are too noisy to erase keys that event history says are still pressed.
                nextEffects = chordEngine.syncPressedKeys(recoveredPressedKeys)
            }
            effects = nextEffects
        }
        if effects.contains(.stopRecording), physicalPressedKeys.isEmpty {
            chordEngine.reset()
        }
        let currentAction = chordEngine.activeRecordingAction
        let effectDescription = effects.map {
            switch $0 {
            case .startRecording:
                "start"
            case .stopRecording:
                "stop"
            }
        }.joined(separator: ", ")
        let actionDescription = currentAction?.rawValue ?? "none"
        let pressedDescription = physicalPressedKeys.map(\.displayName).sorted().joined(separator: " + ")
        let logMessage = "Event \(describe(inputEvent)); pressed=\(pressedDescription.isEmpty ? "none" : pressedDescription); activeAction=\(actionDescription); effects=\(effectDescription.isEmpty ? "none" : effectDescription)"

        let startAction = effects.contains(.startRecording) ? currentAction : nil
        let stopAction = effects.contains(.stopRecording) ? previousAction : nil
        return HandlingResult(logMessage: logMessage, startAction: startAction, stopAction: stopAction)
    }

    private func currentPressedKeys() -> Set<PhysicalKey> {
        currentNonModifierPressedKeys().union(modifierPressedKeys(from: modifierFlagsProvider()))
    }

    private func trackedNonModifierPressedKeys() -> Set<PhysicalKey> {
        chordEngine.pressedKeys.filter { !$0.isModifierKey }
    }

    private func currentNonModifierPressedKeys() -> Set<PhysicalKey> {
        monitoredKeys.filter { !$0.isModifierKey && keyStateProvider($0) }
    }

    private func shouldProcessNonModifierEvents(with flags: CGEventFlags) -> Bool {
        guard !nonModifierBindingPrefixes.isEmpty else {
            return false
        }

        let activeModifiers = modifierPressedKeys(from: flags)
        return nonModifierBindingPrefixes.contains { prefix in
            prefix.isEmpty || activeModifiers.isSuperset(of: prefix)
        }
    }

    private func modifierPressedKeys(from flags: CGEventFlags) -> Set<PhysicalKey> {
        monitoredKeys.filter { key in
            guard let modifierMaskRawValue = key.modifierMaskRawValue else {
                return false
            }

            return flags.rawValue & modifierMaskRawValue == modifierMaskRawValue
        }
    }

    private func currentStateReflectsCurrentEvent(
        _ inputEvent: ChordEngine.InputEvent,
        pressedKeys: Set<PhysicalKey>
    ) -> Bool {
        switch inputEvent {
        case .flagsChanged(let key), .keyDown(let key), .keyUp(let key):
            return pressedKeys.contains(key) == chordEngine.pressedKeys.contains(key)
        }
    }

    private func describe(_ inputEvent: ChordEngine.InputEvent) -> String {
        switch inputEvent {
        case .flagsChanged(let key):
            return "flagsChanged(\(key.displayName))"
        case .keyDown(let key):
            return "keyDown(\(key.displayName))"
        case .keyUp(let key):
            return "keyUp(\(key.displayName))"
        }
    }

    private func apply(_ result: HandlingResult?) {
        guard let result else {
            return
        }

        if let logMessage = result.logMessage {
            debugLogger?(.hotkey, logMessage)
        }

        if let startAction = result.startAction {
            switch startAction {
            case .pushToTalk:
                if let onPushToTalkStart {
                    onPushToTalkStart()
                } else {
                    onRecordingStart?()
                }
            case .toggleToTalk:
                if let onToggleToTalkStart {
                    onToggleToTalkStart()
                } else {
                    onRecordingStart?()
                }
            }
        }

        if let stopAction = result.stopAction {
            switch stopAction {
            case .pushToTalk:
                if let onPushToTalkStop {
                    onPushToTalkStop()
                } else {
                    onRecordingStop?()
                }
            case .toggleToTalk:
                if let onToggleToTalkStop {
                    onToggleToTalkStop()
                } else {
                    onRecordingStop?()
                }
            }
        }
    }

    private static func nonModifierBindingPrefixes(from bindings: [ChordAction: KeyChord]) -> [Set<PhysicalKey>] {
        bindings.values.compactMap { chord in
            guard chord.keys.contains(where: { !$0.isModifierKey }) else {
                return nil
            }

            return chord.keys.filter(\.isModifierKey)
        }
    }

    @objc private func installEventTap(_ request: HotkeyTapInstallRequest) {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            request.succeeded = false
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        stateLock.lock()
        eventTap = tap
        runLoopSource = source
        stateLock.unlock()
        request.succeeded = true
    }

    @objc private func uninstallEventTapAndStopRunLoop() {
        stateLock.lock()
        let tap = eventTap
        let source = runLoopSource
        eventTap = nil
        runLoopSource = nil
        stateLock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

private final class HotkeyMonitorThread: Thread {
    private let readySemaphore = DispatchSemaphore(value: 0)
    private let keepAlivePort = Port()

    override func main() {
        autoreleasepool {
            RunLoop.current.add(keepAlivePort, forMode: .default)
            readySemaphore.signal()
            CFRunLoopRun()
        }
    }

    func waitUntilReady() {
        readySemaphore.wait()
    }
}

private final class HotkeyTapInstallRequest: NSObject {
    var succeeded = false
}

private extension HotkeyMonitor.EventSnapshot {
    init?(type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged, .keyDown, .keyUp:
            self.init(
                type: type,
                key: PhysicalKey(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode))),
                flags: event.flags
            )
        default:
            return nil
        }
    }
}

private extension PhysicalKey {
    var isModifierKey: Bool {
        modifierMaskRawValue != nil
    }

    var modifierMaskRawValue: UInt64? {
        switch keyCode {
        case 54:
            UInt64(NX_DEVICERCMDKEYMASK | NX_COMMANDMASK)
        case 55:
            UInt64(NX_DEVICELCMDKEYMASK | NX_COMMANDMASK)
        case 56:
            UInt64(NX_DEVICELSHIFTKEYMASK | NX_SHIFTMASK)
        case 57:
            CGEventFlags.maskAlphaShift.rawValue
        case 58:
            UInt64(NX_DEVICELALTKEYMASK | NX_ALTERNATEMASK)
        case 59:
            UInt64(NX_DEVICELCTLKEYMASK | NX_CONTROLMASK)
        case 60:
            UInt64(NX_DEVICERSHIFTKEYMASK | NX_SHIFTMASK)
        case 61:
            UInt64(NX_DEVICERALTKEYMASK | NX_ALTERNATEMASK)
        case 62:
            UInt64(NX_DEVICERCTLKEYMASK | NX_CONTROLMASK)
        case 63:
            CGEventFlags.maskSecondaryFn.rawValue
        default:
            nil
        }
    }
}

// MARK: - C Callback

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    // Re-enable tap if it was disabled by the system
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        if let tap = monitor.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        monitor.debugLogger?(.hotkey, "Hotkey event tap was disabled and has been re-enabled.")
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    monitor.handleEvent(type, event: event)
    return Unmanaged.passUnretained(event)
}
