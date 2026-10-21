import { describe, expect, it } from 'vitest'
import {
  MAX_UINT256,
  RAY,
  compoundedInterest,
  healthFactor,
  linearInterest,
  rayDivCeil,
  rayDivFloor,
  rayMul,
  rayMulCeil,
  rayMulFloor,
  readConfiguration,
  type Reserve,
} from './aave'
import { formatGap, formatHealth, formatWeth, parseAmount, toInput } from './format'
import {
  depositRoom,
  maxDeposit,
  maxWithdraw,
  position,
  previewDeposit,
  previewRedeem,
  simulateDeposit,
  simulateExit,
  simulateReinvest,
  simulateWithdraw,
  SimulatedRevert,
  vaultTotalAssets,
  type State,
} from './vault'

const E18 = 10n ** 18n
const PRICE = 249_211_000_000n // ETH at $2,492.11, Aave's 8-decimal base currency

/** WETH reserve config: LTV 83.5%, LT 85%, 18 decimals, active, borrowing on, RF 10%, caps 1,200 / 2,500. */
const CONFIG = 8350n | (8500n << 16n) | (18n << 48n) | (1n << 56n) | (1n << 58n) | (1000n << 64n) | (1200n << 80n) | (2500n << 116n)

function reserve(overrides: Partial<Reserve> = {}): Reserve {
  return {
    configuration: CONFIG,
    liquidityIndex: RAY,
    currentLiquidityRate: 0n,
    variableBorrowIndex: RAY,
    currentVariableBorrowRate: 0n,
    lastUpdateTimestamp: 1_000n,
    accruedToTreasury: 0n,
    scaledATokenSupply: 1_000n * E18,
    scaledDebtSupply: 500n * E18,
    virtualBalance: 500n * E18,
    ...overrides,
  }
}

function emptyState(overrides: Partial<Reserve> = {}): State {
  return {
    reserve: reserve(overrides),
    price: PRICE,
    flashLiquidity: 1_000n * E18,
    strategy: {
      aScaled: 0n,
      debtScaled: 0n,
      idle: 0n,
      totalSupply: 0n,
      emergency: false,
      params: {
        targetLeverage: 10n,
        minHealthFactor: (102n * E18) / 100n,
        targetHealthFactor: (105n * E18) / 100n,
        minRemainingEquity: 10n ** 12n,
        minInvestAssets: 10n ** 12n,
        marginBps: 10n,
        eModeLtv: 9300n,
        eModeLiquidationThreshold: 9500n,
      },
    },
    vault: { totalSupply: 1000n, idle: 1000n, strategyShares: 0n, highWaterMark: 1000n, feeBps: 1000n, feeRecipientSet: true, emergency: false },
  }
}

describe('Aave math', () => {
  it('rounds each operation the way WadRayMath does', () => {
    expect(rayMul(3n, RAY / 2n)).toBe(2n) // 1.5 rounds half up
    expect(rayMulFloor(3n, RAY / 2n)).toBe(1n)
    expect(rayMulCeil(3n, RAY / 2n)).toBe(2n)
    expect(rayDivFloor(1n, 3n * RAY)).toBe(0n)
    expect(rayDivCeil(1n, 3n * RAY)).toBe(1n)
  })

  it('accrues linear supply interest and binomial debt interest', () => {
    const rate = (35n * RAY) / 1000n // 3.5% a year
    expect(linearInterest(rate, 0n, 31_536_000n)).toBe(RAY + rate)
    expect(compoundedInterest(rate, 5n, 5n)).toBe(RAY)
    // e^0.035 = 1.035619..., the three-term approximation sits just below it
    const year = compoundedInterest(rate, 0n, 31_536_000n)
    expect(year > RAY + rate && year < (1_035_620n * RAY) / 1_000_000n).toBe(true)
  })

  it("reproduces Aave's health factor of a fresh 10x position on Base Sepolia", () => {
    // Read from getUserAccountData on a Base Sepolia fork after a 1 WETH deposit at 10x (collateral rounds down, debt up)
    expect(healthFactor(9_999_999_999_999_999_999n, 9_000_000_000_000_000_001n, PRICE, 9500n)).toBe(1_055_555_555_554_661_375n)
    expect(healthFactor(E18, 0n, PRICE, 9500n)).toBe(MAX_UINT256)
  })

  it('decodes the reserve configuration bitmap', () => {
    const c = readConfiguration(CONFIG)
    expect([c.ltv, c.liquidationThreshold, c.decimals, c.reserveFactor, c.borrowCap, c.supplyCap]).toEqual([8350n, 8500n, 18n, 1000n, 1200n, 2500n])
    expect([c.active, c.frozen, c.borrowingEnabled, c.paused]).toEqual([true, false, true, false])
  })
})

