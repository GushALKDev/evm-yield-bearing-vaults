import { describe, expect, it } from 'vitest'
import { pageFor } from '../hooks/useRoute'
import { WAD } from './aave'
import { depositSteps, projectYear, withdrawSteps, yieldBreakdown } from './flow'

const kinds = (steps: { kind: string; done: boolean }[]) => steps.map((s) => `${s.kind}${s.done ? ' (done)' : ''}`)

describe('deposit and withdrawal flows', () => {
  it('wraps Ether before approving and depositing, and shows a joined whitelist as done', () => {
    expect(kinds(depositSteps({ payWith: 'ETH', whitelisted: true, allowance: 0n, amount: WAD }))).toEqual([
      'join (done)',
      'wrap',
      'approve',
      'deposit',
    ])
  })

  it('skips the wrap when paying with WETH and the approval when the allowance covers the amount', () => {
    expect(kinds(depositSteps({ payWith: 'WETH', whitelisted: false, allowance: WAD, amount: WAD }))).toEqual([
      'join',
      'approve (done)',
      'deposit',
    ])
  })

  it('does not count an approval as done before an amount is typed', () => {
    expect(depositSteps({ payWith: 'WETH', whitelisted: true, allowance: 0n, amount: 0n })[1]).toEqual({ kind: 'approve', done: false })
  })

  it('redeems with Max and unwraps when paid out in Ether', () => {
    expect(kinds(withdrawSteps({ redeemAll: true, receive: 'ETH' }))).toEqual(['redeem', 'unwrap'])
    expect(kinds(withdrawSteps({ redeemAll: false, receive: 'WETH' }))).toEqual(['withdraw'])
  })
})

describe('yield breakdown', () => {
  const ray = (pct: number) => (BigInt(Math.round(pct * 100)) * 10n ** 27n) / 10_000n

  it('splits a 10x loop into 10 x supply minus 9 x borrow', () => {
    const p = { collateral: 10n * WAD, debt: 9n * WAD, idle: 0n, healthFactor: 0n }
    const y = yieldBreakdown(p, WAD, ray(2.07), ray(3.5))!
    expect(y.collateralMultiple).toBe(10n * WAD)
    expect(y.debtMultiple).toBe(9n * WAD)
    expect(y.earn).toBe((207n * WAD) / 1000n)
    expect(y.cost).toBe((315n * WAD) / 1000n)
    expect(y.net).toBe((-108n * WAD) / 1000n)
  })

  it('has nothing to explain without debt or equity', () => {
    const idle = { collateral: 0n, debt: 0n, idle: WAD, healthFactor: 0n }
    expect(yieldBreakdown(idle, WAD, ray(2), ray(3))).toBeNull()
    expect(yieldBreakdown({ ...idle, debt: WAD }, 0n, ray(2), ray(3))).toBeNull()
  })

  it('projects a year without going below zero', () => {
    expect(projectYear(WAD, (-108n * WAD) / 1000n)).toBe((892n * WAD) / 1000n)
    expect(projectYear(WAD, -2n * WAD)).toBe(0n)
  })
})

describe('routes', () => {
  it('serves the stress test at its new path and at the old /emergency link', () => {
    expect(pageFor('/stress-test')).toBe('stress')
    expect(pageFor('/emergency/')).toBe('stress')
    expect(pageFor('/how-it-works#stand-ins')).toBe('how')
    expect(pageFor('/unknown')).toBe('vault')
  })
})
