# Test Suite Documentation

## Overview

The suite is organized into unit tests (mocked dependencies), integration tests (mainnet fork), stateless fuzz tests, stateful invariant tests with the handler pattern and a gas benchmark. Results below were obtained on commit `48144c3` with Forge 1.7.1; fork suites run against Ethereum mainnet at block 26043110. See the [main README](../README.md) for the project status, trust assumptions and review notes.

## Test Statistics

| Category | Location | Tests | Needs `ETHEREUM_MAINNET_RPC` |
|----------|----------|-------|------------------------------|
| Unit | `unit/` | 114 | No |
| Integration | `integration/` | 55 | Yes |
| Stateless fuzzing | `fuzz/` | 43 (15 mock, 28 fork) | For `WETHLoopStrategyFuzz` and `AaveSimpleStrategyFuzz` |
| Stateful fuzzing (invariants) | `invariant/` | 25 | No in mock mode (default) |
| Gas benchmark | `gas/` | 10 (5 mock, 5 fork) | For `GasBenchmarkForkTest` |
| **Total** | | **247, all passing** | |

Iterations:

- Stateless: 43 tests x 256 runs = 11,008 runs (Foundry default runs; `foundry.toml` has no `[fuzz]` section).
- Stateful: 25 invariant functions x 256 runs x 50 depth = 320,000 handler calls (`[invariant]` in `foundry.toml`). Forge reports `runs: 256, calls: 12800` for each invariant function.
- Total: 331,008 fuzz runs and handler calls.

Mock mode (no RPC) runs 159 tests:

```bash
forge test --no-match-path "test/{integration/*,fuzz/*StrategyFuzz.t.sol,gas/GasBenchmarkFork.t.sol}"
```

Without `ETHEREUM_MAINNET_RPC`, plain `forge test` fails in `setUp()` for the fork suites.

## Fork Configuration

`utils/ForkConfig.sol` forks at `FORK_BLOCK`, default 26043110. `FORK_BLOCK=0` forks the latest block. The RPC must serve historical state for the pinned block.

## Shared Test Utilities

- `utils/ForkConfig.sol` - Pinned mainnet fork selection
- `utils/VaultDeployer.sol` - Deploys vaults with CREATE2 after pulling the initial deposit; tests approve this deployed helper instead of a predicted vault address, which keeps `forge test --gas-report` (isolation mode) working
- `utils/StrategyTestBase.sol` - Shared mock and fork setup for the regression tests; mock and fork variants inherit the same abstract test contract

## Code Coverage

`forge coverage --no-match-coverage "(test|script|mock)"`, all 247 tests:

| File | Lines | Statements | Branches | Functions |
|------|-------|------------|----------|-----------|
| `access/Whitelist.sol` | 25.81% (8/31) | 24.14% (7/29) | 28.57% (2/7) | 33.33% (2/6) |
| `adapters/AaveAdapter.sol` | 100.00% (15/15) | 100.00% (17/17) | 100.00% (4/4) | 100.00% (4/4) |
| `adapters/UniswapV4Adapter.sol` | 100.00% (24/24) | 100.00% (24/24) | 100.00% (2/2) | 100.00% (5/5) |
| `base/BaseStrategy.sol` | 97.92% (47/48) | 88.89% (32/36) | 80.00% (8/10) | 100.00% (18/18) |
| `base/BaseVault.sol` | 100.00% (112/112) | 95.90% (117/122) | 80.77% (21/26) | 100.00% (23/23) |
| `strategies/AaveSimpleLendingStrategy.sol` | 100.00% (22/22) | 96.00% (24/25) | 66.67% (2/3) | 100.00% (7/7) |
| `strategies/WETHLoopStrategy.sol` | 94.12% (96/102) | 83.21% (109/131) | 41.38% (12/29) | 100.00% (13/13) |
| **Total** | **91.53% (324/354)** | **85.94% (330/384)** | **62.96% (51/81)** | **94.74% (72/76)** |

Main gaps:

- `Whitelist.sol`: the batch functions and the unused `onlyWhitelisted` modifier are not covered.
- `WETHLoopStrategy.sol`: 17 of 29 branches, mostly error paths, are not covered.

## Test Organization

