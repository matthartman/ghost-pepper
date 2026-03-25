import XCTest
import CoreGraphics
import IOKit.hidsystem
@testable import GhostPepper

final class HotkeyMonitorTests: XCTestCase {
    private let a = PhysicalKey(keyCode: 0)
    private let rightCommand = PhysicalKey(keyCode: 54)
    private let rightOption = PhysicalKey(keyCode: 61)
    private let space = PhysicalKey(keyCode: 49)

    func testPushChordTriggersStartAndStopCallbacks() throws {
        var keyStates: [PhysicalKey: Bool] = [:]
        let monitor = HotkeyMonitor(
            bindings: [
                .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption])))
            ],
            keyStateProvider: { keyStates[$0] ?? false }
        )
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }
        monitor.onRecordingStop = {
            events.append("stop")
        }

        keyStates[rightCommand] = true
        monitor.handleInput(.flagsChanged(rightCommand))
        keyStates[rightOption] = true
        monitor.handleInput(.flagsChanged(rightOption))
        keyStates[rightOption] = false
        monitor.handleInput(.flagsChanged(rightOption))

        XCTAssertEqual(events, ["start", "stop"])
    }

    func testToggleChordTriggersStopOnSecondMatch() throws {
        var keyStates: [PhysicalKey: Bool] = [:]
        let monitor = HotkeyMonitor(
            bindings: [
                .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption, space])))
            ],
            keyStateProvider: { keyStates[$0] ?? false }
        )
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }
        monitor.onRecordingStop = {
            events.append("stop")
        }

        keyStates[rightCommand] = true
        monitor.handleInput(.flagsChanged(rightCommand))
        keyStates[rightOption] = true
        monitor.handleInput(.flagsChanged(rightOption))
        keyStates[space] = true
        monitor.handleInput(.keyDown(space))
        keyStates[space] = false
        monitor.handleInput(.keyUp(space))
        keyStates[rightOption] = false
        monitor.handleInput(.flagsChanged(rightOption))
        keyStates[rightCommand] = false
        monitor.handleInput(.flagsChanged(rightCommand))
        keyStates[rightCommand] = true
        monitor.handleInput(.flagsChanged(rightCommand))
        keyStates[rightOption] = true
        monitor.handleInput(.flagsChanged(rightOption))
        keyStates[space] = true
        monitor.handleInput(.keyDown(space))

        XCTAssertEqual(events, ["start", "stop"])
    }

    func testPushChordStartsWhenCurrentKeyStateLagsBehindModifierEvents() throws {
        var keyStates: [PhysicalKey: Bool] = [:]
        let monitor = HotkeyMonitor(
            bindings: [
                .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption])))
            ],
            keyStateProvider: { keyStates[$0] ?? false }
        )
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }

        monitor.handleInput(.flagsChanged(rightCommand))
        keyStates[rightCommand] = true
        monitor.handleInput(.flagsChanged(rightOption))
        keyStates[rightOption] = true

        XCTAssertEqual(events, ["start"])
    }

    func testToggleChordStartsWhenCurrentKeyStateLagsBehindKeyDownEvent() throws {
        var keyStates: [PhysicalKey: Bool] = [:]
        let monitor = HotkeyMonitor(
            bindings: [
                .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption, space])))
            ],
            keyStateProvider: { keyStates[$0] ?? false }
        )
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }

        monitor.handleInput(.flagsChanged(rightCommand))
        keyStates[rightCommand] = true
        monitor.handleInput(.flagsChanged(rightOption))
        keyStates[rightOption] = true
        monitor.handleInput(.keyDown(space))
        keyStates[space] = true

        XCTAssertEqual(events, ["start"])
    }

    func testMonitorResyncsMissingModifierEdgeFromCurrentKeyState() throws {
        var keyStates: [PhysicalKey: Bool] = [:]
        let monitor = HotkeyMonitor(
            bindings: [
                .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption])))
            ],
            keyStateProvider: { keyStates[$0] ?? false },
            modifierFlagsProvider: { self.modifierFlags(for: keyStates) }
        )
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }

        keyStates[rightCommand] = true
        keyStates[rightOption] = true
        monitor.handleInput(.flagsChanged(rightOption))

        XCTAssertEqual(events, ["start"])
    }

    func testMonitorResyncsToggleChordFromCurrentKeyStateOnKeyDown() throws {
        var keyStates: [PhysicalKey: Bool] = [:]
        let monitor = HotkeyMonitor(
            bindings: [
                .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption, space])))
            ],
            keyStateProvider: { keyStates[$0] ?? false },
            modifierFlagsProvider: { self.modifierFlags(for: keyStates) }
        )
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }

        keyStates[rightCommand] = true
        keyStates[rightOption] = true
        keyStates[space] = true
        monitor.handleInput(.keyDown(space))

        XCTAssertEqual(events, ["start"])
    }

    func testToggleChordStillStartsWhenPolledStateOmitsEarlierModifier() throws {
        var keyStates: [PhysicalKey: Bool] = [:]
        let monitor = HotkeyMonitor(
            bindings: [
                .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption, space])))
            ],
            keyStateProvider: { keyStates[$0] ?? false }
        )
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }

        keyStates[rightCommand] = true
        monitor.handleInput(.flagsChanged(rightCommand))

        keyStates = [rightOption: true]
        monitor.handleInput(.flagsChanged(rightOption))

        keyStates = [
            rightOption: true,
            space: true
        ]
        monitor.handleInput(.keyDown(space))

        XCTAssertEqual(events, ["start"])
    }

    func testToggleChordStillStopsWhenPolledStateOmitsEarlierModifier() throws {
        var keyStates: [PhysicalKey: Bool] = [:]
        let monitor = HotkeyMonitor(
            bindings: [
                .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption, space])))
            ],
            keyStateProvider: { keyStates[$0] ?? false }
        )
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }
        monitor.onRecordingStop = {
            events.append("stop")
        }

        keyStates[rightCommand] = true
        monitor.handleInput(.flagsChanged(rightCommand))
        keyStates[rightOption] = true
        monitor.handleInput(.flagsChanged(rightOption))
        keyStates[space] = true
        monitor.handleInput(.keyDown(space))
        keyStates[space] = false
        monitor.handleInput(.keyUp(space))
        keyStates[rightOption] = false
        monitor.handleInput(.flagsChanged(rightOption))
        keyStates[rightCommand] = false
        monitor.handleInput(.flagsChanged(rightCommand))

        keyStates[rightCommand] = true
        monitor.handleInput(.flagsChanged(rightCommand))

        keyStates = [rightOption: true]
        monitor.handleInput(.flagsChanged(rightOption))

        keyStates = [
            rightOption: true,
            space: true
        ]
        monitor.handleInput(.keyDown(space))

        XCTAssertEqual(events, ["start", "stop"])
    }

    func testSuspendedMonitorWaitsForKeysToReleaseBeforeMatchingAgain() throws {
        var keyStates: [PhysicalKey: Bool] = [:]
        let monitor = HotkeyMonitor(
            bindings: [
                .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption])))
            ],
            keyStateProvider: { keyStates[$0] ?? false }
        )
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }

        monitor.setSuspended(true)
        keyStates[rightCommand] = true
        monitor.handleInput(.flagsChanged(rightCommand))
        keyStates[rightOption] = true
        monitor.handleInput(.flagsChanged(rightOption))

        monitor.setSuspended(false)
        keyStates[rightOption] = false
        monitor.handleInput(.flagsChanged(rightOption))
        keyStates[rightCommand] = false
        monitor.handleInput(.flagsChanged(rightCommand))
        keyStates[rightCommand] = true
        monitor.handleInput(.flagsChanged(rightCommand))
        keyStates[rightOption] = true
        monitor.handleInput(.flagsChanged(rightOption))

        XCTAssertEqual(events, ["start"])
    }

    func testMonitorRecoversAfterShortcutCaptureWhenReleaseEventsWereConsumedElsewhere() throws {
        var keyStates: [PhysicalKey: Bool] = [:]
        let monitor = HotkeyMonitor(
            bindings: [
                .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption])))
            ],
            keyStateProvider: { keyStates[$0] ?? false }
        )
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }

        monitor.setSuspended(true)
        keyStates[rightCommand] = true
        keyStates[rightOption] = true

        monitor.setSuspended(false)

        // Shortcut capture consumed the release events, so the hotkey monitor only sees
        // the next real hotkey attempt after the physical keys are already back up.
        keyStates[rightCommand] = false
        keyStates[rightOption] = false
        keyStates[rightCommand] = true
        monitor.handleInput(.flagsChanged(rightCommand))
        keyStates[rightOption] = true
        monitor.handleInput(.flagsChanged(rightOption))

        XCTAssertEqual(events, ["start"])
    }

    func testMonitorClearsStalePressedKeysWhenStopEventSeesNoPhysicalKeys() throws {
        var keyStates: [PhysicalKey: Bool] = [:]
        let monitor = HotkeyMonitor(
            bindings: [
                .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption])))
            ],
            keyStateProvider: { keyStates[$0] ?? false }
        )
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }
        monitor.onRecordingStop = {
            events.append("stop")
        }

        keyStates[rightCommand] = true
        monitor.handleInput(.flagsChanged(rightCommand))
        keyStates[rightOption] = true
        monitor.handleInput(.flagsChanged(rightOption))

        keyStates[rightOption] = false
        keyStates[rightCommand] = false
        monitor.handleInput(.flagsChanged(rightCommand))

        keyStates[rightCommand] = true
        monitor.handleInput(.flagsChanged(rightCommand))
        keyStates[rightOption] = true
        monitor.handleInput(.flagsChanged(rightOption))

        XCTAssertEqual(events, ["start", "stop", "start"])
    }

    func testMonitorIgnoresUnboundKeysWithoutLoggingOrTriggeringCallbacks() throws {
        let monitor = HotkeyMonitor(
            bindings: [
                .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption])))
            ],
            keyStateProvider: { _ in false },
            eventProcessor: { work in work() }
        )
        var events: [String] = []
        var logs: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }
        monitor.onRecordingStop = {
            events.append("stop")
        }
        monitor.debugLogger = { _, message in
            logs.append(message)
        }

        monitor.handleInput(.keyDown(a))
        monitor.handleInput(.keyUp(a))

        XCTAssertEqual(events, [])
        XCTAssertEqual(logs, [])
    }

    func testFlagsChangedSnapshotsDoNotRestartChordFromStaleModifierState() throws {
        let monitor = HotkeyMonitor(
            bindings: [
                .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption])))
            ],
            keyStateProvider: { _ in false },
            eventProcessor: { work in work() }
        )
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }
        monitor.onRecordingStop = {
            events.append("stop")
        }

        monitor.handleEvent(
            .flagsChanged,
            event: modifierEvent(
                key: rightCommand,
                flagsRawValue: UInt64(NX_COMMANDMASK | NX_DEVICERCMDKEYMASK)
            )
        )
        monitor.handleEvent(
            .flagsChanged,
            event: modifierEvent(
                key: rightOption,
                flagsRawValue: UInt64(NX_COMMANDMASK | NX_ALTERNATEMASK | NX_DEVICERCMDKEYMASK | NX_DEVICERALTKEYMASK)
            )
        )

        // The Right Command release was missed. The next Right Option release arrives after both keys are already up,
        // so its flags snapshot must clear the stale command state instead of leaving it latched.
        monitor.handleEvent(
            .flagsChanged,
            event: modifierEvent(
                key: rightOption,
                flagsRawValue: 0
            )
        )
        monitor.handleEvent(
            .flagsChanged,
            event: modifierEvent(
                key: rightOption,
                flagsRawValue: UInt64(NX_ALTERNATEMASK | NX_DEVICERALTKEYMASK)
            )
        )

        XCTAssertEqual(events, ["start", "stop"])
    }

    func testFlagsChangedSnapshotStartsChordWhenEarlierModifierEdgeWasMissed() throws {
        let monitor = HotkeyMonitor(
            bindings: [
                .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption])))
            ],
            keyStateProvider: { _ in false },
            eventProcessor: { work in work() }
        )
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }

        // The Right Command press edge was missed, but the next modifier event already reports the
        // full side-specific modifier snapshot. Matching should still start from that snapshot.
        monitor.handleEvent(
            .flagsChanged,
            event: modifierEvent(
                key: rightOption,
                flagsRawValue: UInt64(NX_COMMANDMASK | NX_ALTERNATEMASK | NX_DEVICERCMDKEYMASK | NX_DEVICERALTKEYMASK)
            )
        )

        XCTAssertEqual(events, ["start"])
    }

    func testKeyDownIgnoresNonModifierWithoutActiveModifierPrefix() throws {
        let monitor = HotkeyMonitor(
            bindings: [
                .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption, space])))
            ],
            keyStateProvider: { _ in
                XCTFail("Non-modifier key handling should not poll global key state when modifiers are inactive.")
                return false
            },
            modifierFlagsProvider: {
                XCTFail("Non-modifier key handling should not poll modifier state when modifiers are inactive.")
                return []
            },
            eventProcessor: { work in work() }
        )
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }

        monitor.handleEvent(
            .keyDown,
            event: modifierEvent(
                key: space,
                flagsRawValue: 0
            )
        )

        XCTAssertEqual(events, [])
    }

    func testKeyDownSnapshotStartsChordWhenModifierPrefixIsAlreadyHeld() throws {
        let monitor = HotkeyMonitor(
            bindings: [
                .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption, space])))
            ],
            keyStateProvider: { _ in
                XCTFail("Real-key matching should rely on the event snapshot instead of polling global key state.")
                return false
            },
            modifierFlagsProvider: {
                XCTFail("Real-key matching should rely on the event snapshot instead of polling modifier state.")
                return []
            },
            eventProcessor: { work in work() }
        )
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
        }

        monitor.handleEvent(
            .keyDown,
            event: modifierEvent(
                key: space,
                flagsRawValue: UInt64(NX_COMMANDMASK | NX_ALTERNATEMASK | NX_DEVICERCMDKEYMASK | NX_DEVICERALTKEYMASK)
            )
        )

        XCTAssertEqual(events, ["start"])
    }

    func testHandleEventDispatchesCallbacksAsynchronously() throws {
        let queue = DispatchQueue(label: "HotkeyMonitorTests.eventProcessor")
        let monitor = HotkeyMonitor(
            bindings: [
                .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption])))
            ],
            keyStateProvider: { _ in false },
            eventProcessor: { work in
                queue.async(execute: work)
            }
        )
        let started = expectation(description: "start callback")
        var events: [String] = []

        monitor.onRecordingStart = {
            events.append("start")
            started.fulfill()
        }

        monitor.handleEvent(
            .flagsChanged,
            event: modifierEvent(
                key: rightOption,
                flagsRawValue: UInt64(NX_COMMANDMASK | NX_ALTERNATEMASK | NX_DEVICERCMDKEYMASK | NX_DEVICERALTKEYMASK)
            )
        )

        XCTAssertEqual(events, [])
        wait(for: [started], timeout: 1.0)
        XCTAssertEqual(events, ["start"])
    }

    private func modifierEvent(key: PhysicalKey, flagsRawValue: UInt64) -> CGEvent {
        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(key.keyCode),
            keyDown: true
        )!
        event.flags = CGEventFlags(rawValue: flagsRawValue)
        return event
    }

    private func modifierFlags(for keyStates: [PhysicalKey: Bool]) -> CGEventFlags {
        var rawValue: UInt64 = 0

        if keyStates[rightCommand] == true {
            rawValue |= UInt64(NX_COMMANDMASK | NX_DEVICERCMDKEYMASK)
        }
        if keyStates[rightOption] == true {
            rawValue |= UInt64(NX_ALTERNATEMASK | NX_DEVICERALTKEYMASK)
        }

        return CGEventFlags(rawValue: rawValue)
    }
}
