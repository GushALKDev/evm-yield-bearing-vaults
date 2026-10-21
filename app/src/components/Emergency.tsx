import { useEffect, useMemo } from 'react'
import { useConnection } from 'wagmi'
import { chain, explorerAddress } from '../config/chain'
import { useSetPreview } from '../hooks/usePreview'
import { useTx } from '../hooks/useTx'
import { MAX_UINT256 } from '../lib/aave'
import { operatorCallAbi, strategyCallAbi } from '../lib/abi'
import { formatHealth, formatWeth, relativeTime, shortAddress } from '../lib/format'
import type { VaultModel } from '../lib/model'
import { position, simulateExit, simulateReinvest, SimulatedRevert, type Position } from '../lib/vault'
import { LoopSheet } from './Hero'

type StepState = 'done' | 'next' | 'waiting'

interface Step {
  title: string
  body: string
  preview: string
  /** Why the button is disabled, when it is */
  disabled?: string
  state: StepState
  label: string
  done: string
  run: () => { address: `0x${string}`; abi: readonly unknown[]; functionName: string }
  after?: Position
}

function useSteps(model: VaultModel): Step[] {
  const d = model.deployment
  const st = model.static
  const t = model.chainTime
  const p = model.positionAtChain
  const live = model.live
  const s = live.strategy
  const emergency = live.vault.emergency
  const { ownsRoles, shocked, nextShockAt } = model.shock
  const hasDebt = p.debt > 0n
  const unhealthy = hasDebt && p.healthFactor < s.minHealthFactor
  const idle = live.vault.idle + p.idle
  const noRoles = 'The demo operator no longer holds the vault roles.'

  // 1. Shock
  const shockMin = hasDebt ? p.healthFactor + st.shockMinOffset : 0n
  const shockTarget = hasDebt ? p.healthFactor + st.shockTargetOffset : 0n
  const shockDisabled = !ownsRoles
    ? noRoles
    : emergency
      ? 'The vault is already in emergency mode.'
      : !hasDebt
        ? 'The strategy has no debt, so there is no health factor to shock. Deposit or reinvest first.'
        : nextShockAt > t
          ? `The next shock opens in ${relativeTime(Number(nextShockAt - t))}: one per ${relativeTime(Number(st.shockCooldown))}.`
          : undefined

  // 2. checkHealth
  let exitAfter: Position | undefined
  let exitPreview = ''
  if (unhealthy) {
    try {
      const res = simulateExit(model.state, t)
      exitAfter = position(res.state, t)
      exitPreview = `Health factor ${formatHealth(p.healthFactor)} is below ${formatHealth(s.minHealthFactor)}: closes the position. A ${formatWeth(res.flashLoan)} WETH flash loan repays the debt, ${formatWeth(res.collateralWithdrawn)} WETH of collateral comes out and ${formatWeth(exitAfter.idle)} WETH stays idle in the strategy. Deposits close.`
    } catch (err) {
      if (!(err instanceof SimulatedRevert)) throw err
      exitPreview = `The exit would fail now (${err.errorName}). Emergency mode still turns on, and withdrawals deleverage proportionally.`
    }
  }
  const healthDisabled = emergency && !unhealthy
    ? 'Emergency mode is on and the position is closed: nothing to check.'
    : !unhealthy
      ? `The health factor (${formatHealth(p.healthFactor)}) is at or above the trip threshold (${formatHealth(s.minHealthFactor)}), so checkHealth() would return true and change nothing.`
      : undefined

  // 4. Reinvest
  let reinvestAfter: Position | undefined
  let reinvestPreview = ''
  let reinvestError: string | undefined
  if (!emergency) {
    try {
      const res = simulateReinvest(model.state, t)
      reinvestAfter = position(res.state, t)
      reinvestPreview =
        res.invested > 0n
          ? `Loops ${formatWeth(res.invested)} WETH of idle WETH at ${s.targetLeverage.toString()}x: collateral ${formatWeth(p.collateral)} to ${formatWeth(reinvestAfter.collateral)}, debt ${formatWeth(p.debt)} to ${formatWeth(reinvestAfter.debt)}, health factor ${formatHealth(reinvestAfter.healthFactor)}, at or above ${formatHealth(s.targetHealthFactor)}.`
          : `Nothing idle above ${formatWeth(st.minInvestAssets, 6)} WETH to loop; the call would only check the health factor against ${formatHealth(s.targetHealthFactor)}.`
    } catch (err) {
      if (!(err instanceof SimulatedRevert)) throw err
      const [a, b] = err.args
      reinvestError =
        err.errorName === 'HealthFactorBelowTarget'
          ? `The rebuilt position would sit at ${formatHealth(a)}, below the re-arm threshold of ${formatHealth(b)}, so reinvest() reverts. Restore the thresholds first.`
          : `Reinvesting would revert now (${err.errorName}).`
    }
  }

  const next: 1 | 2 | 3 | 4 = emergency ? 3 : unhealthy ? 2 : shocked ? 3 : idle >= st.minInvestAssets ? 4 : 1
  const state = (n: number): StepState => (n === next ? 'next' : n < next ? 'done' : 'waiting')

  return [
    {
      title: 'Shock the thresholds',
      body: "Raises the strategy's trip threshold above its live health factor, the way the test suite simulates an unhealthy position. On mainnet the health factor itself would fall: interest accrual or an Aave parameter change.",
      preview: hasDebt
        ? `Trip threshold ${formatHealth(s.minHealthFactor)} to ${formatHealth(shockMin)}, re-arm threshold ${formatHealth(s.targetHealthFactor)} to ${formatHealth(shockTarget)}, from a health factor of ${formatHealth(p.healthFactor)} at the latest block.`
        : 'No debt, no health factor to shock.',
      disabled: shockDisabled,
      state: state(1),
      label: 'Shock the thresholds',
      done: 'Thresholds raised',
      run: () => ({ address: d.operator, abi: operatorCallAbi, functionName: 'shock' }),
    },
    {
      title: 'Call checkHealth()',
      body: 'Permissionless, on the strategy itself. Below the trip threshold it puts the vault in emergency mode, which tries to close the whole position with one flash loan for the entire debt and keeps the equity as idle WETH.',
      preview: unhealthy ? exitPreview : `Healthy: returns true and changes nothing.`,
      disabled: healthDisabled,
      state: state(2),
      label: 'Call checkHealth()',
      done: 'checkHealth() ran',
      run: () => ({ address: d.strategy, abi: strategyCallAbi, functionName: 'checkHealth' }),
      after: exitAfter,
    },
    {
      title: 'Restore',
      body: "The first recovery step: clears emergency mode on the vault and the strategy, and puts the thresholds back to their deployment values. The idle WETH stays idle, so this step cannot fail because of Aave or Uniswap.",
      preview:
        emergency || shocked
          ? `${emergency ? 'Clears emergency mode. ' : ''}${shocked ? `Thresholds back to ${formatHealth(st.defaultMinHealthFactor)} and ${formatHealth(st.defaultTargetHealthFactor)}.` : ''}`
          : 'Nothing to restore right now.',
      disabled: !ownsRoles ? noRoles : !emergency && !shocked ? 'Emergency mode is off and the thresholds are at their deployment values.' : undefined,
      state: state(3),
      label: 'Restore',
      done: 'Restored',
      run: () => ({ address: d.operator, abi: operatorCallAbi, functionName: 'restore' }),
    },
    {
      title: 'Reinvest',
      body: 'The second step, kept separate on purpose: loops the idle WETH at the target leverage again and reverts unless the rebuilt position reaches the re-arm threshold.',
      preview: emergency ? 'Waits for restore: reinvest() reverts during emergency mode.' : (reinvestError ?? reinvestPreview),
      disabled: !ownsRoles
        ? noRoles
        : emergency
          ? 'Restore first: reinvest() reverts during emergency mode.'
          : (reinvestError ?? (idle < st.minInvestAssets ? 'Nothing idle to loop right now.' : undefined)),
      state: state(4),
      label: 'Reinvest',
      done: 'Reinvested',
      run: () => ({ address: d.operator, abi: operatorCallAbi, functionName: 'reinvest' }),
      after: reinvestAfter,
    },
  ]
}

