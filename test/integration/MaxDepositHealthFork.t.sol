// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {IPool} from "../../src/interfaces/aave/IPool.sol";
import {MaxDepositHealthTestBase} from "../unit/MaxDepositHealth.t.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title MaxDepositHealthForkTest
 * @notice maxDeposit() and maxMint() under the minimum health factor check, against Aave V3 and Uniswap V4 at FORK_BLOCK.
 */
contract MaxDepositHealthForkTest is MaxDepositHealthTestBase {
    function _useFork() internal pure override returns (bool) {
        return true;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }

    /// @notice Aave's rounding leaves a real position below L * LT / (L - 1), so without the margin maxDeposit would
    ///         overstate: a minimum between the real and the implied health factor must already give 0.
    function test_MaxDeposit_MarginCoversAaveRounding() public {
        // ============ ARRANGE: MEASURE THE SMALLEST 2x SLICE ============
        (YieldBearingVault probeVault, WETHLoopStrategy probe) = _deployWethLoop();
        vm.prank(admin);
        probe.setLeverage(2);
        uint256 slice = probe.MIN_INVEST_ASSETS();
        _deposit(probeVault, alice, slice);
        (,,,,, uint256 realHealthFactor) = IPool(aavePool).getUserAccountData(address(probe));
        uint256 implied = 2 * E_MODE_LIQUIDATION_THRESHOLD * 1e14;
        assertLt(realHealthFactor, implied, "Aave rounding leaves the real health factor below the implied one");

        // ============ ARRANGE: SAME SLICE, MINIMUM BETWEEN REAL AND IMPLIED ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        vm.startPrank(admin);
        strategy.setLeverage(2);
        strategy.setHealthFactors(realHealthFactor + 1, realHealthFactor + 0.01e18);
        vm.stopPrank();

        // ============ ASSERT ============
        assertEq(vault.maxDeposit(alice), 0, "The margin must turn the limit to 0");
        _fund(alice, slice);
        vm.startPrank(alice);
        weth.approve(address(vault), slice);
        vm.expectPartialRevert(WETHLoopStrategy.HealthFactorBelowMinimum.selector);
        vault.deposit(slice, alice);
        vm.stopPrank();
    }

    /// @notice Without E-Mode the WETH reserve's 83% liquidation threshold applies: 10x implies 0.922, 4x implies 1.107.
    function test_MaxDeposit_ReserveLiquidationThresholdWithoutEMode() public {
        // ============ ASSERT: RESERVE CONFIGURATION AT THE FORK BLOCK ============
        assertEq((IPool(aavePool).getConfiguration(address(weth)) >> 16) & 0xFFFF, 8300, "WETH reserve liquidation threshold");

        // ============ ASSERT: 10x ============
        (YieldBearingVault vault10,) = _deployWethLoopWithoutEMode(10);
        assertEq(vault10.maxDeposit(alice), 0, "10x cannot stay above 1.02 with an 83% threshold");

        // ============ ASSERT: 4x ============
        (YieldBearingVault vault4, WETHLoopStrategy strategy4) = _deployWethLoopWithoutEMode(4);
        assertEq(vault4.maxDeposit(alice), type(uint256).max, "4x stays above 1.02 with an 83% threshold");
        _deposit(vault4, alice, 1 ether);
        (,,,,, uint256 healthFactor) = IPool(aavePool).getUserAccountData(address(strategy4));
        assertGe(healthFactor, MIN_HEALTH_FACTOR, "The 4x deposit keeps the minimum");
    }
}
