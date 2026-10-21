# WETH Loop Vault demo app

A web app for the vault in this repository, running on Base Sepolia against the real Aave V3 pool, Uniswap V4
PoolManager and WETH of that testnet. Visitors can read the whole vault without a wallet, and with one they can join the
whitelist, wrap Ether, deposit, withdraw or redeem, and run the emergency cycle: shock the thresholds, close the
position with checkHealth(), restore and reinvest.

Proof of concept, not audited. Testnet Ether has no value.

<!-- Live: https://vaults-poc.<your-subdomain>.workers.dev -->

## What it shows

- **The loop, as Aave holds it.** Collateral and idle WETH against debt and equity, at the same scale, with the health
  factor on a scale that marks Aave's liquidation point, the trip threshold and the re-arm threshold. The balances are
  projected to the current second from Aave's indexes with Aave 3.6's own rounding (`src/lib/aave.ts`), so the equity
  sliver visibly shrinks while the borrow rate exceeds the supply rate.
- **Previews before every call.** Each deposit, withdrawal and emergency step shows the position before and after,
  simulated with the vault's, the strategy's and Aave's own arithmetic (`src/lib/vault.ts`), and the result is outlined
  on the drawing. The call is then simulated against the chain before the wallet asks for a signature, and a revert
  arrives as a sentence (`src/lib/errors.ts`) decoded from the errors of every contract the call reaches.
- **The shared constraints.** Aave's borrow and supply caps, the WETH Aave can pay out and the WETH the Uniswap V4
  PoolManager holds for flash loans are read live; the app works out the largest deposit they leave room for.
- **The performance fee against its high-water mark.** With negative carry the vault's equity stays below the mark, so
  no fee is charged; the card says how far below.

## What is real and what is a stand-in

The vault and the strategy are the repository's contracts, unchanged, with the parameters the test suite uses: 10x
leverage, E-Mode category 1, minHealthFactor 1.02 (the trip threshold) and targetHealthFactor 1.05 (the re-arm
threshold), and a 10% performance fee to the deployer. They run on the real Aave V3 pool (release 3.6, Pool revision
10), Uniswap V4 PoolManager and WETH of Base Sepolia. There is no price stand-in: the protocol has no oracle of its
own, and Aave's oracle (Chainlink ETH/USD on Base Sepolia) values collateral and debt with the same WETH price, so it
cancels out of the health factor except for rounding.

The one stand-in is [`DemoOperator`](../script/testnet/DemoOperator.sol), a testnet-only contract that holds the vault's
owner and admin roles. What anyone can call:

- `join()` adds the caller, and only the caller, to the whitelist.
- `shock()` raises minHealthFactor (and targetHealthFactor) above the strategy's live health factor, the way the test
  suite simulates an unhealthy position. At most once an hour, only while the strategy has debt and emergency mode is
  off. It closes nothing by itself: anyone then calls the strategy's own checkHealth().
- `restore()` clears emergency mode and puts both thresholds back to their deployment values.
- `reinvest()` calls the vault's reinvest(), which reverts unless the rebuilt position reaches targetHealthFactor.

What it does not check: anyone can close every depositor's position into idle WETH (shock, then checkHealth), and
anyone can then restore and reinvest it; equity is kept except for rounding. It exposes nothing else: no strategy
change, no fee or leverage change, no whitelist removal, and its seed shares cannot be moved. Its owner (the deployer)
can hand both roles to other addresses with `handBack()`, which ends the public controls.

Aave's caps and the PoolManager's WETH are shared with every user of the testnet. At the block the fork tests pin
(48,476,000) the WETH borrow cap had 107.45 WETH of room, enough for about 11.9 WETH of deposits at 10x; other users
move that figure, and a deposit beyond it reverts in Aave with a decoded message.

## Run it locally

Requires Node 22 and, for a local chain, Foundry.

```bash
cd app
npm ci
npm run dev                  # reads the Base Sepolia deployment, once there is one
```

Against a local chain instead: anvil forking Base Sepolia (real Aave, Uniswap and WETH code), with the vault deployed
by the same script as on the testnet. It needs a Base Sepolia RPC that serves history (`BASE_SEPOLIA_RPC_URL`, default
`https://sepolia.base.org`) and sends nothing to Base Sepolia itself:

```bash
./app/scripts/local-chain.sh                 # from the repo root; writes src/config/deployments/31337.json
cd app && VITE_CHAIN_ID=31337 npm run dev
```

`RPC=http://127.0.0.1:8546 ./app/scripts/local-chain.sh` puts the node on another port; then start the app with
`VITE_RPC_URL=http://127.0.0.1:8546` too. Anvil's default accounts hold 10,000 ETH each on the fork; import one of its
public test keys into a browser wallet to try the app by hand.

Checks:

```bash
npm run typecheck
npm test                                                    # unit tests of the math
LOCAL_RPC=http://127.0.0.1:8545 npx vitest run scripts      # parity with the contracts on the fork
E2E_RPC=http://127.0.0.1:8545 npx playwright test           # end to end, with wagmi's mock connector
```

