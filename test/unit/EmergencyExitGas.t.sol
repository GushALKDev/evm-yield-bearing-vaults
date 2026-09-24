// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {BaseStrategy} from "../../src/base/BaseStrategy.sol";
import {StrategyTestBase} from "../utils/StrategyTestBase.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title EmergencyExitGasTestBase
 * @notice A caller must not be able to activate emergency mode with the position still open by sending just enough
 *         gas for the outer call to succeed while exitPosition() runs out of gas inside the try/catch.
 */
abstract contract EmergencyExitGasTestBase is StrategyTestBase {
    uint256 internal constant SWEEP_FROM = 100_000;
    uint256 internal constant SWEEP_TO = 1_200_000;
    uint256 internal constant SWEEP_STEP = 2_500;

    /// @notice No gas limit makes checkHealth() succeed with emergency mode active and debt left.
    function test_CheckHealth_NoGasLimitLeavesPositionOpen() public {
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        _makeUnhealthy(strategy);

        for (uint256 gasLimit = SWEEP_FROM; gasLimit <= SWEEP_TO; gasLimit += SWEEP_STEP) {
            uint256 snapshot = vm.snapshotState();
            (bool success,) = address(strategy).call{gas: gasLimit}(abi.encodeCall(strategy.checkHealth, ()));
            _assertNotOpenInEmergency(vault, strategy, success, gasLimit);
            vm.revertToState(snapshot);
        }
    }

    /// @notice No gas limit makes the admin activation succeed with emergency mode active and debt left.
    function test_AdminEmergency_NoGasLimitLeavesPositionOpen() public {
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);

        for (uint256 gasLimit = SWEEP_FROM; gasLimit <= SWEEP_TO; gasLimit += SWEEP_STEP) {
            uint256 snapshot = vm.snapshotState();
            vm.prank(admin);
            (bool success,) = address(vault).call{gas: gasLimit}(abi.encodeCall(vault.setEmergencyMode, (true)));
            _assertNotOpenInEmergency(vault, strategy, success, gasLimit);
            vm.revertToState(snapshot);
        }
    }

    /// @notice Below the exit gas, checkHealth() reverts instead of activating emergency mode.
    function test_CheckHealth_RevertsWithInsufficientGas() public {
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        _makeUnhealthy(strategy);
        uint256 gasLimit = strategy.EXIT_GAS();

        vm.expectPartialRevert(BaseStrategy.InsufficientGasForExit.selector);
        strategy.checkHealth{gas: gasLimit}();

        assertFalse(vault.emergencyMode(), "Emergency mode should stay off");
    }

    /// @notice Below the exit gas, the admin activation reverts instead of activating emergency mode.
    function test_AdminEmergency_RevertsWithInsufficientGas() public {
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        uint256 gasLimit = strategy.EXIT_GAS();

        vm.prank(admin);
        vm.expectPartialRevert(BaseStrategy.InsufficientGasForExit.selector);
        vault.setEmergencyMode{gas: gasLimit}(true);

        assertFalse(vault.emergencyMode(), "Emergency mode should stay off");
    }

    /// @notice With enough gas the exit completes.
    function test_CheckHealth_EnoughGasClosesPosition() public {
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        _makeUnhealthy(strategy);

        strategy.checkHealth{gas: 1_000_000}();

        assertTrue(vault.emergencyMode(), "Emergency mode should be active");
        assertEq(IERC20(debtToken).balanceOf(address(strategy)), 0, "The position should be closed");
    }

    /// @notice An exit that fails for a reason other than gas still activates emergency mode and emits EmergencyExitFailed.
    function test_CheckHealth_GenuineExitFailureStillActivates() public {
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        _makeUnhealthy(strategy);
        _setPoolManagerBalance(0);

        vm.expectEmit(false, false, false, false, address(strategy));
        emit BaseStrategy.EmergencyExitFailed("");
        strategy.checkHealth{gas: 1_000_000}();

        assertTrue(vault.emergencyMode(), "Emergency mode should be active");
        assertGt(IERC20(debtToken).balanceOf(address(strategy)), 0, "The position stays open without flash liquidity");
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

    function _assertNotOpenInEmergency(YieldBearingVault vault, WETHLoopStrategy strategy, bool success, uint256 gasLimit) internal view {
        if (!success) return;
        bool openInEmergency = vault.emergencyMode() && IERC20(debtToken).balanceOf(address(strategy)) > 0;
        assertFalse(openInEmergency, string.concat("Emergency active with the position open at gas limit ", vm.toString(gasLimit)));
    }
}

contract EmergencyExitGasMockTest is EmergencyExitGasTestBase {
    function _useFork() internal pure override returns (bool) {
        return false;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }
}
