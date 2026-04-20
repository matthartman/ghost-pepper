import Foundation
import FluidAudio

struct SpeakerIdentityInput: Equatable {
    let speakerID: String
    let audioDuration: TimeInterval
    let evidenceTranscript: String
    let embedding: [Float]?
}

struct SpeakerIdentityResolution: Equatable {
    let recognizedVoices: [RecognizedVoiceProfile]
    let localProfiles: [TranscriptionLabSpeakerProfile]
}

struct SpeakerIdentityResolver {
    let matchDistanceThreshold: Float
    let minimumEmbeddingDuration: TimeInterval

    init(
        matchDistanceThreshold: Float = 0.45,
        minimumEmbeddingDuration: TimeInterval = 1.0
    ) {
        self.matchDistanceThreshold = matchDistanceThreshold
        self.minimumEmbeddingDuration = minimumEmbeddingDuration
    }

    func resolve(
        entryID: UUID,
        speakers: [SpeakerIdentityInput],
        existingLocalProfiles: [TranscriptionLabSpeakerProfile],
        recognizedVoices: [RecognizedVoiceProfile],
        now: Date = Date()
    ) -> SpeakerIdentityResolution {
        var resolvedVoices = recognizedVoices
        var recognizedVoiceIndicesByID = Dictionary(
            uniqueKeysWithValues: resolvedVoices.enumerated().map { ($0.element.id, $0.offset) }
        )
        let localProfilesBySpeakerID = Dictionary(
            uniqueKeysWithValues: existingLocalProfiles.map { ($0.speakerID, $0) }
        )

        let resolvedLocalProfiles = speakers.map { speaker in
            let normalizedEvidence = speaker.evidenceTranscript.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let existingLocalProfile = localProfilesBySpeakerID[speaker.speakerID]
            var localProfile = existingLocalProfile ?? TranscriptionLabSpeakerProfile(
                entryID: entryID,
                speakerID: speaker.speakerID,
                displayName: speaker.speakerID,
                isMe: false,
                recognizedVoiceID: nil,
                evidenceTranscript: normalizedEvidence
            )

            if normalizedEvidence.isEmpty == false {
                localProfile.evidenceTranscript = normalizedEvidence
            }

            guard
                let embedding = speaker.embedding,
                speaker.audioDuration >= minimumEmbeddingDuration,
                SpeakerUtilities.validateEmbedding(embedding)
            else {
                return localProfile
            }

            if let recognizedVoiceID = localProfile.recognizedVoiceID,
               let recognizedVoiceIndex = recognizedVoiceIndicesByID[recognizedVoiceID] {
                let updatedVoice = updatedRecognizedVoice(
                    recognizedVoice: resolvedVoices[recognizedVoiceIndex],
                    embedding: embedding,
                    evidenceTranscript: normalizedEvidence,
                    now: now
                )
                resolvedVoices[recognizedVoiceIndex] = updatedVoice
                if existingLocalProfile == nil {
                    localProfile.displayName = updatedVoice.displayName
                    localProfile.isMe = updatedVoice.isMe
                }
                return localProfile
            }

            if let matchedVoiceIndex = bestMatchingRecognizedVoiceIndex(
                for: embedding,
                in: resolvedVoices
            ) {
                let matchedVoice = updatedRecognizedVoice(
                    recognizedVoice: resolvedVoices[matchedVoiceIndex],
                    embedding: embedding,
                    evidenceTranscript: normalizedEvidence,
                    now: now
                )
                resolvedVoices[matchedVoiceIndex] = matchedVoice
                localProfile.recognizedVoiceID = matchedVoice.id
                if existingLocalProfile == nil {
                    localProfile.displayName = matchedVoice.displayName
                    localProfile.isMe = matchedVoice.isMe
                }
                return localProfile
            }

            let createdVoice = RecognizedVoiceProfile(
                id: UUID(),
                displayName: nextRecognizedVoiceName(existingVoices: resolvedVoices),
                isMe: false,
                embedding: normalizedEmbedding(embedding),
                updateCount: 1,
                createdAt: now,
                updatedAt: now,
                evidenceTranscript: normalizedEvidence
            )
            recognizedVoiceIndicesByID[createdVoice.id] = resolvedVoices.count
            resolvedVoices.append(createdVoice)

            localProfile.recognizedVoiceID = createdVoice.id
            if existingLocalProfile == nil {
                localProfile.displayName = createdVoice.displayName
                localProfile.isMe = createdVoice.isMe
            }

            return localProfile
        }

        return SpeakerIdentityResolution(
            recognizedVoices: resolvedVoices.sorted(by: Self.sortRecognizedVoices),
            localProfiles: resolvedLocalProfiles.sorted {
                $0.speakerID.localizedStandardCompare($1.speakerID) == .orderedAscending
            }
        )
    }

