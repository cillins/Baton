import { useState } from 'react'

// AppsPane (native): lists apps that have been bound to a profile. Each row
// has an icon, app name, a profile picker, and a remove button. "添加应用…"
// opens a modal-style inline panel listing every installed app (icons +
// names) returned by the bridge's listInstalledApps command.
export default function AppsPane({ presets, profiles, availableApps,
  onSetPresetProfile, onRemovePreset, onAddPreset }) {
  const [pickerOpen, setPickerOpen] = useState(false)

  return (
    <div className="pane">
      <p className="group-label">应用预设</p>
      <div className="group">
        <div>
          {presets.length === 0 && (
            <p className="map-note" style={{ marginTop: 0 }}>尚未绑定任何应用。下面前台打开时会套用「默认映射」。</p>
          )}
          {presets.map((p) => (
            <div className="app-row" key={p.bundleId}>
              {p.iconData
                ? <img className="app-ic-img" src={`data:image/png;base64,${p.iconData}`} alt="" />
                : <span className="app-ic" />}
              <span className="app-name">{p.appName}</span>
              <select
                className="map-sel"
                aria-label={`${p.appName} 的配置`}
                value={p.profileId}
                onChange={(e) => onSetPresetProfile(p.bundleId, e.target.value)}
              >
                {profiles.map(pr => (
                  <option key={pr.id} value={pr.id}>{pr.name}</option>
                ))}
              </select>
              <button
                className="abtn abtn-ghost app-remove"
                aria-label="移除"
                onClick={() => onRemovePreset(p.bundleId)}
              >移除</button>
            </div>
          ))}
        </div>
        <p className="map-note">
          前台打开应用时自动套用对应的配置；回到其他应用恢复当前的「默认映射」。
        </p>
        <div className="map-foot">
          <button className="abtn" onClick={() => setPickerOpen(v => !v)}>
            {pickerOpen ? '收起列表' : '添加应用…'}
          </button>
        </div>
        {pickerOpen && (
          <div className="app-picker">
            <p className="map-note">点击应用即可绑定到当前配置「{profiles.find(p => p.active)?.name || '默认映射'}」。</p>
            {availableApps.length === 0
              ? <p className="map-note">未发现已安装的应用。</p>
              : availableApps
                  .filter(a => !presets.some(p => p.bundleId === a.bundleId))
                  .map(a => (
                    <div className="app-row" key={a.bundleId}>
                      {a.iconData
                        ? <img className="app-ic-img" src={`data:image/png;base64,${a.iconData}`} alt="" />
                        : <span className="app-ic" />}
                      <span className="app-name">{a.appName}</span>
                      <button
                        className="abtn app-add"
                        onClick={() => onAddPreset(a.bundleId)}
                      >添加</button>
                    </div>
                  ))}
          </div>
        )}
      </div>
    </div>
  )
}