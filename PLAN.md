# Plan: Fix meeting window unconditionally opening at startup (#149)

Upstream PR against `matthartman/ghost-pepper`, referencing issue #149
("Meeting window unconditionally opens at startup").

## Root cause

Not window restoration — the app has exactly one scene (`MenuBarExtra`), no
`WindowGroup`, no `AppDelegate`, no restoration code. The meeting window is
opened by three explicit, ungated calls to `appState.showMeetingTranscriptWindow()`
inside the `MenuBarExtra` label's `.onAppear`:

- `GhostPepper/GhostPepperApp.swift:59`  (`--force-onboarding` path)
- `GhostPepper/GhostPepperApp.swift:64`  (normal launch — primary repro)
- `GhostPepper/GhostPepperApp.swift:70`  (first-run onboarding path)

None of the layers below check the "Enable Meeting Transcription" setting:

- `AppState.showMeetingTranscriptWindow()` — `AppState.swift:1851`
- `AppState.showOrCreateMeetingWindow()` — `AppState.swift:1855`
- `MeetingTranscriptWindowController.show()` — `MeetingTranscriptWindow.swift:1109`

The setting exists and is gated everywhere else: `@AppStorage("meetingTranscriptEnabled")`
(`AppState.swift:218`, default `false`), the menu bar items (`MenuBarView.swift:25`),
the settings sub-toggles (`SettingsWindow.swift:2609`), and the detector
(`setupMeetingDetector`, `AppState.swift:1897`). The codebase already has the
exact precedent for the fix — `showPepperChat()` at `AppState.swift:1616` does
`guard pepperChatEnabled else { return }`.

Git blame: line 64 came from `a7ec56a` "auto-open meeting window" (Apr 2026).
It reads like an intentional feature that simply never got wired to the flag.

## Aggravating factors (context only, not changed by this PR)

1. **`AppState.swift:449-455`** — a one-time migration silently sets
   `meetingTranscriptEnabled = true` for anyone who had used a previous
   version. Users got opted in without asking. This is mentioned in the PR
   body as the reason some users have the flag on unexpectedly, but is left
   untouched per scope decision.
2. **`MeetingTranscriptWindow.swift:1175`** — `show()` calls
   `NSApp.setActivationPolicy(.regular)`. Since `LSUIElement` is `true`,
   auto-opening also spawns a Dock icon, turning a menu-bar app into a
   regular app on every launch. That's why it feels so intrusive. Noted as
   a possible follow-up, not changed here.

## Changes

### 1. New preference — `GhostPepper/AppState.swift:222`

Add alongside the existing meeting flags, following their naming convention:

```swift
@AppStorage("meetingWindowOpensAtLaunch") var meetingWindowOpensAtLaunch: Bool = false
```

Default `false`, so auto-open becomes opt-in. This is a behaviour change
for users who currently like the auto-open — the PR description calls that
out explicitly as the maintainer's call to accept.

### 2. Testable predicate — `GhostPepper/UI/MeetingTranscriptWindow.swift:1060`

Extend the existing `MeetingTranscriptWindowPresentation` enum, mirroring how
`windowLevel` was extracted for testing:

```swift
static func shouldOpenAtLaunch(
    transcriptionEnabled: Bool,
    opensAtLaunch: Bool
) -> Bool {
    transcriptionEnabled && opensAtLaunch
}
```

### 3. Gate the accessors — `GhostPepper/AppState.swift:1851-1857`

```swift
func showMeetingTranscriptWindow() {
    guard meetingTranscriptEnabled else { return }
    meetingTranscriptWindowController.show()
}

func showMeetingTranscriptWindowAtLaunch() {
    guard MeetingTranscriptWindowPresentation.shouldOpenAtLaunch(
        transcriptionEnabled: meetingTranscriptEnabled,
        opensAtLaunch: meetingWindowOpensAtLaunch
    ) else { return }
    meetingTranscriptWindowController.show()
}

func showOrCreateMeetingWindow() {
    guard meetingTranscriptEnabled else { return }
    meetingTranscriptWindowController.show()
}
```

