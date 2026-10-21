// Vault and strategy math, mirrored from src/base/BaseVault.sol, src/base/BaseStrategy.sol and
// src/strategies/WETHLoopStrategy.sol (with OpenZeppelin's ERC4626 underneath), so the app can preview each call
// before sending it. Rounding follows the contracts: conversions take the direction each ERC-4626 function uses, the
// pending performance fee counts in every conversion, and the position moves through Aave's own scaled-balance math
// (./aave.ts). Simulations return the state the call leaves, at the timestamp it runs.

import {
  aTokenBalance,
  aTokenBurnScaled,
  aTokenMintScaled,
  debtBalance,
  debtBurnScaled,
  debtMintScaled,
  fitsBorrowCap,
  fitsSupplyCap,
  healthFactor,
  MAX_UINT256,
  normalizedDebt,
  normalizedIncome,
  readConfiguration,
  updatedReserve,
  WAD,
  type Reserve,
} from './aave'

export const MAX_BPS = 10_000n
/** BaseStrategy.DECIMALS_OFFSET is 6, so strategy conversions add 10**6 virtual shares. */
const STRATEGY_VIRTUAL_SHARES = 10n ** 6n
/** BaseVault has no decimals offset: one virtual share. */
const VAULT_VIRTUAL_SHARES = 1n
/** WETHLoopStrategy.HEALTH_FACTOR_FLOOR */
export const HEALTH_FACTOR_FLOOR = WAD

export type Rounding = 'floor' | 'ceil'

/** OpenZeppelin Math.mulDiv for non-negative operands. */
export function mulDiv(a: bigint, b: bigint, d: bigint, rounding: Rounding = 'floor'): bigint {
  const p = a * b
  const q = p / d
  return rounding === 'ceil' && q * d !== p ? q + 1n : q
}

/* ------------------------------------------------------------------ */
/* State                                                               */
/* ------------------------------------------------------------------ */

/** Strategy parameters: constants and the admin-set values, read from the chain. */
export interface StrategyParams {
  targetLeverage: bigint
  minHealthFactor: bigint
  targetHealthFactor: bigint
  /** MIN_REMAINING_EQUITY: a withdrawal leaving less equity closes the whole position */
  minRemainingEquity: bigint
  /** MIN_INVEST_ASSETS: smaller amounts stay idle */
  minInvestAssets: bigint
  /** HEALTH_FACTOR_MARGIN_BPS, applied by maxDeposit() */
  marginBps: bigint
  /** E-Mode category LTV and liquidation threshold, in bps */
  eModeLtv: bigint
  eModeLiquidationThreshold: bigint
}

export interface StrategyState {
  /** aToken.scaledBalanceOf(strategy) */
  aScaled: bigint
  /** variableDebtToken.scaledBalanceOf(strategy) */
  debtScaled: bigint
  /** WETH held by the strategy itself */
  idle: bigint
  totalSupply: bigint
  emergency: boolean
  params: StrategyParams
}

export interface VaultState {
  totalSupply: bigint
  /** WETH held by the vault itself */
  idle: bigint
  /** strategy.balanceOf(vault) */
  strategyShares: bigint
  highWaterMark: bigint
  feeBps: bigint
  /** feeRecipient != address(0) */
  feeRecipientSet: boolean
  emergency: boolean
}

export interface State {
  reserve: Reserve
  /** Aave oracle price of WETH, base currency (8 decimals) */
  price: bigint
  /** WETH held by the Uniswap V4 PoolManager: what one flash loan can take */
  flashLiquidity: bigint
  strategy: StrategyState
  vault: VaultState
}

/* ------------------------------------------------------------------ */
/* Position                                                            */
/* ------------------------------------------------------------------ */

export interface Position {
  collateral: bigint
  debt: bigint
  idle: bigint
  /** Aave's health factor; type(uint256).max without debt */
  healthFactor: bigint
}

