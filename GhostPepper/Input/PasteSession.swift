import CoreGraphics
import Foundation

struct PasteSession: Equatable, Sendable {
    let pastedText: String
    let pastedAt: Date
    let frontmostAppBundleIdentifier: String?
    let frontmostWindowID: UInt32?
    let frontmostWindowFrame: CGRect?
    let focusedElementFrame: CGRect?
    let focusedElementText: String?
}
