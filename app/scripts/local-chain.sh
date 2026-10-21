#!/usr/bin/env bash
# Local rehearsal of the testnet deployment: anvil forking Base Sepolia, so the vault runs against the real Aave V3
# pool, Uniswap V4 PoolManager and WETH, then DeployTestnet from anvil's first account (seed included).
# Writes app/src/config/deployments/31337.json; start the app with VITE_CHAIN_ID=31337.
# Requires Foundry and a Base Sepolia RPC: BASE_SEPOLIA_RPC_URL, default https://sepolia.base.org (serves history).
# FORK_BLOCK pins the fork (default: latest). RPC picks the local node (default http://127.0.0.1:8545); if nothing
# answers there, anvil starts on its port. Nothing is sent to Base Sepolia itself.
# Run from anywhere: ./app/scripts/local-chain.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RPC="${RPC:-http://127.0.0.1:8545}"
FORK_URL="${BASE_SEPOLIA_RPC_URL:-https://sepolia.base.org}"
# anvil's first default account, public test key
KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

cd "$ROOT"

if ! cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "Starting anvil on $RPC, forking $FORK_URL"
  # Output detached: a background process holding the caller's stdout keeps a pipeline from finishing
  anvil --silent --chain-id 31337 --port "${RPC##*:}" --fork-url "$FORK_URL" ${FORK_BLOCK:+--fork-block-number "$FORK_BLOCK"} \
    > /dev/null 2>&1 &
  for _ in $(seq 1 100); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
fi

forge script script/testnet/DeployTestnet.s.sol --rpc-url "$RPC" --private-key "$KEY" --broadcast -q
echo "Wrote app/src/config/deployments/31337.json"
