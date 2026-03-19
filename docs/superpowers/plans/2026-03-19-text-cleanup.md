# Text Cleanup Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add local LLM-powered text cleanup to WhisperCat that removes filler words and handles self-corrections using Qwen 2.5 1.5B via MLX.

**Architecture:** After WhisperKit transcription, optionally pass text through a local Qwen 2.5 1.5B model (via mlx-swift-lm) to clean it up. The cleanup model loads in the background after the app reaches Ready state, so transcription works immediately even while the cleanup model downloads.

**Tech Stack:** mlx-swift-lm (MLXLLM), Qwen2.5-1.5B-Instruct-4bit, SwiftUI

**Spec:** `docs/superpowers/specs/2026-03-19-text-cleanup-design.md`

---

## File Structure

```
WhisperCat/Cleanup/
├── TextCleanupManager.swift   # MLX model lifecycle (load/unload/state)
└── TextCleaner.swift          # Sends text to model, returns cleaned text

Modified:
├── project.yml                # Add mlx-swift-lm dependency
├── WhisperCat/AppState.swift  # Add cleanup toggle, manager, integration
└── WhisperCat/UI/MenuBarView.swift  # Add cleanup picker + status
```

---

## Task 1: Add mlx-swift-lm SPM Dependency

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add mlx-swift-lm package to project.yml**

Add to the `packages:` section:

```yaml
  mlx-swift-lm:
    url: https://github.com/ml-explore/mlx-swift-lm.git
    branch: main
```

Add to the WhisperCat target `dependencies:`:

```yaml
      - package: mlx-swift-lm
        product: MLXLLM
```

- [ ] **Step 2: Regenerate Xcode project and resolve dependencies**

```bash
xcodegen generate
xcodebuild -resolvePackageDependencies -project WhisperCat.xcodeproj -scheme WhisperCat
```

- [ ] **Step 3: Fix entitlements (xcodegen overwrites them)**

Restore `WhisperCat/WhisperCat.entitlements` with audio-input entitlement.

- [ ] **Step 4: Build to verify dependency resolves**

```bash
xcodebuild build -project WhisperCat.xcodeproj -scheme WhisperCat -configuration Debug -quiet 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add project.yml WhisperCat.xcodeproj WhisperCat/WhisperCat.entitlements
git commit -m "feat: add mlx-swift-lm SPM dependency for text cleanup"
```

---

## Task 2: TextCleanupManager

**Files:**
- Create: `WhisperCat/Cleanup/TextCleanupManager.swift`

- [ ] **Step 1: Create the Cleanup directory**

```bash
mkdir -p WhisperCat/Cleanup
```

- [ ] **Step 2: Implement TextCleanupManager**

```swift
// WhisperCat/Cleanup/TextCleanupManager.swift
import Foundation
import MLXLLM
import MLXLMCommon

enum CleanupModelState: Equatable {
    case idle
    case loading
    case ready
    case error
}

@MainActor
final class TextCleanupManager: ObservableObject {
    @Published private(set) var state: CleanupModelState = .idle
    @Published private(set) var error: Error?

    private(set) var modelContainer: ModelContainer?

    private let modelName = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"

    var isReady: Bool { state == .ready }

    func loadModel() async {
        guard state == .idle || state == .error else { return }

        state = .loading
        error = nil

        do {
            let config = ModelConfiguration.configuration(id: modelName)
            let container = try await LLMModelFactory.shared.loadContainer(configuration: config)
            self.modelContainer = container
            self.state = .ready
        } catch {
            self.error = error
            self.state = .error
        }
    }

    func unloadModel() {
        modelContainer = nil
        state = .idle
        error = nil
    }
}
```

Note: The exact `MLXLLM` API may differ — check the resolved package source. The key classes are `ModelConfiguration`, `ModelContainer`, and `LLMModelFactory`. Verify by looking at the package's public API before finalizing.

- [ ] **Step 3: Regenerate Xcode project to pick up new file**

```bash
xcodegen generate
```

Fix entitlements again after xcodegen.

- [ ] **Step 4: Build to verify**

```bash
xcodebuild build -project WhisperCat.xcodeproj -scheme WhisperCat -configuration Debug -quiet 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add WhisperCat/Cleanup/TextCleanupManager.swift WhisperCat.xcodeproj project.yml WhisperCat/WhisperCat.entitlements
git commit -m "feat: add TextCleanupManager for MLX model lifecycle"
```

---

## Task 3: TextCleaner

**Files:**
- Create: `WhisperCat/Cleanup/TextCleaner.swift`

- [ ] **Step 1: Implement TextCleaner**

```swift
// WhisperCat/Cleanup/TextCleaner.swift
import Foundation
import MLXLLM
import MLXLMCommon

final class TextCleaner {
    private let cleanupManager: TextCleanupManager

    private static let systemPrompt = """
    Clean up this speech transcription. Remove filler words (um, uh, like, you know, so, basically, literally, right, I mean). \
    If the speaker corrects themselves (e.g. "actually let's say X", "no wait X", "I mean X", "sorry, X"), keep only the final correction. \
    Do not change the meaning, tone, or add any words. If the text is already clean or very short, return it unchanged. \
    Output only the cleaned text, nothing else.
    """

    private static let timeoutSeconds: TimeInterval = 3.0

    init(cleanupManager: TextCleanupManager) {
        self.cleanupManager = cleanupManager
    }

    /// Cleans up transcribed text using the local LLM.
    /// Returns the cleaned text, or the original text if cleanup fails or times out.
    func clean(text: String) async -> String {
        let container: ModelContainer? = await MainActor.run { cleanupManager.modelContainer }
        guard let container = container else { return text }

        // Estimate max tokens: roughly 1 token per 4 chars, then 2x
        let estimatedInputTokens = max(text.count / 4, 10)
        let maxOutputTokens = estimatedInputTokens * 2

        let messages: [[String: String]] = [
            ["role": "system", "content": Self.systemPrompt],
            ["role": "user", "content": text]
        ]

        do {
            let result = try await withTimeout(seconds: Self.timeoutSeconds) {
                try await container.perform { context in
                    let input = try await context.processor.prepare(
                        input: .init(messages: messages)
                    )
                    let result = try MLXLMCommon.generate(
                        input: input,
                        parameters: .init(temperature: 0.1),
                        context: context
                    ) { tokens in
                        tokens.count < maxOutputTokens ? .more : .stop
                    }
                    return result.output
                }
            }
            let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? text : cleaned
        } catch {
            return text
        }
    }

    /// Runs an async operation with a timeout. Returns the result or throws on timeout.
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
```

