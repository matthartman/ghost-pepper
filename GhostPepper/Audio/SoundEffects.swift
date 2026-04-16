import AppKit

class SoundEffects {
    private let startSound: NSSound?
    private let stopSound: NSSound?
    private let isEnabled: () -> Bool
    private let startPlayer: () -> Void
    private let stopPlayer: () -> Void

    init(
        isEnabled: @escaping () -> Bool = { true },
        startPlayer: (() -> Void)? = nil,
        stopPlayer: (() -> Void)? = nil
    ) {
        startSound = NSSound(named: "Tink")
        stopSound = NSSound(named: "Pop")
        self.isEnabled = isEnabled
        self.startPlayer = startPlayer ?? { [weak startSound] in
            startSound?.stop()
            startSound?.play()
        }
        self.stopPlayer = stopPlayer ?? { [weak stopSound] in
            stopSound?.stop()
            stopSound?.play()
        }
    }

    func playStart() {
        guard isEnabled() else { return }
        startPlayer()
    }

    func playStop() {
        guard isEnabled() else { return }
        stopPlayer()
    }

    func stopAll() {
        startSound?.stop()
        stopSound?.stop()
    }
}