The parity suite checks the values the app mirrors against the contracts and Aave on the fork, to the wei: balances and
the health factor projected up to 30 days ahead, every conversion, preview and ERC-4626 limit with a pending fee, the
position each deposit, withdrawal, redeem, emergency exit and reinvest leaves (scaled balances, indexes, treasury
accrual), and the largest deposit Aave's caps accept (one wei more reverts). Its gas test estimates each call right
after another account touched Aave's WETH reserve in the same block, which makes Aave's state update a no-op in the
estimate, and lands it one block later with the app's margin. The end-to-end suite drives every action and failure
path in a browser. Both snapshot the fork and revert it when they finish. Some branches are covered by the unit tests
only (a full close by withdrawal, which the locked seed keeps out of reach on this deployment; Aave's reserve flags;
liquidity limits), and conditions Aave can change on its own (an E-Mode reconfiguration, its LTV check) are left to the
simulation against the chain before each signature.

## Gas

A node estimates gas at the latest block. When another call already updated Aave's WETH reserve in that block, the
reserve update is a no-op in the estimate but runs when the call lands a block later, and the call can run out of gas:
the parity suite's helper hit exactly that before it set its own limits. The app sends `estimate x 1.3 + 30,000`
(`src/lib/gas.ts`). On the fork (`LOCAL_RPC=... npx vitest run scripts/parity.test.ts --reporter=verbose`), the
largest overrun of the estimate in that worst case was the shock: 145,772 gas used against an estimate of 144,649;
deposits and withdrawals used less than their estimate. A call whose path changes between the estimate and the landing
(for example a withdrawal that the vault's idle WETH covered at the estimate and the strategy has to pay when it
lands) can still need more; it then reverts as a landed revert and changes nothing.

## Deploy the contracts to Base Sepolia

From the repository root, with a fresh key used only for this demo:

```bash
cast wallet import demo-deployer --interactive    # stores the key encrypted, asks for a password
```

Fund that address from one of the [Base faucets](https://docs.base.org/base-chain/network-information/network-faucets)
with at least 0.11 Base Sepolia ETH: the run wraps 0.1 ETH into the seed position plus 1,000 wei for the vault's dead
shares, and gas at the current Base Sepolia price costs far less. `SEED_ASSETS=<wei>` changes the seed. Then:

```bash
forge script script/testnet/DeployTestnet.s.sol \
  --rpc-url https://sepolia.base.org --account demo-deployer --broadcast
```

The script checks the dependencies first (code at every address, the aToken and debt token against Aave's reserve, the
reserve flags, E-Mode category 1, and room for the seed under both caps and in the PoolManager), and forge simulates the
whole run, seed deposit included, before anything is sent. It deploys the vault, the strategy and DemoOperator, sets the
10% fee, deposits the seed on behalf of DemoOperator (which cannot withdraw it) and hands DemoOperator the owner and
admin roles. A smoke test then drives the deployment the way the app does, in simulation only. With `--broadcast` it
writes `app/src/config/deployments/84532.json`, which the app reads; a run without it leaves the file alone. Forge
writes the file while it runs the script, before it sends the transactions, so check that the broadcast went through
before committing it:

```bash
cast code $(jq -r .vault app/src/config/deployments/84532.json) --rpc-url https://sepolia.base.org   # not 0x
```

Nothing in the run carries a time-sensitive price, so there is no second script.

To verify the contracts on BaseScan, add `--verify --etherscan-api-key <key>` (an Etherscan API V2 key covers
BaseScan).

The testnet tooling has its own tests, kept apart so the protocol's test figures stay unchanged; the fork tests read
Base Sepolia through `BASE_SEPOLIA_RPC_URL` (default `https://sepolia.base.org`):

```bash
FOUNDRY_PROFILE=testnet forge test
```

## Deploy the app to Cloudflare Workers

The app runs as `vaults-poc`, an assets-only Worker: there is no Worker script. `wrangler.jsonc` points it at `dist/`
and holds the SPA fallback, which serves `index.html` for every page path (`/emergency`, `/how-it-works`).
`public/_headers` holds the cache and security headers; Vite copies it into `dist/`.

First deploy, from a terminal in `app/`:

```bash
npx wrangler login           # authorizes wrangler on your Cloudflare account, in the browser
npm run deploy               # builds, deploys and prints the workers.dev URL
```

Deploys on push: in the Cloudflare dashboard, connect this repository to the Worker (Workers Builds) with root
directory `app`, build command `npm run build` and deploy command `npx wrangler deploy`. The Worker name in
`wrangler.jsonc` must match the Worker in the dashboard, or the build fails.

`VITE_RPC_URL` is optional, for when the public Base Sepolia RPC rate limits the page. Vite reads it at build time, so
on Workers Builds it goes in the build variables (Settings, Build), not in the runtime variables. Any key in it is
visible to visitors, so restrict it to the site's domain at the provider.

The Workers Free plan is enough: the site is static, there is no Worker script, and requests to static assets are free.

## Structure

```
src/
  abi/          generated from the Foundry build (npm run abi after forge build)
  config/       chain, links, and the deployment files the script writes
  lib/          Aave and vault math, reads, the gas margin, error messages, formatting
  hooks/        chain reads, the derived model, transactions, the action preview, toasts, the current page
  components/   the interface
scripts/
  local-chain.sh       local rehearsal of the testnet deployment on a Base Sepolia fork
  parity.test.ts       app math against the contracts on the fork
  local-chain.test.ts  regression test of local-chain.sh
  sync-abi.mjs         regenerates src/abi
e2e/            Playwright suite and review screenshots
```

Design notes, shared with the other demo apps: [DESIGN.md](./DESIGN.md).
