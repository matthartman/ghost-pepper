import Cocoa
import AVFoundation
import CoreGraphics
import IOKit.hidsystem
import SwiftUI

struct RunningAppDragTile: View {
    private let appURL = Bundle.main.bundleURL

    var body: some View {
        HStack(spacing: 10) {
            DraggableAppIcon(appURL: appURL)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Drag this app into the permission list")
                    .font(.caption.weight(.semibold))
                Text(appURL.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .help("Drag the exact running Ghost Pepper app into System Settings")
    }
}

private struct DraggableAppIcon: NSViewRepresentable {
    let appURL: URL

    func makeNSView(context: Context) -> AppBundleDragImageView {
        AppBundleDragImageView(appURL: appURL)
    }

    func updateNSView(_ view: AppBundleDragImageView, context: Context) {
        view.appURL = appURL
    }
}

private final class AppBundleDragImageView: NSImageView, NSDraggingSource {
    var appURL: URL {
        didSet { image = NSWorkspace.shared.icon(forFile: appURL.path) }
    }

    init(appURL: URL) {
        self.appURL = appURL
        super.init(frame: .zero)
        image = NSWorkspace.shared.icon(forFile: appURL.path)
        imageScaling = .scaleProportionallyUpOrDown
        toolTip = "Drag \(appURL.lastPathComponent) into System Settings"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(appURL.absoluteString, forType: .fileURL)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let iconSize = NSSize(width: 44, height: 44)
        let origin = NSPoint(
            x: bounds.midX - iconSize.width / 2,
            y: bounds.midY - iconSize.height / 2
        )
        draggingItem.setDraggingFrame(NSRect(origin: origin, size: iconSize), contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }
}

enum MicrophonePermissionStatus: Equatable {
    case authorized
    case denied
    case notDetermined
}

class PermissionChecker {
    struct Client {
        let checkAccessibility: () -> Bool
        let promptAccessibility: () -> Void
        let microphoneStatus: () -> MicrophonePermissionStatus
        let requestMicrophoneAccess: () async -> Bool
        let openAccessibilitySettings: () -> Void
        let openMicrophoneSettings: () -> Void
    }

    static let defaultClient: Client = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return Client.test
        }
        return Client.live
    }()

    static var current = defaultClient

    static func checkAccessibility() -> Bool {
        current.checkAccessibility()
    }

    static func promptAccessibility() {
        current.promptAccessibility()
    }

    static func microphoneStatus() -> MicrophonePermissionStatus {
        current.microphoneStatus()
    }

    static func checkMicrophone() async -> Bool {
        let status = microphoneStatus()
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await current.requestMicrophoneAccess()
        case .denied:
            return false
        }
    }

    static func openAccessibilitySettings() {
        current.openAccessibilitySettings()
    }

    static func openMicrophoneSettings() {
        current.openMicrophoneSettings()
    }

    static func checkInputMonitoring() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func promptInputMonitoring() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openInputMonitoringSettings() {
        openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func openSystemSettingsPane(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        if NSWorkspace.shared.open(url) {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [urlString]
        try? process.run()
    }
}

private extension PermissionChecker.Client {
    static let live = PermissionChecker.Client(
        checkAccessibility: {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        },
        promptAccessibility: {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        },
        microphoneStatus: {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return .authorized
            case .notDetermined:
                return .notDetermined
            default:
                return .denied
            }
        },
        requestMicrophoneAccess: {
            await AVCaptureDevice.requestAccess(for: .audio)
        },
        openAccessibilitySettings: {
            PermissionChecker.openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        },
        openMicrophoneSettings: {
            PermissionChecker.openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    )

    static let test = PermissionChecker.Client(
        checkAccessibility: { false },
        promptAccessibility: {},
        microphoneStatus: { .denied },
        requestMicrophoneAccess: { false },
        openAccessibilitySettings: {},
        openMicrophoneSettings: {}
    )
}
