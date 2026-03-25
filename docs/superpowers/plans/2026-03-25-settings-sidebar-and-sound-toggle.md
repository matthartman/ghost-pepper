# Settings Sidebar And Sound Toggle Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single `Play sounds` preference and rebuild Ghost Pepper's settings window into a large, spacious, macOS-style sidebar settings app without removing any existing settings.

**Architecture:** Keep `SettingsWindowController` as the AppKit host, but move the settings content to a SwiftUI sidebar/detail shell driven by a `SettingsSection` enum. Preserve existing settings logic and helpers, add a persisted sound preference in `AppState`, and split the current monolithic settings form into focused section views.

**Tech Stack:** SwiftUI, AppKit `NSWindow`, `UserDefaults`/`@AppStorage`, XCTest

---

## File Structure

**Modify:**
- `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/AppState.swift`
  - Add persisted sound preference state and defaults wiring.
- `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/Audio/SoundEffects.swift`
  - Make sound playback conditional on the new setting.
- `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/UI/SettingsWindow.swift`
  - Replace the single-page form with a larger sidebar/detail SwiftUI shell and section subviews.
- `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepperTests/GhostPepperTests.swift`
  - Extend window-host and app-state tests for the new settings structure and sound preference persistence.

**Create:**
- None required if the section views remain nested in `SettingsWindow.swift`.
- Optional follow-up extraction only if `SettingsWindow.swift` becomes unreasonably large during implementation.

**Test:**
- `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepperTests/GhostPepperTests.swift`

---

## Chunk 1: Sound Preference Plumbing

### Task 1: Add a failing persistence test for the new sound preference

**Files:**
- Modify: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepperTests/GhostPepperTests.swift`
- Modify: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/AppState.swift`

- [ ] **Step 1: Write the failing test**

Add tests that prove:
- a fresh `AppState` defaults to sounds enabled
- changing the setting persists into the provided defaults suite
- a newly created `AppState` reloads the persisted value

- [ ] **Step 2: Run the test to verify it fails**

Run:
```sh
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/settings-sound-red -clonedSourcePackagesDirPath build/settings-sound-red-source CODE_SIGNING_ALLOWED=NO -skipMacroValidation -only-testing:GhostPepperTests/GhostPepperTests/testAppStateDefaultsSoundsEnabled -only-testing:GhostPepperTests/GhostPepperTests/testAppStatePersistsSoundPreference test
```

Expected:
- the new tests fail because `AppState` does not expose or persist a sound preference yet

- [ ] **Step 3: Implement the minimal app-state preference**

In `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/AppState.swift`:
- add a persisted `playSounds` setting
- store it in defaults with the rest of the app-owned preferences
- keep the default `true`

- [ ] **Step 4: Run the same test to verify it passes**

Run the same command from Step 2.

Expected:
- both new tests pass

- [ ] **Step 5: Commit**

```sh
git add GhostPepper/AppState.swift GhostPepperTests/GhostPepperTests.swift
git commit -m "Persist sound effects preference"
```

### Task 2: Make `SoundEffects` honor the setting

