# Pepper X Shell And GNOME Integration Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bootstrap the new `pepper-x` repo as a GNOME-first Linux desktop app with a Rust GTK4/libadwaita shell, a thin GNOME Shell extension, a narrow IPC contract between them, and working modifier-only hold-to-talk signaling.

**Architecture:** Build the smallest serious foundation for Pepper X as two cooperating parts: a Rust desktop app that owns product/runtime state and a GNOME Shell extension that owns shell-facing hotkey integration. Keep the extension thin by routing every meaningful action through a small app-owned IPC daemon and prove the modifier-only hold-to-talk loop end to end before touching ASR, cleanup, OCR, or insertion.

**Tech Stack:** Rust, Cargo workspace, GTK4, libadwaita, D-Bus, GObject Introspection, GNOME Shell extension (GJS), Debian packaging, RPM packaging, shell-based smoke tests

---

## File Structure

**Repository root:** `pepper-x/`

**Create:**
- `Cargo.toml`
  - Workspace root declaring the app crate and internal crates.
- `Cargo.lock`
  - Generated Cargo lockfile checked into the repo.
- `README.md`
  - Linux-specific build, install, and development entrypoint.
- `.gitignore`
  - Rust, GNOME extension, and packaging build outputs.
- `docs/architecture/gnome-integration.md`
  - Short reference for the app ↔ extension contract and required GNOME assumptions.
- `app/Cargo.toml`
  - Main GTK/libadwaita application crate.
- `app/src/main.rs`
  - Desktop app entrypoint.
- `app/src/app.rs`
  - `adw::Application` setup and application lifecycle.
- `app/src/window.rs`
  - Main settings/history shell window stub.
- `app/src/background.rs`
  - Background-app lifecycle, startup policy, and action wiring.
- `app/src/settings.rs`
  - App-side settings model for shell/integration configuration.
- `crates/pepperx-ipc/Cargo.toml`
  - IPC crate manifest.
- `crates/pepperx-ipc/src/lib.rs`
  - Shared Rust-side IPC contract types and helpers.
- `crates/pepperx-session/Cargo.toml`
  - Session state crate manifest.
- `crates/pepperx-session/src/lib.rs`
  - Recording session state machine without audio logic yet.
- `crates/pepperx-platform-gnome/Cargo.toml`
  - GNOME-specific host integration crate manifest.
- `crates/pepperx-platform-gnome/src/lib.rs`
  - Thin GNOME-facing service bootstrap from the app side.
- `crates/pepperx-platform-gnome/src/service.rs`
  - D-Bus service implementation for extension communication.
- `gnome-extension/metadata.json`
  - GNOME extension manifest.
- `gnome-extension/extension.js`
  - Extension entrypoint.
- `gnome-extension/ipc.js`
  - D-Bus client wrapper for talking to the app service.
- `gnome-extension/keybindings.js`
  - Modifier-only and normal shortcut registration code.
- `gnome-extension/README.md`
  - Development and install instructions for the extension.
- `packaging/deb/pepper-x.desktop`
  - Desktop entry for Debian-family packaging.
- `packaging/deb/pepper-x-autostart.desktop`
  - Autostart desktop entry.
- `packaging/deb/control`
  - Debian package metadata skeleton.
- `packaging/rpm/pepper-x.spec`
  - RPM spec skeleton.
- `packaging/tests/test_metadata.py`
  - Lightweight packaging metadata checks for desktop file and package spec consistency.
- `scripts/dev-run-app.sh`
  - Local helper to run the Rust app in development.
- `scripts/dev-install-extension.sh`
  - Local helper to install/reload the GNOME extension in development.
- `scripts/smoke-hotkey.sh`
  - End-to-end smoke helper for modifier-only signaling.
- `tests/smoke/test_extension_ipc.sh`
  - Scripted D-Bus smoke test for app/extension reachability.
- `tests/smoke/test_modifier_only_hotkey.md`
  - Manual GNOME Wayland smoke-test checklist.

