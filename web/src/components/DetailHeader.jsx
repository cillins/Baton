import { isNative } from '../bridge'

// Battery indicator: SVG shell (rounded rect) + filled bar + tip + percentage.
// Always rendered (the design shows last-known battery even when disconnected).
// batt === 0 means "unknown" (no BLE reading yet) — show "—" instead of 0%.
function battStatus(d) {
  const known = d.batt > 0
  const fillW = known ? Math.max(1.5, Math.round(d.batt / 100 * 18 * 10) / 10) : 0
  const level = known && d.batt < 20 ? 'warn' : 'ok'
  return (
    <span className="batt-ind" data-level={level} role="img" aria-label={known ? `电量 ${d.batt} 百分比` : '电量未知'}>
      <svg viewBox="0 0 26 14" width="22" height="12" aria-hidden="true">
        <rect className="batt-shell" x="1" y="1" width="22" height="12" rx="2.2" />
        {known && <rect className="batt-fill" x="3" y="3" width={fillW} height="8" rx="1" />}
        <rect className="batt-tip" x="23.5" y="4.5" width="2" height="5" rx="0.6" />
      </svg>
      <span className="batt-pct num">{known ? `${d.batt}%` : '—'}</span>
    </span>
  )
}

export default function DetailHeader({ dev, connecting, onConnect }) {
  return (
    <header className="detail-head">
      <div className="dh-text">
        <h1 className="dh-name">{dev.name}</h1>
        <div className="dh-status">{battStatus(dev)}</div>
      </div>
      {!dev.connected && !isNative && (
        <button className="abtn" disabled={connecting} onClick={onConnect}>
          {connecting ? '连接中…' : '连接'}
        </button>
      )}
    </header>
  )
}

export function LowBatteryAlert({ dev }) {
  return (
    <div className="alert">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M12 3.5 2.5 20.5h19L12 3.5z"/><path d="M12 10v4.6M12 17.8v.2"/></svg>
      <span><b>电量不足。</b><span>{dev.name} 电量仅剩 {dev.batt}%，请尽快为其充电，以免使用中断开连接。</span></span>
    </div>
  )
}
