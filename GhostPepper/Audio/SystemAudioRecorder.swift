import AVFoundation
import ScreenCaptureKit

/// Captures system audio output (what other call participants say) using ScreenCaptureKit.
/// Mirrors `AudioRecorder`'s interface but uses `SCStream` instead of `AVAudioEngine`.
final class SystemAudioRecorder: NSObject {
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: (() -> Void)?
    var onConvertedAudioChunk: (([Float]) -> Void)?

    private let bufferLock = NSLock()
    private(set) var audioBuffer: [Float] = []

    private var stream: SCStream?
    private var isRecording = false

    /// Target format: 16 kHz, mono, Float32 — matches AudioRecorder pipeline.
    private let targetSampleRate: Double = 16000
    private let targetChannelCount: Int = 1

    /// Starts capturing system audio output via ScreenCaptureKit.
    /// Requires Screen Recording permission.
    func startRecording() async throws {
        guard !isRecording else { return }

        resetBuffer()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw SystemAudioRecorderError.noDisplayAvailable
        }

        // Capture entire display audio — this gets all system audio output.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(targetSampleRate)
        config.channelCount = targetChannelCount

        // We only want audio, minimize video overhead.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum
        config.showsCursor = false

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await newStream.startCapture()

        stream = newStream
        isRecording = true
        onRecordingStarted?()
    }

    /// Stops capturing system audio and returns the recorded buffer.
    func stopRecording() async -> [Float] {
        guard isRecording else { return [] }

        // Wait briefly for final audio buffers to flush.
        try? await Task.sleep(nanoseconds: 200_000_000)

        if let stream = stream {
            try? await stream.stopCapture()
        }
        stream = nil
        isRecording = false
        onRecordingStopped?()

        let result = copyBuffer()
        print("SystemAudioRecorder: stopped, buffer has \(result.count) samples (\(Double(result.count) / targetSampleRate)s of audio)")
        if !result.isEmpty {
            let maxAmplitude = result.map { abs($0) }.max() ?? 0
            print("SystemAudioRecorder: max amplitude = \(maxAmplitude)")
        }
        return result
    }

    /// Stops capture immediately without waiting for buffered audio to flush.
    func cancelRecordingImmediately() {
        guard isRecording else { return }

        if let stream {
            Task {
                try? await stream.stopCapture()
            }
        }
        stream = nil
        isRecording = false
        onRecordingStopped?()
    }

    /// Thread-safe copy of the current buffer.
    private func copyBuffer() -> [Float] {
        bufferLock.lock()
        let copy = audioBuffer
        bufferLock.unlock()
        return copy
    }

    func resetBuffer() {
        bufferLock.lock()
        audioBuffer = []
        bufferLock.unlock()
    }

    private func appendSamples(_ samples: [Float]) {
        bufferLock.lock()
        audioBuffer.append(contentsOf: samples)
        bufferLock.unlock()

        onConvertedAudioChunk?(samples)
    }
}

// MARK: - SCStreamOutput

extension SystemAudioRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        // Extract Float32 samples from the CMSampleBuffer.
        guard let formatDescription = sampleBuffer.formatDescription,
              let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }

        let asbd = audioStreamBasicDescription.pointee
        let sourceChannelCount = Int(asbd.mChannelsPerFrame)

        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset: Int = 0
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == noErr, let ptr = dataPointer else { return }

        // SCStream delivers Float32 audio when configured.
        let floatPointer = UnsafeRawPointer(ptr).bindMemory(to: Float.self, capacity: length / MemoryLayout<Float>.stride)
        let totalFloats = length / MemoryLayout<Float>.stride

        var monoSamples: [Float]
        if sourceChannelCount == 1 {
            monoSamples = Array(UnsafeBufferPointer(start: floatPointer, count: totalFloats))
        } else {
            // Downmix to mono by averaging channels.
            let frameCount = totalFloats / sourceChannelCount
            monoSamples = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<sourceChannelCount {
                    sum += floatPointer[frame * sourceChannelCount + ch]
                }
                monoSamples[frame] = sum / Float(sourceChannelCount)
            }
        }

        appendSamples(monoSamples)
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("SystemAudioRecorder: stream stopped with error — \(error.localizedDescription)")
        isRecording = false
    }
}

// MARK: - Errors

enum SystemAudioRecorderError: Error, LocalizedError {
    case noDisplayAvailable
    case screenRecordingPermissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display available for system audio capture."
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission is required to capture system audio."
        }
    }
}
