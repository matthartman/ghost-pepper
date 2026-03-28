# Pepper X Design

## Goal

Create `Pepper X`, a brand new Linux-native desktop app inspired by Ghost Pepper, with zero shared code, a first-class GNOME/Wayland experience, and full product parity with Ghost Pepper V1 as the baseline.

Pepper X is not a port. It is a new local-first dictation product for Linux.

## Product Positioning

Pepper X should preserve the product identity that makes Ghost Pepper useful:

- always-available background utility
- hold-to-talk dictation
- fully local speech transcription and cleanup
- OCR-informed cleanup
- persistent corrections and conservative learning
- history, reruns, and evaluation tooling

Pepper X should feel native to GNOME instead of mimicking macOS UI conventions literally.

## Agreed Constraints

- New repo in `obra`
- Zero shared code with Ghost Pepper
- GNOME-first
- Wayland-only for V1
- Fedora and Ubuntu as supported distros for V1
- Unsandboxed for V1
- Native `.deb` and `.rpm` distribution
- No cloud features
- Must work offline after install and model download
- Mainstream `x86_64` laptop CPU baseline
- Linux-native stack chosen from scratch
- Cleanup likely built on `llama.cpp`
- Speech likely built around Parakeet or another Linux-native local ASR stack
- Whisper compatibility is not required
- Modifier-only hold-to-talk is required
- A thin GNOME Shell extension is acceptable in V1

## Non-Goals

- Non-GNOME desktop support in V1
- X11-first design
- Flatpak or sandboxed packaging in V1
- Cloud APIs or remote inference
- GPU-first optimization
- Exact implementation parity with macOS internals
- Reusing Ghost Pepper code directly
- Broad plugin architecture

## Recommended Product Scope

Pepper X V1 should target full feature parity with the current macOS app in product behavior, while allowing Linux-native substitutions in implementation.

This includes:

- background utility behavior
- modifier-only hold-to-talk
- local speech transcription
- local cleanup with model selection
- OCR-assisted cleanup context
- deterministic corrections
- conservative post-paste learning
- history browser
- reruns with alternate models and prompts
- runtime/model diagnostics

## Recommended Architecture

Pepper X should use an app-first architecture with a thin GNOME Shell extension.

### Core principle

The Rust app owns all product logic. The GNOME extension exists only for shell-facing integration that GNOME Shell is uniquely positioned to provide.

### Main components

1. `Pepper X` desktop app
   - Rust
   - GTK4
   - libadwaita
   - owns session state, models, settings, history, and the full recording pipeline

2. Thin GNOME Shell extension
   - owns modifier-only global hotkey capture
   - can expose GNOME-native status affordances if useful
   - communicates with the app over a narrow IPC boundary

### Why this approach

- It preserves a first-class GNOME experience.
- It keeps the extension small and replaceable.
- It prevents GNOME Shell JS from becoming the home of core product logic.
- It gives the app a clean internal architecture that can evolve independently.

## System Boundaries

Pepper X should be split into focused subsystems with clear responsibilities.

### App shell

Responsibilities:

- application lifecycle
- settings window
- history window
- diagnostics surfaces
- model inventory and status
- startup/background behavior

### Session coordinator

Responsibilities:

- recording session state machine
- start/stop orchestration
- timing and trace collection
- coordination between audio, ASR, cleanup, OCR, insertion, and history

This should be the central runtime orchestrator, not a UI object.

### Audio subsystem

Responsibilities:

- microphone enumeration
- input device selection
- live capture
- buffering and segment handoff

### ASR subsystem

Responsibilities:

- local model download/bootstrap
- model cache management
- speech transcription
- speech model readiness and diagnostics

The baseline stack should be selected for Linux-native reliability on mainstream `x86_64`, not for cross-platform symmetry with macOS.

### Cleanup subsystem

Responsibilities:

- local cleanup runtime via `llama.cpp`
- cleanup model catalog
- prompt assembly
- OCR-informed prompt context
- deterministic correction passes
- fallback behavior when models are unavailable or unusable

The Ghost Pepper concepts of `Very fast`, `Fast`, and `Full` are worth preserving if they still benchmark well on Linux.

### OCR/context subsystem

Responsibilities:

- acquire frontmost-window or relevant screen content in a GNOME/Wayland-friendly way
- run local OCR
- provide bounded, supporting context for cleanup

OCR remains a supporting-input system, not a separate user-facing feature.

### Insertion subsystem

Responsibilities:

- insert final text into the focused app
- choose the most reliable insertion path for the current target
- expose diagnostics about which insertion path was used

The product requirement is successful focused-app text insertion. The implementation may vary between clipboard-assisted flows, accessibility-mediated insertion, and other Linux-native strategies.

### Corrections/learning subsystem

Responsibilities:

- persistent preferred transcriptions
- persistent commonly-misheard replacements
- conservative post-paste learning
- deterministic application of user-owned vocabulary and corrections

### History/lab subsystem

Responsibilities:

- persist archived runs
- store timing/model/prompt/OCR artifacts
- show detailed history
- rerun old recordings with different models/prompts
- support model/prompt comparison

This should be a first-class product pillar in Pepper X, not merely a debugging aid.

