import { useState, useEffect, useRef, useCallback } from 'react'
import { DEVICES } from './data'
import { REMOTE_ART } from './art'
import {
  isNative, requestInitialState, listInstalledApps,
  setButtonMapping, setSwipeMapping, setScrollSpeed, setGyroSettings, setTrackpadSensitivity,
  resetMappings, setCustomText, setCustomKey,
  setCurrentProfile, createProfile as createProfileBridge, deleteProfile as deleteProfileBridge, renameProfile as renameProfileBridge, setProfileMapping, resetProfile as resetProfileBridge,
  setTrackpadMode as setTrackpadModeBridge, requestProfileEdit,
  addAppPreset, removeAppPreset, setAppPresetProfile,
} from './bridge'
import Window from './components/Window'
import Sidebar from './components/Sidebar'
import DetailHeader, { LowBatteryAlert } from './components/DetailHeader'
import OverviewPane from './components/OverviewPane'
import ButtonsPane from './components/ButtonsPane'
import AppsPane from './components/AppsPane'
import SettingsPane from './components/SettingsPane'
import SensitivityPane from './components/SensitivityPane'

const STORAGE_KEY = 'baton-state'
const PANES = [
  ['overview', '概览'],
  ['buttons', '按键映射'],
  ['apps', '应用预设'],
  ['sensitivity', '灵敏度'],
]

function loadState() {
  const state = { dev: 'living', pane: 'overview', appearance: 'auto' }
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || 'null')
    if (saved && typeof saved === 'object') {
      if (DEVICES.some(d => d.id === saved.dev)) state.dev = saved.dev
      if (typeof saved.pane === 'string') state.pane = saved.pane
      if (['auto', 'light', 'dark'].includes(saved.appearance)) state.appearance = saved.appearance
    }
  } catch (e) { /* ignore */ }
  if (state.pane === 'trackpad') state.pane = 'buttons'
  if (!PANES.some(([p]) => p === state.pane)) state.pane = 'overview'
  return state
}

