import type { Abi } from 'viem'
import {
  aaveOracleAbi,
  aavePoolAbi,
  aaveTokenAbi,
  currencyErrorsAbi,
  customRevertErrorsAbi,
  operatorAbi,
  poolManagerErrorsAbi,
  strategyAbi,
  vaultAbi,
  wethAbi,
} from '../abi'

type AbiItem = Abi[number]

const errorsOf = (abi: readonly unknown[]) => (abi as AbiItem[]).filter((item) => item.type === 'error')

const signature = (item: AbiItem) =>
  item.type === 'error' ? `${item.name}(${item.inputs.map((i) => i.type).join(',')})` : JSON.stringify(item)

/** Appends the errors of every contract a call can reach, once each, so viem decodes any revert into its name. */
function withErrors(main: readonly unknown[], ...reached: (readonly unknown[])[]): Abi {
  const seen = new Set<string>()
  const out: AbiItem[] = []
  for (const item of [...(main as AbiItem[]), ...reached.flatMap(errorsOf)]) {
    const key = signature(item)
    if (seen.has(key)) continue
    seen.add(key)
    out.push(item)
  }
  return out
}

// What a call can reach: the vault calls the strategy, which calls Aave and the Uniswap V4 PoolManager; checkHealth()
// calls back into the vault; the operator calls the vault and the strategy.
const external = [aavePoolAbi, poolManagerErrorsAbi, customRevertErrorsAbi, currencyErrorsAbi] as const

export const vaultCallAbi = withErrors(vaultAbi, strategyAbi, ...external)
export const strategyCallAbi = withErrors(strategyAbi, vaultAbi, ...external)
export const operatorCallAbi = withErrors(operatorAbi, vaultAbi, strategyAbi, ...external)

export { aaveOracleAbi, aavePoolAbi, aaveTokenAbi, operatorAbi, strategyAbi, vaultAbi, wethAbi }
