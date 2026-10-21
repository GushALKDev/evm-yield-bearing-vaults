import { readFileSync } from 'node:fs'
import { encodeFunctionData, parseAbi, type Address, type Hex } from 'viem'

export const RPC = process.env.E2E_RPC ?? 'http://127.0.0.1:8545'
// anvil's default accounts 1 and 2, unlocked on a local node
export const ALICE = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8' as Address
export const CAROL = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC' as Address

export const deployment = () =>
  JSON.parse(readFileSync(new URL('../src/config/deployments/31337.json', import.meta.url), 'utf8')) as Record<string, Address>

export async function rpc<T = unknown>(method: string, params: unknown[] = []): Promise<T> {
  const res = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) })
  const body = (await res.json()) as { result?: T; error?: { message: string } }
  if (body.error) throw new Error(`${method}: ${body.error.message}`)
  return body.result as T
}

/** Sends a call as an unlocked anvil account, with an ample gas limit, and waits for it to be mined. */
export async function sendAs(from: Address, to: Address, signature: string, args: unknown[] = []): Promise<void> {
  const fn = signature.split('(')[0]
  const data = encodeFunctionData({ abi: parseAbi([`function ${signature}`]), functionName: fn, args } as never) as Hex
  const hash = await rpc<Hex>('eth_sendTransaction', [{ from, to, data, gas: '0x5b8d80' }])
  for (let i = 0; i < 50; i++) {
    const receipt = await rpc<{ status: Hex } | null>('eth_getTransactionReceipt', [hash])
    if (receipt) {
      if (receipt.status !== '0x1') throw new Error(`${fn} reverted`)
      return
    }
    await new Promise((r) => setTimeout(r, 100))
  }
  throw new Error(`${fn} not mined`)
}

export async function advance(seconds: number): Promise<void> {
  await rpc('evm_increaseTime', [seconds])
  await rpc('evm_mine')
}
