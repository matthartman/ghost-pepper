import Foundation

enum SpeechBackendKind: Equatable {
    case whisperKit
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
    let fluidAudioVariant: FluidAudioModelVariant?

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
        }
    }

    var supportsSpeakerFiltering: Bool {
        // Speaker filtering uses a separate diarization pipeline, so any
        // FluidAudio-backed ASR model can participate in filtering.
        backend == .fluidAudio
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
        fluidAudioVariant: nil
    )

    static let whisperSmallEnglish = SpeechModelDescriptor(
        name: "openai_whisper-small.en",
        pickerTitle: "Accuracy",
        variantName: "small.en",
        sizeDescription: "~466 MB",
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-small.en"],
        fluidAudioVariant: nil
    )

    static let whisperSmallMultilingual = SpeechModelDescriptor(
        name: "openai_whisper-small",
        pickerTitle: "Multilingual",
        variantName: "small",
        sizeDescription: "~466 MB",
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-small"],
        fluidAudioVariant: nil
    )

    static let parakeetV3 = SpeechModelDescriptor(
        name: "fluid_parakeet-v3",
        pickerTitle: "Parakeet v3",
        variantName: "25 languages",
        sizeDescription: "~1.4 GB",
        backend: .fluidAudio,
        cachePathComponents: ["FluidInference", "parakeet-tdt-0.6b-v3-coreml"],
        fluidAudioVariant: .parakeetV3
    )

    static let qwen3AsrInt8 = SpeechModelDescriptor(
        name: "fluid_qwen3-asr-0.6b-int8",
        pickerTitle: "Qwen3-ASR 0.6B",
        variantName: "int8, 50+ languages",
        sizeDescription: "~900 MB",
        backend: .fluidAudio,
        cachePathComponents: [],
        fluidAudioVariant: .qwen3AsrInt8
    )

    /// Models that are always selectable on the current OS.
    private static let baseModels: [SpeechModelDescriptor] = [
        whisperTiny,
        whisperSmallEnglish,
        whisperSmallMultilingual,
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
        availableModels.filter { $0.backend == .whisperKit }
    }

    static func model(named name: String) -> SpeechModelDescriptor? {
        availableModels.first { $0.name == name }
    }
}
