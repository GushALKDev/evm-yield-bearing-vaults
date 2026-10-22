// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {VaultDeployer} from "../utils/VaultDeployer.sol";

/**
 * @title DonationHighWaterMarkTest
 * @notice Regression tests for the donation report in issue #1: a direct transfer to the vault, a fee assessment
 *         and the donor's exit leave the high-water mark stuck above totalAssets(). A donation can only leave the
 *         vault through withdraw/redeem, which lower the high-water mark by the same assets, and the fee shares go
 *         to the fee recipient, so the donor loses at least the fee and later yield still pays it.
 */
contract DonationHighWaterMarkTest is Test {
    uint256 internal constant INITIAL_DEPOSIT = 1000;
    uint16 internal constant FEE_BPS = 2500;
    uint16 internal constant MAX_BPS = 10_000;
    uint256 internal constant DONATION = 1_000_000 ether;
    uint256 internal constant YIELD = 10 ether;
    uint256 internal constant DUST = 10;

    MockWETH internal asset;
    YieldBearingVault internal vault;
    MockStrategy internal strategy;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        asset = new MockWETH();
        asset.mint(owner, INITIAL_DEPOSIT);
        vm.startPrank(owner);
        VaultDeployer vaultDeployer = new VaultDeployer();
        asset.approve(address(vaultDeployer), INITIAL_DEPOSIT);
        vault = vaultDeployer.deploy(IERC20(address(asset)), owner, admin, INITIAL_DEPOSIT);
        vault.addToWhitelist(alice);
        vault.addToWhitelist(attacker);
        vault.addToWhitelist(feeRecipient);
        vm.stopPrank();

        strategy = new MockStrategy(IERC20(address(asset)), address(vault));
        vm.startPrank(admin);
        vault.setStrategy(strategy);
        vault.setFeeRecipient(feeRecipient);
        vault.setProtocolFee(FEE_BPS);
        vm.stopPrank();

        // The attacker already holds half of the shares, so it gets back as much of the donation as it can
        _deposit(alice, 100 ether);
        _deposit(attacker, 100 ether);
    }

    /// @notice The donor's exit lowers the high-water mark with totalAssets(), and the donor loses at least the fee.
    function test_Donation_DonorExitLeavesNoHighWaterMarkGap() public {
        // ============ ARRANGE ============
        asset.mint(attacker, DONATION + 1 ether);
        uint256 attackerValueBefore = asset.balanceOf(attacker) + vault.previewRedeem(vault.balanceOf(attacker));

        // ============ ACT ============
        _donateTriggerAndExit();

        // ============ ASSERT ============
        assertApproxEqAbs(vault.highWaterMark(), vault.totalAssets(), DUST, "High-water mark should follow totalAssets()");
        assertEq(vault.balanceOf(attacker), 0, "Attacker should have exited");
        uint256 attackerLoss = attackerValueBefore - asset.balanceOf(attacker);
        assertGe(attackerLoss, DONATION * FEE_BPS / MAX_BPS, "Attacker should lose at least the fee on the donation");
        uint256 feeValue = vault.previewRedeem(vault.balanceOf(feeRecipient));
        assertApproxEqRel(feeValue, DONATION * FEE_BPS / MAX_BPS, 1e12, "Fee shares should go to the fee recipient");
    }

    /// @notice Yield earned after the donor's exit still pays the performance fee.
    function test_Donation_LaterYieldStillPaysFee() public {
        // ============ ARRANGE ============
        asset.mint(attacker, DONATION + 1 ether);
        _donateTriggerAndExit();
        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        // ============ ACT ============
        asset.mint(address(strategy), YIELD);
        vault.assessPerformanceFee();

        // ============ ASSERT ============
        uint256 newFeeValue = vault.previewRedeem(vault.balanceOf(feeRecipient) - feeSharesBefore);
        assertApproxEqRel(newFeeValue, YIELD * FEE_BPS / MAX_BPS, 1e12, "Later yield should pay the fee");
    }

    /**
     * @dev The steps of the report: a direct transfer, a deposit that assesses the fee, and a full redeem as the
     *      only way to take assets back out of the vault.
     */
    function _donateTriggerAndExit() internal {
        vm.startPrank(attacker);
        asset.transfer(address(vault), DONATION);
        asset.approve(address(vault), 1 ether);
        vault.deposit(1 ether, attacker);
        vault.redeem(vault.balanceOf(attacker), attacker, attacker);
        vm.stopPrank();
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        asset.mint(user, amount);
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }
}
