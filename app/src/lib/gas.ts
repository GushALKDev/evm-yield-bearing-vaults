/**
 * Gas limit from our own estimate. The node estimates at the latest block, and the call lands at least a block later:
 * when another call touched Aave's WETH reserve in the latest block, its updateState() is a no-op in the estimate but
 * writes the indexes, the timestamp and the treasury accrual once the call lands; a withdrawal can also switch from
 * the idle-WETH path to a flash loan, or from a proportional deleverage to a full close, if the position moves in
 * between. The margin is sized from the measurements in scripts/parity.test.ts (gas margin test).
 */
export const gasWithMargin = (estimate: bigint) => (estimate * 130n) / 100n + 30_000n
