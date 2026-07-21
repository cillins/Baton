# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Baton** — a native macOS menu-bar app that maps Apple Siri Remote models including A1513 and A1962 onto mouse, keyboard, media, presentation, and Claude Code workflows. It supports configurable buttons and gestures, gyro drag-mode, profiles, and per-app auto-switching. Fork of [Remotastic](https://github.com/lauschue/Remotastic). Production UI is SwiftUI; `web/` is reference-only.

Repo is **flat at the root** for core Swift sources; the production settings UI lives in `SettingsUI/`. No Xcode project, no test suite. The exhaustive per-file reference lives in `AGENTS.md` — this file is the **quick-start** that future Claude instances need at session start.

## Build & Run

```bash
./build.sh                          # single swiftc → ./Baton binary (canonical build)
./create_app_bundle.sh              # wraps binary + icons + ad-hoc codesign (no web/ bundled)
open Baton.app                      # run as a proper app (needed for TCC permissions)
./Baton                             # or run the raw binary (menu bar only)
./script/build_and_run.sh --verify  # canonical kill + build + bundle + launch verification
```

- `build.sh` is the **only real build**. It links the private `MultitouchSupport` framework via `-Xlinker -F -Xlinker /System/Library/PrivateFrameworks` and bridges C via `SiriRemote-Bridging-Header.h`. `Package.swift` exists for IDE indexing only and **cannot link private frameworks** — never use `swift build`.
- **Adding a new `.swift` file?** Append it to **both** `SWIFT_FILES` in `build.sh` **and** the `sources` list in `Package.swift`. Files under `SettingsUI/**` must also be listed in both lists.
- `web/` is **reference-only**. The settings UI is now a native SwiftUI tree under `SettingsUI/`; `web/dist/index.html` is no longer bundled and the React frontend has no production role. The directory is kept in source for visual comparison and design provenance.
- `RemoteTouchSurface.swift` positively identifies the remote's small multitouch surface so a Magic Trackpad is never adopted. Run `Tests/run-tests.sh` for the pure classifier and `Tests/run-touch-surface-probe.sh` to inspect live device geometry.
- Set `BATON_SIGN_IDENTITY` when running `create_app_bundle.sh` to use a stable local signing identity; unset keeps the ad-hoc default.
- Requires macOS 12+, Xcode Command Line Tools (`xcode-select --install`), arm64 or x86_64 (auto-detected in `build.sh`).
- Runtime TCC permissions (granted in System Settings): **Accessibility**, **Input Monitoring**, **Bluetooth**. Without Input Monitoring, media-key interception silently fails and volume buttons hit the system.
- Diagnostic log: **`/tmp/baton.log`** via `rmDebug()` (defined in `RemoteDetector.swift`). NSLog is redacted under hardened runtime; use `rmDebug`, never `print`, when diagnosing HID/TCC issues in a signed bundle.
- Ad-hoc signing ties TCC grants to the binary hash — **rebuilds may require re-approving permissions**.

## Architecture

Single-process AppKit menu-bar app (`LSUIElement`). `main.swift` → `AppDelegate` (`SiriRemoteApp.swift`) wires together the components below. The core design problem the codebase solves: **a single physical Siri Remote press arrives through multiple macOS channels, and each channel needs its own suppression strategy.**

### Input paths (all converge on the same mapping)

1. **HID (seized)** — `RemoteDetector` finds the remote via `IOHIDManager` (vendor `0x004C` + known product IDs / name match). The Siri Remote exposes **multiple HID interfaces** (consumer page, game controls, vendor page) — `RemoteInputHandler` seizes every matching interface with `kIOHIDOptionsTypeSeizeDevice`. `identifyButton(page:usage:)` maps `(usagePage, usage)` → button name; `buttonState` dict collapses the mirrored-interface duplicates into one state transition per physical press.
2. **AVRCP → NX_SYSDEFINED** — Bluetooth media keys bypass the seized HID device and arrive as `NX_SYSDEFINED` (type 14, subtype 8) events. `MediaKeyInterceptor` runs a `.cghidEventTap` at `.headInsertEventTap` (a session tap arrives too late — Music.app gets it first). `data1` bitfield layout: `(nxKeyCode << 16) | (keyState << 8)` with `0xA`/`0xB` for down/up.
3. **Trackpad multitouch** — `TouchHandler` reads raw touch frames via the private `MultitouchSupport` framework. 1 finger = cursor, 2 = scroll, flick = swipe gesture, tap = click. Aggressive reconnect (`checkAndReconnect` timer + wake observer + starvation detection) because the MT device silently stops after remote sleep.
4. **Gyro (gen 1 only)** — `MotionCapture` enables gyro by writing FEATURE report 255 (`A0 01`) on the vendor-page HID interface; keepalive `F0 7F` every 45s or streaming stops. `RemoteInputHandler.handleGyro` runs **only while `select` is held** (drag mode) — One Euro filter for speed-adaptive smoothing, bias re-learning when still, deadzone, 350 ms activation delay to swallow the press jolt. Settings exposed as `gyroGain` / `gyroSmoothing` in the UI.
5. **Battery** — IOHID does not expose battery for BT HID devices. `BleBatteryMonitor` opens a parallel CoreBluetooth GATT connection (Battery Service `0x180F` / `0x2A19`); macOS allows multiple BLE links to the same peripheral, so HID keeps working.

