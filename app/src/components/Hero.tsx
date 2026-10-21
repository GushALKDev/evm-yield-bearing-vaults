import type { ReactNode } from 'react'
import { chain, explorerAddress } from '../config/chain'
import { usePreview } from '../hooks/usePreview'
import { MAX_UINT256, WAD } from '../lib/aave'
import { formatHealth, formatLeverage, formatPct, formatWeth } from '../lib/format'
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

/** The strategy's position as Aave holds it: collateral and idle WETH against debt and equity, at the same scale. */
export function LoopSheet({ model, title, children }: { model: VaultModel; title?: string; children?: ReactNode }) {
  const p = model.position
  const preview = usePreview()
  const after = preview?.after ?? null
  const equity = model.strategyEquity
  const held = p.collateral + p.idle
  const owed = p.debt + equity
  const heldAfter = after ? after.collateral + after.idle : null
  const owedAfter = after ? after.debt + (after.collateral + after.idle > after.debt ? after.collateral + after.idle - after.debt : 0n) : null
  const scale = [held, owed, heldAfter ?? 0n, owedAfter ?? 0n].reduce((a, b) => (a > b ? a : b))

  const heldSegs: Segment[] = [
    { key: 'collateral', label: 'Collateral', value: p.collateral, className: 'seg-collateral' },
    { key: 'idle', label: 'Idle WETH', value: p.idle, className: 'seg-idle' },
  ]
  const owedSegs: Segment[] = [
    { key: 'debt', label: 'Debt', value: p.debt, className: 'seg-debt' },
    { key: 'equity', label: 'Equity', value: equity, className: 'seg-equity' },
  ]

  return (
    <div className="sheet">
      <div className="sheet-top">
        <h2>{title ?? 'The loop, as Aave holds it'}</h2>
        <a className="card-sub" href={explorerAddress(model.deployment.strategy)} target="_blank" rel="noreferrer">
          Read live from {chain.name}
        </a>
      </div>
      {scale === 0n ? (
        <p className="muted">The strategy holds nothing yet. The first deposit will appear here.</p>
      ) : (
        <>
          <div className="sheet-rows">
            <span className="sheet-label">The strategy holds</span>
            <Bar segments={heldSegs} scale={scale} ghost={heldAfter} label="Collateral in Aave and idle WETH" />
            <span className="sheet-total">
              {formatWeth(held)}
              {heldAfter !== null ? <span className="sheet-after"> to {formatWeth(heldAfter)}</span> : null}
            </span>
            <span className="sheet-label">It owes, and keeps</span>
            <Bar segments={owedSegs} scale={scale} ghost={owedAfter} label="Debt to Aave and the vault's equity" />
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
                  {s.key === 'collateral' ? 'Collateral (aWETH)' : s.key === 'debt' ? 'Debt (variable WETH)' : s.label}{' '}
                  <strong style={{ fontWeight: 500 }}>{formatWeth(s.value)}</strong>
                </span>
              ))}
          </div>
          {preview ? <p className="hint" style={{ marginTop: 8 }}>Dashed outlines: the position after {preview.label}, as previewed.</p> : null}
        </>
      )}
      <HealthScale model={model} ghost={after} />
      {children}
    </div>
  )
}