/** The strategy's position at `now`, as aToken.balanceOf, debtToken.balanceOf and getUserAccountData report it. */
export function position(s: State, now: bigint): Position {
  const collateral = aTokenBalance(s.strategy.aScaled, normalizedIncome(s.reserve, now))
  const debt = debtBalance(s.strategy.debtScaled, normalizedDebt(s.reserve, now))
  // Collateral counts while the scaled balance is non-zero (Aave clears the collateral flag on a zero balance)
  const counted = s.strategy.aScaled > 0n ? collateral : 0n
  return {
    collateral,
    debt,
    idle: s.strategy.idle,
    healthFactor: healthFactor(counted, debt, s.price, s.strategy.params.eModeLiquidationThreshold),
  }
}

/** WETHLoopStrategy.totalAssets(): collateral + idle - debt, 0 when underwater. No flash loan is open outside a call. */
export function strategyTotalAssets(p: Position): bigint {
  const assets = p.collateral + p.idle
  return assets > p.debt ? assets - p.debt : 0n
}

export function strategyToAssets(s: State, shares: bigint, now: bigint, rounding: Rounding): bigint {
  return mulDiv(shares, strategyTotalAssets(position(s, now)) + 1n, s.strategy.totalSupply + STRATEGY_VIRTUAL_SHARES, rounding)
}

export function strategyToShares(s: State, assets: bigint, now: bigint, rounding: Rounding): bigint {
  return mulDiv(assets, s.strategy.totalSupply + STRATEGY_VIRTUAL_SHARES, strategyTotalAssets(position(s, now)) + 1n, rounding)
}

/* ------------------------------------------------------------------ */
/* Vault conversions                                                   */
/* ------------------------------------------------------------------ */

/** BaseVault.totalAssets(): idle WETH plus the strategy shares at the strategy's convertToAssets (floor). */
export function vaultTotalAssets(s: State, now: bigint): bigint {
  return s.vault.idle + strategyToAssets(s, s.vault.strategyShares, now, 'floor')
}

export interface PendingFee {
  feeShares: bigint
  currentAssets: bigint
  profit: bigint
}

/** BaseVault._pendingFee(): what the next fee assessment would mint and record. */
export function pendingFee(s: State, now: bigint): PendingFee {
  const v = s.vault
  if (v.feeBps === 0n || !v.feeRecipientSet) return { feeShares: 0n, currentAssets: 0n, profit: 0n }
  const currentAssets = vaultTotalAssets(s, now)
  if (currentAssets <= v.highWaterMark) return { feeShares: 0n, currentAssets, profit: 0n }
  const profit = currentAssets - v.highWaterMark
  const feeInAssets = (profit * v.feeBps) / MAX_BPS
  const feeShares = feeInAssets > 0n ? mulDiv(feeInAssets, v.totalSupply + 1n, currentAssets - feeInAssets + 1n) : 0n
  return { feeShares, currentAssets, profit }
}

/** BaseVault._convertToShares, counting the pending fee shares. */
export function vaultToShares(s: State, assets: bigint, now: bigint, rounding: Rounding): bigint {
  const { feeShares } = pendingFee(s, now)
  return mulDiv(assets, s.vault.totalSupply + feeShares + VAULT_VIRTUAL_SHARES, vaultTotalAssets(s, now) + 1n, rounding)
}

/** BaseVault._convertToAssets, counting the pending fee shares. */
export function vaultToAssets(s: State, shares: bigint, now: bigint, rounding: Rounding): bigint {
  const { feeShares } = pendingFee(s, now)
  return mulDiv(shares, vaultTotalAssets(s, now) + 1n, s.vault.totalSupply + feeShares + VAULT_VIRTUAL_SHARES, rounding)
}

export const previewDeposit = (s: State, assets: bigint, now: bigint) => vaultToShares(s, assets, now, 'floor')
export const previewMint = (s: State, shares: bigint, now: bigint) => vaultToAssets(s, shares, now, 'ceil')
export const previewWithdraw = (s: State, assets: bigint, now: bigint) => vaultToShares(s, assets, now, 'ceil')
export const previewRedeem = (s: State, shares: bigint, now: bigint) => vaultToAssets(s, shares, now, 'floor')

