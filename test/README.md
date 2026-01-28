# Test Suite Documentation

## Overview

This test suite provides comprehensive coverage for the Yield Bearing Vaults system, organized into **unit tests** (isolated contract testing with mocks) and **integration tests** (fork tests with real protocols).

## Test Statistics

- **Total Tests**: 135
- **Unit Tests**: 100
- **Integration Tests**: 35
- **Pass Rate**: 100%

## Code Coverage

```
╭─────────────────┬──────────┬─────────┬─────────────┬──────────┬────────╮
│ Metric          │ Covered  │ Total   │ Percentage  │ Target   │ Status │
├─────────────────┼──────────┼─────────┼─────────────┼──────────┼────────┤
│ Lines           │ 209      │ 223     │ 93.72%      │ ≥90%     │ ✅ PASS│
│ Statements      │ 209      │ 233     │ 89.70%      │ ≥85%     │ ✅ PASS│
│ Branches        │ 31       │ 46      │ 67.39%      │ ≥60%     │ ✅ PASS│
│ Functions       │ 54       │ 57      │ 94.74%      │ ≥90%     │ ✅ PASS│
╰─────────────────┴──────────┴─────────┴─────────────┴──────────┴────────╯
```

### Per-File Coverage

**✅ Perfect Coverage (100%)**:
- `BaseVault.sol` - 100% lines, statements, branches, functions
- `AaveSimpleLendingStrategy.sol` - 100% lines, statements, functions
- `UniswapV4Adapter.sol` - 100% lines, statements, branches, functions

**⭐ Excellent Coverage (90%+)**:
- `BaseStrategy.sol` - 96% lines, 85.71% statements, 100% functions
- `AaveAdapter.sol` - 100% lines, 82.35% statements, 100% functions

**✔️ Good Coverage (80%+)**:
- `WETHLoopStrategy.sol` - 85.07% lines, 80.25% statements, 83.33% functions

**⚠️ Needs Improvement**:
- `Whitelist.sol` - 66.67% lines, 0% branches (modifier not tested directly)

### Coverage Improvements

**Before New Tests** (92 tests):
- Lines: 88.79%, Statements: 85.41%, Branches: 63.04%, Functions: 84.21%

**After New Tests** (135 tests, +43):
- Lines: 93.72% (+4.93%)
- Statements: 89.70% (+4.29%)
- Branches: 67.39% (+4.35%)
- Functions: 94.74% (+10.53%)

## Test Organization

```
test/
├── unit/                                   # Unit tests (100 tests)
│   ├── BaseVault.t.sol                    # 22 tests - Vault admin functions
│   ├── Whitelist.t.sol                    # 17 tests - Whitelist enforcement
│   ├── AccessControl.t.sol                # 22 tests - Access control modifiers
│   ├── EdgeCases.t.sol                    # 19 tests - Edge cases and boundaries
│   ├── YieldFlow.t.sol                    #  4 tests - Yield mechanics
│   └── AdapterErrorPaths.t.sol            # 16 tests - Adapter edge cases
├── integration/                            # Integration tests (35 tests)
│   ├── AaveSimpleStrategyFork.t.sol       #  3 tests - Aave simple strategy
│   ├── WETHLoopStrategy.t.sol             #  5 tests - WETH leveraged strategy
│   ├── StrategyHealthCheck.t.sol          #  9 tests - Strategy health & harvest
│   └── WETHLoopStrategyErrorPaths.t.sol   # 18 tests - WETH strategy error paths
└── mocks/
    └── MockStrategy.sol                   # Mock strategy for unit tests
```

## Unit Tests Coverage

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
- `test_EmergencyMode_AllowsWithdrawals` - Withdrawals allowed during emergency
- `test_SetEmergencyMode_RevertIfNotAdmin` - Only admin can toggle emergency

**Constructor & State**:
- `test_Constructor_RevertIfIncorrectInitialDeposit` - Validates initial deposit
- `test_Constructor_BurnsInitialDeposit` - Initial shares burned to dead address
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
- `test_AddMultipleToWhitelist` - Multiple addresses can be whitelisted

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
- `test_Strategy_EmergencyMode_AllowsWithdrawals` - Withdrawals allowed during emergency
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
- `test_Withdraw_ZeroAmount` - Zero withdrawal works correctly
- `test_Redeem_ZeroShares` - Zero redeem works correctly

