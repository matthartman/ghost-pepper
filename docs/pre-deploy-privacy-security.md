# Pre-Deploy Privacy and Security Gate

Run this gate before every public build, appcast update, GitHub release, or notarized DMG upload.

## Required checks

1. Run the local static preflight:

   ```sh
   ./scripts/privacy-security-preflight.sh
   ```

2. Run or review the Codex audit suite for the current deployment candidate:

   - Repo leaks and secrets
   - Network egress and cloud boundaries
   - Logs, diagnostics, storage, and retention
   - Agent sandboxing and path traversal
   - Dependencies, updater, model downloads, and release artifacts

3. Confirm there is no real user data in tracked, modified, or untracked release inputs:

   - Granola cache files or imported meeting markdown
   - Meeting participant names from private tests
   - Transcripts, summaries, or people indexes from real meetings
   - Audio/video files, screenshots, OCR text, or debug logs
   - API keys, tokens, signing credentials, or local config

4. Confirm all network paths are expected:

   - Core transcription, cleanup, OCR, local summaries, and local storage do not send user content over the network.
   - Cloud integrations are opt-in and require user configuration.
   - Sparkle, GitHub, and Hugging Face paths are release/update/model-download paths only.

5. Review any new debug or export UI for private content exposure.

## Release rule

Do not deploy until the preflight passes and any fresh Codex audit findings are either fixed or explicitly accepted for the release.
