import { readFileSync } from 'node:fs'
import { rpc } from './chain'

export default async function globalTeardown() {
  await rpc('evm_revert', [readFileSync('test-results/e2e-snapshot', 'utf8')])
}
