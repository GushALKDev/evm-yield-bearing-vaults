import { explorerAddress } from '../config/chain'
import { formatBaseUsd, formatBps, formatGap, formatPct, formatWeth, shortAddress } from '../lib/format'
import { rateToWad, type VaultModel } from '../lib/model'

function CapRow({ label, room, cap, unit }: { label: string; room: bigint | null; cap: bigint; unit: bigint }) {
  if (room === null)
    return (
      <div className="row">
        <dt>{label}</dt>
        <dd>No cap</dd>
      </div>
    )
  const total = cap * unit
  const used = total - room
  const pct = total > 0n ? Number((used * 10_000n) / total) / 100 : 0
  return (
    <div className="row">
      <dt>{label}</dt>
      <dd>
        {formatWeth(room, 2)} <span className="faint">left of {formatWeth(total, 0)}</span>
        <div className="cap-bar" aria-hidden="true">
          <span style={{ width: `${Math.max(pct, 1)}%` }} />
        </div>
      </dd>
    </div>
  )
}

export function AaveCard({ model }: { model: VaultModel }) {
  const c = model.config
  const d = model.deployment
  const unit = 10n ** c.decimals
  const debt = model.position.debt
  const status = c.paused ? ['Paused', 'danger'] : c.frozen ? ['Frozen', 'warn'] : !c.active ? ['Inactive', 'danger'] : ['Active', 'ok']
  const exitCovered = model.live.flashLiquidity >= debt
  return (
    <div className="card">
      <div className="card-title">
        <h2>Aave WETH reserve</h2>
        <span className="status" data-tone={status[1]}>
          {status[0]}
        </span>
      </div>
      <dl className="rows">
        <div className="row">
          <dt>Supply APR / borrow APR</dt>
          <dd>
            {formatPct(rateToWad(model.supplyRate))} <span className="faint">/</span> {formatPct(rateToWad(model.borrowRate))}
          </dd>
        </div>
        <div className="row">
          <dt>E-Mode {model.static.eModeCategory}: LTV / liquidation threshold</dt>
          <dd>
            {formatBps(model.live.eModeLtv)} <span className="faint">/</span> {formatBps(model.live.eModeLiquidationThreshold)}
          </dd>
        </div>
        <CapRow label="Borrow cap" room={model.borrowCapRoom} cap={c.borrowCap} unit={unit} />
        <CapRow label="Supply cap" room={model.supplyCapRoom} cap={c.supplyCap} unit={unit} />
        <div className="row">
          <dt>WETH Aave can pay out now</dt>
          <dd>{formatWeth(model.aaveLiquidity, 2)}</dd>
        </div>
        <div className="row">
          <dt>WETH price on Aave's oracle</dt>
          <dd>{formatBaseUsd(model.live.price)}</dd>
        </div>
      </dl>
      <p className="hint" style={{ marginTop: 10 }}>
        Each WETH deposited borrows {(model.live.strategy.targetLeverage - 1n).toString()} more from this reserve, so the caps and
        the PoolManager below leave room for about <strong>{formatWeth(model.depositRoom, 2)} WETH</strong> of deposits right now.
        Other testnet users move both.{' '}
        <a href={explorerAddress(d.aavePool)} target="_blank" rel="noreferrer">
          Pool
        </a>
      </p>

      <div className="card-title" style={{ marginTop: 22 }}>
        <h3>Uniswap V4 flash liquidity</h3>
        <span className="status" data-tone={exitCovered ? 'ok' : 'warn'}>
          {exitCovered ? 'Covers a full exit' : 'Short of a full exit'}
        </span>
      </div>
      <dl className="rows">
        <div className="row">
          <dt>WETH held by the PoolManager</dt>
          <dd>{formatWeth(model.live.flashLiquidity, 2)}</dd>
        </div>
        <div className="row">
          <dt>A full exit borrows the whole debt</dt>
          <dd>{formatWeth(debt)}</dd>
        </div>
      </dl>
      <p className="hint" style={{ marginTop: 10 }}>
        Deposits, withdrawals that reach the position and the emergency exit borrow from this balance and repay it in the same
        call; the PoolManager charges no fee for it. maxWithdraw() counts it.{' '}
        <a href={explorerAddress(d.poolManager)} target="_blank" rel="noreferrer">
          PoolManager
        </a>
      </p>
    </div>
  )
}

export function FeeCard({ model }: { model: VaultModel }) {
  const v = model.live.vault
  const assets = model.vaultAssets
  const below = assets <= v.highWaterMark
  return (
    <div className="card">
      <div className="card-title">
        <h2>Performance fee</h2>
        <span className="card-sub">{formatBps(v.feeBps)} above the high-water mark</span>
      </div>
      <dl className="rows">
        <div className="row">
          <dt>High-water mark</dt>
          <dd>{formatWeth(v.highWaterMark, 6)}</dd>
        </div>
        <div className="row">
          <dt>Vault equity now</dt>
          <dd>{formatWeth(assets, 6)}</dd>
        </div>
        <div className="row">
          <dt>Fee recipient</dt>
          <dd>
            <a className="mono" href={explorerAddress(v.feeRecipient)} target="_blank" rel="noreferrer">
              {shortAddress(v.feeRecipient)}
            </a>
          </dd>
        </div>
      </dl>
      <p className="hint" style={{ marginTop: 10 }}>
        {below
          ? `Equity is ${formatGap(v.highWaterMark - assets)} WETH below the mark, so no fee is due. The mark moves up by each deposit and down by each withdrawal, and only gains above it are charged.`
          : `Equity is ${formatGap(assets - v.highWaterMark)} WETH above the mark: the next deposit or withdrawal mints ${formatWeth(model.fee.feeShares, 6)} fee shares before it is priced.`}
      </p>
    </div>
  )
}