/* ------------------------------------------------------------------ */
/* Limits                                                              */
/* ------------------------------------------------------------------ */

/** Aave's paused flag zeroes what the reserve can pay out (AaveAdapter.withdrawableLiquidity). */
export function aaveLiquidity(s: State): bigint {
  return readConfiguration(s.reserve.configuration).paused ? 0n : s.reserve.virtualBalance
}

/** WETHLoopStrategy._withdrawableAssets(): idle WETH plus the most _divest() can take from the position now. */
export function strategyWithdrawable(s: State, now: bigint): bigint {
  const p = position(s, now)
  const params = s.strategy.params
  if (p.collateral === 0n) return p.idle
  const liquidity = aaveLiquidity(s)
  if (p.debt === 0n) return p.idle + min(p.collateral, liquidity)
  if (p.collateral <= p.debt) return p.idle
  if (p.healthFactor < HEALTH_FACTOR_FLOOR) return p.idle
  const equity = p.collateral - p.debt
  if (p.debt <= s.flashLiquidity && equity <= liquidity) return p.idle + equity
  if (equity <= params.minRemainingEquity) return p.idle
  const partial = min(equity - params.minRemainingEquity, (s.flashLiquidity * equity) / p.debt)
  return p.idle + min(partial, liquidity)
}

/** BaseStrategy.maxWithdraw(vault). */
export function strategyMaxWithdraw(s: State, now: bigint): bigint {
  return min(strategyToAssets(s, s.vault.strategyShares, now, 'floor'), strategyWithdrawable(s, now))
}

/** BaseVault._withdrawableAssets(): vault idle plus the strategy's maxWithdraw for the vault. */
export function vaultWithdrawable(s: State, now: bigint): bigint {
  return s.vault.idle + strategyMaxWithdraw(s, now)
}

/** BaseVault.maxWithdraw(owner). */
export function maxWithdraw(s: State, ownerShares: bigint, now: bigint): bigint {
  return min(vaultToAssets(s, ownerShares, now, 'floor'), vaultWithdrawable(s, now))
}

/** BaseVault.maxRedeem(owner). */
export function maxRedeem(s: State, ownerShares: bigint, now: bigint): bigint {
  const withdrawable = vaultWithdrawable(s, now)
  if (vaultToAssets(s, ownerShares, now, 'floor') <= withdrawable) return ownerShares
  return vaultToShares(s, withdrawable, now, 'floor')
}

const applyMargin = (hf: bigint, marginBps: bigint) => (hf * (MAX_BPS - marginBps)) / MAX_BPS

/** Health factor of a slice invested at target leverage: L * LT / (L - 1), LT in bps scaled to 1e18. */
export function impliedHealthFactor(params: StrategyParams): bigint {
  const l = params.targetLeverage
  return (l * params.eModeLiquidationThreshold * 10n ** 14n) / (l - 1n)
}

/** WETHLoopStrategy._investmentKeepsMinimum(). */
export function investmentKeepsMinimum(s: State, now: bigint): boolean {
  const params = s.strategy.params
  if (s.strategy.debtScaled > 0n && applyMargin(position(s, now).healthFactor, params.marginBps) < params.minHealthFactor) return false
  return applyMargin(impliedHealthFactor(params), params.marginBps) >= params.minHealthFactor
}

/** BaseVault.maxDeposit(receiver): 0 or type(uint256).max. */
export function maxDeposit(s: State, receiverWhitelisted: boolean, now: bigint): bigint {
  if (s.vault.emergency || !receiverWhitelisted) return 0n
  if (s.strategy.emergency || !investmentKeepsMinimum(s, now)) return 0n
  return MAX_UINT256
}

