import { useEffect, useMemo } from 'react'
import { useConnection } from 'wagmi'
import { chain, explorerAddress } from '../config/chain'
import { useSetPreview } from '../hooks/usePreview'
import { useTx } from '../hooks/useTx'
import { operatorCallAbi, strategyCallAbi } from '../lib/abi'
import { formatHealth, formatWeth, relativeTime, shortAddress } from '../lib/format'
import type { VaultModel } from '../lib/model'
import { position, simulateExit, simulateReinvest, SimulatedRevert, type Position } from '../lib/vault'
import { LoopSheet } from './Loop'

type StepState = 'done' | 'next' | 'waiting'

interface Step {
  title: string
  /** One line for a collapsed step */
  summary: string
  body: string
  /** The contract call behind the button */
  code: string
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
    ? 'Emergency mode is on and the position is closed: nothing left to check.'
    : !unhealthy
      ? `The health factor (${formatHealth(p.healthFactor)}) is at or above the exit line (${formatHealth(s.minHealthFactor)}), so the check would return true and change nothing. Push the line first.`
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
          ? `The rebuilt position would sit at ${formatHealth(a)}, below the re-entry line of ${formatHealth(b)}, so reinvest() reverts. Reopen the vault first, which resets the lines.`
          : `Reinvesting would revert now (${err.errorName}).`
    }
  }

  const next: 1 | 2 | 3 | 4 = emergency ? 3 : unhealthy ? 2 : shocked ? 3 : idle >= st.minInvestAssets ? 4 : 1
  const state = (n: number): StepState => (n === next ? 'next' : n < next ? 'done' : 'waiting')

  return [
    {
      title: 'Push the exit line above the position',
      summary: "Raises the exit line above today's health factor.",
      body: "On mainnet the health factor itself would fall, through interest or an Aave parameter change. Here the line moves instead, the way the test suite does it, so the position reads as unhealthy without touching it.",
      code: 'DemoOperator.shock()',
      preview: hasDebt
        ? `Exit line ${formatHealth(s.minHealthFactor)} to ${formatHealth(shockMin)} and re-entry line ${formatHealth(s.targetHealthFactor)} to ${formatHealth(shockTarget)}, just above today's ${formatHealth(p.healthFactor)}.`
        : 'No debt, no health factor to push against.',
      disabled: shockDisabled,
      state: state(1),
      label: 'Push the line',
      done: 'Exit line raised',
      run: () => ({ address: d.operator, abi: operatorCallAbi, functionName: 'shock' }),
    },
    {
      title: 'Let the vault exit',
      summary: "Anyone calls the strategy's health check; it repays the whole debt with one flash loan and keeps the equity as idle WETH.",
      body: 'The health check is permissionless and lives on the strategy itself; the repository ships no keeper that calls it. Below the exit line it puts the vault in emergency mode and closes the whole position with one flash loan for the entire debt. Deposits close; withdrawals stay open.',
      code: 'WETHLoopStrategy.checkHealth()',
      preview: unhealthy ? exitPreview : 'Healthy: the check returns true and changes nothing.',
      disabled: healthDisabled,
      state: state(2),
      label: 'Run the health check',
      done: 'Health check ran',
      run: () => ({ address: d.strategy, abi: strategyCallAbi, functionName: 'checkHealth' }),
      after: exitAfter,
    },
    {
      title: 'Reopen the vault',
      summary: `Clears emergency mode and puts the lines back at ${formatHealth(st.defaultMinHealthFactor, 2)} and ${formatHealth(st.defaultTargetHealthFactor, 2)}. The WETH stays idle.`,
      body: 'The first of two recovery steps: it clears emergency mode on the vault and the strategy and puts both lines back to their deployment values. The idle WETH stays idle, so this step cannot fail because of Aave or Uniswap.',
      code: 'DemoOperator.restore()',
      preview:
        emergency || shocked
          ? `${emergency ? 'Clears emergency mode. ' : ''}${shocked ? `Lines back to ${formatHealth(st.defaultMinHealthFactor)} and ${formatHealth(st.defaultTargetHealthFactor)}.` : ''}`
          : 'Nothing to reopen right now.',
      disabled: !ownsRoles ? noRoles : !emergency && !shocked ? 'Emergency mode is off and the lines are at their deployment values.' : undefined,
      state: state(3),
      label: 'Reopen the vault',
      done: 'Vault reopened',
      run: () => ({ address: d.operator, abi: operatorCallAbi, functionName: 'restore' }),
    },
    {
      title: 'Loop again',
      summary: `Rebuilds the ${s.targetLeverage.toString()}x position from the idle WETH, only if it lands at the re-entry line or above.`,
      body: 'The second step, kept separate on purpose: it loops the idle WETH at the target leverage again and reverts unless the rebuilt position reaches the re-entry line, which sits above the exit line, so a recovery does not re-arm into a position the health check would close at once.',
      code: 'vault.reinvest()',
      preview: emergency ? 'Waits for the reopen step: reinvest() reverts during emergency mode.' : (reinvestError ?? reinvestPreview),
      disabled: !ownsRoles
        ? noRoles
        : emergency
          ? 'Reopen the vault first: reinvest() reverts during emergency mode.'
          : (reinvestError ?? (idle < st.minInvestAssets ? 'Nothing idle to loop right now.' : undefined)),
      state: state(4),
      label: 'Loop again',
      done: 'Position rebuilt',
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
        <h2>The vault now</h2>
        <span className="status" data-tone={live.vault.emergency ? 'warn' : 'ok'}>
          {live.vault.emergency ? 'Emergency mode' : 'Open for deposits'}
        </span>
      </div>
      <dl className="rows">
        <div className="row">
          <dt>Safety (health factor)</dt>
          <dd>{formatHealth(p.healthFactor)}</dd>
        </div>
        <div className="row">
          <dt>
            Exit line <span className="faint mono">minHealthFactor</span>
          </dt>
          <dd>
            {formatHealth(live.strategy.minHealthFactor)} <span className="faint">default {formatHealth(st.defaultMinHealthFactor, 2)}</span>
          </dd>
        </div>
        <div className="row">
          <dt>
            Re-entry line <span className="faint mono">targetHealthFactor</span>
          </dt>
          <dd>
            {formatHealth(live.strategy.targetHealthFactor)} <span className="faint">default {formatHealth(st.defaultTargetHealthFactor, 2)}</span>
          </dd>
        </div>
        <div className="row">
          <dt>Position</dt>
          <dd>{p.debt > 0n ? `Open, ${formatWeth(p.debt)} WETH of debt` : p.idle > 0n ? `Closed, ${formatWeth(p.idle)} WETH idle` : 'None'}</dd>
        </div>
        <div className="row">
          <dt>Last push</dt>
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
        Withdrawals stay open in every step: during emergency mode they are paid from the idle WETH the exit left, or
        deleverage the position proportionally if the exit failed. What can still limit them is liquidity (Aave's and the
        PoolManager's), a paused reserve or a health factor below 1, which maxWithdraw() reports.
      </p>
    </div>
  )
}

export function StressTest({ model, onConnect }: { model: VaultModel; onConnect: () => void }) {
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
  const emergency = model.live.vault.emergency

  return (
    <>
      <section className="wrap top">
        <div className="top-head">
          <div>
            <h1>Stress test: exit before liquidation, and back.</h1>
            <p className="top-sub">
              Make the position read as unhealthy, let the vault close it on its own before Aave could liquidate it, then
              bring it back. On this testnet anyone can run the cycle on the shared vault: it moves every depositor's
              position into idle WETH and back, and their equity stays theirs except for rounding.
            </p>
          </div>
          <span className="status" data-tone={emergency ? 'warn' : 'ok'}>
            {emergency ? 'Emergency mode' : 'Vault healthy'}
          </span>
        </div>
      </section>
      <div className="wrap layout">
        <div className="stack">
          <div className="card">
            <div className="cycle">
              {steps.map((s, i) => (
                <div className="cycle-step" key={s.title} data-state={s.state === 'waiting' ? 'later' : s.state}>
                  <b>{s.state === 'done' ? '✓' : i + 1}</b>
                  <div className="cycle-body">
                    <h3>{s.title}</h3>
                    {s.state === 'next' ? (
                      <>
                        <p>{s.body}</p>
                        <p className="hint" style={{ color: 'var(--ink)' }}>
                          {s.preview}
                        </p>
                        <div className="cycle-actions">
                          {connected ? (
                            <button className="btn btn-primary" disabled={!!s.disabled || !!busy || !model.chainKnown} onClick={() => run(s.label, s.done, s.run)}>
                              {busy === s.label ? 'Working…' : s.label}
                            </button>
                          ) : (
                            <button className="btn btn-primary" onClick={onConnect}>
                              Connect a wallet to run it
                            </button>
                          )}
                          <span className="hint">
                            {model.shock.ownsRoles || i === 1 ? 'Anyone can call it. ' : null}
                            <span className="code">{s.code}</span>
                          </span>
                        </div>
                        {s.disabled && connected ? <p className="hint">{s.disabled}</p> : null}
                      </>
                    ) : (
                      <p>{s.summary}</p>
                    )}
                  </div>
                </div>
              ))}
            </div>
          </div>
          <LoopSheet model={model} title="The position now" stress />
        </div>
        <aside className="side side-after">
          <StatusCard model={model} />
        </aside>
      </div>
    </>
  )
}
