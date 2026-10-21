// Aave V3.6 math, mirrored from aave-v3-origin tag v3.6.0 (the release on Base Sepolia: Pool revision 10, aToken and
// debt token revision 5) so the app can project balances to the second and preview what a call does to the
// strategy's position. Every function keeps Aave's rounding: aToken balances round down, debt rounds up, and the
// health factor values collateral down and debt up. All values are bigint at Aave's own scales.

export const WAD = 10n ** 18n
export const RAY = 10n ** 27n
const HALF_RAY = RAY / 2n
export const PERCENTAGE_FACTOR = 10_000n
/** MathUtils.SECONDS_PER_YEAR: 365 days */
export const SECONDS_PER_YEAR = 31_536_000n
export const MAX_UINT256 = 2n ** 256n - 1n

/* ------------------------------------------------------------------ */
/* WadRayMath, PercentageMath, MathUtils                               */
/* ------------------------------------------------------------------ */

export const rayMul = (a: bigint, b: bigint) => (a * b + HALF_RAY) / RAY
export const rayMulFloor = (a: bigint, b: bigint) => (a * b) / RAY
export const rayMulCeil = (a: bigint, b: bigint) => ceilDiv(a * b, RAY)
export const rayDivFloor = (a: bigint, b: bigint) => (a * RAY) / b
export const rayDivCeil = (a: bigint, b: bigint) => ceilDiv(a * RAY, b)
export const wadDiv = (a: bigint, b: bigint) => (a * WAD + b / 2n) / b
export const percentMul = (value: bigint, percentage: bigint) => (value * percentage + PERCENTAGE_FACTOR / 2n) / PERCENTAGE_FACTOR
export const mulDivCeil = (a: bigint, b: bigint, c: bigint) => ceilDiv(a * b, c)

function ceilDiv(a: bigint, b: bigint): bigint {
  return a === 0n ? 0n : (a - 1n) / b + 1n
}

/** MathUtils.calculateLinearInterest: supply side. */
export function linearInterest(rate: bigint, lastUpdate: bigint, now: bigint): bigint {
  return RAY + (rate * (now - lastUpdate)) / SECONDS_PER_YEAR
}

/** MathUtils.calculateCompoundedInterest: debt side, a third-order binomial approximation. */
export function compoundedInterest(rate: bigint, lastUpdate: bigint, now: bigint): bigint {
  const exp = now - lastUpdate
  if (exp === 0n) return RAY
  const x = (rate * exp) / SECONDS_PER_YEAR
  return RAY + x + rayMul(x, x / 2n + rayMul(x, x / 6n))
}

/* ------------------------------------------------------------------ */
/* Reserve                                                             */
/* ------------------------------------------------------------------ */

/** What the app reads for the WETH reserve: getReserveData plus the token supplies and the virtual balance. */
export interface Reserve {
  configuration: bigint
  liquidityIndex: bigint
  currentLiquidityRate: bigint
  variableBorrowIndex: bigint
  currentVariableBorrowRate: bigint
  lastUpdateTimestamp: bigint
  accruedToTreasury: bigint
  /** aToken.scaledTotalSupply() */
  scaledATokenSupply: bigint
  /** variableDebtToken.scaledTotalSupply() */
  scaledDebtSupply: bigint
  /** Pool.getVirtualUnderlyingBalance(): what withdrawals and borrows can take out */
  virtualBalance: bigint
}

const bits = (config: bigint, from: number, width: number) => (config >> BigInt(from)) & ((1n << BigInt(width)) - 1n)

/** ReserveConfiguration fields the app needs. Caps are in whole tokens; 0 means no cap. */
export function readConfiguration(config: bigint) {
  return {
    ltv: bits(config, 0, 16),
    liquidationThreshold: bits(config, 16, 16),
    decimals: bits(config, 48, 8),
    active: bits(config, 56, 1) === 1n,
    frozen: bits(config, 57, 1) === 1n,
    borrowingEnabled: bits(config, 58, 1) === 1n,
    paused: bits(config, 60, 1) === 1n,
    reserveFactor: bits(config, 64, 16),
    borrowCap: bits(config, 80, 36),
    supplyCap: bits(config, 116, 36),
  }
}

/** ReserveLogic.getNormalizedIncome: the liquidity index at `now`, as aToken.balanceOf() uses it. */
export function normalizedIncome(r: Reserve, now: bigint): bigint {
  if (now === r.lastUpdateTimestamp) return r.liquidityIndex
  return rayMul(linearInterest(r.currentLiquidityRate, r.lastUpdateTimestamp, now), r.liquidityIndex)
}

/** ReserveLogic.getNormalizedDebt: the variable borrow index at `now`, as debtToken.balanceOf() uses it. */
export function normalizedDebt(r: Reserve, now: bigint): bigint {
  if (now === r.lastUpdateTimestamp) return r.variableBorrowIndex
  return rayMul(compoundedInterest(r.currentVariableBorrowRate, r.lastUpdateTimestamp, now), r.variableBorrowIndex)
}

