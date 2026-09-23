# Test Suite Documentation

## Overview

The suite is organized into unit tests (mocked dependencies), integration tests (mainnet fork), stateless fuzz tests and stateful invariant tests with the handler pattern. Results below were obtained on commit `b15658e` with Forge 1.7.1, running the fork suites against Ethereum mainnet (September 2026). See the [main README](../README.md) for the project status, trust assumptions and known issues.

## Test Statistics

| Category | Tests | Needs `ETHEREUM_MAINNET_RPC` |
|----------|-------|------------------------------|
| Unit | 100 | No |
| Integration | 39 | Yes |
| Stateless fuzzing | 43 (15 mock, 28 fork) | For `WETHLoopStrategyFuzz` and `AaveSimpleStrategyFuzz` |
| Stateful fuzzing (invariants) | 27 (24 invariants + 3 call-summary loggers) | No in mock mode (default) |
| **Total** | **209, all passing** | |

Iterations:

- Stateless: 43 tests x 256 runs = 11,008 runs (Foundry default runs; `foundry.toml` has no `[fuzz]` section).
- Stateful: 27 invariant functions x 256 runs x 50 depth = 345,600 handler calls (`[invariant]` in `foundry.toml`). Forge reports `runs: 256, calls: 12800` for each invariant function.
- Total: 356,608 fuzz runs and handler calls.

Without `ETHEREUM_MAINNET_RPC`, `forge test` runs 142 tests and the 6 fork suites fail in `setUp()`.

Note: the 16 tests in `unit/AdapterErrorPaths.t.sol` do not import or call `AaveAdapter` or `UniswapV4Adapter`. They are placeholder and arithmetic assertions and do not contribute to adapter coverage.

## Code Coverage

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

Main gaps:

- `Whitelist.sol`: the batch functions and the unused `onlyWhitelisted` modifier are not covered.
- `WETHLoopStrategy.sol`: 17 of 26 branches, mostly error paths, are not covered.
- `AaveAdapter.sol`: 3 of the 4 zero-amount early returns are not covered.

## Test Organization

```
test/
├── unit/                                   # Unit tests (100 tests)
│   ├── BaseVault.t.sol                    # 22 tests - Vault admin functions
│   ├── Whitelist.t.sol                    # 17 tests - Whitelist enforcement
│   ├── AccessControl.t.sol                # 22 tests - Access control modifiers
│   ├── EdgeCases.t.sol                    # 19 tests - Edge cases and boundaries
│   ├── YieldFlow.t.sol                    #  4 tests - Yield mechanics
│   └── AdapterErrorPaths.t.sol            # 16 tests - Placeholder tests (do not call adapter code)
├── integration/                            # Integration tests, mainnet fork (39 tests)
│   ├── AaveSimpleStrategyFork.t.sol       #  3 tests - Aave simple strategy
│   ├── WETHLoopStrategy.t.sol             #  9 tests - WETH leveraged strategy and emergency flow
│   ├── StrategyHealthCheck.t.sol          #  9 tests - Strategy health and harvest
│   └── WETHLoopStrategyErrorPaths.t.sol   # 18 tests - WETH strategy error paths and views
├── fuzz/                                   # Stateless fuzzing (43 tests)
│   ├── BaseVaultFuzz.t.sol                # 15 tests - Vault fuzzing (mock)
│   ├── WETHLoopStrategyFuzz.t.sol         # 13 tests - WETH strategy fuzzing (fork)
│   └── AaveSimpleStrategyFuzz.t.sol       # 15 tests - Aave strategy fuzzing (fork)
├── invariant/                              # Stateful fuzzing (27 invariant functions)
│   ├── InvariantBase.sol                  # Shared actors, constants, fork/mock detection
│   ├── BaseVaultInvariant.t.sol           #  9 functions - Vault invariants
│   ├── WETHLoopStrategyInvariant.t.sol    #  9 functions - Strategy invariants
│   ├── IntegratedInvariant.t.sol          #  9 functions - System-wide invariants
│   └── handlers/
│       ├── BaseVaultHandler.sol           # Vault operations handler
│       ├── WETHLoopStrategyHandler.sol    # Strategy operations handler
│       └── AdminHandler.sol               # Admin operations handler
└── mocks/
    ├── MockStrategy.sol                   # Strategy that keeps funds in the contract
    ├── MockWETH.sol                       # WETH with mint/burn
    ├── MockAavePool.sol                   # Aave V3 Pool simulation
    ├── MockAToken.sol                     # aToken simulation
    ├── MockVariableDebtToken.sol          # Debt token simulation
    └── MockPoolManager.sol                # Uniswap V4 PoolManager simulation
```