```
test/
├── unit/                                   # Unit tests (114 tests)
│   ├── BaseVault.t.sol                    # 22 tests - Vault admin functions
│   ├── Whitelist.t.sol                    # 17 tests - Whitelist enforcement
│   ├── AccessControl.t.sol                # 22 tests - Access control modifiers
│   ├── EdgeCases.t.sol                    # 18 tests - Edge cases and boundaries
│   ├── YieldFlow.t.sol                    #  4 tests - Yield mechanics
│   ├── Adapters.t.sol                     #  9 tests - AaveAdapter and UniswapV4Adapter through harnesses
│   ├── Reentrancy.t.sol                   #  6 tests - Reentrant calls through a callback token
│   ├── PerformanceFeeTiming.t.sol         #  2 tests - Review finding 5
│   ├── EmergencyAccounting.t.sol          #  6 tests - Review finding 1 (mock)
│   ├── EmergencyActivation.t.sol          #  5 tests - Review finding 2 (mock)
│   └── FullExit.t.sol                     #  3 tests - Review finding 3 (mock)
├── integration/                            # Integration tests, mainnet fork (55 tests)
│   ├── AaveSimpleStrategyFork.t.sol       #  3 tests - Aave simple strategy
│   ├── WETHLoopStrategy.t.sol             #  9 tests - WETH leveraged strategy and emergency flow
│   ├── StrategyHealthCheck.t.sol          #  9 tests - Strategy health and harvest
│   ├── WETHLoopStrategyErrorPaths.t.sol   # 18 tests - WETH strategy error paths and views
│   ├── EmergencyAccountingFork.t.sol      #  5 tests - Review finding 1 (fork)
│   ├── EmergencyActivationFork.t.sol      #  5 tests - Review finding 2 (fork)
│   ├── FullExitFork.t.sol                 #  3 tests - Review finding 3 (fork)
│   └── LeverageBoundsFork.t.sol           #  3 tests - E-Mode parameters and leverage limits
├── fuzz/                                   # Stateless fuzzing (43 tests)
│   ├── BaseVaultFuzz.t.sol                # 15 tests - Vault fuzzing (mock)
│   ├── WETHLoopStrategyFuzz.t.sol         # 13 tests - WETH strategy fuzzing (fork)
│   └── AaveSimpleStrategyFuzz.t.sol       # 15 tests - Aave strategy fuzzing (fork)
├── invariant/                              # Stateful fuzzing (25 invariant functions)
│   ├── InvariantBase.sol                  # Shared actors, constants, fork/mock detection
│   ├── BaseVaultInvariant.t.sol           #  8 invariants - Vault
│   ├── WETHLoopStrategyInvariant.t.sol    #  9 invariants - Strategy
│   ├── IntegratedInvariant.t.sol          #  8 invariants - System-wide
│   └── handlers/
│       ├── BaseVaultHandler.sol           # Vault operations, HWM model, simulated yield
│       ├── WETHLoopStrategyHandler.sol    # Strategy operations, equity model, emergency actions
│       └── AdminHandler.sol               # Admin operations
├── gas/                                    # Gas benchmark (10 tests)
│   ├── GasBenchmark.t.sol                 #  5 tests - Shared scenarios, mock mode
│   └── GasBenchmarkFork.t.sol             #  5 tests - Same scenarios, fork mode
├── utils/                                  # Shared helpers (see above)
└── mocks/
    ├── MockStrategy.sol                   # Strategy that keeps funds in the contract
    ├── MockWETH.sol                       # WETH with mint/burn
    ├── MockAavePool.sol                   # Aave V3 Pool simulation (supply is public virtual for test pools)
    ├── MockAToken.sol                     # aToken simulation
    ├── MockVariableDebtToken.sol          # Debt token simulation
    ├── MockPoolManager.sol                # Uniswap V4 PoolManager simulation (settle is public virtual)
    └── ReentrantERC20.sol                 # ERC20 whose next transfer calls back into a target
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
- `test_EmergencyMode_AllowsWithdrawals` - Withdrawals allowed during emergency (with `MockStrategy`)
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

### EdgeCases.t.sol (18 tests)

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
- `test_TotalAssets_WithStrategy` - TotalAssets includes strategy
- `test_TotalAssets_WithoutStrategy` - TotalAssets without strategy

### YieldFlow.t.sol (4 tests)

- `test_FullYieldFlow` - Deposit, yield, withdrawal flow
- `test_RevertIfNotWhitelisted` - Whitelist enforcement on deposits
- `test_SharePriceEvolution` - Share price increases with yield
- `test_PerformanceFeeLogic` - Fee is charged only on gains above the high-water mark

### Adapters.t.sol (9 tests)

The adapters are called through harness contracts (`AaveAdapterHarness`, `UniswapV4AdapterHarness`) against `MockAavePool` and `MockPoolManager`.

- `test_AaveAdapter_ZeroAmounts_DoNotCallPool` - Zero amounts return early without calling the pool
- `test_AaveAdapter_Supply` - Approves and supplies exactly the amount, leaves no allowance
- `test_AaveAdapter_Withdraw_ReturnsWithdrawnAmount` - Returns the amount the pool withdrew, including a full withdrawal
- `test_AaveAdapter_Borrow_UsesVariableRate` - Borrows with interest rate mode 2 and returns the amount
- `test_AaveAdapter_Repay_ReturnsRepaidAmount` - Returns the amount repaid, capped at the debt
- `test_UniswapV4Adapter_FlashLoan_RepaysAndTracksOutstanding` - Callback receives funds and data, outstanding loan tracked during the callback and cleared after, PoolManager repaid in full
- `test_UniswapV4Adapter_UnlockCallback_RevertIfNotPoolManager` - `CallbackUnauthorized` for other callers
- `test_UniswapV4Adapter_RevertIfSettleDoesNotMatch` - `FlashLoanRepaymentFailed` when `settle()` reports a different amount
- `test_UniswapV4Adapter_RevertIfPoolManagerLacksLiquidity` - Flash loan reverts without liquidity

### Reentrancy.t.sol (6 tests)

The vault asset is `ReentrantERC20`, whose next transfer calls back into the vault. Each attempt must revert with `ReentrancyGuardReentrantCall`.

- `test_Reentrancy_DepositDuringDeposit_Reverts`
- `test_Reentrancy_MintDuringDeposit_Reverts`
- `test_Reentrancy_WithdrawDuringWithdraw_Reverts`
- `test_Reentrancy_RedeemDuringRedeem_Reverts`
- `test_Reentrancy_AssessFeeDuringDeposit_Reverts`
- `test_Reentrancy_CallbackOutsideVaultCall_Succeeds` - Control: the same callback outside a vault call succeeds

Removing `nonReentrant` from `deposit` and `withdraw` makes 4 of these tests fail.

### PerformanceFeeTiming.t.sol (2 tests, review finding 5)

- `test_Redeem_AfterProfit_ExitingUserPaysFee` - After a 10 WETH profit on 100 WETH with a 10% fee, the exiting user receives 109 WETH and the fee recipient holds 1 WETH of value
- `test_Deposit_AfterProfit_NewDepositorNotDiluted` - A depositor entering after the profit keeps the deposited value within 2 wei

### EmergencyAccounting.t.sol (6 tests, review finding 1, mock)

Shared with `integration/EmergencyAccountingFork.t.sol` (5 tests, all except the flash loan observation test).

- `test_EmergencyDivest_RedeemReturnsProportionalEquity` - After an emergency divest the only depositor receives the pro rata share of raw equity within 2 wei, and the deposit within 10 wei
- `test_EmergencyDivest_MultipleUsersRedeemProRata` - Two depositors redeem in sequence, each within 2 wei of the pro rata share
- `test_WethLoop_TotalAssetsCountsIdleAssets` - `totalAssets() = collateral + idle - debt` after an emergency divest
- `test_AaveSimple_TotalAssetsCountsIdleAssets` - Idle assets are counted by the Aave simple strategy
- `test_Donation_BeforeFirstDeposit_DoesNotDiluteDepositor` - A 1 WETH donation to the empty strategy leaves the first 1 WETH depositor at least 99.9999% of the deposit
- `test_TotalAssets_NoDoubleCountingDuringFlashLoan` (mock only) - A test pool reads `totalAssets()` inside the flash loan callback; it equals previous equity plus the deposit, without the borrowed WETH

### EmergencyActivation.t.sol (5 tests, review finding 2, mock)

Shared with `integration/EmergencyActivationFork.t.sol` (5 tests).

- `test_AdminEmergency_WethLoop_ClosesPositionAndAllowsRedeem` - Admin activation repays all debt and the user redeems the pro rata share
- `test_AdminEmergency_AaveSimple_ExitsAaveAndAllowsRedeem` - Admin activation withdraws the Aave supply and the user redeems the pro rata share
- `test_AdminEmergency_ExitFailure_FallsBackToProportionalWithdrawals` - With no flash liquidity the exit fails, `EmergencyExitFailed` is emitted, emergency mode stays active and withdrawals deleverage proportionally once liquidity returns
- `test_AdminEmergency_RetryClosesPosition` - A second activation closes the position after a failed exit
- `test_AdminEmergency_RecoveryReinvests` - Deactivation rebuilds the 10x position without changing equity

### FullExit.t.sol (3 tests, review finding 3, mock)

Shared with `integration/FullExitFork.t.sol` (3 tests).

- `test_FullRedeem_SingleDepositor_ClosesPosition` - The only depositor redeems everything; no debt remains
- `test_FullRedeem_LastOfTwoDepositors_ClosesPosition` - The last of two depositors exits; no debt remains
- `test_PartialWithdraw_RemainingEquityExactAndLeverageNotHigher` - Strategy equity decreases by exactly the amount paid (within 2 wei) and leverage does not increase (within 2 wei of Aave rounding on collateral)

## Integration Tests

All integration tests fork Ethereum mainnet at `FORK_BLOCK` (default 26043110). `WETHLoopStrategy.t.sol` and `fuzz/WETHLoopStrategyFuzz.t.sol` `deal` 10,000 WETH to the Uniswap V4 PoolManager and 100 WETH directly to the vault in `setUp`; the review finding tests and `LeverageBoundsFork.t.sol` use the PoolManager's real balance.

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
- `test_CheckHealth_TriggersEmergencyDivest` - Debt exactly 0, collateral at most 2 wei, recovered WETH within 10 wei of the deposit and counted by `totalAssets()`, deposits blocked
- `test_EmergencyMode_WithdrawalsPaidFromIdleWeth` - Resets the vault to its initial deposit, then a vault redemption during emergency pays the pro rata share within 2 wei and the deposit within 10 wei
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

### Review finding fork tests (13 tests)

`EmergencyAccountingFork.t.sol` (5), `EmergencyActivationFork.t.sol` (5) and `FullExitFork.t.sol` (3) run the same tests as their mock counterparts in `unit/`, against Aave V3 and Uniswap V4.

### LeverageBoundsFork.t.sol (3 tests)

- `test_Leverage10x_InitialHealthFactor` - E-Mode LTV 9300 and liquidation threshold 9500 at the fork block; HF at 10x equals `10 * 0.95 / 9`
- `test_Leverage14x_Accepted` - A fresh 14x position is accepted with HF `14 * 0.95 / 13`
- `test_Leverage15x_RejectedByAave` - A fresh 15x position is rejected by Aave's LTV check

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
- `testFuzz_CheckHealth_TriggersEmergency` - Emergency divest when `minHealthFactor` is raised 0.05 to 0.2 above the current health factor; debt exactly 0 and equity within 10 wei of the deposit
- `testFuzz_Recovery_ReinvestsAfterEmergency` - Reinvestment after admin deactivation

**Share Conversion Fuzzing** (2 tests):
- `testFuzz_ShareConversion_Consistency` - Conversions with leverage
- `testFuzz_Preview_MatchesActual` - Preview functions match actual with leverage

**Invariant Fuzzing** (2 tests):
- `testFuzz_Invariant_TotalAssets` - `totalAssets() = aToken - debt + idle WETH` within 100 wei
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

- Emergency operations: exact equality where the code allows it (debt 0, `totalAssets()` formula), 2 wei for share conversion rounding, 10 wei for Aave rounding on a deposit round trip. There is no percentage tolerance on emergency operations.
- Other fork tests: absolute tolerances between 1 and 1,000 wei for Aave rounding; relative tolerances of 1% (conversions and previews) and 5% (leverage ratio).

## Stateful Fuzzing (Invariant) Tests

Each suite uses handler contracts that wrap protocol operations and record ghost variables. Foundry reports `runs: 256, calls: 12800` for every invariant function, since each function runs its own campaign. Handler statistics are logged by `afterInvariant()` hooks (visible with `-vv`), which are not invariants.

### BaseVaultInvariant.t.sol (8 invariants)

Always uses `MockStrategy` and a mock ERC20, in both modes. Protocol fee 10%.

- `invariant_TotalSupplyConsistency` - Total supply = sum of the 5 actors' shares + dead shares + fee recipient shares
- `invariant_DeadSharesConstant` - Dead address holds exactly 1,000 shares
- `invariant_ConversionReversibility` - `convertToShares(convertToAssets(x))` within 10 wei of `x`
- `invariant_EmergencyModeSynchronized` - Vault and strategy emergency flags equal
- `invariant_TotalAssetsConsistency` - Vault `totalAssets()` = idle balance + strategy assets, within 10 wei
- `invariant_WhitelistEnforcement` - Every actor holding shares is whitelisted
- `invariant_HighWaterMarkFollowsDefinition` - HWM equals a model of its definition (`BaseVaultHandler.ghost_expectedHwm`: deposits added, withdrawals subtracted and floored at 0, raised to `totalAssets()` on fee assessment), and HWM `<= totalAssets() + 10 wei` since the suite has no loss source
- `invariant_ProtocolFeeBounded` - Protocol fee `<= 2,500` bps

Handlers: `BaseVaultHandler` (deposit, withdraw, transfer, assessFee, simulateYield) and `AdminHandler` (whitelist add and remove, fee changes, emergency toggle). `simulateYield` sends up to 10% of the strategy's assets to the strategy, only while it has shares outstanding. `AdminHandler` only removes addresses with a zero balance.

### WETHLoopStrategyInvariant.t.sol (9 invariants)

- `invariant_LeverageWithinBounds` - `collateral / (collateral - debt) <= 14.00x`
- `invariant_HealthFactorSafe` - Health factor `>= minHealthFactor - 0.01` unless emergency mode is active
- `invariant_TotalAssetsCalculation` - `totalAssets() = aToken + idle WETH - debt`, exact
- `invariant_EmergencyDivestClosesPosition` - Debt is 0 while emergency mode is active
- `invariant_EmergencyRedeemIsProportional` - During emergency mode a redeem pays the pro rata share of raw equity (vault idle + collateral + strategy idle - debt) within 2 wei
- `invariant_EmergencyModeSynchronized` - Strategy and vault emergency flags equal
- `invariant_StrategyVaultBinding` - `strategy.VAULT()` is the vault
- `invariant_MaxLeverageTracked` - Highest leverage observed by the handler `<= 14.00x`
- `invariant_PositionValueConsistency` - `collateral + idle - debt` equals `ghost_expectedEquity` (deposits minus amounts pulled from the strategy plus interest measured on each warp), within 4 wei per Aave operation

Handler: `WETHLoopStrategyHandler` (deposit 1 wei to 100 WETH through the vault, redeem 1% to 100%, `checkHealth()`, `triggerEmergency()`, `recover()`, time warp of 1 hour to 7 days). `triggerEmergency()` raises `minHealthFactor` above the current health factor, calls `checkHealth()` and restores the thresholds.

The 14x bound: with a 93% LTV the theoretical upper bound on leverage is `1 / (1 - 0.93) = 14.29x`, so the invariant checks that leverage never exceeds what the LTV allows, while the suite targets 10x.

### IntegratedInvariant.t.sol (8 invariants)

Protocol fee 10%.

- `invariant_TotalSupplyConsistency` - Same as the vault suite
- `invariant_VaultStrategyValueConsistency` - Vault `totalAssets()` = vault idle balance + `strategy.totalAssets()`, within 10 wei
- `invariant_NoValueLeak` - Vault `totalAssets()` + withdrawals = initial deposit + deposits + simulated yield + measured interest, within 10 wei plus 4 wei per operation
- `invariant_SystemEmergencyConsistency` - Emergency flags equal
- `invariant_LeverageWithinBounds` - Leverage `<= 14.00x`
- `invariant_HealthFactorSafe` - Health factor `>= minHealthFactor - 0.01` unless emergency mode is active
- `invariant_WhitelistIntegrity` - Every actor holding shares is whitelisted
- `invariant_FeeBounded` - Protocol fee `<= 2,500` bps

Handlers: all three, including `simulateYield`, `triggerEmergency` and `recover`. The admin handler's emergency toggle now closes the position on activation. Handler reverts are tolerated because `fail_on_revert = false`.

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

Mock mode: 25 functions x 256 runs x 50 depth = 320,000 handler calls.

### Mock vs Fork Mode

**Mock mode (default)** uses the contracts in `test/mocks/` and needs no RPC. Limitations:

- `MockAavePool` does not accrue interest and does not enforce the LTV on borrow. The health factor stays at `10 * 0.95 / 9 = 1.0556` for every 10x position, so `checkHealth()` alone never triggers an emergency divest; `triggerEmergency()` and the admin handler do.
- `MockPoolManager` charges no fee and only checks that its balance is restored.

**Fork mode** runs `WETHLoopStrategyInvariant` and `IntegratedInvariant` against Aave V3 and Uniswap V4 at `FORK_BLOCK` with 20 runs x 10 depth (200 handler calls per invariant function). `BaseVaultInvariant` uses mocks in both modes. All 25 invariant functions passed in fork mode with `--threads 1`; the default parallel execution can hit RPC rate limits.

```bash
# Mock mode (default)
forge test --match-path "test/invariant/*.sol"

