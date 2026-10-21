import { useEffect, useMemo, useState } from 'react'
import { useConnection } from 'wagmi'
import { chain, links } from '../config/chain'
import { useSetPreview } from '../hooks/usePreview'
import { useTx, type ContractCall } from '../hooks/useTx'
import { operatorAbi, vaultCallAbi, wethAbi } from '../lib/abi'
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
  type Position,
  type State,
} from '../lib/vault'
import { Link } from './Sections'

/** Ether kept back when wrapping everything, for gas. Base Sepolia gas costs far less, but the wallet needs some. */
const GAS_RESERVE = 10n ** 14n

/* ------------------------------------------------------------------ */
/* Position summary                                                    */
/* ------------------------------------------------------------------ */

function PositionSummary({ model, acc }: { model: VaultModel; acc: AccountView }) {
  const supply = model.live.vault.totalSupply
  const sharePct = supply > 0n ? (acc.shares * 10n ** 18n) / supply : 0n
  const p = model.position
  const slice = (x: bigint) => (supply > 0n ? (x * acc.shares) / supply : 0n)
  return (
    <>
      <div className="position-main">
        <span className="position-state">{acc.shares > 0n ? 'Your shares are worth' : 'No vault shares yet'}</span>
        <span className="position-amount">
          {formatWeth(acc.assets, 6)}
          <small>WETH</small>
        </span>
        <span className="hint">
          {acc.shares > 0n
            ? `${formatWeth(acc.shares, 6)} YBV, ${formatPct(sharePct)} of the vault. The value moves every second with Aave's interest.`
            : 'Deposit WETH and the strategy loops it at the target leverage in the same transaction.'}
        </span>
      </div>
      <dl className="rows">
        {acc.shares > 0n ? (
          <>
            <div className="row">
              <dt>Your slice of the collateral and debt</dt>
              <dd>
                {formatWeth(slice(p.collateral))} <span className="faint">/</span> {formatWeth(slice(p.debt))}
              </dd>
            </div>
            <div className="row">
              <dt>Withdrawable now</dt>
              <dd>{formatWeth(acc.maxWithdraw, 6)} WETH</dd>
            </div>
          </>
        ) : null}
        <div className="row">
          <dt>Wallet</dt>
          <dd>
            {formatWeth(acc.data.weth)} WETH <span className="faint">·</span> {acc.data.eth !== undefined ? formatWeth(acc.data.eth) : '…'} ETH
          </dd>
        </div>
      </dl>
    </>
  )
}

/* ------------------------------------------------------------------ */
/* Action plans                                                        */
/* ------------------------------------------------------------------ */

type Tab = 'deposit' | 'withdraw' | 'wrap'

const tabs: { id: Tab; label: string }[] = [
  { id: 'deposit', label: 'Deposit' },
  { id: 'withdraw', label: 'Withdraw' },
  { id: 'wrap', label: 'Wrap ETH' },
]

interface Row {
  label: string
  before: string
  after: string
}

interface Plan {
  symbol: 'WETH' | 'ETH'
  max: bigint
  maxLabel: string
  maxHint?: string
  /** Allowance the call needs from the vault, if it pulls WETH */
  approve?: { current: bigint; needed: bigint }
  /** Why the action is closed whatever the amount */
  blocked?: string
  error?: string
  note?: string
  rows: Row[]
  after?: Position
  verb: string
  done: string
  call: () => ContractCall
}

