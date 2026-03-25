# Cleanup Model Probe Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local CLI probe that loads Ghost Pepper's real cleanup models and shows prompt, raw output, sanitized output, and final cleaned output for exact inputs.

**Architecture:** Add a small executable target that reuses the app's cleanup pipeline through a thin shared probe runner instead of duplicating model and prompt logic. Keep app behavior unchanged while exposing one-shot and interactive command paths for debugging Qwen failures.

**Tech Stack:** Swift, XcodeGen project.yml, GhostPepper cleanup code, obra/LLM.swift

---

## Chunk 1: Shared Probe Runner

### Task 1: Extract a reusable cleanup probe runner

**Files:**
- Modify: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/Cleanup/TextCleaner.swift`
- Modify: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/Cleanup/TextCleanupManager.swift`
- Create: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepper/Cleanup/CleanupModelProbeRunner.swift`
- Test: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepperTests/CleanupModelProbeRunnerTests.swift`

- [ ] **Step 1: Write the failing tests for stage capture**

Add tests that prove a shared runner can report:
- effective prompt
- raw model output
- sanitized output
- final cleaned output
- selected thinking mode

Include a case where raw output is reasoning-only so the sanitized output becomes empty while raw output remains visible.

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/cleanup-probe-tests CODE_SIGNING_ALLOWED=NO -skipMacroValidation test -only-testing:GhostPepperTests/CleanupModelProbeRunnerTests
```

Expected: FAIL because the runner type does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create a small shared runner that:
- accepts input text, prompt, optional window context, and thinking mode
- invokes the same local cleanup model path used by the app
- returns a structured transcript object containing all stages

Only extract the minimum code needed from existing cleanup classes.

- [ ] **Step 4: Run test to verify it passes**

Run the same test command.

Expected: PASS

- [ ] **Step 5: Commit**

```sh
git add GhostPepper/Cleanup/TextCleaner.swift GhostPepper/Cleanup/TextCleanupManager.swift GhostPepper/Cleanup/CleanupModelProbeRunner.swift GhostPepperTests/CleanupModelProbeRunnerTests.swift
git commit -m "Add shared cleanup model probe runner"
```

## Chunk 2: Command-Line Probe Target

### Task 2: Add the executable target and one-shot command mode

**Files:**
- Modify: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/project.yml`
- Create: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/CleanupModelProbe/main.swift`
- Test: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepperTests/CleanupModelProbeRunnerTests.swift`

- [ ] **Step 1: Write the failing tests for argument parsing and transcript formatting**

Add tests for:
- model selection parsing
- thinking mode parsing
- one-shot transcript formatting

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/cleanup-probe-tests CODE_SIGNING_ALLOWED=NO -skipMacroValidation test -only-testing:GhostPepperTests/CleanupModelProbeRunnerTests
```

Expected: FAIL because probe CLI parsing/formatting helpers do not exist yet.

- [ ] **Step 3: Write minimal implementation**

Add a new executable target `CleanupModelProbe` that supports:
- `--model fast|full`
- `--input <text>`
- `--prompt <text>` optional
- `--window-context <text>` optional
- `--window-context-file <path>` optional
- `--thinking none|suppressed|enabled`

Print a readable transcript for one-shot runs.

- [ ] **Step 4: Run tests and a build to verify it passes**

Run:

```sh
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/cleanup-probe-tests CODE_SIGNING_ALLOWED=NO -skipMacroValidation test -only-testing:GhostPepperTests/CleanupModelProbeRunnerTests
xcodebuild -project GhostPepper.xcodeproj -scheme CleanupModelProbe -derivedDataPath build/cleanup-probe-cli CODE_SIGNING_ALLOWED=NO -skipMacroValidation build
```

Expected: PASS and `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```sh
git add project.yml CleanupModelProbe/main.swift GhostPepperTests/CleanupModelProbeRunnerTests.swift
git commit -m "Add cleanup model probe CLI"
```

## Chunk 3: Interactive Mode And Real-Model Verification

### Task 3: Add interactive REPL mode and verify against Qwen fast

**Files:**
- Modify: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/CleanupModelProbe/main.swift`
- Test: `/Users/jesse/.config/superpowers/worktrees/ghost-pepper/codex-qwen35-integration/GhostPepperTests/CleanupModelProbeRunnerTests.swift`

- [ ] **Step 1: Write the failing tests for interactive mode boundaries**

Cover:
- entering REPL mode without `--input`
- clean exit on EOF or `:quit`
- keeping the selected model loaded across multiple entries

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/cleanup-probe-tests CODE_SIGNING_ALLOWED=NO -skipMacroValidation test -only-testing:GhostPepperTests/CleanupModelProbeRunnerTests
```

Expected: FAIL because interactive mode is not implemented yet.

- [ ] **Step 3: Write minimal implementation**

Add interactive mode that:
- loads the selected model once
- prompts for input repeatedly
- supports `:quit`
- prints one transcript per entry

- [ ] **Step 4: Run tests and verify with the real fast model**

Run:

```sh
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -derivedDataPath build/cleanup-probe-tests CODE_SIGNING_ALLOWED=NO -skipMacroValidation test
xcodebuild -project GhostPepper.xcodeproj -scheme CleanupModelProbe -derivedDataPath build/cleanup-probe-cli CODE_SIGNING_ALLOWED=NO -skipMacroValidation build
./build/cleanup-probe-cli/Build/Products/Debug/CleanupModelProbe --model fast --input "Okay, it's running now." --thinking none
./build/cleanup-probe-cli/Build/Products/Debug/CleanupModelProbe --model fast --input "Okay, it's running now." --thinking suppressed
```

Expected:
- full test suite passes
- CLI builds
- one-shot runs print stage-by-stage output
- the difference between `none` and `suppressed` is visible for the fast Qwen model

- [ ] **Step 5: Commit**

```sh
git add CleanupModelProbe/main.swift GhostPepperTests/CleanupModelProbeRunnerTests.swift
git commit -m "Add interactive cleanup model probe mode"
```