**Test:**
- `app/src/app.rs`
- `app/src/background.rs`
- `app/src/settings.rs`
- `crates/pepperx-ipc/src/lib.rs`
- `crates/pepperx-session/src/lib.rs`
- `crates/pepperx-platform-gnome/src/service.rs`
- `tests/smoke/test_extension_ipc.sh`

---

## Chunk 1: Workspace Bootstrap

### Task 1: Create the new repo skeleton and failing bootstrap checks

**Files:**
- Create: `Cargo.toml`
- Create: `.gitignore`
- Create: `README.md`
- Create: `app/Cargo.toml`
- Create: `app/src/main.rs`
- Create: `tests/smoke/test_extension_ipc.sh`

- [ ] **Step 1: Create the empty repo structure**

Create the top-level directories and empty files listed above so the repo has a stable workspace shape from the start.

- [ ] **Step 2: Write the failing bootstrap checks**

Add:
- a workspace manifest that references `app`, `crates/pepperx-ipc`, `crates/pepperx-session`, and `crates/pepperx-platform-gnome`
- a placeholder `app` crate manifest that does not yet build successfully because the referenced modules do not exist
- a smoke script that exits non-zero until the D-Bus service name is reachable

- [ ] **Step 3: Run the bootstrap checks to verify failure**

Run:
```sh
cd pepper-x
cargo check --workspace
bash tests/smoke/test_extension_ipc.sh
```

Expected:
- `cargo check --workspace` fails because the internal crates and modules are not implemented yet
- the IPC smoke script fails because no service is available yet

- [ ] **Step 4: Fill in the minimal workspace bootstrap**

Implement the smallest working setup:
- a compiling workspace root
- a compiling `app` crate that starts and exits cleanly
- a README with local build prerequisites for Fedora and Ubuntu
- `.gitignore` covering Cargo, packaging, and extension outputs

- [ ] **Step 5: Re-run the bootstrap checks**

Run the commands from Step 3.

Expected:
- `cargo check --workspace` passes
- the smoke script still fails because IPC is not implemented yet

- [ ] **Step 6: Commit**

```bash
git -C pepper-x status --short
git -C pepper-x add Cargo.toml Cargo.lock .gitignore README.md app/Cargo.toml app/src/main.rs tests/smoke/test_extension_ipc.sh
git -C pepper-x commit -m "Bootstrap Pepper X Rust workspace"
```

---

## Chunk 2: GTK4/libadwaita App Shell

### Task 2: Add failing tests for a GNOME-style background app shell

**Files:**
- Modify: `app/Cargo.toml`
- Create: `app/src/app.rs`
- Create: `app/src/window.rs`
- Create: `app/src/background.rs`
- Create: `app/src/settings.rs`

- [ ] **Step 1: Write the failing app-shell tests**

Add Rust tests that prove:
- the app can build an `adw::Application` with a stable application ID
- the main window can be created without starting recording/transcription logic
- the background controller exposes actions for `show-settings`, `show-history`, and `quit`
- the settings model includes integration toggles for:
  - launch at login
  - enable GNOME extension integration
  - preferred recording trigger mode

- [ ] **Step 2: Run the targeted tests to verify failure**

Run:
```sh
cd pepper-x
cargo test -p pepper-x-app app_shell -- --nocapture
```

Expected:
- the new tests fail because the app shell modules and actions do not exist yet

- [ ] **Step 3: Implement the minimal app shell**

Implement:
- `app/src/app.rs` with the `adw::Application` bootstrap
- `app/src/window.rs` with a simple GNOME-native window shell
- `app/src/background.rs` with application actions and background behavior
- `app/src/settings.rs` with a lightweight serializable settings model

Keep the UI intentionally shallow:
- a settings shell window
- a history shell placeholder
- no transcription or cleanup UI yet

- [ ] **Step 4: Re-run the targeted tests**

Run the command from Step 2.

