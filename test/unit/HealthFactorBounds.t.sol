// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {StrategyTestBase} from "../utils/StrategyTestBase.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title HealthFactorBoundsTest
 * @notice Boundaries of 1e18 < minHealthFactor < targetHealthFactor in the constructor and in setHealthFactors().
 */
contract HealthFactorBoundsTest is StrategyTestBase {
    uint256 internal constant ONE = 1e18;

    YieldBearingVault internal vault;
    WETHLoopStrategy internal strategy;

    function _useFork() internal pure override returns (bool) {
        return false;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
        (vault, strategy) = _deployWethLoop();
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice minHealthFactor equal to 1e18 is rejected.
    function test_Constructor_RevertIfMinAtOne() public {
        vm.expectRevert(abi.encodeWithSelector(WETHLoopStrategy.InvalidHealthFactors.selector, ONE, TARGET_HEALTH_FACTOR));
        _deployStrategy(ONE, TARGET_HEALTH_FACTOR);
    }

    /// @notice minHealthFactor one wei above 1e18 is accepted.
    function test_Constructor_AcceptsMinJustAboveOne() public {
        WETHLoopStrategy deployed = _deployStrategy(ONE + 1, TARGET_HEALTH_FACTOR);
        assertEq(deployed.minHealthFactor(), ONE + 1, "Min health factor should be stored");
    }

    /// @notice minHealthFactor equal to targetHealthFactor is rejected.
    function test_Constructor_RevertIfMinEqualsTarget() public {
        vm.expectRevert(abi.encodeWithSelector(WETHLoopStrategy.InvalidHealthFactors.selector, MIN_HEALTH_FACTOR, MIN_HEALTH_FACTOR));
        _deployStrategy(MIN_HEALTH_FACTOR, MIN_HEALTH_FACTOR);
    }

    /// @notice targetHealthFactor one wei above minHealthFactor is accepted.
    function test_Constructor_AcceptsTargetJustAboveMin() public {
        WETHLoopStrategy deployed = _deployStrategy(MIN_HEALTH_FACTOR, MIN_HEALTH_FACTOR + 1);
        assertEq(deployed.targetHealthFactor(), MIN_HEALTH_FACTOR + 1, "Target health factor should be stored");
    }

    /*//////////////////////////////////////////////////////////////
                           SET HEALTH FACTORS
    //////////////////////////////////////////////////////////////*/

    /// @notice minHealthFactor equal to 1e18 is rejected.
    function test_SetHealthFactors_RevertIfMinAtOne() public {
        vm.expectRevert(abi.encodeWithSelector(WETHLoopStrategy.InvalidHealthFactors.selector, ONE, TARGET_HEALTH_FACTOR));
        vm.prank(admin);
        strategy.setHealthFactors(ONE, TARGET_HEALTH_FACTOR);
    }

    /// @notice minHealthFactor one wei above 1e18 is accepted.
    function test_SetHealthFactors_AcceptsMinJustAboveOne() public {
        vm.prank(admin);
        strategy.setHealthFactors(ONE + 1, TARGET_HEALTH_FACTOR);
        assertEq(strategy.minHealthFactor(), ONE + 1, "Min health factor should be stored");
    }

    /// @notice minHealthFactor equal to targetHealthFactor is rejected.
    function test_SetHealthFactors_RevertIfMinEqualsTarget() public {
        vm.expectRevert(abi.encodeWithSelector(WETHLoopStrategy.InvalidHealthFactors.selector, MIN_HEALTH_FACTOR, MIN_HEALTH_FACTOR));
        vm.prank(admin);
        strategy.setHealthFactors(MIN_HEALTH_FACTOR, MIN_HEALTH_FACTOR);
    }

    /// @notice targetHealthFactor one wei above minHealthFactor is accepted.
    function test_SetHealthFactors_AcceptsTargetJustAboveMin() public {
        vm.prank(admin);
        strategy.setHealthFactors(MIN_HEALTH_FACTOR, MIN_HEALTH_FACTOR + 1);
        assertEq(strategy.targetHealthFactor(), MIN_HEALTH_FACTOR + 1, "Target health factor should be stored");
    }

    function _deployStrategy(uint256 minHealthFactor, uint256 targetHealthFactor) internal returns (WETHLoopStrategy) {
        return new WETHLoopStrategy(weth, address(vault), poolManager, aavePool, aToken, debtToken, TARGET_LEVERAGE, minHealthFactor, targetHealthFactor, EMODE_ETH_CORRELATED);
    }
}
