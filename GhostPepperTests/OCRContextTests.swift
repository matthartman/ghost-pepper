import XCTest
import Vision
@testable import GhostPepper

private enum TestImageFactory {
    static func makeCGImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel
        let bitsPerComponent = 8
        var pixel: [UInt8] = [255, 255, 255, 255]
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let provider = CGDataProvider(data: NSData(bytes: &pixel, length: pixel.count)) else {
            fatalError("Failed to create test image provider")
        }

        guard let image = CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bytesPerPixel * bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            fatalError("Failed to create test CGImage")
        }

        return image
    }
}

private final class SpyWindowCaptureService: WindowCaptureServing {
    var captureCallCount = 0
    var nextImage: CGImage?

    func captureFrontmostWindowImage() async throws -> CGImage? {
        captureCallCount += 1
        return nextImage
    }
}

final class OCRContextTests: XCTestCase {
    func testOCRRequestFactoryUsesAccurateRecognitionLevel() {
        let request = OCRRequestFactory().makeRequest(customWords: [])

        XCTAssertEqual(request.recognitionLevel, .accurate)
        XCTAssertEqual(request.revision, VNRecognizeTextRequestRevision3)
    }

    func testOCRRequestFactoryEnablesLanguageCorrection() {
        let request = OCRRequestFactory().makeRequest(customWords: [])

        XCTAssertTrue(request.usesLanguageCorrection)
    }

    func testOCRRequestFactoryAcceptsCustomWords() {
        let request = OCRRequestFactory().makeRequest(customWords: ["Ghost Pepper", "Jesse"])

        XCTAssertEqual(request.customWords, ["Ghost Pepper", "Jesse"])
    }

    func testCaptureStillAttemptsWindowImageWhenPreflightPermissionIsFalse() async {
        let captureService = SpyWindowCaptureService()
        captureService.nextImage = TestImageFactory.makeCGImage()
        let service = FrontmostWindowOCRService(
            permissionProvider: { false },
            windowCaptureService: captureService,
            recognizeText: { _, _ in
                "hello from ocr"
            }
        )

        let context = await service.captureContext(customWords: [])

        XCTAssertEqual(context?.windowContents, "hello from ocr")
        XCTAssertEqual(captureService.captureCallCount, 1)
    }

    func testCaptureLogsFullOCRTextOnlyToSensitiveLogger() async {
        let captureService = SpyWindowCaptureService()
        captureService.nextImage = TestImageFactory.makeCGImage()
        var regularMessages: [String] = []
        var sensitiveMessages: [String] = []
        let service = FrontmostWindowOCRService(
            permissionProvider: { true },
            windowCaptureService: captureService,
            recognizeText: { _, _ in
                "hello from ocr"
            }
        )
        service.debugLogger = { _, message in
            regularMessages.append(message)
        }
        service.sensitiveDebugLogger = { _, message in
            sensitiveMessages.append(message)
        }

        _ = await service.captureContext(customWords: [])

        XCTAssertFalse(regularMessages.contains(where: { $0.contains("hello from ocr") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("hello from ocr") }))
    }
}