Expected:
- the app shell tests pass

- [ ] **Step 5: Run a manual development smoke**

Run:
```sh
cd pepper-x
./scripts/dev-run-app.sh
```

Expected:
- the app launches as a GTK/libadwaita window
- the shell actions exist
- no transcription/runtime logic is required yet

- [ ] **Step 6: Commit**

```bash
git -C pepper-x status --short
git -C pepper-x add app/Cargo.toml app/src/app.rs app/src/window.rs app/src/background.rs app/src/settings.rs scripts/dev-run-app.sh
git -C pepper-x commit -m "Add Pepper X GTK app shell"
```

---

## Chunk 3: Session State And IPC Contract

### Task 3: Add failing tests for the app-owned recording session state machine

**Files:**
- Create: `crates/pepperx-session/Cargo.toml`
- Create: `crates/pepperx-session/src/lib.rs`

- [ ] **Step 1: Write the failing session-state tests**

Add tests that prove:
- a session starts in `Idle`
- `start_recording` transitions to `Recording`
- `stop_recording` transitions back to `Idle`
- a duplicate `start_recording` request while already recording is rejected
- a duplicate `stop_recording` request while idle is rejected
- the state machine tracks trigger source as:
  - `ModifierOnly`
  - `StandardShortcut`
  - `ShellAction`

- [ ] **Step 2: Run the targeted tests to verify failure**

Run:
```sh
cd pepper-x
cargo test -p pepperx-session -- --nocapture
```

Expected:
- the tests fail because the session crate does not exist yet

- [ ] **Step 3: Implement the minimal session crate**

Implement a small crate with:
- session state enum
- trigger source enum
- transition methods returning explicit results
- no audio or model logic

- [ ] **Step 4: Re-run the targeted tests**

Run the command from Step 2.

Expected:
- all session tests pass

- [ ] **Step 5: Commit**

```bash
git -C pepper-x status --short
git -C pepper-x add crates/pepperx-session/Cargo.toml crates/pepperx-session/src/lib.rs
git -C pepper-x commit -m "Add Pepper X session state machine"
```

### Task 4: Add failing tests for the D-Bus contract between app and extension

**Files:**
- Create: `crates/pepperx-ipc/Cargo.toml`
- Create: `crates/pepperx-ipc/src/lib.rs`
- Create: `crates/pepperx-platform-gnome/Cargo.toml`
- Create: `crates/pepperx-platform-gnome/src/lib.rs`
- Create: `crates/pepperx-platform-gnome/src/service.rs`

- [ ] **Step 1: Write the failing IPC tests**

Add tests that prove the contract supports:
- `Ping`
- `StartRecording`
- `StopRecording`
- `ShowSettings`
- `ShowHistory`
- `GetCapabilities`

Also add a serialization round-trip test for the capability payload, including:
- `modifier_only_supported`
- `extension_connected`
- `version`

- [ ] **Step 2: Run the targeted tests to verify failure**

Run:
```sh
cd pepper-x
cargo test -p pepperx-ipc -p pepperx-platform-gnome -- --nocapture
```

Expected:
- tests fail because the IPC contract and D-Bus service are not implemented

- [ ] **Step 3: Implement the minimal IPC contract and service**

Implement:
- shared message and capability types in `pepperx-ipc`
- one D-Bus service in `pepperx-platform-gnome`
- app-side handler functions that translate IPC requests into:
  - session state changes
  - shell action routing
- `docs/architecture/gnome-integration.md` documenting:
  - the D-Bus service name
  - method list
  - capability payload
  - extension startup expectations

Do not add speculative RPCs for future ASR/cleanup features.

- [ ] **Step 4: Re-run the targeted tests**

Run the command from Step 2.

Expected:
- all IPC/service tests pass

- [ ] **Step 5: Update the smoke test**

Update `tests/smoke/test_extension_ipc.sh` so it:
- starts the app dev shell
- verifies the D-Bus name is present
- verifies `Ping` succeeds

