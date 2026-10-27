import type { ComponentProps } from 'react'
import { chain, explorerAddress, links } from '../config/chain'
import { LEGAL_PATH, navigate, pages, type Page } from '../hooks/useRoute'
import { formatBps, formatHealth, formatWeth } from '../lib/format'
import type { VaultModel } from '../lib/model'
import { Mark } from './icons'
import { WalletButton } from './Wallet'

/** Link to a page of this app: a plain click switches page without a reload, a modified click keeps the browser's behavior. */
export function Link({ href, ...rest }: ComponentProps<'a'> & { href: string }) {
  return (
    <a
      href={href}
      {...rest}
      onClick={(e) => {
        if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
        e.preventDefault()
        navigate(href)
      }}
    />
  )
}

export function Header({ page, onConnect, onFaucet }: { page: Page; onConnect: () => void; onFaucet: () => void }) {
  return (
    <header className="site-header">
      <div className="wrap">
        <Link className="wordmark" href="/">
          <Mark />
          WETH Loop Vault
        </Link>
        <span className="network">{chain.name}</span>
        <nav className="page-nav" aria-label="Pages">
          {pages.map((p) => (
            <Link key={p.page} className="page-link" href={p.path} aria-current={p.page === page ? 'page' : undefined}>
              {p.label}
            </Link>
          ))}
        </nav>
        <div className="header-actions">
          <button className="btn btn-faucet" onClick={onFaucet} aria-label="Get test ETH">
            <span>Test ETH</span>
            <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
              <path d="M8 2.5c2 2.6 3.5 4.6 3.5 6.6a3.5 3.5 0 0 1-7 0c0-2 1.5-4 3.5-6.6z" fill="none" stroke="currentColor" strokeWidth="1.4" />
            </svg>
          </button>
          <WalletButton onConnect={onConnect} />
        </div>
      </div>
    </header>
  )
}

export function Notice() {
  return (
    <div className="notice">
      <div className="wrap">
        Testnet proof of concept for educational purposes, not audited; the ETH here has no value. It runs on the real Aave
        V3 and Uniswap V4 testnet deployments, and anyone can run the stress test on this shared vault:{' '}
        <Link href="/how-it-works#stand-ins">how and why</Link>.
      </div>
    </div>
  )
}

