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
 * @title BaseVaultTest
 * @notice Comprehensive tests for BaseVault admin functions, emergency mode, and edge cases.
 * @dev Tests admin operations, fee management, emergency circuit breaker, and error paths.
 */
contract BaseVaultTest is Test {
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
    address public feeRecipient;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 constant INITIAL_DEPOSIT = 1000;
    uint256 constant DEPOSIT_AMOUNT = 100e18;
    uint16 constant MAX_PROTOCOL_FEE_BPS = 2500;
    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // ============ CREATE TEST ADDRESSES ============
        owner = makeAddr("owner");
        admin = makeAddr("admin");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        feeRecipient = makeAddr("feeRecipient");

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
        vm.prank(owner);
        asset.transfer(alice, DEPOSIT_AMOUNT * 10);
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that admin can be changed by current admin.
     */
    function test_SetAdmin_Success() public {
        // ============ ARRANGE ============
        address newAdmin = makeAddr("newAdmin");

        // ============ ACT ============
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit AdminSet(newAdmin);
        vault.setAdmin(newAdmin);

        // ============ ASSERT ============
        assertEq(vault.admin(), newAdmin, "Admin should be updated");
    }

    /**
     * @notice Tests that only current admin can change admin.
     */
    function test_SetAdmin_RevertIfNotAdmin() public {
        // ============ ARRANGE ============
        address newAdmin = makeAddr("newAdmin");

        // ============ ACT & ASSERT ============
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin()"));
        vault.setAdmin(newAdmin);
    }

    /**
     * @notice Tests that admin cannot be set to zero address.
     */
    function test_SetAdmin_RevertIfZeroAddress() public {
        // ============ ACT & ASSERT ============
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidAdmin()"));
        vault.setAdmin(address(0));
    }

    /**
     * @notice Tests that strategy can be changed by admin.
     */
    function test_SetStrategy_Success() public {
        // ============ ARRANGE ============
        MockStrategy newStrategy = new MockStrategy(asset, address(vault));

        // ============ ACT ============
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit StrategySet(address(newStrategy));
        vault.setStrategy(newStrategy);

        // ============ ASSERT ============
        assertEq(address(vault.strategy()), address(newStrategy), "Strategy should be updated");
    }

    /**
     * @notice Tests that only admin can change strategy.
     */
    function test_SetStrategy_RevertIfNotAdmin() public {
        // ============ ARRANGE ============
        MockStrategy newStrategy = new MockStrategy(asset, address(vault));

        // ============ ACT & ASSERT ============
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin()"));
        vault.setStrategy(newStrategy);
    }

    /**
     * @notice Tests that protocol fee can be set within valid range.
     */
    function test_SetProtocolFee_Success() public {
        // ============ ARRANGE ============
        uint16 newFee = 1000; // 10%

        // ============ ACT ============
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit ProtocolFeeSet(newFee);
        vault.setProtocolFee(newFee);

        // ============ ASSERT ============
        assertEq(vault.protocolFeeBps(), newFee, "Protocol fee should be updated");
    }

    /**
     * @notice Tests that protocol fee cannot exceed maximum (25%).
     */
    function test_SetProtocolFee_RevertIfTooHigh() public {
        // ============ ARRANGE ============
        uint16 invalidFee = MAX_PROTOCOL_FEE_BPS + 1; // 25.01%

        // ============ ACT & ASSERT ============
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("ProtocolFeeTooHigh()"));
        vault.setProtocolFee(invalidFee);
    }

    /**
     * @notice Tests that only admin can set protocol fee.
     */
    function test_SetProtocolFee_RevertIfNotAdmin() public {
        // ============ ACT & ASSERT ============
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin()"));
        vault.setProtocolFee(1000);
    }

    /**
     * @notice Tests that fee recipient can be changed.
     */
    function test_SetFeeRecipient_Success() public {
        // ============ ACT ============
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit FeeRecipientSet(feeRecipient);
        vault.setFeeRecipient(feeRecipient);

        // ============ ASSERT ============
        assertEq(vault.feeRecipient(), feeRecipient, "Fee recipient should be updated");
    }

    /**
     * @notice Tests that fee recipient cannot be zero address.
     */
    function test_SetFeeRecipient_RevertIfZeroAddress() public {
        // ============ ACT & ASSERT ============
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidRecipient()"));
        vault.setFeeRecipient(address(0));
    }

    /**
     * @notice Tests that only admin can set fee recipient.
     */
    function test_SetFeeRecipient_RevertIfNotAdmin() public {
        // ============ ACT & ASSERT ============
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin()"));
        vault.setFeeRecipient(feeRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                       EMERGENCY MODE TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that emergency mode can be activated.
     */
    function test_SetEmergencyMode_Activate() public {
        // ============ ACT ============
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit EmergencyModeSet(true);
        vault.setEmergencyMode(true);

        // ============ ASSERT ============
        assertTrue(vault.emergencyMode(), "Emergency mode should be activated");
        assertTrue(strategy.emergencyMode(), "Strategy emergency mode should be activated");
    }

    /**
     * @notice Tests that emergency mode can be deactivated.
     */
    function test_SetEmergencyMode_Deactivate() public {
        // ============ ARRANGE ============
        vm.prank(admin);
        vault.setEmergencyMode(true);

        // ============ ACT ============
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit EmergencyModeSet(false);
        vault.setEmergencyMode(false);

        // ============ ASSERT ============
        assertFalse(vault.emergencyMode(), "Emergency mode should be deactivated");
        assertFalse(strategy.emergencyMode(), "Strategy emergency mode should be deactivated");
    }

    /**
     * @notice Tests that deposits are blocked during emergency mode.
     */
    function test_EmergencyMode_BlocksDeposits() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.prank(admin);
        vault.setEmergencyMode(true);

        // ============ ACT & ASSERT ============
        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vm.expectRevert(abi.encodeWithSignature("VaultInEmergency()"));
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    /**
     * @notice Tests that withdrawals are allowed during emergency mode.
     */
    function test_EmergencyMode_AllowsWithdrawals() public {
        // ============ ARRANGE: DEPOSIT FIRST ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ACT: ACTIVATE EMERGENCY & WITHDRAW ============
        vm.prank(admin);
        vault.setEmergencyMode(true);

        uint256 balanceBefore = asset.balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(DEPOSIT_AMOUNT / 2, alice, alice);

        // ============ ASSERT ============
        assertGt(asset.balanceOf(alice), balanceBefore, "Alice should receive assets");
    }

    /**
     * @notice Tests that only admin can activate emergency mode.
     */
    function test_SetEmergencyMode_RevertIfNotAdmin() public {
        // ============ ACT & ASSERT ============
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin()"));
        vault.setEmergencyMode(true);
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that constructor reverts with incorrect initial deposit.
     */
    function test_Constructor_RevertIfIncorrectInitialDeposit() public {
        // ============ ARRANGE ============
        uint256 wrongAmount = 999;

        vm.startPrank(owner);
        address vaultAddr = vm.computeCreateAddress(owner, vm.getNonce(owner));
        asset.approve(vaultAddr, wrongAmount);

        // ============ ACT & ASSERT ============
        vm.expectRevert(abi.encodeWithSignature("IncorrectInitialDeposit(uint256)", wrongAmount));
        new YieldBearingVault(asset, owner, admin, wrongAmount);
        vm.stopPrank();
    }

    /**
     * @notice Tests that initial deposit is burned to dead address.
     */
    function test_Constructor_BurnsInitialDeposit() public {
        // ============ ASSERT ============
        assertEq(vault.balanceOf(DEAD_ADDRESS), INITIAL_DEPOSIT, "Dead address should hold initial shares");
        assertEq(vault.totalSupply(), INITIAL_DEPOSIT, "Total supply should equal initial deposit");
    }

    /**
     * @notice Tests that highWaterMark is initialized correctly.
     */
    function test_Constructor_InitializesHighWaterMark() public {
        // ============ ASSERT ============
        assertEq(vault.highWaterMark(), INITIAL_DEPOSIT, "High water mark should equal initial deposit");
    }

    /*//////////////////////////////////////////////////////////////
                       HIGH WATER MARK TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that high water mark increases with deposits.
     */
    function test_HighWaterMark_IncreasesWithDeposits() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        uint256 hwmBefore = vault.highWaterMark();

        // ============ ACT ============
        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ASSERT ============
        assertEq(vault.highWaterMark(), hwmBefore + DEPOSIT_AMOUNT, "HWM should increase by deposit amount");
    }

    /**
     * @notice Tests that high water mark decreases with withdrawals.
     */
    function test_HighWaterMark_DecreasesWithWithdrawals() public {
        // ============ ARRANGE: DEPOSIT ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        uint256 hwmBefore = vault.highWaterMark();
        uint256 withdrawAmount = DEPOSIT_AMOUNT / 2;

        // ============ ACT: WITHDRAW ============
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        // ============ ASSERT ============
        assertEq(vault.highWaterMark(), hwmBefore - withdrawAmount, "HWM should decrease by withdraw amount");
    }

    /**
     * @notice Tests that high water mark handles full withdrawal correctly.
     */
    function test_HighWaterMark_FullWithdrawal() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 hwmBefore = vault.highWaterMark();

        // ============ ACT: FULL REDEEM ============
        vault.redeem(vault.balanceOf(alice), alice, alice);
        vm.stopPrank();

        // ============ ASSERT ============
        // HWM should decrease by amount withdrawn, back to initial deposit
        assertEq(vault.highWaterMark(), INITIAL_DEPOSIT, "HWM should return to initial deposit");
        assertLt(vault.highWaterMark(), hwmBefore, "HWM should have decreased");
    }

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event AdminSet(address indexed newAdmin);
    event StrategySet(address indexed strategy);
    event EmergencyModeSet(bool isOpen);
    event ProtocolFeeSet(uint16 feeBps);
    event FeeRecipientSet(address indexed recipient);
    event PerformanceFeePaid(uint256 profit, uint256 feeShares);
}
