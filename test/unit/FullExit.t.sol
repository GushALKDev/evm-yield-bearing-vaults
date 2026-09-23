// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {StrategyTestBase} from "../utils/StrategyTestBase.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title FullExitTestBase
 * @notice Regression tests for review finding 3: the last depositor redeeming 100% through the vault left a dust
 *         leveraged position (about 9,000 wei of debt), which Aave rejects on withdraw with
 *         HealthFactorLowerThanLiquidationThreshold().
 */
abstract contract FullExitTestBase is StrategyTestBase {
    uint256 internal constant AAVE_ROUNDING = 2;

    /// @notice The only depositor redeems all shares and the leveraged position is closed completely.
    function test_FullRedeem_SingleDepositor_ClosesPosition() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        uint256 expected = vault.balanceOf(alice) * _rawEquity(vault, address(strategy)) / vault.totalSupply();

        // ============ ACT ============
        uint256 received = _redeemAll(vault, alice);

        // ============ ASSERT ============
        assertApproxEqAbs(received, expected, 2, "Redeem should pay the proportional share of equity");
        assertEq(IERC20(debtToken).balanceOf(address(strategy)), 0, "No debt may remain after the last exit");
        assertLt(IERC20(aToken).balanceOf(address(strategy)), 100, "Collateral should be withdrawn");
    }

    /// @notice Two depositors exit one after the other; the last exit closes the position.
    function test_FullRedeem_LastOfTwoDepositors_ClosesPosition() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        _deposit(vault, bob, 3 ether);

        // ============ ACT ============
        _redeemAll(vault, alice);
        uint256 expectedBob = vault.balanceOf(bob) * _rawEquity(vault, address(strategy)) / vault.totalSupply();
        uint256 receivedBob = _redeemAll(vault, bob);

        // ============ ASSERT ============
        assertApproxEqAbs(receivedBob, expectedBob, 2, "Last depositor gets the proportional share");
        assertEq(IERC20(debtToken).balanceOf(address(strategy)), 0, "No debt may remain after the last exit");
    }

    /// @notice A partial withdrawal reduces strategy equity by exactly the amount paid and does not raise leverage.
    function test_PartialWithdraw_RemainingEquityExactAndLeverageNotHigher() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        _deposit(vault, bob, 1 ether);
        uint256 equityBefore = strategy.totalAssets();
        uint256 collateralBefore = IERC20(aToken).balanceOf(address(strategy));
        uint256 debtBefore = IERC20(debtToken).balanceOf(address(strategy));
        uint256 vaultIdleBefore = weth.balanceOf(address(vault));
        uint256 amount = 0.3 ether + 7;

        // ============ ACT ============
        vm.prank(alice);
        vault.withdraw(amount, alice, alice);

        // ============ ASSERT ============
        uint256 pulledFromStrategy = amount - (vaultIdleBefore - weth.balanceOf(address(vault)));
        assertApproxEqAbs(strategy.totalAssets(), equityBefore - pulledFromStrategy, 2, "Remaining equity decreases by the amount paid");

        uint256 collateralAfter = IERC20(aToken).balanceOf(address(strategy));
        uint256 debtAfter = IERC20(debtToken).balanceOf(address(strategy));
        // collateralAfter / debtAfter >= collateralBefore / debtBefore. The strategy rounds debt repayment up;
        // Aave's scaled-balance rounding can still move collateral by up to 2 wei, which is allowed here.
        assertGe(collateralAfter + AAVE_ROUNDING, collateralBefore * debtAfter / debtBefore, "Leverage must not increase");
    }
}

contract FullExitMockTest is FullExitTestBase {
    function _useFork() internal pure override returns (bool) {
        return false;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }
}