## Unit Tests

### BaseVault.t.sol (22 tests)

**Admin Functions**:
- `test_SetAdmin_Success` - Admin can be changed
- `test_SetAdmin_RevertIfNotAdmin` - Only admin can change admin
- `test_SetAdmin_RevertIfZeroAddress` - Cannot set zero address as admin
- `test_SetStrategy_Success` - Strategy can be changed
- `test_SetStrategy_RevertIfNotAdmin` - Only admin can change strategy
- `test_SetProtocolFee_Success` - Protocol fee can be set
- `test_SetProtocolFee_RevertIfTooHigh` - Fee cannot exceed 25%
- `test_SetProtocolFee_RevertIfNotAdmin` - Only admin can set fee
- `test_SetFeeRecipient_Success` - Fee recipient can be changed
- `test_SetFeeRecipient_RevertIfZeroAddress` - Cannot set zero address
- `test_SetFeeRecipient_RevertIfNotAdmin` - Only admin can set recipient

**Emergency Mode**:
- `test_SetEmergencyMode_Activate` - Emergency mode can be activated
- `test_SetEmergencyMode_Deactivate` - Emergency mode can be deactivated
- `test_EmergencyMode_BlocksDeposits` - Deposits blocked during emergency
- `test_EmergencyMode_AllowsWithdrawals` - Withdrawals allowed during emergency (with `MockStrategy`, which keeps funds in the contract)
- `test_SetEmergencyMode_RevertIfNotAdmin` - Only admin can toggle emergency

**Constructor & State**:
- `test_Constructor_RevertIfIncorrectInitialDeposit` - Validates initial deposit
- `test_Constructor_BurnsInitialDeposit` - Initial shares minted to the dead address
- `test_Constructor_InitializesHighWaterMark` - HWM initialized correctly

**High Water Mark**:
- `test_HighWaterMark_IncreasesWithDeposits` - HWM tracks deposits
- `test_HighWaterMark_DecreasesWithWithdrawals` - HWM decreases on withdrawal
- `test_HighWaterMark_FullWithdrawal` - HWM handles full withdrawal

### Whitelist.t.sol (17 tests)

**Whitelist Management**:
- `test_AddToWhitelist_Success` - Owner can whitelist addresses
- `test_AddToWhitelist_RevertIfNotOwner` - Only owner can whitelist
- `test_RemoveFromWhitelist_Success` - Owner can remove from whitelist
- `test_RemoveFromWhitelist_RevertIfNotOwner` - Only owner can remove
- `test_AddMultipleToWhitelist` - Multiple addresses can be whitelisted (individual calls, not the batch functions)

**Deposit Enforcement**:
- `test_Deposit_SuccessIfWhitelisted` - Whitelisted users can deposit
- `test_Deposit_RevertIfNotWhitelisted` - Non-whitelisted cannot deposit
- `test_Mint_SuccessIfWhitelisted` - Whitelisted users can mint
- `test_Mint_RevertIfNotWhitelisted` - Non-whitelisted cannot mint
- `test_Deposit_BlockedAfterRemovalFromWhitelist` - Removed users cannot deposit

**Transfer Enforcement**:
- `test_Transfer_SuccessToWhitelisted` - Can transfer to whitelisted
- `test_Transfer_RevertToNonWhitelisted` - Cannot transfer to non-whitelisted
- `test_TransferFrom_SuccessToWhitelisted` - TransferFrom works with whitelist
- `test_TransferFrom_RevertToNonWhitelisted` - TransferFrom respects whitelist