export function HowItWorks({ model }: { model: VaultModel }) {
  const d = model.deployment
  const st = model.static
  const s = model.live.strategy
  const l = s.targetLeverage.toString()
  return (
    <section className="section" id="how">
      <div className="wrap">
        <div className="section-head">
          <h2>How this vault works</h2>
          <p>Six mechanics, each written up in the repository's guides and checked by its tests.</p>
        </div>
        <div className="mechanics">
          <div className="mechanic">
            <h3>One deposit, one transaction</h3>
            <p>
              A deposit of X WETH reaches the strategy in the same call. The strategy flash-borrows X × ({l} - 1) WETH from the
              Uniswap V4 PoolManager, supplies X × {l} to Aave in E-Mode, borrows X × ({l} - 1) at the variable rate and repays the
              flash loan. It reverts if the position would end below the trip threshold. Deposits under{' '}
              {formatWeth(st.minInvestAssets, 6)} WETH stay idle instead.
            </p>
          </div>
          <div className="mechanic">
            <h3>Withdrawals keep the leverage</h3>
            <p>
              The vault pays from its idle WETH first. To pay N WETH from the position, the strategy repays debt × N / equity of
              debt with a flash loan (rounded up) and withdraws that plus N of collateral, so the remaining equity is exact and
              leverage does not increase. If less than {formatWeth(st.minRemainingEquity, 6)} WETH of equity would remain, it
              closes the whole position instead.
            </p>
          </div>
          <div className="mechanic">
            <h3>Exit before liquidation</h3>
            <p>
              Anyone can call checkHealth(). When Aave reports a health factor below the trip threshold, minHealthFactor (the
              exit line on the vault page, now {formatHealth(s.minHealthFactor)}), the strategy puts the vault in emergency mode, which tries to close the whole
              position with one flash loan for the entire debt. Emergency mode blocks deposits, not withdrawals: they are paid from
              the idle WETH the exit leaves, or deleverage proportionally if the exit failed.
            </p>
          </div>
          <div className="mechanic">
            <h3>Two steps to recover</h3>
            <p>
              Leaving emergency mode only clears the flags; the idle WETH stays idle. A separate reinvest() loops it again and
              reverts unless the rebuilt position reaches the re-arm threshold, targetHealthFactor (the re-entry line, now{' '}
              {formatHealth(s.targetHealthFactor)}), which
              sits above the trip threshold, so a recovery does not re-arm into a position checkHealth() would close at once.
            </p>
          </div>
          <div className="mechanic">
            <h3>A fee only on new gains</h3>
            <p>
              The {formatBps(model.live.vault.feeBps)} performance fee is charged only on gains above the high-water mark, assessed
              before each deposit, mint, withdraw and redeem is priced, and minted as shares to a whitelisted recipient. While the
              vault's equity stays below the mark, as it does with negative carry, no fee is charged.
            </p>
          </div>
          <div className="mechanic">
            <h3>A permissioned vault</h3>
            <p>
              Only whitelisted addresses can receive vault shares, on deposit, mint and transfer, and maxDeposit() reports 0 for
              anyone else. An address removed from the whitelist keeps its shares and can still withdraw them.
            </p>
          </div>
        </div>

        <div className="oracle-note" id="stand-ins">
          <div>
            <h3>What runs here, and what is a stand-in</h3>
            <p>
              The vault and the strategy are the repository's contracts, unchanged, on the real Aave V3 pool (release 3.6), Uniswap
              V4 PoolManager and WETH of {chain.name}. Their parameters are the test suite's: {l}x leverage, E-Mode category{' '}
              {st.eModeCategory}, trip threshold {formatHealth(st.defaultMinHealthFactor, 2)} and re-arm threshold{' '}
              {formatHealth(st.defaultTargetHealthFactor, 2)}. Aave's caps and the PoolManager's WETH are shared with every other
              user of the testnet, so the room for deposits moves on its own.
            </p>
            <p>
              The one stand-in is{' '}
              <a href={explorerAddress(d.operator)} target="_blank" rel="noreferrer">
                DemoOperator
              </a>
              , a testnet-only contract that holds the vault's owner and admin roles so visitors can try the permissioned and
              emergency paths. Anyone can add their own address to the whitelist, shock the thresholds above the live health factor
              (once an hour, only with an open position), restore them, and reinvest. That means a stranger can close everyone's
              position into idle WETH; anyone can then restore and reinvest it. Nothing else is reachable: no strategy change, no
              fee or leverage change, no whitelist removal. On a real deployment these roles belong to the owner and the admin.
            </p>
            <p>
              Prices do not matter much here: collateral and debt are both WETH, so Aave's oracle (Chainlink ETH/USD on{' '}
              {chain.name}) cancels out of the health factor except for rounding.
            </p>
          </div>
          <div className="flow" aria-label="What happens in a deposit">
            <p className="muted" style={{ marginBottom: 4 }}>
              In a deposit of 1 WETH at {l}x:
            </p>
            <div className="flow-step">
              <b>1</b>
              <span>The vault mints your shares and passes the WETH to the strategy, in the same call.</span>
            </div>
            <div className="flow-step">
              <b>2</b>
              <span>The strategy flash-borrows {Number(l) - 1} WETH from the Uniswap V4 PoolManager.</span>
            </div>
            <div className="flow-step">
              <b>3</b>
              <span>
                It supplies {l} WETH to Aave and borrows {Number(l) - 1} WETH against it, in E-Mode.
              </span>
            </div>
            <div className="flow-step">
              <b>4</b>
              <span>It repays the flash loan with the borrowed WETH.</span>
            </div>
            <div className="flow-step">
              <b>5</b>
              <span>It reads the health factor from Aave and reverts the whole call if it is below the trip threshold.</span>
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}

export function Footer({ model }: { model: VaultModel | null }) {
  return (
    <footer className="site-footer">
      <div className="wrap">
        <p>Proof of concept for educational purposes, not audited. Testnet ETH has no value.</p>
        <nav className="footer-links" aria-label="Links">
          <a href={links.repo} target="_blank" rel="noreferrer">
            Source code
          </a>
          <a href={links.docs} target="_blank" rel="noreferrer">
            Documentation
          </a>
          {model ? (
            <a href={explorerAddress(model.deployment.vault)} target="_blank" rel="noreferrer">
              Vault contract
            </a>
          ) : null}
          <span>
            Built by{' '}
            <a href={links.author} target="_blank" rel="noreferrer">
              Gustavo Martín
            </a>{' '}
            at{' '}
            <a href={links.tesselium} target="_blank" rel="noopener">
              Tesselium Labs
            </a>
          </span>
          <Link href={LEGAL_PATH}>Legal notice</Link>
        </nav>
      </div>
    </footer>
  )
}
