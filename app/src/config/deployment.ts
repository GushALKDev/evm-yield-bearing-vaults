import type { Address } from 'viem'

// Deployment files are written by script/testnet/DeployTestnet.s.sol, one per chain id, only on a run with --broadcast.
interface RawDeployment {
  chainId: number
  deployBlock: number
  vault: Address
  strategy: Address
  operator: Address
  weth: Address
  aavePool: Address
  aToken: Address
  variableDebtToken: Address
  aaveOracle: Address
  poolManager: Address
  seedAssets: string
}

export interface Deployment {
  chainId: number
  deployBlock: bigint
  vault: Address
  strategy: Address
  operator: Address
  weth: Address
  aavePool: Address
  aToken: Address
  variableDebtToken: Address
  aaveOracle: Address
  poolManager: Address
  seedAssets: bigint
}

const files = import.meta.glob<RawDeployment>('./deployments/*.json', { eager: true, import: 'default' })

export function loadDeployment(chainId: number): Deployment | null {
  const raw = files[`./deployments/${chainId}.json`]
  if (!raw) return null
  return {
    chainId: raw.chainId,
    deployBlock: BigInt(raw.deployBlock),
    vault: raw.vault,
    strategy: raw.strategy,
    operator: raw.operator,
    weth: raw.weth,
    aavePool: raw.aavePool,
    aToken: raw.aToken,
    variableDebtToken: raw.variableDebtToken,
    aaveOracle: raw.aaveOracle,
    poolManager: raw.poolManager,
    seedAssets: BigInt(raw.seedAssets),
  }
}
