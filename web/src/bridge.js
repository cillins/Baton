// web/src/bridge.js
// Swift <-> JS bridge for Baton settings window.
// In WKWebView: window.webkit.messageHandlers.bat is registered by Swift.
// In browser dev mode: bridge is a no-op, React falls back to localStorage.

const handler = (typeof window !== 'undefined' && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bat) || null

export const isNative = !!handler

// JS -> Swift: request the initial real state (connection, device name, version).
export function requestInitialState() {
  if (!handler) return
  handler.postMessage({ type: 'requestInitialState' })
}

// JS -> Swift: mapping writes. `action`/`speed` are Swift enum rawValues
// (the UserDefaults persistence keys), echoed back in setMappings pushes.
export function setButtonMapping(button, action) {
  if (!handler) return
  handler.postMessage({ type: 'setButtonMapping', button, action })
}

export function setSwipeMapping(direction, action) {
  if (!handler) return
  handler.postMessage({ type: 'setSwipeMapping', direction, action })
}

export function setScrollSpeed(speed) {
  if (!handler) return
  handler.postMessage({ type: 'setScrollSpeed', speed })
}

// Gyro drag feel: gain 0.5-6.0, smoothing 0-100 (strength %).
export function setGyroSettings(gain, smoothing) {
  if (!handler) return
  handler.postMessage({ type: 'setGyroSettings', gain, smoothing })
}

// Trackpad cursor sensitivity: 100-1000 (cursorScale, default 500).
export function setTrackpadSensitivity(sensitivity) {
  if (!handler) return
  handler.postMessage({ type: 'setTrackpadSensitivity', sensitivity })
}

export function resetMappings() {
  if (!handler) return
  handler.postMessage({ type: 'resetMappings' })
}

// Custom action payloads. target: 'button' | 'swipe'; key: button key or
// swipe direction. Empty text clears the payload.
export function setCustomText(target, key, text) {
  if (!handler) return
  handler.postMessage({ type: 'setCustomText', target, key, text })
}

// combo: { keyCode (CGKeyCode int), modifiers: ['cmd','shift','opt','ctrl'], label: '⌘⇧P' }
export function setCustomKey(target, key, combo) {
  if (!handler) return
  handler.postMessage({ type: 'setCustomKey', target, key, ...combo })
}

// JS -> Swift: per-app profile + preset writes. Profile CRUD operates on
// MenuBarManager; mapping edits target a specific profile (so multiple profiles
// can have different mappings). Available apps are listed on request.
export function setCurrentProfile(id) {
  if (!handler) return
  handler.postMessage({ type: 'setCurrentProfile', id })
}
export function createProfile(name) {
  if (!handler) return
  handler.postMessage({ type: 'createProfile', name })
}
export function deleteProfile(id) {
  if (!handler) return
  handler.postMessage({ type: 'deleteProfile', id })
}
export function renameProfile(id, name) {
  if (!handler) return
  handler.postMessage({ type: 'renameProfile', id, name })
}
export function setProfileMapping(profileId, target, key, action) {
  if (!handler) return
  handler.postMessage({ type: 'setProfileMapping', profileId, target, key, action })
}
export function addAppPreset(bundleId, appName, profileId, iconData) {
  if (!handler) return
  handler.postMessage({ type: 'addAppPreset', bundleId, appName, profileId, iconData: iconData || '' })
}
export function removeAppPreset(bundleId) {
  if (!handler) return
  handler.postMessage({ type: 'removeAppPreset', bundleId })
}
export function setAppPresetProfile(bundleId, profileId) {
  if (!handler) return
  handler.postMessage({ type: 'setAppPresetProfile', bundleId, profileId })
}
export function listInstalledApps() {
  if (!handler) return
  handler.postMessage({ type: 'listInstalledApps' })
}

// Swift -> JS: native calls window.batonNative.setState(state) to push real state.
// App.jsx installs a handler on mount.
// setAppearance(appearance) is called when the user picks a new appearance in
// the native popover - App.jsx updates its `appearance` state + localStorage.
// setAvailableApps(apps) is called in response to listInstalledApps.
if (typeof window !== 'undefined') {
  window.batonNative = {
    setStateHandler: null,
    setAppearanceHandler: null,
    setMappingsHandler: null,
    setAvailableAppsHandler: null,
    setState(state) {
      if (this.setStateHandler) this.setStateHandler(state)
    },
    setAppearance(appearance) {
      if (this.setAppearanceHandler) this.setAppearanceHandler(appearance)
    },
    setMappings(mappings) {
      if (this.setMappingsHandler) this.setMappingsHandler(mappings)
    },
    setAvailableApps(apps) {
      if (this.setAvailableAppsHandler) this.setAvailableAppsHandler(apps)
    },
  }
}