**Dust Amount Tests**:
- `test_Deposit_DustAmount` - Dust deposits (1 wei) handled correctly
- `test_InflationProtection_SmallDeposits` - Inflation attack protection works

**Maximum Amount Tests**:
- `test_Deposit_MaximumAmount` - Can deposit maximum balance
- `test_Withdraw_MaximumShares` - Can withdraw all shares

**Fee Edge Cases**:
- `test_PerformanceFee_ZeroFee` - Zero fee works correctly
- `test_PerformanceFee_NoRecipient` - No fees without recipient
- `test_PerformanceFee_MaximumFee` - Maximum fee (25%) works correctly

**Conversion Tests**:
- `test_ConvertToShares_ZeroAssets` - Zero asset conversion
- `test_ConvertToAssets_ZeroShares` - Zero share conversion
- `test_PreviewDeposit_Accuracy` - Preview matches actual deposit
- `test_PreviewWithdraw_Accuracy` - Preview matches actual withdrawal

**Other Tests**:
- `test_Deposit_BlockedDuringEmergency` - Emergency blocks deposits
- `test_MaxDeposit_ReturnsMaxUint` - MaxDeposit returns correct value
- `test_ReentrancyGuard_DepositsProtected` - Reentrancy protection active
- `test_TotalAssets_WithStrategy` - TotalAssets includes strategy
- `test_TotalAssets_WithoutStrategy` - TotalAssets without strategy

### YieldFlow.t.sol (4 tests)

**Yield Mechanics**:
- `test_FullYieldFlow` - Complete deposit → yield → withdrawal flow
- `test_RevertIfNotWhitelisted` - Whitelist enforcement on deposits
- `test_SharePriceEvolution` - Share price increases with yield
- `test_PerformanceFeeLogic` - High Water Mark prevents double taxation

### AdapterErrorPaths.t.sol (16 tests)

**Adapter Edge Cases**:
- `test_AaveAdapter_Supply_ZeroAmount` - Zero amount handling
- `test_AaveAdapter_Withdraw_ZeroAmount` - Zero withdrawal
- `test_AaveAdapter_Borrow_ZeroAmount` - Zero borrow
- `test_AaveAdapter_Repay_ZeroAmount` - Zero repay
- `test_AaveAdapter_ValidParameters` - Parameter validation
- `test_AaveAdapter_MaxUint256Amount` - Max amount handling
- `test_Adapter_AddressValidation` - Address validation
- `test_Adapter_AmountValidation` - Amount validation
- `test_Adapter_EdgeCaseAmounts` - Edge case amounts (dust, large)
- `test_InterestRateMode_Constants` - Interest rate mode constants
- `test_VariableInterestRateMode` - Variable rate mode
- `test_AaveAdapter_LibraryImport` - Library import validation
- `test_AaveAdapter_RealisticParameters` - Realistic parameters
- `test_Adapter_NoOverflow` - No overflow in calculations
- `test_Adapter_PercentageCalculations` - Percentage calculations
- `test_Adapter_BasisPointsCalculations` - Basis points calculations

## Integration Tests Coverage

### AaveSimpleStrategyFork.t.sol (3 tests)

Tests the simple Aave V3 lending strategy using Ethereum mainnet fork:
- `test_DepositInvestsInAave` - Funds deposited to Aave correctly
- `test_WithdrawDivestsFromAave` - Withdrawals include accrued yield
- `test_RedeemDivestsFromAave` - Redemptions include accrued yield

### WETHLoopStrategy.t.sol (5 tests)

Tests the leveraged WETH strategy using Uniswap V4 flash loans and Aave V3 E-Mode:
- `test_Invest_LeveragesCorrectly` - 10x leverage established correctly
- `test_Invest_MultipleDeposits` - Multiple deposits maintain health
- `test_Divest_PartialWithdrawal` - Proportional deleverage works
- `test_Divest_FullWithdrawal` - Full position exit works
- `test_MultipleUsers_DifferentDepositWithdrawOrder` - Multi-user scenarios

### StrategyHealthCheck.t.sol (9 tests)

Tests health monitoring and harvest functions:
- `test_WETHStrategy_CheckHealth_Healthy` - WETH strategy health check
- `test_WETHStrategy_Harvest` - WETH harvest function
- `test_WETHStrategy_TotalAssets` - WETH total assets calculation
- `test_USDCStrategy_CheckHealth` - USDC strategy health check
- `test_USDCStrategy_Harvest_Reverts` - USDC harvest reverts (not harvestable)
- `test_USDCStrategy_TotalAssets` - USDC total assets calculation
- `test_USDCStrategy_TotalAssets_IncreasesWithYield` - USDC yield accrual
- `test_Strategies_BothHealthy` - Both strategies healthy
- `test_Strategies_HarvestBehavior` - Harvest behavior comparison