**Debounce between (1) and (2):** static `RemoteInputHandler.lastProcessedButton` / `lastProcessedTime` (mach_absolute_time) + 200 ms window in `AppDelegate.handleInterceptedMediaKey`. Don't break this when touching either path.

### Additional system suppression

- `RCDControl` (in `SiriRemoteApp.swift`) runs `launchctl bootout gui/<uid>/com.apple.rcd` on launch — otherwise AVRCP play signals launch Music.app regardless of the event tap. Restored via `bootstrap` on clean exit; auto-restored next login regardless.
- `VolumeRevertGuard` (`SystemVolume.swift`) — AVRCP absolute-volume changes reach coreaudiod *below* the event tap, so they cannot be intercepted. Instead a CoreAudio property listener tracks volume with a 150 ms lagged baseline; on a remote volume HID press (`armFromRemoteButton()`), any change still in the settle queue is retroactively reverted. Keyboard changes outside the guard window pass through and become the new baseline.

### Mapping layer — `MenuBarManager`

Central store + executor for every button / swipe / drag assignment. Persistence keys in `UserDefaults`: `buttonMappings`, `swipeMappings`, `profiles`, `appPresets`, `customButtonTexts`, `customSwipeTexts`, `customButtonKeyCombos`, `customSwipeKeyCombos`. Schema versioning via `buttonMappingsSchema` (currently v5) and `profileSchema` (currently v10) — bump them when canonical defaults change so existing users' built-in profiles refresh on next launch. User-created (non-builtin) profiles are never touched.

- **`ButtonAction`** — enum, rawValue is the English persistence key (stable across UI language changes). Push-to-talk actions (`spaceKey`, `rightCmd`, `rightOpt`) have `requiresHold == true` and are only valid on `holdCapableButtons` = `{playPause, volumeUp, volumeDown, siri}`; `menu` / `tv` are press-only.
- **`SwipeAction`** — slash commands typed via `CGEvent.keyboardSetUnicodeString`. **Never sends Enter** (user confirms). Trailing-space policy is per-action: arg-taking commands (`/btw`, `/schedule`, `ultrathink`) get a space; standalone pickers (`/compact`, `/config`, `/model`, `/usage`, ...) don't.
- **Custom actions** — beyond the enums: `customText` (arbitrary string typed) and `customKey` (`keyCode` + modifiers dict) per button/swipe, stored under separate defaults keys.
- **Profiles** — named snapshots of button+swipe mappings. `AppPreset` binds a `bundleId` → `profileId`; `NSWorkspace.didActivateApplicationNotification` flips the active profile when a bound app becomes frontmost. **The TV button is hardcoded in `RemoteInputHandler.swift:130` to call `menuBarManager.toggleSystemOverride()` for system/app mode switching before the mapping layer sees it — no profile should bind `tv`.** Four built-ins are seeded on first run (`loadProfiles`, schema v10):
  - **默认配置** (`defaultButtonMappings` / `defaultSwipeMappings`, trackpadMode=`mouse`) — general navigation: Play/Pause→Enter, Menu→Esc, Select→TrackpadClick, Volume Up/Down→.none (system volume), Siri→Space push-to-talk, TV→.none; swipes are ↑ / ↓ / ← / →.
  - **Vibe Coding** (`codingButtonMappings` / `codingSwipeMappings`, trackpadMode=`gesture`) — Claude Code coding focused: same buttons as 默认配置 (Volume→.none for system volume); swipes are `/usage` / `/compact` / `/model` / mode-switch.
  - **演示模式** (`demoButtonMappings` / `demoSwipeMappings`, trackpadMode=`gesture`) — PowerPoint presentation: Play/Pause (center)→→ (next slide), Menu→⌥⌘P (toggle slideshow), Siri→← (previous slide), Select→TrackpadClick, Volume Up/Down→.none (let AVRCP pass through), TV→.none; swipes are B / W (black/white screen) / ← / →.
  - **媒体播放** (`mediaButtonMappings` / `mediaSwipeMappings`, trackpadMode=`gesture`) — media playback: Play/Pause→mediaPlayPause, Menu→mediaPrev, Siri→mediaMute, Select→TrackpadClick, Volume Up/Down→.none (let AVRCP reach `coreaudiod`), TV→.none; swipes are mediaNext / mediaPrev / mediaPrev / mediaNext.
  The seed loop is idempotent: existing users automatically get any newly-added built-ins appended without touching their saved data; bumping `profileSchema` overwrites the *content* of existing built-ins in-place (user-created profiles are left alone).

