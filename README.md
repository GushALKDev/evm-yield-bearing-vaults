# Yield Bearing Vaults

![Status](https://img.shields.io/badge/Status-Proof%20of%20concept-lightgrey)
![License](https://img.shields.io/badge/License-MIT-green)
![Solidity](https://img.shields.io/badge/Solidity-0.8.26-blue)
![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)

![Tests](https://img.shields.io/badge/Tests-365%20passing%20%2B%2010%20gas%20benchmarks-brightgreen)
![Coverage](https://img.shields.io/badge/Line%20coverage-98.60%25-brightgreen)
![Invariants](https://img.shields.io/badge/Invariants-27-blue)
![Fuzzing](https://img.shields.io/badge/Fuzzing-359%2C168%20runs%20%2B%20calls-blue)

A modular ERC-4626 vault with pluggable strategies. The repository contains a simple Aave V3 supply strategy and a leveraged WETH loop strategy that uses Uniswap V4 flash loans and Aave V3 E-Mode.

## Status

Proof of concept. Not audited and not deployed.

The repository contains no deployment scripts (`script/` is empty) and no `broadcast/` directory. Reviews of the documentation, the tests and the code found 18 issues; all are fixed, each with a regression test, see [Review notes](#review-notes). Do not use this code with real funds.

## Overview

- **Vault and strategy split.** `YieldBearingVault` is an ERC-4626 vault that holds shares of a single ERC-4626 strategy. Deposits are forwarded to the strategy in the same transaction. On withdrawal the vault first uses its own idle balance and withdraws only the shortfall from the strategy.
- **Leveraged WETH loop.** `WETHLoopStrategy` uses a Uniswap V4 flash loan and Aave V3 E-Mode (category 1, "ETH correlated") to build a leveraged WETH position. The tests use 10x. The code accepts any integer `targetLeverage >= 2`; with the E-Mode LTV of 93% at the pinned fork block, Aave accepts a fresh position at 14x and rejects one at 15x (`LeverageBoundsForkTest`).
- **Negative carry.** The WETH loop demonstrates the leverage mechanics. Because collateral and debt are the same asset in the same Aave reserve, the loop has negative carry; a positive spread requires yield-bearing collateral such as an LST (see [Roadmap](#roadmap)). See [Economics of the WETH loop](#economics-of-the-weth-loop).
- **Emergency mode.** Activating emergency mode, by the admin or by the health check, blocks deposits and attempts to close the external position. If the close fails, emergency mode stays active and withdrawals deleverage proportionally. Strategy accounting counts idle assets, so withdrawals during emergency mode pay the pro rata share of equity.
- **Health check.** `WETHLoopStrategy.checkHealth()` is a permissionless function. When the Aave health factor is below `minHealthFactor`, it activates emergency mode. It is designed to exit the position before liquidation, but it only runs when someone calls it. The repository does not include a keeper.
- **Recovery in two steps.** The vault admin first deactivates emergency mode, which only clears the flags, and then calls `vault.reinvest()`, which invests the strategy's idle balance at the current `targetLeverage` and reverts unless the health factor reaches `targetHealthFactor`. The thresholds are asymmetric: the strategy trips below `minHealthFactor` and re-arms only at or above `targetHealthFactor` (`1e18 < minHealthFactor < targetHealthFactor`).
- **Performance fee with high-water mark.** Performance fees are only charged on gains above the previous high-water mark. The fee is assessed before each deposit, mint, withdraw and redeem is priced, and is minted as vault shares to the fee recipient, which must be whitelisted. Conversions and previews count the pending fee, so they match those calls.
- **Permissioned ERC-4626.** The vault implements the ERC-4626 interface on top of OpenZeppelin Contracts v5.7.0. It is permissioned: deposit and mint receivers, share transfer recipients and the fee recipient must be whitelisted. Withdrawals and redemptions are not whitelist-gated. The `max*` functions report 0 or a lower amount whenever the call could revert (see [Trust assumptions and limitations](#trust-assumptions-and-limitations)).
- **Flash loan provider.** Uniswap V4 charged no flash loan fee at the time of writing. Aave V3's flash loan premium was 0.05% at the time of writing (`FLASHLOAN_PREMIUM_TOTAL = 5` bps at block 26043110). Neither value is fixed.

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
| `BaseStrategy` | Abstract ERC-4626 strategy that only accepts deposits from its vault; `_invest()`, `_divest()` and `_exitPosition()` hooks; decimals offset of 6 |
| `AaveSimpleLendingStrategy` | Supplies the asset to Aave V3, no leverage. Amounts that Aave would mint as 0 scaled aTokens stay idle. `checkHealth()` always returns `true` |
| `WETHLoopStrategy` | Leveraged WETH strategy using Uniswap V4 flash loans and Aave V3 E-Mode |
| `AaveAdapter` | Library for Aave V3 supply, withdraw, borrow (variable rate) and repay |
| `UniswapV4Adapter` | Abstract adapter implementing flash loans through `unlock` / `unlockCallback`; records the outstanding loan in transient storage |
| `Whitelist` | `Ownable` whitelist of addresses |

### Roles

| Role | Holder | Can call |
|------|--------|----------|
| Owner | `Ownable` owner of the vault (constructor `_owner`) | `addToWhitelist`, `removeFromWhitelist`, `addBatchToWhitelist`, `removeBatchFromWhitelist` (the current fee recipient cannot be removed), `transferOwnership`. `renounceOwnership` always reverts |
| Admin | Vault `admin` (constructor `_admin`) | Vault: `setAdmin`, `setStrategy` (not during emergency mode), `setEmergencyMode`, `reinvest`, `setProtocolFee`, `setFeeRecipient` (whitelisted addresses only). Strategy: `setLeverage`, `setHealthFactors`, `harvest` (reverts in both strategies) |
| Strategy | The vault's current `strategy` | `activateEmergencyMode()` on the vault (activate only) |
| Vault | The strategy's immutable `VAULT` | Strategy `deposit`, `mint`, `withdraw`, `redeem`, `setEmergencyMode`, `reinvest` |
| Strategy itself | The strategy contract | `exitPosition()` (called from `setEmergencyMode` inside try/catch) |
| Anyone | Any address | `checkHealth()` on the strategies, `assessPerformanceFee()` on the vault |

## WETHLoopStrategy flow

### Investment (leverage loop)

```
1. The vault deposits X WETH into the strategy; if X < MIN_INVEST_ASSETS (1e12 wei) it stays idle and
   the steps below are skipped
2. Strategy flash-borrows X * (L - 1) WETH from the Uniswap V4 PoolManager
3. Strategy supplies X * L WETH to Aave; idle WETH already in the strategy is left for reinvest()
4. Strategy borrows X * (L - 1) WETH from Aave at the variable rate
5. Strategy repays the flash loan with the borrowed WETH
6. Strategy reverts with HealthFactorBelowMinimum if the position's health factor is below minHealthFactor
7. Result: X * L collateral, X * (L - 1) debt

Example with L = 10 and a 1 WETH deposit:
- Collateral: 10 WETH | Debt: 9 WETH | Net equity: 1 WETH
```

### Divestment (proportional deleverage)

```
1. The vault requests Y WETH from the strategy (only the part it cannot pay from its idle balance)
2. The strategy pays from its own idle WETH first; N = Y - idle is taken from the position
3. netEquity = collateral - debt
4. If netEquity - N < MIN_REMAINING_EQUITY (1e12 wei): repay all debt and withdraw all collateral;
   the surplus above N stays as idle WETH
5. Otherwise: debtToRepay = ceil(debt * N / netEquity), collateralToWithdraw = debtToRepay + N
6. Strategy flash-borrows debtToRepay WETH from the Uniswap V4 PoolManager, repays it to Aave,
   withdraws collateralToWithdraw and repays the flash loan
7. Result: remaining equity is exactly netEquity - N and leverage does not increase

Example: 50% withdrawal from 10 WETH collateral / 9 WETH debt:
- Repay 4.5 WETH debt | Withdraw 5 WETH collateral | Return 0.5 WETH
```

If the strategy has no debt it withdraws `N` directly. If collateral is less than or equal to debt the call reverts with `InsufficientEquity()`.

### Emergency divest

```
1. Emergency mode is activated in one of two ways:
   a. Anyone calls checkHealth(); Aave reports healthFactor < minHealthFactor;
      the strategy calls vault.activateEmergencyMode()
   b. The admin calls vault.setEmergencyMode(true)
2. The vault sets its flag and calls strategy.setEmergencyMode(true)
3. The strategy sets its flag, reverts with InsufficientGasForExit unless gasleft() covers
   EXIT_GAS * 64 / 63 plus a 5,000 gas overhead, and calls exitPosition() inside try/catch:
   flash-borrows the total debt, repays it, withdraws all collateral, repays the flash loan,
   and reverts with EmergencyDivestFailed() if any debt remains
4. On success, the WETH stays in the strategy as idle equity, counted by totalAssets()
5. On failure, EmergencyExitFailed(reason) is emitted, emergency mode stays active and the position
   stays open; calling setEmergencyMode(true) again retries the exit, and so does checkHealth()
   while the health factor is still below minHealthFactor (otherwise it returns true and does nothing)
6. While emergency mode is active: vault and strategy deposits and mints revert;
   withdrawals pay from idle WETH, or deleverage proportionally if the position is still open
```

### Recovery

```
1. Admin calls vault.setEmergencyMode(false)
2. The vault clears its flag and calls strategy.setEmergencyMode(false), which clears the strategy flag
   and does not touch the idle WETH, so this step cannot fail because of the protocols
3. Deposits are accepted again; each deposit invests only itself at targetLeverage and reverts
   if the position ends below minHealthFactor
4. Admin calls vault.reinvest(), which reverts while emergency mode is active, deposits the vault's
   own idle WETH (initial deposit, donations) into the strategy and calls strategy.reinvest():
   the whole idle WETH balance is invested at the current targetLeverage, unless it is below
   MIN_INVEST_ASSETS, in which case it stays idle
5. The strategy reads the Aave health factor of the whole position and reverts with
   HealthFactorBelowTarget unless it is at or above targetHealthFactor
```

If step 4 or 5 reverts (for example without flash loan liquidity, or with a `targetHealthFactor` the target leverage cannot reach), emergency mode stays off and the idle WETH stays idle: it counts in `totalAssets()` and pays withdrawals first.

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

With the WETH reserve rates at the pinned block 26043110 (supply 1.41%, variable borrow 2.02%), the same formula gives about -4.1% per year at 10x.

Consequence for the health factor. Debt grows at `r` and collateral grows at `s < r`, so the health factor drifts down over time even if prices do not move. Collateral and debt are both WETH, so a WETH price move does not change the health factor; interest accrual and changes to Aave's risk parameters do.

```
HF    = collateral * LT / debt
HF_0  = L * LT / (L - 1)
HF(t) ~ HF_0 * exp(-(r - s) * t)
t     = ln(HF_0 / HF_min) / (r - s)      (time until HF reaches HF_min)
```

With the E-Mode liquidation threshold at the pinned block (`LT = 95%`, checked by `LeverageBoundsForkTest`):

- `L = 10`: `HF_0 = 10 * 0.95 / 9 = 1.0556`.
- `L = 14`: `HF_0 = 14 * 0.95 / 13 = 1.0231`, close to the `minHealthFactor` of 1.02 used in the tests.

Illustrative drift at 10x with `minHealthFactor = 1.02`: with `r - s = 0.8` percentage points (the example above), HF reaches 1.02 after about 4.3 years and 1.00 after about 6.8 years. With the rates at the pinned block (`r - s = 0.61` points), HF reaches 1.02 after about 5.6 years. A sustained spread of 5 percentage points (for example during a utilization spike) reaches 1.02 in about 8 months. This is why the emergency divest path, and someone calling `checkHealth()` in time, matters.

The reserve rates can be read at the pinned block with the command below. The third field is the supply (liquidity) rate and the fifth the variable borrow rate, both in ray (1e27 = 100%).

```bash
cast call 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 "getReserveData(address)((uint256,uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128))" 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 --block 26043110 --rpc-url $ETHEREUM_MAINNET_RPC
```

## Trust assumptions and limitations

- **Admin powers.** The admin can:
  - replace the strategy at any time with `setStrategy()`. The new strategy receives an unlimited allowance of the vault asset and all future deposits; funds in the old strategy are not migrated and stop being counted in `totalAssets()`;
  - set the protocol fee (up to 2,500 bps, 25%) and the fee recipient;
  - activate emergency mode, which closes the external position, deactivate it, and reinvest the strategy's idle balance at the current leverage with `reinvest()`;
  - change `targetLeverage` (any integer >= 2, no upper bound in code) and the health factor thresholds (`1e18 < min < target`, no upper bound). Raising `minHealthFactor` above the current health factor lets anyone trigger an emergency divest; the tests use this to simulate an unhealthy position;
  - transfer the admin role with `setAdmin()`.
  The admin cannot replace the strategy while emergency mode is active.
  There is no timelock.
- **Owner powers.** The owner controls the whitelist and can transfer ownership. `renounceOwnership()` always reverts, so the whitelist always has an owner.
- **Keeper liveness.** `checkHealth()` is permissionless, but the repository does not include a keeper, bot or script that calls it. If nobody calls it in time, the emergency divest does not happen and the position can be liquidated.
- **Emergency exit gas.** The exit runs inside try/catch so that emergency mode can be activated even when the exit fails. Activation reverts with `InsufficientGasForExit` unless `exitPosition()` will receive `EXIT_GAS` (450,000 for the WETH loop, 250,000 for the Aave simple strategy), so a caller cannot activate emergency mode with the position open by limiting gas. The measured exit costs at the pinned block are 288,613 and 156,070 gas (see the NatSpec of `EXIT_GAS` for the commands). The constants are fixed: if an Aave or Uniswap upgrade raised the exit cost above them, a caller could again send enough gas for the check but not for the exit. A genuine exit failure, such as missing flash loan liquidity, still activates emergency mode and emits `EmergencyExitFailed`; `setEmergencyMode(true)` retries it, and so does `checkHealth()` while the health factor is below `minHealthFactor`.
- **Flash loan liquidity.** Investment, proportional divestment and the emergency exit all flash-borrow WETH from the Uniswap V4 PoolManager. The exit borrows the full debt. At block 26043110 the PoolManager held 1,004.74 WETH (command below), which at 10x limits a single deposit to about 111.6 WETH (1,004.74 / 9) and a position the exit can close to about 111.6 WETH of equity. `maxWithdraw()` and `maxRedeem()` account for this limit. Some older fork tests `deal` 10,000 WETH to the PoolManager; the regression tests, the gas benchmark and `LeverageBoundsForkTest` use its real balance.

  ```bash
  cast call 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 "balanceOf(address)(uint256)" 0x000000000004444c5dc75cB358380D2e3dE08A90 --block 26043110 --rpc-url $ETHEREUM_MAINNET_RPC
  ```
- **Aave parameters.** LTV (93%), liquidation threshold (95%) and E-Mode category 1 parameters are the values at block 26043110. They are set by Aave governance and can change; a lower liquidation threshold lowers the health factor of an existing position immediately.
- **Negative carry.** The WETH loop loses value over time at typical rates; see [Economics of the WETH loop](#economics-of-the-weth-loop).
- **No rebalancing.** Leverage is only applied when assets are invested. `setLeverage()` affects future deposits and reinvestments, not the existing position. `targetHealthFactor` is only checked by `reinvest()`. `harvest()` reverts in both strategies.
- **Dust exits.** A withdrawal that would leave less than `MIN_REMAINING_EQUITY` (1e12 wei) in the position closes the whole position; the remaining equity stays as idle WETH until the admin calls `reinvest()`.
- **ERC-4626 limits.** `maxDeposit()` and `maxMint()` return 0 during emergency mode, for receivers that are not whitelisted, and when a WETH loop investment could end below `minHealthFactor` (see "Deposits and the health factor" below); `type(uint256).max` otherwise. They underestimate when needed, as ERC-4626 allows: deposits below `MIN_INVEST_ASSETS`, and deposits whose combined position stays above the minimum, succeed while they report 0. Other reasons a deposit can revert are not modeled: Aave supply or borrow caps, a paused or frozen reserve, Aave's LTV check (for example at 15x) and missing flash loan liquidity.
  `maxWithdraw()` and `maxRedeem()` are capped by what the vault can pay now: its idle balance plus what the strategy can pay. The WETH loop mirrors both `_divest()` paths: a full close needs the whole debt in PoolManager liquidity and the equity in Aave liquidity; a proportional deleverage of `n` needs `ceil(debt * n / equity)` in PoolManager liquidity, `n` in Aave liquidity and leaves at least `MIN_REMAINING_EQUITY`. Nothing is taken from the position while Aave's reserve is paused, while collateral does not exceed debt or while the health factor is below 1. The Aave simple strategy is capped by Aave's liquidity. This holds in normal and emergency mode.
  `deposit()`, `mint()`, `withdraw()` and `redeem()` compare only against the owner's balance or the receiver's whitelist status and emergency mode, not against the `max*` functions: every other limit is enforced where it applies, with its specific revert reason.
- **Dust investments.** Amounts below `MIN_INVEST_ASSETS` (1e12 wei) are not invested by the WETH loop, and amounts that Aave would mint as 0 scaled aTokens are not supplied by the Aave simple strategy: without an existing position, Aave reverts on them (1,000 wei at 10x, and a 1 wei supply, at the pinned block). They stay idle, count in `totalAssets()`, pay withdrawals first and are invested by `reinvest()` once the idle balance is large enough.
- **Deposits and the health factor.** Every WETH loop investment (deposit, mint or `reinvest()`) reverts with `HealthFactorBelowMinimum` if the position ends below `minHealthFactor`. This happens when `minHealthFactor` is above the health factor that `targetLeverage` gives (for example after Aave lowers the liquidation threshold, or after the admin raises `minHealthFactor`), and also when an existing position has drifted below `minHealthFactor` before anyone called `checkHealth()`. `maxDeposit()` and `maxMint()` return 0 in both cases without simulating the deposit: with one collateral and one debt asset the resulting position is the mediant of the existing position and the invested slice, so it stays at or above the minimum when both do. The existing position's health factor comes from Aave (only when it has debt) and the slice's is `L * LT / (L - 1)` with the live liquidation threshold (the E-Mode category's, or the reserve's without E-Mode). Both are reduced by `HEALTH_FACTOR_MARGIN_BPS` (0.1%) before the comparison, because Aave's rounding leaves a real position slightly below the implied value (`test_MaxDeposit_MarginCoversAaveRounding` shows it for the smallest 2x slice at the pinned block and fails with a zero margin); the margin covers the smallest investable slice for any leverage while WETH is priced above 30 USD.
- **Whitelist scope.** The whitelist is checked on the deposit or mint receiver (not the caller), on the recipient of share transfers and on the fee recipient, which receives the fee shares: `setFeeRecipient()` requires a whitelisted address, and the current fee recipient cannot be removed from the whitelist (`FeeRecipientNotRemovable`); the admin first moves the fee to another address. Addresses removed from the whitelist keep their shares and can still withdraw and transfer to whitelisted addresses.
- **High-water mark details.** The high-water mark is an aggregate asset amount, not a per-share price. It increases by deposited assets, decreases by withdrawn assets, and is raised to `totalAssets()` when fees are assessed with a non-zero rate and a recipient set. While the fee is 0 or no recipient is set, it is not raised, so enabling the fee later charges it on gains accrued before.
- **Share inflation.** The vault's 1,000 wei dead shares raise the cost of a first-depositor inflation attack on vault shares; they do not eliminate it, and the vault has no decimals offset. The strategies use a decimals offset of 6: strategy shares are only held by the vault, so the vault's dead shares do not protect strategy share pricing, and counting idle assets would otherwise let a donation to an empty strategy round the vault's strategy shares to zero. With the offset, a 1 WETH donation before a 1 WETH first deposit leaves the depositor at least 99.9999% of the deposit (`test_Donation_BeforeFirstDeposit_DoesNotDiluteDepositor`); rounding a deposit down to zero strategy shares would require a donation of about 1e6 times the deposit.
- **Not audited.**

## Review notes

Reviews of the documentation against the code (1 to 4), of the invariants (5), of the emergency and stop mechanisms (6 to 14) and a final code review (15 to 18) found the issues below. Each has a regression test that was run against the code without its fix and failed: on the parent of the fix commit, or on the tree before the fix was written (1 to 10, 15 to 18; for 6 a copy of the tests without the new `reinvest()` calls), or with the new check disabled where the tests call an API the fix adds (11 to 14). Mock and fork variants share one abstract test contract.

| # | Issue | Fix commit | Regression tests |
|---|-------|------------|------------------|
| 1 | Idle WETH not counted after an emergency divest | `93d043b` | `EmergencyAccountingMockTest`, `EmergencyAccountingForkTest` |
| 2 | Admin-activated emergency mode blocked withdrawals | `4291057` | `EmergencyActivationMockTest`, `EmergencyActivationForkTest` |
| 3 | Full exit through the vault reverted | `3af50b4` | `FullExitMockTest`, `FullExitForkTest`, `GasBenchmarkForkTest.test_Gas_Redeem` |
| 4 | `forge test --gas-report` failed in `setUp()` | `65b3bd9` | `forge test --gas-report` |
| 5 | Performance fee assessed after pricing | `162cfea` | `PerformanceFeeTimingTest`, `invariant_ConversionReversibility` |
| 6 | Leaving emergency mode reinvested with no health check and could not complete if the reinvestment reverted | `bb1beb2` | `EmergencyRecoveryMockTest`, `EmergencyRecoveryForkTest`, `invariant_ReinvestMeetsTargetHealthFactor` |
| 7 | `maxDeposit`/`maxMint` were unlimited during emergency mode and for non-whitelisted receivers | `1ffce8e` | `BaseVaultTest.test_MaxDeposit_*`, `BaseVaultTest.test_MaxMint_*` |
| 8 | Health factor thresholds had no bounds | `93e8db7` | `HealthFactorBoundsTest` |
| 9 | `setStrategy` during emergency mode left vault and strategy flags out of sync | `7c4610f` | `BaseVaultTest.test_SetStrategy_RevertIfEmergency` |
| 10 | `renounceOwnership` would freeze the whitelist | `6f26f54` | `WhitelistTest.test_RenounceOwnership_*` |
| 11 | A deposit could open a position below `minHealthFactor` | `1f9b997` | `EmergencyRecovery*Test.test_DepositAfterExit_RevertsBelowMinHealthFactor` |
| 12 | Dust investments reverted in Aave | `543989d`, `151c57f` | `EmergencyRecovery*Test.test_Reinvest_DustIdleStaysIdle`, `test_Deposit_DustStaysIdleUntilReinvest`, `test_AaveSimple_DustStaysIdle` |
| 13 | The vault's own idle balance was never reinvested | `aa2da50` | `EmergencyRecovery*Test.test_Reinvest_MovesVaultIdleIntoStrategy` |
| 14 | `maxDeposit`/`maxMint` ignored the minimum health factor | `8495c95`, `e0e3d16` | `MaxDepositHealthMockTest`, `MaxDepositHealthForkTest`, `testFuzz_MaxDeposit_NeverOverstates`, `invariant_MaxDepositNeverOverstated` |
| 15 | Previews and conversions ignored the pending performance fee | `68a7cb3` | `PreviewWithFeeTest`, `PreviewFeeFuzzTest` |
| 16 | Emergency activation could be griefed with a gas limit | `5cfe901`, `9f599c4` | `EmergencyExitGasMockTest`, `EmergencyExitGasForkTest` |
| 17 | `maxWithdraw`/`maxRedeem` ignored liquidity limits | `3d50867` | `MaxWithdrawMockTest`, `MaxWithdrawForkTest`, `testFuzz_MaxWithdraw_NeverOverstates`, `testFuzz_MaxRedeem_NeverOverstates` |
| 18 | Fee shares could be minted to a non-whitelisted fee recipient | `a6191b2` | `FeeRecipientWhitelistTest`, `invariant_WhitelistEnforcement`, `invariant_WhitelistIntegrity` |

1. **Idle WETH not counted.** Root cause: `WETHLoopStrategy.totalAssets()` returned `aToken - debt`, but an emergency divest leaves the equity as WETH in the strategy, so the strategy reported about 0 assets. A user who deposited 1 WETH and redeemed during emergency mode received 1,000 wei (the vault's initial deposit). `AaveSimpleLendingStrategy.totalAssets()` had the same pattern. Fix: `totalAssets()` returns `collateral + idle WETH - debt - outstanding flash loan` (the adapter records the loan in a transient slot during `unlockCallback`, so borrowed WETH never counts as equity); `AaveSimpleLendingStrategy` adds idle assets; both `_divest()` implementations pay from idle assets first; `BaseStrategy` sets a decimals offset of 6 against donations to an empty strategy (see [Trust assumptions and limitations](#trust-assumptions-and-limitations)).
2. **Admin emergency blocked withdrawals.** Root cause: `BaseStrategy._withdraw()` skipped `_divest()` in emergency mode on the assumption that the position was already closed, which only held after a health-check divest. With `setEmergencyMode(true)` from the admin, the position stayed open and every withdrawal that needed strategy funds reverted, in both strategies. Fix: every activation calls `exitPosition()` inside try/catch (WETH loop: close the position; Aave simple: withdraw the supply); `_withdraw()` always calls `_divest()`, which pays from idle assets and otherwise deleverages proportionally. Design choice: a failed exit leaves emergency mode active and emits `EmergencyExitFailed`, and withdrawals still work.
3. **Full exit reverted.** Root cause: the vault pays part of a redemption from its idle balance, so the last depositor's redemption asked the strategy for slightly less than its equity. The proportional deleverage left about 10,000 wei of collateral against 9,000 wei of debt. Aave values debt rounding up and collateral rounding down in its 8-decimal base currency; at block 26043110 that dust position had `debtBase = 1` and `collateralBase = 0`, so the collateral withdrawal reverted with `HealthFactorLowerThanLiquidationThreshold()`. Fix: a withdrawal that would leave less than `MIN_REMAINING_EQUITY` (1e12 wei) closes the whole position; otherwise debt repayment rounds up and the collateral withdrawn is `debtRepaid + assets`, so the remaining equity is exact and leverage does not increase.
4. **Gas report failed.** Root cause: gas reports run in isolation mode, where each pranked call is a transaction that bumps the sender's nonce, so the vault address predicted with `vm.computeCreateAddress` for the initial-deposit approval was wrong. Fix: tests approve a deployed `VaultDeployer` helper, which pulls the initial deposit and deploys the vault with CREATE2.
5. **Fee assessed after pricing.** Root cause: the fee was assessed inside `_deposit`/`_withdraw`, after ERC-4626 had priced the operation. An exiting user was paid the pre-fee share price (skipping the fee) and the fee shares then diluted the remaining holders. In the test, a user redeeming after a 10 WETH profit on 100 WETH with a 10% fee received 110 WETH instead of 109. Fix: `deposit`, `mint`, `withdraw` and `redeem` assess the fee before pricing, and fee shares are priced against assets net of the fee, so they are worth the fee amount after minting.
6. **Recovery without a health check.** Root cause: `setEmergencyMode(false)` reinvested in the same transaction without checking the resulting health factor, so re-arming could trip emergency mode again, and a failing reinvestment (for example without flash loan liquidity) made it impossible to leave emergency mode. Fix: deactivation only clears the flags; the admin calls `reinvest()` separately, which reverts with `HealthFactorBelowTarget` unless the position reaches `targetHealthFactor`; deposits invest only their own principal, so idle WETH is invested only through `reinvest()`.
7. **Deposit limits during emergency mode.** Root cause: `maxDeposit()` and `maxMint()` were not overridden and returned `type(uint256).max` while deposits reverted. Fix: they return 0 during emergency mode and for receivers that are not whitelisted; `deposit` and `mint` check emergency mode and the whitelist first, keeping `VaultInEmergency` and `NotWhitelisted` as revert reasons.
8. **Unbounded thresholds.** Root cause: the only check was `min < target`, so `minHealthFactor` could be at or below 1e18, where Aave liquidates. Fix: the constructor and `setHealthFactors` require `1e18 < minHealthFactor < targetHealthFactor`.
9. **Strategy replaced during emergency mode.** Root cause: a new strategy starts with its emergency flag off while the vault's is on. Fix: `setStrategy` reverts with `VaultInEmergency`.
10. **Renounced ownership.** Root cause: renouncing would leave the whitelist with no owner, so it could never change again. Fix: `renounceOwnership` always reverts with `RenounceOwnershipDisabled`.
11. **Deposit below the minimum health factor.** Root cause: a deposit invested at `targetLeverage` without checking the result, so after leaving emergency mode with `minHealthFactor` above what the leverage gives (for example after Aave lowered the liquidation threshold), a deposit opened a position that `checkHealth()` could close right away (in the regression test the minimum is 0.01 above the 10x health factor of 1.0556). Fix: every investment reverts with `HealthFactorBelowMinimum` if the position ends below `minHealthFactor`.
12. **Dust investments.** Root cause: without an existing position, investing 1,000 wei at 10x reverted in Aave, as did a 1 wei supply to the Aave simple strategy (0 scaled aTokens), so dust deposits and `reinvest()` of dust reverted at the pinned block. Fix: the WETH loop keeps amounts below `MIN_INVEST_ASSETS` (1e12 wei) idle; the Aave simple strategy keeps idle any amount that would mint 0 scaled aTokens; idle assets count in `totalAssets()`, pay withdrawals first and are invested by `reinvest()`.
13. **Vault idle balance.** Root cause: `reinvest()` only invested the strategy's idle WETH; the vault's own balance (the initial deposit and donations) was never invested. Fix: `vault.reinvest()` deposits it into the strategy first, with the usual share check.
14. **Deposit limits and the health factor.** Root cause: with fix 11, deposits could revert with `HealthFactorBelowMinimum` while `maxDeposit()` reported an unlimited amount. Fix: `maxDeposit()` and `maxMint()` return 0 when the existing position (if it has debt) or the slice implied by `targetLeverage` and the live liquidation threshold is below `minHealthFactor`, with a 0.1% margin for Aave's rounding (see [Trust assumptions and limitations](#trust-assumptions-and-limitations)).
15. **Previews and the pending fee.** Root cause: after fix 5, the calls mint the pending fee before pricing, but `convertTo*` and `preview*` priced against the pre-fee supply. With a 10% fee on 10 WETH of profit, `previewRedeem` promised 10.9999 WETH for shares that `redeem` paid 10.8999 WETH for, which ERC-4626 forbids. Fix: `_pendingFee()` computes, without state changes, the fee shares the next assessment would mint; the conversions add them to `totalSupply()`. `totalAssets()` is unchanged because the fee is paid in shares.
16. **Emergency exit gas griefing.** Root cause: `checkHealth()` is permissionless and the exit runs inside try/catch; with a gas limit (the regression test's sweep found it at its first step, 100,000 gas, in mock and fork), the outer frames succeeded while `exitPosition()` ran out of gas, activating emergency mode with the position open, through `checkHealth()` and through the admin activation. Fix: activation reverts with `InsufficientGasForExit` unless `gasleft()` covers `EXIT_GAS * 64 / 63` plus a 5,000 gas overhead, checked right before the call (see [Trust assumptions and limitations](#trust-assumptions-and-limitations)).
17. **Withdrawal limits and liquidity.** Root cause: `maxWithdraw()` and `maxRedeem()` returned the owner's full balance, but the proportional deleverage borrows `debt * assets / equity` from the PoolManager, a full close borrows the whole debt, and Aave's liquidity, a paused reserve or a health factor below 1 also block withdrawals; `withdraw(maxWithdraw(owner))` reverted with limited flash loan liquidity. Fix: both functions are capped by what the vault and the strategy can pay now (see [Trust assumptions and limitations](#trust-assumptions-and-limitations)).
18. **Fee recipient outside the whitelist.** Root cause: fee shares were minted to the fee recipient with no whitelist check, so a non-whitelisted address could hold shares. Fix: `setFeeRecipient()` requires a whitelisted address, and the current fee recipient cannot be removed from the whitelist (single or batch removal reverts with `FeeRecipientNotRemovable`). Reverting is the only option that neither breaks the property nor changes the fee silently: skipping the mint or clearing the recipient would.

## Security considerations

| Topic | Implementation |
|-------|----------------|
| Share inflation | The vault constructor requires exactly 1,000 wei (`REQUIRED_INITIAL_DEPOSIT`) and mints 1,000 shares to `0x...dEaD`. Strategies use a decimals offset of 6. Both mitigate inflation attacks; neither eliminates them |
| Reentrancy | OpenZeppelin `ReentrancyGuard` (`nonReentrant`) on vault `deposit`, `mint`, `withdraw`, `redeem` and `assessPerformanceFee`, checked by `ReentrancyTest` with a callback token. Strategy entry points have no guard and are restricted to the vault with `onlyVault` |
| Flash loan callback | `unlockCallback()` reverts unless called by the PoolManager; repayment is checked against the value returned by `settle()`; the outstanding loan is excluded from `totalAssets()` while the callback runs |
| Strategy share checks | The vault compares the strategy shares minted or burned with `previewDeposit` / `previewWithdraw` and reverts on a worse result |
| Emergency mode | Blocks vault and strategy deposits and mints and attempts to close the external position; activation reverts unless the exit receives `EXIT_GAS`; withdrawals pay from idle assets or deleverage proportionally |
| Health check | Permissionless `checkHealth()`; activates emergency mode when the health factor is below `minHealthFactor`. Designed to exit before liquidation, depends on someone calling it |
| Recovery | Two steps: admin deactivation only clears the flags; admin `reinvest()` moves the vault's idle balance into the strategy, invests the strategy's idle balance and requires the health factor to reach `targetHealthFactor` |
| Investment health | Every WETH loop investment requires the health factor to stay at or above `minHealthFactor`; dust amounts stay idle instead of reverting in Aave |
| ERC-4626 limits | `maxDeposit`/`maxMint` report 0 whenever a deposit could revert for emergency mode, the whitelist or the minimum health factor; `maxWithdraw`/`maxRedeem` are capped by the liquidity the vault and strategy can pay out; previews and conversions count the pending performance fee |
| Access control | Owner manages the whitelist and cannot renounce ownership or remove the current fee recipient; admin manages configuration; the strategy can activate but not deactivate emergency mode; `exitPosition()` only accepts calls from the strategy itself |
| Performance fee | Assessed before each deposit, mint, withdraw and redeem is priced; charged only on gains above the high-water mark; capped at 25% by `MAX_PROTOCOL_FEE_BPS`; minted only to a whitelisted fee recipient |
| Rounding | Proportional deleverage rounds debt repayment up; withdrawals that would leave dust close the position |

## Installation

This project uses [Foundry](https://book.getfoundry.sh/). Dependencies are git submodules, pinned in `foundry.lock`:

| Submodule | Version |
|-----------|---------|
| `lib/forge-std` | v1.14.0 (`1801b05`) |
| `lib/openzeppelin-contracts` | v5.7.0 (`cab1993`) |
| `lib/v4-core` | v4.0.0 (`e50237c`) |

```bash
git clone --recursive https://github.com/GushALKDev/evm-yield-bearing-vaults.git
```

```bash
cd evm-yield-bearing-vaults
```

If you cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

Fork tests need an Ethereum mainnet RPC that serves historical state (archive access for block 26043110):

```bash
cp .env_example .env
```

Then set `ETHEREUM_MAINNET_RPC=https://...` in `.env`.

## Usage

```bash
forge build
```

All tests (fork suites need `ETHEREUM_MAINNET_RPC`):

```bash
forge test
```

Mock mode, only the tests that do not need an RPC:

```bash
forge test --no-match-path "test/{integration/*,fuzz/*StrategyFuzz.t.sol,gas/GasBenchmarkFork.t.sol}"
```

Coverage:

```bash
forge coverage --no-match-coverage "(test|script|mock)"
```

Gas report for the whole suite:

```bash
forge test --gas-report
```

Fork tests fork Ethereum mainnet at block 26043110 by default (`test/utils/ForkConfig.sol`). Override it with `FORK_BLOCK`, or set `FORK_BLOCK=0` to fork the latest block. Results at other blocks can differ from the numbers in this document.

```bash
FORK_BLOCK=0 forge test --match-path "test/integration/*"
```

Invariant suites against the fork (add `--threads 1` if the RPC provider rate-limits parallel requests):

```bash
INVARIANT_USE_FORK=true FOUNDRY_PROFILE=fork-invariant forge test --match-path "test/invariant/*.sol" --threads 1
```

## Testing

Results below were obtained on commit `9f599c4` (the last commit that changes code or tests) with Forge 1.7.1, fork suites at block 26043110.

### Test statistics

365 tests (unit, integration, fuzz, invariant) plus 10 gas benchmarks, all passing (`forge test` reports 375).

| Category | Location | Tests | Needs RPC | Iterations |
|----------|----------|-------|-----------|------------|
| Unit (mocks) | `test/unit` | 197 | No | - |
| Integration (fork) | `test/integration` | 88 | Yes | - |
| Stateless fuzzing | `test/fuzz` | 53 (22 mock, 31 fork) | For 31 of them | 53 x 256 runs = 13,568 |
| Stateful fuzzing (invariants) | `test/invariant` | 27 | No (mock mode) | 27 x 256 runs x 50 depth = 345,600 handler calls |
| **Correctness tests** | | **365** | | **359,168 fuzz runs and handler calls** |
| Gas benchmarks | `test/gas` | 10 (5 mock, 5 fork) | For 5 of them | - |

Mock mode runs 246 correctness tests (197 unit, 22 fuzz, 27 invariants) plus 5 gas benchmarks (`forge test` reports 251). Without `ETHEREUM_MAINNET_RPC`, plain `forge test` fails in `setUp()` for the fork suites; use the mock mode command above.

Fork mode for the invariant suites uses 20 runs x 10 depth; all 27 invariant functions passed with `--threads 1`.

### Coverage

`forge coverage --no-match-coverage "(test|script|mock)"`, all 375 tests (correctness tests and gas benchmarks):

| File | Lines | Statements | Branches | Functions |
|------|-------|------------|----------|-----------|
| `access/Whitelist.sol` | 100.00% (36/36) | 100.00% (32/32) | 100.00% (7/7) | 100.00% (8/8) |
| `adapters/AaveAdapter.sol` | 100.00% (18/18) | 100.00% (22/22) | 100.00% (5/5) | 100.00% (5/5) |
| `adapters/UniswapV4Adapter.sol` | 100.00% (24/24) | 100.00% (24/24) | 100.00% (2/2) | 100.00% (5/5) |
| `base/BaseStrategy.sol` | 98.73% (78/79) | 96.25% (77/80) | 85.71% (12/14) | 100.00% (25/25) |
| `base/BaseVault.sol` | 100.00% (163/163) | 95.96% (190/198) | 78.95% (30/38) | 100.00% (34/34) |
| `strategies/AaveSimpleLendingStrategy.sol` | 100.00% (31/31) | 97.62% (41/42) | 75.00% (3/4) | 100.00% (9/9) |
| `strategies/WETHLoopStrategy.sol` | 96.00% (144/150) | 88.58% (194/219) | 57.14% (24/42) | 100.00% (21/21) |
| **Total** | **98.60% (494/501)** | **94.00% (580/617)** | **74.11% (83/112)** | **100.00% (107/107)** |

### Stateless fuzzing

53 tests, 256 runs each (Foundry default; `foundry.toml` does not set `fuzz.runs`).

| Suite | Tests | Mode | Focus |
|-------|-------|------|-------|
| `BaseVaultFuzz` | 15 | Mock | Deposits (1 wei to 1,000,000 tokens), withdrawals, fees (0 to 2,500 bps), emergency mode, conversions |
| `WETHLoopStrategyFuzz` | 13 | Fork | Deposits (0.1 to 5 WETH), leverage targets 5x to 10x, withdrawals 10% to 90%, `minHealthFactor` 1.01 to 1.05, emergency divest and recovery |
| `AaveSimpleStrategyFuzz` | 15 | Fork | Deposits (100 to 100,000 USDC), 2 to 5 users, yield over 1 to 30 days, conversions |
| `PreviewFeeFuzz` | 4 | Mock | `preview*` equals the result of deposit, mint, withdraw and redeem with a fee of 0 to 2,500 bps and a pending profit of 0% to 50% |
| `MaxWithdrawFuzz` / `MaxWithdrawStrategyFuzz` | 2 + 2 | Mock / Fork | `withdraw(maxWithdraw)` and `redeem(maxRedeem)` never revert with random positions, PoolManager liquidity from 0 to 200 WETH and optional emergency mode |
| `MaxDepositFuzz` / `MaxDepositStrategyFuzz` | 1 + 1 | Mock / Fork | With `maxDeposit()` not 0, a deposit never reverts with `HealthFactorBelowMinimum` (existing position 2x to 14x, target 2x to 14x, `minHealthFactor` within 0.2% of the lower health factor) |

### Stateful fuzzing (invariants)

27 invariant functions with the handler pattern, 256 runs x 50 depth each (`[invariant]` in `foundry.toml`). Handler statistics are logged by `afterInvariant()` hooks, which are not counted as invariants.

| Suite | Invariants | Handlers |
|-------|------------|----------|
| `BaseVaultInvariant` | 8 | `BaseVaultHandler` (deposit, withdraw, transfer, assessFee, simulateYield), `AdminHandler` (whitelist, fee, fee recipient change and removal attempt, emergency toggle, reinvest) |
| `WETHLoopStrategyInvariant` | 10 | `WETHLoopStrategyHandler` (deposit, withdraw, checkHealth, triggerEmergency, recover (exit then reinvest), setMinHealthFactor, warpTime) |
| `IntegratedInvariant` | 9 | All three |

What the main invariants check:

- Total supply equals the sum of the actors', dead and fee recipient shares; the dead address holds exactly 1,000 shares.
- `convertToShares(convertToAssets(x))` returns `x` within 10 wei.
- The high-water mark equals a model of its definition in `BaseVault` (deposits added, withdrawals subtracted, raised to `totalAssets()` on fee assessment) and stays at most 10 wei above `totalAssets()` (the suite has no loss source).
- Strategy `totalAssets()` equals `aToken + idle WETH - debt` exactly.
- Strategy equity equals the equity expected from deposits, withdrawals and interest measured on each time warp, within 4 wei per Aave operation.
- During emergency mode, a redeeming user receives the pro rata share of raw equity within 2 wei, and the position has no debt.
- Vault `totalAssets() + withdrawals = initial deposit + deposits + simulated yield + measured interest`, within rounding.
- Vault `totalAssets()` equals its idle balance plus the strategy's `totalAssets()` within 10 wei.
- Leverage `collateral / (collateral - debt) <= 14.00x`. With a 93% LTV the theoretical upper bound is `1 / (1 - 0.93) = 14.29x`, so the invariant checks that leverage never exceeds what the LTV allows, while the strategy targets 10x.
- Health factor `>= minHealthFactor - 0.01` unless emergency mode is active; emergency flags of vault and strategy are equal; every actor holding shares, the fee recipient if it holds shares and the current fee recipient are whitelisted; protocol fee `<= 2,500` bps.
- After every successful `reinvest()` through the admin handler, the health factor is `>= targetHealthFactor`.
- No deposit reverts with `HealthFactorBelowMinimum` while `maxDeposit()` reports a non-zero limit.

Mock mode limitations: `MockAavePool` does not accrue interest and does not enforce the LTV on borrow, so leverage stays at the configured 10x and the health factor stays at `10 * 0.95 / 9`. Emergency mode is reached through `triggerEmergency()` (which raises `minHealthFactor` above the current health factor) and the admin handler.

See [test/README.md](test/README.md) for the per-test breakdown.

## Gas

### Optimizations applied

- Storage packing in `BaseVault`: `strategy` (20 bytes), `protocolFeeBps` (2 bytes) and `emergencyMode` (1 byte) share slot 7 (`forge inspect YieldBearingVault storageLayout`).
- Storage reads cached in local variables (`strategy`, `protocolFeeBps`, `feeRecipient`, `highWaterMark`).
- Immutables and `asset()` cached in local variables. The gas effect is negligible, since immutables are embedded in the bytecode.
- `unchecked` arithmetic where the bounds are checked beforehand.
- Whitelist add and remove return early when the state would not change, skipping a redundant storage write and event.
- Batch whitelist functions (`addBatchToWhitelist`, `removeBatchFromWhitelist`).
- Modifiers delegate to internal functions to reduce bytecode size.
- Custom errors instead of revert strings.
- The outstanding flash loan is kept in transient storage.

The repository does not contain before and after measurements for these changes.

### Measured costs

From the committed harness in `test/gas/`, commit `9f599c4`, reproducible with:

```bash
forge test --match-contract GasBenchmarkMockTest --gas-report
```

```bash
forge test --match-contract GasBenchmarkForkTest --gas-report
```

`setUp` opens a 1 WETH position at 10x (`minHealthFactor` 1.02, E-Mode 1) with `vault.mint`, so each measured function below is called once per scenario. Values are the gas reported by `--gas-report`, which runs each call as a separate transaction. The fork column runs against Aave V3 and the Uniswap V4 PoolManager at block 26043110 with the PoolManager's real WETH balance.

| Function | Scenario | Mock mode | Mainnet fork |
|----------|----------|-----------|--------------|
| `vault.deposit` | 1 WETH into an existing 10x position | 276,259 | 418,232 |
| `vault.withdraw` | 0.5 WETH from a 1 WETH position | 261,080 | 396,253 |
| `vault.redeem` | All shares of the only depositor (position closed) | 253,586 | 357,515 |
| `strategy.checkHealth` | Emergency divest of 10 WETH collateral / 9 WETH debt | 218,663 | 345,280 |
| `vault.setEmergencyMode(false)` | Recovery step 1, clears the flags | 34,519 | 34,519 |
| `vault.reinvest` | Recovery step 2: moves the vault's 1,000 wei into the strategy, reinvests about 1 WETH at 10x and checks the health factor | 258,984 | 396,262 |

Mock mode uses `MockAavePool`, `MockPoolManager` and `MockWETH`, whose gas costs are not representative of the real protocols.

## Tech stack

- Solidity 0.8.26, EVM version Cancun, optimizer 200 runs
- Foundry (Forge 1.7.1 used for the results above)
- OpenZeppelin Contracts v5.7.0
- Uniswap V4 Core v4.0.0
- Aave V3 (mainnet deployment, accessed through a local `IPool` interface)

## Roadmap

- [x] ERC-4626 vault
- [x] Aave simple lending strategy
- [x] Leveraged loop strategy (WETH)
- [x] Proportional deleveraging
- [x] Performance fee with high-water mark
- [x] Emergency mode circuit breaker with position exit
- [x] Permissionless health check with emergency divest
- [x] Two-step emergency recovery with a `targetHealthFactor` check on reinvestment
- [x] Fixes for the review findings (see [Review notes](#review-notes))
- [x] Test suite (365 tests plus 10 gas benchmarks, 98.60% line coverage)
- [x] Stateless fuzzing (53 tests, 13,568 runs)
- [x] Stateful fuzzing (27 invariant functions, 345,600 handler calls)
- [x] Gas benchmark harness (mock and fork)
- [ ] Keeper for `checkHealth()`
- [ ] Loop strategies with yield-bearing collateral (stETH, rETH, cbETH)
- [ ] Multi-asset vaults

## License

MIT, see [LICENSE](LICENSE).

---

Built by **GushALKDev**
