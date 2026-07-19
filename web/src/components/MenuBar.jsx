import { useState, useEffect } from 'react'
import Switch from './Switch'

function formatClock() {
  const d = new Date()
  const weekdays = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']
  const hh = String(d.getHours()).padStart(2, '0')
  const mm = String(d.getMinutes()).padStart(2, '0')
  return `${d.getMonth() + 1}月${d.getDate()}日 ${weekdays[d.getDay()]} ${hh}:${mm}`
}

function dotClass(d) {
  return !d.connected ? 'dot-off' : d.batt < 20 ? 'dot-warn' : 'dot-ok'
}

export default function MenuBar({ devices, appearance, onAppearance, onOpenWindow, onPair }) {
  const [open, setOpen] = useState(false)
  const [clock, setClock] = useState(formatClock)

  useEffect(() => {
    const t = setInterval(() => setClock(formatClock()), 30000)
    return () => clearInterval(t)
  }, [])

  useEffect(() => {
    if (!open) return
    const close = () => setOpen(false)
    const esc = (e) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('click', close)
    document.addEventListener('keydown', esc)
    return () => {
      document.removeEventListener('click', close)
      document.removeEventListener('keydown', esc)
    }
  }, [open])

  const connCount = devices.filter(d => d.connected).length
  const cur = devices.find(d => d.connected) || devices[0]

  return (
    <header className="menubar">
      <div className="mb-left">
        <svg viewBox="0 0 384 512" aria-hidden="true"><path d="M318.7 268.7c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141.2 4 184.8 4 273.5q0 39.3 14.4 81.2c12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.7 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-91.9zm-56.6-164.2c27.3-32.4 24.8-61.9 24-72.5-24.1 1.4-52 16.4-67.9 34.9-17.5 19.8-27.8 44.3-25.6 71.9 26.1 2 49.9-11.4 69.5-34.3z"/></svg>
        <span className="mb-app">Baton</span>
        <span className="mb-menu">文件</span>
        <span className="mb-menu">编辑</span>
        <span className="mb-menu">显示</span>
        <span className="mb-menu">窗口</span>
        <span className="mb-menu">帮助</span>
      </div>
      <div className="mb-right">
        <span className="mb-sys" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><path d="M5 12.5a10 10 0 0 1 14 0M8.2 15.7a5.5 5.5 0 0 1 7.6 0"/><circle cx="12" cy="18.6" r="1.1" fill="currentColor" stroke="none"/></svg>
        </span>
        <button
          className={`mb-icon${open ? ' open' : ''}`}
          aria-haspopup="true"
          aria-expanded={open}
          title="Baton"
          onClick={(e) => { e.stopPropagation(); setOpen(v => !v) }}
        >
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round"><rect x="8.5" y="2.5" width="7" height="19" rx="3"/><circle cx="12" cy="7.4" r="2.4"/><path d="M10.4 13.6h3.2M10.4 16.4h3.2"/></svg>
          <span className="mb-batt-pct num">{cur.batt}%</span>
        </button>
        <span className="mb-clock num">{clock}</span>
      </div>

      {open && (
        <div className="popover" role="menu" aria-label="Baton 菜单栏工具" onClick={(e) => e.stopPropagation()}>
          <div className="pv-head">
            <div className="pv-title">Siri Remote</div>
            <div className="pv-sub">{devices.length} 台设备 · {connCount} 台已连接</div>
          </div>
          <div>
            {devices.map(d => (
              <div className="pv-row" role="menuitem" key={d.id}>
                <i className={`pv-dot ${dotClass(d)}`}></i>
                <span className="pv-name">
                  <b>{d.name}</b>
                  <span>{d.connected ? `电量 ${d.batt}%${d.batt < 20 ? ' · 电量低' : ''}` : `未连接 · ${d.last}`}</span>
                </span>
              </div>
            ))}
          </div>
          <div className="pv-sep"></div>
          <div className="pv-switch-row">
            <span>外观</span>
            <div className="pv-seg" role="group" aria-label="外观">
              {[['auto', '跟随系统'], ['light', '浅色'], ['dark', '深色']].map(([value, label]) => (
                <button
                  key={value}
                  type="button"
                  className={appearance === value ? 'on' : ''}
                  aria-pressed={appearance === value}
                  onClick={() => onAppearance(value)}
                >{label}</button>
              ))}
            </div>
          </div>
          <div className="pv-sep"></div>
          <div className="pv-switch-row">
            <span>低电量提醒</span>
            <Switch small label="低电量提醒" />
          </div>
          <div className="pv-sep"></div>
          <div className="pv-foot">
            <button className="pv-btn" onClick={() => { setOpen(false); onPair() }}>添加遥控器…</button>
            <button className="pv-btn" onClick={() => { setOpen(false); onOpenWindow() }}>打开 Baton</button>
          </div>
        </div>
      )}
    </header>
  )
}
