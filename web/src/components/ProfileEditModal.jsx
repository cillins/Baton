import { useEffect, useRef, useState } from 'react'

// DOM event.code -> macOS CGKeyCode (ANSI layout subset covering common keys).
const DOM_TO_CG = {
  KeyA: 0, KeyS: 1, KeyD: 2, KeyF: 3, KeyH: 4, KeyG: 5, KeyZ: 6, KeyX: 7,
  KeyC: 8, KeyV: 9, KeyB: 11, KeyQ: 12, KeyW: 13, KeyE: 14, KeyR: 15, KeyY: 16, KeyT: 17,
  Digit1: 18, Digit2: 19, Digit3: 20, Digit4: 21, Digit6: 22, Digit5: 23,
  Digit9: 25, Digit7: 26, Digit8: 28, Digit0: 29,
  Equal: 24, Minus: 27, BracketRight: 30, BracketLeft: 33,
  KeyO: 31, KeyU: 32, KeyI: 34, KeyP: 35, Enter: 36, KeyL: 37, KeyJ: 38,
  Quote: 39, KeyK: 40, Semicolon: 41, Backslash: 42, Comma: 43, Slash: 44,
  KeyN: 45, KeyM: 46, Period: 47, Tab: 48, Space: 49, Backquote: 50,
  Backspace: 51, Delete: 117, Escape: 53,
  F1: 122, F2: 120, F3: 99, F4: 118, F5: 96, F6: 97, F7: 98, F8: 100,
  F9: 101, F10: 109, F11: 103, F12: 111,
  Home: 115, End: 119, PageUp: 116, PageDown: 121,
  ArrowLeft: 123, ArrowRight: 124, ArrowDown: 125, ArrowUp: 126,
}
const MODIFIER_CODES = new Set(['MetaLeft', 'MetaRight', 'ControlLeft', 'ControlRight', 'AltLeft', 'AltRight', 'ShiftLeft', 'ShiftRight'])
const MOD_GLYPH = { ctrl: '⌃', opt: '⌥', shift: '⇧', cmd: '⌘' }
const KEY_NAMES = { Enter: '↩', Tab: '⇥', Backspace: '⌫', Delete: '⌦', Escape: '⎋', ArrowUp: '↑', ArrowDown: '↓', ArrowLeft: '←', ArrowRight: '→', ' ': '␣' }

function comboLabel(e, modifiers) {
  const k = KEY_NAMES[e.key] || (e.key.length === 1 ? e.key.toUpperCase() : e.key)
  return modifiers.map(m => MOD_GLYPH[m]).join('') + k
}

