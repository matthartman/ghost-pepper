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
    let backend: SpeechBackendKind
    let cachePathComponents: [String]
    let downloadURL: String?
    let fluidAudioVariant: FluidAudioModelVariant?

    var id: String { name }

    var pickerLabel: String {
        "\(pickerTitle) (\(variantName) — \(sizeDescription))"
    }

    var statusName: String {
        switch backend {
        case .whisperKit:
            "Whisper \(variantName) (\(pickerTitle.lowercased()))"
        case .whisperCpp:
            "\(pickerTitle) (\(variantName.lowercased()))"
        case .fluidAudio:
            "\(pickerTitle) (\(variantName.lowercased()))"
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
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-small"],
        downloadURL: nil,
        fluidAudioVariant: nil
    )

    static let whisperLargeV3Turbo = SpeechModelDescriptor(
        name: "openai_whisper-large-v3_turbo",
        pickerTitle: "Large v3 Turbo",
        variantName: "multilingual",
        sizeDescription: "~954 MB",
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-large-v3_turbo"],
        downloadURL: nil,
        fluidAudioVariant: nil
    )

    static let whisperCppLargeV3TurboQuantized = SpeechModelDescriptor(
        name: "ggml-large-v3-turbo-q5_0",
        pickerTitle: "whisper.cpp Large v3 Turbo",
        variantName: "Q5_0 quantized",
        sizeDescription: "~574 MB",
        backend: .whisperCpp,
        cachePathComponents: ["ggml-large-v3-turbo-q5_0.bin"],
        downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
        fluidAudioVariant: nil
    )

    static let whisperCppLargeV3Turbo = SpeechModelDescriptor(
        name: "ggml-large-v3-turbo",
        pickerTitle: "whisper.cpp Large v3 Turbo",
        variantName: "F16 full precision",
        sizeDescription: "~1.5 GB",
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
        whisperLargeV3Turbo,
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