/** Health factor on a scale with Aave's liquidation point and the strategy's two thresholds. */
export function HealthScale({ model, ghost }: { model: VaultModel; ghost?: Position | null }) {
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

  return (
    <div className="hf">
      <div className="hf-head">
        <span className="muted">Health factor, as Aave reports it for the strategy</span>
        <span>
          <span className={`hf-value ${tone === 'danger' ? 'tone-danger' : tone === 'warn' ? 'tone-warn' : ''}`}>{formatHealth(hf)}</span>
          {ghostHf !== null ? <span className="muted"> to {formatHealth(ghostHf)}</span> : null}{' '}
          {tone === 'warn' ? <span className="status" data-tone="warn">Below the trip threshold</span> : null}
          {tone === 'danger' ? <span className="status" data-tone="danger">Liquidatable on Aave</span> : null}
        </span>
      </div>
      <div
        className="hf-track"
        role="img"
        aria-label={`Health factor ${formatHealth(hf)}. Aave liquidates below 1.00, checkHealth closes the position below ${formatHealth(min)}, reinvest needs ${formatHealth(target)}.`}
      >
        <div className="hf-zone-liq" style={{ width: `${at(WAD)}%` }} />
        <div className="hf-mark" data-kind="liq" style={{ left: `${at(WAD)}%` }} />
        <span className="hf-mark-label" data-kind="liq" data-side="up" style={{ left: `${at(WAD)}%` }}>
          Liquidation 1.00
        </span>
        <div className="hf-mark" data-kind="trip" style={{ left: `${at(min)}%` }} />
        <span className="hf-mark-label" data-kind="trip" style={{ left: `${at(min)}%` }}>
          Trip {formatHealth(min, 2)}
        </span>
        <div className="hf-mark" data-kind="target" style={{ left: `${at(target)}%` }} />
        <span className="hf-mark-label" data-kind="target" data-side="up" style={{ left: `${at(target)}%` }}>
          Re-arm {formatHealth(target, 2)}
        </span>
        {ghostHf !== null ? <div className="hf-ghost" style={{ left: `${at(ghostHf)}%` }} /> : null}
        {!noDebt ? <div className="hf-now" style={{ left: `${at(hf)}%` }} /> : null}
      </div>
      <p className="hint">
        {noDebt
          ? 'The strategy has no debt, so Aave reports no health factor. Deposits and reinvest rebuild the loop.'
          : `Aave liquidates below 1.00. Below the trip threshold anyone can call checkHealth(), which tries to close the whole position; reinvest() only rebuilds it at or above the re-arm threshold.`}
      </p>
    </div>
  )
}

export function Figures({ model }: { model: VaultModel }) {
  const p = model.position
  return (
    <div className="figures">
      <div className="figure">
        <div className="figure-value tone-accent">{formatWeth(model.vaultAssets)}</div>
        <div className="figure-label">WETH of equity in the vault</div>
      </div>
      <div className="figure">
        <div className="figure-value">{p.debt > 0n ? formatLeverage(p.collateral, model.strategyEquity) : 'None'}</div>
        <div className="figure-label">Leverage, target {model.live.strategy.targetLeverage.toString()}x</div>
      </div>
      <div className="figure">
        <div className="figure-value">{model.netRate !== null ? formatPct(model.netRate) : 'n/a'}</div>
        <div className="figure-label">A year on equity, at today's Aave rates</div>
      </div>
      <div className="figure">
        <div className="figure-value">
          {formatPct(rateToWad(model.supplyRate))}
          <span className="faint"> / </span>
          <span className="tone-debt">{formatPct(rateToWad(model.borrowRate))}</span>
        </div>
        <div className="figure-label">Aave WETH supply / borrow APR</div>
      </div>
    </div>
  )
}

function carryNote(model: VaultModel): string {
  const s = formatPct(rateToWad(model.supplyRate))
  const r = formatPct(rateToWad(model.borrowRate))
  const base = `Amounts in WETH, projected to the current second from Aave's indexes. Collateral earns the WETH supply rate (${s}) and the debt pays the borrow rate (${r}) of the same reserve.`
  if (model.netRate === null || model.position.debt === 0n) return base
  const drift =
    model.yearsToTrip !== null
      ? ` At these rates the health factor would drift down to the trip threshold in about ${model.yearsToTrip >= 1 ? `${model.yearsToTrip.toFixed(1)} years` : `${Math.max(1, Math.round(model.yearsToTrip * 12))} months`} (an estimate from Guide 2's formula).`
      : ''
  return model.netRate < 0n
    ? `${base} With the debt this size, the loop loses about ${formatPct(-model.netRate)} of its equity a year while rates stay where they are: equity shrinks every second.${drift}`
    : `${base} At these rates the loop earns about ${formatPct(model.netRate)} a year on equity.${drift}`
}

export function Hero({ model }: { model: VaultModel }) {
  return (
    <section className="hero">
      <div className="wrap">
        <div className="hero-head">
          <h1>Ten times WETH on Aave, built in one transaction.</h1>
          <p className="hero-sub">
            An ERC-4626 vault whose strategy loops WETH on Aave V3 with a Uniswap V4 flash loan, running on {chain.name} against the
            real testnet deployments of both. Every figure on this page is computed from the contracts' live state.
          </p>
        </div>
        {model.live.vault.emergency ? (
          <div className="callout" data-tone="warn" style={{ marginTop: 22 }}>
            The vault is in emergency mode: deposits are closed and withdrawals are paid from idle WETH. Anyone can restore it and
            reinvest from the <Link href="/emergency">Emergency</Link> page.
          </div>
        ) : null}
        <LoopSheet model={model}>
          <p className="sheet-note">{carryNote(model)}</p>
          <Figures model={model} />
        </LoopSheet>
      </div>
    </section>
  )
}
