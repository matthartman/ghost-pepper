import Foundation

final class ChordBindingStore {
    enum StoreError: Error, Equatable {
        case duplicateBinding
    }

    enum BindingState: Equatable {
        /// No user choice has been recorded yet (first-run). Caller should fall back to the default.
        case unset
        /// The user explicitly cleared the shortcut and does not want one bound.
        case cleared
        /// The user has configured a specific chord.
        case set(KeyChord)

        var chord: KeyChord? {
            if case let .set(chord) = self { return chord }
            return nil
        }
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func binding(for action: ChordAction) -> BindingState {
        if defaults.bool(forKey: clearedFlagKey(for: action)) {
            return .cleared
        }

        guard let data = defaults.data(forKey: defaultsKey(for: action)),
              let chord = try? decoder.decode(KeyChord.self, from: data) else {
            return .unset
        }

        return .set(chord)
    }

    func setBinding(_ chord: KeyChord, for action: ChordAction) throws {
        for otherAction in ChordAction.allCases where otherAction != action {
            if case .set(let existing) = binding(for: otherAction), existing == chord {
                throw StoreError.duplicateBinding
            }
        }

        defaults.set(try encoder.encode(chord), forKey: defaultsKey(for: action))
        defaults.removeObject(forKey: clearedFlagKey(for: action))
    }

    func clearBinding(for action: ChordAction) {
        defaults.removeObject(forKey: defaultsKey(for: action))
        defaults.set(true, forKey: clearedFlagKey(for: action))
    }

    private func defaultsKey(for action: ChordAction) -> String {
        "chordBinding.\(action.rawValue)"
    }

    private func clearedFlagKey(for action: ChordAction) -> String {
        "chordBinding.\(action.rawValue).cleared"
    }
}
