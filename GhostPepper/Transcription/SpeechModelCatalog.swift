import Foundation

enum SpeechBackendKind: Equatable {
    case whisperKit
    case fluidAudio
    case mlxAudio
    case speechAnalyzer
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
    let fluidAudioVariant: FluidAudioModelVariant?
    let mlxAudioRepository: String?

    var id: String { name }

    var pickerLabel: String {
        "\(pickerTitle) (\(variantName) — \(sizeDescription))"
    }

    var statusName: String {
        switch backend {
        case .whisperKit:
            "Whisper \(variantName) (\(pickerTitle.lowercased()))"
        case .fluidAudio:
            "\(pickerTitle) (\(variantName.lowercased()))"
        case .mlxAudio:
            "\(pickerTitle) (\(variantName.lowercased()))"
        case .speechAnalyzer:
            pickerTitle
        }
    }

    var supportsSpeakerFiltering: Bool {
        // Speaker filtering uses a separate diarization pipeline, so any
        // FluidAudio-backed ASR model can participate in filtering.
        backend == .fluidAudio
    }

    var isSystemManaged: Bool {
        backend == .speechAnalyzer
    }

    var isEnglishOnly: Bool {
        name.hasSuffix(".en") || name == SpeechModelCatalog.nemotronSpeechStreamingEnglish.name
    }

    var automaticLanguageLabel: String {
        isSystemManaged ? "System language" : "Auto-detect"
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
        fluidAudioVariant: nil,
        mlxAudioRepository: nil
    )

    static let whisperSmallEnglish = SpeechModelDescriptor(
        name: "openai_whisper-small.en",
        pickerTitle: "Accuracy",
        variantName: "small.en",
        sizeDescription: "~466 MB",
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-small.en"],
        fluidAudioVariant: nil,
        mlxAudioRepository: nil
    )

    static let whisperSmallMultilingual = SpeechModelDescriptor(
        name: "openai_whisper-small",
        pickerTitle: "Multilingual",
        variantName: "small",
        sizeDescription: "~466 MB",
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-small"],
        fluidAudioVariant: nil,
        mlxAudioRepository: nil
    )

    static let parakeetV3 = SpeechModelDescriptor(
        name: "fluid_parakeet-v3",
        pickerTitle: "Parakeet v3",
        variantName: "25 languages",
        sizeDescription: "~1.4 GB",
        backend: .fluidAudio,
        cachePathComponents: ["FluidInference", "parakeet-tdt-0.6b-v3-coreml"],
        fluidAudioVariant: .parakeetV3,
        mlxAudioRepository: nil
    )

    static let qwen3AsrInt8 = SpeechModelDescriptor(
        name: "fluid_qwen3-asr-0.6b-int8",
        pickerTitle: "Qwen3-ASR 0.6B",
        variantName: "int8, 50+ languages",
        sizeDescription: "~900 MB",
        backend: .fluidAudio,
        cachePathComponents: [],
        fluidAudioVariant: .qwen3AsrInt8,
        mlxAudioRepository: nil
    )

    static let nemotronSpeechStreamingEnglish = SpeechModelDescriptor(
        name: "mlx_nemotron-speech-streaming-en-0.6b-8bit",
        pickerTitle: "Nemotron Speech 0.6B",
        variantName: "8-bit, English streaming",
        sizeDescription: "~633 MB",
        backend: .mlxAudio,
        cachePathComponents: [
            "mlx-audio",
            "animaslabs_nemotron-speech-streaming-en-0.6b-mlx-8bit",
        ],
        fluidAudioVariant: nil,
        mlxAudioRepository: "animaslabs/nemotron-speech-streaming-en-0.6b-mlx-8bit"
    )

    static let nemotron35Streaming = SpeechModelDescriptor(
        name: "mlx_nemotron-3.5-asr-streaming-0.6b-8bit",
        pickerTitle: "Nemotron 3.5 ASR 0.6B",
        variantName: "8-bit, 40 language-locales",
        sizeDescription: "~721 MB",
        backend: .mlxAudio,
        cachePathComponents: [
            "mlx-audio",
            "mlx-community_nemotron-3.5-asr-streaming-0.6b-8bit",
        ],
        fluidAudioVariant: nil,
        mlxAudioRepository: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"
    )

    static let speechAnalyzer = SpeechModelDescriptor(
        name: "apple_speech-analyzer",
        pickerTitle: "Apple SpeechAnalyzer",
        variantName: "System model",
        sizeDescription: "Managed by macOS",
        backend: .speechAnalyzer,
        cachePathComponents: [],
        fluidAudioVariant: nil,
        mlxAudioRepository: nil
    )

    /// Models that are always selectable on the current OS.
    private static let baseModels: [SpeechModelDescriptor] = [
        whisperTiny,
        whisperSmallEnglish,
        whisperSmallMultilingual,
        parakeetV3,
        nemotronSpeechStreamingEnglish,
        nemotron35Streaming,
    ]

    static var availableModels: [SpeechModelDescriptor] {
        var models = baseModels
        if #available(macOS 15, iOS 18, *) {
            models.append(qwen3AsrInt8)
        }
        if #available(macOS 26, *) {
            models.append(speechAnalyzer)
        }
        return models
    }

    static let defaultModelID = whisperSmallEnglish.id

    static var whisperModels: [SpeechModelDescriptor] {
        availableModels.filter { $0.backend == .whisperKit }
    }

    static func model(named name: String) -> SpeechModelDescriptor? {
        availableModels.first { $0.name == name }
    }
}
