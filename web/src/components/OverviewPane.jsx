export default function OverviewPane({ dev }) {
  return (
    <div className="pane">
      <p className="group-label">连接</p>
      <div className="group">
        <div className="kv"><span className="k">状态</span><span className={`v ${dev.connected ? 'ok' : 'off'}`}>{dev.connected ? '已连接' : '未连接'}</span></div>
        <div className="kv"><span className="k">方式</span><span className="v">{dev.art === 'gen1' ? '蓝牙 4.0' : '蓝牙 5.0'}</span></div>
      </div>

      <p className="group-label">设备信息</p>
      <div className="group">
        <div className="kv"><span className="k">型号</span><span className="v">{dev.model}</span></div>
        <div className="kv"><span className="k">上次连接</span><span className="v">{dev.last}</span></div>
      </div>
    </div>
  )
}
