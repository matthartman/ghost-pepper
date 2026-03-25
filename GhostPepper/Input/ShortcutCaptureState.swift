struct ShortcutCaptureState {
    private(set) var pressedKeys: Set<PhysicalKey> = []
    private(set) var capturedKeys: Set<PhysicalKey> = []

    mutating func handle(_ inputEvent: ChordEngine.InputEvent) -> KeyChord? {
        switch inputEvent {
        case .flagsChanged(let key):
            if pressedKeys.contains(key) {
                pressedKeys.remove(key)
                return finishIfNeeded()
            }

            pressedKeys.insert(key)
            capturedKeys.insert(key)
            return nil

        case .keyDown(let key):
            pressedKeys.insert(key)
            capturedKeys.insert(key)
            return nil

        case .keyUp(let key):
            pressedKeys.remove(key)
            return finishIfNeeded()
        }
    }

    mutating func reset() {
        pressedKeys = []
        capturedKeys = []
    }

    private mutating func finishIfNeeded() -> KeyChord? {
        guard pressedKeys.isEmpty else {
            return nil
        }

        let chord = KeyChord(keys: capturedKeys)
        reset()
        return chord
    }
}
