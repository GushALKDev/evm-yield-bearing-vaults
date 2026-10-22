import { WAD } from './aave'
import type { Position } from './vault'

/* ------------------------------------------------------------------ */
/* Transaction flows                                                   */
/* ------------------------------------------------------------------ */

export type Asset = 'ETH' | 'WETH'

export type StepKind = 'join' | 'wrap' | 'approve' | 'deposit' | 'withdraw' | 'redeem' | 'unwrap'

/** One transaction of a flow; `done` steps are already satisfied and send nothing. */
export interface FlowStep {
  kind: StepKind
  done: boolean
}

/**
 * The transactions a deposit takes, in order: join the whitelist, wrap Ether when paying with it, approve the vault for
 * the amount, deposit. Join and approve are shown as done when already satisfied, so the flow still explains them.
 */
export function depositSteps(o: { payWith: Asset; whitelisted: boolean; allowance: bigint; amount: bigint }): FlowStep[] {
  return [
    { kind: 'join', done: o.whitelisted },
    ...(o.payWith === 'ETH' ? [{ kind: 'wrap' as const, done: false }] : []),
    { kind: 'approve', done: o.allowance >= o.amount && o.amount > 0n },
    { kind: 'deposit', done: false },
  ]
}

/** The transactions a withdrawal takes: withdraw an amount or redeem every share, then unwrap when paid out in Ether. */
export function withdrawSteps(o: { redeemAll: boolean; receive: Asset }): FlowStep[] {
  return [{ kind: o.redeemAll ? 'redeem' : 'withdraw', done: false }, ...(o.receive === 'ETH' ? [{ kind: 'unwrap' as const, done: false }] : [])]
}

/* ------------------------------------------------------------------ */
/* Yield                                                               */
/* ------------------------------------------------------------------ */

export interface YieldBreakdown {
  /** Collateral and debt per unit of equity, 1e18 scale */
  collateralMultiple: bigint
  debtMultiple: bigint
  /** A year on equity at today's rates, 1e18 scale: what the collateral earns, what the debt costs, and the net */
  earn: bigint
  cost: bigint
  net: bigint
}

/**
 * What the loop earns and pays per unit of equity, at Aave's current rates (ray, 1e27). Null without debt or equity:
 * there is no loop to explain.
 */
export function yieldBreakdown(p: Position, equity: bigint, supplyRate: bigint, borrowRate: bigint): YieldBreakdown | null {
  if (equity <= 0n || p.debt === 0n) return null
  // ray rate times a WETH ratio, down to 1e18
  const earn = (p.collateral * supplyRate) / equity / 10n ** 9n
  const cost = (p.debt * borrowRate) / equity / 10n ** 9n
  return { collateralMultiple: (p.collateral * WAD) / equity, debtMultiple: (p.debt * WAD) / equity, earn, cost, net: earn - cost }
}

/** A value a year from now if the net rate held, without compounding: an estimate for display. */
export function projectYear(value: bigint, netRate: bigint): bigint {
  const projected = value + (value * netRate) / WAD
  return projected > 0n ? projected : 0n
}
