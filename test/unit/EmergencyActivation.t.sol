// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {AaveSimpleLendingStrategy} from "../../src/strategies/AaveSimpleLendingStrategy.sol";
import {BaseStrategy} from "../../src/base/BaseStrategy.sol";
import {StrategyTestBase} from "../utils/StrategyTestBase.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title EmergencyActivationTestBase
 * @notice Regression tests for review finding 2: emergency mode activated by the admin left the position open
 *         while withdrawals skipped the divest, so withdrawals reverted in both strategies.
 */
abstract contract EmergencyActivationTestBase is StrategyTestBase {
    /// @notice Admin activation closes the WETH loop position and the user withdraws their share.
    function test_AdminEmergency_WethLoop_ClosesPositionAndAllowsRedeem() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);

        // ============ ACT ============
        vm.prank(admin);
        vault.setEmergencyMode(true);

        // ============ ASSERT ============
        assertEq(IERC20(debtToken).balanceOf(address(strategy)), 0, "Activation should repay all debt");
        assertLt(IERC20(aToken).balanceOf(address(strategy)), 100, "Activation should withdraw the collateral");

        uint256 expected = vault.balanceOf(alice) * _rawEquity(vault, address(strategy)) / vault.totalSupply();
        uint256 received = _redeemAll(vault, alice);
        assertApproxEqAbs(received, expected, 2, "Redeem should pay the proportional share of equity");
        assertApproxEqAbs(received, 1 ether, 10, "User keeps the deposit");
    }

    /// @notice Admin activation withdraws the Aave supply and the user withdraws their share.
    function test_AdminEmergency_AaveSimple_ExitsAaveAndAllowsRedeem() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, AaveSimpleLendingStrategy strategy) = _deployAaveSimple();
        _deposit(vault, alice, 1 ether);

        // ============ ACT ============
        vm.prank(admin);
        vault.setEmergencyMode(true);

        // ============ ASSERT ============
        assertEq(IERC20(aToken).balanceOf(address(strategy)), 0, "Activation should withdraw the Aave supply");

        uint256 expected = vault.balanceOf(alice) * _rawEquity(vault, address(strategy)) / vault.totalSupply();
        uint256 received = _redeemAll(vault, alice);
        assertApproxEqAbs(received, expected, 2, "Redeem should pay the proportional share of equity");
        assertApproxEqAbs(received, 1 ether, 2, "User keeps the deposit");
    }

    /// @notice If the exit cannot complete, emergency mode stays active and withdrawals deleverage proportionally.
    function test_AdminEmergency_ExitFailure_FallsBackToProportionalWithdrawals() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        _deposit(vault, bob, 1 ether);
        uint256 poolManagerBalance = weth.balanceOf(poolManager);
        _setPoolManagerBalance(0);

        // ============ ACT ============
        vm.expectEmit(false, false, false, false, address(strategy));
        emit BaseStrategy.EmergencyExitFailed("");
        vm.prank(admin);
        vault.setEmergencyMode(true);

        // ============ ASSERT: EMERGENCY ACTIVE, POSITION STILL OPEN ============
        assertTrue(vault.emergencyMode(), "Vault emergency mode should be active");
        assertTrue(strategy.emergencyMode(), "Strategy emergency mode should be active");
        assertGt(IERC20(debtToken).balanceOf(address(strategy)), 0, "Position stays open when the exit fails");

        // ============ ASSERT: WITHDRAWALS DELEVERAGE ONCE LIQUIDITY RETURNS ============
        _setPoolManagerBalance(poolManagerBalance);
        uint256 expected = vault.balanceOf(alice) * _rawEquity(vault, address(strategy)) / vault.totalSupply();
        uint256 received = _redeemAll(vault, alice);
        assertApproxEqAbs(received, expected, 2, "Redeem should pay the proportional share of equity");
        assertGt(IERC20(debtToken).balanceOf(address(strategy)), 0, "Bob's share of the position stays leveraged");
    }

    /// @notice Calling setEmergencyMode(true) again retries the exit after a failed attempt.
    function test_AdminEmergency_RetryClosesPosition() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        uint256 poolManagerBalance = weth.balanceOf(poolManager);
        _setPoolManagerBalance(0);
        vm.prank(admin);
        vault.setEmergencyMode(true);
        _setPoolManagerBalance(poolManagerBalance);

        // ============ ACT ============
        vm.prank(admin);
        vault.setEmergencyMode(true);

        // ============ ASSERT ============
        assertEq(IERC20(debtToken).balanceOf(address(strategy)), 0, "Retry should close the position");
    }

    /// @notice Deactivating emergency mode after an admin activation rebuilds the leveraged position.
    function test_AdminEmergency_RecoveryReinvests() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        vm.prank(admin);
        vault.setEmergencyMode(true);
        uint256 equity = strategy.totalAssets();

        // ============ ACT ============
        vm.prank(admin);
        vault.setEmergencyMode(false);

        // ============ ASSERT ============
        assertLt(weth.balanceOf(address(strategy)), 100, "Idle WETH should be reinvested");
        assertApproxEqAbs(IERC20(debtToken).balanceOf(address(strategy)), equity * (TARGET_LEVERAGE - 1), 10, "Debt back at target leverage");
        assertApproxEqAbs(strategy.totalAssets(), equity, 10, "Reinvesting does not change equity");
    }

    function _setPoolManagerBalance(uint256 amount) internal {
        if (_useFork()) {
            deal(address(weth), poolManager, amount);
            return;
        }
        uint256 current = weth.balanceOf(poolManager);
        if (current > amount) mockWeth.burn(poolManager, current - amount);
        else mockWeth.mint(poolManager, amount - current);
    }
}

contract EmergencyActivationMockTest is EmergencyActivationTestBase {
    function _useFork() internal pure override returns (bool) {
        return false;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }
}
