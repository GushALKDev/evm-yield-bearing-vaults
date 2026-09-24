// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {StrategyTestBase} from "../utils/StrategyTestBase.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title MaxDepositHealthTestBase
 * @notice maxDeposit() and maxMint() return 0 whenever a deposit could revert with HealthFactorBelowMinimum.
 */
abstract contract MaxDepositHealthTestBase is StrategyTestBase {
    uint256 internal constant E_MODE_LIQUIDATION_THRESHOLD = 9500;

    /// @notice With the default thresholds the limits are unlimited and a deposit succeeds.
    function test_MaxDeposit_UnlimitedWhenHealthy() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);

        // ============ ASSERT ============
        assertEq(vault.maxDeposit(alice), type(uint256).max, "Vault maxDeposit should be unlimited");
        assertEq(vault.maxMint(alice), type(uint256).max, "Vault maxMint should be unlimited");
        assertEq(strategy.maxDeposit(address(vault)), type(uint256).max, "Strategy maxDeposit should be unlimited");
        _deposit(vault, bob, 1 ether);
    }

    /// @notice Case a: the existing position is below minHealthFactor while the 10x slice is above it.
    function test_MaxDeposit_ZeroWhenPositionBelowMinimum() public {
        // ============ ARRANGE: 14x POSITION (HF 14 * 0.95 / 13), TARGET BACK TO 10x (HF 10 * 0.95 / 9) ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        vm.prank(admin);
        strategy.setLeverage(14);
        _deposit(vault, alice, 1 ether);
        vm.startPrank(admin);
        strategy.setLeverage(10);
        strategy.setHealthFactors(1.03e18, 1.04e18);
        vm.stopPrank();

        // ============ ASSERT ============
        assertEq(vault.maxDeposit(bob), 0, "Vault maxDeposit should be 0");
        assertEq(vault.maxMint(bob), 0, "Vault maxMint should be 0");
        assertEq(strategy.maxDeposit(address(vault)), 0, "Strategy maxDeposit should be 0");
        assertEq(strategy.maxMint(address(vault)), 0, "Strategy maxMint should be 0");

        // A small deposit barely moves the position, which stays below the minimum
        _fund(bob, 0.01 ether);
        vm.startPrank(bob);
        weth.approve(address(vault), 0.01 ether);
        vm.expectPartialRevert(WETHLoopStrategy.HealthFactorBelowMinimum.selector);
        vault.deposit(0.01 ether, bob);
        vm.stopPrank();
    }

    /// @notice Case b: no position, and the health factor implied by the target leverage is below minHealthFactor.
    function test_MaxDeposit_ZeroWhenImpliedBelowMinimum() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        vm.prank(admin);
        strategy.setHealthFactors(1.06e18, 1.07e18);

        // ============ ASSERT ============
        assertEq(vault.maxDeposit(alice), 0, "Vault maxDeposit should be 0");
        assertEq(vault.maxMint(alice), 0, "Vault maxMint should be 0");

        _fund(alice, 1 ether);
        vm.startPrank(alice);
        weth.approve(address(vault), 1 ether);
        vm.expectPartialRevert(WETHLoopStrategy.HealthFactorBelowMinimum.selector);
        vault.deposit(1 ether, alice);
        vm.stopPrank();
    }

    /// @notice The implied health factor is reduced by HEALTH_FACTOR_MARGIN_BPS before the comparison.
    function test_MaxDeposit_MarginBoundary() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        uint256 implied = uint256(TARGET_LEVERAGE) * E_MODE_LIQUIDATION_THRESHOLD * 1e14 / (TARGET_LEVERAGE - 1);
        uint256 withMargin = implied * (10_000 - strategy.HEALTH_FACTOR_MARGIN_BPS()) / 10_000;

        // ============ ACT & ASSERT: MINIMUM AT THE MARGIN ============
        vm.prank(admin);
        strategy.setHealthFactors(withMargin, withMargin + 0.01e18);
        assertEq(vault.maxDeposit(alice), type(uint256).max, "At the margin the limit stays open");

        // ============ ACT & ASSERT: ONE WEI ABOVE ============
        vm.prank(admin);
        strategy.setHealthFactors(withMargin + 1, withMargin + 0.01e18);
        assertEq(vault.maxDeposit(alice), 0, "Inside the margin the limit is 0 even though implied > minimum");
    }

    /// @notice The strategy's own limits are 0 during emergency mode.
    function test_StrategyMaxDeposit_ZeroInEmergency() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        vm.prank(admin);
        vault.setEmergencyMode(true);

        // ============ ASSERT ============
        assertEq(strategy.maxDeposit(address(vault)), 0, "Strategy maxDeposit should be 0");
        assertEq(strategy.maxMint(address(vault)), 0, "Strategy maxMint should be 0");
    }

    function _deployWethLoopWithoutEMode(uint8 leverage) internal returns (YieldBearingVault vault, WETHLoopStrategy strategy) {
        vault = _deployVault();
        strategy = new WETHLoopStrategy(weth, address(vault), poolManager, aavePool, aToken, debtToken, leverage, MIN_HEALTH_FACTOR, TARGET_HEALTH_FACTOR, 0);
        vm.prank(admin);
        vault.setStrategy(strategy);
    }
}

contract MaxDepositHealthMockTest is MaxDepositHealthTestBase {
    function _useFork() internal pure override returns (bool) {
        return false;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }

    /// @notice The limit follows the live liquidation threshold: 10 * 0.91 / 9 = 1.0111 is below 1.02.
    function test_MaxDeposit_FollowsLiveLiquidationThreshold() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault,) = _deployWethLoop();
        assertEq(vault.maxDeposit(alice), type(uint256).max, "Unlimited at 95%");

        // ============ ACT ============
        mockPool.setLiquidationThreshold(9100);

        // ============ ASSERT ============
        assertEq(vault.maxDeposit(alice), 0, "0 once the liquidation threshold drops");
        _fund(alice, 1 ether);
        vm.startPrank(alice);
        weth.approve(address(vault), 1 ether);
        vm.expectPartialRevert(WETHLoopStrategy.HealthFactorBelowMinimum.selector);
        vault.deposit(1 ether, alice);
        vm.stopPrank();
    }

    /// @notice Without E-Mode the reserve's liquidation threshold from its configuration is used.
    function test_MaxDeposit_ReserveLiquidationThresholdWithoutEMode() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault,) = _deployWethLoopWithoutEMode(TARGET_LEVERAGE);
        assertEq(vault.maxDeposit(alice), type(uint256).max, "Unlimited at 95%");

        // ============ ACT ============
        mockPool.setLiquidationThreshold(9100);

        // ============ ASSERT ============
        assertEq(vault.maxDeposit(alice), 0, "0 once the reserve liquidation threshold drops");
    }
}
