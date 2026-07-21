import Switch from './Switch'

function Kbd({ children }) {
  return <span className="v kbd-row">{children}</span>
}

export default function SettingsPane({ version = '1.0 (1)' }) {
  return (
    <div className="pane">
      <h1 className="dh-name" style={{ margin: '0 0 16px' }}>通用设置</h1>

      <p className="group-label">通用</p>
      <div className="group">
        <div className="kv"><span className="k">登录时启动</span><Switch label="登录时启动" /></div>
        <div className="kv"><span className="k">关闭主窗口时保持运行</span><Switch label="关闭主窗口时保持运行" /></div>
        <div className="kv"><span className="k">菜单栏显示电池百分比</span><Switch label="菜单栏显示电池百分比" /></div>
        <div className="kv">
          <span className="k">整体外观</span>
          <select className="map-sel" defaultValue="auto" aria-label="整体外观">
            <option value="auto">跟随系统</option>
            <option value="light">浅色</option>
            <option value="dark">深色</option>
          </select>
        </div>
      </div>

      <p className="group-label">快捷键</p>
      <div className="group">
        <div className="kv"><span className="k">显示 / 隐藏主窗口</span><Kbd><kbd>⌘</kbd><kbd>Shift</kbd><kbd>R</kbd></Kbd></div>
        <div className="kv"><span className="k">添加遥控器</span><Kbd><kbd>⌘</kbd><kbd>N</kbd></Kbd></div>
        <div className="kv"><span className="k">切换外观模式</span><Kbd><kbd>⌘</kbd><kbd>Shift</kbd><kbd>L</kbd></Kbd></div>
        <div className="kv"><span className="k">跳到当前选中设备的设置</span><Kbd><kbd>⌘</kbd><kbd>,</kbd></Kbd></div>
      </div>

      <p className="group-label">关于</p>
      <div className="group">
        <div className="kv"><span className="k">版本</span><span className="v num">{version}</span></div>
        <div className="kv"><span className="k">开发者</span><span className="v">Baton Team</span></div>
        <div className="kv"><span className="k">本地数据</span><span className="v num">~/Library/Application Support/Baton</span></div>
        <div className="card-foot" style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
          <a className="abtn" href="https://github.com/cillins/Baton" target="_blank" rel="noreferrer">查看帮助</a>
        </div>
      </div>
    </div>
  )
}
