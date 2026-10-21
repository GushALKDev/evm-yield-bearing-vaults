import { describe, expect, it } from 'vitest'
import { pickTimes } from './model'

describe('pickTimes', () => {
  // F11: before the first block arrived, limits and previews used Aave's last update, which can be hours old
  it("uses the visitor's clock for limits until the latest block is known", () => {
    expect(pickTimes(2_000n, undefined, 1_000n)).toEqual({ now: 2_000n, chainTime: 2_000n, chainKnown: false })
  })

  it("uses the latest block once known, never behind Aave's last update", () => {
    expect(pickTimes(2_000n, 1_500n, 1_000n)).toEqual({ now: 2_000n, chainTime: 1_500n, chainKnown: true })
    expect(pickTimes(900n, 950n, 1_000n)).toEqual({ now: 1_000n, chainTime: 1_000n, chainKnown: true })
  })
})