**Withdrawal**:
- `test_Withdraw_SuccessIfWhitelisted` - Whitelisted can withdraw
- `test_Withdraw_AllowedAfterRemovalFromWhitelist` - Removed users can still withdraw
- `test_Redeem_Success` - Users can redeem shares

### AccessControl.t.sol (22 tests)

**Strategy Access Control**:
- `test_Strategy_Deposit_RevertIfNotVault` - Only vault can deposit to strategy
- `test_Strategy_Deposit_SuccessFromVault` - Vault can deposit successfully
- `test_Strategy_Mint_RevertIfNotVault` - Only vault can mint
- `test_Strategy_Withdraw_RevertIfNotVault` - Only vault can withdraw
- `test_Strategy_Withdraw_SuccessFromVault` - Vault can withdraw successfully
- `test_Strategy_Redeem_RevertIfNotVault` - Only vault can redeem
- `test_Strategy_Redeem_SuccessFromVault` - Vault can redeem successfully
- `test_Strategy_SetEmergencyMode_RevertIfNotVault` - Only vault can set emergency
- `test_Strategy_SetEmergencyMode_SuccessFromVault` - Vault can set emergency

**Strategy Emergency Mode**:
- `test_Strategy_EmergencyMode_BlocksDeposits` - Deposits blocked during emergency
- `test_Strategy_EmergencyMode_AllowsWithdrawals` - Withdrawals allowed during emergency (with `MockStrategy`)
- `test_Strategy_EmergencyMode_BlocksMints` - Mints blocked during emergency

**Vault Admin Control**:
- `test_Vault_SetStrategy_RevertIfNotAdmin` - Non-admin cannot set strategy
- `test_Vault_SetEmergencyMode_RevertIfNotAdmin` - Non-admin cannot set emergency
- `test_Vault_SetProtocolFee_RevertIfNotAdmin` - Non-admin cannot set fee
- `test_Vault_SetFeeRecipient_RevertIfNotAdmin` - Non-admin cannot set recipient
- `test_Vault_SetAdmin_RevertIfNotAdmin` - Non-admin cannot change admin

**Vault Owner Control**:
- `test_Vault_AddToWhitelist_RevertIfNotOwner` - Non-owner cannot whitelist
- `test_Vault_AddToWhitelist_SuccessFromOwner` - Owner can whitelist
- `test_Vault_RemoveFromWhitelist_RevertIfNotOwner` - Non-owner cannot remove
- `test_Vault_RemoveFromWhitelist_SuccessFromOwner` - Owner can remove
- `test_AdminAndOwnerAreDifferentRoles` - Verifies role separation

### EdgeCases.t.sol (19 tests)

**Zero Amount Tests**:
- `test_Deposit_ZeroAmount` - Zero deposit returns zero shares
- `test_Withdraw_ZeroAmount` - Zero withdrawal
- `test_Redeem_ZeroShares` - Zero redeem

**Dust Amount Tests**:
- `test_Deposit_DustAmount` - 1 wei deposit
- `test_InflationProtection_SmallDeposits` - Small deposits after the dead-share mint

**Large Amount Tests**:
- `test_Deposit_MaximumAmount` - Deposit of the full user balance
- `test_Withdraw_MaximumShares` - Withdrawal of all user shares

**Fee Edge Cases**:
- `test_PerformanceFee_ZeroFee` - Zero fee
- `test_PerformanceFee_NoRecipient` - No fees without recipient
- `test_PerformanceFee_MaximumFee` - 25% fee

**Conversion Tests**:
- `test_ConvertToShares_ZeroAssets` - Zero asset conversion
- `test_ConvertToAssets_ZeroShares` - Zero share conversion
- `test_PreviewDeposit_Accuracy` - Preview matches actual deposit
- `test_PreviewWithdraw_Accuracy` - Preview matches actual withdrawal

