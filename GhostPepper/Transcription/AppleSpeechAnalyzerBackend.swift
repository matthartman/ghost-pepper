import AVFAudio
import Foundation
import Speech

private final class MainActorProgressDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var finished = false

    func enqueue(
        _ value: Double,
        handler: @escaping @MainActor (Double?) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard finished == false else { return }

        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            handler(value)
        }
    }

    func finish(
        handler: @escaping @MainActor (Double?) -> Void
    ) async {
        lock.lock()
        finished = true
        let previous = tail
        lock.unlock()

        await previous?.value
        await MainActor.run {
            handler(nil)
        }
    }
}

@MainActor
protocol SpeechAnalyzerTranscribing: AnyObject {
    func transcribe(audioBuffer: [Float]) async throws -> String?
}

@available(macOS 26.0, *)
enum AppleSpeechAnalyzerError: LocalizedError {
    case unavailable
    case unsupportedLocale(String)
    case emptyAudio
    case missingAudioFormat
    case audioBufferCreationFailed
    case audioConverterCreationFailed
    case audioConversionFailed(Error)
    case assetInstallationFailed(Error)
    case analysisFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Apple SpeechAnalyzer is unavailable on this Mac."
        case .unsupportedLocale(let identifier):
            "Apple SpeechAnalyzer does not support the \(identifier) locale."
        case .emptyAudio:
            "Apple SpeechAnalyzer received an empty audio buffer."
        case .missingAudioFormat:
            "Apple SpeechAnalyzer did not provide a compatible audio format."
        case .audioBufferCreationFailed:
            "Ghost Pepper could not create an audio buffer for Apple SpeechAnalyzer."
        case .audioConverterCreationFailed:
            "Ghost Pepper could not create an audio converter for Apple SpeechAnalyzer."
        case .audioConversionFailed(let error):
            "Ghost Pepper could not convert audio for Apple SpeechAnalyzer: \(error.localizedDescription)"
        case .assetInstallationFailed(let error):
            "Apple SpeechAnalyzer could not install its language assets: \(error.localizedDescription)"
        case .analysisFailed(let error):
            "Apple SpeechAnalyzer could not transcribe the recording: \(error.localizedDescription)"
        }
    }
}

@available(macOS 26.0, *)
@MainActor
final class AppleSpeechAnalyzerBackend: SpeechAnalyzerTranscribing {
    typealias ProgressHandler = @MainActor (Double?) -> Void
    typealias SupportedLocaleResolver = @MainActor (Locale) async -> Locale?

    private let locale: Locale

    private init(locale: Locale) {
        self.locale = locale
    }

    static func prepare(
        languageCode: String?,
        currentLocale: Locale = .current,
        supportedLocaleResolver: SupportedLocaleResolver? = nil,
        progressHandler: @escaping ProgressHandler
    ) async throws -> AppleSpeechAnalyzerBackend {
        guard Speech.SpeechTranscriber.isAvailable else {
            throw AppleSpeechAnalyzerError.unavailable
        }

        let requestedLocale = requestedLocale(
            languageCode: languageCode,
            currentLocale: currentLocale
        )
        let supportedLocale: Locale?
        if let supportedLocaleResolver {
            supportedLocale = await supportedLocaleResolver(requestedLocale)
        } else {
            supportedLocale = await Speech.SpeechTranscriber.supportedLocale(
                equivalentTo: requestedLocale
            )
        }
        guard let supportedLocale else {
            throw AppleSpeechAnalyzerError.unsupportedLocale(requestedLocale.identifier)
        }

        let module = Speech.SpeechTranscriber(
            locale: supportedLocale,
            preset: .transcription
        )

        do {
            if let request = try await Speech.AssetInventory.assetInstallationRequest(
                supporting: [module]
            ) {
                let progressDelivery = MainActorProgressDelivery()
                let observation = request.progress.observe(
                    \.fractionCompleted,
                    options: [.initial, .new]
                ) { progress, _ in
                    let fractionCompleted = progress.fractionCompleted
                    progressDelivery.enqueue(fractionCompleted, handler: progressHandler)
                }

                do {
                    try await request.downloadAndInstall()
                } catch {
                    observation.invalidate()
                    await progressDelivery.finish(handler: progressHandler)
                    throw error
                }

                observation.invalidate()
                await progressDelivery.finish(handler: progressHandler)
            }
        } catch {
            throw AppleSpeechAnalyzerError.assetInstallationFailed(error)
        }

        return AppleSpeechAnalyzerBackend(locale: supportedLocale)
    }

    static func requestedLocale(
        languageCode: String?,
        currentLocale: Locale = .current
    ) -> Locale {
        guard let languageCode, languageCode.isEmpty == false else {
            return currentLocale
        }
        return Locale(identifier: languageCode)
    }

    func transcribe(audioBuffer: [Float]) async throws -> String? {
        guard audioBuffer.isEmpty == false else {
            return nil
        }

        let module = Speech.SpeechTranscriber(locale: locale, preset: .transcription)
        guard let format = await Speech.SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module]
        ) else {
            throw AppleSpeechAnalyzerError.missingAudioFormat
        }
        let buffer = try Self.makeAnalyzerBuffer(audioBuffer: audioBuffer, format: format)
        let analyzer = Speech.SpeechAnalyzer(modules: [module])
        let resultTask = Task<[String], Error> {
            var results: [String] = []
            for try await result in module.results {
                results.append(String(result.text.characters))
            }
            return results
        }
        let inputs = AsyncStream<Speech.AnalyzerInput> { continuation in
            continuation.yield(Speech.AnalyzerInput(buffer: buffer))
            continuation.finish()
        }

        do {
            if let lastSampleTime = try await analyzer.analyzeSequence(inputs) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }

            return Self.transcriptText(from: try await resultTask.value)
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw AppleSpeechAnalyzerError.analysisFailed(error)
        }
    }

    static func transcriptText(from results: [String]) -> String? {
        let text = results
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func makeAnalyzerBuffer(
        audioBuffer: [Float],
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard audioBuffer.isEmpty == false else {
            throw AppleSpeechAnalyzerError.emptyAudio
        }
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(audioBuffer.count)
        ), let sourceChannel = sourceBuffer.floatChannelData?[0] else {
            throw AppleSpeechAnalyzerError.audioBufferCreationFailed
        }

        let clippedSamples = audioBuffer.map { sample in
            guard sample.isFinite else { return Float.zero }
            return min(max(sample, -1), 1)
        }
        sourceChannel.update(from: clippedSamples, count: clippedSamples.count)
        sourceBuffer.frameLength = AVAudioFrameCount(clippedSamples.count)

        if sourceFormat == format {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw AppleSpeechAnalyzerError.audioConverterCreationFailed
        }
        let ratio = format.sampleRate / sourceFormat.sampleRate
        let frameCapacity = max(
            AVAudioFrameCount(ceil(Double(sourceBuffer.frameLength) * ratio)),
            1
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCapacity
        ) else {
            throw AppleSpeechAnalyzerError.audioBufferCreationFailed
        }

        do {
            try converter.convert(to: convertedBuffer, from: sourceBuffer)
        } catch {
            throw AppleSpeechAnalyzerError.audioConversionFailed(error)
        }
        return convertedBuffer
    }
}