export default function App() {
  const [initial] = useState(loadState)
  // In WKWebView, only the real connected device is shown; in browser dev mode
  // the full DEVICES list is used so the prototype can be browsed.
  const [devices, setDevices] = useState(() => isNative
    ? [{ ...DEVICES[0], batt: 0, connected: false, last: '未连接' }]
    : DEVICES)
  const [availableApps, setAvailableApps] = useState([])
  // profiles/appPresets now arrive from the native mappings payload — no
  // local mock state. Derive everything from `mappings` below.
  const [devId, setDevId] = useState(initial.dev)
  const [pane, setPane] = useState(initial.pane)
  const [appearance, setAppearance] = useState(initial.appearance)
  const [settingsView, setSettingsView] = useState(false)
  const [toast, setToast] = useState(null)
  const [flash, setFlash] = useState(false)
  const [connecting, setConnecting] = useState(false)
  const [version, setVersion] = useState('1.0 (1)')
  // Real mapping state pushed from Swift (null until first setMappings call).
  const [mappings, setMappings] = useState(null)
  // Separate mappings for the edit modal (pushed via setEditMappings, does NOT
  // activate the profile so trackpadMode stays unchanged).
  const [editMappings, setEditMappings] = useState(null)
  // Profile being edited in the profile-edit modal. null = modal closed.
  const [editingProfileId, setEditingProfileId] = useState(null)
  // When non-null, App will open the modal on the next mappings update once a
  // matching profile appears. Used by 新建配置… which doesn't know the new id
  // synchronously (Swift generates it).
  const [pendingNewProfileName, setPendingNewProfileName] = useState(null)
  const toastTimer = useRef(null)
  const flashTimer = useRef(null)

  const dev = devices.find(d => d.id === devId) || devices[0]
  const profiles = mappings?.profiles || []
  const presets = mappings?.appPresets || []
  const profile = profiles.find(p => p.id === (dev.profile || 'default')) || profiles[0]

  const showToast = useCallback((msg) => {
    clearTimeout(toastTimer.current)
    setToast({ msg, id: Date.now() })
    toastTimer.current = setTimeout(() => setToast(null), 2800)
  }, [])

  const flashWindow = useCallback(() => {
    clearTimeout(flashTimer.current)
    setFlash(true)
    flashTimer.current = setTimeout(() => setFlash(false), 900)
  }, [])

  useEffect(() => {
    document.documentElement.dataset.appearance = appearance
  }, [appearance])

  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ dev: devId, pane, appearance }))
    } catch (e) { /* ignore */ }
  }, [devId, pane, appearance])

  // Native bridge: receive real state (connection, device name, generation,
  // battery, serial, model, lastConnectedAt, version) from Swift.
  useEffect(() => {
    if (!isNative) return
    window.batonNative.setStateHandler = (state) => {
      if (state.connected !== undefined || state.deviceName !== undefined) {
        setDevices(ds => ds.map((d, i) => i === 0 ? {
          ...d,
          id: 'living',
          name: state.deviceName || d.name,
          connected: state.connected !== undefined ? state.connected : d.connected,
          last: state.connected ? '当前已连接' : (state.lastConnectedAt ? relativeTime(state.lastConnectedAt) : '未连接'),
        } : d))
      }
      // Swift sends 'gen1', 'gen2' or '' (empty = unknown / disconnected).
      // Gen 2 covers both Apple TV 4K 1/2 and 4K 3 since they're visually identical
      // from the front (both have the dark clickpad ring with arrow buttons).
      if (typeof state.generation === 'string' && state.generation !== '') {
        setDevices(ds => ds.map((d, i) => i === 0 ? {
          ...d,
          art: state.generation === 'gen1' ? 'gen1' : 'gen2',
        } : d))
      }
      // Battery: 0 means "unknown" (BLE hasn't notified yet) — show 0% rather
      // than the placeholder 87; once a real value arrives we display it.
      if (typeof state.battery === 'number' && state.battery > 0) {
        setDevices(ds => ds.map((d, i) => i === 0 ? { ...d, batt: state.battery } : d))
      }
      if (typeof state.model === 'string' && state.model !== '') {
        setDevices(ds => ds.map((d, i) => i === 0 ? { ...d, model: state.model } : d))
      }
      if (state.version) setVersion(state.version)
    }
    window.batonNative.setAppearanceHandler = (ap) => {
      if (['auto', 'light', 'dark'].includes(ap)) setAppearance(ap)
    }
    window.batonNative.setMappingsHandler = (m) => setMappings(m)
    window.batonNative.setEditMappingsHandler = (m) => setEditMappings(m)
    window.batonNative.setAvailableAppsHandler = (apps) => setAvailableApps(apps || [])
    requestInitialState()
    if (isNative) listInstalledApps()
    return () => {
      window.batonNative.setStateHandler = null
      window.batonNative.setAppearanceHandler = null
      window.batonNative.setMappingsHandler = null
      window.batonNative.setEditMappingsHandler = null
      window.batonNative.setAvailableAppsHandler = null
    }
  }, [])

  // After 新建配置…, Swift generates the new profile id and pushes the
  // updated mappings. Once a new profile matching the pending name appears,
  // open the edit modal (and activate it since it's brand-new).
  useEffect(() => {
    if (!pendingNewProfileName || !mappings) return
    const created = mappings.profiles.find(p => p.name === pendingNewProfileName && !p.builtin)
    if (!created) return
    setEditingProfileId(created.id)
    setCurrentProfile(created.id)
    requestProfileEdit(created.id)
    setPendingNewProfileName(null)
  }, [mappings, pendingNewProfileName])

