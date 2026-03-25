import SwiftUI

@MainActor
final class ScreenRecordingPermissionController: ObservableObject {
    @Published private(set) var isGranted: Bool

    private let hasPermission: () -> Bool
    private let requestPermission: () -> Void

    init(
        hasPermission: @escaping () -> Bool = PermissionChecker.hasScreenRecordingPermission,
        requestPermission: @escaping () -> Void = {
            _ = PermissionChecker.requestScreenRecordingPermission()
        }
    ) {
        self.hasPermission = hasPermission
        self.requestPermission = requestPermission
        self.isGranted = hasPermission()
    }

    func refresh() {
        isGranted = hasPermission()
    }

    func requestAccess() {
        requestPermission()
        refresh()
    }
}