**Other Tests**:
- `test_Deposit_BlockedDuringEmergency` - Emergency blocks deposits
- `test_MaxDeposit_ReturnsMaxUint` - `maxDeposit` returns `type(uint256).max`
- `test_ReentrancyGuard_DepositsProtected` - Performs a normal deposit; it does not attempt a reentrant call
- `test_TotalAssets_WithStrategy` - TotalAssets includes strategy
- `test_TotalAssets_WithoutStrategy` - TotalAssets without strategy

### YieldFlow.t.sol (4 tests)

- `test_FullYieldFlow` - Deposit, yield, withdrawal flow
- `test_RevertIfNotWhitelisted` - Whitelist enforcement on deposits
- `test_SharePriceEvolution` - Share price increases with yield
- `test_PerformanceFeeLogic` - Fee is charged only on gains above the high-water mark

### AdapterErrorPaths.t.sol (16 tests)

These tests only import `forge-std/Test.sol`. They do not deploy or call `AaveAdapter` or `UniswapV4Adapter`; five of them are `assertTrue(true)` placeholders and the rest check local arithmetic or constants.

- `test_AaveAdapter_Supply_ZeroAmount`
- `test_AaveAdapter_Withdraw_ZeroAmount`
- `test_AaveAdapter_Borrow_ZeroAmount`
- `test_AaveAdapter_Repay_ZeroAmount`
- `test_AaveAdapter_ValidParameters`
- `test_AaveAdapter_MaxUint256Amount`
- `test_Adapter_AddressValidation`
- `test_Adapter_AmountValidation`
- `test_Adapter_EdgeCaseAmounts`
- `test_InterestRateMode_Constants`
- `test_VariableInterestRateMode`
- `test_AaveAdapter_LibraryImport`
- `test_AaveAdapter_RealisticParameters`
- `test_Adapter_NoOverflow`
- `test_Adapter_PercentageCalculations`
- `test_Adapter_BasisPointsCalculations`

## Integration Tests

All integration tests fork the latest mainnet block (no pinned block number). `WETHLoopStrategy.t.sol` and `fuzz/WETHLoopStrategyFuzz.t.sol` `deal` 10,000 WETH to the Uniswap V4 PoolManager and 100 WETH directly to the vault in `setUp`.

### AaveSimpleStrategyFork.t.sol (3 tests)

- `test_DepositInvestsInAave` - Funds deposited to Aave
- `test_WithdrawDivestsFromAave` - Withdrawals include accrued yield
- `test_RedeemDivestsFromAave` - Redemptions include accrued yield

### WETHLoopStrategy.t.sol (9 tests)

Leverage tests (the first four prank the vault address and call the strategy directly; the multi-user test goes through the vault):
- `test_Invest_LeveragesCorrectly` - 10x leverage established
- `test_Invest_MultipleDeposits` - Multiple deposits keep the health factor above the minimum
- `test_Divest_PartialWithdrawal` - Proportional deleverage (50%)
- `test_Divest_FullWithdrawal` - Full exit through `strategy.redeem()` with all strategy shares
- `test_MultipleUsers_DifferentDepositWithdrawOrder` - Three users, different withdrawal order

Emergency tests (the unhealthy state is simulated by raising `minHealthFactor` above the current health factor):
- `test_CheckHealth_HealthyPosition` - Healthy position does not trigger emergency
- `test_CheckHealth_TriggersEmergencyDivest` - Emergency divest closes the position and blocks deposits
- `test_EmergencyMode_WithdrawalsSkipDivest` - Vault redemption during emergency. The redemption is paid from the 100 WETH dealt to the vault, within a 2% tolerance; see Known issue 1 in the main README
- `test_RecoveryFromEmergency_ReinvestsAutomatically` - Admin deactivation reinvests at target leverage and deposits resume

### StrategyHealthCheck.t.sol (9 tests)

