import { useState } from 'react'

// Slider row: local state while dragging, commits to native on pointer-up
// (React fires onChange continuously during drags, so committing there would
// spam UserDefaults at 60Hz). Keyboard changes commit on keyup/blur.
export default function SliderRow({ label, min, max, step, value, format, disabled, onCommit }) {
  const [draft, setDraft] = useState(null)
  const shown = draft !== null ? draft : value
  const commit = (v) => { onCommit(v); setDraft(null) }
  return (
    <div className="kv gyro-slider">
      <span className="k">{label}</span>
      <span className="v gyro-slider-ctl">
        <input
          type="range"
          min={min}
          max={max}
          step={step}
          value={shown}
          disabled={disabled}
          onChange={(e) => setDraft(Number(e.target.value))}
          onPointerUp={() => { if (draft !== null) commit(draft) }}
          onKeyUp={(e) => commit(Number(e.target.value))}
          onBlur={() => { if (draft !== null) commit(draft) }}
        />
        <span className="num gyro-slider-val">{format(shown)}</span>
      </span>
    </div>
  )
}
