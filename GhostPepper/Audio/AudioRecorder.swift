import AVFoundation
import CoreAudio

final class AudioRecorder {
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: (() -> Void)?
    var onConvertedAudioChunk: (([Float]) -> Void)?

    /// The device ID to record from. If nil, uses the system default.
    var targetDeviceID: AudioDeviceID?

    /// Kept alive across recordings so AVFAudio does not have to re-run device
    /// discovery on every hotkey press. We only rebuild when the user explicitly
    /// changes the target input device or asks for an audio reset.
    private var engine = AVAudioEngine()
    private var configuredTargetDeviceID: AudioDeviceID?
    private let bufferLock = NSLock()
    private let tapStateLock = NSLock()

    /// The accumulated audio samples captured during recording.
    /// Accessible for reading within the module (internal) so tests can inspect it.
    var audioBuffer: [Float] = []

    /// Target format for WhisperKit: 16 kHz, mono, Float32.
    private lazy var targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    }()
    private let stopFlushSlackNanoseconds: UInt64 = 5_000_000
    private var tapBufferDurationNanoseconds: UInt64 = 20_000_000
    private var lastConvertedChunkAtNanoseconds: UInt64?
    private var inFlightTapCallbacks = 0
    private var stopWaitContinuation: CheckedContinuation<Void, Never>?

    /// Pre-warm the audio engine so the first recording starts faster.
    func prewarm() {
        applyTargetDeviceIfNeeded()
        _ = engine.inputNode // Force node initialization
        engine.prepare()
    }

    /// Reset the audio engine to pick up a newly selected input route.
    /// Call this after changing the microphone selection in Settings.
    func resetForDeviceChange() {
        rebuildEngine()
        prewarm()
    }

    static func serializeAudioBuffer(_ samples: [Float]) throws -> Data {
        samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    static func serializePlayableArchiveAudioBuffer(_ samples: [Float]) throws -> Data {
        let sampleRate = UInt32(16_000)
        let channelCount = UInt16(1)
        let bitsPerSample = UInt16(16)
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataSize = samples.count * bytesPerSample
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample) / 8
        let blockAlign = channelCount * bitsPerSample / 8
        let riffChunkSize = UInt32(36 + dataSize)

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(contentsOf: riffChunkSize.littleEndianBytes)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(contentsOf: UInt32(16).littleEndianBytes)
        data.append(contentsOf: UInt16(1).littleEndianBytes)
        data.append(contentsOf: channelCount.littleEndianBytes)
        data.append(contentsOf: sampleRate.littleEndianBytes)
        data.append(contentsOf: byteRate.littleEndianBytes)
        data.append(contentsOf: blockAlign.littleEndianBytes)
        data.append(contentsOf: bitsPerSample.littleEndianBytes)
        data.append("data".data(using: .ascii)!)
        data.append(contentsOf: UInt32(dataSize).littleEndianBytes)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let scaled = Int16((clamped * Float(Int16.max)).rounded())
            data.append(contentsOf: scaled.littleEndianBytes)
        }

        return data
    }

    static func deserializeAudioBuffer(from data: Data) throws -> [Float] {
        let stride = MemoryLayout<Float>.stride
        guard data.count.isMultiple(of: stride) else {
            throw AudioRecorderPersistenceError.invalidSerializedAudioData
        }

        return data.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            return Array(floatBuffer)
        }
    }

    static func deserializeArchivedAudioBuffer(from data: Data) throws -> [Float] {
        if data.starts(with: Data("RIFF".utf8)) {
            return try deserializeWAVAudioBuffer(from: data)
        }

        return try deserializeAudioBuffer(from: data)
    }

    /// Clears the in-memory audio buffer.
    func resetBuffer() {
        bufferLock.lock()
        audioBuffer = []
        bufferLock.unlock()
    }

    /// Snapshot the buffer under the lock from a sync context.
    /// Extracted so async callers don't touch NSLock directly (Swift 6 enforcement).
    private func snapshotBuffer() -> [Float] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return audioBuffer
    }

    /// Starts capturing audio from the targeted input device (or system default).
    /// Audio is converted to 16 kHz mono Float32 and appended to `audioBuffer`.
    func startRecording() throws {
        resetBuffer()

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        applyTargetDeviceIfNeeded()

        let inputNode = engine.inputNode
        // `inputFormat(forBus:)` reflects the bus's *actual* HW input format.
        // `outputFormat(forBus:)` is the downstream format and is the one that
        // can go stale. Always trust inputFormat for input nodes.
        let hwFormat = inputNode.inputFormat(forBus: 0)
        print("AudioRecorder: input HW format = \(hwFormat), sampleRate=\(hwFormat.sampleRate), channels=\(hwFormat.channelCount)")

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputAvailable
        }

        // Keep the tap interval short so stop-time tail flushes stay cheap.
        let bufferDuration = 0.02
        let bufferSize = max(1, AVAudioFrameCount(hwFormat.sampleRate * bufferDuration))
        resetTapDrainState(bufferDurationSeconds: Double(bufferSize) / hwFormat.sampleRate)

        cachedConverter = nil
        cachedConverterSourceFormat = nil

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] pcmBuffer, _ in
            guard let self = self else { return }
            self.beginTapCallback()
            defer { self.endTapCallback() }

            // For devices with >2 channels (e.g. aggregate devices), AVAudioConverter
            // can't downmix to mono. Manually downmix to mono first, then convert.
            if pcmBuffer.format.channelCount > 2 {
                self.convertWithManualDownmix(buffer: pcmBuffer)
            } else {
                guard let converter = self.converter(for: pcmBuffer.format) else { return }
                self.convert(buffer: pcmBuffer, using: converter)
            }
        }

        try engine.start()
        onRecordingStarted?()
    }

    private var cachedConverter: AVAudioConverter?
    private var cachedConverterSourceFormat: AVAudioFormat?

    private func rebuildEngine() {
        engine.stop()
        engine = AVAudioEngine()
        configuredTargetDeviceID = nil
    }

    private func applyTargetDeviceIfNeeded() {
        if targetDeviceID == nil, configuredTargetDeviceID != nil {
            rebuildEngine()
        }

        guard configuredTargetDeviceID != targetDeviceID,
              let deviceID = targetDeviceID else {
            return
        }

        // Rebuild the engine when switching devices so inputNode picks up the new format
        rebuildEngine()

        let audioUnit = engine.inputNode.audioUnit!
        var devID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            print("AudioRecorder: failed to set device \(deviceID) on audio unit, status=\(status)")
            return
        }

        configuredTargetDeviceID = deviceID
        print("AudioRecorder: targeting device \(deviceID) directly on audio unit")
    }

    private func converter(for sourceFormat: AVAudioFormat) -> AVAudioConverter? {
        if let cachedConverter, let cachedConverterSourceFormat,
           cachedConverterSourceFormat.sampleRate == sourceFormat.sampleRate,
           cachedConverterSourceFormat.channelCount == sourceFormat.channelCount {
            return cachedConverter
        }

        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        cachedConverter = converter
        cachedConverterSourceFormat = sourceFormat
        if converter == nil {
            print("AudioRecorder: failed to create converter from \(sourceFormat) to \(targetFormat)")
        }
        return converter
    }

    /// Stops capturing audio and returns the recorded buffer.
    /// Waits only for the remainder of the active tap interval plus any
    /// in-flight conversion work so stop latency tracks the tap size.
    func stopRecording() async -> [Float] {
        let flushDelay = stopFlushDelayNanoseconds()
        if flushDelay > 0 {
            try? await Task.sleep(nanoseconds: flushDelay)
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        await waitForTapCallbacksToDrain()
        onRecordingStopped?()

        let result = snapshotBuffer()
        print("AudioRecorder: stopped, buffer has \(result.count) samples (\(Double(result.count) / 16000.0)s of audio)")
        if !result.isEmpty {
            let maxAmplitude = result.map { abs($0) }.max() ?? 0
            print("AudioRecorder: max amplitude = \(maxAmplitude)")
        }
        return result
    }

    // MARK: - Private

    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * (targetFormat.sampleRate / buffer.format.sampleRate)
        ) + 1 // +1 to avoid rounding down to zero

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return
        }

        var error: NSError?
        var allConsumed = false

        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if allConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            allConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            print("AudioRecorder: conversion error – \(error.localizedDescription)")
            return
        }

        guard let channelData = convertedBuffer.floatChannelData, convertedBuffer.frameLength > 0 else {
            return
        }

        let frames = Array(UnsafeBufferPointer(start: channelData[0], count: Int(convertedBuffer.frameLength)))

        appendConvertedFrames(frames)
    }

    /// Manual mono downmix for devices with >2 channels (aggregate devices).
    /// AVAudioConverter can't handle non-standard channel counts, so we average
    /// all channels to mono first, then use a mono→mono converter for sample rate.
    private func convertWithManualDownmix(buffer: AVAudioPCMBuffer) {
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return }

        // Average all channels to produce mono samples
        var monoSamples = [Float](repeating: 0, count: frameLength)

        if let channelData = buffer.floatChannelData {
            // Non-interleaved: each channel is a separate pointer
            for frame in 0..<frameLength {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += channelData[ch][frame]
                }
                monoSamples[frame] = sum / Float(channelCount)
            }
        } else {
            return
        }

        // Create a mono buffer at the source sample rate
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false)!
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frameLength)) else { return }
        monoBuffer.frameLength = AVAudioFrameCount(frameLength)
        if let dest = monoBuffer.floatChannelData?[0] {
            monoSamples.withUnsafeBufferPointer { src in
                dest.update(from: src.baseAddress!, count: frameLength)
            }
        }

        // Now convert mono→mono with sample rate change (source rate → 16kHz)
        guard let converter = self.converter(for: monoFormat) else { return }
        self.convert(buffer: monoBuffer, using: converter)
    }

    #if DEBUG
    func test_convert(samples: [Float]) {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat),
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData?.pointee {
            samples.withUnsafeBufferPointer { source in
                if let baseAddress = source.baseAddress {
                    channelData.update(from: baseAddress, count: samples.count)
                }
            }
        }

        convert(buffer: buffer, using: converter)
    }
    #endif

    private func appendConvertedFrames(_ frames: [Float]) {
        bufferLock.lock()
        audioBuffer.append(contentsOf: frames)
        bufferLock.unlock()

        recordConvertedChunkArrival()
        onConvertedAudioChunk?(frames)
    }

    private func resetTapDrainState(bufferDurationSeconds: TimeInterval) {
        tapStateLock.lock()
        defer { tapStateLock.unlock() }
        tapBufferDurationNanoseconds = UInt64(bufferDurationSeconds * 1_000_000_000)
        lastConvertedChunkAtNanoseconds = nil
        inFlightTapCallbacks = 0
        stopWaitContinuation = nil
    }

    private func beginTapCallback() {
        tapStateLock.lock()
        inFlightTapCallbacks += 1
        tapStateLock.unlock()
    }

    private func endTapCallback() {
        var continuation: CheckedContinuation<Void, Never>?
        tapStateLock.lock()
        inFlightTapCallbacks = max(0, inFlightTapCallbacks - 1)
        if inFlightTapCallbacks == 0 {
            continuation = stopWaitContinuation
            stopWaitContinuation = nil
        }
        tapStateLock.unlock()
        continuation?.resume()
    }

    private func recordConvertedChunkArrival() {
        tapStateLock.lock()
        lastConvertedChunkAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        tapStateLock.unlock()
    }

    private func stopFlushDelayNanoseconds() -> UInt64 {
        tapStateLock.lock()
        let tapBufferDurationNanoseconds = self.tapBufferDurationNanoseconds
        let lastConvertedChunkAtNanoseconds = self.lastConvertedChunkAtNanoseconds
        tapStateLock.unlock()

        guard tapBufferDurationNanoseconds > 0 else {
            return 0
        }

        guard let lastConvertedChunkAtNanoseconds else {
            return tapBufferDurationNanoseconds + stopFlushSlackNanoseconds
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= lastConvertedChunkAtNanoseconds
            ? now - lastConvertedChunkAtNanoseconds
            : 0
        let remaining = elapsed >= tapBufferDurationNanoseconds
            ? 0
            : tapBufferDurationNanoseconds - elapsed
        return remaining + stopFlushSlackNanoseconds
    }

    private func waitForTapCallbacksToDrain() async {
        let hasInFlightCallbacks = tapStateLock.withLock { inFlightTapCallbacks > 0 }
        guard hasInFlightCallbacks else {
            return
        }

        await withCheckedContinuation { continuation in
            let shouldResumeImmediately = tapStateLock.withLock {
                if inFlightTapCallbacks == 0 {
                    return true
                }

                stopWaitContinuation = continuation
                return false
            }

            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }
}

// MARK: - Errors

private extension AudioRecorder {
    static func deserializeWAVAudioBuffer(from data: Data) throws -> [Float] {
        guard data.count >= 44,
              data.starts(with: Data("RIFF".utf8)),
              data.dropFirst(8).starts(with: Data("WAVE".utf8)) else {
            throw AudioRecorderPersistenceError.invalidSerializedAudioData
        }

        var offset = 12
        var audioFormat: UInt16?
        var bitsPerSample: UInt16?
        var channelCount: UInt16?
        var sampleData = Data()

        while offset + 8 <= data.count {
            let chunkIDData = data[offset..<(offset + 4)]
            let chunkSize = UInt32(littleEndian: data[(offset + 4)..<(offset + 8)].withUnsafeBytes { $0.load(as: UInt32.self) })
            offset += 8

            guard offset + Int(chunkSize) <= data.count else {
                throw AudioRecorderPersistenceError.invalidSerializedAudioData
            }

            let chunkData = data[offset..<(offset + Int(chunkSize))]
            let chunkID = String(decoding: chunkIDData, as: UTF8.self)

            if chunkID == "fmt " {
                guard chunkData.count >= 16 else {
                    throw AudioRecorderPersistenceError.invalidSerializedAudioData
                }

                audioFormat = UInt16(littleEndian: chunkData[chunkData.startIndex..<(chunkData.startIndex + 2)].withUnsafeBytes { $0.load(as: UInt16.self) })
                channelCount = UInt16(littleEndian: chunkData[(chunkData.startIndex + 2)..<(chunkData.startIndex + 4)].withUnsafeBytes { $0.load(as: UInt16.self) })
                bitsPerSample = UInt16(littleEndian: chunkData[(chunkData.startIndex + 14)..<(chunkData.startIndex + 16)].withUnsafeBytes { $0.load(as: UInt16.self) })
            } else if chunkID == "data" {
                sampleData = Data(chunkData)
            }

            offset += Int(chunkSize)
            if chunkSize.isMultiple(of: 2) == false {
                offset += 1
            }
        }

        guard audioFormat == 1,
              channelCount == 1,
              bitsPerSample == 16,
              sampleData.count.isMultiple(of: 2) else {
            throw AudioRecorderPersistenceError.invalidSerializedAudioData
        }

        return sampleData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            return int16Buffer.map { Float($0) / Float(Int16.max) }
        }
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}

enum AudioRecorderError: Error, LocalizedError {
    case noInputAvailable
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .noInputAvailable:
            return "No audio input device available."
        case .converterCreationFailed:
            return "Failed to create audio format converter."
        }
    }
}

enum AudioRecorderPersistenceError: Error {
    case invalidSerializedAudioData
}
