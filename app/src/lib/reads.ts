// What the app reads from the chain, and how it decodes it: shared by the data hook and the parity suite, so the suite
// checks the exact values the app projects. Every live read goes into one Multicall3 call, so it comes from one block.
import type { Abi, Address } from 'viem'
import type { Deployment } from '../config/deployment'
import { aaveOracleAbi, aavePoolAbi, aaveTokenAbi, operatorAbi, strategyAbi, vaultAbi, wethAbi } from './abi'
import type { Reserve } from './aave'

/** Constants of the strategy and the operator: read once. */
export interface StaticData {
  eModeCategory: number
  minRemainingEquity: bigint
  minInvestAssets: bigint
  marginBps: bigint
  shockCooldown: bigint
  shockMinOffset: bigint
  shockTargetOffset: bigint
  defaultMinHealthFactor: bigint
  defaultTargetHealthFactor: bigint
}

/** Everything that moves, read in one Multicall3 call so it comes from a single block. */
export interface LiveData {
  vault: {
    totalSupply: bigint
    highWaterMark: bigint
    feeBps: bigint
    feeRecipient: Address
    emergency: boolean
    admin: Address
    owner: Address
    idle: bigint
    strategyShares: bigint
  }
  strategy: {
    totalSupply: bigint
    emergency: boolean
    minHealthFactor: bigint
    targetHealthFactor: bigint
    targetLeverage: bigint
    idle: bigint
    aScaled: bigint
    debtScaled: bigint
  }
  reserve: Reserve
  eModeLtv: bigint
  eModeLiquidationThreshold: bigint
  price: bigint
  flashLiquidity: bigint
  lastShockAt: bigint
  account?: AccountReads
}

export interface AccountReads {
  shares: bigint
  whitelisted: boolean
  weth: bigint
  allowance: bigint
}

export interface AccountData extends AccountReads {
  /** Unknown while loading, so the interface does not flash a no-gas warning */
  eth: bigint | undefined
}

export interface Read {
  address: Address
  abi: Abi | readonly unknown[]
  functionName: string
  args?: readonly unknown[]
}

export function staticReads(d: Deployment) {
  return {
    eModeCategory: { address: d.strategy, abi: strategyAbi, functionName: 'E_MODE_CATEGORY_ID' },
    minRemainingEquity: { address: d.strategy, abi: strategyAbi, functionName: 'MIN_REMAINING_EQUITY' },
    minInvestAssets: { address: d.strategy, abi: strategyAbi, functionName: 'MIN_INVEST_ASSETS' },
    marginBps: { address: d.strategy, abi: strategyAbi, functionName: 'HEALTH_FACTOR_MARGIN_BPS' },
    shockCooldown: { address: d.operator, abi: operatorAbi, functionName: 'SHOCK_COOLDOWN' },
    shockMinOffset: { address: d.operator, abi: operatorAbi, functionName: 'SHOCK_MIN_OFFSET' },
    shockTargetOffset: { address: d.operator, abi: operatorAbi, functionName: 'SHOCK_TARGET_OFFSET' },
    defaultMin: { address: d.operator, abi: operatorAbi, functionName: 'DEFAULT_MIN_HEALTH_FACTOR' },
    defaultTarget: { address: d.operator, abi: operatorAbi, functionName: 'DEFAULT_TARGET_HEALTH_FACTOR' },
  } satisfies Record<string, Read>
}

