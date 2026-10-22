import { useState } from 'react'
import { chain, explorerAddress } from '../config/chain'
import { yieldBreakdown } from '../lib/flow'
import { formatBaseUsd, formatBps, formatGap, formatHealth, formatPct, formatWeth, shortAddress } from '../lib/format'
import { rateToWad, type VaultModel } from '../lib/model'
import { LoopSheet, YieldCard } from './Loop'
import { Link } from './Sections'

type Tab = 'overview' | 'risks' | 'capacity' | 'fees' | 'contracts'

const tabs: { id: Tab; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'risks', label: 'Risks' },
  { id: 'capacity', label: 'Capacity' },
  { id: 'fees', label: 'Fees' },
  { id: 'contracts', label: 'Contracts' },
]

/** The vault page's left column: how the vault works and what bounds it, one tab at a time. */
export function VaultDetails({ model }: { model: VaultModel }) {
  const [tab, setTab] = useState<Tab>('overview')
  return (
    <div className="details">
      <div className="content-tabs" role="tablist" aria-label="Vault details">
        {tabs.map((t) => (
          <button key={t.id} role="tab" className="content-tab" aria-selected={tab === t.id} onClick={() => setTab(t.id)}>
            {t.label}
          </button>
        ))}
      </div>
      <div className="stack" role="tabpanel">
        {tab === 'overview' ? (
          <>
            <LoopSheet model={model} slice />
            <YieldCard model={model} />
          </>
        ) : null}
        {tab === 'risks' ? <RisksCard model={model} /> : null}
        {tab === 'capacity' ? <CapacityCard model={model} /> : null}
        {tab === 'fees' ? <FeeCard model={model} /> : null}
        {tab === 'contracts' ? <ContractsCard model={model} /> : null}
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Risks                                                               */
/* ------------------------------------------------------------------ */

interface Risk {
  tag: string
  tone?: 'danger' | 'warn'
  title: string
  body: string
}

function RisksCard({ model }: { model: VaultModel }) {
  const y = yieldBreakdown(model.position, model.strategyEquity, model.supplyRate, model.borrowRate)
  const min = formatHealth(model.live.strategy.minHealthFactor, 2)
  const risks: Risk[] = []
  if (y && y.net < 0n)
    risks.push({
      tag: 'Now',
      tone: 'danger',
      title: 'Negative carry',
      body: `At today's rates the debt costs more than the collateral earns: your WETH shrinks about ${formatPct(-y.net)} a year, a little every second.`,
    })
  if (model.shock.ownsRoles)
    risks.push({
      tag: 'Shared',
      tone: 'warn',
      title: 'Anyone can close the position on this testnet',
      body: "The stress test is public. It moves every depositor's position into idle WETH and back; equity is kept except for rounding, but while the WETH is idle it earns and loses nothing.",
    })
  risks.push(
    {
      tag: 'Shared',
      tone: 'warn',
      title: 'Capacity is shared with every Aave user',
      body: "Aave's caps, the WETH Aave can pay out and the flash loan liquidity limit how much can go in or out at once. The panel shows the live limit before you sign.",
    },
    {
      tag: 'Low',
      title: 'Liquidation',
      body: `Collateral and debt are both WETH, so the ETH price cancels out. The health factor moves with interest or an Aave parameter change, and the vault exits at ${min}, before Aave liquidates at 1.00. Nothing calls the exit on its own: anyone can, and the repository ships no keeper.`,
    },
    {
      tag: 'Always',
      title: 'Not audited',
      body: 'A proof of concept for educational purposes on a testnet. Do not reuse it with real funds.',
    },
  )
  return (
    <div className="card">
      <div className="card-title">
        <h2>What can go wrong</h2>
        <span className="card-sub">In plain words, the most likely first</span>
      </div>
      <div className="risk-list">
        {risks.map((r) => (
          <div className="risk" key={r.title}>
            <span className="status" data-tone={r.tone}>
              {r.tag}
            </span>
            <h3>{r.title}</h3>
            <p>{r.body}</p>
          </div>
        ))}
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Capacity                                                            */
/* ------------------------------------------------------------------ */

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

function CapacityCard({ model }: { model: VaultModel }) {
  const c = model.config
  const d = model.deployment
  const unit = 10n ** c.decimals
  const debt = model.position.debt
  const status = c.paused ? ['Aave reserve paused', 'danger'] : c.frozen ? ['Aave reserve frozen', 'warn'] : !c.active ? ['Aave reserve inactive', 'danger'] : null
  const exitCovered = model.live.flashLiquidity >= debt
  return (
    <div className="card">
      <div className="room">
        <div>
          <div className="card-sub">Largest deposit that fits right now</div>
          <div className="room-value">{formatWeth(model.depositRoom, 2)} WETH</div>
        </div>
        <span className="status" data-tone={status ? status[1] : exitCovered ? 'ok' : 'warn'}>
          {status ? status[0] : exitCovered ? 'Full exit covered' : 'Short of a full exit'}
        </span>
      </div>
      <p className="sheet-note">
        Each WETH deposited borrows {(model.live.strategy.targetLeverage - 1n).toString()} more from Aave, so the room is set by
        Aave's caps and by the WETH the Uniswap V4 PoolManager can lend for the loop, at no fee. Other {chain.name} users move
        both.
      </p>
      <dl className="rows" style={{ marginTop: 12 }}>
        <CapRow label="Aave borrow cap" room={model.borrowCapRoom} cap={c.borrowCap} unit={unit} />
        <CapRow label="Aave supply cap" room={model.supplyCapRoom} cap={c.supplyCap} unit={unit} />
        <div className="row">
          <dt>WETH Aave can pay out now</dt>
          <dd>{formatWeth(model.aaveLiquidity, 2)}</dd>
        </div>
        <div className="row">
          <dt>Uniswap V4 flash liquidity</dt>
          <dd>
            {formatWeth(model.live.flashLiquidity, 2)} <span className="faint">a full exit needs {formatWeth(debt, 2)}</span>
          </dd>
        </div>
        <div className="row">
          <dt>Aave WETH supply / borrow APR</dt>
          <dd>
            {formatPct(rateToWad(model.supplyRate))} <span className="faint">/</span> {formatPct(rateToWad(model.borrowRate))}
          </dd>
        </div>
        <div className="row">
          <dt>E-Mode {model.static.eModeCategory}: max LTV / liquidation threshold</dt>
          <dd>
            {formatBps(model.live.eModeLtv)} <span className="faint">/</span> {formatBps(model.live.eModeLiquidationThreshold)}
          </dd>
        </div>
        <div className="row">
          <dt>WETH price on Aave's oracle</dt>
          <dd>{formatBaseUsd(model.live.price)}</dd>
        </div>
      </dl>
      <p className="hint" style={{ marginTop: 10 }}>
        Withdrawals that reach the position borrow from the same flash liquidity, and maxWithdraw() counts it.{' '}
        <a href={explorerAddress(d.aavePool)} target="_blank" rel="noreferrer">
          Aave Pool
        </a>
        ,{' '}
        <a href={explorerAddress(d.poolManager)} target="_blank" rel="noreferrer">
          PoolManager
        </a>
      </p>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Fees                                                                */
/* ------------------------------------------------------------------ */

function FeeCard({ model }: { model: VaultModel }) {
  const v = model.live.vault
  const assets = model.vaultAssets
  const below = assets <= v.highWaterMark
  return (
    <div className="card">
      <div className="card-title">
        <h2>Performance fee</h2>
        <span className="card-sub">{formatBps(v.feeBps)} of gains above the high-water mark</span>
      </div>
      <div className="room">
        <div>
          <div className="card-sub">Fee due now</div>
          <div className="room-value">{below ? '0' : formatWeth(model.fee.feeShares, 6)} {below ? 'WETH' : 'YBV'}</div>
        </div>
        <span className="status">
          {below ? `${formatGap(v.highWaterMark - assets)} WETH below the mark` : `${formatGap(assets - v.highWaterMark)} WETH above the mark`}
        </span>
      </div>
      <p className="sheet-note">
        {below
          ? 'The vault only charges on new highs: the mark moves up with each deposit and down with each withdrawal, so losses have to be recovered before any fee is taken.'
          : 'The next deposit or withdrawal mints these fee shares to the recipient before it is priced.'}{' '}
        There are no deposit or withdrawal fees.
      </p>
      <dl className="rows" style={{ marginTop: 12 }}>
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
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Contracts                                                           */
/* ------------------------------------------------------------------ */

function ContractsCard({ model }: { model: VaultModel }) {
  const d = model.deployment
  const rows: [string, `0x${string}`][] = [
    ['Vault (ERC-4626, YBV shares)', d.vault],
    ['Strategy (WETH loop)', d.strategy],
    [model.shock.ownsRoles ? 'DemoOperator, owner and admin' : 'DemoOperator (roles handed back)', d.operator],
    ['Aave V3 Pool', d.aavePool],
    ['aWETH', d.aToken],
    ['Variable debt WETH', d.variableDebtToken],
    ['Uniswap V4 PoolManager', d.poolManager],
    ['WETH', d.weth],
  ]
  return (
    <div className="card">
      <div className="card-title">
        <h2>Contracts</h2>
        <span className="card-sub">{chain.name}</span>
      </div>
      <dl className="rows">
        {rows.map(([label, address]) => (
          <div className="row" key={label}>
            <dt>{label}</dt>
            <dd>
              <a className="mono" href={explorerAddress(address)} target="_blank" rel="noreferrer">
                {shortAddress(address)}
              </a>
            </dd>
          </div>
        ))}
      </dl>
      <p className="hint" style={{ marginTop: 10 }}>
        The vault and the strategy are the repository's contracts, unchanged. What DemoOperator lets anyone do is on{' '}
        <Link href="/how-it-works#stand-ins">How it works</Link>.
      </p>
    </div>
  )
}