/**
 * Why maxDeposit() reports 0, for the message the app shows. 'margin' is the band within HEALTH_FACTOR_MARGIN_BPS above
 * the trip threshold: deposits are closed there although checkHealth() does not trip yet. 'slice' is a position that a
 * slice at target leverage could not keep above the threshold.
 */
export type DepositClosed = 'emergency' | 'whitelist' | 'strategy' | 'belowTrip' | 'margin' | 'slice'

export function depositClosedReason(s: State, receiverWhitelisted: boolean, now: bigint): DepositClosed | null {
  if (maxDeposit(s, receiverWhitelisted, now) > 0n) return null
  if (s.vault.emergency) return 'emergency'
  if (!receiverWhitelisted) return 'whitelist'
  if (s.strategy.emergency) return 'strategy'
  const params = s.strategy.params
  if (s.strategy.debtScaled > 0n) {
    const hf = position(s, now).healthFactor
    if (hf < params.minHealthFactor) return 'belowTrip'
    if (applyMargin(hf, params.marginBps) < params.minHealthFactor) return 'margin'
  }
  return 'slice'
}

/**
 * Largest deposit whose loop fits Aave's supply and borrow caps and the PoolManager's WETH at `now`. Not a contract
 * limit (maxDeposit() does not model caps or flash liquidity): the app uses it to warn before a deposit would revert
 * inside Aave or Uniswap.
 */
export function depositRoom(s: State, now: bigint): bigint {
  const l = s.strategy.params.targetLeverage
  const fits = (x: bigint) =>
    x * (l - 1n) <= s.flashLiquidity && fitsSupplyCap(s.reserve, x * l, now) && fitsBorrowCap(s.reserve, x * (l - 1n), now)
  let lo = 0n
  let hi = s.flashLiquidity / (l - 1n) + 1n
  if (fits(hi)) return hi
  while (hi - lo > 1n) {
    const mid = (lo + hi) / 2n
    if (fits(mid)) lo = mid
    else hi = mid
  }
  return lo
}

/* ------------------------------------------------------------------ */
/* Simulations                                                         */
/* ------------------------------------------------------------------ */

/** Why a simulated call would revert, named after the contract error it would raise. */
export class SimulatedRevert extends Error {
  constructor(
    readonly errorName: string,
    readonly args: readonly bigint[] = [],
  ) {
    super(errorName)
  }
}

const clone = (s: State): State => ({ ...s, reserve: { ...s.reserve }, strategy: { ...s.strategy }, vault: { ...s.vault } })

/** BaseVault._assessPerformanceFee() at `now`: mints the fee shares and raises the mark when there is profit. */
function assessFee(s: State, now: bigint): State {
  const fee = pendingFee(s, now)
  if (fee.profit === 0n) return s
  const next = clone(s)
  next.vault.totalSupply += fee.feeShares
  next.vault.highWaterMark = fee.currentAssets
  return next
}

/** Aave reserve after updateState at `now`, with the scaled supplies moved by a call. */
function touchReserve(s: State, now: bigint, aDelta: bigint, debtDelta: bigint): Reserve {
  const r = updatedReserve(s.reserve, now)
  return { ...r, scaledATokenSupply: r.scaledATokenSupply + aDelta, scaledDebtSupply: r.scaledDebtSupply + debtDelta }
}

/** ValidationLogic.validateSupply and validateBorrow: the reserve flags, in Aave's order. */
function assertInvestable(s: State) {
  const c = readConfiguration(s.reserve.configuration)
  if (!c.active) throw new SimulatedRevert('ReserveInactive')
  if (c.paused) throw new SimulatedRevert('ReservePaused')
  if (c.frozen) throw new SimulatedRevert('ReserveFrozen')
  if (!c.borrowingEnabled) throw new SimulatedRevert('BorrowingNotEnabled')
}

/** ValidationLogic.validateWithdraw and validateRepay: a frozen reserve still lets both through, a paused one does not. */
function assertWithdrawable(s: State) {
  const c = readConfiguration(s.reserve.configuration)
  if (!c.active) throw new SimulatedRevert('ReserveInactive')
  if (c.paused) throw new SimulatedRevert('ReservePaused')
}

