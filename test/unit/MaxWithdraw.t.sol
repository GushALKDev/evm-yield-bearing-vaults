// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {AaveSimpleLendingStrategy} from "../../src/strategies/AaveSimpleLendingStrategy.sol";
import {StrategyTestBase} from "../utils/StrategyTestBase.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title MaxWithdrawTestBase
 * @notice maxWithdraw() and maxRedeem() never exceed what withdraw() and redeem() accept for the owner, in normal and
 *         emergency mode, including the flash loan liquidity the proportional deleverage needs.
 */
abstract contract MaxWithdrawTestBase is StrategyTestBase {
    /// @notice Normal mode with enough liquidity: the owner can withdraw everything.
    function test_MaxWithdraw_Normal_FullAmount() public {
        (YieldBearingVault vault,) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);

        uint256 max = vault.maxWithdraw(alice);
        assertApproxEqAbs(max, vault.previewRedeem(vault.balanceOf(alice)), 1, "maxWithdraw should cover the owner's assets");
        _withdraw(vault, alice, max);
    }

    /// @notice Normal mode with enough liquidity: the owner can redeem every share.
    function test_MaxRedeem_Normal_AllShares() public {
        (YieldBearingVault vault,) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);

        uint256 max = vault.maxRedeem(alice);
        assertEq(max, vault.balanceOf(alice), "maxRedeem should cover every share");
        _redeem(vault, alice, max);
    }

    /// @notice The proportional deleverage borrows debt * assets / equity: the flash loan liquidity caps the withdrawal.
    function test_MaxWithdraw_LimitedByFlashLiquidity() public {
        (YieldBearingVault vault,) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        _deposit(vault, bob, 1 ether);
        _setPoolManagerBalance(2 ether);

        uint256 max = vault.maxWithdraw(alice);
        uint256 ownerAssets = vault.previewRedeem(vault.balanceOf(alice));
        assertLt(max, ownerAssets, "Flash loan liquidity should cap the limit");
        _expectWithdrawRevert(vault, alice, ownerAssets);
        _withdraw(vault, alice, max);
    }

    /// @notice Same cap for redeem.
    function test_MaxRedeem_LimitedByFlashLiquidity() public {
        (YieldBearingVault vault,) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        _deposit(vault, bob, 1 ether);
        _setPoolManagerBalance(2 ether);

        uint256 max = vault.maxRedeem(alice);
        assertLt(max, vault.balanceOf(alice), "Flash loan liquidity should cap the limit");
        _redeem(vault, alice, max);
    }

    /// @notice Emergency mode with a failed exit: withdrawals deleverage proportionally, capped by flash liquidity.
    function test_MaxWithdraw_EmergencyExitFailed() public {
        (YieldBearingVault vault,) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        _deposit(vault, bob, 1 ether);
        _setPoolManagerBalance(0);
        vm.prank(admin);
        vault.setEmergencyMode(true);
        _setPoolManagerBalance(2 ether);

        uint256 max = vault.maxWithdraw(alice);
        assertLt(max, vault.previewRedeem(vault.balanceOf(alice)), "Flash loan liquidity should cap the limit");
        _withdraw(vault, alice, max);

        uint256 maxShares = vault.maxRedeem(bob);
        assertLt(maxShares, vault.balanceOf(bob), "Flash loan liquidity should cap the limit");
        _redeem(vault, bob, maxShares);
    }

    /// @notice Emergency mode after a successful exit: the position is idle WETH and fully withdrawable.
    function test_MaxWithdraw_EmergencyExitClosed() public {
        (YieldBearingVault vault,) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        vm.prank(admin);
        vault.setEmergencyMode(true);
        _setPoolManagerBalance(0);

        uint256 max = vault.maxWithdraw(alice);
        assertApproxEqAbs(max, vault.previewRedeem(vault.balanceOf(alice)), 1, "Idle WETH needs no flash loan");
        _withdraw(vault, alice, max);
    }

    /// @notice Without flash loan liquidity only idle assets can be paid out.
    function test_MaxWithdraw_NoFlashLiquidity() public {
        (YieldBearingVault vault,) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        _setPoolManagerBalance(0);

        uint256 max = vault.maxWithdraw(alice);
        assertEq(max, weth.balanceOf(address(vault)), "Only the vault's idle balance can be paid");
        _withdraw(vault, alice, max);
    }

    function _withdraw(YieldBearingVault vault, address user, uint256 assets) internal {
        vm.prank(user);
        vault.withdraw(assets, user, user);
    }

    function _redeem(YieldBearingVault vault, address user, uint256 shares) internal {
        vm.prank(user);
        vault.redeem(shares, user, user);
    }

    function _expectWithdrawRevert(YieldBearingVault vault, address user, uint256 assets) internal {
        vm.prank(user);
        vm.expectRevert();
        vault.withdraw(assets, user, user);
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

contract MaxWithdrawMockTest is MaxWithdrawTestBase {
    function _useFork() internal pure override returns (bool) {
        return false;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }

    /// @notice Aave's available liquidity caps the collateral that can be withdrawn.
    function test_MaxWithdraw_LimitedByAaveLiquidity() public {
        (YieldBearingVault vault,) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        mockWeth.burn(aavePool, weth.balanceOf(aavePool) - 0.1 ether);

        uint256 max = vault.maxWithdraw(alice);
        uint256 ownerAssets = vault.previewRedeem(vault.balanceOf(alice));
        assertLt(max, ownerAssets, "Aave liquidity should cap the limit");
        _expectWithdrawRevert(vault, alice, ownerAssets);
        _withdraw(vault, alice, max);
    }

    /// @notice A paused reserve blocks withdrawals from Aave: only idle assets remain withdrawable.
    function test_MaxWithdraw_ReservePaused() public {
        (YieldBearingVault vault,) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        mockPool.setReservePaused(true);

        uint256 max = vault.maxWithdraw(alice);
        assertEq(max, weth.balanceOf(address(vault)), "Only the vault's idle balance can be paid");
        _expectWithdrawRevert(vault, alice, max + 1);
        _withdraw(vault, alice, max);
    }

    /// @notice With the health factor below 1 Aave rejects collateral withdrawals: only idle assets count.
    function test_MaxWithdraw_HealthFactorBelowOne() public {
        (YieldBearingVault vault,) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        // 10 * 0.80 / 9 = 0.889
        mockPool.setLiquidationThreshold(8000);

        assertEq(vault.maxWithdraw(alice), weth.balanceOf(address(vault)), "Only the vault's idle balance can be paid");
    }

    /// @notice The Aave simple strategy is capped by Aave's available liquidity.
    function test_AaveSimple_MaxWithdraw_LimitedByAaveLiquidity() public {
        (YieldBearingVault vault,) = _deployAaveSimple();
        _deposit(vault, alice, 1 ether);
        mockWeth.burn(aavePool, weth.balanceOf(aavePool) - 0.1 ether);

        uint256 max = vault.maxWithdraw(alice);
        uint256 ownerAssets = vault.previewRedeem(vault.balanceOf(alice));
        assertLt(max, ownerAssets, "Aave liquidity should cap the limit");
        _expectWithdrawRevert(vault, alice, ownerAssets);
        _withdraw(vault, alice, max);
    }

    /// @notice The Aave simple strategy pays only idle assets while the reserve is paused.
    function test_AaveSimple_MaxWithdraw_ReservePaused() public {
        (YieldBearingVault vault, AaveSimpleLendingStrategy strategy) = _deployAaveSimple();
        _deposit(vault, alice, 1 ether);
        mockPool.setReservePaused(true);

        uint256 max = vault.maxWithdraw(alice);
        assertEq(max, weth.balanceOf(address(vault)) + weth.balanceOf(address(strategy)), "Only idle assets can be paid");
        _withdraw(vault, alice, max);
    }
}