- **`媒体播放` profile is also wired into two system-level paths** so volume and media keys actually reach the playing app:
  - `MediaKeyInterceptor.handleInterceptedMediaKey` forwards `.volumeUp` / `.volumeDown` to macOS only when `currentProfileId == "media"` (consumed otherwise). The HID path synthesizes play/pause/next/prev/mute via `mediaController`, so forwarding those would double-fire — they're always consumed and the synthesized event is the single source.
  - `VolumeRevertGuard.shouldArmForRemoteButton` is wired at app launch to consult `currentProfileId`; the guard is a no-op in `media` profile so the system volume change persists. In other profiles the guard reverts the AVRCP-driven change (when the listener is active).
- **When changing defaults or removing actions: bump `buttonMappingsSchema` and add a migration in `loadMappings()`** — otherwise existing users silently lose mappings on the next launch.

## Settings UI — `SettingsUI/` + `SettingsWindowController`

Native SwiftUI tree hosted inside an `NSHostingView` inside the existing `WindowContainerView` (fixed 1020×684 window, `fullSizeContentView` with custom traffic lights). Pixel-perfect reproduction of the prior React UI — same colors, spacing, animations, interaction details. The settings window flips activation policy to `.regular` while open (gets a Dock icon), restores `.accessory` on close.

**Layout:**
- `SettingsUI/Theme.swift` — design tokens (Color, Spacing, Radius, Motion, BatonFont, shadows).
- `SettingsUI/RemoteArt.swift` — minimal SVG parser + Canvas-based renderer for the gen1/gen2 remote artwork.
- `SettingsUI/SettingsViewModel.swift` — `ObservableObject` mirroring `MenuBarManager` state (`buttons`, `swipes`, `profiles`, `appPresets`, `scrollSpeed`, `gyro`, `trackpadSensitivity`, `device`). Intent methods match the old WebBridge 1:1 (so this is essentially the bridge contract in Swift form).
- `SettingsUI/SettingsRootView.swift` — top-level composition: titlebar + sidebar + detail body + toast + profile-edit modal overlay.
- `SettingsUI/Components/` — `GroupCard`, `KeyValueRow`, `BatteryIndicator`, `MacSwitch`, `SegmentedTabs`, `SliderRow`, `KeyRecorderButton` (NSEvent local monitor — no DOM-to-CG table needed since `event.keyCode` is the CGKeyCode), `MapRow`.
- `SettingsUI/Panes/` — `SidebarView`, `DetailHeaderView`, `OverviewPane`, `ButtonsPane` (profile list + footer actions), `ProfileEditSheet` (modal — `ZStack` overlay, NOT `.sheet`, because CSS backdrop is transparent), `AppsPane`, `SensitivityPane`, `SettingsPane`.
- `SettingsUI/Support/RelativeTime.swift` — "X 分钟前" formatter mirroring React `App.jsx:relativeTime`.

Custom controls (NOT the native AppKit equivalents) — `Picker(.segmented)` and `Toggle(.switch)` can't reproduce the CSS look, so:
- `SegmentedTabs` paints an inset `--surface` track with per-button `--shadow-card` pills.
- `MacSwitch` is a custom 38×23 pill (19×19 knob) with `--success` on-state and a 20 % fg overlay off-state.
- `KeyRecorderButton` uses `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` and skips the DOM-to-CGKeyCode mapping entirely; same glyph normalization (`↩`→`⏎`, `⎋`→`esc`) as `MenuBarManager.customKeyGlyphNormalization`.