/** WETHLoopStrategy._invest(assets), the assets already in the strategy's idle balance. */
function invest(s: State, assets: bigint, now: bigint): State {
  const params = s.strategy.params
  if (assets < params.minInvestAssets) return s
  assertInvestable(s)
  const l = params.targetLeverage
  const flash = assets * (l - 1n)
  const supply = assets * l
  if (flash > s.flashLiquidity) throw new SimulatedRevert('FlashLiquidity', [flash, s.flashLiquidity])
  if (!fitsSupplyCap(s.reserve, supply, now)) throw new SimulatedRevert('SupplyCapExceeded')
  if (!fitsBorrowCap(s.reserve, flash, now)) throw new SimulatedRevert('BorrowCapExceeded')
  const u = updatedReserve(s.reserve, now)
  const aMinted = aTokenMintScaled(supply, u.liquidityIndex)
  const debtMinted = debtMintScaled(flash, u.variableBorrowIndex)
  const next = clone(s)
  next.reserve = touchReserve(s, now, aMinted, debtMinted)
  next.reserve.virtualBalance = s.reserve.virtualBalance + supply - flash
  next.strategy.aScaled += aMinted
  next.strategy.debtScaled += debtMinted
  next.strategy.idle -= assets
  const hf = position(next, now).healthFactor
  if (hf < params.minHealthFactor) throw new SimulatedRevert('HealthFactorBelowMinimum', [hf, params.minHealthFactor])
  return next
}

export interface DepositResult {
  state: State
  shares: bigint
  strategyShares: bigint
  /** The deposit was looped, not left idle */
  invested: boolean
}

/** vault.deposit(assets, receiver) at `now`. Throws SimulatedRevert where the contracts would revert. */
export function simulateDeposit(s0: State, assets: bigint, receiverWhitelisted: boolean, now: bigint): DepositResult {
  if (s0.vault.emergency) throw new SimulatedRevert('VaultInEmergency')
  if (!receiverWhitelisted) throw new SimulatedRevert('NotWhitelisted')
  let s = assessFee(s0, now)
  const shares = previewDeposit(s, assets, now)
  if (s.strategy.emergency) throw new SimulatedRevert('StrategyInEmergency')
  const strategyShares = strategyToShares(s, assets, now, 'floor')
  s = clone(s)
  s.vault.totalSupply += shares
  s.vault.highWaterMark += assets
  s.vault.strategyShares += strategyShares
  s.strategy.totalSupply += strategyShares
  s.strategy.idle += assets
  const before = s.strategy.idle
  s = invest(s, assets, now)
  return { state: s, shares, strategyShares, invested: s.strategy.idle !== before }
}

export interface DivestResult {
  state: State
  debtRepaid: bigint
  collateralWithdrawn: bigint
  flashLoan: bigint
  /** The remaining equity was below MIN_REMAINING_EQUITY, so the whole position closed */
  fullClose: boolean
}