function revertMessage(err: unknown, model: VaultModel): string {
  if (!(err instanceof SimulatedRevert)) throw err
  const [x, y] = err.args
  switch (err.errorName) {
    case 'HealthFactorBelowMinimum':
      return `The position would end at a health factor of ${formatHealth(x)}, below the trip threshold of ${formatHealth(y)}.`
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
  switch (depositClosedReason(model.state, acc.data.whitelisted, model.chainTime)) {
    case null:
      return undefined
    case 'emergency':
      return 'Deposits are closed while the vault is in emergency mode. Anyone can restore it on the Emergency page.'
    case 'whitelist':
      return 'Join the whitelist first, from the button above.'
    case 'strategy':
      return 'The strategy is in emergency mode. Anyone can restore it on the Emergency page.'
    case 'belowTrip':
      return 'Deposits are closed: the health factor is below the trip threshold, so an investment would revert. Anyone can call checkHealth() on the Emergency page, or restore the thresholds if a shock raised them.'
    case 'margin':
      return `Deposits are closed: the health factor sits within ${formatBps(model.state.strategy.params.marginBps)} of the trip threshold, where maxDeposit() reports 0 to cover Aave's rounding, although checkHealth() would not trip yet. The emergency cycle (shock, checkHealth, restore, reinvest) rebuilds the position at the re-arm threshold.`
    case 'slice':
      return 'Deposits are closed: a slice at the target leverage would start below the trip threshold.'
  }
}

function useActionPlan(model: VaultModel, acc: AccountView, tab: Tab, amount: bigint | null, usedMax: boolean, unwrap: boolean, account: `0x${string}`): Plan {
  const d = model.deployment
  const t = model.chainTime
  const s: State = model.state
  const before = model.positionAtChain
  const a = amount ?? 0n

  switch (tab) {
    case 'deposit': {
      const wallet = acc.data.weth
      const rows: Row[] = []
      const blocked = depositBlocked(model, acc)
      let error: string | undefined
      let after: Position | undefined
      let note: string | undefined
      if (!blocked && a > wallet) error = 'More than your WETH balance. Wrap ETH first, in the Wrap ETH tab.'
      if (!blocked && !error && a > 0n) {
        try {
          const res = simulateDeposit(s, a, acc.data.whitelisted, t)
          after = position(res.state, t)
          rows.push({ label: 'Your shares', before: formatWeth(acc.shares, 6), after: formatWeth(acc.shares + res.shares, 6) })
          rows.push(...positionRows(before, after))
          note = res.invested
            ? `In the same transaction: a ${formatWeth(a * (s.strategy.params.targetLeverage - 1n))} WETH flash loan from the Uniswap V4 PoolManager, ${formatWeth(a * s.strategy.params.targetLeverage)} WETH supplied to Aave and the flash loan repaid with WETH borrowed from Aave.`
            : `Below ${formatWeth(s.strategy.params.minInvestAssets, 6)} WETH the strategy keeps a deposit idle; reinvest() loops it later.`
        } catch (err) {
          error = revertMessage(err, model)
        }
      }
      return {
        symbol: 'WETH',
        max: wallet,
        maxLabel: `Wallet ${formatWeth(wallet)} WETH`,
        maxHint:
          model.depositRoom < wallet && !blocked
            ? `Aave's caps and the PoolManager's WETH leave room for about ${formatWeth(model.depositRoom)} WETH of deposits right now. Both are shared with other testnet users.`
            : undefined,
        approve: { current: acc.data.allowance, needed: a },
        blocked,
        error,
        note,
        rows,
        after,
        verb: 'Deposit WETH',
        done: 'WETH deposited',
        call: () => ({ address: d.vault, abi: vaultCallAbi, functionName: 'deposit', args: [a, account] }),
      }
    }
    case 'withdraw': {
      const redeemAll = usedMax && acc.maxRedeem > 0n
      const rows: Row[] = []
      let error: string | undefined
      let note: string | undefined
      let after: Position | undefined
      const blocked = acc.shares === 0n ? 'You hold no vault shares.' : undefined
      if (!blocked && !redeemAll && a > acc.maxWithdraw) error = `More than you can withdraw right now: ${formatWeth(acc.maxWithdraw, 6)} WETH. Max redeems your shares instead.`
      if (!blocked && !error && (a > 0n || redeemAll)) {
        try {
          const res = redeemAll ? simulateRedeem(s, acc.maxRedeem, acc.shares, t) : simulateWithdraw(s, a, acc.shares, t)
          after = position(res.state, t)
          rows.push({ label: 'Your shares', before: formatWeth(acc.shares, 6), after: formatWeth(acc.shares - res.shares, 6) })
          rows.push({ label: 'WETH to your wallet', before: formatWeth(acc.data.weth), after: formatWeth(acc.data.weth + res.assets) })
          rows.push(...positionRows(before, after))
          note =
            res.flashLoan > 0n
              ? res.fullClose
                ? `Closes the whole position: a ${formatWeth(res.flashLoan)} WETH flash loan repays all the debt, ${formatWeth(res.collateralWithdrawn)} WETH of collateral comes out, and what is left above your withdrawal stays idle in the strategy.`
                : `A ${formatWeth(res.flashLoan)} WETH flash loan repays that much debt and ${formatWeth(res.collateralWithdrawn)} WETH of collateral comes out, so the remaining position keeps its leverage.`
              : 'Paid from idle WETH, without touching Aave.'
        } catch (err) {
          error = revertMessage(err, model)
        }
      }
      const shown = redeemAll ? previewRedeem(s, acc.maxRedeem, t) : a
      return {
        symbol: 'WETH',
        max: acc.maxWithdraw,
        maxLabel: `Withdrawable ${formatWeth(acc.maxWithdraw)} WETH`,
        maxHint: redeemAll
          ? `Max redeems ${acc.maxRedeem === acc.shares ? 'all your shares' : 'the shares the vault can pay now'} for about ${formatWeth(shown, 6)} WETH at the latest block. Equity shrinks every second at current rates, so redeeming shares avoids asking for an amount that is gone by the time the call lands.`
          : acc.maxWithdraw < acc.assetsAtChain && acc.shares > 0n
            ? 'Capped by what Aave and the PoolManager can pay out right now.'
            : undefined,
        blocked,
        error,
        note,
        rows,
        after,
        verb: redeemAll ? 'Redeem shares' : 'Withdraw WETH',
        done: redeemAll ? 'Shares redeemed' : 'WETH withdrawn',
        call: () =>
          redeemAll
            ? { address: d.vault, abi: vaultCallAbi, functionName: 'redeem', args: [acc.maxRedeem, account, account] }
            : { address: d.vault, abi: vaultCallAbi, functionName: 'withdraw', args: [a, account, account] },
      }
    }
    case 'wrap': {
      const eth = acc.data.eth ?? 0n
      if (unwrap) {
        const wallet = acc.data.weth
        return {
          symbol: 'WETH',
          max: wallet,
          maxLabel: `Wallet ${formatWeth(wallet)} WETH`,
          error: a > wallet ? 'More than your WETH balance.' : undefined,
          rows: a > 0n ? [{ label: 'ETH in your wallet', before: formatWeth(eth), after: formatWeth(eth + a) }] : [],
          verb: 'Unwrap WETH',
          done: 'WETH unwrapped',
          call: () => ({ address: d.weth, abi: wethAbi, functionName: 'withdraw', args: [a] }),
        }
      }
      const max = eth > GAS_RESERVE ? eth - GAS_RESERVE : 0n
      return {
        symbol: 'ETH',
        max,
        maxLabel: `Wallet ${formatWeth(eth)} ETH`,
        maxHint: `Max keeps ${formatWeth(GAS_RESERVE)} ETH back for gas.`,
        error: a > eth ? 'More than your ETH balance.' : undefined,
        rows: a > 0n ? [{ label: 'WETH in your wallet', before: formatWeth(acc.data.weth), after: formatWeth(acc.data.weth + a) }] : [],
        verb: 'Wrap ETH',
        done: 'ETH wrapped',
        call: () => ({ address: d.weth, abi: wethAbi, functionName: 'deposit', value: a }),
      }
    }
  }
}

/* ------------------------------------------------------------------ */
/* Actions                                                             */
/* ------------------------------------------------------------------ */

function Actions({ model, acc }: { model: VaultModel; acc: AccountView }) {
  const [tab, setTab] = useState<Tab>(acc.shares > 0n ? 'withdraw' : acc.data.weth > 0n ? 'deposit' : 'wrap')
  const [input, setInput] = useState('')
  const [usedMax, setUsedMax] = useState(false)
  const [unwrap, setUnwrap] = useState(false)
  const { run, busy } = useTx()
  const { address } = useConnection()
  const setPreview = useSetPreview()
  const amount = parseAmount(input, 18)
  const plan = useActionPlan(model, acc, tab, amount, usedMax, unwrap, address!)
  const invalidInput = input !== '' && amount === null
  const noGas = acc.data.eth === 0n
  const hasAmount = (!!amount && amount > 0n) || (tab === 'withdraw' && usedMax && acc.maxRedeem > 0n)
  const needsApproval = !!plan.approve && !!amount && plan.approve.current < plan.approve.needed
  const canSubmit = hasAmount && !plan.blocked && !plan.error && !busy && !noGas && model.chainKnown

  const previewAfter = hasAmount && !plan.blocked && !plan.error ? plan.after : undefined
  const previewLabel = tab === 'deposit' ? 'this deposit' : 'this withdrawal'
  useEffect(() => {
    setPreview(previewAfter ? { label: previewLabel, after: previewAfter } : null)
  }, [previewAfter, previewLabel, setPreview])
  useEffect(() => () => setPreview(null), [setPreview])

  const reset = () => {
    setInput('')
    setUsedMax(false)
  }

  const submit = async () => {
    if (!address || !hasAmount) return
    if (needsApproval && plan.approve) {
      const needed = plan.approve.needed
      const ok = await run('Approve WETH', 'WETH approved', () => ({
        address: model.deployment.weth,
        abi: wethAbi,
        functionName: 'approve',
        args: [model.deployment.vault, needed],
      }))
      if (!ok) return
    }
    const ok = await run(plan.verb, plan.done, plan.call, { afterApproval: needsApproval })
    if (ok) reset()
  }

  return (
    <div style={{ marginTop: 22 }}>
      <div className="tabs" role="tablist" aria-label="Action">
        {tabs.map((t) => (
          <button
            key={t.id}
            role="tab"
            className="tab"
            aria-selected={tab === t.id}
            onClick={() => {
              setTab(t.id)
              reset()
            }}
          >
            {t.label}
          </button>
        ))}
      </div>

      <div className="action" role="tabpanel">
        {tab === 'wrap' ? (
          <div className="choice" aria-label="Direction">
            <button className="chip" aria-pressed={!unwrap} onClick={() => (setUnwrap(false), reset())}>
              ETH to WETH
            </button>
            <button className="chip" aria-pressed={unwrap} onClick={() => (setUnwrap(true), reset())}>
              WETH to ETH
            </button>
          </div>
        ) : null}

        <div className="field">
          <label className="field-label" htmlFor="amount">
            <span>Amount</span>
            <span>{plan.maxLabel}</span>
          </label>
          <div className="input-wrap" data-invalid={invalidInput || (hasAmount && !!(plan.blocked ?? plan.error))}>
            <input
              id="amount"
              className="amount-input"
              inputMode="decimal"
              autoComplete="off"
              placeholder="0.00"
              value={input}
              onChange={(e) => {
                setInput(e.target.value)
                setUsedMax(false)
              }}
            />
            <span className="unit">{plan.symbol}</span>
            <button
              className="max"
              disabled={plan.max === 0n}
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
          {plan.maxHint ? <span className="hint">{plan.maxHint}</span> : null}
        </div>

        {plan.note && previewAfter ? <div className="callout">{plan.note}</div> : null}

        {hasAmount && !plan.blocked && !plan.error && plan.rows.length > 0 ? (
          <dl className="rows">
            {plan.rows.map((r) => (
              <div className="row" key={r.label}>
                <dt>{r.label}</dt>
                <dd>
                  <span className="faint">{r.before}</span>
                  <span className="arrow">to</span>
                  {r.after}
                </dd>
              </div>
            ))}
          </dl>
        ) : null}

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
          {busy ?? (needsApproval ? `Approve and ${plan.verb.charAt(0).toLowerCase()}${plan.verb.slice(1)}` : plan.verb)}
        </button>
        {needsApproval && canSubmit ? <p className="hint">Two transactions: an approval for this amount, then the deposit itself.</p> : null}
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Whitelist                                                           */
/* ------------------------------------------------------------------ */

function JoinWhitelist({ model }: { model: VaultModel }) {
  const { run, busy } = useTx()
  if (!model.shock.ownsRoles) {
    return (
      <div className="callout" data-tone="warn">
        This address is not on the whitelist, and the demo operator no longer holds the owner role, so only the owner can add it.
      </div>
    )
  }
  return (
    <div className="callout">
      <p style={{ marginBottom: 10 }}>
        <strong style={{ color: 'var(--ink)' }}>The vault only issues shares to whitelisted addresses.</strong> On this testnet the
        owner role sits with a demo contract that lets anyone add their own address.
      </p>
      <button
        className="btn btn-primary"
        disabled={!!busy}
        onClick={() =>
          run('Join the whitelist', 'Whitelisted', () => ({ address: model.deployment.operator, abi: operatorAbi, functionName: 'join' }))
        }
      >
        {busy ?? 'Join the whitelist'}
      </button>
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
          <span>Connect your wallet and add your address to the vault's whitelist.</span>
        </div>
        <div className="flow-step">
          <b>3</b>
          <span>
            Wrap some ETH and deposit it: the strategy loops it {model.live.strategy.targetLeverage.toString()} times on Aave in the
            same transaction.
          </span>
        </div>
        <div className="flow-step">
          <b>4</b>
          <span>
            Run the <Link href="/emergency">emergency cycle</Link>: shock the thresholds, close the position with checkHealth(),
            then restore and reinvest.
          </span>
        </div>
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Card                                                                */
/* ------------------------------------------------------------------ */

export function AccountCard({ model, onConnect, onFaucet }: { model: VaultModel; onConnect: () => void; onFaucet: () => void }) {
  const { status, chainId } = useConnection()
  const acc = model.account
  const empty = useMemo(() => !!acc && acc.shares === 0n && acc.data.weth === 0n, [acc])

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
            <p>The vault takes {chain.name} WETH. Get test ETH from a faucet, then wrap it here.</p>
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

  if (chainId !== chain.id) {
    return (
      <div className="card">
        <div className="card-title">
          <h2>Your position</h2>
        </div>
        <p className="muted">Your wallet is on another network. Switch to {chain.name} from the button at the top.</p>
      </div>
    )
  }

  if (!acc) {
    return (
      <div className="card">
        <div className="card-title">
          <h2>Your position</h2>
        </div>
        <p className="muted">Reading your position…</p>
      </div>
    )
  }

  return (
    <div className="card">
      <div className="card-title">
        <h2>Your position</h2>
        {empty ? (
          <button className="link-button" onClick={onFaucet}>
            Get test ETH
          </button>
        ) : null}
      </div>
      <PositionSummary model={model} acc={acc} />
      {!acc.data.whitelisted ? (
        <div style={{ marginTop: 18 }}>
          <JoinWhitelist model={model} />
        </div>
      ) : null}
      <Actions model={model} acc={acc} />
    </div>
  )
}