// Format an ISO-8601 timestamp into the "X 天前" relative-time format the
// React UI uses everywhere (matches data.js: "3 天前", "5 小时前", etc.).
function relativeTime(iso) {
  const then = new Date(iso).getTime()
  if (Number.isNaN(then)) return '未知时间'
  const sec = Math.max(0, Math.round((Date.now() - then) / 1000))
  if (sec < 60) return '刚刚'
  if (sec < 3600) return `${Math.floor(sec / 60)} 分钟前`
  if (sec < 86400) return `${Math.floor(sec / 3600)} 小时前`
  const days = Math.floor(sec / 86400)
  if (days < 30) return `${days} 天前`
  return '很久之前'
}

  const pair = useCallback(() => {
    showToast('将 Siri Remote 靠近 Mac，并同时按住「返回」与「音量+」开始配对…')
  }, [showToast])

  const selectDevice = (id) => { setSettingsView(false); setDevId(id) }
  const selectPane = (p) => { setSettingsView(false); setPane(p) }

  const connectDevice = () => {
    setConnecting(true)
    setTimeout(() => {
      setDevices(ds => ds.map(d => d.id === devId ? {
        ...d,
        connected: true,
        last: '当前已连接',
      } : d))
      setConnecting(false)
      showToast(`「${dev.name}」已连接`)
    }, 1400)
  }

  const selectProfile = (id) => {
    setDevices(ds => ds.map(d => d.id === devId ? { ...d, profile: id } : d))
    setCurrentProfile(id)
    const p = profiles.find(x => x.id === id)
    if (p) showToast(`已切换到「${p.name}」配置`)
  }

  // store is "button" | "swipe"; key is the button/swipe identifier;
  // action is the new ButtonAction / SwipeAction rawValue.
  const writeRow = (store, key, action) => {
    if (!profile) return
    setProfileMapping(profile.id, store, key, action)
    showToast(`「${profile.name}」配置已更新`)
  }

  const resetProfile = () => {
    if (!profile) return
    // Clear every key in this profile back to .none. Native applies and persists.
    ;(mappings?.buttons || []).forEach(b => setProfileMapping(profile.id, 'button', b.key, 'None'))
    ;(mappings?.swipes || []).forEach(s => setProfileMapping(profile.id, 'swipe', s.key, 'None'))
    showToast(`已恢复「${profile.name}」配置的默认映射`)
  }

  const createProfile = () => {
    // Auto-name: "新配置 N", skipping names already in use.
    const existing = profiles.map(p => p.name)
    let n = 1
    while (existing.includes(`新配置 ${n}`)) n++
    const name = `新配置 ${n}`
    setPendingNewProfileName(name)
    createProfileBridge(name)
  }

  const renameProfile = (id, name) => {
    if (!name) return
    renameProfileBridge(id, name)
    showToast(`已重命名为「${name}」`)
  }

  const deleteProfile = (id) => {
    const p = profiles.find(x => x.id === id)
    if (p?.builtin) { showToast('内置配置不可删除'); return }
    deleteProfileBridge(id)
    showToast(`已删除「${p?.name}」配置`)
  }

  // AppsPane: addApp(bundleId) — turn an available app into a preset bound to
  // the current profile.
  const addAppPresetFromAvailable = (bundleId) => {
    const app = availableApps.find(a => a.bundleId === bundleId)
    if (!app || !profile) return
    addAppPreset(bundleId, app.appName, profile.id, app.iconData)
    showToast(`已将「${app.appName}」绑定到「${profile.name}」`)
  }

  const removePresetByBundleId = (bundleId) => {
    const app = presets.find(a => a.bundleId === bundleId)
    removeAppPreset(bundleId)
    if (app) showToast(`已移除「${app.appName}」预设`)
  }

  const setPresetProfile = (bundleId, profileId) => {
    setAppPresetProfile(bundleId, profileId)
    const app = presets.find(a => a.bundleId === bundleId)
    const p = profiles.find(x => x.id === profileId)
    if (app && p) showToast(`「${app.appName}」将使用「${p.name}」`)
  }

  const addApp = () => showToast('在弹出的应用选取器中选择一个 App，即可为它指定映射模板')

  // Real mapping writes (native mode): target the editing profile when the
  // modal is open, otherwise the active profile. Swift re-pushes state.
  const handleSetButton = (key, action) => {
    const targetId = editingProfileId || profile?.id
    if (!targetId) return
    if (editingProfileId) {
      setEditMappings(m => m && { ...m, buttons: m.buttons.map(b => b.key === key ? { ...b, action } : b) })
    } else {
      setMappings(m => m && { ...m, buttons: m.buttons.map(b => b.key === key ? { ...b, action } : b) })
    }
    setProfileMapping(targetId, 'button', key, action)
  }
  const handleSetSwipe = (key, action) => {
    const targetId = editingProfileId || profile?.id
    if (!targetId) return
    if (editingProfileId) {
      setEditMappings(m => m && { ...m, swipes: m.swipes.map(s => s.key === key ? { ...s, action } : s) })
    } else {
      setMappings(m => m && { ...m, swipes: m.swipes.map(s => s.key === key ? { ...s, action } : s) })
    }
    setProfileMapping(targetId, 'swipe', key, action)
  }
  const handleSetScrollSpeed = (speed) => {
    setMappings(m => m && { ...m, scrollSpeed: speed })
    setScrollSpeed(speed)
  }
  // partial: { gain } / { smoothing } — merges into mappings.gyro
  const handleSetGyroSettings = (partial) => {
    const next = { gain: 2.5, smoothing: 67, ...(mappings?.gyro || {}), ...partial }
    setMappings(m => m && { ...m, gyro: next })
    setGyroSettings(next.gain, next.smoothing)
  }
  const handleSetTrackpadSensitivity = (v) => {
    setMappings(m => m && { ...m, trackpadSensitivity: v })
    setTrackpadSensitivity(v)
  }
  const handleResetMappings = () => {
    // Profile-aware reset: clear every mapping on the active profile to .None
    // (mirrors the legacy "restore defaults" semantics for the active profile).
    if (profile) {
      ;(mappings?.buttons || []).forEach(b => setProfileMapping(profile.id, 'button', b.key, 'None'))
      ;(mappings?.swipes || []).forEach(s => setProfileMapping(profile.id, 'swipe', s.key, 'None'))
      showToast(`已恢复「${profile.name}」的默认映射`)
    }
  }
  // Reset a specific profile (row-level 重置 button in the profile list).
  const handleResetProfile = (id) => {
    const p = profiles.find(x => x.id === id)
    if (!p) return
    resetProfileBridge(id)
    showToast(`已恢复「${p.name}」的默认映射`)
  }
  // Open the profile-edit modal for the given profile. Does NOT activate the
  // profile — just requests its mappings for display/editing in the modal.
  const handleEditProfile = (id) => {
    setEditingProfileId(id)
    requestProfileEdit(id)
  }
  const handleCloseModal = () => {
    setEditingProfileId(null)
    setEditMappings(null)
  }
  const handleSetCustomText = (target, key, text) => {
    const setter = editingProfileId ? setEditMappings : setMappings
    setter(m => m && {
      ...m,
      [target === 'button' ? 'buttons' : 'swipes']: m[target === 'button' ? 'buttons' : 'swipes']
        .map(r => r.key === key ? { ...r, customText: text } : r),
    })
    setCustomText(target, key, text)
  }
  const handleSetCustomKey = (target, key, combo) => {
    const setter = editingProfileId ? setEditMappings : setMappings
    setter(m => m && {
      ...m,
      [target === 'button' ? 'buttons' : 'swipes']: m[target === 'button' ? 'buttons' : 'swipes']
        .map(r => r.key === key ? { ...r, customKey: combo } : r),
    })
    setCustomKey(target, key, combo)
  }
  const handleSetTrackpadMode = (profileId, mode) => {
    setTrackpadModeBridge(profileId, mode)
    setMappings(m => m && { ...m, profiles: (m.profiles || []).map(p => p.id === profileId ? { ...p, trackpadMode: mode } : p) })
    if (editingProfileId === profileId) {
      setEditMappings(m => m && { ...m, trackpadMode: mode })
    }
  }

  return (
    <div className="app-root">
      <Window
        flash={flash}
        settingsView={settingsView}
        onToggleSettings={() => setSettingsView(v => !v)}
        onPair={pair}
        toast={toast}
      >
        <Sidebar devices={devices} devId={devId} onSelect={selectDevice} onPair={pair} />
        <section className="detail">
          <div className="detail-body">
            {settingsView ? (
              <SettingsPane
                version={version}
              />
            ) : (
              <>
                <DetailHeader dev={dev} connecting={connecting} onConnect={connectDevice} />
                {dev.connected && dev.batt > 0 && dev.batt < 20 && <LowBatteryAlert dev={dev} />}
                <div className="seg" role="tablist">
                  {PANES.map(([value, label]) => (
                    <button
                      key={value}
                      role="tab"
                      aria-selected={pane === value}
                      className={pane === value ? 'on' : ''}
                      onClick={() => selectPane(value)}
                    >{label}</button>
                  ))}
                </div>
                {pane === 'overview' && <OverviewPane dev={dev} />}
                {pane === 'buttons' && (
                  <ButtonsPane
                    dev={dev}
                    profile={profile}
                    profiles={profiles}
                    onSelectProfile={selectProfile}
                    onWriteRow={writeRow}
                    onReset={resetProfile}
                    onCreate={createProfile}
                    onRename={renameProfile}
                    onDelete={deleteProfile}
                    onCreateProfile={createProfile}
                    onRenameProfile={renameProfile}
                    onDeleteProfile={deleteProfile}
                    showToast={showToast}
                    mappings={mappings}
                    onSetButton={handleSetButton}
                    onSetSwipe={handleSetSwipe}
                    onSetScrollSpeed={handleSetScrollSpeed}
                    onResetMappings={handleResetMappings}
                    onResetProfile={handleResetProfile}
                    onEditProfile={handleEditProfile}
                    onCloseModal={handleCloseModal}
                    editingProfileId={editingProfileId}
                    onSetCustomText={handleSetCustomText}
                    onSetCustomKey={handleSetCustomKey}
                    onSetTrackpadMode={handleSetTrackpadMode}
                    editMappings={editMappings}
                  />
                )}
                {pane === 'apps' && (
                  <AppsPane
                    presets={presets}
                    profiles={profiles}
                    availableApps={availableApps}
                    onSetPresetProfile={setPresetProfile}
                    onRemovePreset={removePresetByBundleId}
                    onAddPreset={addAppPresetFromAvailable}
                  />
                )}
                {pane === 'sensitivity' && (
                  <SensitivityPane
                    dev={dev}
                    mappings={mappings}
                    trackpadSensitivity={mappings?.trackpadSensitivity}
                    onSetTrackpadSensitivity={handleSetTrackpadSensitivity}
                    onSetGyroSettings={handleSetGyroSettings}
                  />
                )}
              </>
            )}
          </div>
          {!settingsView && (
            <div className="detail-art" dangerouslySetInnerHTML={{ __html: REMOTE_ART[dev.art] }} />
          )}
        </section>
      </Window>
    </div>
  )
}