Note: The exact MLXLLM generation API (prepare/generate) may differ. Check the package source for the correct method signatures. The key pattern is: create messages → prepare input → generate with token limit → return output string.

- [ ] **Step 2: Build to verify**

```bash
xcodegen generate
# Fix entitlements
xcodebuild build -project WhisperCat.xcodeproj -scheme WhisperCat -configuration Debug -quiet 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add WhisperCat/Cleanup/TextCleaner.swift WhisperCat.xcodeproj WhisperCat/WhisperCat.entitlements
git commit -m "feat: add TextCleaner for LLM-powered text cleanup"
```

---

## Task 4: Wire Cleanup into AppState

**Files:**
- Modify: `WhisperCat/AppState.swift`

- [ ] **Step 1: Update AppState**

Add to properties:

```swift
@AppStorage("cleanupEnabled") var cleanupEnabled: Bool = true
let textCleanupManager = TextCleanupManager()
let textCleaner: TextCleaner
```

Update `init()`:

```swift
init() {
    self.transcriber = WhisperTranscriber(modelManager: modelManager)
    self.textCleaner = TextCleaner(cleanupManager: textCleanupManager)
}
```

Update `initialize()` — after `startHotkeyMonitor()`, add cleanup model loading in background:

```swift
// Load cleanup model in background (don't block Ready state)
if cleanupEnabled {
    Task {
        await textCleanupManager.loadModel()
    }
}
```

Update `stopRecordingAndTranscribe()` — after transcription, before paste:

```swift
if let text = await transcriber.transcribe(audioBuffer: buffer) {
    let finalText: String
    if cleanupEnabled && textCleanupManager.isReady {
        finalText = await textCleaner.clean(text: text)
    } else {
        finalText = text
    }
    textPaster.paste(text: finalText)
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build -project WhisperCat.xcodeproj -scheme WhisperCat -configuration Debug -quiet 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add WhisperCat/AppState.swift
git commit -m "feat: wire text cleanup into transcription pipeline"
```

---

## Task 5: Add Cleanup Toggle to MenuBarView

**Files:**
- Modify: `WhisperCat/UI/MenuBarView.swift`

- [ ] **Step 1: Add cleanup picker and status to MenuBarView**

After the Input Device picker and before the Divider/Restart section, add:

```swift
Divider()

Picker("Cleanup", selection: $appState.cleanupEnabled) {
    Text("Off").tag(false)
    Text("On").tag(true)
}
.onChange(of: appState.cleanupEnabled) { _, enabled in
    Task {
        if enabled {
            await appState.textCleanupManager.loadModel()
        } else {
            appState.textCleanupManager.unloadModel()
        }
    }
}

if appState.cleanupEnabled {
    switch appState.textCleanupManager.state {
    case .loading:
        Text("Loading cleanup model...")
            .font(.caption)
            .foregroundStyle(.secondary)
    case .error:
        Text("Cleanup model error")
            .font(.caption)
            .foregroundStyle(.red)
    case .ready:
        Text("Cleanup ready")
            .font(.caption)
            .foregroundStyle(.green)
    case .idle:
        EmptyView()
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build -project WhisperCat.xcodeproj -scheme WhisperCat -configuration Debug -quiet 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add WhisperCat/UI/MenuBarView.swift
git commit -m "feat: add cleanup on/off toggle to menu bar dropdown"
```

---

## Task 6: Test End-to-End

- [ ] **Step 1: Build and launch**

```bash
pkill -x WhisperCat; xcodebuild build -project WhisperCat.xcodeproj -scheme WhisperCat -configuration Debug -quiet
open ~/Library/Developer/Xcode/DerivedData/WhisperCat-*/Build/Products/Debug/WhisperCat.app
```

- [ ] **Step 2: Verify checklist**

1. App launches, loads WhisperKit model, shows "Ready"
2. Cleanup model loads in background (menu shows "Loading cleanup model..." then "Cleanup ready")
3. Hold Control, speak with filler words ("um so like I want to say hello"), release
4. Pasted text should have fillers removed
5. Toggle cleanup off — transcription still works, raw text is pasted
6. Toggle cleanup back on — model reloads
7. Speak with self-correction: "let's go to the store, actually no let's go to the park" → should paste "let's go to the park"

- [ ] **Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: text cleanup integration adjustments"
```

---

## Summary

| Task | Component | Dependencies |
|------|-----------|-------------|
| 1 | SPM dependency | None |
| 2 | TextCleanupManager | Task 1 |
| 3 | TextCleaner | Task 2 |
| 4 | AppState integration | Task 3 |
| 5 | MenuBarView toggle | Task 4 |
| 6 | End-to-end test | Task 5 |

All tasks are sequential — each builds on the previous.