describe('vault and strategy simulations', () => {
  it('loops a deposit ten times and keeps the strategy idle balance', () => {
    const res = simulateDeposit(emptyState(), E18, true, 1_000n)
    const p = position(res.state, 1_000n)
    expect(res.invested).toBe(true)
    expect(p.collateral).toBe(10n * E18)
    expect(p.debt).toBe(9n * E18)
    expect(p.idle).toBe(0n)
    expect(res.shares).toBe(previewDeposit(emptyState(), E18, 1_000n))
    expect(vaultTotalAssets(res.state, 1_000n)).toBe(E18 + 1000n)
  })

  it('keeps a deposit below MIN_INVEST_ASSETS idle', () => {
    const res = simulateDeposit(emptyState(), 10n ** 12n - 1n, true, 1_000n)
    expect(res.invested).toBe(false)
    expect(res.state.strategy.idle).toBe(10n ** 12n - 1n)
  })

  it('refuses deposits for a receiver outside the whitelist and during emergency mode', () => {
    expect(() => simulateDeposit(emptyState(), E18, false, 1_000n)).toThrow(SimulatedRevert)
    const s = emptyState()
    s.vault.emergency = true
    expect(maxDeposit(s, true, 1_000n)).toBe(0n)
    expect(() => simulateDeposit(s, E18, true, 1_000n)).toThrow('VaultInEmergency')
  })

  it('deleverages a withdrawal proportionally: repay 4.5, withdraw 5, pay 0.5', () => {
    const s = simulateDeposit(emptyState(), E18, true, 1_000n).state
    const w = simulateWithdraw(s, E18 / 2n, s.vault.totalSupply - 1000n, 1_000n)
    // The vault pays its own 1,000 idle wei first, the strategy the rest
    const fromStrategy = E18 / 2n - 1000n
    expect(w.fromStrategy).toBe(fromStrategy)
    expect(w.fullClose).toBe(false)
    expect(w.debtRepaid).toBe(9n * fromStrategy)
    expect(w.collateralWithdrawn).toBe(10n * fromStrategy)
    // Leverage does not increase in WETH (debt repaid rounds up); Aave's 8-decimal rounding can still move the HF by wei
    const before = position(s, 1_000n)
    const after = position(w.state, 1_000n)
    expect(after.collateral * before.debt >= before.collateral * after.debt).toBe(true)
  })

  it('closes the position on an emergency exit and rebuilds it on reinvest', () => {
    const s = simulateDeposit(emptyState(), E18, true, 1_000n).state
    const exit = simulateExit(s, 1_000n)
    expect(exit.state.strategy.debtScaled).toBe(0n)
    expect(exit.state.strategy.idle).toBe(E18)
    const re = simulateReinvest(exit.state, 1_000n)
    // Regression: the vault's own 1,000 wei go in too, and are counted once although they first sit idle in the strategy
    expect(re.invested).toBe(E18 + 1000n)
    expect(position(re.state, 1_000n).debt).toBe(9n * (E18 + 1000n))
  })

  it('reports the full equity as withdrawable while the PoolManager covers the debt', () => {
    const s = simulateDeposit(emptyState(), E18, true, 1_000n).state
    const shares = s.vault.totalSupply - 1000n
    expect(maxWithdraw(s, shares, 1_000n)).toBe(previewRedeem(s, shares, 1_000n))
  })

  it('finds the deposit room under the borrow cap to the wei', () => {
    // 1,200 WETH cap, 1,190 borrowed: room for 10 / 9 WETH of deposits at 10x
    const s = emptyState({ scaledDebtSupply: 1_190n * E18 })
    const room = depositRoom(s, 1_000n)
    expect(room).toBe((10n * E18) / 9n)
    expect(() => simulateDeposit(s, room + 1n, true, 1_000n)).toThrow('BorrowCapExceeded')
    expect(() => simulateDeposit(s, room, true, 1_000n)).not.toThrow()
  })
})

describe('formatting', () => {
  it('parses and prints amounts without losing wei', () => {
    expect(parseAmount('1.5', 18)).toBe(15n * 10n ** 17n)
    expect(parseAmount('1.', 18)).toBe(E18)
    expect(parseAmount('0.0000000000000000001', 18)).toBeNull()
    expect(toInput(1_234_500_000_000_000_000n, 18)).toBe('1.2345')
    expect(formatWeth(1_999_999n * 10n ** 12n)).toBe('1.9999')
    expect(formatHealth(MAX_UINT256)).toBe('No debt')
  })

  // Regression: the fee card printed a 1 wei gap below the high-water mark as "0.000000 WETH below the mark"
  it('does not print a gap under the shown precision as zero', () => {
    expect(formatGap(1n)).toBe('less than 0.000001')
    expect(formatGap(10n ** 12n - 1n)).toBe('less than 0.000001')
    expect(formatGap(10n ** 12n)).toBe('0.000001')
    expect(formatGap(0n)).toBe('0.000000')
  })
})