function StatusCard({ model }: { model: VaultModel }) {
  const live = model.live
  const st = model.static
  const p = model.position
  return (
    <div className="card">
      <div className="card-title">
        <h2>State</h2>
        <span className="status" data-tone={live.vault.emergency ? 'warn' : 'ok'}>
          {live.vault.emergency ? 'Emergency mode' : 'Open for deposits'}
        </span>
      </div>
      <dl className="rows">
        <div className="row">
          <dt>Trip threshold, checkHealth()</dt>
          <dd>
            {formatHealth(live.strategy.minHealthFactor)} <span className="faint">deployed {formatHealth(st.defaultMinHealthFactor, 2)}</span>
          </dd>
        </div>
        <div className="row">
          <dt>Re-arm threshold, reinvest()</dt>
          <dd>
            {formatHealth(live.strategy.targetHealthFactor)} <span className="faint">deployed {formatHealth(st.defaultTargetHealthFactor, 2)}</span>
          </dd>
        </div>
        <div className="row">
          <dt>Position</dt>
          <dd>{p.debt > 0n ? `Open, ${formatWeth(p.debt)} WETH of debt` : p.idle > 0n ? `Closed, ${formatWeth(p.idle)} WETH idle` : 'None'}</dd>
        </div>
        <div className="row">
          <dt>Last shock</dt>
          <dd>{live.lastShockAt === 0n ? 'Never' : `${relativeTime(Number(model.now - live.lastShockAt))} ago`}</dd>
        </div>
        <div className="row">
          <dt>Owner and admin</dt>
          <dd>
            {model.shock.ownsRoles ? (
              <a href={explorerAddress(model.deployment.operator)} target="_blank" rel="noreferrer">
                DemoOperator
              </a>
            ) : (
              <span className="mono">{shortAddress(live.vault.admin)}</span>
            )}
          </dd>
        </div>
      </dl>
      <p className="hint" style={{ marginTop: 10 }}>
        Withdrawals stay open in every state. During emergency mode they are paid from the idle WETH the exit left; if the exit
        failed and the position is still open, they deleverage it proportionally.
      </p>
    </div>
  )
}

