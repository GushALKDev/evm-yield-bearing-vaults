# Yield Bearing Vaults

![Status](https://img.shields.io/badge/Status-Proof%20of%20concept-lightgrey)
![License](https://img.shields.io/badge/License-MIT-green)
![Solidity](https://img.shields.io/badge/Solidity-0.8.26-blue)
![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)

![Tests](https://img.shields.io/badge/Tests-209%20passing-brightgreen)
![Coverage](https://img.shields.io/badge/Line%20coverage-89.31%25-yellowgreen)
![Fuzzing](https://img.shields.io/badge/Fuzzing-356%2C608%20runs%20%2B%20calls-blue)

A modular ERC-4626 vault with pluggable strategies. The repository contains a simple Aave V3 supply strategy and a leveraged WETH loop strategy that uses Uniswap V4 flash loans and Aave V3 E-Mode.

## Status

Proof of concept. Not audited and not deployed.

The repository contains no deployment scripts (`script/` is empty) and no `broadcast/` directory. Several known issues are listed in [Known issues](#known-issues). Do not use this code with real funds.

## Overview

- **Vault and strategy split.** `YieldBearingVault` is an ERC-4626 vault that holds shares of a single ERC-4626 strategy. Deposits are forwarded to the strategy in the same transaction. On withdrawal the vault first uses its own idle balance and withdraws only the shortfall from the strategy.
- **Leveraged WETH loop.** `WETHLoopStrategy` uses a Uniswap V4 flash loan and Aave V3 E-Mode (category 1, "ETH correlated") to build a leveraged WETH position. The tests use 10x. The code accepts any integer `targetLeverage >= 2`; with the E-Mode LTV of 93% observed at the time of testing, Aave accepts a fresh position at 14x and rejects one at 15x.
- **Negative carry.** The WETH loop demonstrates the leverage mechanics. Because collateral and debt are the same asset in the same Aave reserve, the loop has negative carry; a positive spread requires yield-bearing collateral such as an LST (see [Roadmap](#roadmap)). See [Economics of the WETH loop](#economics-of-the-weth-loop).
- **Health check and emergency divest.** `WETHLoopStrategy.checkHealth()` is a permissionless function. When the Aave health factor is below `minHealthFactor`, it activates emergency mode and closes the whole position with a flash loan. It is designed to exit the position before liquidation, but it only runs when someone calls it. The repository does not include a keeper.
- **Recovery.** When the vault admin deactivates emergency mode, the strategy reinvests its idle balance at the current `targetLeverage`.
- **Performance fee with high-water mark.** Performance fees are only charged on gains above the previous high-water mark. Fees are minted as vault shares to the fee recipient.
- **Permissioned ERC-4626.** The vault implements the ERC-4626 interface on top of OpenZeppelin Contracts v5.5.0. It is permissioned: deposit and mint receivers and share transfer recipients must be whitelisted. Withdrawals and redemptions are not whitelist-gated.
- **Flash loan provider.** Uniswap V4 charged no flash loan fee at the time of writing. Aave V3's flash loan premium was 0.05% at the time of writing (`FLASHLOAN_PREMIUM_TOTAL = 5` bps at block 26043165). Neither value is fixed.

## Architecture

```
┌──────────────────────────┐
│           USER           │
└────────────┬─────────────┘
             │    ▲
      Assets │    │ vShares
             ▼    │
┌──────────────────────────┐
│    YieldBearingVault     │
│  (ERC4626, Whitelist)    │
└────────────┬─────────────┘
             │    ▲
      Assets │    │ sShares
             ▼    │
┌──────────────────────────┐
│         Strategy         │
│ (AaveSimple / WETHLoop)  │
└────────────┬─────────────┘
             │    ▲
      Assets │    │ aTokens / debt tokens
             ▼    │
┌──────────────────────────┐
│    External Protocols    │
│ (Aave V3 / Uniswap V4)   │
└──────────────────────────┘
```

## Contracts

| Contract | Description |
|----------|-------------|
| `YieldBearingVault` | Concrete vault ("YieldBearingVault", "YBV") built on `BaseVault` |
| `BaseVault` | Abstract ERC-4626 vault: whitelist, strategy integration, high-water-mark fee, emergency mode, 1,000 wei dead shares |
| `BaseStrategy` | Abstract ERC-4626 strategy that only accepts deposits from its vault; `_invest()` and `_divest()` hooks |
| `AaveSimpleLendingStrategy` | Supplies the asset to Aave V3, no leverage. `checkHealth()` always returns `true` |
| `WETHLoopStrategy` | Leveraged WETH strategy using Uniswap V4 flash loans and Aave V3 E-Mode |
| `AaveAdapter` | Library for Aave V3 supply, withdraw, borrow (variable rate) and repay |
| `UniswapV4Adapter` | Abstract adapter implementing flash loans through `unlock` / `unlockCallback` |
| `Whitelist` | `Ownable` whitelist of addresses |

### Roles

| Role | Holder | Can call |
|------|--------|----------|
| Owner | `Ownable` owner of the vault (constructor `_owner`) | `addToWhitelist`, `removeFromWhitelist`, `addBatchToWhitelist`, `removeBatchFromWhitelist`, `transferOwnership`, `renounceOwnership` |
| Admin | Vault `admin` (constructor `_admin`) | Vault: `setAdmin`, `setStrategy`, `setEmergencyMode`, `setProtocolFee`, `setFeeRecipient`. Strategy: `setLeverage`, `setHealthFactors`, `harvest` (reverts in both strategies) |
| Strategy | The vault's current `strategy` | `activateEmergencyMode()` on the vault (activate only) |
| Vault | The strategy's immutable `VAULT` | Strategy `deposit`, `mint`, `withdraw`, `redeem`, `setEmergencyMode` |
| Anyone | Any address | `checkHealth()` on the strategies, `assessPerformanceFee()` on the vault |

## WETHLoopStrategy flow

### Investment (leverage loop)

```
1. The vault deposits X WETH into the strategy
2. Strategy flash-borrows X * (L - 1) WETH from the Uniswap V4 PoolManager
3. Strategy supplies its whole WETH balance (X * L if it held no idle WETH) to Aave
4. Strategy borrows X * (L - 1) WETH from Aave at the variable rate
5. Strategy repays the flash loan with the borrowed WETH
6. Result: X * L collateral, X * (L - 1) debt

Example with L = 10 and a 1 WETH deposit:
- Collateral: 10 WETH | Debt: 9 WETH | Net equity: 1 WETH
```

### Divestment (proportional deleverage)

```
1. The vault requests Y WETH from the strategy (only the part it cannot pay from its idle balance)
2. ratio = Y / netEquity, where netEquity = collateral - debt
3. Strategy flash-borrows totalDebt * ratio WETH from the Uniswap V4 PoolManager
4. Strategy repays totalDebt * ratio to Aave
5. Strategy withdraws totalCollateral * ratio from Aave
6. Strategy repays the flash loan and transfers Y WETH to the vault
7. Result: position reduced proportionally, leverage ratio unchanged

Example: 50% withdrawal from 10 WETH collateral / 9 WETH debt:
- Withdraw 5 WETH collateral | Repay 4.5 WETH debt | Return 0.5 WETH
```

If the strategy has no debt it withdraws `Y` directly. If collateral is less than or equal to debt the call reverts with `InsufficientEquity()`.

### Emergency divest

```
1. Anyone calls checkHealth(); Aave reports healthFactor < minHealthFactor
2. Strategy calls vault.activateEmergencyMode(), which also sets the strategy's emergency flag
3. Strategy flash-borrows totalDebt WETH from the Uniswap V4 PoolManager
4. Strategy repays all debt to Aave
5. Strategy withdraws all collateral from Aave
6. Strategy repays the flash loan; the remaining WETH stays in the strategy
7. The call reverts with EmergencyDivestFailed() if any debt remains
8. Emergency mode is active: vault and strategy deposits and mints revert
```

If any step reverts (for example, not enough WETH in the PoolManager), the whole transaction reverts, including the activation of emergency mode.

### Recovery

```
1. Admin calls vault.setEmergencyMode(false)
2. The vault calls strategy.setEmergencyMode(false)
3. The strategy detects the transition and calls _reinvest() with its whole WETH balance
4. The position is rebuilt at the current targetLeverage
5. Deposits are accepted again
```

Emergency mode set by the admin with `setEmergencyMode(true)` does not close the position. See [Known issues](#known-issues).

## Economics of the WETH loop

In an Aave reserve, suppliers receive the interest paid by borrowers minus the reserve factor:

```
s = r * U * (1 - RF)

s  = supply rate of the reserve
r  = variable borrow rate of the same reserve
U  = utilization of the reserve
RF = reserve factor
```

Since `U <= 1` and `RF > 0`, `s < r`. The WETH loop supplies WETH and borrows WETH from the same reserve, so the collateral earns `s` and the debt costs `r`.

Return on equity at leverage `L` (per unit of equity, ignoring rewards, gas and flash loan fees):

```
ROE = L * s - (L - 1) * r
```

Illustrative example (rates change constantly): `U = 80%`, `RF = 15%`, `L = 10`:

```
s   = 0.80 * 0.85 * r = 0.68 * r
ROE = 10 * 0.68 * r - 9 * r = 6.8r - 9r = -2.2r
r = 2.5%  ->  ROE = -5.5% per year
```

With the WETH reserve rates observed on mainnet at block 26043094 (supply 1.41%, variable borrow 2.02%), the same formula gives about -4.1% per year at 10x.

Consequence for the health factor. Debt grows at `r` and collateral grows at `s < r`, so the health factor drifts down over time even if prices do not move. Collateral and debt are both WETH, so a WETH price move does not change the health factor; interest accrual and changes to Aave's risk parameters do.

```
HF    = collateral * LT / debt
HF_0  = L * LT / (L - 1)
HF(t) ~ HF_0 * exp(-(r - s) * t)
t     = ln(HF_0 / HF_min) / (r - s)      (time until HF reaches HF_min)
```

With the E-Mode liquidation threshold observed at the time of testing (`LT = 95%`):

- `L = 10`: `HF_0 = 10 * 0.95 / 9 = 1.0556`. A 10x position opened on a mainnet fork during review reported `1.055555555554728178`.
- `L = 14`: `HF_0 = 14 * 0.95 / 13 = 1.0231` (fork: `1.023076923076359553`), close to the `minHealthFactor` of 1.02 used in the tests.

Illustrative drift at 10x with `minHealthFactor = 1.02`: with `r - s = 0.8` percentage points (the example above), HF reaches 1.02 after about 4.3 years and 1.00 after about 6.8 years. A sustained spread of 5 percentage points (for example during a utilization spike) reaches 1.02 in about 8 months. This is why the emergency divest path, and someone calling `checkHealth()` in time, matters.

## Trust assumptions and limitations

- **Admin powers.** The admin can:
  - replace the strategy at any time with `setStrategy()`. The new strategy receives an unlimited allowance of the vault asset, receives all future deposits, and funds in the old strategy are not migrated and stop being counted in `totalAssets()`;
  - set the protocol fee (up to 2,500 bps, 25%) and the fee recipient;
  - activate or deactivate emergency mode. Deactivation triggers an automatic reinvestment of the strategy's idle balance at the current leverage;
  - change `targetLeverage` (any integer >= 2, no upper bound in code) and the health factor thresholds (any `min < target`, no bounds). Raising `minHealthFactor` above the current health factor lets anyone trigger an emergency divest; the tests use this to simulate an unhealthy position;
  - transfer the admin role with `setAdmin()`.
  There is no timelock.
- **Owner powers.** The owner controls the whitelist and can transfer or renounce ownership. Renouncing freezes the whitelist.
- **Keeper liveness.** `checkHealth()` is permissionless, but the repository does not include a keeper, bot or script that calls it. If nobody calls it in time, the emergency divest does not happen and the position can be liquidated.
- **Flash loan liquidity.** Investment, proportional divestment and emergency divest all flash-borrow WETH from the Uniswap V4 PoolManager. The emergency divest borrows the full debt. At block 26043094 the PoolManager held about 1,012 WETH, which at 10x limits a single deposit to about 112 WETH and a closable position to about 112 WETH of equity. The fork tests `deal` 10,000 WETH to the PoolManager in `setUp`, so they do not reflect real liquidity.
- **Aave parameters.** LTV (93%), liquidation threshold (95%) and E-Mode category 1 parameters were read at the time of testing. They are set by Aave governance and can change; a lower liquidation threshold lowers the health factor of an existing position immediately.
- **Negative carry.** The WETH loop loses value over time at typical rates; see [Economics of the WETH loop](#economics-of-the-weth-loop).
- **No rebalancing.** Leverage is only applied when assets are invested. `setLeverage()` affects future deposits and reinvestments, not the existing position. `targetHealthFactor` is stored and validated but not used by any logic. `harvest()` reverts in both strategies.
- **ERC-4626 limits.** `maxDeposit()` and `maxMint()` are not overridden and return `type(uint256).max` even for non-whitelisted receivers and during emergency mode.
- **Whitelist scope.** The whitelist is checked on the deposit or mint receiver (not the caller) and on the recipient of share transfers. Performance fee shares are minted to the fee recipient without a whitelist check. Addresses removed from the whitelist keep their shares and can still withdraw and transfer to whitelisted addresses.
- **High-water mark details.** The high-water mark is an aggregate asset amount, not a per-share price. It increases by deposited assets, decreases by withdrawn assets, and is raised to `totalAssets()` when fees are assessed with a non-zero rate and a recipient set. While the fee is 0 or no recipient is set, it is not raised, so enabling the fee later charges it on gains accrued before.
- **Dead shares.** The 1,000 wei initial deposit raises the cost of a first-depositor share inflation attack; it does not eliminate it. There is no decimals offset.
- **Not audited.**

## Known issues

Found while verifying this document against the code. They are documented here and not fixed in this revision.

1. **Idle WETH is not counted after an emergency divest.** `WETHLoopStrategy.totalAssets()` returns `aToken balance - debt` and does not include WETH held by the strategy. After an emergency divest the strategy holds the recovered WETH but reports close to 0 assets, so the vault's `totalAssets()` drops accordingly. On a mainnet fork, a user who deposited 1 WETH and redeemed all shares during emergency mode received 1,000 wei (paid from the vault's idle initial deposit), while about 1 WETH stayed in the strategy. `test_EmergencyMode_WithdrawalsSkipDivest` passes because its `setUp` sends 100 WETH directly to the vault, so the redemption is paid from that balance within a 2% tolerance. `invariant_TotalAssetsCalculation` expects idle WETH to be included, and passes because no idle WETH accumulates during the invariant runs.
2. **Admin-activated emergency mode blocks withdrawals.** `BaseStrategy._withdraw()` skips `_divest()` whenever emergency mode is active, on the assumption that the position was already closed. When the admin activates emergency mode directly, the position is still open, so withdrawals that need funds from the strategy revert. Observed on a fork for both `WETHLoopStrategy` and `AaveSimpleLendingStrategy`.
3. **Full exit through the vault can revert.** On a mainnet fork, a single depositor redeeming all vault shares from a 10x position reverted with Aave's `HealthFactorLowerThanLiquidationThreshold()`. The vault pays part of the amount from its idle balance (the 1,000 wei initial deposit), so the strategy is asked for slightly less than its full equity; the proportional repayment then leaves dust debt against dust collateral, which Aave rejects. Redeeming 50% succeeded. `test_Divest_FullWithdrawal` calls `strategy.redeem()` directly with all strategy shares and does not cover this path.
4. **`forge test --gas-report` fails.** With `--gas-report`, 15 suites revert in `setUp()` with `ERC20InsufficientAllowance`. Gas reports run tests in isolation mode, where the deployer's nonce no longer matches the one passed to `vm.computeCreateAddress`, so the initial deposit is approved for the wrong vault address.

## Security considerations

| Topic | Implementation |
|-------|----------------|
| Share inflation | The constructor requires exactly 1,000 wei (`REQUIRED_INITIAL_DEPOSIT`), pulls it from the deployer and mints 1,000 shares to `0x...dEaD`. Mitigates first-depositor inflation; does not eliminate it |
| Reentrancy | OpenZeppelin `ReentrancyGuard` (`nonReentrant`) on vault `deposit`, `mint`, `withdraw`, `redeem` and `assessPerformanceFee`. Strategy entry points have no guard and are restricted to the vault with `onlyVault` |
| Flash loan callback | `unlockCallback()` reverts unless called by the PoolManager; repayment is checked against the value returned by `settle()` |
| Strategy share checks | The vault compares the strategy shares minted or burned with `previewDeposit` / `previewWithdraw` and reverts on a worse result |
| Emergency mode | Blocks vault and strategy deposits and mints. The flag does not block withdrawals, but see [Known issues](#known-issues) 1 and 2 |
| Health check | Permissionless `checkHealth()`; closes the position when the health factor is below `minHealthFactor`. Designed to exit before liquidation, depends on someone calling it |
| Recovery | Admin deactivation of emergency mode reinvests the strategy's idle balance |
| Access control | Owner manages the whitelist; admin manages configuration; the strategy can activate but not deactivate emergency mode |
| Performance fee | Charged only on gains above the high-water mark; capped at 25% by `MAX_PROTOCOL_FEE_BPS` |
| Emergency withdrawals | The strategy skips `_divest()` during emergency mode on the assumption that the position is already closed. This holds after an emergency divest, not after admin activation ([Known issues](#known-issues) 2) |

## Installation

This project uses [Foundry](https://book.getfoundry.sh/). `lib/` is not tracked and `foundry.lock` does not list OpenZeppelin, so a plain `forge install` after cloning installs nothing. Install the dependencies explicitly:

```bash
git clone https://github.com/GushALKDev/evm-yield-bearing-vaults.git
cd evm-yield-bearing-vaults

forge install --no-git foundry-rs/forge-std@v1.14.0 Uniswap/v4-core@v4.0.0 OpenZeppelin/openzeppelin-contracts@v5.5.0

cp .env_example .env
# Set ETHEREUM_MAINNET_RPC=https://... in .env (needed only for fork tests)
```

## Usage

```bash
# Build
forge build

# All tests (fork suites need ETHEREUM_MAINNET_RPC)
forge test

# Only the tests that do not need an RPC (unit, BaseVaultFuzz, invariants in mock mode)
forge test --no-match-path "test/{integration/*,fuzz/*StrategyFuzz.t.sol}"

# Coverage
forge coverage --no-match-coverage "(test|script|mock)"
```

Fork tests fork the latest mainnet block (no pinned block number), so results depend on the chain state at run time.

## Testing

Results below were obtained on commit `b15658e` with Forge 1.7.1, running the fork suites against Ethereum mainnet (September 2026).

### Test statistics

| Category | Tests | Needs RPC | Iterations |
|----------|-------|-----------|------------|
| Unit | 100 | No | - |
| Integration (fork) | 39 | Yes | - |
| Stateless fuzzing | 43 (15 mock, 28 fork) | For 28 of them | 43 x 256 runs = 11,008 |
| Stateful fuzzing (invariants) | 27 (24 invariants + 3 call-summary loggers) | No (mock mode) | 27 x 256 runs x 50 depth = 345,600 handler calls |
| **Total** | **209, all passing** | | **356,608 fuzz runs and handler calls** |

The 16 tests in `test/unit/AdapterErrorPaths.t.sol` do not import or call the adapter code; they are placeholder and arithmetic assertions. Without `ETHEREUM_MAINNET_RPC`, `forge test` runs 142 tests and the 6 fork suites fail in `setUp()`.

Fork mode for the invariant suites (`INVARIANT_USE_FORK=true FOUNDRY_PROFILE=fork-invariant`) uses 20 runs x 10 depth. In the review run the default parallel execution hit the RPC provider's rate limit (HTTP 429); with `--threads 1`, all 18 fork-mode invariant functions in `WETHLoopStrategyInvariant` and `IntegratedInvariant` passed.

### Coverage

`forge coverage --no-match-coverage "(test|script|mock)"`, all 209 tests:

| File | Lines | Statements | Branches | Functions |
|------|-------|------------|----------|-----------|
| `access/Whitelist.sol` | 25.81% (8/31) | 24.14% (7/29) | 28.57% (2/7) | 33.33% (2/6) |
| `adapters/AaveAdapter.sol` | 100.00% (15/15) | 82.35% (14/17) | 25.00% (1/4) | 100.00% (4/4) |
| `adapters/UniswapV4Adapter.sol` | 100.00% (16/16) | 94.44% (17/18) | 50.00% (1/2) | 100.00% (3/3) |
| `base/BaseStrategy.sol` | 97.44% (38/39) | 90.91% (30/33) | 83.33% (5/6) | 100.00% (15/15) |
| `base/BaseVault.sol` | 100.00% (110/110) | 95.83% (115/120) | 80.77% (21/26) | 100.00% (23/23) |
| `strategies/AaveSimpleLendingStrategy.sol` | 100.00% (14/14) | 90.91% (10/11) | 0.00% (0/1) | 100.00% (6/6) |
| `strategies/WETHLoopStrategy.sol` | 89.25% (83/93) | 78.81% (93/118) | 34.62% (9/26) | 92.31% (12/13) |
| **Total** | **89.31% (284/318)** | **82.66% (286/346)** | **54.17% (39/72)** | **92.86% (65/70)** |

### Stateless fuzzing

43 tests, 256 runs each (Foundry default; `foundry.toml` does not set `fuzz.runs`).

| Suite | Tests | Mode | Focus |
|-------|-------|------|-------|
| `BaseVaultFuzz` | 15 | Mock | Deposits (1 wei to 1,000,000 tokens), withdrawals, fees (0 to 2,500 bps), emergency mode, conversions |
| `WETHLoopStrategyFuzz` | 13 | Fork | Deposits (0.1 to 5 WETH), leverage targets 5x to 10x, withdrawals 10% to 90%, `minHealthFactor` 1.01 to 1.05, emergency trigger and recovery |
| `AaveSimpleStrategyFuzz` | 15 | Fork | Deposits (100 to 100,000 USDC), 2 to 5 users, yield over 1 to 30 days, conversions |

### Stateful fuzzing (invariants)

27 invariant functions with the handler pattern, 256 runs x 50 depth each (`[invariant]` in `foundry.toml`). Each invariant function runs its own campaign of 12,800 handler calls.

| Suite | Invariants | Handlers | Protocols in mock mode |
|-------|------------|----------|------------------------|
| `BaseVaultInvariant` | 8 + call summary | `BaseVaultHandler`, `AdminHandler` | `MockStrategy` (always mock) |
| `WETHLoopStrategyInvariant` | 8 + call summary | `WETHLoopStrategyHandler` | `MockAavePool`, `MockPoolManager`, `MockWETH` |
| `IntegratedInvariant` | 8 + call summary | All three | Same as above |

What the main invariants check, as written in the tests:

- Total supply equals the sum of the 5 actors' shares, the dead shares and the fee recipient's shares.
- The dead address holds exactly 1,000 shares.
- `convertToShares(convertToAssets(x))` returns `x` within 10 wei.
- Vault and strategy emergency flags are equal.
- Vault `totalAssets()` equals its idle balance plus strategy assets within 10 wei (`BaseVaultInvariant`), and is at least the strategy's `totalAssets()` minus 100 wei (`IntegratedInvariant`).
- Every actor holding shares is whitelisted. The admin handler only removes addresses with a zero balance.
- High-water mark `<= totalAssets() * 1.1 + 1,000`.
- Protocol fee `<= 2,500` bps.
- Leverage `collateral / (collateral - debt) <= 14.00x` while a position exists. With a 93% LTV the theoretical upper bound is `1 / (1 - 0.93) = 14.29x`, so the invariant checks that leverage never exceeds what the LTV allows, while the strategy targets 10x in these suites.
- Health factor `>= minHealthFactor - 0.01` unless emergency mode is active.
- Value accounting is checked with loose lower bounds: withdrawn plus current assets must be at least 85% (integrated) or 90% minus 1 WETH (strategy) of the deposited amount.

Mock mode limitations: `MockAavePool` does not accrue interest and does not enforce the LTV on borrow, so leverage stays at the configured 10x and the health factor stays at `10 * 0.95 / 9 = 1.0556`. The leverage and health factor invariants are therefore not stressed in mock mode, and `checkHealth()` never triggers an emergency divest there. In `IntegratedInvariant`, the admin handler toggles emergency mode without closing the position, and handler reverts are tolerated because `fail_on_revert = false` (about 12% of handler calls reverted in the review run).

See [test/README.md](test/README.md) for the per-test breakdown.

## Gas

### Optimizations applied

- Storage packing in `BaseVault`: `strategy` (20 bytes), `protocolFeeBps` (2 bytes) and `emergencyMode` (1 byte) share slot 7.
- Storage reads cached in local variables (`strategy`, `protocolFeeBps`, `feeRecipient`, `highWaterMark`).
- Immutables and `asset()` cached in local variables. The gas effect is negligible, since immutables are embedded in the bytecode.
- `unchecked` arithmetic where the bounds are checked beforehand.
- Whitelist add and remove return early when the state would not change, skipping a redundant storage write and event.
- Batch whitelist functions (`addBatchToWhitelist`, `removeBatchFromWhitelist`).
- Modifiers delegate to internal functions to reduce bytecode size.
- Custom errors instead of revert strings.

The repository does not contain before and after measurements for these changes.

### Measured costs

Because the repository's own `forge test --gas-report` fails ([Known issues](#known-issues) 4), these figures come from a separate measurement harness that is not part of the repository. It deploys the same contracts with the same parameters as the tests (10x leverage, `minHealthFactor` 1.02, `targetHealthFactor` 1.05, E-Mode 1), makes an initial 1 WETH deposit, and runs one scenario per `forge test --gas-report` invocation. Values are the gas reported by `--gas-report`, which runs each call as a separate transaction. Commit `b15658e`.

| Function | Scenario | Mock mode | Mainnet fork |
|----------|----------|-----------|--------------|
| `vault.deposit` | 1 WETH, first deposit, empty position | 360,248 | 494,319 |
| `vault.deposit` | 1 WETH into an existing position | 262,250 | 392,887 |
| `vault.mint` | Shares for 1 WETH into an existing position | 262,284 | 392,941 |
| `vault.withdraw` | 0.5 WETH from a 1 WETH position | 255,422 | 391,627 |
| `vault.redeem` | 50% of the shares of a 1 WETH position | 249,841 | 379,201 |
| `strategy.checkHealth` | Healthy, no action | 45,582 | 115,560 |
| `strategy.checkHealth` | Emergency divest of 10 WETH collateral / 9 WETH debt | 214,407 | 344,198 |
| `vault.setEmergencyMode(false)` | Recovery, reinvest about 1 WETH at 10x | 218,405 | 311,106 |

Mock mode uses `MockAavePool`, `MockPoolManager` and `MockWETH`, whose gas costs are not representative of the real protocols. The fork column was measured against Ethereum mainnet around block 26043110.

## Tech stack

- Solidity 0.8.26, EVM version Cancun, optimizer 200 runs
- Foundry (Forge 1.7.1 used for the results above)
- OpenZeppelin Contracts v5.5.0
- Uniswap V4 Core v4.0.0
- Aave V3 (mainnet deployment, accessed through a local `IPool` interface)

## Roadmap

- [x] ERC-4626 vault
- [x] Aave simple lending strategy
- [x] Leveraged loop strategy (WETH)
- [x] Proportional deleveraging
- [x] Performance fee with high-water mark
- [x] Emergency mode circuit breaker
- [x] Permissionless health check with emergency divest
- [x] Automatic reinvestment on emergency recovery
- [x] Test suite (209 tests, 89.31% line coverage)
- [x] Stateless fuzzing (43 tests, 11,008 runs)
- [x] Stateful fuzzing (27 invariant functions, 345,600 handler calls)
- [x] Gas optimizations (storage packing, caching, unchecked math)
- [ ] Fix the [known issues](#known-issues)
- [ ] Keeper for `checkHealth()`
- [ ] Loop strategies with yield-bearing collateral (stETH, rETH, cbETH)
- [ ] Multi-asset vaults

## License

MIT, as declared in the SPDX headers. The repository does not include a LICENSE file.

---

Built by **GushALKDev**
