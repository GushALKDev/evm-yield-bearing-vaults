// Regression tests for scripts/local-chain.sh, run against a fresh anvil fork on a spare port:
//   LOCAL_CHAIN_TEST=1 npx vitest run scripts/local-chain.test.ts
// Needs Foundry and the Base Sepolia RPC the script forks. The deployment goes to a separate file, removed at the end,
// and the test stops only the anvil it started.
import { execFileSync, spawn } from 'node:child_process'
import { existsSync, readFileSync, rmSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { afterAll, describe, expect, it, vi } from 'vitest'

const enabled = !!process.env.LOCAL_CHAIN_TEST
vi.setConfig({ testTimeout: 120_000 })

const script = fileURLToPath(new URL('./local-chain.sh', import.meta.url))
const file = fileURLToPath(new URL('../src/config/deployments/local-chain-test.json', import.meta.url))
const port = 8_611

const listenerPids = () => {
  try {
    return execFileSync('lsof', ['-ti', `tcp:${port}`, '-sTCP:LISTEN']).toString().trim().split('\n').filter(Boolean)
  } catch {
    return []
  }
}

/** Runs the script with its output piped, as CI and `| tail` do; resolves with the exit code, or null on timeout. */
function runPiped(timeoutMs: number): Promise<number | null> {
  return new Promise((resolve) => {
    const child = spawn('bash', ['-o', 'pipefail', '-c', `"${script}" | cat`], {
      env: { ...process.env, RPC: `http://127.0.0.1:${port}`, DEPLOYMENT_FILE: 'app/src/config/deployments/local-chain-test.json' },
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    child.stdout.resume()
    child.stderr.resume()
    const timer = setTimeout(() => {
      child.kill('SIGKILL')
      resolve(null)
    }, timeoutMs)
    child.on('exit', (code) => {
      clearTimeout(timer)
      resolve(code)
    })
  })
}

describe.skipIf(!enabled)('local-chain.sh', () => {
  afterAll(() => {
    for (const pid of listenerPids()) process.kill(Number(pid))
    rmSync(file, { force: true })
  })

  // Regressions: anvil started on 8545 whatever RPC said, and its inherited stdout kept a pipeline from finishing
  it('starts anvil on the port RPC names and finishes when its output is piped', async () => {
    expect(listenerPids(), `port ${port} must be free`).toEqual([])
    const code = await runPiped(90_000)
    expect(code, 'the piped run finished (null means it hung)').toBe(0)
    expect(listenerPids().length, `anvil listens on ${port}`).toBeGreaterThan(0)
    expect(existsSync(file), 'deployment written').toBe(true)
    expect(JSON.parse(readFileSync(file, 'utf8')).chainId).toBe(31_337)
  })
})
