// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BaseStrategy} from "../../src/base/BaseStrategy.sol";

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
 * @title AccessControlTest
 * @notice Comprehensive tests for access control mechanisms in vault and strategy.
 * @dev Tests onlyVault, onlyAdmin, and onlyVaultAdmin modifiers.
 */
contract AccessControlTest is Test {
    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    MockERC20 public asset;
    YieldBearingVault public vault;
    MockStrategy public strategy;

    address public owner;
    address public admin;
    address public attacker;
    address public alice;

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
        attacker = makeAddr("attacker");
        alice = makeAddr("alice");

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

        // ============ FUND ACCOUNTS ============
        vm.startPrank(owner);
        asset.transfer(alice, DEPOSIT_AMOUNT * 10);
        asset.transfer(attacker, DEPOSIT_AMOUNT * 10);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       STRATEGY ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that only vault can call strategy.deposit().
     */
    function test_Strategy_Deposit_RevertIfNotVault() public {
        // ============ ACT & ASSERT ============
        vm.startPrank(attacker);
        asset.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.expectRevert(abi.encodeWithSignature("OnlyVault()"));
        strategy.deposit(DEPOSIT_AMOUNT, attacker);
        vm.stopPrank();
    }

    /**
     * @notice Tests that vault can successfully call strategy.deposit().
     */
    function test_Strategy_Deposit_SuccessFromVault() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        asset.transfer(address(vault), DEPOSIT_AMOUNT);

        // ============ ACT ============
        vm.startPrank(address(vault));
        asset.approve(address(strategy), DEPOSIT_AMOUNT);
        uint256 shares = strategy.deposit(DEPOSIT_AMOUNT, address(vault));
        vm.stopPrank();

        // ============ ASSERT ============
        assertGt(shares, 0, "Vault should receive shares");
        assertEq(strategy.balanceOf(address(vault)), shares, "Vault should own strategy shares");
    }

    /**
     * @notice Tests that only vault can call strategy.mint().
     */
    function test_Strategy_Mint_RevertIfNotVault() public {
        // ============ ACT & ASSERT ============
        vm.startPrank(attacker);
        asset.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.expectRevert(abi.encodeWithSignature("OnlyVault()"));
        strategy.mint(DEPOSIT_AMOUNT, attacker);
        vm.stopPrank();
    }

    /**
     * @notice Tests that only vault can call strategy.withdraw().
     */
    function test_Strategy_Withdraw_RevertIfNotVault() public {
        // ============ ARRANGE: VAULT DEPOSITS FIRST ============
        vm.prank(owner);
        asset.transfer(address(vault), DEPOSIT_AMOUNT);

        vm.startPrank(address(vault));
        asset.approve(address(strategy), DEPOSIT_AMOUNT);
        strategy.deposit(DEPOSIT_AMOUNT, address(vault));
        vm.stopPrank();

        // ============ ACT & ASSERT: ATTACKER TRIES TO WITHDRAW ============
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OnlyVault()"));
        strategy.withdraw(DEPOSIT_AMOUNT / 2, attacker, address(vault));
    }

    /**
     * @notice Tests that vault can successfully withdraw from strategy.
     */
    function test_Strategy_Withdraw_SuccessFromVault() public {
        // ============ ARRANGE: VAULT DEPOSITS ============
        vm.prank(owner);
        asset.transfer(address(vault), DEPOSIT_AMOUNT);

        vm.startPrank(address(vault));
        asset.approve(address(strategy), DEPOSIT_AMOUNT);
        strategy.deposit(DEPOSIT_AMOUNT, address(vault));

        uint256 balanceBefore = asset.balanceOf(address(vault));

        // ============ ACT: WITHDRAW ============
        uint256 shares = strategy.withdraw(DEPOSIT_AMOUNT / 2, address(vault), address(vault));
        vm.stopPrank();

        // ============ ASSERT ============
        assertGt(asset.balanceOf(address(vault)), balanceBefore, "Vault should receive assets");
    }

    /**
     * @notice Tests that only vault can call strategy.redeem().
     */
    function test_Strategy_Redeem_RevertIfNotVault() public {
        // ============ ARRANGE: VAULT DEPOSITS ============
        vm.prank(owner);
        asset.transfer(address(vault), DEPOSIT_AMOUNT);

        vm.startPrank(address(vault));
        asset.approve(address(strategy), DEPOSIT_AMOUNT);
        uint256 shares = strategy.deposit(DEPOSIT_AMOUNT, address(vault));
        vm.stopPrank();

        // ============ ACT & ASSERT: ATTACKER TRIES TO REDEEM ============
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OnlyVault()"));
        strategy.redeem(shares, attacker, address(vault));
    }

    /**
     * @notice Tests that vault can successfully redeem from strategy.
     */
    function test_Strategy_Redeem_SuccessFromVault() public {
        // ============ ARRANGE: VAULT DEPOSITS ============
        vm.prank(owner);
        asset.transfer(address(vault), DEPOSIT_AMOUNT);

        vm.startPrank(address(vault));
        asset.approve(address(strategy), DEPOSIT_AMOUNT);
        uint256 shares = strategy.deposit(DEPOSIT_AMOUNT, address(vault));

        uint256 balanceBefore = asset.balanceOf(address(vault));

        // ============ ACT: REDEEM ============
        uint256 assets = strategy.redeem(shares / 2, address(vault), address(vault));
        vm.stopPrank();

        // ============ ASSERT ============
        assertGt(assets, 0, "Should return assets");
        assertGt(asset.balanceOf(address(vault)), balanceBefore, "Vault should receive assets");
    }

    /**
     * @notice Tests that only vault can set emergency mode on strategy.
     */
    function test_Strategy_SetEmergencyMode_RevertIfNotVault() public {
        // ============ ACT & ASSERT ============
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OnlyVault()"));
        strategy.setEmergencyMode(true);
    }

    /**
     * @notice Tests that vault can set emergency mode on strategy.
     */
    function test_Strategy_SetEmergencyMode_SuccessFromVault() public {
        // ============ ACT ============
        vm.prank(address(vault));
        strategy.setEmergencyMode(true);

        // ============ ASSERT ============
        assertTrue(strategy.emergencyMode(), "Emergency mode should be activated");
    }

    /*//////////////////////////////////////////////////////////////
                    STRATEGY EMERGENCY MODE BEHAVIOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that deposits are blocked during strategy emergency mode.
     */
    function test_Strategy_EmergencyMode_BlocksDeposits() public {
        // ============ ARRANGE: ACTIVATE EMERGENCY MODE ============
        vm.prank(address(vault));
        strategy.setEmergencyMode(true);

        // ============ ACT & ASSERT: VAULT TRIES TO DEPOSIT ============
        vm.prank(owner);
        asset.transfer(address(vault), DEPOSIT_AMOUNT);

        vm.startPrank(address(vault));
        asset.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.expectRevert(abi.encodeWithSignature("StrategyInEmergency()"));
        strategy.deposit(DEPOSIT_AMOUNT, address(vault));
        vm.stopPrank();
    }

    /**
     * @notice Tests that withdrawals are allowed during strategy emergency mode.
     */
    function test_Strategy_EmergencyMode_AllowsWithdrawals() public {
        // ============ ARRANGE: DEPOSIT FIRST ============
        vm.prank(owner);
        asset.transfer(address(vault), DEPOSIT_AMOUNT);

        vm.startPrank(address(vault));
        asset.approve(address(strategy), DEPOSIT_AMOUNT);
        strategy.deposit(DEPOSIT_AMOUNT, address(vault));
        vm.stopPrank();

        // ============ ACT: ACTIVATE EMERGENCY & WITHDRAW ============
        vm.prank(address(vault));
        strategy.setEmergencyMode(true);

        uint256 balanceBefore = asset.balanceOf(address(vault));

        vm.prank(address(vault));
        strategy.withdraw(DEPOSIT_AMOUNT / 2, address(vault), address(vault));

        // ============ ASSERT ============
        assertGt(asset.balanceOf(address(vault)), balanceBefore, "Vault should receive assets during emergency");
    }

    /**
     * @notice Tests that mints are blocked during strategy emergency mode.
     */
    function test_Strategy_EmergencyMode_BlocksMints() public {
        // ============ ARRANGE: ACTIVATE EMERGENCY MODE ============
        vm.prank(address(vault));
        strategy.setEmergencyMode(true);

        // ============ ACT & ASSERT: VAULT TRIES TO MINT ============
        vm.prank(owner);
        asset.transfer(address(vault), DEPOSIT_AMOUNT);

        vm.startPrank(address(vault));
        asset.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.expectRevert(abi.encodeWithSignature("StrategyInEmergency()"));
        strategy.mint(DEPOSIT_AMOUNT, address(vault));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       VAULT ADMIN CONTROL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that non-admin cannot set strategy.
     */
    function test_Vault_SetStrategy_RevertIfNotAdmin() public {
        // ============ ARRANGE ============
        MockStrategy newStrategy = new MockStrategy(asset, address(vault));

        // ============ ACT & ASSERT ============
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin()"));
        vault.setStrategy(newStrategy);
    }

    /**
     * @notice Tests that non-admin cannot set emergency mode.
     */
    function test_Vault_SetEmergencyMode_RevertIfNotAdmin() public {
        // ============ ACT & ASSERT ============
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin()"));
        vault.setEmergencyMode(true);
    }

    /**
     * @notice Tests that non-admin cannot set protocol fee.
     */
    function test_Vault_SetProtocolFee_RevertIfNotAdmin() public {
        // ============ ACT & ASSERT ============
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin()"));
        vault.setProtocolFee(1000);
    }

    /**
     * @notice Tests that non-admin cannot set fee recipient.
     */
    function test_Vault_SetFeeRecipient_RevertIfNotAdmin() public {
        // ============ ACT & ASSERT ============
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin()"));
        vault.setFeeRecipient(attacker);
    }

    /**
     * @notice Tests that non-admin cannot change admin.
     */
    function test_Vault_SetAdmin_RevertIfNotAdmin() public {
        // ============ ACT & ASSERT ============
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin()"));
        vault.setAdmin(attacker);
    }

    /*//////////////////////////////////////////////////////////////
                       VAULT OWNER CONTROL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that non-owner cannot add to whitelist.
     */
    function test_Vault_AddToWhitelist_RevertIfNotOwner() public {
        // ============ ACT & ASSERT ============
        vm.prank(attacker);
        vm.expectRevert();
        vault.addToWhitelist(alice);
    }

    /**
     * @notice Tests that non-owner cannot remove from whitelist.
     */
    function test_Vault_RemoveFromWhitelist_RevertIfNotOwner() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        // ============ ACT & ASSERT ============
        vm.prank(attacker);
        vm.expectRevert();
        vault.removeFromWhitelist(alice);
    }

    /**
     * @notice Tests that owner can add to whitelist.
     */
    function test_Vault_AddToWhitelist_SuccessFromOwner() public {
        // ============ ACT ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        // ============ ASSERT ============
        assertTrue(vault.isWhitelisted(alice), "Alice should be whitelisted");
    }

    /**
     * @notice Tests that owner can remove from whitelist.
     */
    function test_Vault_RemoveFromWhitelist_SuccessFromOwner() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        // ============ ACT ============
        vm.prank(owner);
        vault.removeFromWhitelist(alice);

        // ============ ASSERT ============
        assertFalse(vault.isWhitelisted(alice), "Alice should not be whitelisted");
    }

    /**
     * @notice Tests that admin and owner are different roles.
     */
    function test_AdminAndOwnerAreDifferentRoles() public {
        // ============ ASSERT ============
        assertNotEq(owner, admin, "Owner and admin should be different");

        // Owner can manage whitelist
        vm.prank(owner);
        vault.addToWhitelist(alice);
        assertTrue(vault.isWhitelisted(alice));

        // Admin cannot manage whitelist
        vm.prank(admin);
        vm.expectRevert();
        vault.addToWhitelist(attacker);

        // Admin can manage strategy
        MockStrategy newStrategy = new MockStrategy(asset, address(vault));
        vm.prank(admin);
        vault.setStrategy(newStrategy);
        assertEq(address(vault.strategy()), address(newStrategy));

        // Owner cannot manage strategy
        MockStrategy anotherStrategy = new MockStrategy(asset, address(vault));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin()"));
        vault.setStrategy(anotherStrategy);
    }
}
