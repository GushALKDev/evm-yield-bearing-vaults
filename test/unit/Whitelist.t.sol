// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice Simple ERC20 token for testing.
 */
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/**
 * @title WhitelistTest
 * @notice Comprehensive tests for whitelist functionality.
 * @dev Tests whitelist enforcement on deposits, transfers, mints, and redemptions.
 */
contract WhitelistTest is Test {
    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    MockERC20 public asset;
    YieldBearingVault public vault;
    MockStrategy public strategy;

    address public owner;
    address public admin;
    address public alice;
    address public bob;
    address public charlie;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 constant INITIAL_DEPOSIT = 1000;
    uint256 constant DEPOSIT_AMOUNT = 100e18;

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // ============ CREATE TEST ADDRESSES ============
        owner = makeAddr("owner");
        admin = makeAddr("admin");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        vm.startPrank(owner);

        // ============ DEPLOY MOCK ASSET ============
        asset = new MockERC20();

        // ============ DEPLOY VAULT ============
        address vaultAddr = vm.computeCreateAddress(owner, vm.getNonce(owner));
        asset.approve(vaultAddr, INITIAL_DEPOSIT);
        vault = new YieldBearingVault(asset, owner, admin, INITIAL_DEPOSIT);

        // ============ DEPLOY & CONNECT STRATEGY ============
        strategy = new MockStrategy(asset, address(vault));
        vm.stopPrank();

        vm.prank(admin);
        vault.setStrategy(strategy);

        // ============ FUND TEST ACCOUNTS ============
        vm.startPrank(owner);
        asset.transfer(alice, DEPOSIT_AMOUNT * 5);
        asset.transfer(bob, DEPOSIT_AMOUNT * 5);
        asset.transfer(charlie, DEPOSIT_AMOUNT * 5);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       WHITELIST MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that owner can add address to whitelist.
     */
    function test_AddToWhitelist_Success() public {
        // ============ ACT ============
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit WhitelistedAdded(alice);
        vault.addToWhitelist(alice);

        // ============ ASSERT ============
        assertTrue(vault.isWhitelisted(alice), "Alice should be whitelisted");
    }

    /**
     * @notice Tests that only owner can add to whitelist.
     */
    function test_AddToWhitelist_RevertIfNotOwner() public {
        // ============ ACT & ASSERT ============
        vm.prank(alice);
        vm.expectRevert();
        vault.addToWhitelist(bob);
    }

    /**
     * @notice Tests that owner can remove address from whitelist.
     */
    function test_RemoveFromWhitelist_Success() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        // ============ ACT ============
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit WhitelistedRemoved(alice);
        vault.removeFromWhitelist(alice);

        // ============ ASSERT ============
        assertFalse(vault.isWhitelisted(alice), "Alice should not be whitelisted");
    }

    /**
     * @notice Tests that only owner can remove from whitelist.
     */
    function test_RemoveFromWhitelist_RevertIfNotOwner() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        // ============ ACT & ASSERT ============
        vm.prank(alice);
        vm.expectRevert();
        vault.removeFromWhitelist(alice);
    }

    /**
     * @notice Tests that multiple addresses can be whitelisted.
     */
    function test_AddMultipleToWhitelist() public {
        // ============ ACT ============
        vm.startPrank(owner);
        vault.addToWhitelist(alice);
        vault.addToWhitelist(bob);
        vault.addToWhitelist(charlie);
        vm.stopPrank();

        // ============ ASSERT ============
        assertTrue(vault.isWhitelisted(alice), "Alice should be whitelisted");
        assertTrue(vault.isWhitelisted(bob), "Bob should be whitelisted");
        assertTrue(vault.isWhitelisted(charlie), "Charlie should be whitelisted");
    }

    /*//////////////////////////////////////////////////////////////
                       DEPOSIT ENFORCEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that whitelisted user can deposit.
     */
    function test_Deposit_SuccessIfWhitelisted() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        // ============ ACT ============
        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ASSERT ============
        assertGt(shares, 0, "Alice should receive shares");
        assertEq(vault.balanceOf(alice), shares, "Alice should own the shares");
    }

    /**
     * @notice Tests that non-whitelisted user cannot deposit.
     */
    function test_Deposit_RevertIfNotWhitelisted() public {
        // ============ ACT & ASSERT ============
        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vm.expectRevert(abi.encodeWithSignature("NotWhitelisted(address)", alice));
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    /**
     * @notice Tests that mint reverts for non-whitelisted receiver.
     */
    function test_Mint_RevertIfNotWhitelisted() public {
        // ============ ACT & ASSERT ============
        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vm.expectRevert(abi.encodeWithSignature("NotWhitelisted(address)", alice));
        vault.mint(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    /**
     * @notice Tests that whitelisted user can mint shares.
     */
    function test_Mint_SuccessIfWhitelisted() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        // ============ ACT ============
        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 assets = vault.mint(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ASSERT ============
        assertGt(assets, 0, "Should require assets");
        assertEq(vault.balanceOf(alice), DEPOSIT_AMOUNT, "Alice should have shares");
    }

    /*//////////////////////////////////////////////////////////////
                       TRANSFER ENFORCEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that shares can be transferred to whitelisted address.
     */
    function test_Transfer_SuccessToWhitelisted() public {
        // ============ ARRANGE: ALICE DEPOSITS ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ACT: WHITELIST BOB & TRANSFER ============
        vm.prank(owner);
        vault.addToWhitelist(bob);

        vm.prank(alice);
        vault.transfer(bob, shares / 2);

        // ============ ASSERT ============
        assertEq(vault.balanceOf(bob), shares / 2, "Bob should receive shares");
        assertEq(vault.balanceOf(alice), shares / 2, "Alice should retain half");
    }

    /**
     * @notice Tests that shares cannot be transferred to non-whitelisted address.
     */
    function test_Transfer_RevertToNonWhitelisted() public {
        // ============ ARRANGE: ALICE DEPOSITS ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ACT & ASSERT: TRANSFER TO BOB FAILS ============
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotWhitelisted(address)", bob));
        vault.transfer(bob, shares / 2);
    }

    /**
     * @notice Tests that transferFrom enforces whitelist for recipient.
     */
    function test_TransferFrom_RevertToNonWhitelisted() public {
        // ============ ARRANGE: ALICE DEPOSITS & APPROVES ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vault.approve(bob, shares);
        vm.stopPrank();

        // ============ ACT & ASSERT: BOB TRIES TO TRANSFER TO CHARLIE ============
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NotWhitelisted(address)", charlie));
        vault.transferFrom(alice, charlie, shares / 2);
    }

    /**
     * @notice Tests that transferFrom succeeds when recipient is whitelisted.
     */
    function test_TransferFrom_SuccessToWhitelisted() public {
        // ============ ARRANGE: ALICE DEPOSITS & APPROVES ============
        vm.startPrank(owner);
        vault.addToWhitelist(alice);
        vault.addToWhitelist(charlie);
        vm.stopPrank();

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vault.approve(bob, shares);
        vm.stopPrank();

        // ============ ACT: BOB TRANSFERS ALICE'S SHARES TO CHARLIE ============
        vm.prank(bob);
        vault.transferFrom(alice, charlie, shares / 2);

        // ============ ASSERT ============
        assertEq(vault.balanceOf(charlie), shares / 2, "Charlie should receive shares");
        assertEq(vault.balanceOf(alice), shares / 2, "Alice should retain half");
    }

    /*//////////////////////////////////////////////////////////////
                       WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that removed user can still withdraw their funds.
     */
    function test_Withdraw_AllowedAfterRemovalFromWhitelist() public {
        // ============ ARRANGE: ALICE DEPOSITS ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ACT: REMOVE ALICE FROM WHITELIST ============
        vm.prank(owner);
        vault.removeFromWhitelist(alice);

        // ============ ASSERT: ALICE CAN STILL WITHDRAW ============
        uint256 balanceBefore = asset.balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(DEPOSIT_AMOUNT / 2, alice, alice);

        assertGt(asset.balanceOf(alice), balanceBefore, "Alice should receive assets despite being removed");
    }

    /**
     * @notice Tests that removed user cannot deposit again.
     */
    function test_Deposit_BlockedAfterRemovalFromWhitelist() public {
        // ============ ARRANGE: ALICE DEPOSITS ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT * 2);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ACT: REMOVE ALICE FROM WHITELIST ============
        vm.prank(owner);
        vault.removeFromWhitelist(alice);

        // ============ ASSERT: ALICE CANNOT DEPOSIT ============
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotWhitelisted(address)", alice));
        vault.deposit(DEPOSIT_AMOUNT, alice);
    }

    /**
     * @notice Tests that whitelisted user can withdraw to self.
     */
    function test_Withdraw_SuccessIfWhitelisted() public {
        // ============ ARRANGE: ALICE DEPOSITS ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 balanceBefore = asset.balanceOf(alice);

        // ============ ACT: WITHDRAW ============
        vault.withdraw(DEPOSIT_AMOUNT / 2, alice, alice);
        vm.stopPrank();

        // ============ ASSERT ============
        assertGt(asset.balanceOf(alice), balanceBefore, "Alice should receive assets");
    }

    /**
     * @notice Tests that user can redeem shares.
     */
    function test_Redeem_Success() public {
        // ============ ARRANGE: ALICE DEPOSITS ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 balanceBefore = asset.balanceOf(alice);

        // ============ ACT: REDEEM ============
        vault.redeem(shares / 2, alice, alice);
        vm.stopPrank();

        // ============ ASSERT ============
        assertGt(asset.balanceOf(alice), balanceBefore, "Alice should receive assets");
        assertEq(vault.balanceOf(alice), shares / 2, "Alice should have half shares left");
    }

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event WhitelistedAdded(address indexed account);
    event WhitelistedRemoved(address indexed account);
}