# Fork mode
INVARIANT_USE_FORK=true FOUNDRY_PROFILE=fork-invariant forge test --match-path "test/invariant/*.sol" --threads 1
```

`.env`:

```env
ETHEREUM_MAINNET_RPC=https://your-rpc-url
INVARIANT_USE_FORK=false  # Set to "true" for fork mode
```

### Ghost Variables

- Vault handler: `ghost_totalDeposited`, `ghost_totalWithdrawn`, `ghost_totalFeesMinted`, `ghost_expectedHwm`, `ghost_totalYield`, per-user deposits and withdrawals, operation counts
- Strategy handler: `ghost_totalInvested`, `ghost_totalDivested`, `ghost_expectedEquity`, `ghost_interest`, `ghost_equityOps`, `ghost_emergencyRedeems`, `ghost_maxEmergencyRedeemError`, `ghost_recoveries`, `ghost_maxLeverageObserved`, `ghost_minHealthFactorObserved`, `ghost_healthCheckCalls`, `ghost_healthCheckFailures`, `ghost_emergencyDivestCount`
- Admin handler: `ghost_whitelistAdditions`, `ghost_whitelistRemovals`, `ghost_feeChanges`, `ghost_emergencyModeChanges`

## Gas Benchmark

`gas/GasBenchmark.t.sol` defines the scenarios and `GasBenchmarkMockTest`; `gas/GasBenchmarkFork.t.sol` runs them as `GasBenchmarkForkTest` at `FORK_BLOCK` with the PoolManager's real WETH balance. `setUp` opens a 1 WETH position at 10x with `vault.mint`, so each measured function is called once per scenario.

- `test_Gas_DepositIntoExistingPosition` - `vault.deposit` of 1 WETH
- `test_Gas_Withdraw` - `vault.withdraw` of 0.5 WETH
- `test_Gas_Redeem` - `vault.redeem` of all shares of the only depositor
- `test_Gas_CheckHealthEmergencyDivest` - `strategy.checkHealth` on the emergency divest path
- `test_Gas_Recovery` - `vault.setEmergencyMode(false)` after an emergency divest

```bash
forge test --match-contract GasBenchmarkMockTest --gas-report
forge test --match-contract GasBenchmarkForkTest --gas-report
```

The measured values are in the main README.

## Running Tests

```bash
# All tests (fork suites need ETHEREUM_MAINNET_RPC)
forge test

# Tests that do not need an RPC
forge test --no-match-path "test/{integration/*,fuzz/*StrategyFuzz.t.sol,gas/GasBenchmarkFork.t.sol}"

# Fork tests against the latest block instead of the pinned one
FORK_BLOCK=0 forge test --match-path "test/integration/*"

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

# Invariant tests with higher depth (mock mode; fork mode will hit RPC rate limits)
forge test --match-path "test/invariant/*.sol" --invariant-depth 100

# Coverage
forge coverage --no-match-coverage "(test|script|mock)"

# Gas report for the whole suite
forge test --gas-report
```

## Test Conventions

- Arrange-Act-Assert structure with `ARRANGE` / `ACT` / `ASSERT` section markers.
- Revert conditions checked with `vm.expectRevert`.
- Events checked with `vm.expectEmit` in `BaseVault.t.sol`, `Whitelist.t.sol` and `EmergencyActivation.t.sol`.
- Regression tests for review findings run in both mock and fork mode from one abstract test contract.

## Dependencies

- Foundry
- OpenZeppelin Contracts (master commit `239795b`, package version 5.5.0)
- Uniswap V4 Core v4.0.0
- Ethereum mainnet RPC with historical state for fork tests (`ETHEREUM_MAINNET_RPC`)
