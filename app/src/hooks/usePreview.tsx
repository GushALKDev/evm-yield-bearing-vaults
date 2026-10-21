import { createContext, useContext, useMemo, useState, type ReactNode } from 'react'
import type { Position } from '../lib/vault'

/** The position a typed action would leave, so the loop drawing can outline it next to the live one. */
export interface Preview {
  label: string
  after: Position
}

const PreviewContext = createContext<{ preview: Preview | null; setPreview: (p: Preview | null) => void } | null>(null)

export function PreviewProvider({ children }: { children: ReactNode }) {
  const [preview, setPreview] = useState<Preview | null>(null)
  const value = useMemo(() => ({ preview, setPreview }), [preview])
  return <PreviewContext.Provider value={value}>{children}</PreviewContext.Provider>
}

export function usePreview(): Preview | null {
  return useContext(PreviewContext)?.preview ?? null
}

export function useSetPreview(): (p: Preview | null) => void {
  const ctx = useContext(PreviewContext)
  if (!ctx) throw new Error('useSetPreview outside PreviewProvider')
  return ctx.setPreview
}
