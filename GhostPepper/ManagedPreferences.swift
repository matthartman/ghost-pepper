import Foundation
import SwiftUI

/// Detects whether a UserDefaults key has been Forced via an MDM-managed
/// preference (a configuration profile delivered through MDM, Profiles.app,
/// or `mcx`). When `isForced` returns `true`, the value cannot be overridden
/// by the user — per Apple's guidance, the app should disable any UI that
/// would otherwise let the user write to the key.
///
/// See:
/// - https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFPreferences/Concepts/BestPractices.html
enum ManagedPreference {
    private static let bundleID: CFString = (Bundle.main.bundleIdentifier
        ?? "com.github.matthartman.ghostpepper") as CFString

    static func isForced(_ key: String) -> Bool {
        CFPreferencesAppValueIsForced(key as CFString, bundleID)
    }
}

extension View {
    /// Disables this control and shows a small lock indicator when the given
    /// UserDefaults key has been Forced by an MDM-managed configuration
    /// profile. Use on settings controls that should reflect organization
    /// policy when applied.
    func managedByMDM(_ key: String) -> some View {
        modifier(ManagedByMDMModifier(key: key))
    }
}

private struct ManagedByMDMModifier: ViewModifier {
    let key: String

    func body(content: Content) -> some View {
        if ManagedPreference.isForced(key) {
            HStack(spacing: 6) {
                content.disabled(true)
                Image(systemName: "lock.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help("Managed by your organization. Contact IT to change this setting.")
            }
        } else {
            content
        }
    }
}

extension Text {
    /// Appends a friendly note explaining that the setting is administered
    /// when the given UserDefaults key is Forced via MDM. Returns the
    /// original Text unchanged when the key is not managed, so further
    /// styling modifiers can be applied uniformly.
    func appendingManagedNote(if key: String) -> Text {
        guard ManagedPreference.isForced(key) else { return self }
        return self + Text(" This setting is managed by your administrator.")
    }
}