State flow: intents (button tap, slider commit, profile rename, …) → VM calls `MenuBarManager` → VM `reload()` → `objectWillChange` fires for `ObservedObject` SwiftUI subscribers. `MenuBarManager.onCurrentProfileChange` calls back into the VM. App-state pushes from `AppDelegate` go via `SettingsWindowController.pushConnectionState / pushGeneration / pushBattery / pushAppearance` — each forwards to `vm.updateDevice(...)` or `vm.appearance = ...`.

`web/` is kept on disk as a reference mock for visual comparison but is **no longer bundled**. To preview the old UI in a browser, `cd web && npm run dev`; bridge calls become no-ops and React falls back to `localStorage` + mock data.

## Key invariants / gotchas

- **Hold-key bookkeeping**: `RemoteInputHandler.heldKeys` captures `(keyCode, flags)` at press time so release fires the correct keyUp even if the user rebinds mid-hold. `releaseAllHeldKeys()` runs on device removal to prevent stuck modifiers. Stale holds close defensively on the next press.
- **First press after connect is swallowed** (`isFirstPressAfterConnection`) — the remote emits a spurious press during the connect handshake.
- **Virtual events post to `.cghidEventTap`** (not session tap) so they look like real hardware input to the receiving app.
- **`usleep` gaps are load-bearing**: 10 ms between key down/up in `sendKey`; 50 ms between media-key down/up in `MediaController`. Without the gap macOS coalesces or drops the pair.
- **Media-key synthesis** (`MediaController`) fabricates `NSSystemDefined` events with magic `modifierFlags` (`0xa00` down / `0xb00` up). All undocumented; read README "NX_SYSDEFINED hack" before touching this.
- Event taps get silently disabled across sleep/wake — always re-enable on `tapDisabledByTimeout`, `tapDisabledByUserInput`, and `NSWorkspace.didWakeNotification` (see `MediaKeyInterceptor` for the pattern).
- App is ad-hoc signed with `Baton.entitlements` (bluetooth, disable-library-validation, allow-dyld-environment-variables) — required on macOS 14+ for `IOHIDManager` to see the BLE remote.
- **Verify before explaining.** When the user reports "X is slow / broken", instrument + measure (`sample <pid>`, targeted `rmDebug` with `CFAbsoluteTimeGetCurrent`) before offering a hypothesis. A confident wrong answer wastes the user's time.

## Threading

- IOHID callbacks and MT touch callbacks arrive **off-main**; both marshal to main via `DispatchQueue.main.async` for UI/event posting.
- `RemoteDetector` uses a serial `processingQueue` for device add/remove to dedupe multi-interface races.
- `MotionCapture` runs on its own serial queue (`com.baton.motion`); gyro data → `RemoteInputHandler.handleGyro` on that thread (cursor movement dispatches to main internally).
- `SettingsViewModel.scanInstalledApps()` runs on `DispatchQueue.global(qos: .userInitiated)` — synchronous icon extraction otherwise freezes the menu bar for seconds. The scan moves to main only to assign `availableApps`; SwiftUI observes that array and updates the apps pane.
- For new C callbacks: capture `self` via `Unmanaged.passUnretained(self).toOpaque()` → in callback, `Unmanaged<T>.fromOpaque(context).takeUnretainedValue()` → dispatch side effects to main.

## Auxiliary tools (research, not part of the main build)

- `./build_probe.sh` → `BleProbe.app`: standalone CoreBluetooth GATT enumerator.
- `AudioProbe.swift` / `BleAudioProbe.swift` — audio stream probing (gated behind `--audio-probe` launch flag). Mic capture via public macOS APIs was investigated and is **unreachable** (Apple reserves the path for its own stacks). A separate `mic-spike/` Opus decoder experiment exists for the PacketLogger HCI path — paused since macOS 26.5 broke Apple PacketLogger.
- `MotionProbe.swift` — motion sensor probing (`--motion-probe` flag). Motion **is reachable** and is now production code in `MotionCapture.swift`.
- These are listed in `build.sh`'s `SWIFT_FILES` for ergonomic single-binary dev, but don't depend on them being there for the app to function. If asked to "clean up" `build.sh`, keep them only if the user explicitly wants them.
