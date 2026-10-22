import { useEffect, useState } from 'react'
import { useConnection } from 'wagmi'
import { readContract } from 'wagmi/actions'
import { chain, links } from '../config/chain'
import { useSetPreview } from '../hooks/usePreview'
import { useTx, type ContractCall } from '../hooks/useTx'
import { operatorAbi, vaultCallAbi, wethAbi } from '../lib/abi'
import { depositSteps, projectYear, withdrawSteps, yieldBreakdown, type Asset, type FlowStep, type StepKind } from '../lib/flow'
import { formatBps, formatHealth, formatPct, formatWeth, parseAmount, toInput } from '../lib/format'
import type { AccountView, VaultModel } from '../lib/model'
import {
  depositClosedReason,
  position,
  previewRedeem,
  simulateDeposit,
  simulateRedeem,
  simulateWithdraw,
  SimulatedRevert,
  vaultToAssets,
  type Position,
  type State,
} from '../lib/vault'
import { wagmiConfig } from '../wagmi'
import { Link } from './Sections'

/** Ether kept back when paying with Ether, for gas. Base Sepolia gas costs far less, but the wallet needs some. */
const GAS_RESERVE = 10n ** 14n

/* ------------------------------------------------------------------ */
/* Position                                                            */
/* ------------------------------------------------------------------ */

