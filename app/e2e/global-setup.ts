import { mkdirSync, writeFileSync } from 'node:fs'
import { rpc } from './chain'

// Snapshot the fork so the run leaves it as it found it (global-teardown.ts reverts)
export default async function globalSetup() {
  const id = await rpc<string>('evm_snapshot')
  mkdirSync('test-results', { recursive: true })
  writeFileSync('test-results/e2e-snapshot', id)
}