function KeyRecorderButton({ onRecord }) {
  const [recording, setRecording] = useState(false)
  useEffect(() => {
    if (!recording) return
    const onKey = (e) => {
      e.preventDefault()
      e.stopPropagation()
      if (MODIFIER_CODES.has(e.code)) return
      if (e.code === 'Escape' && !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey) {
        setRecording(false)
        return
      }
      const keyCode = DOM_TO_CG[e.code]
      if (keyCode == null) return
      const modifiers = []
      if (e.ctrlKey) modifiers.push('ctrl')
      if (e.altKey) modifiers.push('opt')
      if (e.shiftKey) modifiers.push('shift')
      if (e.metaKey) modifiers.push('cmd')
      onRecord({ keyCode, modifiers, label: comboLabel(e, modifiers) })
      setRecording(false)
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [recording, onRecord])
  return (
    <button className={`abtn${recording ? '' : ' abtn-ghost'}`} onClick={() => setRecording(v => !v)}>
      {recording ? '按下组合键…（Esc 取消）' : '录制'}
    </button>
  )
}

function CustomEditor({ target, row, onSetCustomText, onSetCustomKey }) {
  if (row.action === 'Custom Text') {
    return (
      <div className="map-custom">
        <input
          key={row.key + ':' + row.customText}
          className="prof-input"
          type="text"
          placeholder="输入要键入的文本，如 /compact 或一段提示词"
          defaultValue={row.customText}
          onKeyDown={(e) => { if (e.key === 'Enter') e.currentTarget.blur() }}
          onBlur={(e) => onSetCustomText(target, row.key, e.target.value.trim())}
        />
      </div>
    )
  }
  if (row.action === 'Custom Key') {
    return (
      <div className="map-custom">
        <span className={`rec-label${row.customKey ? ' has-combo' : ''}`}>
          {row.customKey ? row.customKey.label : '未设置'}
        </span>
        <KeyRecorderButton onRecord={(combo) => onSetCustomKey(target, row.key, combo)} />
      </div>
    )
  }
  return null
}

// Modal that opens when the user clicks 编辑 on a profile row, or after
// 新建配置… creates one. Edits the profile's name (header input) and its
// button + swipe mappings (body). Built-in profiles get a locked name input
// (visually still in place but read-only and borderless).
export default function ProfileEditModal({ dev, profile, mappings,
  onSetButton, onSetSwipe, onSetScrollSpeed, onSetCustomText, onSetCustomKey,
  onRenameProfile, onSetTrackpadMode, onClose }) {
  const gen = dev.art === 'gen1' ? '1 代' : '2/3 代'
  const [name, setName] = useState(profile?.name || '')
  const nameInputRef = useRef(null)

  // Keep local name in sync with profile prop when switching between profiles.
  useEffect(() => { setName(profile?.name || '') }, [profile?.id])

  // Auto-focus the name input on mount (skip for built-ins since it's locked).
  useEffect(() => {
    if (!profile || profile.builtin) return
    const t = setTimeout(() => {
      if (nameInputRef.current) {
        nameInputRef.current.focus()
        nameInputRef.current.select()
      }
    }, 30)
    return () => clearTimeout(t)
  }, [profile?.id])

  // Esc closes the modal; backdrop click closes too.
  useEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  const handleBackdropClick = (e) => {
    if (e.target === e.currentTarget) onClose()
  }

  const commitName = () => {
    const trimmed = name.trim()
    if (!profile || profile.builtin) return
    if (!trimmed || trimmed === profile.name) return
    onRenameProfile(profile.id, trimmed)
  }

  if (!mappings || !profile) return null

  // The default profile is the system baseline — view-only to prevent accidental breakage.
  const readOnly = profile.id === 'default'

  return (
    <div className="modal-backdrop" role="dialog" aria-modal="true" onClick={handleBackdropClick}>
      <div className="modal" aria-labelledby="profModalName">
        <div className="modal-head">
          <input
            id="profModalName"
            ref={nameInputRef}
            className="modal-head-name"
            type="text"
            maxLength={16}
            placeholder="配置名称"
            aria-label="配置名称"
            value={name}
            disabled={profile.builtin}
            onChange={(e) => setName(e.target.value)}
            onBlur={commitName}
            onKeyDown={(e) => {
              if (e.key === 'Enter') { e.currentTarget.blur(); onClose() }
              if (e.key === 'Escape') onClose()
            }}
          />
          <button className="modal-close" aria-label="关闭" type="button" onClick={onClose}>×</button>
        </div>
        <div className="modal-body">
          {readOnly && <p className="map-note" style={{margin:'0 0 8px'}}>默认配置为系统基准，仅供查看，不可修改。</p>}
          <p className="group-label">按键自定义 · {dev.name}（{gen}）</p>
          <div className="group">
            <div className="map-head"><span>按键</span><span>手势</span><span>执行操作</span></div>
            <div>
              {mappings.buttons.map((r) => (
                <div key={r.key}>
                  <div className="map-row">
                    <span className="map-key">{r.label}</span>
                    <span className="map-gesture">{r.gesture}</span>
                    <select
                      className="map-sel"
                      value={r.action}
                      disabled={readOnly}
                      onChange={(e) => onSetButton(r.key, e.target.value)}
                    >
                      {r.options.map((o) => <option key={o.raw} value={o.raw}>{o.label}</option>)}
                    </select>
                  </div>
                  {!readOnly && <CustomEditor target="button" row={r} onSetCustomText={onSetCustomText} onSetCustomKey={onSetCustomKey} />}
                </div>
              ))}
            </div>
            <p className="map-note">
              语音听写类动作需按住说话，仅适用于支持长按的按键；映射立即生效并自动保存。
            </p>
          </div>

          <p className="group-label">触控板手势</p>
          <div className="group">
            <div className="map-row">
              <span className="map-key">触摸板模式</span>
              <span className="map-gesture">单指操作</span>
              <select
                className="map-sel"
                value={profile.trackpadMode || 'mouse'}
                disabled={readOnly}
                onChange={(e) => onSetTrackpadMode(profile.id, e.target.value)}
              >
                <option value="mouse">鼠标（光标控制）</option>
                <option value="gesture">手势（滑动快捷键）</option>
              </select>
            </div>
            <div className="map-head"><span>手势</span><span>触发方式</span><span>执行操作</span></div>
            <div>
              {mappings.swipes.map((r) => (
                <div key={r.key}>
                  <div className="map-row">
                    <span className="map-key">{r.label}</span>
                    <span className="map-gesture">{r.desc}</span>
                    <select
                      className="map-sel"
                      value={r.action}
                      disabled={readOnly}
                      onChange={(e) => onSetSwipe(r.key, e.target.value)}
                    >
                      {r.options.map((o) => <option key={o.raw} value={o.raw}>{o.label}</option>)}
                    </select>
                  </div>
                  {!readOnly && <CustomEditor target="swipe" row={r} onSetCustomText={onSetCustomText} onSetCustomKey={onSetCustomKey} />}
                </div>
              ))}
              <div className="map-row">
                <span className="map-key">滚动速度</span>
                <span className="map-gesture">双指滑动</span>
                <select
                  className="map-sel"
                  value={mappings.scrollSpeed}
                  disabled={readOnly}
                  onChange={(e) => onSetScrollSpeed(e.target.value)}
                >
                  {mappings.scrollSpeedOptions.map((o) => <option key={o.raw} value={o.raw}>{o.label}</option>)}
                </select>
              </div>
            </div>
            <p className="map-note">
              斜杠命令只会输入到输入框，需手动回车确认执行；映射立即生效并自动保存。
            </p>
          </div>
        </div>
      </div>
    </div>
  )
}