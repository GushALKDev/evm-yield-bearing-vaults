// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 1_000_000_000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title BaseVaultFuzzTest
 * @notice Stateless fuzzing tests for BaseVault functionality.
 * @dev Tests vault operations with randomized inputs to discover edge cases.
 */
contract BaseVaultFuzzTest is Test {

    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    MockERC20 public asset;
    YieldBearingVault public vault;
    MockStrategy public strategy;

    address public owner;
    address public admin;
    address public feeRecipient;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 constant INITIAL_DEPOSIT = 1000;
    uint16 constant MAX_PROTOCOL_FEE_BPS = 2500;
    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        owner = makeAddr("owner");
        admin = makeAddr("admin");
        feeRecipient = makeAddr("feeRecipient");

        vm.startPrank(owner);
        asset = new MockERC20();

        address vaultAddr = vm.computeCreateAddress(owner, vm.getNonce(owner));
        asset.approve(vaultAddr, INITIAL_DEPOSIT);
        vault = new YieldBearingVault(asset, owner, admin, INITIAL_DEPOSIT);

        strategy = new MockStrategy(asset, address(vault));
        vm.stopPrank();

        vm.prank(admin);
        vault.setStrategy(strategy);

        vm.prank(admin);
        vault.setFeeRecipient(feeRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                         DEPOSIT FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes deposit amounts to ensure correctness across all valid inputs.
     * @param depositAmount Random deposit amount between 1 wei and 1M tokens.
     */
    function testFuzz_Deposit_CorrectShareCalculation(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, 1_000_000e18);

        address user = makeAddr("user");
        vm.prank(owner);
        vault.addToWhitelist(user);

        asset.mint(user, depositAmount);

        vm.startPrank(user);
        asset.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user);
        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares");
        assertEq(vault.balanceOf(user), shares, "User should own shares");
        assertGe(vault.totalAssets(), depositAmount + INITIAL_DEPOSIT, "Total assets should include deposit");
    }

    /**
     * @notice Fuzzes multiple sequential deposits from same user.
     * @param deposit1 First deposit amount.
     * @param deposit2 Second deposit amount.
     */
    function testFuzz_Deposit_MultipleDeposits(uint256 deposit1, uint256 deposit2) public {
        deposit1 = bound(deposit1, 1, 1_000_000e18);
        deposit2 = bound(deposit2, 1, 1_000_000e18);

        address user = makeAddr("user");
        vm.prank(owner);
        vault.addToWhitelist(user);

        asset.mint(user, deposit1 + deposit2);

        vm.startPrank(user);
        asset.approve(address(vault), deposit1 + deposit2);

        uint256 shares1 = vault.deposit(deposit1, user);
        uint256 shares2 = vault.deposit(deposit2, user);
        vm.stopPrank();

        assertEq(vault.balanceOf(user), shares1 + shares2, "Total shares should be sum");
        assertGe(vault.totalAssets(), deposit1 + deposit2 + INITIAL_DEPOSIT, "Total assets should include both deposits");
    }

    /**
     * @notice Fuzzes deposits from multiple users.
     * @param userCount Number of users (2-10).
     * @param depositAmount Base deposit amount.
     */
    function testFuzz_Deposit_MultipleUsers(uint8 userCount, uint256 depositAmount) public {
        userCount = uint8(bound(userCount, 2, 10));
        depositAmount = bound(depositAmount, 100, 100_000e18);

        uint256 totalDeposits = 0;

        for (uint256 i = 0; i < userCount; i++) {
            address user = makeAddr(string(abi.encodePacked("user", i)));

            vm.prank(owner);
            vault.addToWhitelist(user);

            asset.mint(user, depositAmount);

            vm.startPrank(user);
            asset.approve(address(vault), depositAmount);
            vault.deposit(depositAmount, user);
            vm.stopPrank();

            totalDeposits += depositAmount;
        }

        assertGe(vault.totalAssets(), totalDeposits + INITIAL_DEPOSIT, "Total assets should match all deposits");
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAW FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes withdrawal amounts ensuring users can always withdraw their funds.
     * @param depositAmount Initial deposit.
     * @param withdrawAmount Amount to withdraw.
     */
    function testFuzz_Withdraw_PartialWithdrawal(uint256 depositAmount, uint256 withdrawAmount) public {
        depositAmount = bound(depositAmount, 1000, 1_000_000e18);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);

        address user = makeAddr("user");
        vm.prank(owner);
        vault.addToWhitelist(user);

        asset.mint(user, depositAmount);

        vm.startPrank(user);
        asset.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);

        uint256 balanceBefore = asset.balanceOf(user);
        vault.withdraw(withdrawAmount, user, user);
        uint256 balanceAfter = asset.balanceOf(user);
        vm.stopPrank();

        assertEq(balanceAfter - balanceBefore, withdrawAmount, "User should receive exact withdrawal amount");
    }

    /**
     * @notice Fuzzes full withdrawal (redeem all shares).
     * @param depositAmount Random deposit amount.
     */
    function testFuzz_Redeem_FullWithdrawal(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1000, 1_000_000e18);

        address user = makeAddr("user");
        vm.prank(owner);
        vault.addToWhitelist(user);

        asset.mint(user, depositAmount);

        vm.startPrank(user);
        asset.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user);

        uint256 assets = vault.redeem(shares, user, user);
        vm.stopPrank();

        assertApproxEqAbs(assets, depositAmount, 10, "Should receive approximately deposit amount");
        assertEq(vault.balanceOf(user), 0, "User should have no shares left");
    }

    /**
     * @notice Fuzzes interleaved deposits and withdrawals.
     * @param deposit1 First deposit.
     * @param withdraw1 First withdrawal.
     * @param deposit2 Second deposit.
     */
    function testFuzz_InterleavedDepositWithdraw(uint256 deposit1, uint256 withdraw1, uint256 deposit2) public {
        deposit1 = bound(deposit1, 1000, 100_000e18);
        withdraw1 = bound(withdraw1, 1, deposit1 / 2);
        deposit2 = bound(deposit2, 1000, 100_000e18);

        address user = makeAddr("user");
        vm.prank(owner);
        vault.addToWhitelist(user);

        asset.mint(user, deposit1 + deposit2);

        vm.startPrank(user);
        asset.approve(address(vault), deposit1 + deposit2);

        vault.deposit(deposit1, user);
        vault.withdraw(withdraw1, user, user);
        vault.deposit(deposit2, user);

        vm.stopPrank();

        uint256 expectedMinAssets = deposit1 - withdraw1 + deposit2;
        assertGe(vault.totalAssets(), expectedMinAssets, "Total assets should reflect operations");
    }

    /*//////////////////////////////////////////////////////////////
                      FEE MANAGEMENT FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes protocol fee values to ensure they're correctly bounded.
     * @param feeBps Fee in basis points.
     */
    function testFuzz_SetProtocolFee_ValidRange(uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 0, MAX_PROTOCOL_FEE_BPS));

        vm.prank(admin);
        vault.setProtocolFee(feeBps);

        assertEq(vault.protocolFeeBps(), feeBps, "Fee should be set correctly");
    }

    /**
     * @notice Fuzzes invalid protocol fees (above max).
     * @param feeBps Fee in basis points above maximum.
     */
    function testFuzz_SetProtocolFee_RevertIfTooHigh(uint16 feeBps) public {
        vm.assume(feeBps > MAX_PROTOCOL_FEE_BPS);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("ProtocolFeeTooHigh()"));
        vault.setProtocolFee(feeBps);
    }

    /**
     * @notice Fuzzes high water mark updates across random deposit/withdraw sequences.
     * @param deposit Random deposit amount.
     * @param withdrawRatio Percentage to withdraw (0-100).
     */
    function testFuzz_HighWaterMark_UpdatesCorrectly(uint256 deposit, uint8 withdrawRatio) public {
        deposit = bound(deposit, 1000, 1_000_000e18);
        withdrawRatio = uint8(bound(withdrawRatio, 0, 99));

        address user = makeAddr("user");
        vm.prank(owner);
        vault.addToWhitelist(user);

        asset.mint(user, deposit);

        vm.startPrank(user);
        asset.approve(address(vault), deposit);
        vault.deposit(deposit, user);

        uint256 hwmAfterDeposit = vault.highWaterMark();
        assertEq(hwmAfterDeposit, INITIAL_DEPOSIT + deposit, "HWM should increase by deposit");

        uint256 withdrawAmount = (deposit * withdrawRatio) / 100;
        if (withdrawAmount > 0) {
            vault.withdraw(withdrawAmount, user, user);

            uint256 hwmAfterWithdraw = vault.highWaterMark();
            assertEq(hwmAfterWithdraw, hwmAfterDeposit - withdrawAmount, "HWM should decrease by withdrawal");
        }

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                     EMERGENCY MODE FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes emergency mode activation with deposits.
     * @param depositAmount Deposit before emergency.
     */
    function testFuzz_EmergencyMode_BlocksDeposits(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1000, 1_000_000e18);

        address user = makeAddr("user");
        vm.prank(owner);
        vault.addToWhitelist(user);

        vm.prank(admin);
        vault.setEmergencyMode(true);

        asset.mint(user, depositAmount);

        vm.startPrank(user);
        asset.approve(address(vault), depositAmount);
        vm.expectRevert(abi.encodeWithSignature("VaultInEmergency()"));
        vault.deposit(depositAmount, user);
        vm.stopPrank();
    }

    /**
     * @notice Fuzzes withdrawals during emergency mode.
     * @param depositAmount Initial deposit.
     * @param withdrawRatio Percentage to withdraw.
     */
    function testFuzz_EmergencyMode_AllowsWithdrawals(uint256 depositAmount, uint8 withdrawRatio) public {
        depositAmount = bound(depositAmount, 1000, 1_000_000e18);
        withdrawRatio = uint8(bound(withdrawRatio, 1, 100));

        address user = makeAddr("user");
        vm.prank(owner);
        vault.addToWhitelist(user);

        asset.mint(user, depositAmount);

        vm.startPrank(user);
        asset.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        vm.prank(admin);
        vault.setEmergencyMode(true);

        uint256 withdrawAmount = (depositAmount * withdrawRatio) / 100;
        uint256 balanceBefore = asset.balanceOf(user);

        vm.prank(user);
        vault.withdraw(withdrawAmount, user, user);

        assertGt(asset.balanceOf(user), balanceBefore, "User should receive assets during emergency");
    }

    /*//////////////////////////////////////////////////////////////
                      SHARE CONVERSION FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes share to asset conversions.
     * @param shares Random share amount.
     */
    function testFuzz_ConvertToAssets_Consistency(uint256 shares) public {
        shares = bound(shares, 1, vault.totalSupply());

        uint256 assets = vault.convertToAssets(shares);
        uint256 reconvertedShares = vault.convertToShares(assets);

        assertApproxEqAbs(reconvertedShares, shares, 1, "Conversion should be reversible");
    }

    /**
     * @notice Fuzzes preview functions match actual operations.
     * @param depositAmount Random deposit amount.
     */
    function testFuzz_PreviewFunctions_MatchActual(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1000, 1_000_000e18);

        address user = makeAddr("user");
        vm.prank(owner);
        vault.addToWhitelist(user);

        asset.mint(user, depositAmount);

        uint256 previewedShares = vault.previewDeposit(depositAmount);

        vm.startPrank(user);
        asset.approve(address(vault), depositAmount);
        uint256 actualShares = vault.deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(actualShares, previewedShares, "Preview should match actual deposit");
    }

    /*//////////////////////////////////////////////////////////////
                        INVARIANT FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes total supply invariant across operations.
     * @param operation Random operation (0=deposit, 1=withdraw).
     * @param amount Random amount.
     */
    function testFuzz_Invariant_TotalSupply(uint8 operation, uint256 amount) public {
        amount = bound(amount, 1000, 100_000e18);

        address user = makeAddr("user");
        vm.prank(owner);
        vault.addToWhitelist(user);

        asset.mint(user, amount);

        if (operation % 2 == 0) {
            vm.startPrank(user);
            asset.approve(address(vault), amount);
            vault.deposit(amount, user);
            vm.stopPrank();
        } else {
            vm.startPrank(user);
            asset.approve(address(vault), amount);
            vault.deposit(amount, user);

            uint256 withdrawAmount = amount / 2;
            vault.withdraw(withdrawAmount, user, user);
            vm.stopPrank();
        }

        assertEq(
            vault.totalSupply(),
            vault.balanceOf(user) + vault.balanceOf(DEAD_ADDRESS),
            "Total supply should equal user + dead shares"
        );
    }

    /**
     * @notice Fuzzes vault-strategy asset consistency.
     * @param depositAmount Random deposit amount.
     */
    function testFuzz_Invariant_VaultStrategyConsistency(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1000, 1_000_000e18);

        address user = makeAddr("user");
        vm.prank(owner);
        vault.addToWhitelist(user);

        asset.mint(user, depositAmount);

        vm.startPrank(user);
        asset.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 vaultAssets = vault.totalAssets();
        uint256 strategyAssets = strategy.totalAssets();

        assertApproxEqAbs(
            vaultAssets,
            strategyAssets + INITIAL_DEPOSIT,
            10,
            "Vault assets should equal strategy assets + buffer"
        );
    }
}
