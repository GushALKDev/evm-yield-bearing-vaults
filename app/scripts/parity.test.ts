// Checks the app's math against the deployed contracts on a local anvil fork of Base Sepolia, to the wei: Aave's
// balances and health factor projected to the second, the vault and strategy conversions with the pending fee, the
// ERC-4626 limits, every simulated call against the state it leaves, the cap room boundary and the gas margin.
// Run after ./scripts/local-chain.sh:  LOCAL_RPC=http://127.0.0.1:8545 npx vitest run scripts/parity.test.ts
// The suite moves the chain forward and reverts it to a snapshot at the end, so it can run again.
import { readFileSync } from 'node:fs'
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeFunctionData,
  http,
  keccak256,
  encodeAbiParameters,
  pad,
  toHex,
  type Abi,
  type Address,
  type Hex,
} from 'viem'
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest'
import type { Deployment } from '../src/config/deployment'
import { aavePoolAbi, aaveTokenAbi, operatorAbi, strategyAbi, vaultAbi, vaultCallAbi, wethAbi } from '../src/lib/abi'
import { gasWithMargin } from '../src/lib/gas'
import { buildState } from '../src/lib/model'
import { decodeLive, decodeStatic, liveReads, staticReads, type StaticData } from '../src/lib/reads'
import {
  depositRoom,
  maxDeposit,
  maxRedeem,
  maxWithdraw,
  position,
  previewDeposit,
  previewMint,
  previewRedeem,
  previewWithdraw,
  simulateDeposit,
  simulateExit,
  simulateRedeem,
  simulateReinvest,
  simulateWithdraw,
  strategyMaxWithdraw,
  strategyToAssets,
  strategyTotalAssets,
  vaultToAssets,
  vaultToShares,
  vaultTotalAssets,
  type State,
} from '../src/lib/vault'

const rpc = process.env.LOCAL_RPC
// A fork fetches state from Base Sepolia the first time it touches it, so calls take longer than on a bare node
vi.setConfig({ testTimeout: 180_000, hookTimeout: 180_000 })
const chain = defineChain({
  id: 31_337,
  name: 'Local fork',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [rpc ?? 'http://127.0.0.1:8545'] } },
  contracts: { multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' } },
})

// anvil's default accounts 0 to 3, unlocked on a local node
const deployer = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' as Address
const alice = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8' as Address
const carol = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC' as Address
const bob = '0x90F79bf6EB2c4f870365E785982E1f101E93b906' as Address

const E18 = 10n ** 18n

interface Call {
  address: Address
  abi: Abi | readonly unknown[]
  functionName: string
  args?: readonly unknown[]
  value?: bigint
}

