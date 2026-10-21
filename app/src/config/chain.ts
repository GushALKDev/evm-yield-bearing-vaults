import { defineChain, type Chain } from 'viem'
import { baseSepolia } from 'viem/chains'
import { loadDeployment } from './deployment'

const envRpcUrl: string | undefined = import.meta.env.VITE_RPC_URL || undefined

// The local rehearsal is anvil forking Base Sepolia (scripts/local-chain.sh), so Multicall3 sits at its usual
// address and every Base Sepolia contract the vault uses is there too. Its default URL is the app's RPC: wagmi's mock
// connector (end-to-end tests) sends transactions to rpcUrls.default, not to the app's transport.
const localChain = defineChain({
  id: 31_337,
  name: 'Local fork',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [envRpcUrl ?? 'http://127.0.0.1:8545'] } },
  contracts: { multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' } },
})

export const chainId = Number(import.meta.env.VITE_CHAIN_ID ?? baseSepolia.id)

export const chain: Chain = chainId === localChain.id ? localChain : baseSepolia

export const rpcUrl: string = envRpcUrl ?? chain.rpcUrls.default.http[0]

export const deployment = loadDeployment(chain.id)

export const explorer = chain.blockExplorers?.default.url

export const links = {
  repo: 'https://github.com/GushALKDev/evm-yield-bearing-vaults',
  docs: 'https://github.com/GushALKDev/evm-yield-bearing-vaults/blob/main/docs/01-architecture.md',
  economics: 'https://github.com/GushALKDev/evm-yield-bearing-vaults/blob/main/docs/02-economics.md',
  author: 'https://www.linkedin.com/in/gustavomaral/',
  ethFaucet: 'https://docs.base.org/base-chain/network-information/network-faucets',
}

export function explorerAddress(address: string) {
  return explorer ? `${explorer}/address/${address}` : undefined
}

export function explorerTx(hash: string) {
  return explorer ? `${explorer}/tx/${hash}` : undefined
}
