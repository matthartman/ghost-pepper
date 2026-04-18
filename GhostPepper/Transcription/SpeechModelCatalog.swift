import Foundation

enum SpeechBackendKind: Equatable {
    case whisperKit
    case whisperCpp
    case fluidAudio
}

enum FluidAudioModelVariant: Equatable {
    case parakeetV3
    case qwen3AsrInt8
}

struct SpeechModelDescriptor: Identifiable, Equatable {
    let name: String
    let pickerTitle: String
    let variantName: String
    let sizeDescription: String
    let pickerLabelOverride: String?
    let statusNameOverride: String?
    let backend: SpeechBackendKind
    let cachePathComponents: [String]
    let downloadURL: String?
    let fluidAudioVariant: FluidAudioModelVariant?

    var id: String { name }

    var pickerLabel: String {
        if let pickerLabelOverride {
            return pickerLabelOverride
        }
        return "\(pickerTitle) (\(variantName) — \(sizeDescription))"
    }

    var statusName: String {
        if let statusNameOverride {
            return statusNameOverride
        }
        switch backend {
        case .whisperKit:
            return "Whisper \(variantName) (\(pickerTitle.lowercased()))"
        case .whisperCpp:
            return "\(pickerTitle) (\(variantName.lowercased()))"
        case .fluidAudio:
            return "\(pickerTitle) (\(variantName.lowercased()))"
        }
    }

    var supportsSpeakerFiltering: Bool {
        // Only Parakeet exposes diarization output via the Sortformer pipeline.
        // Qwen3-ASR is an encoder-decoder and has no per-speaker segmentation.
        fluidAudioVariant == .parakeetV3
    }
}

enum SpeechModelCatalog {
    static let whisperTiny = SpeechModelDescriptor(
        name: "openai_whisper-tiny.en",
        pickerTitle: "Speed",
        variantName: "tiny.en",
        sizeDescription: "~75 MB",
        pickerLabelOverride: nil,
        statusNameOverride: nil,
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-tiny.en"],
        downloadURL: nil,
        fluidAudioVariant: nil
    )

    static let whisperSmallEnglish = SpeechModelDescriptor(
        name: "openai_whisper-small.en",
        pickerTitle: "Accuracy",
        variantName: "small.en",
        sizeDescription: "~466 MB",
        pickerLabelOverride: nil,
        statusNameOverride: nil,
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-small.en"],
        downloadURL: nil,
        fluidAudioVariant: nil
    )

    static let whisperSmallMultilingual = SpeechModelDescriptor(
        name: "openai_whisper-small",
        pickerTitle: "Multilingual",
        variantName: "small",
        sizeDescription: "~466 MB",
        pickerLabelOverride: nil,
        statusNameOverride: nil,
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-small"],
        downloadURL: nil,
        fluidAudioVariant: nil
    )

    static let whisperCppLargeV3TurboQuantized = SpeechModelDescriptor(
        name: "ggml-large-v3-turbo-q5_0",
        pickerTitle: "Whisper large v3 turbo",
        variantName: "q5_0, multilingual",
        sizeDescription: "~547 MB",
        pickerLabelOverride: nil,
        statusNameOverride: nil,
        backend: .whisperCpp,
        cachePathComponents: ["ggml-large-v3-turbo-q5_0.bin"],
        downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
        fluidAudioVariant: nil
    )

    static let whisperCppLargeV3Turbo = SpeechModelDescriptor(
        name: "ggml-large-v3-turbo",
        pickerTitle: "Whisper large v3 turbo",
        variantName: "full, multilingual",
        sizeDescription: "~1.5 GB",
        pickerLabelOverride: nil,
        statusNameOverride: nil,
        backend: .whisperCpp,
        cachePathComponents: ["ggml-large-v3-turbo.bin"],
        downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
        fluidAudioVariant: nil
    )

    static let parakeetV3 = SpeechModelDescriptor(
        name: "fluid_parakeet-v3",
        pickerTitle: "Parakeet v3",
        variantName: "25 languages",
        sizeDescription: "~1.4 GB",
        pickerLabelOverride: nil,
        statusNameOverride: nil,
        backend: .fluidAudio,
        cachePathComponents: ["FluidInference", "parakeet-tdt-0.6b-v3-coreml"],
        downloadURL: nil,
        fluidAudioVariant: .parakeetV3
    )

    static let qwen3AsrInt8 = SpeechModelDescriptor(
        name: "fluid_qwen3-asr-0.6b-int8",
        pickerTitle: "Qwen3-ASR 0.6B",
        variantName: "int8, 50+ languages",
        sizeDescription: "~900 MB",
        pickerLabelOverride: nil,
        statusNameOverride: nil,
        backend: .fluidAudio,
        cachePathComponents: [],
        downloadURL: nil,
        fluidAudioVariant: .qwen3AsrInt8
    )

    /// Models that are always selectable on the current OS.
    private static let baseModels: [SpeechModelDescriptor] = [
        whisperTiny,
        whisperSmallEnglish,
        whisperSmallMultilingual,
        whisperCppLargeV3TurboQuantized,
        whisperCppLargeV3Turbo,
        parakeetV3,
    ]

    static var availableModels: [SpeechModelDescriptor] {
        if #available(macOS 15, iOS 18, *) {
            return baseModels + [qwen3AsrInt8]
        }
        return baseModels
    }

    static let defaultModelID = whisperSmallEnglish.id

    static var whisperModels: [SpeechModelDescriptor] {
        availableModels.filter { $0.backend == .whisperKit || $0.backend == .whisperCpp }
    }

    static func model(named name: String) -> SpeechModelDescriptor? {
        availableModels.first { $0.name == name }
    }
}
