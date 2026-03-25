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

    func testPushToTalkPromotesToToggleWithoutRestarting() throws {
        var engine = ChordEngine(bindings: [
            .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption]))),
            .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption, space])))
        ])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [.startRecording])
        XCTAssertEqual(engine.activeRecordingAction, .pushToTalk)

        XCTAssertEqual(engine.handle(.keyDown(space)), [])
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
