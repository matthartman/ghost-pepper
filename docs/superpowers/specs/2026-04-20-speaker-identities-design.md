# Speaker Identities Design

## Goal

Add durable speaker identities on top of transcription-lab speaker tagging so Jesse can:

- see speaker names directly on the speaker-tagging timeline
- rename speakers locally within a lab recording
- optionally push a local rename into a global recognized-voices store
- mark multiple recognized voices as `me`
- carry those global voice identities forward into future speaker-tagged lab reruns

This slice is intentionally limited to the transcription lab and global settings. The live meeting transcript flow still only produces `me` versus `others`, so it does not have the per-speaker diarization data needed for the same identity workflow yet.

## Current Context

- The transcription lab already stores archived recordings and can rerun speaker tagging.
- Speaker-tagged reruns already produce:
  - diarized spans
  - a speaker-tagged transcript
  - a color timeline in Settings
- The current app only exposes anonymous session-local speaker IDs such as `Speaker 0`.
- Ghost Pepper already depends on `FluidAudio`, and that package exposes:
  - speaker embedding extraction through `DiarizerManager.extractSpeakerEmbedding(from:)`
  - cosine-distance speaker matching helpers
  - speaker enrollment APIs for future extensions

## Non-Goals

- no live meeting diarization
- no retroactive relabeling of past lab recordings after a global voice changes
- no attempt to rewrite existing lab archive formats
- no automatic merging UI for similar global voices in this slice

## Approach Options

### Option 1: Local aliases only

Store per-recording speaker names and never create a global identity store.

Pros:

- smallest code change
- no matching risk

Cons:

- does not help future sessions
- does not support recognized voices settings

### Option 2: Global profiles backed by stored enrollment audio

Persist a short audio sample for each global voice, then pre-enroll those voices into Sortformer before future diarization runs.

Pros:

- reuses Sortformer enrollment directly
- avoids storing explicit embedding vectors

Cons:

- matching behavior becomes opaque
- harder to explain or debug why a match happened
- awkward to show confidence or update a profile incrementally

### Option 3: Global profiles backed by extracted embeddings

Extract an embedding for each speaker from merged speaker audio, persist the embedding with metadata, and match future speakers by cosine distance.

Pros:

- explicit, testable matching behavior
- easy to snapshot a session-local resolved name while keeping future matching global
- easy to allow multiple voice prints per person

Cons:

- introduces a new persistent store
- first use may need to download the diarizer embedding models

## Chosen Design

Use global recognized voices backed by extracted embeddings, with a separate per-lab-recording speaker snapshot.

### Data Model

Add a global `RecognizedVoiceStore` under Application Support with:

- `RecognizedVoiceProfile`
  - `id`
  - `displayName`
  - `isMe`
  - `embedding`
  - `updateCount`
  - `createdAt`
  - `updatedAt`
  - `evidenceTranscript`

Add a separate lab-scoped `TranscriptionLabSpeakerProfileStore` with per-entry speaker snapshots:

- `TranscriptionLabSpeakerProfile`
  - `entryID`
  - `speakerID`
  - `displayName`
  - `isMe`
  - `recognizedVoiceID`
  - `evidenceTranscript`

These stores are separate from the existing transcription-lab archive so existing entries keep loading unchanged.

### Matching

When a speaker-tagged rerun completes:

1. merge all spans for each speaker
2. extract the speaker-only audio
3. extract one speaker embedding from that merged audio
4. compare that embedding against all global recognized voices
5. if the closest match is inside a conservative auto-match threshold, snapshot that global identity onto the lab recording
6. otherwise create a new global recognized voice with placeholder naming and snapshot that onto the lab recording

If the same global voice matches again later, update its stored embedding by averaging the old and new normalized embeddings, then re-normalizing.

### Local Versus Global Naming

The lab recording owns the displayed name for that recording.

- Renaming a speaker inside the recording updates only the lab-scoped snapshot.
- After a local change, show an inline `Update global voice print` action.
- Pressing that action writes the current local name and `isMe` value into the linked global recognized voice.
- Past recordings are not relabeled when a global profile changes.

This preserves Jesse’s “future sessions only” rule.

### UI

#### Transcription Lab

Extend the lab speaker-tagging detail with:

- labels drawn directly on the timeline for all speakers
- a per-speaker editor row showing:
  - color
  - current display name
  - `This is me` checkbox
  - evidence transcript snippet
  - inline `Update global voice print` button when local and global values differ
- the speaker-tagged transcript rendered with resolved display names instead of raw `Speaker N`

#### Settings

Add a new Settings section: `Recognized Voices`.

Show one row per global voice print with:

- editable name
- `This is me` checkbox
- last updated date
- evidence transcript

This is a voice-print list, not a person graph. Multiple rows may be marked as `me`.

## Error Handling

- If embedding extraction fails for a speaker, keep the raw speaker ID for that speaker and do not create a global profile.
- If diarizer embedding models fail to download or load, speaker tagging still succeeds; only identity matching is skipped.
- If a recording has too little usable speaker audio, skip identity creation for that speaker.

## Testing

Add focused tests for:

- recognized voice store persistence
- lab speaker snapshot store persistence
- controller formatting and display-name resolution
- matching logic:
  - auto-match to an existing recognized voice
  - auto-create a new recognized voice when no match exists
  - local rename does not mutate the global profile until explicitly promoted
  - global updates do not rewrite older lab snapshots
- timeline display order still follows diarization span order

## Risks

- embedding thresholds may need tuning on real recordings
- auto-created voice prints can still duplicate the same person when the audio is poor
- this does not yet solve live meeting diarization because that pipeline does not emit per-speaker spans
