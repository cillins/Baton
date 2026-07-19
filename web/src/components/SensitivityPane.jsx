import SliderRow from './SliderRow'

// Consolidated sensitivity controls: trackpad cursor scale + gyro drag gain
// and smoothing (gen 1 remote only). Sits after 应用预设 in the main tab bar
// so the per-profile mapping editor stays focused on key/swipe assignments.
export default function SensitivityPane({ dev, mappings,
  trackpadSensitivity, onSetTrackpadSensitivity,
  onSetGyroSettings }) {
  const trackpad = trackpadSensitivity ?? 500
  const gyro = mappings?.gyro
  const isGen1 = dev?.art === 'gen1'

  return (
    <div className="pane">
      <p className="group-label">触控板</p>
      <div className="group">
        <SliderRow
          label="光标灵敏度"
          min={100} max={1000} step={10}
          value={trackpad}
          format={(v) => `${Math.round(v)}`}
          disabled={trackpadSensitivity == null || !onSetTrackpadSensitivity}
          onCommit={(v) => onSetTrackpadSensitivity && onSetTrackpadSensitivity(Math.round(v))}
        />
        <p className="map-note">调整双指移动时光标的响应幅度；数值越大移动越快。</p>
      </div>

      {isGen1 && gyro && onSetGyroSettings && (
        <>
          <p className="group-label">陀螺仪（一代遥控器）</p>
          <div className="group">
            <SliderRow
              label="拖动灵敏度"
              min={0.5} max={6} step={0.1}
              value={gyro.gain}
              format={(v) => Number(v).toFixed(1)}
              onCommit={(v) => onSetGyroSettings({ gain: v })}
            />
            <SliderRow
              label="防抖强度"
              min={0} max={100} step={1}
              value={gyro.smoothing}
              format={(v) => `${Math.round(v)}%`}
              onCommit={(v) => onSetGyroSettings({ smoothing: Math.round(v) })}
            />
            <p className="map-note">按住触控板挥动遥控器，按挥动速度拖动光标。</p>
          </div>
        </>
      )}
    </div>
  )
}