- `test_WETHStrategy_CheckHealth_Healthy` - WETH strategy health check
- `test_WETHStrategy_Harvest_Reverts` - WETH harvest reverts with `StrategyNotHarvestable()`
- `test_WETHStrategy_TotalAssets` - WETH total assets calculation
- `test_USDCStrategy_CheckHealth` - USDC strategy health check
- `test_USDCStrategy_Harvest_Reverts` - USDC harvest reverts
- `test_USDCStrategy_TotalAssets` - USDC total assets calculation
- `test_USDCStrategy_TotalAssets_IncreasesWithYield` - USDC yield accrual
- `test_Strategies_BothHealthy` - Both strategies report healthy
- `test_Strategies_HarvestBehavior` - Harvest behavior comparison

### WETHLoopStrategyErrorPaths.t.sol (18 tests)

- `test_UnlockCallback_RevertIfNotPoolManager` - Flash loan callback rejects other callers
- `test_Withdraw_WithNoPosition_Reverts` - Withdrawal without position
- `test_Redeem_WithNoShares` - Redeem with zero shares
- `test_TotalAssets_NoPosition` - Total assets with no position
- `test_TotalAssets_WithDebt` - Total assets with debt
- `test_PreviewDeposit_Zero` - Preview deposit of zero
- `test_PreviewWithdraw_Zero` - Preview withdraw of zero
- `test_PreviewMint_Zero` - Preview mint of zero
- `test_PreviewRedeem_Zero` - Preview redeem of zero
- `test_MaxDeposit` - Max deposit returns `type(uint256).max`
- `test_MaxMint` - Max mint returns `type(uint256).max`
- `test_MaxWithdraw_WithPosition` - Max withdraw with position
- `test_MaxRedeem_WithShares` - Max redeem with shares
- `test_ConvertToShares_Zero` - Convert zero assets to shares
- `test_ConvertToAssets_Zero` - Convert zero shares to assets
- `test_ConvertAccuracy_AfterDeposit` - Conversion accuracy
- `test_ImmutableValues` - Immutable values set correctly
- `test_EmergencyMode_Propagates` - Emergency mode propagation

## Stateless Fuzzing Tests

256 runs per test.

### BaseVaultFuzz.t.sol (15 tests, mock)

**Deposit Fuzzing** (3 tests):
- `testFuzz_Deposit_CorrectShareCalculation` - Share calculation (1 wei to 1,000,000 tokens)
- `testFuzz_Deposit_MultipleDeposits` - Sequential deposits from the same user
- `testFuzz_Deposit_MultipleUsers` - Deposits from 2 to 10 users

**Withdraw Fuzzing** (3 tests):
- `testFuzz_Withdraw_PartialWithdrawal` - Partial withdrawals with random amounts
- `testFuzz_Redeem_FullWithdrawal` - Full redemption across deposit sizes
- `testFuzz_InterleavedDepositWithdraw` - Interleaved operations

**Fee Management Fuzzing** (3 tests):
- `testFuzz_SetProtocolFee_ValidRange` - Fees within 0 to 2,500 bps
- `testFuzz_SetProtocolFee_RevertIfTooHigh` - Fees above 2,500 bps rejected
- `testFuzz_HighWaterMark_UpdatesCorrectly` - HWM updates across sequences

**Emergency Mode Fuzzing** (2 tests):
- `testFuzz_EmergencyMode_BlocksDeposits` - Deposits blocked during emergency
- `testFuzz_EmergencyMode_AllowsWithdrawals` - Withdrawals during emergency (with `MockStrategy`)

**Share Conversion Fuzzing** (2 tests):
- `testFuzz_ConvertToAssets_Consistency` - Share and asset conversions reversible
- `testFuzz_PreviewFunctions_MatchActual` - Preview functions match actual

**Invariant Fuzzing** (2 tests):
- `testFuzz_Invariant_TotalSupply` - Total supply = user shares + dead shares
- `testFuzz_Invariant_VaultStrategyConsistency` - Vault assets = strategy assets + 1,000 wei initial deposit, within 10 wei

### WETHLoopStrategyFuzz.t.sol (13 tests, fork)