    private func bestMatchingRecognizedVoiceIndex(
        for embedding: [Float],
        in recognizedVoices: [RecognizedVoiceProfile]
    ) -> Int? {
        let normalized = normalizedEmbedding(embedding)
        let bestMatch = recognizedVoices.enumerated().min { lhs, rhs in
            SpeakerUtilities.cosineDistance(normalized, lhs.element.embedding)
                < SpeakerUtilities.cosineDistance(normalized, rhs.element.embedding)
        }

        guard let bestMatch else {
            return nil
        }

        let distance = SpeakerUtilities.cosineDistance(normalized, bestMatch.element.embedding)
        guard distance <= matchDistanceThreshold else {
            return nil
        }

        return bestMatch.offset
    }

    private func updatedRecognizedVoice(
        recognizedVoice: RecognizedVoiceProfile,
        embedding: [Float],
        evidenceTranscript: String,
        now: Date
    ) -> RecognizedVoiceProfile {
        var updatedVoice = recognizedVoice
        updatedVoice.embedding = mergedEmbedding(
            current: recognizedVoice.embedding,
            currentUpdateCount: recognizedVoice.updateCount,
            new: embedding
        )
        updatedVoice.updateCount += 1
        updatedVoice.updatedAt = now
        if evidenceTranscript.isEmpty == false {
            updatedVoice.evidenceTranscript = evidenceTranscript
        }
        return updatedVoice
    }

    private func mergedEmbedding(
        current: [Float],
        currentUpdateCount: Int,
        new: [Float]
    ) -> [Float] {
        let normalizedCurrent = normalizedEmbedding(current)
        let normalizedNew = normalizedEmbedding(new)
        let currentWeight = Float(max(currentUpdateCount, 1))
        let newWeight: Float = 1
        let totalWeight = currentWeight + newWeight

        var merged = [Float](repeating: 0, count: normalizedCurrent.count)
        for index in merged.indices {
            merged[index] = (
                normalizedCurrent[index] * currentWeight
                + normalizedNew[index] * newWeight
            ) / totalWeight
        }
        return normalizedEmbedding(merged)
    }

    private func normalizedEmbedding(_ embedding: [Float]) -> [Float] {
        guard embedding.isEmpty == false else {
            return embedding
        }

        let magnitudeSquared = embedding.reduce(into: Float.zero) { partialResult, value in
            partialResult += value * value
        }
        guard magnitudeSquared > 0 else {
            return embedding
        }

        let magnitude = magnitudeSquared.squareRoot()
        return embedding.map { $0 / magnitude }
    }

    private func nextRecognizedVoiceName(existingVoices: [RecognizedVoiceProfile]) -> String {
        "Recognized Voice \(existingVoices.count + 1)"
    }

    private static func sortRecognizedVoices(
        lhs: RecognizedVoiceProfile,
        rhs: RecognizedVoiceProfile
    ) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.createdAt > rhs.createdAt
        }

        return lhs.updatedAt > rhs.updatedAt
    }
}
