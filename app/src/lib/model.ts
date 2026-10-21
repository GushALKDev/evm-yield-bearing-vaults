import { zeroAddress } from 'viem'
import type { Deployment } from '../config/deployment'
import type { AccountData, LiveData, StaticData } from './reads'
import { MAX_UINT256, RAY, WAD, readConfiguration, debtBalance, aTokenBalance, normalizedDebt, normalizedIncome } from './aave'
import {
  depositRoom,
  maxDeposit,
  maxRedeem,
  maxWithdraw,
  pendingFee,
  position,
  strategyTotalAssets,
  vaultToAssets,
  vaultTotalAssets,
  type PendingFee,
  type Position,
  type State,
} from './vault'

export interface AccountView {
  shares: bigint
  /** Shares at convertToAssets, projected to the visitor's clock */
  assets: bigint
  /** The same at the latest block's timestamp: what the next call sees */
  assetsAtChain: bigint
  /** Limits at the latest block's timestamp */
  maxWithdraw: bigint
  maxRedeem: bigint
  maxDeposit: bigint
  data: AccountData
}

export interface ShockView {
  ownsRoles: boolean
  lastShockAt: bigint
  nextShockAt: bigint
  /** Thresholds differ from the deployment values */
  shocked: boolean
}

export interface VaultModel {
  deployment: Deployment
  static: StaticData
  live: LiveData
  /** For simulations and previews */
  state: State
  /** Visitor's clock (balances tick with it) and the latest block's timestamp (limits and previews use it) */
  now: bigint
  chainTime: bigint
  /** The latest block has been read; until then chainTime is the visitor's clock and actions wait */
  chainKnown: boolean
  position: Position
  positionAtChain: Position
  strategyEquity: bigint
  vaultAssets: bigint
  fee: PendingFee
  supplyRate: bigint
  borrowRate: bigint
  /** Annual rate on the vault's equity at current Aave rates: (collateral * s - debt * r) / equity, 1e18 scale */
  netRate: bigint | null
  /** Years until the health factor drifts to the trip threshold at current rates; an estimate, null when not drifting */
  yearsToTrip: number | null
  config: ReturnType<typeof readConfiguration>
  /** Room left under Aave's caps, in WETH (null without a cap) */
  borrowCapRoom: bigint | null
  supplyCapRoom: bigint | null
  aaveLiquidity: bigint
  /** Largest deposit whose loop fits the caps and the PoolManager's WETH now */
  depositRoom: bigint
  shock: ShockView
  account: AccountView | null
}

export function buildState(st: StaticData, live: LiveData): State {
  return {
    reserve: live.reserve,
    price: live.price,
    flashLiquidity: live.flashLiquidity,
    strategy: {
      aScaled: live.strategy.aScaled,
      debtScaled: live.strategy.debtScaled,
      idle: live.strategy.idle,
      totalSupply: live.strategy.totalSupply,
      emergency: live.strategy.emergency,
      params: {
        targetLeverage: live.strategy.targetLeverage,
        minHealthFactor: live.strategy.minHealthFactor,
        targetHealthFactor: live.strategy.targetHealthFactor,
        minRemainingEquity: st.minRemainingEquity,
        minInvestAssets: st.minInvestAssets,
        marginBps: st.marginBps,
        eModeLtv: live.eModeLtv,
        eModeLiquidationThreshold: live.eModeLiquidationThreshold,
      },
    },
    vault: {
      totalSupply: live.vault.totalSupply,
      idle: live.vault.idle,
      strategyShares: live.vault.strategyShares,
      highWaterMark: live.vault.highWaterMark,
      feeBps: live.vault.feeBps,
      feeRecipientSet: live.vault.feeRecipient !== zeroAddress,
      emergency: live.vault.emergency,
    },
  }
}

