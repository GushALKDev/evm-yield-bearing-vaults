// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {StrategyTestBase} from "../utils/StrategyTestBase.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title MaxWithdrawFuzzBase
 * @notice withdraw(maxWithdraw(owner)) and redeem(maxRedeem(owner)) never revert, with random positions, flash loan
 *         liquidity and emergency mode (whose exit fails when the flash loan liquidity is below the debt).
 */
abstract contract MaxWithdrawFuzzBase is StrategyTestBase {
    function testFuzz_MaxWithdraw_NeverOverstates(uint256 aliceAmount, uint256 bobAmount, uint256 flashLiquidity, bool emergency) public {
        YieldBearingVault vault = _arrange(aliceAmount, bobAmount, flashLiquidity, emergency);

        uint256 max = vault.maxWithdraw(alice);
        vm.prank(alice);
        try vault.withdraw(max, alice, alice) {}
        catch (bytes memory reason) {
            fail(string.concat("withdraw(maxWithdraw) reverted: ", vm.toString(reason)));
        }
    }

    function testFuzz_MaxRedeem_NeverOverstates(uint256 aliceAmount, uint256 bobAmount, uint256 flashLiquidity, bool emergency) public {
        YieldBearingVault vault = _arrange(aliceAmount, bobAmount, flashLiquidity, emergency);

        uint256 max = vault.maxRedeem(alice);
        vm.prank(alice);
        try vault.redeem(max, alice, alice) {}
        catch (bytes memory reason) {
            fail(string.concat("redeem(maxRedeem) reverted: ", vm.toString(reason)));
        }
    }

    function _arrange(uint256 aliceAmount, uint256 bobAmount, uint256 flashLiquidity, bool emergency) internal returns (YieldBearingVault vault) {
        (vault,) = _deployWethLoop();
        _deposit(vault, alice, bound(aliceAmount, 0.01 ether, 10 ether));
        bobAmount = bound(bobAmount, 0, 10 ether);
        if (bobAmount > 0) _deposit(vault, bob, bobAmount);

        _setPoolManagerBalance(bound(flashLiquidity, 0, 200 ether));
        if (emergency) {
            vm.prank(admin);
            vault.setEmergencyMode(true);
        }
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

contract MaxWithdrawMockFuzzTest is MaxWithdrawFuzzBase {
    function _useFork() internal pure override returns (bool) {
        return false;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }
}
