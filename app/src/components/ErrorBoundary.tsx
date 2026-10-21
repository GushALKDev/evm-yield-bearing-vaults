import { Component, type ErrorInfo, type ReactNode } from 'react'
import { links } from '../config/chain'

/** Shows a message instead of a blank page when a render throws, for example on state no preview models. */
export class ErrorBoundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null }

  static getDerivedStateFromError(error: Error) {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error(error, info.componentStack)
  }

  render() {
    if (!this.state.error) return this.props.children
    return (
      <main className="wrap hero">
        <div className="hero-head">
          <h1>The page could not show the vault's current state.</h1>
          <p className="hero-sub">
            Reload to read it again. If it keeps happening, the chain is in a state this app does not model; the{' '}
            <a href={links.repo}>source code</a> has the details. ({this.state.error.message})
          </p>
        </div>
      </main>
    )
  }
}