/**
 * ReserveLogic.updateState at `now`, as the first Aave call of a block runs it: the indexes the call then uses and the
 * treasury's scaled accrual. The liquidity index moves only with a non-zero supply rate, the borrow index only with
 * debt outstanding; later calls in the same block see lastUpdateTimestamp == now and change nothing.
 */
export function updatedReserve(r: Reserve, now: bigint): Reserve {
  if (now === r.lastUpdateTimestamp) return r
  const liquidityIndex =
    r.currentLiquidityRate !== 0n
      ? rayMul(linearInterest(r.currentLiquidityRate, r.lastUpdateTimestamp, now), r.liquidityIndex)
      : r.liquidityIndex
  const variableBorrowIndex =
    r.scaledDebtSupply !== 0n
      ? rayMul(compoundedInterest(r.currentVariableBorrowRate, r.lastUpdateTimestamp, now), r.variableBorrowIndex)
      : r.variableBorrowIndex
  let accruedToTreasury = r.accruedToTreasury
  const reserveFactor = readConfiguration(r.configuration).reserveFactor
  if (reserveFactor !== 0n) {
    const totalDebtAccrued = rayMulFloor(r.scaledDebtSupply, variableBorrowIndex - r.variableBorrowIndex)
    const amountToMint = percentMul(totalDebtAccrued, reserveFactor)
    if (amountToMint !== 0n) accruedToTreasury += rayDivFloor(amountToMint, liquidityIndex)
  }
  return { ...r, liquidityIndex, variableBorrowIndex, accruedToTreasury, lastUpdateTimestamp: now }
}

/* ------------------------------------------------------------------ */
/* Balances (TokenMath)                                                */
/* ------------------------------------------------------------------ */

export const aTokenBalance = (scaled: bigint, liquidityIndex: bigint) => rayMulFloor(scaled, liquidityIndex)
export const debtBalance = (scaled: bigint, borrowIndex: bigint) => rayMulCeil(scaled, borrowIndex)
export const aTokenMintScaled = (amount: bigint, liquidityIndex: bigint) => rayDivFloor(amount, liquidityIndex)
export const aTokenBurnScaled = (amount: bigint, liquidityIndex: bigint) => rayDivCeil(amount, liquidityIndex)
export const debtMintScaled = (amount: bigint, borrowIndex: bigint) => rayDivCeil(amount, borrowIndex)
export const debtBurnScaled = (amount: bigint, borrowIndex: bigint) => rayDivFloor(amount, borrowIndex)

/* ------------------------------------------------------------------ */
/* Health factor (GenericLogic.calculateUserAccountData)               */
/* ------------------------------------------------------------------ */

/**
 * Health factor of an account whose only collateral and only debt are the same 18-decimal asset, valued at `price`
 * (8 decimals, from Aave's oracle) with liquidation threshold `lt` in bps (the E-Mode category's). Collateral counts
 * only while the scaled aToken balance is non-zero; no debt in base currency is type(uint256).max, as Aave reports it.
 */
export function healthFactor(collateral: bigint, debt: bigint, price: bigint, lt: bigint, unit = WAD): bigint {
  // Aave tests the debt in base currency, so a zero price reads as no debt too
  const debtBase = mulDivCeil(debt, price, unit)
  if (debtBase === 0n) return MAX_UINT256
  const collateralBase = (collateral * price) / unit
  return wadDiv(collateralBase * lt, debtBase) / PERCENTAGE_FACTOR
}

/* ------------------------------------------------------------------ */
/* Caps (ValidationLogic.validateSupply, validateBorrow)               */
/* ------------------------------------------------------------------ */

/** Whether supplying `amount` at `now` fits the supply cap. */
export function fitsSupplyCap(r: Reserve, amount: bigint, now: bigint): boolean {
  const c = readConfiguration(r.configuration)
  if (c.supplyCap === 0n) return true
  const u = updatedReserve(r, now)
  const scaled = aTokenMintScaled(amount, u.liquidityIndex)
  return aTokenBalance(r.scaledATokenSupply + scaled + u.accruedToTreasury, u.liquidityIndex) <= c.supplyCap * 10n ** c.decimals
}

/** Whether borrowing `amount` at `now` fits the borrow cap. */
export function fitsBorrowCap(r: Reserve, amount: bigint, now: bigint): boolean {
  const c = readConfiguration(r.configuration)
  if (c.borrowCap === 0n) return true
  const u = updatedReserve(r, now)
  const scaled = debtMintScaled(amount, u.variableBorrowIndex)
  return debtBalance(r.scaledDebtSupply + scaled, u.variableBorrowIndex) <= c.borrowCap * 10n ** c.decimals
}

/** Rates in ray as annual percentages at 1e18 scale (APR, no compounding), for display. */
export const rayToWadRate = (rate: bigint) => rate / 10n ** 9n
