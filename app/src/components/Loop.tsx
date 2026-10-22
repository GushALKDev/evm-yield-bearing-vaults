import { useState } from 'react'
import { chain, explorerAddress } from '../config/chain'
import { usePreview } from '../hooks/usePreview'
import { MAX_UINT256, WAD } from '../lib/aave'
import { yieldBreakdown } from '../lib/flow'
import { formatHealth, formatMultiple, formatPct, formatWeth } from '../lib/format'
import { rateToWad, type VaultModel } from '../lib/model'
import type { Position } from '../lib/vault'
import { Link } from './Sections'

interface Segment {
  key: string
  label: string
  value: bigint
  className: string
}

const share = (value: bigint, scale: bigint) => (scale > 0n ? Number((value * 10_000n) / scale) / 100 : 0)

function Bar({ segments, scale, ghost, label }: { segments: Segment[]; scale: bigint; ghost: bigint | null; label: string }) {
  return (
    <div className="bar-wrap">
      <div className="bar" role="img" aria-label={label}>
        {segments.map((s) => {
          const pct = share(s.value, scale)
          if (pct <= 0) return null
          return (
            <div key={s.key} className={`seg ${s.className}`} style={{ flex: `0 0 ${Math.max(pct, 0.8)}%` }} title={`${s.label}: ${formatWeth(s.value)} WETH`}>
              {pct > 14 ? <span className="seg-text">{s.label}</span> : null}
            </div>
          )
        })}
      </div>
      {ghost !== null ? <div className="bar-ghost" style={{ width: `${Math.min(100, share(ghost, scale))}%` }} aria-hidden="true" /> : null}
    </div>
  )
}

/** Collateral, debt and idle WETH of a position, cut to a slice of shares over a supply. */
function cut(p: Position, shares: bigint, supply: bigint): Position {
  const f = (x: bigint) => (supply > 0n ? (x * shares) / supply : 0n)
  return { collateral: f(p.collateral), debt: f(p.debt), idle: f(p.idle), healthFactor: p.healthFactor }
}

const equityOf = (p: Position) => (p.collateral + p.idle > p.debt ? p.collateral + p.idle - p.debt : 0n)

/**
 * The strategy's position as Aave holds it: collateral and idle WETH against debt and equity, at the same scale. With
 * `slice`, a connected depositor can switch to their own share of it.
 */
export function LoopSheet({ model, title, slice = false, stress = false }: { model: VaultModel; title?: string; slice?: boolean; stress?: boolean }) {
  const preview = usePreview()
  const acc = model.account
  const supply = model.live.vault.totalSupply
  const canSlice = slice && !!acc && (acc.shares > 0n || !!preview?.share)
  const [choice, setChoice] = useState<'vault' | 'you' | null>(null)
  const scope = canSlice ? (choice ?? (acc.shares > 0n ? 'you' : 'vault')) : 'vault'

  const live = scope === 'you' ? cut(model.position, acc!.shares, supply) : model.position
  const afterFull = preview?.after ?? null
  const after = afterFull && scope === 'you' ? (preview?.share ? cut(afterFull, preview.share.shares, preview.share.supply) : null) : afterFull
  const equity = scope === 'you' ? equityOf(live) : model.strategyEquity
  const held = live.collateral + live.idle
  const owed = live.debt + equity
  const heldAfter = after ? after.collateral + after.idle : null
  const owedAfter = after ? after.debt + equityOf(after) : null
  const scale = [held, owed, heldAfter ?? 0n, owedAfter ?? 0n].reduce((a, b) => (a > b ? a : b))

  const heldSegs: Segment[] = [
    { key: 'collateral', label: 'aWETH on Aave', value: live.collateral, className: 'seg-collateral' },
    { key: 'idle', label: 'Idle WETH', value: live.idle, className: 'seg-idle' },
  ]
  const owedSegs: Segment[] = [
    { key: 'debt', label: 'Debt', value: live.debt, className: 'seg-debt' },
    { key: 'equity', label: 'Equity', value: equity, className: 'seg-equity' },
  ]
  const legend: Record<string, string> = {
    collateral: 'Collateral',
    idle: 'Idle WETH',
    debt: 'Debt',
    equity: scope === 'you' ? 'Equity, yours' : 'Equity',
  }

  const summary =
    live.debt > 0n
      ? scope === 'you'
        ? `Your ${formatWeth(equity)} WETH works as ${formatWeth(live.collateral)} WETH of collateral against ${formatWeth(live.debt)} WETH of debt.`
        : `All depositors together: ${formatWeth(equity)} WETH of equity working as ${formatWeth(live.collateral)} WETH of collateral against ${formatWeth(live.debt)} WETH of debt.`
      : live.idle > 0n
        ? `The position is closed: ${formatWeth(live.idle)} WETH sits idle in the strategy, outside Aave.`
        : null

  return (
    <div className="card">
      <div className="card-title">
        <h2>{title ?? 'The loop, as Aave holds it'}</h2>
        {canSlice ? (
          <div className="switch" role="group" aria-label="Scope">
            <button aria-pressed={scope === 'vault'} onClick={() => setChoice('vault')}>
              Whole vault
            </button>
            <button aria-pressed={scope === 'you'} onClick={() => setChoice('you')}>
              Your slice
            </button>
          </div>
        ) : (
          <a className="card-sub" href={explorerAddress(model.deployment.strategy)} target="_blank" rel="noreferrer">
            Read live from {chain.name}
          </a>
        )}
      </div>
      {summary ? <p className="card-sub card-lead">{summary}</p> : null}
      {scale === 0n ? (
        <p className="muted">{scope === 'you' ? 'You hold no shares yet: type an amount to see your slice.' : 'The strategy holds nothing yet. The first deposit will appear here.'}</p>
      ) : (
        <>
          <div className="sheet-rows">
            <span className="sheet-label">Collateral</span>
            <Bar segments={heldSegs} scale={scale} ghost={heldAfter} label="Collateral in Aave and idle WETH" />
            <span className="sheet-total">
              {formatWeth(held)}
              {heldAfter !== null ? <span className="sheet-after"> to {formatWeth(heldAfter)}</span> : null}
            </span>
            <span className="sheet-label">Debt + equity</span>
            <Bar segments={owedSegs} scale={scale} ghost={owedAfter} label="Debt to Aave and the equity" />
            <span className="sheet-total">
              {formatWeth(owed)}
              {owedAfter !== null ? <span className="sheet-after"> to {formatWeth(owedAfter)}</span> : null}
            </span>
          </div>
          <div className="legend" style={{ marginTop: 14, marginBottom: 0 }}>
            {[...heldSegs, ...owedSegs]
              .filter((s) => s.value > 0n || s.key !== 'idle')
              .map((s) => (
                <span key={s.key}>
                  <i className={s.className} style={{ height: 10, width: 10, borderRadius: 3 }} />
                  {legend[s.key]} <strong style={{ fontWeight: 500 }}>{formatWeth(s.value)}</strong>
                </span>
              ))}
          </div>
          {preview && after ? <p className="hint" style={{ marginTop: 8 }}>Dashed outline: after {preview.label}, as previewed.</p> : null}
        </>
      )}
      <HealthScale model={model} ghost={afterFull} stress={stress} />
    </div>
  )
}