describe.skipIf(!rpc)('parity with the contracts on a local Base Sepolia fork', () => {
  // Read lazily: the local deployment file is not committed, and a skipped suite still gets collected
  let d: Deployment
  let st: StaticData
  let snapshot: Hex
  const pub = createPublicClient({ chain, transport: http(rpc) })
  const walletOf = (account: Address) => createWalletClient({ chain, transport: http(rpc), account })

  const rpcCall = (method: string, params: unknown[] = []) => pub.request({ method: method as never, params: params as never })
  const latest = () => pub.getBlock({ blockTag: 'latest' })
  const setNextTimestamp = (t: bigint) => rpcCall('evm_setNextBlockTimestamp', [Number(t)])
  const mineAt = async (t: bigint) => {
    await setNextTimestamp(t)
    await rpcCall('evm_mine')
  }

  /** Sends a call (optionally in a block at timestamp `at`, with an explicit gas limit) and returns the receipt. */
  async function send(account: Address, call: Call, opts: { at?: bigint; gas?: bigint; mayRevert?: boolean } = {}) {
    if (opts.at !== undefined) await setNextTimestamp(opts.at)
    const hash = await walletOf(account).sendTransaction({
      to: call.address,
      data: encodeFunctionData({ abi: call.abi as Abi, functionName: call.functionName, args: call.args as unknown[] }),
      value: call.value,
      // A node's plain estimate runs short whenever Aave's reserve was already updated in the latest block (the gas test
      // below measures it), so calls outside that test carry a fixed, ample limit
      gas: opts.gas ?? 6_000_000n,
      chain,
    })
    const receipt = await pub.waitForTransactionReceipt({ hash })
    if (receipt.status !== 'success' && !opts.mayRevert) {
      // Replays the call on the parent block for the revert reason
      const reason = await pub
        .simulateContract({ account, address: call.address, abi: [...(call.abi as Abi), ...vaultCallAbi] as Abi, functionName: call.functionName, args: call.args as unknown[], value: call.value, blockNumber: receipt.blockNumber - 1n } as never)
        .then(() => 'no revert on the parent block')
        .catch((e: Error) => e.message.split('\n').slice(0, 3).join(' '))
      throw new Error(`${call.functionName} reverted in block ${receipt.blockNumber}: ${reason}`)
    }
    return receipt
  }

  /** The app's reads, at a block, decoded by the app's own code. */
  async function readState(account: Address = alice, blockNumber?: bigint) {
    const block = blockNumber === undefined ? await latest() : await pub.getBlock({ blockNumber })
    const reads = liveReads(d, st.eModeCategory, account)
    const keys = Object.keys(reads) as (keyof typeof reads)[]
    const results = await pub.multicall({ contracts: keys.map((k) => reads[k]) as never, allowFailure: false, blockNumber: block.number })
    const live = decodeLive(Object.fromEntries(keys.map((k, i) => [k, results[i]])), account)
    return { state: buildState(st, live), live, block, account: live.account! }
  }

  const view = <T>(address: Address, abi: Abi | readonly unknown[], functionName: string, args: readonly unknown[], blockNumber: bigint) =>
    pub.readContract({ address, abi: abi as Abi, functionName, args, blockNumber } as never) as Promise<T>

  const wrapAndApprove = async (account: Address, amount: bigint) => {
    await send(account, { address: d.weth, abi: wethAbi, functionName: 'deposit', value: amount })
    await send(account, { address: d.weth, abi: wethAbi, functionName: 'approve', args: [d.vault, 2n ** 256n - 1n] })
  }

  const deposit = (account: Address, amount: bigint, at?: bigint) =>
    send(account, { address: d.vault, abi: vaultAbi, functionName: 'deposit', args: [amount, account] }, { at })

  /** The scaled balances, idle WETH and supplies a simulation predicts against what the chain holds afterwards. */
  function expectSameState(actual: State, predicted: State) {
    expect(actual.strategy.aScaled, 'aToken scaled balance').toBe(predicted.strategy.aScaled)
    expect(actual.strategy.debtScaled, 'debt scaled balance').toBe(predicted.strategy.debtScaled)
    expect(actual.strategy.idle, 'strategy idle WETH').toBe(predicted.strategy.idle)
    expect(actual.strategy.totalSupply, 'strategy shares').toBe(predicted.strategy.totalSupply)
    expect(actual.vault.totalSupply, 'vault shares').toBe(predicted.vault.totalSupply)
    expect(actual.vault.strategyShares, "vault's strategy shares").toBe(predicted.vault.strategyShares)
    expect(actual.vault.idle, 'vault idle WETH').toBe(predicted.vault.idle)
    expect(actual.vault.highWaterMark, 'high-water mark').toBe(predicted.vault.highWaterMark)
    expect(actual.reserve.scaledATokenSupply, 'aToken scaled supply').toBe(predicted.reserve.scaledATokenSupply)
    expect(actual.reserve.scaledDebtSupply, 'debt scaled supply').toBe(predicted.reserve.scaledDebtSupply)
    expect(actual.reserve.liquidityIndex, 'liquidity index').toBe(predicted.reserve.liquidityIndex)
    expect(actual.reserve.variableBorrowIndex, 'borrow index').toBe(predicted.reserve.variableBorrowIndex)
    expect(actual.reserve.accruedToTreasury, 'treasury accrual').toBe(predicted.reserve.accruedToTreasury)
    expect(actual.reserve.virtualBalance, 'virtual balance').toBe(predicted.reserve.virtualBalance)
  }

  beforeAll(async () => {
    const raw = JSON.parse(readFileSync(new URL('../src/config/deployments/31337.json', import.meta.url), 'utf8'))
    d = { ...raw, deployBlock: BigInt(raw.deployBlock), seedAssets: BigInt(raw.seedAssets) }
    snapshot = (await rpcCall('evm_snapshot')) as Hex
    const reads = staticReads(d)
    const keys = Object.keys(reads) as (keyof typeof reads)[]
    const results = await pub.multicall({ contracts: keys.map((k) => reads[k]) as never, allowFailure: false })
    st = decodeStatic(Object.fromEntries(keys.map((k, i) => [k, results[i]])))
    for (const account of [alice, bob]) {
      await send(account, { address: d.operator, abi: operatorAbi, functionName: 'join' })
      await wrapAndApprove(account, 30n * E18)
    }
  })

  afterAll(async () => {
    if (snapshot) await rpcCall('evm_revert', [snapshot])
  })

  it('projects the Aave balances and health factor to the second', async () => {
    const { state, block } = await readState()
    for (const dt of [0n, 1n, 7n, 3_600n, 30n * 86_400n]) {
      if (dt > 0n) await mineAt(block.timestamp + dt)
      const n = (await latest()).number
      const p = position(state, block.timestamp + dt)
      expect(p.collateral, `collateral after ${dt}s`).toBe(await view<bigint>(d.aToken, aaveTokenAbi, 'balanceOf', [d.strategy], n))
      expect(p.debt, `debt after ${dt}s`).toBe(await view<bigint>(d.variableDebtToken, aaveTokenAbi, 'balanceOf', [d.strategy], n))
      const data = await view<readonly bigint[]>(d.aavePool, aavePoolAbi, 'getUserAccountData', [d.strategy], n)
      expect(p.healthFactor, `health factor after ${dt}s`).toBe(data[5])
      expect(strategyTotalAssets(p), `strategy totalAssets after ${dt}s`).toBe(await view<bigint>(d.strategy, strategyAbi, 'totalAssets', [], n))
    }
  })

  it('previews a deposit to the wei: shares, scaled balances, indexes and treasury accrual', async () => {
    const { state, block, account } = await readState()
    const at = block.timestamp + 13n
    const amount = 1_234_567_890_123_456_789n
    const sim = simulateDeposit(state, amount, account.whitelisted, at)
    await deposit(alice, amount, at)
    const after = await readState()
    expect(after.block.timestamp).toBe(at)
    expect(after.account.shares - account.shares, 'shares minted').toBe(sim.shares)
    expectSameState(after.state, sim.state)
    expect(position(after.state, at).healthFactor, 'health factor').toBe(position(sim.state, at).healthFactor)
  })

  it('matches every conversion, preview and limit, with a pending performance fee', async () => {
    // A donation lifts totalAssets above the high-water mark, so the 10% fee is pending in every conversion
    await send(carol, { address: d.weth, abi: wethAbi, functionName: 'deposit', value: E18 / 20n })
    await send(carol, { address: d.weth, abi: wethAbi, functionName: 'transfer', args: [d.vault, E18 / 20n] })
    const { state, block, account } = await readState()
    const n = block.number
    const t = block.timestamp
    expect(vaultTotalAssets(state, t), 'vault totalAssets').toBe(await view<bigint>(d.vault, vaultAbi, 'totalAssets', [], n))
    expect(vaultTotalAssets(state, t)).toBeGreaterThan(state.vault.highWaterMark)
    for (const x of [1n, 999n, 10n ** 12n, 3n * 10n ** 17n, 7n * E18 + 123n]) {
      expect(previewDeposit(state, x, t), `previewDeposit ${x}`).toBe(await view<bigint>(d.vault, vaultAbi, 'previewDeposit', [x], n))
      expect(previewMint(state, x, t), `previewMint ${x}`).toBe(await view<bigint>(d.vault, vaultAbi, 'previewMint', [x], n))
      expect(previewWithdraw(state, x, t), `previewWithdraw ${x}`).toBe(await view<bigint>(d.vault, vaultAbi, 'previewWithdraw', [x], n))
      expect(previewRedeem(state, x, t), `previewRedeem ${x}`).toBe(await view<bigint>(d.vault, vaultAbi, 'previewRedeem', [x], n))
      expect(vaultToShares(state, x, t, 'floor'), `convertToShares ${x}`).toBe(await view<bigint>(d.vault, vaultAbi, 'convertToShares', [x], n))
      expect(vaultToAssets(state, x, t, 'floor'), `convertToAssets ${x}`).toBe(await view<bigint>(d.vault, vaultAbi, 'convertToAssets', [x], n))
      expect(strategyToAssets(state, x, t, 'floor'), `strategy convertToAssets ${x}`).toBe(await view<bigint>(d.strategy, strategyAbi, 'convertToAssets', [x], n))
    }
    expect(maxDeposit(state, true, t), 'maxDeposit').toBe(await view<bigint>(d.vault, vaultAbi, 'maxDeposit', [alice], n))
    expect(maxDeposit(state, false, t), 'maxDeposit outside the whitelist').toBe(await view<bigint>(d.vault, vaultAbi, 'maxDeposit', [carol], n))
    expect(maxWithdraw(state, account.shares, t), 'maxWithdraw').toBe(await view<bigint>(d.vault, vaultAbi, 'maxWithdraw', [alice], n))
    expect(maxRedeem(state, account.shares, t), 'maxRedeem').toBe(await view<bigint>(d.vault, vaultAbi, 'maxRedeem', [alice], n))
    expect(strategyMaxWithdraw(state, t), 'strategy maxWithdraw').toBe(await view<bigint>(d.strategy, strategyAbi, 'maxWithdraw', [d.vault], n))

    // The next deposit mints the fee shares first: the vault's supply must move by exactly the previewed amount
    const at = t + 5n
    const sim = simulateDeposit(state, E18 / 3n, true, at)
    await deposit(alice, E18 / 3n, at)
    expectSameState((await readState()).state, sim.state)
  })

  it('caps maxWithdraw by the PoolManager when its WETH cannot cover a full exit', async () => {
    const snap = (await rpcCall('evm_snapshot')) as Hex
    // WETH9 keeps balances in slot 3: leave the PoolManager 0.6 WETH, less than the strategy's debt
    const slot = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [d.poolManager, 3n]))
    await rpcCall('anvil_setStorageAt', [d.weth, slot, pad(toHex(6n * 10n ** 17n), { size: 32 })])
    await rpcCall('evm_mine')
    const { state, block, account } = await readState()
    const n = block.number
    expect(state.flashLiquidity).toBe(6n * 10n ** 17n)
    expect(position(state, block.timestamp).debt).toBeGreaterThan(state.flashLiquidity)
    expect(strategyMaxWithdraw(state, block.timestamp), 'partial path').toBe(await view<bigint>(d.strategy, strategyAbi, 'maxWithdraw', [d.vault], n))
    expect(maxWithdraw(state, account.shares, block.timestamp), 'vault maxWithdraw').toBe(await view<bigint>(d.vault, vaultAbi, 'maxWithdraw', [alice], n))
    expect(maxRedeem(state, account.shares, block.timestamp), 'vault maxRedeem').toBe(await view<bigint>(d.vault, vaultAbi, 'maxRedeem', [alice], n))
    await rpcCall('evm_revert', [snap])
  })

  it('previews a proportional withdrawal and a redeem of every share', async () => {
    let { state, block, account } = await readState()
    let at = block.timestamp + 3n
    const w = simulateWithdraw(state, E18 / 2n, account.shares, at)
    expect(w.flashLoan).toBeGreaterThan(0n)
    expect(w.fullClose).toBe(false)
    const wethBefore = account.weth
    await send(alice, { address: d.vault, abi: vaultAbi, functionName: 'withdraw', args: [E18 / 2n, alice, alice] }, { at })
    ;({ state, block, account } = await readState())
    expect(account.weth - wethBefore, 'WETH received').toBe(E18 / 2n)
    expectSameState(state, w.state)

    at = block.timestamp + 21n
    const shares = maxRedeem(state, account.shares, block.timestamp)
    const r = simulateRedeem(state, shares, account.shares, at)
    await send(alice, { address: d.vault, abi: vaultAbi, functionName: 'redeem', args: [shares, alice, alice] }, { at })
    const after = await readState()
    expect(after.account.shares, 'all shares redeemed').toBe(account.shares - shares)
    expect(after.account.weth - account.weth, 'WETH received').toBe(r.assets)
    expectSameState(after.state, r.state)
  })

  it('previews the emergency cycle: shock, checkHealth, a withdrawal from idle WETH, restore, reinvest', async () => {
    await deposit(bob, E18)
    let { state, block } = await readState()
    let at = block.timestamp + 6n
    const hfAt = position(state, at).healthFactor
    await send(carol, { address: d.operator, abi: operatorAbi, functionName: 'shock' }, { at })
    ;({ state, block } = await readState())
    expect(state.strategy.params.minHealthFactor, 'trip threshold after the shock').toBe(hfAt + st.shockMinOffset)
    expect(state.strategy.params.targetHealthFactor, 're-arm threshold after the shock').toBe(hfAt + st.shockTargetOffset)
    expect(maxDeposit(state, true, block.timestamp), 'deposits closed').toBe(await view<bigint>(d.vault, vaultAbi, 'maxDeposit', [alice], block.number))
    expect(maxDeposit(state, true, block.timestamp)).toBe(0n)

    at = block.timestamp + 9n
    const exit = simulateExit(state, at)
    await send(carol, { address: d.strategy, abi: strategyAbi, functionName: 'checkHealth' }, { at })
    ;({ state, block } = await readState())
    expect(state.vault.emergency && state.strategy.emergency, 'emergency mode').toBe(true)
    expectSameState(state, { ...exit.state, vault: { ...exit.state.vault, emergency: true } })

    // Withdrawals stay open during emergency mode, paid from the idle WETH the exit left
    const bobState = await readState(bob)
    at = bobState.block.timestamp + 3n
    const w = simulateWithdraw(bobState.state, (3n * E18) / 10n, bobState.account.shares, at)
    expect(w.flashLoan, 'no flash loan from idle WETH').toBe(0n)
    await send(bob, { address: d.vault, abi: vaultAbi, functionName: 'withdraw', args: [(3n * E18) / 10n, bob, bob] }, { at })
    const afterWithdraw = await readState(bob)
    expect(afterWithdraw.account.weth - bobState.account.weth, 'WETH received').toBe((3n * E18) / 10n)
    expectSameState(afterWithdraw.state, w.state)
    ;({ state, block } = await readState())

    await send(carol, { address: d.operator, abi: operatorAbi, functionName: 'restore' })
    ;({ state, block } = await readState())
    expect(state.vault.emergency).toBe(false)
    expect(state.strategy.params.minHealthFactor).toBe(st.defaultMinHealthFactor)

    at = block.timestamp + 2n
    const re = simulateReinvest(state, at)
    expect(re.invested).toBeGreaterThan(0n)
    await send(carol, { address: d.operator, abi: operatorAbi, functionName: 'reinvest' }, { at })
    ;({ state } = await readState())
    expectSameState(state, re.state)
    expect(position(state, at).healthFactor).toBeGreaterThanOrEqual(state.strategy.params.targetHealthFactor)
  })

  it("finds the largest deposit Aave's caps accept, to the wei", async () => {
    const { state, block } = await readState()
    const at = block.timestamp + 5n
    const room = depositRoom(state, at)
    expect(room).toBeGreaterThan(10n ** 12n)
    expect(room).toBeLessThan(30n * E18)

    const snap = (await rpcCall('evm_snapshot')) as Hex
    const over = await send(alice, { address: d.vault, abi: vaultAbi, functionName: 'deposit', args: [room + 1n, alice] }, { at, gas: 3_000_000n, mayRevert: true })
    expect(over.status, 'one wei over the room reverts').toBe('reverted')
    await rpcCall('evm_revert', [snap])
    const exact = await send(alice, { address: d.vault, abi: vaultAbi, functionName: 'deposit', args: [room, alice] }, { at, gas: 3_000_000n })
    expect(exact.status, 'the room itself lands').toBe('success')
    // Back below the caps, so the gas test below has room
    const { account } = await readState()
    await send(alice, { address: d.vault, abi: vaultAbi, functionName: 'redeem', args: [account.shares, alice, alice] })
  })

  it('covers the landing cost with the gas margin when Aave was touched in the estimated block', async () => {
    // Each action is estimated at the latest block right after another account touched Aave's WETH reserve in that
    // block (updateState is then a no-op in the estimate) and lands one block later with the app's margin.
    const touch = async () => {
      await send(deployer, { address: d.weth, abi: wethAbi, functionName: 'deposit', value: 10n ** 6n })
      await send(deployer, { address: d.weth, abi: wethAbi, functionName: 'approve', args: [d.aavePool, 10n ** 6n] })
      await send(deployer, { address: d.aavePool, abi: aavePoolAbi, functionName: 'supply', args: [d.weth, 10n ** 6n, deployer, 0] })
    }
    const report: string[] = []
    const measure = async (label: string, account: Address, call: Call) => {
      await touch()
      const head = await latest()
      const reserve = await pub.readContract({ address: d.aavePool, abi: aavePoolAbi, functionName: 'getReserveData', args: [d.weth] })
      expect(BigInt(reserve.lastUpdateTimestamp), 'reserve updated in the estimated block').toBe(head.timestamp)
      const estimate = await pub.estimateGas({
        account,
        to: call.address,
        data: encodeFunctionData({ abi: call.abi as Abi, functionName: call.functionName, args: call.args as unknown[] }),
        value: call.value,
        blockNumber: head.number,
      })
      const receipt = await send(account, call, { at: head.timestamp + 2n, gas: gasWithMargin(estimate) })
      expect(receipt.status, `${label} lands with the margin`).toBe('success')
      report.push(`${label}: estimate ${estimate}, used ${receipt.gasUsed}, limit ${gasWithMargin(estimate)}`)
      return receipt
    }

    const fresh = carol
    await send(fresh, { address: d.weth, abi: wethAbi, functionName: 'deposit', value: 3n * E18 })
    await measure('join', fresh, { address: d.operator, abi: operatorAbi, functionName: 'join' })
    await measure('wrap', fresh, { address: d.weth, abi: wethAbi, functionName: 'deposit', value: E18 })
    await measure('approve', fresh, { address: d.weth, abi: wethAbi, functionName: 'approve', args: [d.vault, 2n * E18] })
    await measure('first deposit', fresh, { address: d.vault, abi: vaultAbi, functionName: 'deposit', args: [E18, fresh] })
    await measure('second deposit', fresh, { address: d.vault, abi: vaultAbi, functionName: 'deposit', args: [E18 / 2n, fresh] })
    await measure('partial withdraw', fresh, { address: d.vault, abi: vaultAbi, functionName: 'withdraw', args: [E18 / 4n, fresh, fresh] })
    const { account } = await readState(fresh)
    await measure('redeem all', fresh, { address: d.vault, abi: vaultAbi, functionName: 'redeem', args: [account.shares, fresh, fresh] })
    await measure('unwrap', fresh, { address: d.weth, abi: wethAbi, functionName: 'withdraw', args: [E18 / 10n] })
    // The cooldown from the cycle test has to pass first
    await mineAt((await latest()).timestamp + st.shockCooldown + 1n)
    await measure('shock', fresh, { address: d.operator, abi: operatorAbi, functionName: 'shock' })
    const trip = await measure('checkHealth trip', fresh, { address: d.strategy, abi: strategyAbi, functionName: 'checkHealth' })
    expect((await readState()).state.strategy.debtScaled, 'the trip closed the position, not just the flag').toBe(0n)
    void trip
    await measure('restore', fresh, { address: d.operator, abi: operatorAbi, functionName: 'restore' })
    await measure('reinvest', fresh, { address: d.operator, abi: operatorAbi, functionName: 'reinvest' })
    console.log(report.join('\n'))
  })
})
