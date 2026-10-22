import { createContext, useCallback, useContext, useRef, useState, type ReactNode } from 'react'
import type { Position } from '../lib/vault'

/** The position a typed action would leave, so the loop drawing can outline it next to the live one. */
export interface Preview {
  label: string
  after: Position
  /** The visitor's vault shares and the total supply after the action, to outline their slice */
  share?: { shares: bigint; supply: bigint }
}

// The value and the setter live in separate contexts: a component that publishes a preview must not re-render when
// the preview changes, or publishing from an effect loops (each render builds a new position object).
const PreviewValue = createContext<Preview | null>(null)
const PreviewSetter = createContext<((p: Preview | null) => void) | null>(null)

const keyOf = (p: Preview | null) =>
  p ? `${p.label}|${p.after.collateral}|${p.after.debt}|${p.after.idle}|${p.after.healthFactor}|${p.share?.shares}|${p.share?.supply}` : ''

export function PreviewProvider({ children }: { children: ReactNode }) {
  const [preview, setPreview] = useState<Preview | null>(null)
  const last = useRef('')
  // Publishes only when the previewed position changes, compared by value
  const publish = useCallback((p: Preview | null) => {
    const key = keyOf(p)
    if (key === last.current) return
    last.current = key
    setPreview(p)
  }, [])
  return (
    <PreviewSetter.Provider value={publish}>
      <PreviewValue.Provider value={preview}>{children}</PreviewValue.Provider>
    </PreviewSetter.Provider>
  )
}

export function usePreview(): Preview | null {
  return useContext(PreviewValue)
}

export function useSetPreview(): (p: Preview | null) => void {
  const set = useContext(PreviewSetter)
  if (!set) throw new Error('useSetPreview outside PreviewProvider')
  return set
}