/** Health factor on a scale with Aave's liquidation point and the strategy's two thresholds. */
export function HealthScale({ model, ghost, stress = false }: { model: VaultModel; ghost?: Position | null; stress?: boolean }) {
  const hf = model.position.healthFactor
  const { minHealthFactor: min, targetHealthFactor: target } = model.live.strategy
  const ghostHf = ghost && ghost.healthFactor !== MAX_UINT256 ? ghost.healthFactor : null
  const noDebt = hf === MAX_UINT256
  const top = [target + WAD / 50n, noDebt ? 0n : hf + WAD / 100n, ghostHf ? ghostHf + WAD / 100n : 0n, (WAD * 108n) / 100n].reduce((a, b) => (a > b ? a : b))
  const bottom = (WAD * 97n) / 100n
  const at = (x: bigint) => {
    const clamped = x < bottom ? bottom : x > top ? top : x
    return Number(((clamped - bottom) * 10_000n) / (top - bottom)) / 100
  }
  const tone = noDebt ? undefined : hf < WAD ? 'danger' : hf < min ? 'warn' : 'ok'
  const years = model.yearsToTrip
  const drift =
    years !== null
      ? ` At today's rates it reaches the exit line in about ${years >= 1 ? `${years.toFixed(1)} years` : `${Math.max(1, Math.round(years * 12))} months`}.`
      : ''

  return (
    <div className="hf">
      <div className="hf-head">
        <span className="muted">Safety (Aave health factor)</span>
        <span>
          <span className={`hf-value ${tone === 'danger' ? 'tone-danger' : tone === 'warn' ? 'tone-warn' : ''}`}>{formatHealth(hf)}</span>
          {ghostHf !== null ? <span className="muted"> to {formatHealth(ghostHf)}</span> : null}{' '}
          {tone === 'warn' ? <span className="status" data-tone="warn">Below the exit line</span> : null}
          {tone === 'danger' ? <span className="status" data-tone="danger">Liquidatable on Aave</span> : null}
        </span>
      </div>
      <div
        className="hf-track"
        role="img"
        aria-label={`Health factor ${formatHealth(hf)}. Aave liquidates below 1.00, the vault exits on its own below ${formatHealth(min)}, re-entry needs ${formatHealth(target)}.`}
      >
        <div className="hf-zone-liq" style={{ width: `${at(WAD)}%` }} />
        <div className="hf-mark" data-kind="liq" style={{ left: `${at(WAD)}%` }} />
        <span className="hf-mark-label" data-kind="liq" data-side="up" style={{ left: `${at(WAD)}%` }}>
          <span className="hf-long">Aave liquidates, </span>
          <span className="hf-short">Liquidation </span>1.00
        </span>
        <div className="hf-mark" data-kind="trip" style={{ left: `${at(min)}%` }} />
        <span className="hf-mark-label" data-kind="trip" style={{ left: `${at(min)}%` }}>
          <span className="hf-long">Vault exits on its own, </span>
          <span className="hf-short">Exit </span>
          {formatHealth(min, 2)}
        </span>
        <div className="hf-mark" data-kind="target" style={{ left: `${at(target)}%` }} />
        <span className="hf-mark-label" data-kind="target" data-side="up" style={{ left: `${at(target)}%` }}>
          <span className="hf-long">Re-entry allowed, </span>
          <span className="hf-short">Re-entry </span>
          {formatHealth(target, 2)}
        </span>
        {ghostHf !== null ? <div className="hf-ghost" style={{ left: `${at(ghostHf)}%` }} /> : null}
        {!noDebt ? <div className="hf-now" style={{ left: `${at(hf)}%` }} /> : null}
      </div>
      <p className="sheet-note">
        {noDebt ? (
          'The strategy has no debt, so Aave reports no health factor. A deposit or a reinvest rebuilds the loop.'
        ) : (
          <>
            {model.borrowRate > model.supplyRate ? 'Interest makes the debt grow faster than the collateral, so this drifts left.' : 'Interest makes the collateral grow faster than the debt, so this drifts right.'}
            {drift} Before Aave could liquidate, anyone can trigger the exit: the vault repays the whole debt with one flash loan
            and keeps the equity as idle WETH.
            {stress ? null : (
              <>
                {' '}
                Try it on the <Link href="/stress-test">stress test</Link>.
              </>
            )}
          </>
        )}
      </p>
    </div>
  )
}

