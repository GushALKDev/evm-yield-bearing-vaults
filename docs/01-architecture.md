# Guide 1: Architecture and Flows

**Previous:** [README](../README.md)
**Next:** [Guide 2: Economics of the WETH Loop](./02-economics.md)

---

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

### Flash loan provider

Uniswap V4 charged no flash loan fee at the time of writing. Aave V3's flash loan premium was 0.05% at the time of writing (`FLASHLOAN_PREMIUM_TOTAL = 5` bps at block 26043110). Neither value is fixed.

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

## Gas optimizations

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