**Investment Fuzzing** (3 tests):
- `testFuzz_Invest_EstablishesLeverage` - Leverage for deposits of 0.1 to 5 WETH
- `testFuzz_Invest_MultipleDeposits` - Sequential deposits keep the health factor above the minimum
- `testFuzz_Invest_DifferentLeverageTargets` - Leverage targets from 5x to 10x

**Divestment Fuzzing** (3 tests):
- `testFuzz_Divest_PartialWithdrawal` - Proportional deleverage (10% to 90%)
- `testFuzz_Divest_FullWithdrawal` - Complete position exit
- `testFuzz_Divest_MultipleUsers` - Two users, first withdraws 50% to 100%

**Health Factor Fuzzing** (3 tests):
- `testFuzz_HealthFactor_CustomThresholds` - `minHealthFactor` from 1.01 to 1.05
- `testFuzz_CheckHealth_TriggersEmergency` - Emergency divest when `minHealthFactor` is raised 0.05 to 0.2 above the current health factor
- `testFuzz_Recovery_ReinvestsAfterEmergency` - Reinvestment after admin deactivation

**Share Conversion Fuzzing** (2 tests):
- `testFuzz_ShareConversion_Consistency` - Conversions with leverage
- `testFuzz_Preview_MatchesActual` - Preview functions match actual with leverage

**Invariant Fuzzing** (2 tests):
- `testFuzz_Invariant_TotalAssets` - Expects `totalAssets() = aToken - debt + idle WETH`; no idle WETH exists in the tested scenario
- `testFuzz_Invariant_LeverageWithinBounds` - Leverage between 5x and 14x

### AaveSimpleStrategyFuzz.t.sol (15 tests, fork)

**Deposit Fuzzing** (3 tests):
- `testFuzz_Deposit_InvestsInAave` - Deposits of 100 to 100,000 USDC invested
- `testFuzz_Deposit_MultipleSequential` - Sequential deposits
- `testFuzz_Deposit_MultipleUsers` - 2 to 5 users

**Withdrawal Fuzzing** (3 tests):
- `testFuzz_Withdraw_PartialAmount` - Partial withdrawals (10% to 90%)
- `testFuzz_Redeem_FullAmount` - Full share redemption
- `testFuzz_InterleavedOperations` - Interleaved deposit and withdraw sequences

**Yield Fuzzing** (3 tests):
- `testFuzz_Yield_AccruesOverTime` - Yield accrual over 1 to 30 days
- `testFuzz_Yield_WithdrawAfterYield` - Withdrawals after yield
- `testFuzz_Yield_SharePriceIncreases` - Share price increases with yield

**Invariant Fuzzing** (3 tests):
- `testFuzz_Invariant_TotalSupply` - Total supply invariant
- `testFuzz_Invariant_VaultStrategyConsistency` - Vault and strategy consistency
- `testFuzz_Invariant_PhysicalBalances` - Physical token balances

**Share Conversion Fuzzing** (3 tests):
- `testFuzz_ShareConversion_Consistency` - Share and asset conversions
- `testFuzz_Preview_MatchesActual` - Preview deposit matches actual
- `testFuzz_PreviewWithdraw_MatchesActual` - Preview withdraw matches actual

### Tolerances

- Absolute tolerances between 1 and 1,000 wei for Aave rounding.
- Relative tolerances of 1% (conversions and previews) and 5% (leverage ratio).
- The integration test `test_EmergencyMode_WithdrawalsSkipDivest` uses a 2% tolerance on the redeemed amount.

## Stateful Fuzzing (Invariant) Tests

Each suite uses handler contracts that wrap protocol operations and record ghost variables. Foundry reports `runs: 256, calls: 12800` for every invariant function, since each function runs its own campaign.

### BaseVaultInvariant.t.sol (9 functions)

Always uses `MockStrategy` and a mock ERC20, in both modes.

