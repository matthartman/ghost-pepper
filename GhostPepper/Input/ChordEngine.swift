struct ChordEngine {
    enum InputEvent: Equatable {
        case flagsChanged(PhysicalKey)
        case keyDown(PhysicalKey)
        case keyUp(PhysicalKey)
    }

    enum Effect: Equatable {
        case startRecording
        case stopRecording
        case restartRecording
        case fireSimpleAction(ChordAction)
    }

    private let bindings: [ChordAction: KeyChord]
    private(set) var pressedKeys: Set<PhysicalKey> = []
    private(set) var activeRecordingAction: ChordAction?
    /// Latches the simple action that fired for the current press so it cannot fire
    /// again while its chord stays held; cleared once a chord key is released.
    private var firedSimpleAction: ChordAction?

    init(bindings: [ChordAction: KeyChord]) {
        self.bindings = bindings
    }

    mutating func handle(_ inputEvent: InputEvent) -> [Effect] {
        guard updatePressedKeys(for: inputEvent) else { return [] }
        return evaluateStateTransition()
    }

    mutating func syncPressedKeys(_ pressedKeys: Set<PhysicalKey>) -> [Effect] {
        guard self.pressedKeys != pressedKeys else { return [] }
        self.pressedKeys = pressedKeys
        return evaluateStateTransition()
    }

    private mutating func evaluateStateTransition() -> [Effect] {
        // Release the simple-action latch once its chord is no longer fully held.
        if let firedSimpleAction,
           let chord = bindings[firedSimpleAction],
           !pressedKeys.isSuperset(of: chord.keys) {
            self.firedSimpleAction = nil
        }

        switch activeRecordingAction {
        case .pushToTalk:
            if matchResult() == .exact(.toggleToTalk) {
                activeRecordingAction = .toggleToTalk
                return [.restartRecording]
            }

            guard let pushChord = bindings[.pushToTalk] else {
                activeRecordingAction = nil
                return []
            }

            if !pressedKeys.isSuperset(of: pushChord.keys) {
                activeRecordingAction = nil
                return [.stopRecording]
            }

            return []

        case .toggleToTalk:
            if matchResult() == .exact(.toggleToTalk) {
                activeRecordingAction = nil
                return [.stopRecording]
            }

            return []

        case .pepperChat:
            guard let pepperChord = bindings[.pepperChat] else {
                activeRecordingAction = nil
                return []
            }

            if !pressedKeys.isSuperset(of: pepperChord.keys) {
                activeRecordingAction = nil
                return [.stopRecording]
            }

            return []

        case .copyLastTranscription, .openHistory:
            // One-shot actions never hold.
            activeRecordingAction = nil
            return []

        case nil:
            switch matchResult() {
            case .exact(let action) where action.isSimpleAction:
                // Edge-triggered: fire once per press. The latch suppresses re-fires while
                // the chord stays held (auto-repeat key-downs, or a superset collapsing back
                // to exact); it clears when a chord key lifts.
                guard firedSimpleAction != action else { return [] }
                firedSimpleAction = action
                return [.fireSimpleAction(action)]
            case .exact(let action):
                activeRecordingAction = action
                return [.startRecording]
            case .none, .prefix:
                return []
            }
        }
    }

    mutating func reset() {
        pressedKeys.removeAll()
        activeRecordingAction = nil
        firedSimpleAction = nil
    }

    func matchResult() -> ChordMatchResult {
        guard !pressedKeys.isEmpty else { return .none }

        // Exact match always wins — even if pressed keys are also a prefix of a longer chord
        for (action, chord) in bindings where chord.keys == pressedKeys {
            return .exact(action)
        }

        if bindings.values.contains(where: { pressedKeys.isSubset(of: $0.keys) && pressedKeys != $0.keys }) {
            return .prefix
        }

        return .none
    }

    private mutating func updatePressedKeys(for inputEvent: InputEvent) -> Bool {
        switch inputEvent {
        case .flagsChanged(let key):
            if pressedKeys.contains(key) {
                pressedKeys.remove(key)
                return true
            }

            pressedKeys.insert(key)
            return true

        case .keyDown(let key):
            return pressedKeys.insert(key).inserted
        case .keyUp(let key):
            return pressedKeys.remove(key) != nil
        }
    }
}

enum ChordMatchResult: Equatable {
    case none
    case prefix
    case exact(ChordAction)
}
