import CoreGraphics
import Foundation

final class FrontmostWindowOCRService {
    typealias PermissionProvider = @Sendable () -> Bool
    typealias TextRecognizer = @Sendable (CGImage, [String]) async throws -> String?

    private let permissionProvider: PermissionProvider
    private let windowCaptureService: WindowCaptureServing
    private let recognizeText: TextRecognizer

    var debugLogger: ((DebugLogCategory, String) -> Void)?
    var sensitiveDebugLogger: ((DebugLogCategory, String) -> Void)?

    init(
        permissionProvider: @escaping PermissionProvider = PermissionChecker.hasScreenRecordingPermission,
        windowCaptureService: WindowCaptureServing = WindowCaptureService(),
        requestFactory: OCRRequestFactory = OCRRequestFactory()
    ) {
        self.permissionProvider = permissionProvider
        self.windowCaptureService = windowCaptureService
        self.recognizeText = { image, customWords in
            try requestFactory.recognizeText(in: image, customWords: customWords)
        }
    }

    init(
        permissionProvider: @escaping PermissionProvider,
        windowCaptureService: WindowCaptureServing,
        recognizeText: @escaping TextRecognizer
    ) {
        self.permissionProvider = permissionProvider
        self.windowCaptureService = windowCaptureService
        self.recognizeText = recognizeText
    }

    func captureContext(customWords: [String]) async -> OCRContext? {
        do {
            guard let image = try await windowCaptureService.captureFrontmostWindowImage(),
                  let text = try await recognizeText(image, customWords) else {
                debugLogger?(.ocr, "Frontmost-window OCR produced no text.")
                return nil
            }

            debugLogger?(.ocr, "Frontmost-window OCR captured text.")
            sensitiveDebugLogger?(.ocr, "Frontmost-window OCR text:\n\(text)")
            return OCRContext(windowContents: text)
        } catch {
            if !permissionProvider() {
                debugLogger?(.ocr, "Frontmost-window OCR failed while Screen Recording permission appears unavailable: \(error.localizedDescription)")
            } else {
                debugLogger?(.ocr, "Frontmost-window OCR failed: \(error.localizedDescription)")
            }
            return nil
        }
    }
}