- `invariant_TotalSupplyConsistency` - Total supply = sum of the 5 actors' shares + dead shares + fee recipient shares
- `invariant_DeadSharesConstant` - Dead address holds exactly 1,000 shares
- `invariant_ConversionReversibility` - `convertToShares(convertToAssets(x))` within 10 wei of `x`
- `invariant_EmergencyModeSynchronized` - Vault and strategy emergency flags equal
- `invariant_TotalAssetsConsistency` - Vault `totalAssets()` = idle balance + strategy assets, within 10 wei
- `invariant_WhitelistEnforcement` - Every actor holding shares is whitelisted
- `invariant_HighWaterMarkBounded` - HWM `<= totalAssets() * 1.1 + 1,000`
- `invariant_ProtocolFeeBounded` - Protocol fee `<= 2,500` bps
- `invariant_CallSummary` - Logs handler statistics (no assertion)

Handlers: `BaseVaultHandler` (deposit, withdraw, transfer, assessFee) and `AdminHandler` (whitelist add and remove, fee changes, emergency toggle). `AdminHandler` only removes addresses with a zero balance.

### WETHLoopStrategyInvariant.t.sol (9 functions)

- `invariant_LeverageWithinBounds` - `collateral / (collateral - debt) <= 14.00x`
- `invariant_HealthFactorSafe` - Health factor `>= minHealthFactor - 0.01` unless emergency mode is active
- `invariant_TotalAssetsCalculation` - Expects `totalAssets() = aToken - debt + idle WETH`. The strategy does not add idle WETH; the invariant passes because no idle WETH accumulates in the mock runs (see Known issue 1 in the main README)
- `invariant_EmergencyDivestClosesPosition` - Debt below 100 wei while emergency mode is active
- `invariant_EmergencyModeSynchronized` - Strategy and vault emergency flags equal
- `invariant_StrategyVaultBinding` - `strategy.VAULT()` is the vault
- `invariant_MaxLeverageTracked` - Highest leverage observed by the handler `<= 14.00x`
- `invariant_PositionValueConsistency` - Current assets + divested + 1,000 wei `>=` 90% of invested minus 1 WETH
- `invariant_CallSummary` - Logs handler statistics (no assertion)

Handler: `WETHLoopStrategyHandler` (deposit 1 wei to 100 WETH through the vault, redeem 1% to 100%, `checkHealth()`, time warp of 1 hour to 7 days).

The 14x bound: with a 93% LTV the theoretical upper bound on leverage is `1 / (1 - 0.93) = 14.29x`, so the invariant checks that leverage never exceeds what the LTV allows, while the suite targets 10x.

### IntegratedInvariant.t.sol (9 functions)

- `invariant_TotalSupplyConsistency` - Same as the vault suite
- `invariant_VaultStrategyValueConsistency` - Vault `totalAssets() + 100 >= strategy.totalAssets()`
- `invariant_NoValueLeak` - Withdrawn + current assets + 1,000 wei `>=` 85% of deposited
- `invariant_SystemEmergencyConsistency` - Emergency flags equal
- `invariant_LeverageWithinBounds` - Leverage `<= 14.00x`
- `invariant_HealthFactorSafe` - Health factor `>= minHealthFactor - 0.01` unless emergency mode is active
- `invariant_WhitelistIntegrity` - Every actor holding shares is whitelisted
- `invariant_FeeBounded` - Protocol fee `<= 2,500` bps
- `invariant_IntegratedCallSummary` - Logs handler statistics (no assertion)

Handlers: all three. The admin handler toggles emergency mode without closing the position, and handler reverts are tolerated because `fail_on_revert = false`. About 12% of handler calls reverted in the review run.

### Configuration

`foundry.toml`:

```toml
[invariant]
runs = 256
depth = 50
fail_on_revert = false
shrink_run_limit = 5000

[profile.fork-invariant.invariant]
runs = 20
depth = 10
fail_on_revert = false
shrink_run_limit = 1000
```

Mock mode: 27 functions x 256 runs x 50 depth = 345,600 handler calls.

### Mock vs Fork Mode

**Mock mode (default)** uses the contracts in `test/mocks/` and needs no RPC. Limitations:

- `MockAavePool` does not accrue interest and does not enforce the LTV on borrow. The health factor stays at `10 * 0.95 / 9 = 1.0556` for every 10x position, so `checkHealth()` never triggers an emergency divest and the leverage and health factor invariants are not stressed.
- `MockPoolManager` charges no fee and only checks that its balance is restored.

**Fork mode** runs `WETHLoopStrategyInvariant` and `IntegratedInvariant` against Aave V3 and Uniswap V4 on a mainnet fork with 20 runs x 10 depth (200 handler calls per invariant function). `BaseVaultInvariant` uses mocks in both modes. In the review run, the default parallel execution hit the RPC provider's rate limit (HTTP 429); running each fork suite with `--threads 1` completed, and all 18 fork-mode invariant functions passed.

```bash
# Mock mode (default)
forge test --match-path "test/invariant/*.sol"

# Fork mode (add --threads 1 if the RPC provider rate-limits parallel requests)
INVARIANT_USE_FORK=true FOUNDRY_PROFILE=fork-invariant forge test --match-path "test/invariant/*.sol"
```

`.env`:

```env
ETHEREUM_MAINNET_RPC=https://your-rpc-url
INVARIANT_USE_FORK=false  # Set to "true" for fork mode
```

### Ghost Variables

- Vault handler: `ghost_totalDeposited`, `ghost_totalWithdrawn`, `ghost_totalFeesMinted`, per-user deposits and withdrawals, operation counts
- Strategy handler: `ghost_totalInvested`, `ghost_totalDivested`, `ghost_maxLeverageObserved`, `ghost_minHealthFactorObserved`, `ghost_healthCheckCalls`, `ghost_healthCheckFailures`, `ghost_emergencyDivestCount`
- Admin handler: `ghost_whitelistAdditions`, `ghost_whitelistRemovals`, `ghost_feeChanges`, `ghost_emergencyModeChanges`

## Performance

Observed in the review run: the full suite (209 tests, fork suites included) finished in about 26 seconds of wall-clock time, with suites running in parallel. Timings depend on the machine and the RPC provider.

## Running Tests

```bash
# All tests (fork suites need ETHEREUM_MAINNET_RPC)
forge test

# Tests that do not need an RPC
forge test --no-match-path "test/{integration/*,fuzz/*StrategyFuzz.t.sol}"

# Unit tests only
forge test --match-path "test/unit/*.sol"

# Integration tests only
forge test --match-path "test/integration/*.sol"

# Specific test file
forge test --match-path test/unit/BaseVault.t.sol

# Specific test function
forge test --match-test test_SetAdmin_Success

# Verbose
forge test -vvv

# Stateless fuzzing only
forge test --match-path "test/fuzz/*.sol"

# Stateless fuzzing with more runs
forge test --match-path "test/fuzz/*.sol" --fuzz-runs 1000

# Invariant tests, mock mode
forge test --match-path "test/invariant/*.sol"

# Invariant tests, fork mode
INVARIANT_USE_FORK=true FOUNDRY_PROFILE=fork-invariant forge test --match-path "test/invariant/*.sol"

# Invariant tests with higher depth (mock mode; fork mode will hit RPC rate limits)
forge test --match-path "test/invariant/*.sol" --invariant-depth 100

# Coverage
forge coverage --no-match-coverage "(test|script|mock)"
```

`forge test --gas-report` currently fails in `setUp()` for 15 suites; see Known issue 4 in the main README.

## Test Conventions

- Arrange-Act-Assert structure with `ARRANGE` / `ACT` / `ASSERT` section markers.
- Revert conditions checked with `vm.expectRevert`.
- Events checked with `vm.expectEmit` in `BaseVault.t.sol` and `Whitelist.t.sol`.
- Aave dust (up to 10 wei in most assertions) is accepted in fork tests.

## Dependencies

- Foundry
- OpenZeppelin Contracts v5.5.0
- Uniswap V4 Core v4.0.0
- Ethereum mainnet RPC for fork tests (`ETHEREUM_MAINNET_RPC`)