/** HF(t) ~ HF0 * exp(-(r - s) * t), from Guide 2: an estimate for display, not contract math. */
function estimateYearsToTrip(hf: bigint, minHf: bigint, supplyRate: bigint, borrowRate: bigint): number | null {
  if (hf === MAX_UINT256 || hf <= minHf || borrowRate <= supplyRate) return null
  const spread = Number(borrowRate - supplyRate) / Number(RAY)
  return Math.log(Number(hf) / Number(minHf)) / spread
}

export function buildModel(
  d: Deployment,
  st: StaticData,
  live: LiveData,
  account: AccountData | undefined,
  now: bigint,
  chainTime: bigint,
  chainKnown = true,
): VaultModel {
  const state = buildState(st, live)
  const pos = position(state, now)
  const posAtChain = position(state, chainTime)
  const equity = strategyTotalAssets(pos)
  const r = live.reserve
  const config = readConfiguration(r.configuration)
  const unit = 10n ** config.decimals

  const totalDebt = debtBalance(r.scaledDebtSupply, normalizedDebt(r, chainTime))
  const totalSupplied = aTokenBalance(r.scaledATokenSupply + r.accruedToTreasury, normalizedIncome(r, chainTime))
  const room = (cap: bigint, used: bigint) => (cap === 0n ? null : cap * unit > used ? cap * unit - used : 0n)

  const supplyRate = r.currentLiquidityRate
  const borrowRate = r.currentVariableBorrowRate
  const netRate = equity > 0n ? (pos.collateral * supplyRate - pos.debt * borrowRate) / equity / 10n ** 9n : null

  const ownsRoles = live.vault.admin === d.operator && live.vault.owner === d.operator
  const shocked =
    live.strategy.minHealthFactor !== st.defaultMinHealthFactor || live.strategy.targetHealthFactor !== st.defaultTargetHealthFactor

  let accountView: AccountView | null = null
  if (account) {
    accountView = {
      shares: account.shares,
      assets: vaultToAssets(state, account.shares, now, 'floor'),
      assetsAtChain: vaultToAssets(state, account.shares, chainTime, 'floor'),
      maxWithdraw: maxWithdraw(state, account.shares, chainTime),
      maxRedeem: maxRedeem(state, account.shares, chainTime),
      maxDeposit: maxDeposit(state, account.whitelisted, chainTime),
      data: account,
    }
  }

  return {
    deployment: d,
    static: st,
    live,
    state,
    now,
    chainTime,
    chainKnown,
    position: pos,
    positionAtChain: posAtChain,
    strategyEquity: equity,
    vaultAssets: vaultTotalAssets(state, now),
    fee: pendingFee(state, now),
    supplyRate,
    borrowRate,
    netRate,
    yearsToTrip: estimateYearsToTrip(pos.healthFactor, live.strategy.minHealthFactor, supplyRate, borrowRate),
    config,
    borrowCapRoom: room(config.borrowCap, totalDebt),
    supplyCapRoom: room(config.supplyCap, totalSupplied),
    aaveLiquidity: config.paused ? 0n : r.virtualBalance,
    depositRoom: depositRoom(state, chainTime),
    shock: {
      ownsRoles,
      lastShockAt: live.lastShockAt,
      nextShockAt: live.lastShockAt === 0n ? 0n : live.lastShockAt + st.shockCooldown,
      shocked,
    },
    account: accountView,
  }
}

/**
 * The two timestamps the model uses: the visitor's clock for balances that tick, and the latest block's timestamp for
 * limits and previews. Neither goes behind Aave's last update.
 */
export function pickTimes(now: bigint, chainTime: bigint | undefined, lastUpdate: bigint): { now: bigint; chainTime: bigint; chainKnown: boolean } {
  return {
    now: now > lastUpdate ? now : lastUpdate,
    // Until the latest block arrives, the visitor's clock: Aave's last update can be hours old
    chainTime: (chainTime ?? now) > lastUpdate ? (chainTime ?? now) : lastUpdate,
    chainKnown: chainTime !== undefined,
  }
}

/** Ray rate to a 1e18 fraction, for formatPct. */
export const rateToWad = (rate: bigint) => (rate * WAD) / RAY
