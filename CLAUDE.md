# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Baton** — a macOS menu-bar app that maps an Apple Siri Remote's buttons and trackpad gestures onto Claude Code workflows (push-to-talk dictation, slash commands via swipe, arrow-key navigation, etc.). Fork of Remotastic, extended with configurable Claude Code actions.

Flat layout: all Swift sources live at the repo root. No Xcode project, no tests.

## Build & Run

```bash
./build.sh                  # single swiftc invocation → ./Baton binary
./create_app_bundle.sh      # wraps binary into Baton.app + ad-hoc codesign
open Baton.app          # run as a proper app
./Baton                 # or run the raw binary (menu bar only; LSUIElement)
```

- `build.sh` is the canonical build. It links the **private `MultitouchSupport` framework** via `-F /System/Library/PrivateFrameworks` and `SiriRemote-Bridging-Header.h`. `Package.swift` exists but explicitly **cannot build the trackpad path** (SPM can't link private frameworks) — do not treat `swift build` as the real build.
- Requires Xcode Command Line Tools, macOS 11+, arm64 or x86_64 (auto-detected in build.sh).
- Runtime permissions the app needs (user grants in System Settings): **Accessibility**, **Input Monitoring**, **Bluetooth**. Without Input Monitoring, media-key interception silently fails and volume buttons hit the system instead.
- Diagnostic log: **`/tmp/baton.log`** — NSLog is redacted under the hardened runtime, so `rmDebug()` (in `RemoteDetector.swift`) appends to this file. Log here, not via `print`, when diagnosing HID/TCC issues in a signed bundle.
- Ad-hoc signing ties TCC grants to the binary hash — **rebuilds may require re-approving permissions**.

## Architecture

Single-process AppKit menu-bar app (`LSUIElement`, no dock icon). `main.swift` → `AppDelegate` (`SiriRemoteApp.swift`) wires together six components. The core design problem the codebase solves: **a single physical Siri Remote press arrives through multiple macOS channels, and each channel needs its own suppression strategy.**

### Input paths (all converge on the same mapping)

1. **HID (seized)** — `RemoteDetector` finds the remote via `IOHIDManager` (vendor `0x004C` + known product IDs / name match). The Siri Remote exposes **multiple HID interfaces** (consumer page, game controls, vendor page) — `RemoteInputHandler` seizes every matching interface with `kIOHIDOptionsTypeSeizeDevice` so macOS doesn't also process the events. `RemoteInputHandler.identifyButton` maps `(usagePage, usage)` → button name; `buttonState` dict collapses the mirrored-interface duplicates into one state transition per physical press.
2. **AVRCP → NX_SYSDEFINED** — Bluetooth media keys (play/pause, volume, next/prev) bypass the seized HID device and arrive as `NX_SYSDEFINED` (type 14, subtype 8) events. `MediaKeyInterceptor` installs a `.cghidEventTap` at `.headInsertEventTap` (session tap is too late) and consumes them before they reach Music.app.
3. **Trackpad multitouch** — `TouchHandler` uses the private `MultitouchSupport` framework (`MTDeviceCreateList`, etc.) to read raw touch frames: 1 finger = cursor, 2 = scroll, flick = swipe gesture, tap = click. Has aggressive reconnect logic (`checkAndReconnect` timer + wake observer + starvation detection) because the MT device silently stops after remote sleep.

**Debounce between paths 1 and 2:** static `lastProcessedButton`/`lastProcessedTime` on `RemoteInputHandler` + 200 ms window in `AppDelegate.handleInterceptedMediaKey`. Don't break this when touching either path.

### Additional system suppression

- `RCDControl` (in `SiriRemoteApp.swift`) runs `launchctl bootout gui/<uid>/com.apple.rcd` on launch — otherwise AVRCP play signals launch Music.app regardless of the event tap. Restored via `bootstrap` on clean exit; auto-restored next login regardless.
- `VolumeRevertGuard` (`SystemVolume.swift`) — AVRCP absolute-volume changes reach coreaudiod *below* the event tap, so they can't be intercepted. Instead a CoreAudio listener tracks volume with a 150 ms lagged baseline; on a remote volume HID press (`armFromRemoteButton()`), any change in the settle window is retroactively reverted. Keyboard volume changes outside the guard window pass through and become the new baseline.

### Mapping layer

`MenuBarManager` is the central mapping store and executor. All button/swipe assignments flow through it:

- `ButtonAction` enum (rawValue = display string) + `holdCapableButtons` set. Push-to-talk actions (`spaceKey`, `rightCmd`, `rightOpt`) have `requiresHold == true` and are only valid on buttons that emit release events (`playPause`, `volumeUp`, `volumeDown`, `siri`); `menu`/`tv` are press-only.
- `SwipeAction` enum — slash commands are typed via `CGEvent.keyboardSetUnicodeString` (never Enter; user confirms). Trailing-space policy is per-action: arg-taking commands get a space, standalone ones don't.
- Persistence: `UserDefaults` keys `buttonMappings`, `swipeMappings`, with a `buttonMappingsSchema` version int that drives migrations (currently v4). When changing defaults or removing actions, bump the schema and add a migration in `loadMappings()`.

### Key invariants / gotchas

- **Hold-key bookkeeping**: `RemoteInputHandler.heldKeys` is captured at press time so release fires the correct keyUp even if the user rebinds mid-hold. `releaseAllHeldKeys()` runs on device removal to prevent stuck modifiers. Stale holds are closed defensively on the next press.
- **First press after connect is swallowed** (`isFirstPressAfterConnection`) — the remote emits a spurious press during the connect handshake.
- **Virtual events are posted to `.cghidEventTap`**, not the session tap, so they look like real hardware input to the receiving app.
- **Media-key synthesis** (`MediaController`) fabricates `NSSystemDefined` events with magic `modifierFlags` (`0xa00`/`0xb00`) and a 50 ms `usleep` between down/up — without the gap macOS coalesces the pair. All undocumented; see README "NX_SYSDEFINED hack" section before touching this.
- Event taps get silently disabled across sleep/wake — always re-enable on `tapDisabledByTimeout`, `tapDisabledByUserInput`, and `NSWorkspace.didWakeNotification` (see `MediaKeyInterceptor` for the pattern).
- App is built ad-hoc signed with `Baton.entitlements` (bluetooth, disable-library-validation, allow-dyld-environment-variables) — required on macOS 14+ for IOHIDManager to see the BLE remote.

### Threading

IOHID callbacks and MT touch callbacks arrive off-main; both marshal to main for UI/event posting. `RemoteDetector` uses a serial `processingQueue` for device add/remove to dedupe multi-interface races. When adding new callbacks, follow the existing pattern (capture self unretained in C callback → dispatch to main for side effects).
