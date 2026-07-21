# AGENTS.md

This file provides guidance to Qoder (qoder.com) when working with code in this repository.

## Project

**Baton** — a macOS menu-bar app (`LSUIElement`, no Dock icon) that maps Apple Siri Remote models including A1513 and A1962 onto mouse, keyboard, media, presentation, and Claude Code workflows. Fork of [Remotastic](https://github.com/lauschue/Remotastic). Core Swift sources live flat at the repo root; the production settings UI is native SwiftUI under `SettingsUI/`. The React app in `web/` is reference-only. No Xcode project, no test suite.

## Build & Run

```bash
# 1. Native binary (single swiftc invocation → ./Baton)
./build.sh

# 2. Package .app bundle (binary + icons + ad-hoc codesign)
./create_app_bundle.sh

# 3. Run
open Baton.app          # proper app (needed for TCC permissions)
./Baton                 # raw binary (menu bar only)

# Canonical local kill + build + package + launch verification
./script/build_and_run.sh --verify

# Optional: preview the legacy React design reference
cd web && npm run dev

# Standalone BLE research tool
./build_probe.sh        # → BleProbe.app (GATT enumeration)
```

**Critical build notes:**
- `build.sh` is the **only** real build. It links the private `MultitouchSupport` framework via `-Xlinker -F -Xlinker /System/Library/PrivateFrameworks` and bridges C via `SiriRemote-Bridging-Header.h` → `MultitouchSupport.h`. `Package.swift` exists for IDE indexing but **cannot link private frameworks** — never use `swift build`.
- When adding a new `.swift` file, add it to **both** the `SWIFT_FILES` array in `build.sh` and the `sources` list in `Package.swift`.
- `SettingsUI/` is the production UI. `web/` is kept only as a visual reference and is not bundled.
- `RemoteTouchSurface.swift` prevents Magic Trackpads from being adopted as the remote touch surface. Verify with `Tests/run-tests.sh` and `Tests/run-touch-surface-probe.sh`.
- `create_app_bundle.sh` accepts optional `BATON_SIGN_IDENTITY`; when unset it preserves the ad-hoc signing behavior.
- Requires: macOS 12+, Xcode CLI Tools (`xcode-select --install`), arm64 or x86_64 (auto-detected).
- Runtime TCC permissions: **Accessibility** + **Input Monitoring** + **Bluetooth**. Ad-hoc signing ties grants to binary hash — rebuilds require re-approval.
- Diagnostic log: `/tmp/baton.log` via `rmDebug()` (defined in `RemoteDetector.swift`). NSLog is redacted under hardened runtime; always use `rmDebug`, never `print`, for HID/TCC diagnostics.

## Architecture

### The core problem

A single physical Siri Remote button press can arrive through **three independent macOS channels**, each requiring its own suppression strategy. The entire codebase is organized around solving this.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Siri Remote (BLE HID)                         │
└──────────┬──────────────────────┬───────────────────┬───────────┘
           │                      │                   │
    ┌──────▼──────┐       ┌──────▼──────┐    ┌──────▼──────┐
    │  Path 1:    │       │  Path 2:    │    │  Path 3:    │
    │  HID seized │       │  AVRCP →    │    │  Multitouch │
    │  (IOKit)    │       │  NX_SYSDEF  │    │  Support    │
    └──────┬──────┘       └──────┬──────┘    └──────┬──────┘
           │                      │                   │
    RemoteInputHandler    MediaKeyInterceptor     TouchHandler
           │                      │                   │
           └──────────┬───────────┘                   │
                      │ 200ms debounce                │ onSwipe callback
                      ▼                               ▼
              ┌─────────────────────────────────────────┐
              │         MenuBarManager                   │
              │  (mapping store + action executor)       │
              └─────────────────────────────────────────┘
                      │
                      ▼
              CGEvent posted to .cghidEventTap
              (keyboard, mouse, scroll, unicode text)
```

### Path 1: HID seized — `RemoteDetector` + `RemoteInputHandler`

- `RemoteDetector` uses `IOHIDManager` with `SetDeviceMatchingMultiple` (4 usage-page dicts: Consumer 0x0C, Digitizer 0x0D, Apple vendor 0xFF00, Generic Desktop 0x01) to find the remote (vendor `0x004C` + known product IDs or name match).
- A single physical remote exposes **multiple HID interfaces** — each fires `deviceAdded`. `RemoteDetector` uses a serial `processingQueue` + `processedDeviceKeys` set (keyed `vendorID:productID`) to dedupe.
- `RemoteInputHandler.setRemoteDevice()` seizes each interface with `kIOHIDOptionsTypeSeizeDevice` so macOS stops processing those events.
- `identifyButton(page:usage:)` maps `(usagePage, usage)` → button name. The same button appears on multiple interfaces; `buttonState` dict collapses duplicates to one state transition.
- `Generation` enum (gen1/gen2) is derived from HID product ID — drives UI artwork and gyro availability (gen1 only).

### Path 2: AVRCP → NX_SYSDEFINED — `MediaKeyInterceptor` + `MediaController`

- Bluetooth media keys (play/pause, volume) bypass HID seize and arrive as `NX_SYSDEFINED` events (type 14, subtype 8). `MediaKeyInterceptor` installs a `.cghidEventTap` at `.headInsertEventTap` (session tap is too late — Music.app gets it first).
- Parses `data1` bitfield: `(nxKeyCode << 16) | (keyState << 8)`, where `0xA` = down, `0xB` = up.
- `MediaController` goes the other direction: **fabricates** `NSSystemDefined` events with magic `modifierFlags` (`0xa00` down / `0xb00` up) and a mandatory 50ms `usleep` between down/up (without it macOS coalesces the pair).
- `RCDControl` (in `SiriRemoteApp.swift`) runs `launchctl bootout gui/<uid>/com.apple.rcd` at launch — otherwise AVRCP play signals launch Music.app regardless of the event tap. Restored on clean exit.

### Path 3: Trackpad — `TouchHandler` (private MultitouchSupport)

- Uses `MTDeviceCreateList()` → finds non-built-in device (the Siri Remote trackpad).
- 1 finger = cursor movement, 2 fingers = scroll, tap = click, flick = swipe gesture.
- Swipe detection: distance ≥ 35% of trackpad, duration < 350ms, dominant axis ≥ 2× orthogonal.
- Aggressive reconnect logic: 2s polling timer + 15s touch-starvation restart + wake observer + `tryReconnectTrackpad()` triggered by HID button activity. The MT device silently stops after remote sleep with no notification.

### Debounce between paths 1 and 2

Static `RemoteInputHandler.lastProcessedButton` / `lastProcessedTime` (mach_absolute_time). In `AppDelegate.handleInterceptedMediaKey`, if the same button was processed via HID within 200ms, the AVRCP event is consumed silently. **Do not break this when touching either path.**

### Volume suppression — `VolumeRevertGuard` (SystemVolume.swift)

AVRCP absolute-volume changes reach coreaudiod *below* the event tap — they cannot be intercepted. Instead:
- A CoreAudio property listener tracks volume with a 150ms lagged baseline (`pendingSettle`).
- On a remote volume HID press, `armFromRemoteButton()` opens a 500ms guard window and retroactively reverts any change still in the settle queue.
- Keyboard volume changes outside the guard window pass through normally after settle.

### Mapping layer — `MenuBarManager`

Central store + executor for all button/swipe assignments:

- `ButtonAction` enum: rawValue is the English persistence key (stable across versions); `displayName` is the Chinese UI label. `requiresHold` actions (spaceKey, rightCmd, rightOpt) only offered on `holdCapableButtons` (playPause, volumeUp, volumeDown, siri).
- `SwipeAction` enum: slash commands typed via `CGEvent.keyboardSetUnicodeString` — **never sends Enter** (user confirms). Trailing-space policy: arg-taking commands (`/btw`, `/schedule`, `ultrathink`) get a space; standalone ones don't.
- Custom actions: `customText` (arbitrary string typed) and `customKey` (keyCode + modifiers dict) per button/swipe, stored in separate UserDefaults keys.
- **Profiles**: named snapshots of button+swipe mappings. `AppPreset` binds a bundleId → profileId; `NSWorkspace.didActivateApplicationNotification` flips the active profile when a bound app becomes frontmost.
- Persistence: UserDefaults keys `buttonMappings`, `swipeMappings`, `profiles`, `appPresets`, `customButtonTexts`, `customSwipeTexts`, `customButtonKeyCombos`, `customSwipeKeyCombos`. Schema versioning via `buttonMappingsSchema` (currently v5) and `profileSchema` (currently v10). When changing defaults or built-in profiles, bump the appropriate schema and preserve user-created profiles.

### Gyro cursor (gen 1 only) — `MotionCapture` + `RemoteInputHandler.handleGyro`

- `MotionCapture` enables gyro by writing FEATURE report 255 (`A0 01`) on the vendor-page HID interface, keeps alive with `F0 7F` every 45s. Motion streams as 25-byte reports (ID 1); gyro X/Y/Z are signed LE int16 at bytes 19-24.
- `handleGyro` runs only while `select` is held (drag mode). Uses One Euro filter for speed-adaptive smoothing, bias re-learning when still, deadzone, and a 350ms activation delay to swallow the press jolt.
- Settings: `gyroGain` (raw→px/s multiplier) and `gyroSmoothing` (0-100 → One Euro minCutoff).

### Battery — `BleBatteryMonitor`

IOHID doesn't expose battery for BT HID devices. A parallel CoreBluetooth GATT connection reads the standard Battery Service (0x180F / 0x2A19). macOS allows multiple BLE links to the same peripheral, so HID keeps working. `refresh()` is called on connect + 2s retry to handle GATT-visibility lag.

### Settings UI — `SettingsWindowController` + `SettingsUI/`

- Native SwiftUI is hosted in an `NSHostingController` inside a fixed 1020×684 AppKit window with custom traffic lights and drag overlay.
- `SettingsViewModel` mirrors canonical state from `MenuBarManager` and exposes mutations for mappings, profiles, app presets, sensitivity, appearance, login item, close behavior, and menu-bar battery display.
- `SettingsWindowController` forwards connection, generation, and battery updates to the view model.
- The window activation policy flips to `.regular` while open. Closing either restores `.accessory` mode or terminates Baton according to `keepRunningWhenClosed`.
- `web/` is a legacy React visual reference only. It is not loaded by WKWebView and is not bundled into `Baton.app`.

### Key invariants / gotchas

- **Hold-key bookkeeping**: `RemoteInputHandler.heldKeys` captures `(keyCode, flags)` at press time so release fires the correct keyUp even if the user rebinds mid-hold. `releaseAllHeldKeys()` on device removal prevents stuck modifiers. Stale holds are closed defensively on the next press.
- **First press after connect is swallowed** (`isFirstPressAfterConnection`) — the remote emits a spurious press during the connect handshake.
- **All virtual events post to `.cghidEventTap`** (not session tap) so they look like real hardware input to receiving apps.
- **Event taps get silently disabled** across sleep/wake and input stalls — always re-enable on `tapDisabledByTimeout`, `tapDisabledByUserInput`, and `NSWorkspace.didWakeNotification`.
- **`usleep` gaps are load-bearing**: 10ms between key down/up in `sendKey`; 50ms between media-key down/up in `MediaController`. Removing them causes macOS to coalesce or drop the pair.
- App is ad-hoc signed with `Baton.entitlements` (bluetooth, disable-library-validation, allow-dyld-environment-variables) — required on macOS 14+ for IOHIDManager to see BLE HID devices.
- `Package.swift` is intentionally incomplete (missing `BleBatteryMonitor.swift`, `MotionCapture.swift`, `MotionProbe.swift`, `MultitouchSupport` linkage) — it exists for IDE support only.

### Threading model

- IOHID callbacks and MT touch callbacks arrive **off-main**. Both marshal to main via `DispatchQueue.main.async` for UI updates and event posting.
- `RemoteDetector` uses a serial `processingQueue` for device add/remove to dedupe multi-interface races.
- `MotionCapture` runs on its own serial queue (`com.baton.motion`); gyro data flows to `RemoteInputHandler.handleGyro` on that thread (cursor movement dispatches to main internally).
- `SettingsViewModel.scanInstalledApps()` runs on `DispatchQueue.global(qos: .userInitiated)` to avoid freezing the menu bar during icon extraction.
- Pattern for new C callbacks: capture `self` via `Unmanaged.passUnretained(self).toOpaque()` → in callback, `Unmanaged<T>.fromOpaque(context).takeUnretainedValue()` → dispatch side effects to main.

### Auxiliary tools (not part of the main build)

- `ble_probe.swift` / `build_probe.sh` → `BleProbe.app`: standalone GATT research tool.
- `AudioProbe.swift`, `BleAudioProbe.swift`: audio stream probing (activated via `--audio-probe` flag).
- `MotionProbe.swift`: motion sensor research (`--motion-probe` flag).
- `MotionCapture.swift`: production gyro capture (gen 1 only, always active when gen1 connected).
- `mic-spike/`: separate Opus microphone experiment (own build, unrelated to main app).
