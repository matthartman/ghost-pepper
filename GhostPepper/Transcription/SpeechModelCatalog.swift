import Foundation

enum SpeechBackendKind: Equatable {
    case whisperKit
    case fluidAudio
    case moonshineMLX
}

enum FluidAudioModelVariant: Equatable {
    case parakeetV3
    case qwen3AsrInt8
}

enum MoonshineMLXModelVariant: Equatable {
    case tiny
    case small
    case medium
}

struct SpeechModelDescriptor: Identifiable, Equatable {
    let name: String
    let pickerTitle: String
    let variantName: String
    let sizeDescription: String
    let backend: SpeechBackendKind
    let cachePathComponents: [String]
    let fluidAudioVariant: FluidAudioModelVariant?
    let moonshineVariant: MoonshineMLXModelVariant?

    init(
        name: String,
        pickerTitle: String,
        variantName: String,
        sizeDescription: String,
        backend: SpeechBackendKind,
        cachePathComponents: [String],
        fluidAudioVariant: FluidAudioModelVariant? = nil,
        moonshineVariant: MoonshineMLXModelVariant? = nil
    ) {
        self.name = name
        self.pickerTitle = pickerTitle
        self.variantName = variantName
        self.sizeDescription = sizeDescription
        self.backend = backend
        self.cachePathComponents = cachePathComponents
        self.fluidAudioVariant = fluidAudioVariant
        self.moonshineVariant = moonshineVariant
    }

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
        case .moonshineMLX:
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

    #if arch(arm64)
    static let moonshineTiny = SpeechModelDescriptor(
        name: "moonshine_tiny",
        pickerTitle: "Moonshine Tiny",
        variantName: "43M params",
        sizeDescription: "~170 MB",
        backend: .moonshineMLX,
        cachePathComponents: ["UsefulSensors", "moonshine-streaming-tiny"],
        moonshineVariant: .tiny
    )

    static let moonshineSmall = SpeechModelDescriptor(
        name: "moonshine_small",
        pickerTitle: "Moonshine Small",
        variantName: "147M params",
        sizeDescription: "~590 MB",
        backend: .moonshineMLX,
        cachePathComponents: ["UsefulSensors", "moonshine-streaming-small"],
        moonshineVariant: .small
    )

    static let moonshineMedium = SpeechModelDescriptor(
        name: "moonshine_medium",
        pickerTitle: "Moonshine Medium",
        variantName: "245M params",
        sizeDescription: "~980 MB",
        backend: .moonshineMLX,
        cachePathComponents: ["UsefulSensors", "moonshine-streaming-medium"],
        moonshineVariant: .medium
    )
    #endif

    /// Models that are always selectable on the current OS.
    private static let baseModels: [SpeechModelDescriptor] = {
        var models = [
            whisperTiny,
            whisperSmallEnglish,
            whisperSmallMultilingual,
            parakeetV3,
        ]
        #if arch(arm64)
        models.append(contentsOf: [
            moonshineTiny,
            moonshineSmall,
            moonshineMedium,
        ])
        #endif
        return models
    }()

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
