import Foundation

/// Result of merging new findings into a dossier body. Shared by the Claude
/// path (`IndexBuilder.mergeDossierBody`) and the local path
/// (`LocalWikiEngine.mergeDossierBody`).
struct MergeDossierResult {
    let body: String
    let generation: GenerationMetadata
}

/// Anything that can build and maintain a wiki index. Two implementations:
///
/// - `IndexBuilder` — the original Claude-driven agent (costs tokens; higher
///   narrative quality).
/// - `LocalWikiEngine` — the on-device pipeline (cards → entity resolution →
///   assembled pages; free).
///
/// `AppState.makeIndexBuilder(for:)` picks one based on the agent backend
/// setting, so the build sheet, incremental updates, and dossier apply all
/// work identically against either.
@MainActor
protocol IndexBuilding: AnyObject {
    func estimateBuildCost(kind: IndexKind) async throws -> IndexBuildEstimate
    func buildFullIndex(kind: IndexKind) -> AsyncThrowingStream<IndexBuildEvent, Error>
    func updateForMeeting(_ meetingURL: URL, kind: IndexKind)
    func mergeDossierBody(
        kind: IndexKind,
        slug: String,
        canonicalName: String,
        newContent: String
    ) async throws -> MergeDossierResult
}
