import CoreGraphics
import Foundation
import Vision

struct OCRRecognitionResult: Equatable, Sendable {
    let text: String
    let confidence: Double
}

struct OCRRequestFactory: Sendable {
    func makeRequest(
        customWords: [String],
        completionHandler: VNRequestCompletionHandler? = nil
    ) -> VNRecognizeTextRequest {
        let request: VNRecognizeTextRequest
        if let completionHandler {
            request = VNRecognizeTextRequest(completionHandler: completionHandler)
        } else {
            request = VNRecognizeTextRequest()
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.customWords = customWords
        request.revision = VNRecognizeTextRequestRevision3
        return request
    }

    func recognizeText(in image: CGImage, customWords: [String]) throws -> String? {
        try recognizeDetailedText(in: image, customWords: customWords)?.text
    }

    func recognizeDetailedText(in image: CGImage, customWords: [String]) throws -> OCRRecognitionResult? {
        var observations: [(boundingBox: CGRect, candidate: VNRecognizedText)] = []
        let request = makeRequest(customWords: customWords) { request, error in
            guard error == nil,
                  let results = request.results as? [VNRecognizedTextObservation] else {
                return
            }

            observations = results.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else {
                    return nil
                }

                return (observation.boundingBox, candidate)
            }
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let sortedObservations = observations.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.02 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.midX < rhs.boundingBox.midX
        }

        let recognizedText = sortedObservations
            .map(\.candidate.string)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recognizedText.isEmpty else {
            return nil
        }

        let averageConfidence = sortedObservations
            .map { Double($0.candidate.confidence) }
            .reduce(0, +) / Double(sortedObservations.count)
        return OCRRecognitionResult(
            text: recognizedText,
            confidence: averageConfidence
        )
    }
}