function PositionCard({ model, acc }: { model: VaultModel; acc: AccountView }) {
  const supply = model.live.vault.totalSupply
  const sharePct = supply > 0n ? (acc.shares * 10n ** 18n) / supply : 0n
  const all = acc.maxWithdraw >= acc.assetsAtChain
  return (
    <div className="card">
      <div className="card-title">
        <h2>Your position</h2>
        {acc.shares > 0n ? <span className="card-sub">{formatPct(sharePct)} of the vault</span> : null}
      </div>
      <div className="position-main">
        <span className="position-state">{acc.shares > 0n ? 'Your shares are worth' : 'No vault shares yet'}</span>
        <span className="position-amount" title={`${formatWeth(acc.assets, 18)} WETH`}>
          {formatWeth(acc.assets)}
          <small>WETH</small>
        </span>
        <span className="hint">
          {acc.shares > 0n
            ? `${formatWeth(acc.shares)} YBV shares. Withdrawable now: ${all ? 'all of it' : `${formatWeth(acc.maxWithdraw)} WETH`}.`
            : 'Deposit ETH or WETH and the strategy loops it at the target leverage in the same transaction.'}
        </span>
      </div>
      <dl className="rows">
        <div className="row">
          <dt>Wallet</dt>
          <dd>
            {acc.data.eth !== undefined ? formatWeth(acc.data.eth) : '…'} ETH <span className="faint">·</span> {formatWeth(acc.data.weth)} WETH
          </dd>
        </div>
      </dl>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Plans                                                               */
/* ------------------------------------------------------------------ */

type Tab = 'deposit' | 'withdraw'

interface Row {
  label: string
  before?: string
  after: string
  tone?: 'danger'
}

/** One transaction of the flow, ready to run. */
interface StepDef {
  name: string
  what: string
  label: string
  done: string
  call: () => Promise<ContractCall> | ContractCall
}

interface Plan {
  symbol: Asset
  max: bigint
  balanceLabel: string
  /** Why the action is closed whatever the amount */
  blocked?: string
  error?: string
  hint?: string
  rows: Row[]
  /** The deeper view: what happens in Aave and Uniswap */
  hood?: { note: string; rows: Row[] }
  preview?: { after: Position; shares: bigint; supply: bigint }
  steps: FlowStep[]
  defs: Partial<Record<StepKind, StepDef>>
  verb: string
}

function revertMessage(err: unknown, model: VaultModel): string {
  if (!(err instanceof SimulatedRevert)) throw err
  const [x, y] = err.args
  switch (err.errorName) {
    case 'HealthFactorBelowMinimum':
      return `The position would end at a health factor of ${formatHealth(x)}, below the exit line of ${formatHealth(y)}.`
    case 'BorrowCapExceeded':
      return "This would take Aave's WETH borrow cap past its limit."
    case 'SupplyCapExceeded':
      return "This would take Aave's WETH supply cap past its limit."
    case 'FlashLiquidity':
      return `The loop needs a ${formatWeth(x)} WETH flash loan; the PoolManager holds ${formatWeth(y)}.`
    case 'AaveLiquidity':
      return `Aave can pay out ${formatWeth(y)} WETH right now, less than the ${formatWeth(x)} this needs.`
    case 'ReserveFrozen':
      return 'Aave has frozen the WETH reserve: no new supply or borrows until it is unfrozen. Withdrawals still work.'
    case 'ReservePaused':
      return 'Aave has paused the WETH reserve: nothing moves in or out until it is unpaused.'
    case 'ReserveInactive':
      return 'The WETH reserve is inactive on Aave.'
    case 'BorrowingNotEnabled':
      return 'Borrowing WETH is disabled on Aave right now, so the loop cannot be built.'
    case 'ERC4626ExceededMaxWithdraw':
      return `More than the ${formatWeth(y, 6)} WETH your shares are worth.`
    case 'VaultInEmergency':
      return 'Deposits are closed while the vault is in emergency mode.'
    case 'StrategyInEmergency':
      return 'The strategy is in emergency mode.'
    case 'NotWhitelisted':
      return 'Join the whitelist first.'
    case 'WithdrawExceedsEquity':
      return `The strategy holds ${formatWeth(y)} WETH of equity, less than the ${formatWeth(x)} this needs.`
    default:
      return `This would revert in the ${model.position.debt > 0n ? 'loop' : 'vault'} (${err.errorName}).`
  }
}

function positionRows(before: Position, after: Position): Row[] {
  const rows: Row[] = [
    { label: 'Strategy collateral', before: formatWeth(before.collateral), after: formatWeth(after.collateral) },
    { label: 'Strategy debt', before: formatWeth(before.debt), after: formatWeth(after.debt) },
  ]
  if (before.idle !== after.idle) rows.push({ label: 'Idle WETH in the strategy', before: formatWeth(before.idle), after: formatWeth(after.idle) })
  rows.push({ label: 'Health factor', before: formatHealth(before.healthFactor), after: formatHealth(after.healthFactor) })
  return rows
}

function depositBlocked(model: VaultModel, acc: AccountView): string | undefined {
  // Joining is a step of the flow while DemoOperator holds the owner role
  const joinable = acc.data.whitelisted || model.shock.ownsRoles
  switch (depositClosedReason(model.state, joinable, model.chainTime)) {
    case null:
      return undefined
    case 'emergency':
      return 'Deposits are closed while the vault is in emergency mode. Anyone can reopen it from the stress test.'
    case 'whitelist':
      return 'This address is not on the whitelist, and the demo operator no longer holds the owner role, so only the owner can add it.'
    case 'strategy':
      return 'The strategy is in emergency mode. Anyone can reopen it from the stress test.'
    case 'belowTrip':
      return 'Deposits are closed: the health factor is below the exit line, so an investment would revert. Anyone can run the exit, or reset the line if a stress test raised it, from the stress test.'
    case 'margin':
      return `Deposits are closed: the health factor sits within ${formatBps(model.state.strategy.params.marginBps)} of the exit line, where maxDeposit() reports 0 to cover Aave's rounding. The stress test (push, exit, reopen, loop again) rebuilds the position at the re-entry line.`
    case 'slice':
      return 'Deposits are closed: a slice at the target leverage would start below the exit line.'
  }
}

function inYear(model: VaultModel, value: bigint, after: Position, afterEquity: bigint): Row | null {
  const y = yieldBreakdown(after, afterEquity, model.supplyRate, model.borrowRate)
  if (!y) return null
  return { label: "In a year at today's rates", after: `≈ ${formatWeth(projectYear(value, y.net))} WETH`, tone: y.net < 0n ? 'danger' : undefined }
}

function buildPlan(model: VaultModel, acc: AccountView, tab: Tab, a: bigint, usedMax: boolean, asset: Asset, account: `0x${string}`): Plan {
  const d = model.deployment
  const t = model.chainTime
  const s: State = model.state
  const before = model.positionAtChain
  const eth = acc.data.eth ?? 0n

  if (tab === 'deposit') {
    const spendable = asset === 'ETH' ? (eth > GAS_RESERVE ? eth - GAS_RESERVE : 0n) : acc.data.weth
    const room = model.depositRoom
    const blocked = depositBlocked(model, acc)
    const rows: Row[] = []
    let error: string | undefined
    let hood: Plan['hood']
    let preview: Plan['preview']
    if (!blocked && a > spendable)
      error = asset === 'ETH' ? `More than your ETH, less ${formatWeth(GAS_RESERVE)} kept for gas.` : 'More than your WETH balance. Pay with ETH to wrap it in the same flow.'
    if (!blocked && !error && a > 0n) {
      try {
        // The flow joins the whitelist before it deposits, so the preview assumes it
        const res = simulateDeposit(s, a, true, t)
        const after = position(res.state, t)
        const shares = acc.shares + res.shares
        const value = vaultToAssets(res.state, shares, t, 'floor')
        rows.push({ label: 'You receive', after: `${formatWeth(res.shares)} YBV` })
        rows.push({ label: 'Your position', before: formatWeth(acc.assetsAtChain), after: `${formatWeth(value)} WETH` })
        const year = inYear(model, value, after, after.collateral + after.idle - after.debt)
        if (year) rows.push(year)
        rows.push({ label: 'Safety after', before: formatHealth(before.healthFactor), after: formatHealth(after.healthFactor) })
        hood = {
          note: res.invested
            ? `In one transaction: a ${formatWeth(a * (s.strategy.params.targetLeverage - 1n))} WETH flash loan from the Uniswap V4 PoolManager (no fee), ${formatWeth(a * s.strategy.params.targetLeverage)} WETH supplied to Aave, and WETH borrowed from Aave to repay the flash loan.`
            : `Below ${formatWeth(s.strategy.params.minInvestAssets, 6)} WETH the strategy keeps a deposit idle; reinvest() loops it later.`,
          rows: [...positionRows(before, after), { label: 'Shares, previewDeposit()', after: formatWeth(res.shares, 6) }],
        }
        preview = { after, shares, supply: res.state.vault.totalSupply }
      } catch (err) {
        error = revertMessage(err, model)
      }
    }
    const x = toInput(a, 18)
    return {
      symbol: asset,
      max: spendable < room ? spendable : room,
      balanceLabel: `Fits now: up to ${formatWeth(room, 2)}`,
      blocked,
      error,
      hint: asset === 'ETH' ? `Max keeps ${formatWeth(GAS_RESERVE)} ETH back for gas.` : undefined,
      rows,
      hood,
      preview,
      steps: depositSteps({ payWith: asset, whitelisted: acc.data.whitelisted, allowance: acc.data.allowance, amount: a }),
      defs: {
        join: {
          name: 'Join the whitelist',
          what: acc.data.whitelisted ? 'Done. The vault only issues shares to listed addresses.' : 'The vault only issues shares to listed addresses; the demo operator adds yours.',
          label: 'Join the whitelist',
          done: 'Whitelisted',
          call: () => ({ address: d.operator, abi: operatorAbi, functionName: 'join' }),
        },
        wrap: {
          name: a > 0n ? `Wrap ${x} ETH into WETH` : 'Wrap ETH into WETH',
          what: 'The WETH contract, deposit(): one WETH for each ETH.',
          label: 'Wrap ETH',
          done: 'ETH wrapped',
          call: () => ({ address: d.weth, abi: wethAbi, functionName: 'deposit', value: a }),
        },
        approve: {
          name: 'Approve the vault',
          what: a > 0n && acc.data.allowance >= a ? 'Done. The vault may already pull this amount.' : a > 0n ? `Lets the vault pull exactly ${x} WETH.` : 'Lets the vault pull exactly the amount you deposit.',
          label: 'Approve WETH',
          done: 'WETH approved',
          call: () => ({ address: d.weth, abi: wethAbi, functionName: 'approve', args: [d.vault, a] }),
        },
        deposit: {
          name: 'Deposit',
          what: 'The vault mints your shares and the strategy loops the WETH, in the same transaction.',
          label: 'Deposit WETH',
          done: 'WETH deposited',
          call: () => ({ address: d.vault, abi: vaultCallAbi, functionName: 'deposit', args: [a, account] }),
        },
      },
      verb: `Deposit ${x} ${asset}`,
    }
  }

  const redeemAll = usedMax && acc.maxRedeem > 0n
  const rows: Row[] = []
  let error: string | undefined
  let hood: Plan['hood']
  let preview: Plan['preview']
  let expected = a
  let what = 'Paid from idle WETH, or from your share of the position with a flash loan.'
  const blocked = acc.shares === 0n ? 'You hold no vault shares.' : undefined
  if (!blocked && !redeemAll && a > acc.maxWithdraw) error = `More than you can withdraw right now: ${formatWeth(acc.maxWithdraw, 6)} WETH. Max redeems your shares instead.`
  if (!blocked && !error && (a > 0n || redeemAll)) {
    try {
      const res = redeemAll ? simulateRedeem(s, acc.maxRedeem, acc.shares, t) : simulateWithdraw(s, a, acc.shares, t)
      const after = position(res.state, t)
      const shares = acc.shares - res.shares
      expected = res.assets
      rows.push({ label: 'You receive', after: `${formatWeth(res.assets)} ${asset}` })
      rows.push({ label: 'Your position', before: formatWeth(acc.assetsAtChain), after: `${formatWeth(vaultToAssets(res.state, shares, t, 'floor'))} WETH` })
      rows.push({ label: 'Safety after', before: formatHealth(before.healthFactor), after: formatHealth(after.healthFactor) })
      const note =
        res.flashLoan > 0n
          ? res.fullClose
            ? `Closes the whole position: a ${formatWeth(res.flashLoan)} WETH flash loan repays all the debt, ${formatWeth(res.collateralWithdrawn)} WETH of collateral comes out, and what is left above your withdrawal stays idle in the strategy.`
            : `A ${formatWeth(res.flashLoan)} WETH flash loan repays that much debt and ${formatWeth(res.collateralWithdrawn)} WETH of collateral comes out, so the remaining position keeps its leverage.`
          : 'Paid from idle WETH, without touching Aave.'
      what = res.flashLoan > 0n ? 'A flash loan repays your share of the debt and your share of the equity comes out, in one transaction.' : note
      hood = { note, rows: positionRows(before, after) }
      preview = { after, shares, supply: res.state.vault.totalSupply }
    } catch (err) {
      error = revertMessage(err, model)
    }
  }
  return {
    symbol: 'WETH',
    max: acc.maxWithdraw,
    balanceLabel: `Withdrawable ${formatWeth(acc.maxWithdraw)} WETH`,
    blocked,
    error,
    hint: redeemAll
      ? `Max redeems ${acc.maxRedeem === acc.shares ? 'all your shares' : 'the shares the vault can pay now'}. Equity shrinks every second at current rates, so redeeming shares avoids asking for an amount that is gone by the time the call lands.`
      : acc.maxWithdraw < acc.assetsAtChain && acc.shares > 0n
        ? 'Capped by what Aave and the PoolManager can pay out right now.'
        : undefined,
    rows,
    hood,
    preview,
    steps: withdrawSteps({ redeemAll, receive: asset }),
    defs: {
      withdraw: {
        name: `Withdraw ${toInput(a, 18)} WETH`,
        what,
        label: 'Withdraw WETH',
        done: 'WETH withdrawn',
        call: () => ({ address: d.vault, abi: vaultCallAbi, functionName: 'withdraw', args: [a, account, account] }),
      },
      redeem: {
        name: 'Redeem all shares',
        what,
        label: 'Redeem shares',
        done: 'Shares redeemed',
        call: () => ({ address: d.vault, abi: vaultCallAbi, functionName: 'redeem', args: [acc.maxRedeem, account, account] }),
      },
      unwrap: {
        name: 'Unwrap into ETH',
        what: 'The WETH contract, withdraw(): one ETH for each WETH received.',
        label: 'Unwrap WETH',
        done: 'WETH unwrapped',
        call: async () => {
          // The redeemed amount is only known once it lands, so the unwrap never asks for more than the wallet holds
          const balance = (await readContract(wagmiConfig, { address: d.weth, abi: wethAbi, functionName: 'balanceOf', args: [account] })) as bigint
          return { address: d.weth, abi: wethAbi, functionName: 'withdraw', args: [expected < balance ? expected : balance] }
        },
      },
    },
    verb: redeemAll ? 'Redeem all shares' : `Withdraw ${toInput(a, 18)} WETH`,
  }
}

/* ------------------------------------------------------------------ */
/* Action panel                                                        */
/* ------------------------------------------------------------------ */

function Stepper({ plan, completed, active }: { plan: Plan; completed: StepKind[]; active: StepKind | null }) {
  const pending = plan.steps.filter((s) => !s.done)
  let nextShown = false
  return (
    <ol className="stepper" aria-label="Transactions">
      {plan.steps.map((s) => {
        const def = plan.defs[s.kind]!
        const done = s.done || completed.includes(s.kind)
        let state = done ? 'done' : s.kind === active ? 'active' : 'pending'
        if (state === 'pending' && !active && !nextShown) {
          state = 'next'
          nextShown = true
        }
        const index = pending.findIndex((p) => p.kind === s.kind)
        return (
          <li key={s.kind} data-state={state}>
            <span className="dot" aria-hidden="true">
              {done ? '✓' : index + 1}
            </span>
            <span>
              <span className="name">{def.name}</span>
              <span className="what">{def.what}</span>
            </span>
            <span className="tag">{done ? 'done' : state === 'active' ? 'in wallet' : `tx ${index + 1} of ${pending.length}`}</span>
          </li>
        )
      })}
    </ol>
  )
}

function ActionCard({ model, acc }: { model: VaultModel; acc: AccountView }) {
  const [tab, setTab] = useState<Tab>('deposit')
  const [input, setInput] = useState('')
  const [usedMax, setUsedMax] = useState(false)
  const [payWith, setPayWith] = useState<Asset>(acc.data.weth > 0n ? 'WETH' : 'ETH')
  const [receive, setReceive] = useState<Asset>('WETH')
  // While a flow runs, the plan it started from stays on screen: each landed step changes the balances it was built on
  const [frozen, setFrozen] = useState<Plan | null>(null)
  const [completed, setCompleted] = useState<StepKind[]>([])
  const [active, setActive] = useState<StepKind | null>(null)
  const { run } = useTx()
  const { address } = useConnection()
  const setPreview = useSetPreview()
  const amount = parseAmount(input, 18)
  const asset = tab === 'deposit' ? payWith : receive
  const live = buildPlan(model, acc, tab, amount ?? 0n, usedMax, asset, address!)
  const plan = frozen ?? live
  const running = frozen !== null
  const invalidInput = input !== '' && amount === null
  const noGas = acc.data.eth === 0n
  const hasAmount = (!!amount && amount > 0n) || (tab === 'withdraw' && usedMax && acc.maxRedeem > 0n)
  const canSubmit = hasAmount && !plan.blocked && !plan.error && !running && !noGas && model.chainKnown
  const pending = plan.steps.filter((s) => !s.done)

  const previewAfter = hasAmount && !plan.blocked && !plan.error ? plan.preview : undefined
  const previewLabel = tab === 'deposit' ? 'this deposit' : 'this withdrawal'
  useEffect(() => {
    setPreview(previewAfter ? { label: previewLabel, after: previewAfter.after, share: { shares: previewAfter.shares, supply: previewAfter.supply } } : null)
  }, [previewAfter, previewLabel, setPreview])
  useEffect(() => () => setPreview(null), [setPreview])

  const reset = () => {
    setInput('')
    setUsedMax(false)
  }

  const submit = async () => {
    if (!address || !hasAmount) return
    const steps = plan.steps.filter((s) => !s.done)
    setFrozen(plan)
    setCompleted([])
    for (let i = 0; i < steps.length; i++) {
      const def = plan.defs[steps[i].kind]!
      setActive(steps[i].kind)
      const ok = await run(def.label, def.done, def.call, { afterApproval: i > 0, quiet: i < steps.length - 1 })
      if (!ok) break
      setCompleted((c) => [...c, steps[i].kind])
      if (i === steps.length - 1) reset()
    }
    setActive(null)
    setFrozen(null)
    setCompleted([])
  }

  const assetChoice = (value: Asset, set: (a: Asset) => void, label: string) => (
    <div className="field">
      <div className="field-label">
        <span>{label}</span>
        {tab === 'deposit' ? (
          <span>
            Wallet {acc.data.eth !== undefined ? formatWeth(acc.data.eth) : '…'} ETH · {formatWeth(acc.data.weth)} WETH
          </span>
        ) : null}
      </div>
      <div className="choice" role="group" aria-label={label}>
        {(['ETH', 'WETH'] as const).map((x) => (
          <button
            key={x}
            className="chip"
            aria-pressed={value === x}
            disabled={running}
            onClick={() => {
              set(x)
              setUsedMax(false)
            }}
          >
            {x}
          </button>
        ))}
      </div>
    </div>
  )

  return (
    <div className="card">
      <div className="tabs" role="tablist" aria-label="Action">
        {(['deposit', 'withdraw'] as const).map((t) => (
          <button
            key={t}
            role="tab"
            className="tab"
            aria-selected={tab === t}
            disabled={running}
            onClick={() => {
              setTab(t)
              reset()
            }}
          >
            {t === 'deposit' ? 'Deposit' : 'Withdraw'}
          </button>
        ))}
      </div>

      <div className="action" role="tabpanel">
        {tab === 'deposit' ? assetChoice(payWith, setPayWith, 'Pay with') : null}

        <div className="field">
          <label className="field-label" htmlFor="amount">
            <span>Amount</span>
            <span>{plan.balanceLabel}</span>
          </label>
          <div className="input-wrap" data-invalid={invalidInput || (hasAmount && !!(plan.blocked ?? plan.error))}>
            <input
              id="amount"
              className="amount-input"
              inputMode="decimal"
              autoComplete="off"
              placeholder="0.00"
              value={input}
              disabled={running}
              onChange={(e) => {
                setInput(e.target.value)
                setUsedMax(false)
              }}
            />
            <span className="unit">{tab === 'deposit' ? payWith : 'WETH'}</span>
            <button
              className="max"
              disabled={plan.max === 0n || running}
              onClick={() => {
                setInput(toInput(tab === 'withdraw' ? previewRedeem(model.state, acc.maxRedeem, model.chainTime) : plan.max, 18))
                setUsedMax(true)
              }}
            >
              Max
            </button>
          </div>
          {invalidInput ? (
            <span className="hint" data-tone="danger">
              Enter a number with at most 18 decimals.
            </span>
          ) : null}
          {plan.blocked || (plan.error && hasAmount) ? (
            <span className="hint" data-tone="danger">
              {plan.blocked ?? plan.error}
            </span>
          ) : null}
          {plan.hint && usedMax ? <span className="hint">{plan.hint}</span> : null}
        </div>

        {tab === 'withdraw' ? assetChoice(receive, setReceive, 'Receive as') : null}

        {hasAmount && !plan.blocked && !plan.error && plan.rows.length > 0 ? (
          <dl className="rows">
            {plan.rows.map((r) => (
              <div className="row" key={r.label}>
                <dt>{r.label}</dt>
                <dd className={r.tone === 'danger' ? 'tone-danger' : undefined}>
                  {r.before !== undefined ? (
                    <>
                      <span className="faint">{r.before}</span>
                      <span className="arrow">→</span>
                    </>
                  ) : null}
                  {r.after}
                </dd>
              </div>
            ))}
          </dl>
        ) : null}

        {!plan.blocked ? <Stepper plan={plan} completed={completed} active={active} /> : null}

        {noGas ? (
          <div className="callout" data-tone="warn">
            Your wallet has no {chain.name} ETH for gas. Get some from a{' '}
            <a href={links.ethFaucet} target="_blank" rel="noreferrer">
              faucet
            </a>
            .
          </div>
        ) : null}

        <button className="btn btn-primary btn-block" disabled={!canSubmit} onClick={submit}>
          {running && active ? `${plan.defs[active]!.label}…` : hasAmount ? plan.verb : 'Enter an amount'}
        </button>
        {pending.length > 1 && canSubmit ? <p className="hint">{pending.length} transactions: your wallet asks for each one in turn.</p> : null}

        {plan.hood && hasAmount && !plan.blocked && !plan.error ? (
          <details className="hood">
            <summary>Under the hood</summary>
            <div className="hood-body">
              <p>{plan.hood.note}</p>
              <dl className="rows">
                {plan.hood.rows.map((r) => (
                  <div className="row" key={r.label}>
                    <dt>{r.label}</dt>
                    <dd>
                      {r.before !== undefined ? (
                        <>
                          <span className="faint">{r.before}</span>
                          <span className="arrow">→</span>
                        </>
                      ) : null}
                      {r.after}
                    </dd>
                  </div>
                ))}
              </dl>
            </div>
          </details>
        ) : null}
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* First visit                                                         */
/* ------------------------------------------------------------------ */

function GetStarted({ model }: { model: VaultModel }) {
  return (
    <div className="card">
      <div className="card-title">
        <h3>Try the loop in a few minutes</h3>
      </div>
      <div className="flow">
        <div className="flow-step">
          <b>1</b>
          <span>
            Get a little {chain.name} ETH from a{' '}
            <a href={links.ethFaucet} target="_blank" rel="noreferrer">
              faucet
            </a>
            .
          </span>
        </div>
        <div className="flow-step">
          <b>2</b>
          <span>Connect your wallet.</span>
        </div>
        <div className="flow-step">
          <b>3</b>
          <span>
            Deposit some ETH. The panel joins the whitelist, wraps, approves and deposits, and the strategy loops it{' '}
            {model.live.strategy.targetLeverage.toString()} times on Aave.
          </span>
        </div>
        <div className="flow-step">
          <b>4</b>
          <span>
            Run the <Link href="/stress-test">stress test</Link>: watch the vault exit before liquidation, then bring it back.
          </span>
        </div>
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Side column                                                         */
/* ------------------------------------------------------------------ */

/** The vault page's right column: the visitor's position and the action panel, in view while the left column scrolls. */
export function AccountSide({ model, onConnect, onFaucet }: { model: VaultModel; onConnect: () => void; onFaucet: () => void }) {
  const { status, chainId } = useConnection()
  const acc = model.account

  if (status !== 'connected') {
    return (
      <>
        <div className="card">
          <div className="card-title">
            <h2>Your position</h2>
          </div>
          <div className="empty">
            <p>
              <strong>Connect a wallet to deposit or withdraw.</strong> You can read the whole vault without one.
            </p>
            <p>The vault takes {chain.name} WETH; the panel wraps ETH for you. Get test ETH from a faucet.</p>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              <button className="btn btn-primary" onClick={onConnect}>
                Connect wallet
              </button>
              <button className="btn" onClick={onFaucet}>
                Get test ETH
              </button>
            </div>
          </div>
        </div>
        <GetStarted model={model} />
      </>
    )
  }

  if (chainId !== chain.id || !acc) {
    return (
      <div className="card">
        <div className="card-title">
          <h2>Your position</h2>
        </div>
        <p className="muted">{chainId !== chain.id ? `Your wallet is on another network. Switch to ${chain.name} from the button at the top.` : 'Reading your position…'}</p>
      </div>
    )
  }

  return (
    <>
      <PositionCard model={model} acc={acc} />
      <ActionCard model={model} acc={acc} />
    </>
  )
}
