import { REMOTE_ART } from '../art'

function dotClass(d) {
  return !d.connected ? 'dot-off' : (d.batt > 0 && d.batt < 20) ? 'dot-warn' : 'dot-ok'
}

export default function Sidebar({ devices, devId, onSelect, onPair }) {
  return (
    <aside className="sidebar">
      <div className="sb-label">设备</div>
      <div className="sb-list">
        {devices.map(d => (
          <button
            key={d.id}
            className={`sb-device${d.id === devId ? ' on' : ''}`}
            role="listitem"
            onClick={() => onSelect(d.id)}
          >
            <span className="sb-ricon" dangerouslySetInnerHTML={{ __html: REMOTE_ART[d.art] }} />
            <span className="sb-meta">
              <span className="sb-name">{d.name}</span>
              <span className="sb-status">
                <i className={`pv-dot ${dotClass(d)}`}></i>
                {d.connected ? '已连接 · ' : '未连接 · '}
                <span className="num">{d.batt > 0 ? `${d.batt}%` : '—'}</span>
              </span>
            </span>
          </button>
        ))}
      </div>
      <div className="sb-foot">
        <button className="sb-add" onClick={onPair}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"><path d="M12 5v14M5 12h14"/></svg>
          添加遥控器…
        </button>
      </div>
    </aside>
  )
}