- [ ] **Step 6: Re-run the smoke script**

Run:
```sh
cd pepper-x
bash tests/smoke/test_extension_ipc.sh
```

Expected:
- the smoke script passes

- [ ] **Step 7: Commit**

```bash
git -C pepper-x status --short
git -C pepper-x add crates/pepperx-ipc/Cargo.toml crates/pepperx-ipc/src/lib.rs crates/pepperx-platform-gnome/Cargo.toml crates/pepperx-platform-gnome/src/lib.rs crates/pepperx-platform-gnome/src/service.rs tests/smoke/test_extension_ipc.sh docs/architecture/gnome-integration.md
git -C pepper-x commit -m "Add Pepper X GNOME IPC service"
```

---

## Chunk 4: GNOME Extension Scaffold

### Task 5: Add failing extension tests and a minimal extension scaffold

**Files:**
- Create: `gnome-extension/metadata.json`
- Create: `gnome-extension/extension.js`
- Create: `gnome-extension/ipc.js`
- Create: `gnome-extension/keybindings.js`
- Create: `gnome-extension/README.md`

- [ ] **Step 1: Write the failing extension checks**

Add development checks that verify:
- `metadata.json` declares the correct UUID, shell version target, and entrypoint
- `extension.js` enables and disables cleanly
- `ipc.js` can build a D-Bus client for the Pepper X service
- `keybindings.js` exposes registration helpers without wiring modifier-only behavior yet

Use lightweight JS linting or scripted checks rather than inventing a large extension test harness.

- [ ] **Step 2: Run the extension checks to verify failure**

Run:
```sh
cd pepper-x
./scripts/dev-install-extension.sh --check
```

Expected:
- the script fails because the extension files are incomplete or missing

- [ ] **Step 3: Implement the minimal extension scaffold**

Implement:
- `metadata.json`
- enable/disable lifecycle in `extension.js`
- D-Bus client helper in `ipc.js`
- registration abstraction in `keybindings.js`

The extension should be able to:
- start
- reach the app service
- expose one manual shell action that opens Pepper X settings

- [ ] **Step 4: Re-run the extension checks**

Run the command from Step 2.

Expected:
- the extension checks pass

- [ ] **Step 5: Manually verify GNOME Shell integration**

Run:
```sh
cd pepper-x
./scripts/dev-install-extension.sh
```

Expected:
- the extension installs in the user session
- it can be enabled and disabled cleanly
- invoking the test action reaches the app and opens settings

- [ ] **Step 6: Commit**

```bash
git -C pepper-x status --short
git -C pepper-x add gnome-extension/metadata.json gnome-extension/extension.js gnome-extension/ipc.js gnome-extension/keybindings.js gnome-extension/README.md scripts/dev-install-extension.sh
git -C pepper-x commit -m "Add Pepper X GNOME extension scaffold"
```

---

## Chunk 5: Modifier-Only Hold-To-Talk

### Task 6: Add failing tests for modifier-only GNOME hotkey signaling

**Files:**
- Modify: `gnome-extension/keybindings.js`
- Modify: `gnome-extension/extension.js`
- Modify: `crates/pepperx-session/src/lib.rs`
- Modify: `crates/pepperx-platform-gnome/src/service.rs`
- Create: `tests/smoke/test_modifier_only_hotkey.md`

- [ ] **Step 1: Write the failing tests and smoke expectations**

Add checks that prove:
- the extension can register a modifier-only trigger path
- pressing the configured modifier-only trigger sends `StartRecording`
- releasing the modifier-only trigger sends `StopRecording`
- the session state machine rejects duplicate starts/stops cleanly
- if the app service is unavailable, the extension logs a clear error instead of hanging

Because GNOME Shell modifier-only behavior is hard to unit test exhaustively, pair narrow code checks with a mandatory manual smoke checklist in `tests/smoke/test_modifier_only_hotkey.md`.

