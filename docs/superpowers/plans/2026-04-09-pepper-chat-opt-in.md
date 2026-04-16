# Pepper Chat Opt-In Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Pepper Chat opt-in so new users do not see or trigger it until they enable it, while preserving the existing enabled behavior for users who already stored a Zo token.

**Architecture:** Add one persisted `pepperChatEnabled` flag in `AppState` and derive its initial value from `pepperChatApiKey` only when the new setting has not been stored yet. Use that single source of truth to gate the menu bar entry, Pepper Chat hotkey bindings, and new launch/record entry points, while leaving already-open windows alone.

**Tech Stack:** SwiftUI, AppStorage/UserDefaults, XCTest

---

## Chunk 1: Persistence and gating

### Task 1: Add failing tests for Pepper Chat enablement defaults and hotkey gating

**Files:**
- Modify: `GhostPepperTests/GhostPepperTests.swift`
- Test: `GhostPepperTests/GhostPepperTests.swift`

- [ ] **Step 1: Write the failing tests**
- [ ] **Step 2: Run the focused tests and verify they fail for the missing behavior**
- [ ] **Step 3: Add the minimal `AppState` implementation for the new persisted flag and shortcut gating**
- [ ] **Step 4: Run the focused tests again and verify they pass**
- [ ] **Step 5: Commit**

### Task 2: Gate new Pepper Chat launches in the app state

**Files:**
- Modify: `GhostPepper/AppState.swift`

- [ ] **Step 1: Add a failing test or extend an existing one if needed**
- [ ] **Step 2: Guard new Pepper Chat launches/recordings behind `pepperChatEnabled`**
- [ ] **Step 3: Re-run the focused test target**
- [ ] **Step 4: Commit**

## Chunk 2: Surface the setting in the UI

### Task 3: Update settings and menu bar UI

**Files:**
- Modify: `GhostPepper/UI/SettingsWindow.swift`
- Modify: `GhostPepper/UI/MenuBarView.swift`
- Test: `GhostPepperTests/GhostPepperTests.swift`

- [ ] **Step 1: Add or extend tests for the visible behavior where practical**
- [ ] **Step 2: Add the Pepper Chat enable toggle in Settings**
- [ ] **Step 3: Hide the menu bar Pepper Chat item when disabled**
- [ ] **Step 4: Run the focused test target, then the broader relevant test target**
- [ ] **Step 5: Commit**