### GNOME integration subsystem

Responsibilities:

- GNOME Shell extension IPC
- modifier-only hold-to-talk
- optional shell-native controls/status

This seam should stay small and sharply defined.

## Linux-Native Feature Mapping

Pepper X should preserve Ghost Pepper capabilities while intentionally changing the implementation where Linux demands it.

### Background utility feel

Pepper X should remain an always-available utility, but it should express that through GNOME-native patterns instead of macOS menu bar metaphors.

### Modifier-only hold-to-talk

This is the strongest reason to accept a GNOME Shell extension in V1. The extension should be used to capture modifier-only chords and relay start/stop events to the app.

### Local transcription

Pepper X should choose a Linux-native local ASR stack from scratch, likely Parakeet-based, and explicitly avoid carrying a Whisper compatibility burden.

### Local cleanup

Cleanup should be based on `llama.cpp`, with the same product concepts Ghost Pepper already exposes:

- prompt editing
- cleanup model selection
- OCR-assisted cleanup
- deterministic corrections

### OCR

OCR should be rebuilt for Linux from scratch. The implementation may differ entirely from macOS, but the user-facing feature remains: use local OCR context to resolve likely recognition mistakes.

### Text insertion

Text insertion is a Linux-critical subsystem and should be designed as a first-class capability with multiple internal strategies and clear runtime diagnostics.

### History and diagnostics

Pepper X should exceed Ghost Pepper here. Linux users need stronger visibility into:

- model load state
- cache locations
- session timings
- insertion path
- extension connectivity
- OCR availability

## Repo Structure

Pepper X should live in a new `obra` repository, suggested name: `pepper-x`.

Suggested layout:

- `app/`
  Rust GTK4/libadwaita application
- `crates/`
  focused Rust crates for subsystem logic
- `gnome-extension/`
  thin GNOME Shell extension
- `packaging/`
  `.deb` and `.rpm` assets, desktop integration files, install scripts
- `docs/`
  specs, plans, compatibility notes, operational notes

This should be a single workspace repo, not multiple repos at V1.

## Distribution Strategy

V1 distribution should be:

- `.deb` for Ubuntu
- `.rpm` for Fedora
- unsandboxed installation

The app should rely on distro-native package updates rather than an in-app updater.

Flatpak should be deferred until after V1 and only reconsidered once the full feature set is stable under Linux desktop constraints.

## Testing Strategy

Pepper X needs more than unit tests because the risky seams are desktop integration seams.

### Unit tests

- session coordinator behavior
- cleanup pipeline and prompt assembly
- model catalog and runtime state
- history serialization
- correction and learning logic

### Integration tests

- app ↔ GNOME extension IPC
- model lifecycle and cache behavior
- archive generation and rerun behavior
- insertion strategy selection

### GNOME Wayland smoke tests

These are mandatory for V1:

- modifier-only hold-to-talk
- successful focused-app insertion
- OCR context capture
- history archive creation
- rerun flows with alternate models/prompts
- startup/background behavior

### Packaging verification

- fresh install on Fedora
- fresh install on Ubuntu
- upgrade flows
- uninstall cleanup expectations
- extension installation/enabling flow

## Decomposition Into Subprojects

Pepper X is too large for one implementation plan. It should be decomposed into distinct subprojects.

### 1. Linux shell and GNOME integration

Includes:

- Rust app shell
- settings/history window scaffolding
- background lifecycle
- thin GNOME extension
- modifier-only hotkey plumbing
- app/extension IPC

### 2. Audio and transcription runtime

Includes:

- microphone/device handling
- recording session core
- Linux-native ASR stack
- model download/cache/readiness

### 3. Cleanup, OCR, and corrections

Includes:

- `llama.cpp` cleanup runtime
- cleanup prompt pipeline
- OCR context
- deterministic correction store
- post-paste learning

### 4. History, reruns, and diagnostics

Includes:

- archival model
- history browser
- reruns
- side-by-side comparisons
- runtime diagnostics surfaces

### 5. Packaging and operational polish

Includes:

- `.deb` and `.rpm`
- desktop integration
- startup behavior
- install/upgrade docs
- release process

V1 should be planned and implemented in that order.

## Risks and Honest Constraints

### Modifier-only hotkeys

This is a real platform risk. The GNOME extension is the chosen mitigation, and V1 scope should not pretend this is a generic Linux capability.

### Focused-app insertion

This is another high-risk seam. Pepper X must treat insertion as a first-class subsystem with diagnostics and explicit smoke coverage.

### OCR/window context on Wayland

This must be designed around GNOME/Wayland realities from the start. We should not assume the macOS capture flow has an easy equivalent.

### Model performance on CPU-only `x86_64`

The Linux-native ASR and cleanup defaults must be benchmarked for real laptop usage, not assumed from macOS results.

## Recommended Next Step

Write the first implementation plan for subproject 1:

`Linux shell and GNOME integration`

That plan should establish:

- repo bootstrap
- Rust workspace shape
- GTK/libadwaita app shell
- GNOME extension scaffold
- IPC contract
- modifier-only hold-to-talk flow
- background utility presence

The rest of Pepper X should be layered on top of that foundation.
