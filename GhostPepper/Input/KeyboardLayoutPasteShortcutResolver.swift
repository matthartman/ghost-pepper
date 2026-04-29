import Carbon
import CoreGraphics

/// Resolves the physical keycode that should be combined with Command to trigger
/// paste in the user's current keyboard layout.
///
/// `CGEvent` keyboard posting works in virtual keycodes, which track physical key
/// positions rather than characters. For non-QWERTY layouts, the ANSI `V` key no
/// longer necessarily produces `v`, so we reverse-translate the active layout to
/// find the unmodified keycode whose character output is exactly lowercase `v`.
struct KeyboardLayoutPasteShortcutResolver {
    typealias LayoutDataProvider = () -> Data?
    typealias KeyboardTypeProvider = () -> UInt32
    typealias KeyTranslator = (_ keyCode: CGKeyCode, _ layoutData: Data, _ keyboardType: UInt32) -> String?

    private static let defaultCandidateKeyCodes = Array(0...127).map(CGKeyCode.init)
    private static let pasteCharacter = "v"

    private let currentLayoutDataProvider: LayoutDataProvider
    private let keyboardTypeProvider: KeyboardTypeProvider
    private let translator: KeyTranslator
    private let candidateKeyCodes: [CGKeyCode]

    init(
        currentLayoutDataProvider: @escaping LayoutDataProvider = Self.defaultCurrentLayoutData,
        keyboardTypeProvider: @escaping KeyboardTypeProvider = { UInt32(LMGetKbdType()) },
        translator: @escaping KeyTranslator = Self.defaultTranslate,
        candidateKeyCodes: [CGKeyCode] = Self.defaultCandidateKeyCodes
    ) {
        self.currentLayoutDataProvider = currentLayoutDataProvider
        self.keyboardTypeProvider = keyboardTypeProvider
        self.translator = translator
        self.candidateKeyCodes = candidateKeyCodes
    }

    func currentPasteKeyCode() -> CGKeyCode? {
        guard let layoutData = currentLayoutDataProvider() else {
            return nil
        }

        let keyboardType = keyboardTypeProvider()
        // macOS exposes layout translation as "keycode -> character", not the reverse,
        // so scan the small keyboard keycode range until we find the physical key that
        // currently produces lowercase `v` with no extra modifiers.
        return candidateKeyCodes.first {
            translator($0, layoutData, keyboardType) == Self.pasteCharacter
        }
    }

    private static func defaultCurrentLayoutData() -> Data? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }

        guard let rawLayoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        guard let layoutData = unretainedDataPropertyValue(from: rawLayoutData) else {
            return nil
        }

        return layoutData
    }

    private static func unretainedDataPropertyValue(from rawPointer: UnsafeMutableRawPointer) -> Data? {
        // `TISGetInputSourceProperty` is a Core Foundation Get-style API that exposes
        // an unretained opaque pointer. Keep the unsafe bridge localized here rather
        // than leaking `UnsafeMutableRawPointer` handling into the resolver logic.
        let value = Unmanaged<CFTypeRef>.fromOpaque(rawPointer).takeUnretainedValue()
        guard CFGetTypeID(value) == CFDataGetTypeID() else {
            return nil
        }

        return value as? Data
    }

    private static func defaultTranslate(
        keyCode: CGKeyCode,
        layoutData: Data,
        keyboardType: UInt32
    ) -> String? {
        layoutData.withUnsafeBytes { rawBufferPointer in
            guard let baseAddress = rawBufferPointer.baseAddress,
                  rawBufferPointer.count >= MemoryLayout<UCKeyboardLayout>.size else {
                return nil
            }

            // The layout payload is an opaque Carbon blob. `UCKeyTranslate` expects a
            // pointer to that blob interpreted as `UCKeyboardLayout` metadata.
            let keyboardLayout = baseAddress.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var translatedCharacters = [UniChar](repeating: 0, count: 4)
            var translatedLength = 0

            let status = UCKeyTranslate(
                keyboardLayout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDown),
                0,
                keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                translatedCharacters.count,
                &translatedLength,
                &translatedCharacters
            )

            guard status == noErr, translatedLength == 1 else {
                return nil
            }

            return String(utf16CodeUnits: translatedCharacters, count: translatedLength)
        }
    }
}