**Files:**
- Modify: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/Audio/SoundEffects.swift`
- Modify: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/AppState.swift`
- Test: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepperTests/GhostPepperTests.swift`

- [ ] **Step 1: Write a failing behavior test**

Add a small test seam around `SoundEffects` so a test can verify that playback is skipped when sounds are disabled.

- [ ] **Step 2: Run the targeted test and verify it fails**

Run:
```sh
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/sound-effects-red -clonedSourcePackagesDirPath build/sound-effects-red-source CODE_SIGNING_ALLOWED=NO -skipMacroValidation -only-testing:GhostPepperTests/GhostPepperTests/testSoundEffectsSkipPlaybackWhenDisabled test
```

Expected:
- the test fails because `SoundEffects` always plays today

- [ ] **Step 3: Implement the minimal guard**

Update `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/Audio/SoundEffects.swift` to accept a simple enabled provider or equivalent test seam, and wire it from `AppState`.

- [ ] **Step 4: Run the targeted test to verify it passes**

Run the same command from Step 2.

Expected:
- the test passes

- [ ] **Step 5: Commit**

```sh
git add GhostPepper/Audio/SoundEffects.swift GhostPepper/AppState.swift GhostPepperTests/GhostPepperTests.swift
git commit -m "Honor sound effects preference"
```

---

## Chunk 2: Settings Window Shell

### Task 3: Add a failing settings window size test

**Files:**
- Modify: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepperTests/GhostPepperTests.swift`
- Modify: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/UI/SettingsWindow.swift`

- [ ] **Step 1: Write the failing test**

Add a test asserting that the settings window opens substantially larger than the current `420x700` frame.

- [ ] **Step 2: Run the targeted test and verify it fails**

Run:
```sh
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/settings-window-size-red -clonedSourcePackagesDirPath build/settings-window-size-red-source CODE_SIGNING_ALLOWED=NO -skipMacroValidation -only-testing:GhostPepperTests/GhostPepperTests/testSettingsWindowUsesLargeRoomyFrame test
```

Expected:
- the test fails because the existing window frame is still compact

- [ ] **Step 3: Implement the larger window frame**

Update `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/UI/SettingsWindow.swift` to use the new larger default size while preserving existing window reuse and close behavior.

- [ ] **Step 4: Run the targeted test to verify it passes**

Run the same command from Step 2.

Expected:
- the test passes

- [ ] **Step 5: Commit**

```sh
git add GhostPepper/UI/SettingsWindow.swift GhostPepperTests/GhostPepperTests.swift
git commit -m "Increase settings window size"
```

### Task 4: Replace the single long form with a sidebar shell

**Files:**
- Modify: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/UI/SettingsWindow.swift`
- Test: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepperTests/GhostPepperTests.swift`

- [ ] **Step 1: Add a shallow failing structure test**

Add a test that proves the settings window still hosts SwiftUI content and remains reusable after the shell conversion. Prefer reinforcing the existing hosting/reuse tests over brittle visual assertions.

- [ ] **Step 2: Run the relevant settings window tests**

Run:
```sh
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/settings-shell-red -clonedSourcePackagesDirPath build/settings-shell-red-source CODE_SIGNING_ALLOWED=NO -skipMacroValidation -only-testing:GhostPepperTests/GhostPepperTests/testSettingsWindowHostsSwiftUIViaContentViewController -only-testing:GhostPepperTests/GhostPepperTests/testSettingsWindowControllerCloseButtonOrdersWindowOutWithoutClosing -only-testing:GhostPepperTests/GhostPepperTests/testAppStateShowSettingsReusesSingleWindow test
```

Expected:
- at least one test fails once the shell test is added

- [ ] **Step 3: Implement the sidebar shell**

In `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/UI/SettingsWindow.swift`:
- add `SettingsSection`
- add a SwiftUI root shell with sidebar selection and detail pane
- keep the AppKit host window controller intact
- preserve all existing helper objects needed by the settings content

- [ ] **Step 4: Re-run the targeted settings window tests**

Run the same command from Step 2.

Expected:
- all targeted tests pass

- [ ] **Step 5: Commit**

```sh
git add GhostPepper/UI/SettingsWindow.swift GhostPepperTests/GhostPepperTests.swift
git commit -m "Add sidebar settings shell"
```

---

## Chunk 3: Move Existing Settings Into Section Views

### Task 5: Build out the `Recording` page and add the `Play sounds` toggle

**Files:**
- Modify: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/UI/SettingsWindow.swift`
- Modify: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/AppState.swift`
- Test: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepperTests/GhostPepperTests.swift`

- [ ] **Step 1: Add a failing recording-page expectation**

Add a shallow test or state-level assertion covering the presence/wiring of the new sound toggle through `AppState`.

- [ ] **Step 2: Run the targeted test**

Run:
```sh
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/settings-recording-red -clonedSourcePackagesDirPath build/settings-recording-red-source CODE_SIGNING_ALLOWED=NO -skipMacroValidation -only-testing:GhostPepperTests/GhostPepperTests/testAppStatePersistsSoundPreference test
```

Expected:
- failure until the recording page is wired to the new state

- [ ] **Step 3: Implement `RecordingSettingsView`**

Move these controls into the new recording section:
- shortcuts
- microphone picker
- live mic preview
- level meter
- speech model picker
- `Play sounds`

