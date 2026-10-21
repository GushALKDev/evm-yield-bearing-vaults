import { afterEach, describe, expect, it, vi } from 'vitest'

describe('chain config', () => {
  afterEach(() => {
    vi.unstubAllEnvs()
    vi.resetModules()
  })

  // Regression: wagmi's mock connector sends transactions to chain.rpcUrls.default, so with the local chain hard-wired to
  // 127.0.0.1:8545 the e2e wallet sent them to whatever node listened there instead of VITE_RPC_URL
  it('points the local chain at VITE_RPC_URL, which the mock connector uses for transactions', async () => {
    vi.stubEnv('VITE_CHAIN_ID', '31337')
    vi.stubEnv('VITE_RPC_URL', 'http://127.0.0.1:9999')
    const { chain, rpcUrl } = await import('./chain')
    expect(rpcUrl).toBe('http://127.0.0.1:9999')
    expect(chain.rpcUrls.default.http[0]).toBe('http://127.0.0.1:9999')
  })

  it('keeps Base Sepolia when no chain id is set', async () => {
    vi.stubEnv('VITE_CHAIN_ID', '84532')
    const { chain } = await import('./chain')
    expect(chain.id).toBe(84_532)
  })
})
