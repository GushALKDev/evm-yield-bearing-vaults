// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {BaseVault} from "../../src/base/BaseVault.sol";
import {BaseStrategy} from "../../src/base/BaseStrategy.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {IPool} from "../../src/interfaces/aave/IPool.sol";
import {StrategyTestBase} from "../utils/StrategyTestBase.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title EmergencyRecoveryTestBase
 * @notice Two-step exit from emergency mode: setEmergencyMode(false) only clears the flags, reinvest() rebuilds the
 *         position and requires the health factor to reach targetHealthFactor.
 */
abstract contract EmergencyRecoveryTestBase is StrategyTestBase {
    /// @notice Leaving emergency mode keeps the recovered WETH idle.
    function test_Exit_DoesNotReinvest() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        vm.prank(admin);
        vault.setEmergencyMode(true);
        uint256 idle = weth.balanceOf(address(strategy));

        // ============ ACT ============
        vm.prank(admin);
        vault.setEmergencyMode(false);

        // ============ ASSERT ============
        assertFalse(vault.emergencyMode(), "Vault emergency mode should be off");
        assertFalse(strategy.emergencyMode(), "Strategy emergency mode should be off");
        assertEq(weth.balanceOf(address(strategy)), idle, "Idle WETH should stay idle");
        assertEq(IERC20(debtToken).balanceOf(address(strategy)), 0, "No position should be opened");
    }

    /// @notice reinvest() rebuilds the position at target leverage with the health factor at or above target.
    function test_Reinvest_RebuildsPositionAtTarget() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        vm.startPrank(admin);
        vault.setEmergencyMode(true);
        vault.setEmergencyMode(false);
        vm.stopPrank();
        uint256 equity = strategy.totalAssets();

        // ============ ACT ============
        vm.prank(admin);
        vault.reinvest();

        // ============ ASSERT ============
        (,,,,, uint256 healthFactor) = IPool(aavePool).getUserAccountData(address(strategy));
        assertGe(healthFactor, TARGET_HEALTH_FACTOR, "Health factor should reach the target");
        assertEq(weth.balanceOf(address(strategy)), 0, "Idle WETH should be reinvested");
        assertApproxEqAbs(IERC20(debtToken).balanceOf(address(strategy)), equity * (TARGET_LEVERAGE - 1), 10, "Debt back at target leverage");
        assertApproxEqAbs(strategy.totalAssets(), equity, 10, "Reinvesting does not change equity");
    }

    /// @notice reinvest() reverts when the rebuilt position would sit below targetHealthFactor.
    function test_Reinvest_RevertsBelowTargetHealthFactor() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        (,,,,, uint256 healthFactor) = IPool(aavePool).getUserAccountData(address(strategy));
        vm.startPrank(admin);
        vault.setEmergencyMode(true);
        vault.setEmergencyMode(false);
        // 10x rebuilds at the same health factor as before, which is now below the target
        strategy.setHealthFactors(MIN_HEALTH_FACTOR, healthFactor + 0.01e18);
        vm.stopPrank();
        uint256 idle = weth.balanceOf(address(strategy));

        // ============ ACT & ASSERT ============
        vm.expectPartialRevert(WETHLoopStrategy.HealthFactorBelowTarget.selector);
        vm.prank(admin);
        vault.reinvest();

        assertEq(weth.balanceOf(address(strategy)), idle, "Idle WETH should stay idle");
        assertEq(IERC20(debtToken).balanceOf(address(strategy)), 0, "No position should be opened");
    }

    /// @notice reinvest() reverts while emergency mode is active, in the vault and in the strategy.
    function test_Reinvest_RevertsInEmergency() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        vm.prank(admin);
        vault.setEmergencyMode(true);

        // ============ ACT & ASSERT ============
        vm.expectRevert(BaseVault.VaultInEmergency.selector);
        vm.prank(admin);
        vault.reinvest();

        vm.expectRevert(BaseStrategy.StrategyInEmergency.selector);
        vm.prank(address(vault));
        strategy.reinvest();
    }

    /// @notice Leaving emergency mode succeeds when reinvesting would revert (no flash loan liquidity).
    function test_Exit_SucceedsWhenReinvestWouldRevert() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        vm.prank(admin);
        vault.setEmergencyMode(true);
        _setPoolManagerBalance(0);

        // ============ ACT ============
        vm.prank(admin);
        vault.setEmergencyMode(false);

        // ============ ASSERT ============
        assertFalse(vault.emergencyMode(), "Exit should succeed without flash loan liquidity");
        assertFalse(strategy.emergencyMode(), "Strategy emergency mode should be off");

        vm.expectRevert();
        vm.prank(admin);
        vault.reinvest();

        uint256 received = _redeemAll(vault, alice);
        assertApproxEqAbs(received, 1 ether, 10, "Withdrawals keep working from idle WETH");
    }

    /// @notice Between exit and reinvest a deposit invests only itself at target leverage; idle WETH waits for reinvest().
    function test_DepositAfterExit_InvestsOnlyTheDeposit() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        vm.startPrank(admin);
        vault.setEmergencyMode(true);
        vault.setEmergencyMode(false);
        vm.stopPrank();
        uint256 idle = weth.balanceOf(address(strategy));

        // ============ ACT ============
        _deposit(vault, bob, 2 ether);

        // ============ ASSERT ============
        assertEq(weth.balanceOf(address(strategy)), idle, "Idle WETH should wait for reinvest()");
        assertApproxEqAbs(IERC20(aToken).balanceOf(address(strategy)), 2 ether * uint256(TARGET_LEVERAGE), 2, "Deposit supplied at target leverage");
        assertApproxEqAbs(IERC20(debtToken).balanceOf(address(strategy)), 2 ether * uint256(TARGET_LEVERAGE - 1), 2, "Deposit borrowed at target leverage");
    }

    /// @notice After exit, a deposit that would open a position below minHealthFactor reverts.
    function test_DepositAfterExit_RevertsBelowMinHealthFactor() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        (,,,,, uint256 healthFactor) = IPool(aavePool).getUserAccountData(address(strategy));
        vm.startPrank(admin);
        vault.setEmergencyMode(true);
        vault.setEmergencyMode(false);
        // 10x opens at the same health factor as before, which is now below the minimum
        strategy.setHealthFactors(healthFactor + 0.01e18, healthFactor + 0.02e18);
        vm.stopPrank();

        _fund(bob, 1 ether);
        vm.startPrank(bob);
        weth.approve(address(vault), 1 ether);

        // ============ ACT & ASSERT ============
        vm.expectPartialRevert(WETHLoopStrategy.HealthFactorBelowMinimum.selector);
        vault.deposit(1 ether, bob);
        vm.stopPrank();

        assertEq(IERC20(debtToken).balanceOf(address(strategy)), 0, "No position should be opened");
    }

    /// @notice Idle WETH below MIN_INVEST_ASSETS stays idle on reinvest() instead of opening a dust position.
    function test_Reinvest_DustIdleStaysIdle() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _fund(address(strategy), 1000);

        // ============ ACT ============
        vm.prank(admin);
        vault.reinvest();

        // ============ ASSERT ============
        assertEq(weth.balanceOf(address(strategy)), 1000, "Dust should stay idle");
        assertEq(IERC20(aToken).balanceOf(address(strategy)), 0, "No collateral should be supplied");
        assertEq(IERC20(debtToken).balanceOf(address(strategy)), 0, "No debt should be taken");
    }

    /// @notice A deposit below MIN_INVEST_ASSETS stays idle and is invested by reinvest() once idle reaches the bound.
    function test_Deposit_DustStaysIdleUntilReinvest() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        uint256 dust = strategy.MIN_INVEST_ASSETS() - 1;

        // ============ ACT: DUST DEPOSIT ============
        _deposit(vault, alice, dust);

        // ============ ASSERT: IDLE ============
        assertEq(weth.balanceOf(address(strategy)), dust, "Dust deposit should stay idle");
        assertEq(IERC20(debtToken).balanceOf(address(strategy)), 0, "No position should be opened");
        assertApproxEqAbs(strategy.totalAssets(), dust, 1, "Idle dust is counted by totalAssets()");

        // ============ ACT: IDLE REACHES THE BOUND ============
        _fund(address(strategy), 1);
        vm.prank(admin);
        vault.reinvest();

        // ============ ASSERT: INVESTED ============
        assertEq(weth.balanceOf(address(strategy)), 0, "Idle WETH should be reinvested");
        assertGt(IERC20(debtToken).balanceOf(address(strategy)), 0, "Position should be opened");
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

contract EmergencyRecoveryMockTest is EmergencyRecoveryTestBase {
    function _useFork() internal pure override returns (bool) {
        return false;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }
}
