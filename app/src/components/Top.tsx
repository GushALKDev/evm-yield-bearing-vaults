import { MAX_UINT256, WAD } from '../lib/aave'
import { yieldBreakdown } from '../lib/flow'
import { formatHealth, formatLeverage, formatMultiple, formatPct, formatWeth } from '../lib/format'
import { rateToWad, type VaultModel } from '../lib/model'
import { depositClosedReason } from '../lib/vault'
import { Link } from './Sections'

/** The vault page's head: what the vault does, the four figures a depositor decides on, and why the yield is what it is. */
export function VaultTop({ model }: { model: VaultModel }) {
  const p = model.position
  const lev = model.live.strategy.targetLeverage
  const y = yieldBreakdown(p, model.strategyEquity, model.supplyRate, model.borrowRate)
  const net = y?.net ?? model.netRate
  const emergency = model.live.vault.emergency
  // Whitelisting is a step of the deposit flow, not a reason the vault is closed
  const closed = depositClosedReason(model.state, true, model.chainTime)
  const hf = p.healthFactor
  const noDebt = hf === MAX_UINT256
  const safety = noDebt
    ? { label: 'No debt', tone: undefined }
    : hf < WAD
      ? { label: 'Liquidatable', tone: 'danger' }
      : hf < model.live.strategy.minHealthFactor
        ? { label: 'Below the exit line', tone: 'warn' }
        : { label: 'Safe', tone: 'ok' }

  return (
    <section className="wrap top">
      <div className="top-head">
        <div>
          <h1>Put WETH to work at {lev.toString()}x on Aave.</h1>
          <p className="top-sub">
            Your deposit and a Uniswap V4 flash loan of {(lev - 1n).toString()} times it are supplied to Aave V3 as collateral;
            borrowing against that collateral repays the flash loan. One transaction, {lev.toString()} times the exposure.
          </p>
        </div>
        <span className="status" data-tone={closed ? 'warn' : 'ok'}>
          {emergency ? 'Emergency mode, deposits closed' : closed ? 'Deposits closed' : 'Deposits open'}
        </span>
      </div>

      <div className="kpis">
        <div className="kpi kpi-lead">
          <div className="kpi-label">
            <span className="term" title="What the collateral earns minus what the debt costs, on your WETH, at today's variable Aave rates">
              Net APY on your WETH
            </span>
          </div>
          <div className={`kpi-value ${net === null ? '' : net < 0n ? 'tone-danger' : 'tone-accent'}`}>
            {net === null ? 'n/a' : `${net > 0n ? '+' : ''}${formatPct(net)}`}
          </div>
          <div className="kpi-sub">
            {!y
              ? 'No open loop right now.'
              : y.net < 0n
                ? 'Variable. Today the debt costs more than the collateral earns.'
                : "Variable, at today's Aave rates."}
          </div>
        </div>
        <div className="kpi">
          <div className="kpi-label">Vault value</div>
          <div className="kpi-value">{formatWeth(model.vaultAssets)}</div>
          <div className="kpi-sub">WETH of equity</div>
        </div>
        <div className="kpi">
          <div className="kpi-label">Leverage</div>
          <div className="kpi-value">{p.debt > 0n ? formatLeverage(p.collateral, model.strategyEquity) : 'None'}</div>
          <div className="kpi-sub">Target {lev.toString()}x</div>
        </div>
        <div className="kpi">
          <div className="kpi-label">
            <span className="term" title="Aave's health factor for the strategy. Aave liquidates below 1.00; the vault exits on its own below its exit line.">
              Safety
            </span>
          </div>
          <div className={`kpi-value ${safety.tone === 'danger' ? 'tone-danger' : safety.tone === 'warn' ? 'tone-warn' : ''}`}>
            {noDebt ? 'n/a' : formatHealth(hf)}
          </div>
          <div className="kpi-sub">
            <span className="status" data-tone={safety.tone}>
              {safety.label}
            </span>{' '}
            exits below {formatHealth(model.live.strategy.minHealthFactor, 2)}
          </div>
        </div>
      </div>

      {y ? (
        <p className="breakdown">
          <span>Why:</span>
          <span>
            collateral earns <b>{formatMultiple(y.collateralMultiple)} x {formatPct(rateToWad(model.supplyRate))}</b>
          </span>
          <span className="op">minus</span>
          <span>
            debt costs <b>{formatMultiple(y.debtMultiple)} x {formatPct(rateToWad(model.borrowRate))}</b>
          </span>
          <span className="op">=</span>
          <b className={y.net < 0n ? 'tone-danger' : 'tone-accent'}>
            {y.net > 0n ? '+' : ''}
            {formatPct(y.net)} a year
          </b>
          <span>on each WETH you deposit.</span>
        </p>
      ) : null}

      {emergency ? (
        <div className="callout" data-tone="warn" style={{ marginTop: 16 }}>
          The vault is in emergency mode: deposits are closed, and withdrawals are paid from idle WETH (or deleverage the
          position if the exit failed). Anyone can reopen it and loop again from the <Link href="/stress-test">stress test</Link>.
        </div>
      ) : null}
    </section>
  )
}