### WETHLoopStrategyErrorPaths.t.sol (18 tests)

Tests error paths and edge cases for leveraged strategy:
- `test_UnlockCallback_RevertIfNotPoolManager` - Flash loan callback protection
- `test_Withdraw_WithNoPosition_Reverts` - Withdrawal without position
- `test_Redeem_WithNoShares` - Redeem with zero shares
- `test_TotalAssets_NoPosition` - Total assets with no position
- `test_TotalAssets_WithDebt` - Total assets with debt
- `test_PreviewDeposit_Zero` - Preview deposit of zero
- `test_PreviewWithdraw_Zero` - Preview withdraw of zero
- `test_PreviewMint_Zero` - Preview mint of zero
- `test_PreviewRedeem_Zero` - Preview redeem of zero
- `test_MaxDeposit` - Max deposit returns max uint256
- `test_MaxMint` - Max mint returns max uint256
- `test_MaxWithdraw_WithPosition` - Max withdraw with position
- `test_MaxRedeem_WithShares` - Max redeem with shares
- `test_ConvertToShares_Zero` - Convert zero assets to shares
- `test_ConvertToAssets_Zero` - Convert zero shares to assets
- `test_ConvertAccuracy_AfterDeposit` - Conversion accuracy
- `test_ImmutableValues` - Immutable values set correctly
- `test_EmergencyMode_Propagates` - Emergency mode propagation

## Running Tests

```bash
# Run all tests
forge test

# Run unit tests only
forge test --match-path "test/unit/*.sol"

# Run integration tests only
forge test --match-path "test/integration/*.sol"

# Run specific test file
forge test --match-path test/unit/BaseVault.t.sol

# Run specific test function
forge test --match-test test_SetAdmin_Success

# Run with verbosity
forge test -vvv

# Run with gas report
forge test --gas-report
```

## Coverage Areas

### ✅ Fully Covered (100%)

1. **BaseVault.sol**: 100% lines, statements, branches, functions
2. **AaveSimpleLendingStrategy.sol**: 100% lines, statements, functions
3. **UniswapV4Adapter.sol**: 100% lines, statements, branches, functions

### ✅ High Coverage (90%+)

4. **BaseStrategy.sol**: 96% lines, 85.71% statements, 100% functions
5. **Total Coverage**: 93.72% lines, 89.70% statements, 94.74% functions

### 🔄 Good Coverage (80%+)

6. **WETHLoopStrategy.sol**: 85.07% lines, 80.25% statements, 83.33% functions
7. **AaveAdapter.sol**: 100% lines, 82.35% statements, 100% functions

### ⚠️ Areas for Improvement

1. **Whitelist.sol**: 66.67% lines, 0% branches - `onlyWhitelisted` modifier not tested directly
2. **WETHLoopStrategy.sol**: 41.18% branches - Some error paths in complex leverage logic
3. **AaveAdapter.sol**: 25% branches - Error handling paths

### 📝 Not Included

1. **Gas Optimization**: No specific gas benchmarking tests
2. **Fuzz Testing**: No property-based fuzz tests
3. **Invariant Testing**: No invariant tests for core properties
4. **Stress Testing**: No extreme value or DoS tests

## Key Test Patterns Used

1. **AAA Pattern**: Arrange-Act-Assert structure in all tests
2. **Descriptive Names**: Test names clearly describe what is tested
3. **NatSpec Documentation**: All tests have clear documentation
4. **Error Testing**: Explicit testing of revert conditions
5. **Event Testing**: Verification of emitted events
6. **State Verification**: Checking contract state before and after operations

## Dependencies

- **Foundry**: Testing framework
- **OpenZeppelin Contracts v5**: Base implementations
- **Ethereum Mainnet Fork**: For integration tests (requires ETHEREUM_MAINNET_RPC)

## Notes

- All tests follow the CEII pattern (Checks-Effects-Interactions-Invariants)
- Integration tests require `ETHEREUM_MAINNET_RPC` environment variable
- Tests use realistic values and scenarios from production environments
- Dust tolerance (≤10 wei) is considered acceptable in integration tests due to Aave rounding
