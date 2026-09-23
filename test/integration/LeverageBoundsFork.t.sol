// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {IPool} from "../../src/interfaces/aave/IPool.sol";
import {StrategyTestBase} from "../utils/StrategyTestBase.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title LeverageBoundsForkTest
 * @notice Leverage limits enforced by Aave V3 E-Mode category 1 at FORK_BLOCK (LTV 93%, liquidation threshold 95%).
 * @dev WETHLoopStrategy accepts any targetLeverage >= 2; Aave's LTV check rejects a borrow above 93% of collateral,
 *      so a fresh position at L needs (L - 1) / L <= 0.93, i.e. L <= 14.29.
 */
contract LeverageBoundsForkTest is StrategyTestBase {
    function _useFork() internal pure override returns (bool) {
        return true;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }

    /// @notice At 10x the initial health factor is 10 * 0.95 / 9.
    function test_Leverage10x_InitialHealthFactor() public {
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);

        (,,, uint256 liquidationThreshold, uint256 ltv, uint256 healthFactor) = IPool(aavePool).getUserAccountData(address(strategy));
        assertEq(ltv, 9300, "E-Mode LTV at the fork block");
        assertEq(liquidationThreshold, 9500, "E-Mode liquidation threshold at the fork block");
        assertApproxEqRel(healthFactor, uint256(10 * 0.95e18) / 9, 1e9, "HF_0 = L * LT / (L - 1)");
    }

    /// @notice A fresh position at 14x is accepted with a health factor of 14 * 0.95 / 13.
    function test_Leverage14x_Accepted() public {
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        vm.prank(admin);
        strategy.setLeverage(14);

        _deposit(vault, alice, 1 ether);

        (,,,,, uint256 healthFactor) = IPool(aavePool).getUserAccountData(address(strategy));
        assertApproxEqRel(healthFactor, uint256(14 * 0.95e18) / 13, 1e9, "HF_0 = L * LT / (L - 1)");
    }

    /// @notice A fresh position at 15x is rejected by Aave's LTV check.
    function test_Leverage15x_RejectedByAave() public {
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        vm.prank(admin);
        strategy.setLeverage(15);

        _fund(alice, 1 ether);
        vm.startPrank(alice);
        weth.approve(address(vault), 1 ether);
        vm.expectRevert();
        vault.deposit(1 ether, alice);
        vm.stopPrank();
    }
}
