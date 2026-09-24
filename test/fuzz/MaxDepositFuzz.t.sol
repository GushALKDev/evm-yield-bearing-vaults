// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {IPool} from "../../src/interfaces/aave/IPool.sol";
import {StrategyTestBase} from "../utils/StrategyTestBase.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title MaxDepositFuzzBase
 * @notice Whenever maxDeposit() is not 0, depositing does not revert with HealthFactorBelowMinimum.
 * @dev minHealthFactor is drawn within 0.2% of the lower of the existing position's health factor and the one
 *      implied by the target leverage, so runs land on both sides of HEALTH_FACTOR_MARGIN_BPS.
 */
abstract contract MaxDepositFuzzBase is StrategyTestBase {
    uint256 internal constant E_MODE_LIQUIDATION_THRESHOLD = 9500;

    function testFuzz_MaxDeposit_NeverOverstates(uint256 existingAmount, uint256 existingLeverage, uint256 leverage, uint256 minSeed, uint256 amount) public {
        // ============ ARRANGE: OPTIONAL EXISTING POSITION ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        existingAmount = bound(existingAmount, 0, 10 ether);
        existingLeverage = bound(existingLeverage, 2, 14);
        if (existingAmount > 0) {
            vm.prank(admin);
            strategy.setLeverage(uint8(existingLeverage));
            _deposit(vault, alice, existingAmount);
        }

        // ============ ARRANGE: TARGET LEVERAGE AND MINIMUM NEAR THE EDGE ============
        leverage = bound(leverage, 2, 14);
        uint256 edge = leverage * E_MODE_LIQUIDATION_THRESHOLD * 1e14 / (leverage - 1);
        if (IERC20(debtToken).balanceOf(address(strategy)) > 0) {
            (,,,,, uint256 healthFactor) = IPool(aavePool).getUserAccountData(address(strategy));
            if (healthFactor < edge) edge = healthFactor;
        }
        uint256 minimum = bound(minSeed, edge * 998 / 1000, edge * 1002 / 1000);
        vm.startPrank(admin);
        strategy.setLeverage(uint8(leverage));
        strategy.setHealthFactors(minimum, minimum + 0.01e18);
        vm.stopPrank();

        // ============ ACT ============
        if (vault.maxDeposit(bob) == 0) return;
        amount = bound(amount, 1, 20 ether);
        _fund(bob, amount);
        vm.startPrank(bob);
        weth.approve(address(vault), amount);
        try vault.deposit(amount, bob) {}
        catch (bytes memory reason) {
            // ============ ASSERT ============
            assertTrue(bytes4(reason) != WETHLoopStrategy.HealthFactorBelowMinimum.selector, "maxDeposit was not 0 but the deposit hit the minimum");
        }
        vm.stopPrank();
    }
}

contract MaxDepositMockFuzzTest is MaxDepositFuzzBase {
    function _useFork() internal pure override returns (bool) {
        return false;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }
}