- [ ] **Step 2: Run the targeted automated checks to verify failure**

Run:
```sh
cd pepper-x
cargo test -p pepperx-session -p pepperx-platform-gnome -- --nocapture
./scripts/smoke-hotkey.sh
```

Expected:
- one or both checks fail because modifier-only signaling is not implemented yet

- [ ] **Step 3: Implement the minimal modifier-only flow**

Implement:
- GNOME extension registration for the configured modifier-only trigger
- extension-side start/stop calls over D-Bus
- app-side state transitions through `pepperx-session`
- clear logging for:
  - start sent
  - stop sent
  - app unavailable
  - duplicate request ignored

Keep this strictly as signaling. Do not start audio capture or ASR yet.

- [ ] **Step 4: Re-run the automated checks**

Run the commands from Step 2.

Expected:
- automated checks pass

- [ ] **Step 5: Run the manual GNOME Wayland smoke**

Follow `tests/smoke/test_modifier_only_hotkey.md` and verify:
- modifier-only press triggers `StartRecording`
- release triggers `StopRecording`
- repeated use stays stable across multiple attempts
- disabling the extension removes the behavior cleanly

- [ ] **Step 6: Commit**

```bash
git -C pepper-x status --short
git -C pepper-x add gnome-extension/keybindings.js gnome-extension/extension.js crates/pepperx-session/src/lib.rs crates/pepperx-platform-gnome/src/service.rs scripts/smoke-hotkey.sh tests/smoke/test_modifier_only_hotkey.md
git -C pepper-x commit -m "Add modifier-only GNOME recording triggers"
```

---

## Chunk 6: Packaging Skeleton And Developer Workflow

### Task 7: Add failing packaging checks for Fedora and Ubuntu installs

**Files:**
- Create: `packaging/deb/pepper-x.desktop`
- Create: `packaging/deb/pepper-x-autostart.desktop`
- Create: `packaging/deb/control`
- Create: `packaging/rpm/pepper-x.spec`
- Create: `packaging/tests/test_metadata.py`

- [ ] **Step 1: Write the failing packaging checks**

Add packaging checks that verify:
- the desktop file uses the intended application ID and executable name
- the autostart file points at the same executable
- Debian metadata is internally consistent
- RPM spec references the same installed paths

- [ ] **Step 2: Run the packaging checks to verify failure**

Run:
```sh
cd pepper-x
python3 -m pytest packaging/tests -q
```

Expected:
- tests fail because the packaging metadata files do not exist yet

- [ ] **Step 3: Implement the minimal packaging skeleton**

Add:
- desktop file
- autostart file
- Debian metadata stub
- RPM spec stub
- minimal metadata checks in `packaging/tests/test_metadata.py`

These should be valid enough for later packaging work, but do not need to build installable packages yet.

- [ ] **Step 4: Re-run the packaging checks**

Run the command from Step 2.

Expected:
- packaging tests pass

- [ ] **Step 5: Commit**

```bash
git -C pepper-x status --short
git -C pepper-x add packaging/deb/pepper-x.desktop packaging/deb/pepper-x-autostart.desktop packaging/deb/control packaging/rpm/pepper-x.spec packaging/tests/test_metadata.py
git -C pepper-x commit -m "Add Pepper X packaging skeleton"
```

---

## Final Verification

- [ ] **Step 1: Run the Rust workspace checks**

Run:
```sh
cd pepper-x
cargo fmt --check
cargo test --workspace
cargo check --workspace
```

Expected:
- all Rust formatting, tests, and checks pass

- [ ] **Step 2: Run the integration smoke commands**

Run:
```sh
cd pepper-x
bash tests/smoke/test_extension_ipc.sh
./scripts/dev-install-extension.sh --check
./scripts/smoke-hotkey.sh
```

Expected:
- all smoke checks pass

- [ ] **Step 3: Verify the worktree is clean**

Run:
```sh
git -C pepper-x status --short
```

Expected:
- no uncommitted changes remain
