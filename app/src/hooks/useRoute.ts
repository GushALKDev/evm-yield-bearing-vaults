import { useSyncExternalStore } from 'react'

export type Page = 'vault' | 'stress' | 'how' | 'legal'

export const pages: { page: Page; path: string; label: string }[] = [
  { page: 'vault', path: '/', label: 'Vault' },
  { page: 'stress', path: '/stress-test', label: 'Stress test' },
  { page: 'how', path: '/how-it-works', label: 'How it works' },
]

/** Linked from the footer only, so it stays out of the header's page list. */
export const LEGAL_PATH = '/legal'

function subscribe(onChange: () => void) {
  window.addEventListener('popstate', onChange)
  return () => window.removeEventListener('popstate', onChange)
}

const currentUrl = () => window.location.pathname + window.location.hash

/** Scrolls to the element the URL fragment names, or to the top when there is none. */
export function scrollToTarget() {
  const target = window.location.hash ? document.getElementById(window.location.hash.slice(1)) : null
  if (target) target.scrollIntoView()
  else window.scrollTo(0, 0)
}

export function navigate(href: string) {
  // The same URL re-renders nothing, so the scroll cannot wait for an effect.
  if (href === currentUrl()) return scrollToTarget()
  window.history.pushState(null, '', href)
  window.dispatchEvent(new PopStateEvent('popstate'))
}

/** Paths a page had before, kept so that old links still land on it. */
const aliases: Record<string, Page> = { '/emergency': 'stress' }

/** The page for a URL. Unknown paths show the vault: the host serves index.html for every path. */
export function pageFor(url: string): Page {
  const path = url.split('#')[0].replace(/\/+$/, '') || '/'
  if (path === LEGAL_PATH) return 'legal'
  return pages.find((p) => p.path === path)?.page ?? aliases[path] ?? 'vault'
}

export function useRoute(): { page: Page; url: string } {
  const url = useSyncExternalStore(subscribe, currentUrl)
  return { page: pageFor(url), url }
}
