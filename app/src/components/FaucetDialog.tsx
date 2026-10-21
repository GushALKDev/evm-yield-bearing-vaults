import { useConnection, useWatchAsset } from 'wagmi'
import { chain, links } from '../config/chain'
import { formatWeth } from '../lib/format'
import type { VaultModel } from '../lib/model'
import { Dialog } from './Wallet'

export function FaucetDialog({ model, onClose, onConnect }: { model: VaultModel; onClose: () => void; onConnect: () => void }) {
  const { address } = useConnection()
  const watch = useWatchAsset()
  const acc = model.account

  return (
    <Dialog title="Test ETH" onClose={onClose}>
      <p className="muted">
        The vault takes the real WETH of {chain.name}, which nobody can mint: it is Ether wrapped one for one. Get {chain.name} ETH
        from one of the faucets Base lists, then wrap it from the Wrap ETH tab of your position. A little ETH also pays for gas.
      </p>
      <div className="steps" style={{ margin: '16px 0' }}>
        <a className="btn btn-primary btn-block" href={links.ethFaucet} target="_blank" rel="noreferrer">
          Open the Base faucets
        </a>
        {!address ? (
          <button className="btn btn-block" onClick={onConnect}>
            Connect wallet
          </button>
        ) : null}
      </div>
      {address && acc ? (
        <div className="rows">
          <div className="row">
            <span className="muted">Your {chain.name} ETH</span>
            <span>{acc.data.eth !== undefined ? formatWeth(acc.data.eth) : '…'}</span>
          </div>
          <div className="row">
            <span className="muted">Your WETH</span>
            <span>
              {formatWeth(acc.data.weth)}{' '}
              <button
                className="link-button"
                style={{ marginLeft: 8, fontSize: 13 }}
                onClick={() => watch.mutate({ type: 'ERC20', options: { address: model.deployment.weth, symbol: 'WETH', decimals: 18 } })}
              >
                Add to wallet
              </button>
            </span>
          </div>
        </div>
      ) : null}
    </Dialog>
  )
}