/** WETHLoopStrategy._divest(assets): pays from idle WETH first, then deleverages proportionally. */
function divest(s: State, assets: bigint, now: bigint): DivestResult {
  const none = { state: s, debtRepaid: 0n, collateralWithdrawn: 0n, flashLoan: 0n, fullClose: false }
  if (s.strategy.idle >= assets) return none
  const needed = assets - s.strategy.idle
  const p = position(s, now)
  if (p.collateral === 0n) return none
  assertWithdrawable(s)
  const u = updatedReserve(s.reserve, now)
  const next = clone(s)
  if (p.debt === 0n) {
    const burned = aTokenBurnScaled(needed, u.liquidityIndex)
    if (burned > s.strategy.aScaled) throw new SimulatedRevert('NotEnoughAvailableUserBalance')
    if (needed > aaveLiquidity(s)) throw new SimulatedRevert('AaveLiquidity', [needed, aaveLiquidity(s)])
    next.reserve = touchReserve(s, now, -burned, 0n)
    next.reserve.virtualBalance -= needed
    next.strategy.aScaled -= burned
    next.strategy.idle += needed
    return { ...none, state: next, collateralWithdrawn: needed }
  }
  if (p.collateral <= p.debt) throw new SimulatedRevert('InsufficientEquity')
  const equity = p.collateral - p.debt
  if (needed > equity) throw new SimulatedRevert('WithdrawExceedsEquity', [needed, equity])
  const fullClose = equity - needed < s.strategy.params.minRemainingEquity
  const debtRepaid = fullClose ? p.debt : mulDiv(p.debt, needed, equity, 'ceil')
  const collateralWithdrawn = fullClose ? p.collateral : debtRepaid + needed
  return closeSlice(s, next, u, debtRepaid, collateralWithdrawn, fullClose, now)
}

/** Flash loan of `debtRepaid`, Aave repay, Aave withdraw of `collateralWithdrawn`, flash repayment. */
function closeSlice(s: State, next: State, u: Reserve, debtRepaid: bigint, collateralWithdrawn: bigint, fullClose: boolean, now: bigint): DivestResult {
  if (debtRepaid > s.flashLiquidity) throw new SimulatedRevert('FlashLiquidity', [debtRepaid, s.flashLiquidity])
  const debtBurned = debtBurnScaled(debtRepaid, u.variableBorrowIndex)
  const aBurned = aTokenBurnScaled(collateralWithdrawn, u.liquidityIndex)
  if (aBurned > s.strategy.aScaled) throw new SimulatedRevert('NotEnoughAvailableUserBalance')
  // Aave's virtual balance underflows (a panic) when the reserve cannot pay out the withdrawal
  if (collateralWithdrawn > aaveLiquidity(s) + debtRepaid) throw new SimulatedRevert('AaveLiquidity', [collateralWithdrawn, aaveLiquidity(s) + debtRepaid])
  next.reserve = touchReserve(s, now, -aBurned, -debtBurned)
  next.reserve.virtualBalance = s.reserve.virtualBalance + debtRepaid - collateralWithdrawn
  next.strategy.debtScaled -= debtBurned
  next.strategy.aScaled -= aBurned
  next.strategy.idle += collateralWithdrawn - debtRepaid
  const p = position(next, now)
  if (p.debt > 0n && p.healthFactor < HEALTH_FACTOR_FLOOR) throw new SimulatedRevert('HealthFactorLowerThanLiquidationThreshold')
  return { state: next, debtRepaid, collateralWithdrawn, flashLoan: debtRepaid, fullClose }
}

export interface WithdrawResult extends Omit<DivestResult, 'state'> {
  state: State
  assets: bigint
  shares: bigint
  /** The part the strategy paid; the rest came from the vault's idle WETH */
  fromStrategy: bigint
}

/** The vault's _withdraw(): idle WETH first, the shortfall from the strategy. */
function vaultWithdraw(s: State, assets: bigint, shares: bigint, now: bigint): WithdrawResult {
  let next = clone(s)
  let divested: Omit<DivestResult, 'state'> = { debtRepaid: 0n, collateralWithdrawn: 0n, flashLoan: 0n, fullClose: false }
  let fromStrategy = 0n
  if (s.vault.idle < assets) {
    fromStrategy = assets - s.vault.idle
    const owned = strategyToAssets(s, s.vault.strategyShares, now, 'floor')
    if (fromStrategy > owned) throw new SimulatedRevert('ERC4626ExceededMaxWithdraw', [fromStrategy, owned])
    const burned = strategyToShares(s, fromStrategy, now, 'ceil')
    const d = divest(next, fromStrategy, now)
    next = clone(d.state)
    if (next.strategy.idle < fromStrategy) throw new SimulatedRevert('ERC20InsufficientBalance')
    next.strategy.idle -= fromStrategy
    next.strategy.totalSupply -= burned
    next.vault.strategyShares -= burned
    next.vault.idle += fromStrategy
    const { state: _ignored, ...rest } = d
    divested = rest
  }
  next.vault.idle -= assets
  next.vault.totalSupply -= shares
  next.vault.highWaterMark = assets > next.vault.highWaterMark ? 0n : next.vault.highWaterMark - assets
  return { ...divested, state: next, assets, shares, fromStrategy }
}