`MeetingTranscriptWindowController.show()` stays ungated —
`startMeetingTranscription()` (`AppState.swift:1842`) calls it directly and
must still work for an in-progress recording. Same for the "What's New" →
"Open Meetings" path (`AppState.swift:640`), which is explicitly
user-initiated.

### 4. Update the three launch call sites — `GhostPepperApp.swift:59`, `:64`, `:70`

Swap `showMeetingTranscriptWindow()` → `showMeetingTranscriptWindowAtLaunch()`
in all three branches (`--force-onboarding`, normal launch, first-run
onboarding), so behaviour is consistent regardless of launch path.

### 5. Settings UI — `GhostPepper/UI/SettingsWindow.swift`

Add a toggle inside the existing `if appState.meetingTranscriptEnabled { }`
block in `meetingTranscriptSection`, placed after "Auto-detect meeting apps"
and before "Float the meeting window while recording":

```swift
Toggle("Open the meeting window at launch", isOn: $appState.meetingWindowOpensAtLaunch)

Text("Opens the meeting window automatically when Ghost Pepper starts. Off by default — the window is also available from the menu bar.")
    .font(.caption)
    .foregroundStyle(.secondary)
```

No `.onChange` handler needed; the value is only read at startup.

### 6. Test seam — `GhostPepper/UI/MeetingTranscriptWindow.swift:1083`

The `window` property is `private var window: NSWindow?`, so add:

```swift
var isWindowOpen: Bool { window != nil }
```

Plus a matching passthrough on `AppState`, since
`meetingTranscriptWindowController` is private (`AppState.swift:1270`):

```swift
var isMeetingWindowOpen: Bool { meetingTranscriptWindowController.isWindowOpen }
```

### 7. Tests — `GhostPepperTests/MeetingTranscriptWindowPresentationTests.swift`

There is currently zero coverage of the app startup sequence or this flag.
Two additions:

- `shouldOpenAtLaunch` truth table, 4 cases (both off; transcription off +
  launch on; transcription on + launch off; both on), in the existing
  `MeetingTranscriptWindowPresentationTests` class. Pure functions, no
  windows, no `UserDefaults` mutation, no `@MainActor` — fits the file's
  existing style.

- A `@MainActor` regression test: construct `AppState` with the fakes used
  at `GhostPepperTests.swift:2195` (`FakeHotkeyMonitor`,
  `ChordBindingStore`, injectable `cleanupSettingsDefaults`), set
  `meetingTranscriptEnabled = false` on `UserDefaults.standard` (not the
  injectable `cleanupSettingsDefaults` — the key is on standard, per
  `AppState.swift:218`), call `showMeetingTranscriptWindowAtLaunch()`,
  assert `isMeetingWindowOpen == false`. Restore defaults in `tearDown`,
  following the `skipConsentKey` pattern at
  `MeetingTranscriptWindowPresentationTests.swift:41-50`.

  Negative-path only, so no real window is created and the activation
  policy isn't flipped to `.regular` mid-suite.

### 8. Verification

Cannot compile or test on this machine (Linux/aarch64, no Swift toolchain,
no Xcode). The maintainer/user must run the test suite and
`script/build_and_run.sh` on a Mac. Manual check: with the setting off,
relaunch and confirm neither the window nor a Dock icon appears — the Dock
icon is the reliable tell, since `show()` calls
`NSApp.setActivationPolicy(.regular)` at `MeetingTranscriptWindow.swift:1175`.

## Out of scope

- The opt-in migration at `AppState.swift:449-455` — left alone, mentioned
  in the PR body as the reason some users have the flag on without asking.
- The `setActivationPolicy(.regular)` / Dock-icon behaviour — noted as a
  possible follow-up, not changed.

## Footprint

5 files, ~50 lines added, 3 changed:

- `GhostPepper/AppState.swift`
- `GhostPepper/GhostPepperApp.swift`
- `GhostPepper/UI/MeetingTranscriptWindow.swift`
- `GhostPepper/UI/SettingsWindow.swift`
- `GhostPepperTests/MeetingTranscriptWindowPresentationTests.swift`