/** Where the yield comes from: what the collateral earns and the debt costs, per unit of equity. */
export function YieldCard({ model }: { model: VaultModel }) {
  const y = yieldBreakdown(model.position, model.strategyEquity, model.supplyRate, model.borrowRate)
  const s = formatPct(rateToWad(model.supplyRate))
  const r = formatPct(rateToWad(model.borrowRate))
  if (!y)
    return (
      <div className="card">
        <div className="card-title">
          <h2>Where the yield comes from</h2>
        </div>
        <p className="muted">
          The strategy has no open loop right now, so its WETH earns nothing. Aave pays {s} on supplied WETH and charges {r} on
          borrowed WETH.
        </p>
      </div>
    )
  const scale = y.earn > y.cost ? y.earn : y.cost
  const width = (x: bigint) => `${scale > 0n ? Number(((x < 0n ? -x : x) * 4_800n) / scale) / 100 : 0}%`
  return (
    <div className="card">
      <div className="card-title">
        <h2>Where the yield comes from</h2>
        <span className="card-sub">Per WETH you deposit, a year at today's rates</span>
      </div>
      <div className="yield-rows">
        <span className="lbl">
          {formatMultiple(y.collateralMultiple)} WETH supplied at {s}
        </span>
        <div className="ytrack" aria-hidden="true">
          <div className="ybar pos" style={{ width: width(y.earn) }} />
        </div>
        <span className="val">+{formatPct(y.earn)}</span>

        <span className="lbl">
          {formatMultiple(y.debtMultiple)} WETH borrowed at {r}
        </span>
        <div className="ytrack" aria-hidden="true">
          <div className="ybar neg" style={{ width: width(y.cost) }} />
        </div>
        <span className="val">-{formatPct(y.cost)}</span>

        <span className="yield-rule" />
        <span className="lbl">
          <b>Net on your WETH</b>
        </span>
        <div className="ytrack" aria-hidden="true">
          <div className={`ybar ${y.net < 0n ? 'net-neg' : 'net-pos'}`} style={{ width: width(y.net) }} />
        </div>
        <span className={`val ${y.net < 0n ? 'tone-danger' : 'tone-accent'}`}>
          {y.net < 0n ? '' : '+'}
          {formatPct(y.net)}
        </span>
      </div>
      <p className="sheet-note">
        The loop multiplies the spread between Aave's WETH supply and borrow rates.{' '}
        {y.net < 0n
          ? `With plain WETH the borrow rate is the higher one, so the vault loses about ${formatPct(-y.net)} of its equity a year until rates change. A loop earns when the supply side outweighs the debt, for example with a collateral that earns a yield of its own, like a liquid staking token.`
          : `At today's rates the supply side outweighs the debt, so the vault earns about ${formatPct(y.net)} a year on its equity. Rates are variable and move with Aave's utilization.`}
      </p>
    </div>
  )
}