/** vault.withdraw(assets, receiver, owner) at `now`. */
export function simulateWithdraw(s0: State, assets: bigint, ownerShares: bigint, now: bigint): WithdrawResult {
  const s = assessFee(s0, now)
  const ownerAssets = vaultToAssets(s, ownerShares, now, 'floor')
  if (assets > ownerAssets) throw new SimulatedRevert('ERC4626ExceededMaxWithdraw', [assets, ownerAssets])
  return vaultWithdraw(s, assets, previewWithdraw(s, assets, now), now)
}

/** vault.redeem(shares, receiver, owner) at `now`. */
export function simulateRedeem(s0: State, shares: bigint, ownerShares: bigint, now: bigint): WithdrawResult {
  const s = assessFee(s0, now)
  if (shares > ownerShares) throw new SimulatedRevert('ERC4626ExceededMaxRedeem', [shares, ownerShares])
  return vaultWithdraw(s, previewRedeem(s, shares, now), shares, now)
}

/** WETHLoopStrategy._exitPosition(): repays the whole debt with a flash loan and withdraws all collateral. */
export function simulateExit(s: State, now: bigint): DivestResult {
  const p = position(s, now)
  const none = { state: s, debtRepaid: 0n, collateralWithdrawn: 0n, flashLoan: 0n, fullClose: true }
  if (p.collateral === 0n) return none
  assertWithdrawable(s)
  const u = updatedReserve(s.reserve, now)
  const next = clone(s)
  if (p.debt === 0n) {
    const burned = aTokenBurnScaled(p.collateral, u.liquidityIndex)
    next.reserve = touchReserve(s, now, -burned, 0n)
    next.reserve.virtualBalance -= p.collateral
    next.strategy.aScaled -= burned
    next.strategy.idle += p.collateral
    return { ...none, state: next, collateralWithdrawn: p.collateral }
  }
  return closeSlice(s, next, u, p.debt, p.collateral, true, now)
}

export interface ReinvestResult {
  state: State
  /** WETH looped: the vault's idle balance plus the strategy's */
  invested: bigint
}

/** vault.reinvest(): the vault's idle WETH into the strategy, then the strategy's whole idle balance at target leverage. */
export function simulateReinvest(s0: State, now: bigint): ReinvestResult {
  if (s0.vault.emergency) throw new SimulatedRevert('VaultInEmergency')
  let s = clone(s0)
  const fromVault = s.vault.idle
  if (fromVault > 0n) {
    if (s.strategy.emergency) throw new SimulatedRevert('StrategyInEmergency')
    const minted = strategyToShares(s, fromVault, now, 'floor')
    s.vault.idle = 0n
    s.vault.strategyShares += minted
    s.strategy.totalSupply += minted
    s.strategy.idle += fromVault
    s = invest(s, fromVault, now)
  }
  if (s.strategy.emergency) throw new SimulatedRevert('StrategyInEmergency')
  const idle = s.strategy.idle
  if (idle > 0n) s = invest(s, idle, now)
  const hf = position(s, now).healthFactor
  if (hf < s.strategy.params.targetHealthFactor) throw new SimulatedRevert('HealthFactorBelowTarget', [hf, s.strategy.params.targetHealthFactor])
  // Whatever left the two idle balances went into Aave (a vault slice below MIN_INVEST_ASSETS is counted once)
  return { state: s, invested: s0.strategy.idle + fromVault - s.strategy.idle }
}

function min(a: bigint, b: bigint): bigint {
  return a < b ? a : b
}
