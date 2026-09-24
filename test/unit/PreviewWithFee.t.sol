// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {VaultDeployer} from "../utils/VaultDeployer.sol";

/**
 * @title PreviewWithFeeTestBase
 * @notice ERC-4626 previews and conversions account for the pending performance fee exactly as deposit, mint,
 *         withdraw and redeem charge it before pricing.
 */
abstract contract PreviewWithFeeTestBase is Test {
    uint256 internal constant INITIAL_DEPOSIT = 1000;

    MockWETH internal asset;
    YieldBearingVault internal vault;
    MockStrategy internal strategy;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _setUpVault(uint16 feeBps) internal {
        asset = new MockWETH();
        asset.mint(owner, INITIAL_DEPOSIT);
        vm.startPrank(owner);
        VaultDeployer vaultDeployer = new VaultDeployer();
        asset.approve(address(vaultDeployer), INITIAL_DEPOSIT);
        vault = vaultDeployer.deploy(IERC20(address(asset)), owner, admin, INITIAL_DEPOSIT);
        vault.addToWhitelist(alice);
        vault.addToWhitelist(bob);
        vault.addToWhitelist(feeRecipient);
        vm.stopPrank();

        strategy = new MockStrategy(IERC20(address(asset)), address(vault));
        vm.startPrank(admin);
        vault.setStrategy(strategy);
        vault.setFeeRecipient(feeRecipient);
        vault.setProtocolFee(feeBps);
        vm.stopPrank();
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        asset.mint(user, amount);
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev Yield sent to the strategy raises totalAssets above the high-water mark: a fee is pending.
    function _addProfit(uint256 amount) internal {
        asset.mint(address(strategy), amount);
    }

    function _checkDeposit(uint256 amount) internal {
        uint256 preview = vault.previewDeposit(amount);
        uint256 shares = _deposit(bob, amount);
        assertEq(shares, preview, "previewDeposit must equal deposit");
    }

    function _checkMint(uint256 shares) internal {
        uint256 preview = vault.previewMint(shares);
        asset.mint(bob, preview);
        vm.startPrank(bob);
        asset.approve(address(vault), preview);
        uint256 assets = vault.mint(shares, bob);
        vm.stopPrank();
        assertEq(assets, preview, "previewMint must equal mint");
    }

    function _checkWithdraw(uint256 assets) internal {
        uint256 preview = vault.previewWithdraw(assets);
        vm.prank(alice);
        uint256 shares = vault.withdraw(assets, alice, alice);
        assertEq(shares, preview, "previewWithdraw must equal withdraw");
    }

    function _checkRedeem(uint256 shares) internal {
        uint256 preview = vault.previewRedeem(shares);
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertEq(assets, preview, "previewRedeem must equal redeem");
    }
}

contract PreviewWithFeeTest is PreviewWithFeeTestBase {
    function setUp() public {
        _setUpVault(1000);
        _deposit(alice, 100 ether);
    }

    function test_PreviewDeposit_NoPendingFee() public {
        _checkDeposit(10 ether);
    }

    function test_PreviewDeposit_PendingFee() public {
        _addProfit(10 ether);
        _checkDeposit(10 ether);
    }

    function test_PreviewMint_NoPendingFee() public {
        _checkMint(10 ether);
    }

    function test_PreviewMint_PendingFee() public {
        _addProfit(10 ether);
        _checkMint(10 ether);
    }

    function test_PreviewWithdraw_NoPendingFee() public {
        _checkWithdraw(10 ether);
    }

    function test_PreviewWithdraw_PendingFee() public {
        _addProfit(10 ether);
        _checkWithdraw(10 ether);
    }

    function test_PreviewRedeem_NoPendingFee() public {
        _checkRedeem(10 ether);
    }

    function test_PreviewRedeem_PendingFee() public {
        _addProfit(10 ether);
        _checkRedeem(10 ether);
    }

    /// @notice Crystallizing the pending fee does not change conversions, since they already account for it.
    function test_Conversions_UnchangedByFeeAssessment() public {
        // ============ ARRANGE ============
        _addProfit(10 ether);
        uint256 assetsBefore = vault.convertToAssets(10 ether);
        uint256 sharesBefore = vault.convertToShares(10 ether);
        uint256 totalAssetsBefore = vault.totalAssets();

        // ============ ACT ============
        vault.assessPerformanceFee();

        // ============ ASSERT ============
        assertGt(vault.balanceOf(feeRecipient), 0, "The fee should be minted");
        assertEq(vault.convertToAssets(10 ether), assetsBefore, "convertToAssets should not change");
        assertEq(vault.convertToShares(10 ether), sharesBefore, "convertToShares should not change");
        assertEq(vault.totalAssets(), totalAssetsBefore, "totalAssets should not change");
    }
}
