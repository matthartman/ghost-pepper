# Paste Fallback Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fall back to leaving transcribed text on the clipboard and telling the user to press Cmd-V when Ghost Pepper cannot confidently paste into the current target.

**Architecture:** Add an Accessibility-based preflight to `TextPaster` so paste attempts only proceed when there is a plausible focused editable text target and a Command-V event can be prepared. Return a small paste result to `AppState`, and use the existing overlay to announce the clipboard fallback without stealing focus.

**Tech Stack:** Swift, AppKit, Accessibility APIs, XCTest

---

## Chunk 1: TextPaster flow

### Task 1: Cover the new paste outcomes

**Files:**
- Modify: `GhostPepperTests/TextPasterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testPasteLeavesTranscriptOnClipboardWhenFocusedInputIsUnavailable()
func testPasteSchedulesCommandVAndRestoresClipboardWhenFocusedInputIsAvailable()
```

- [ ] **Step 2: Run the targeted test to verify it fails**

Run: `xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:GhostPepperTests/TextPasterTests`
Expected: FAIL because `TextPaster` does not report outcomes or preflight paste targets yet.

- [ ] **Step 3: Write the minimal implementation**

Add a small `PasteResult` enum, inject just enough dependencies into `TextPaster` to test scheduling and event preparation, and gate the simulated paste behind an AX-based focused-input check.

- [ ] **Step 4: Run the targeted test to verify it passes**

Run: `xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:GhostPepperTests/TextPasterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GhostPepper/Input/TextPaster.swift GhostPepperTests/TextPasterTests.swift docs/superpowers/plans/2026-03-28-paste-fallback.md
git commit -m "feat: add paste fallback preflight"
```

## Chunk 2: User-facing fallback message

### Task 2: Announce the clipboard fallback without stealing focus

**Files:**
- Modify: `GhostPepper/UI/RecordingOverlay.swift`
- Modify: `GhostPepper/AppState.swift`

- [ ] **Step 1: Write the failing test**

Use the `TextPaster` result from Task 1 as the behavior contract. No new UI test is required if the announcement is a thin mapping from that result to the existing overlay.

- [ ] **Step 2: Implement the minimal announcement flow**

Add an overlay message for the clipboard fallback and show it briefly when `TextPaster` returns the fallback result.

- [ ] **Step 3: Run focused verification**

Run:
- `xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/test-derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO test -only-testing:GhostPepperTests/TextPasterTests`
- `xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -configuration Debug -derivedDataPath build/derived -skipMacroValidation CODE_SIGNING_ALLOWED=NO build`

Expected: PASS / BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add GhostPepper/AppState.swift GhostPepper/UI/RecordingOverlay.swift
git commit -m "feat: announce clipboard paste fallback"
```