- [ ] **Step 4: Run the targeted sound/state test again**

Expected:
- the test passes

- [ ] **Step 5: Commit**

```sh
git add GhostPepper/UI/SettingsWindow.swift GhostPepper/AppState.swift GhostPepperTests/GhostPepperTests.swift
git commit -m "Add recording settings section"
```

### Task 6: Move cleanup and corrections into their own pages

**Files:**
- Modify: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/UI/SettingsWindow.swift`

- [ ] **Step 1: Run a focused existing settings smoke suite**

Run:
```sh
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/settings-cleanup-sections-pre -clonedSourcePackagesDirPath build/settings-cleanup-sections-pre-source CODE_SIGNING_ALLOWED=NO -skipMacroValidation -only-testing:GhostPepperTests/GhostPepperTests/testSettingsWindowHostsSwiftUIViaContentViewController -only-testing:GhostPepperTests/GhostPepperTests/testAppStateShowSettingsReusesSingleWindow test
```

Expected:
- current tests pass before the refactor

- [ ] **Step 2: Implement `CleanupSettingsView` and `CorrectionsSettingsView`**

Move the existing cleanup, OCR context, post-paste learning, and corrections editors into dedicated section views.

- [ ] **Step 3: Re-run the same smoke suite**

Expected:
- tests still pass

- [ ] **Step 4: Commit**

```sh
git add GhostPepper/UI/SettingsWindow.swift
git commit -m "Split cleanup and corrections settings"
```

### Task 7: Move models and general settings into their own pages

**Files:**
- Modify: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/UI/SettingsWindow.swift`

- [ ] **Step 1: Run a focused settings smoke suite**

Run:
```sh
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/settings-models-general-pre -clonedSourcePackagesDirPath build/settings-models-general-pre-source CODE_SIGNING_ALLOWED=NO -skipMacroValidation -only-testing:GhostPepperTests/GhostPepperTests/testSettingsWindowControllerCloseButtonOrdersWindowOutWithoutClosing -only-testing:GhostPepperTests/GhostPepperTests/testAppStateShowSettingsReusesSingleWindow test
```

Expected:
- tests pass before the move

- [ ] **Step 2: Implement `ModelsSettingsView` and `GeneralSettingsView`**

Move the model inventory/download UI and launch-at-login control into dedicated pages.

- [ ] **Step 3: Re-run the smoke suite**

Expected:
- tests still pass

- [ ] **Step 4: Commit**

```sh
git add GhostPepper/UI/SettingsWindow.swift
git commit -m "Split models and general settings"
```

---

## Chunk 4: Verification And Finish

### Task 8: Run full verification

**Files:**
- No new files

- [ ] **Step 1: Run the full app test suite**

Run:
```sh
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/settings-sidebar-full -clonedSourcePackagesDirPath build/settings-sidebar-full-source CODE_SIGNING_ALLOWED=NO -skipMacroValidation test
```

Expected:
- full suite passes

- [ ] **Step 2: Build a signed local app**

Run:
```sh
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -configuration Debug -derivedDataPath build/settings-sidebar-signed -clonedSourcePackagesDirPath build/settings-sidebar-signed-source -skipMacroValidation CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Developer ID Application: Jesse Vincent (87WJ58S66M)' DEVELOPMENT_TEAM=87WJ58S66M build
```

Expected:
- `** BUILD SUCCEEDED **`

- [ ] **Step 3: Install and launch the signed app**

Run:
```sh
rm -rf /Applications/GhostPepper.app
cp -R build/settings-sidebar-signed/Build/Products/Debug/GhostPepper.app /Applications/GhostPepper.app
open -na /Applications/GhostPepper.app
```

Expected:
- the signed app launches successfully

- [ ] **Step 4: Manual smoke check**

Verify:
- settings window opens large and roomy
- sidebar navigation works
- all existing settings remain available
- toggling `Play sounds` immediately suppresses start/stop sounds

- [ ] **Step 5: Commit**

```sh
git add GhostPepper/AppState.swift GhostPepper/Audio/SoundEffects.swift GhostPepper/UI/SettingsWindow.swift GhostPepperTests/GhostPepperTests.swift
git commit -m "Redesign settings window and add sound toggle"
```
