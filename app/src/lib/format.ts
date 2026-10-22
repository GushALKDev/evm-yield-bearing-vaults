import { MAX_UINT256, WAD } from './aave'

const groupInt = (s: string) => s.replace(/\B(?=(\d{3})+(?!\d))/g, ',')

/**
 * Formats a fixed-point bigint. Truncates toward zero, so a balance is never shown higher than it is.
 * `shown` is the number of decimals displayed; trailing zeros are kept for column alignment.
 */
export function formatFixed(value: bigint, decimals: number, shown: number): string {
  const negative = value < 0n
  const abs = negative ? -value : value
  const scale = 10n ** BigInt(decimals)
  const int = abs / scale
  let out = groupInt(int.toString())
  if (shown > 0) {
    const frac = (abs % scale).toString().padStart(decimals, '0').slice(0, shown).padEnd(shown, '0')
    out += `.${frac}`
  }
  return negative ? `-${out}` : out
}

/** WETH amount (18 decimals). */
export const formatWeth = (value: bigint, shown = 4) => formatFixed(value, 18, shown)

/** USD value from Aave's base currency (8 decimals). */
export const formatBaseUsd = (value: bigint, shown = 2) => `$${formatFixed(value, 8, shown)}`

/** Health factor at 1e18 scale; no debt is reported by Aave as type(uint256).max. */
export function formatHealth(hf: bigint, shown = 4): string {
  if (hf === MAX_UINT256) return 'No debt'
  return formatFixed(hf, 18, shown)
}

/** Fraction at 1e18 scale as a percentage. */
export function formatPct(value18: bigint, shown = 2): string {
  return `${formatFixed(value18 * 100n, 18, shown)}%`
}

/** Leverage, collateral over equity, as a multiple with two decimals. */
export function formatLeverage(collateral: bigint, equity: bigint): string {
  if (equity <= 0n) return 'n/a'
  return `${formatFixed((collateral * WAD) / equity, 18, 2)}x`
}

/** A multiple at 1e18 scale with up to two decimals and no trailing zeros: 10, 9.5, 9.99. */
export function formatMultiple(value18: bigint): string {
  return formatFixed(value18, 18, 2).replace(/\.?0+$/, '')
}

/** Basis points as a percentage: 8000 -> 80%. */
export function formatBps(bps: bigint): string {
  const whole = bps / 100n
  const frac = bps % 100n
  return frac === 0n ? `${whole}%` : `${whole}.${frac.toString().padStart(2, '0').replace(/0$/, '')}%`
}

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

/** Parses a user-typed decimal amount into base units; null if it is not a valid number. */
export function parseAmount(input: string, decimals: number): bigint | null {
  const s = input.trim().replace(/,/g, '')
  if (!/^\d*\.?\d*$/.test(s) || s === '' || s === '.') return null
  const [int, frac = ''] = s.split('.')
  if (frac.length > decimals) return null
  return BigInt(int || '0') * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, '0') || '0')
}

/** Inverse of parseAmount for Max buttons: no grouping, trailing zeros trimmed. */
export function toInput(value: bigint, decimals: number): string {
  const scale = 10n ** BigInt(decimals)
  const frac = (value % scale).toString().padStart(decimals, '0').replace(/0+$/, '')
  return frac ? `${value / scale}.${frac}` : `${value / scale}`
}

export function relativeTime(seconds: number): string {
  if (seconds < 60) return `${Math.max(0, Math.round(seconds))} s`
  if (seconds < 3600) return `${Math.round(seconds / 60)} min`
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)} h ${Math.round((seconds % 3600) / 60)} min`
  return `${Math.round(seconds / 86_400)} days`
}

/** A WETH gap for prose, with a floor so a gap under the shown precision does not read as zero. */
export const formatGap = (x: bigint) => (x > 0n && x < 10n ** 12n ? 'less than 0.000001' : formatWeth(x, 6))