export function Emergency({ model, onConnect }: { model: VaultModel; onConnect: () => void }) {
  const steps = useSteps(model)
  const { status, chainId } = useConnection()
  const { run, busy } = useTx()
  const setPreview = useSetPreview()
  const connected = status === 'connected' && chainId === chain.id
  const nextStep = useMemo(() => steps.find((s) => s.state === 'next' && s.after && !s.disabled), [steps])
  const nextAfter = nextStep?.after
  const nextTitle = nextStep?.title
  useEffect(() => {
    setPreview(nextAfter && nextTitle ? { label: `the next step (${nextTitle.toLowerCase()})`, after: nextAfter } : null)
  }, [nextAfter, nextTitle, setPreview])
  useEffect(() => () => setPreview(null), [setPreview])
  const noDebt = model.position.healthFactor === MAX_UINT256

  return (
    <section className="section">
      <div className="wrap">
        <div className="section-head">
          <h2>Exit before liquidation, and back</h2>
          <p>
            The strategy closes its own position when Aave's health factor falls below a threshold, before Aave could liquidate it,
            and re-arms in two separate steps. On this testnet anyone can run the whole cycle on the shared vault: it moves every
            depositor's position into idle WETH and back, without losing their equity beyond rounding.
          </p>
        </div>
        <LoopSheet model={model} title="The position now" />
        <div className="two-col" style={{ marginTop: 20 }}>
          <div className="card">
            <div className="card-title">
              <h2>The cycle</h2>
              <span className="card-sub">{noDebt ? 'No open position' : `Health factor ${formatHealth(model.position.healthFactor)}`}</span>
            </div>
            <div className="cycle">
              {steps.map((s, i) => (
                <div className="cycle-step" key={s.title} data-state={s.state}>
                  <b>{i + 1}</b>
                  <div className="cycle-body">
                    <h3>{s.title}</h3>
                    <p>{s.body}</p>
                    <p className="hint" style={{ color: 'var(--ink)' }}>
                      {s.preview}
                    </p>
                    <div className="cycle-actions">
                      {connected ? (
                        <button
                          className={s.state === 'next' ? 'btn btn-primary' : 'btn'}
                          disabled={!!s.disabled || !!busy}
                          onClick={() => run(s.label, s.done, s.run)}
                        >
                          {busy === s.label ? 'Working…' : s.label}
                        </button>
                      ) : i === 0 ? (
                        <button className="btn btn-primary" onClick={onConnect}>
                          Connect a wallet to run it
                        </button>
                      ) : null}
                      {s.disabled && connected ? <span className="hint">{s.disabled}</span> : null}
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </div>
          <div className="stack">
            <StatusCard model={model} />
          </div>
        </div>
      </div>
    </section>
  )
}