export function liveReads(d: Deployment, eModeCategory: number, account: Address | undefined) {
  const base = {
    vaultSupply: { address: d.vault, abi: vaultAbi, functionName: 'totalSupply' },
    hwm: { address: d.vault, abi: vaultAbi, functionName: 'highWaterMark' },
    feeBps: { address: d.vault, abi: vaultAbi, functionName: 'protocolFeeBps' },
    feeRecipient: { address: d.vault, abi: vaultAbi, functionName: 'feeRecipient' },
    vaultEmergency: { address: d.vault, abi: vaultAbi, functionName: 'emergencyMode' },
    admin: { address: d.vault, abi: vaultAbi, functionName: 'admin' },
    owner: { address: d.vault, abi: vaultAbi, functionName: 'owner' },
    vaultIdle: { address: d.weth, abi: wethAbi, functionName: 'balanceOf', args: [d.vault] },
    vaultStrategyShares: { address: d.strategy, abi: strategyAbi, functionName: 'balanceOf', args: [d.vault] },
    strategySupply: { address: d.strategy, abi: strategyAbi, functionName: 'totalSupply' },
    strategyEmergency: { address: d.strategy, abi: strategyAbi, functionName: 'emergencyMode' },
    minHf: { address: d.strategy, abi: strategyAbi, functionName: 'minHealthFactor' },
    targetHf: { address: d.strategy, abi: strategyAbi, functionName: 'targetHealthFactor' },
    leverage: { address: d.strategy, abi: strategyAbi, functionName: 'targetLeverage' },
    strategyIdle: { address: d.weth, abi: wethAbi, functionName: 'balanceOf', args: [d.strategy] },
    aScaled: { address: d.aToken, abi: aaveTokenAbi, functionName: 'scaledBalanceOf', args: [d.strategy] },
    debtScaled: { address: d.variableDebtToken, abi: aaveTokenAbi, functionName: 'scaledBalanceOf', args: [d.strategy] },
    aSupply: { address: d.aToken, abi: aaveTokenAbi, functionName: 'scaledTotalSupply' },
    debtSupply: { address: d.variableDebtToken, abi: aaveTokenAbi, functionName: 'scaledTotalSupply' },
    reserve: { address: d.aavePool, abi: aavePoolAbi, functionName: 'getReserveData', args: [d.weth] },
    virtualBalance: { address: d.aavePool, abi: aavePoolAbi, functionName: 'getVirtualUnderlyingBalance', args: [d.weth] },
    eMode: { address: d.aavePool, abi: aavePoolAbi, functionName: 'getEModeCategoryCollateralConfig', args: [eModeCategory] },
    price: { address: d.aaveOracle, abi: aaveOracleAbi, functionName: 'getAssetPrice', args: [d.weth] },
    flash: { address: d.weth, abi: wethAbi, functionName: 'balanceOf', args: [d.poolManager] },
    lastShockAt: { address: d.operator, abi: operatorAbi, functionName: 'lastShockAt' },
  } satisfies Record<string, Read>
  if (!account) return base
  return {
    ...base,
    shares: { address: d.vault, abi: vaultAbi, functionName: 'balanceOf', args: [account] },
    whitelisted: { address: d.vault, abi: vaultAbi, functionName: 'isWhitelisted', args: [account] },
    weth: { address: d.weth, abi: wethAbi, functionName: 'balanceOf', args: [account] },
    allowance: { address: d.weth, abi: wethAbi, functionName: 'allowance', args: [account, d.vault] },
  } satisfies Record<string, Read>
}

interface RawReserve {
  configuration: bigint
  liquidityIndex: bigint
  currentLiquidityRate: bigint
  variableBorrowIndex: bigint
  currentVariableBorrowRate: bigint
  lastUpdateTimestamp: number
  accruedToTreasury: bigint
}

const accountFrom = (r: Record<string, unknown>): AccountReads => ({
  shares: r.shares as bigint,
  whitelisted: r.whitelisted as boolean,
  weth: r.weth as bigint,
  allowance: r.allowance as bigint,
})

export function decodeStatic(r: Record<string, unknown>): StaticData {
  return {
    eModeCategory: Number(r.eModeCategory),
    minRemainingEquity: r.minRemainingEquity as bigint,
    minInvestAssets: r.minInvestAssets as bigint,
    marginBps: r.marginBps as bigint,
    shockCooldown: r.shockCooldown as bigint,
    shockMinOffset: r.shockMinOffset as bigint,
    shockTargetOffset: r.shockTargetOffset as bigint,
    defaultMinHealthFactor: r.defaultMin as bigint,
    defaultTargetHealthFactor: r.defaultTarget as bigint,
  }
}

export function decodeLive(r: Record<string, unknown>, account: Address | undefined): LiveData {
  const reserve = r.reserve as RawReserve
  const eMode = r.eMode as { ltv: number; liquidationThreshold: number }
  return {
    vault: {
      totalSupply: r.vaultSupply as bigint,
      highWaterMark: r.hwm as bigint,
      feeBps: BigInt(r.feeBps as number),
      feeRecipient: r.feeRecipient as Address,
      emergency: r.vaultEmergency as boolean,
      admin: r.admin as Address,
      owner: r.owner as Address,
      idle: r.vaultIdle as bigint,
      strategyShares: r.vaultStrategyShares as bigint,
    },
    strategy: {
      totalSupply: r.strategySupply as bigint,
      emergency: r.strategyEmergency as boolean,
      minHealthFactor: r.minHf as bigint,
      targetHealthFactor: r.targetHf as bigint,
      targetLeverage: BigInt(r.leverage as number),
      idle: r.strategyIdle as bigint,
      aScaled: r.aScaled as bigint,
      debtScaled: r.debtScaled as bigint,
    },
    reserve: {
      configuration: BigInt(reserve.configuration),
      liquidityIndex: BigInt(reserve.liquidityIndex),
      currentLiquidityRate: BigInt(reserve.currentLiquidityRate),
      variableBorrowIndex: BigInt(reserve.variableBorrowIndex),
      currentVariableBorrowRate: BigInt(reserve.currentVariableBorrowRate),
      lastUpdateTimestamp: BigInt(reserve.lastUpdateTimestamp),
      accruedToTreasury: BigInt(reserve.accruedToTreasury),
      scaledATokenSupply: r.aSupply as bigint,
      scaledDebtSupply: r.debtSupply as bigint,
      virtualBalance: BigInt(r.virtualBalance as bigint),
    },
    eModeLtv: BigInt(eMode.ltv),
    eModeLiquidationThreshold: BigInt(eMode.liquidationThreshold),
    price: r.price as bigint,
    flashLiquidity: r.flash as bigint,
    lastShockAt: r.lastShockAt as bigint,
    account: account && 'shares' in r ? accountFrom(r as Record<string, unknown>) : undefined,
  }
}
