import XCTest
@testable import GhostPepper

final class ChordEngineTests: XCTestCase {
    private let rightCommand = PhysicalKey(keyCode: 54)
    private let rightOption = PhysicalKey(keyCode: 61)
    private let space = PhysicalKey(keyCode: 49)
    private let leftCommand = PhysicalKey(keyCode: 55)

    func testPushToTalkStartsWhenChordMatchesEvenIfToggleExtendsIt() throws {
        var engine = ChordEngine(bindings: [
            .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption]))),
            .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption, space])))
        ])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [.startRecording])
        XCTAssertEqual(engine.activeRecordingAction, .pushToTalk)
    }

    func testPushToTalkPromotesToToggleByRestarting() throws {
        var engine = ChordEngine(bindings: [
            .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption]))),
            .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption, space])))
        ])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [.startRecording])
        XCTAssertEqual(engine.activeRecordingAction, .pushToTalk)

        XCTAssertEqual(engine.handle(.keyDown(space)), [.restartRecording])
        XCTAssertEqual(engine.activeRecordingAction, .toggleToTalk)

        XCTAssertEqual(engine.handle(.keyUp(space)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [])
        XCTAssertEqual(engine.handle(.keyDown(space)), [.stopRecording])
        XCTAssertNil(engine.activeRecordingAction)
    }

    func testPushToTalkStartsImmediatelyWhenExactChordMatches() throws {
        var engine = ChordEngine(bindings: [
            .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption]))),
            .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([leftCommand, space])))
        ])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [.startRecording])
        XCTAssertEqual(engine.activeRecordingAction, .pushToTalk)
    }

    func testToggleToTalkTogglesOnSecondMatch() throws {
        var engine = ChordEngine(bindings: [
            .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([leftCommand, space]))),
            .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption, space])))
        ])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [])
        XCTAssertEqual(engine.handle(.keyDown(space)), [.startRecording])
        XCTAssertEqual(engine.activeRecordingAction, .toggleToTalk)

        XCTAssertEqual(engine.handle(.keyUp(space)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [])
        XCTAssertEqual(engine.handle(.keyDown(space)), [.stopRecording])
        XCTAssertNil(engine.activeRecordingAction)
    }

    func testSimpleActionFiresOnceOnKeyDownEdgeAndSuppressesRepeat() throws {
        var engine = ChordEngine(bindings: [
            .copyLastTranscription: try XCTUnwrap(KeyChord(keys: Set([rightCommand, space])))
        ])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.keyDown(space)), [.fireSimpleAction(.copyLastTranscription)])
        XCTAssertNil(engine.activeRecordingAction)

        XCTAssertEqual(engine.handle(.keyDown(space)), [])
        XCTAssertEqual(engine.handle(.keyUp(space)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
    }

    func testSimpleActionDoesNotRefireWhenChordIsReenteredFromASuperset() throws {
        let extra = PhysicalKey(keyCode: 4) // H
        var engine = ChordEngine(bindings: [
            .copyLastTranscription: try XCTUnwrap(KeyChord(keys: Set([rightCommand, space])))
        ])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.keyDown(space)), [.fireSimpleAction(.copyLastTranscription)])

        // Extend past the chord, then collapse back to the exact set — must not re-fire.
        XCTAssertEqual(engine.handle(.keyDown(extra)), [])
        XCTAssertEqual(engine.handle(.keyUp(extra)), [])

        // Releasing a chord key clears the latch, so a fresh press fires again.
        XCTAssertEqual(engine.handle(.keyUp(space)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.keyDown(space)), [.fireSimpleAction(.copyLastTranscription)])
    }

    func testOverlappingSimpleActionDoesNotRefireWhenSupersetCollapses() throws {
        let extra = PhysicalKey(keyCode: 4) // H
        var engine = ChordEngine(bindings: [
            .copyLastTranscription: try XCTUnwrap(KeyChord(keys: Set([rightCommand, space]))),
            .openHistory: try XCTUnwrap(KeyChord(keys: Set([rightCommand, space, extra])))
        ])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.keyDown(space)), [.fireSimpleAction(.copyLastTranscription)])
        XCTAssertEqual(engine.handle(.keyDown(extra)), [.fireSimpleAction(.openHistory)])

        // Collapsing the superset back to the smaller chord must not re-fire it.
        XCTAssertEqual(engine.handle(.keyUp(extra)), [])
    }

    func testRecordingChordStillStartsWhenASimpleActionIsAlsoBound() throws {
        var engine = ChordEngine(bindings: [
            .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption]))),
            .openHistory: try XCTUnwrap(KeyChord(keys: Set([leftCommand, space])))
        ])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [.startRecording])
        XCTAssertEqual(engine.activeRecordingAction, .pushToTalk)
    }

    func testPushToTalkStopsWhenAnyRequiredKeyReleases() throws {
        var engine = ChordEngine(bindings: [
            .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption]))),
            .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([leftCommand, space])))
        ])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [.startRecording])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [.stopRecording])
        XCTAssertNil(engine.activeRecordingAction)
    }
}
