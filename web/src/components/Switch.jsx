import { useState } from 'react'

export default function Switch({ defaultOn = true, small = false, label }) {
  const [on, setOn] = useState(defaultOn)
  return (
    <button
      className={`sw${small ? ' sm' : ''}${on ? ' on' : ''}`}
      role="switch"
      aria-checked={on}
      aria-label={label}
      onClick={() => setOn(v => !v)}
    />
  )
}
