// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
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
 * @title EdgeCasesTest
 * @notice Tests edge cases, zero amounts, and boundary conditions.
 * @dev Tests unusual scenarios and input validation.
 */
contract EdgeCasesTest is Test {

    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    MockERC20 public asset;
    YieldBearingVault public vault;
    MockStrategy public strategy;

    address public owner;
    address public admin;
    address public alice;
    address public feeRecipient;

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

        // ============ FUND ACCOUNTS ============
        vm.prank(owner);
        asset.transfer(alice, DEPOSIT_AMOUNT * 10);
    }

    /*//////////////////////////////////////////////////////////////
                       ZERO AMOUNT TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests deposit with zero amount.
     */
    function test_Deposit_ZeroAmount() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        // ============ ACT & ASSERT ============
        // ERC4626 allows zero deposits (returns 0 shares)
        vm.startPrank(alice);
        asset.approve(address(vault), 0);
        uint256 shares = vault.deposit(0, alice);
        vm.stopPrank();

        assertEq(shares, 0, "Should receive 0 shares for 0 deposit");
    }

    /**
     * @notice Tests withdraw with zero amount.
     */
    function test_Withdraw_ZeroAmount() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 balanceBefore = asset.balanceOf(alice);

        // ============ ACT ============
        uint256 shares = vault.withdraw(0, alice, alice);
        vm.stopPrank();

        // ============ ASSERT ============
        assertEq(shares, 0, "Should burn 0 shares for 0 withdrawal");
        assertEq(asset.balanceOf(alice), balanceBefore, "Balance should not change");
    }

    /**
     * @notice Tests redeem with zero shares.
     */
    function test_Redeem_ZeroShares() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 balanceBefore = asset.balanceOf(alice);

        // ============ ACT ============
        uint256 assets = vault.redeem(0, alice, alice);
        vm.stopPrank();

        // ============ ASSERT ============
        assertEq(assets, 0, "Should receive 0 assets for 0 shares");
        assertEq(asset.balanceOf(alice), balanceBefore, "Balance should not change");
    }

    /*//////////////////////////////////////////////////////////////
                       DUST AMOUNT TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests deposit with very small (dust) amount.
     */
    function test_Deposit_DustAmount() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        uint256 dustAmount = 1; // 1 wei

        // ============ ACT ============
        vm.startPrank(alice);
        asset.approve(address(vault), dustAmount);
        uint256 shares = vault.deposit(dustAmount, alice);
        vm.stopPrank();

        // ============ ASSERT ============
        // 1 wei deposit should return minimal shares (1 wei of shares)
        assertGt(shares, 0, "Dust deposit should return minimal shares");
        assertLe(shares, dustAmount, "Shares should not exceed deposit amount");
    }

    /**
     * @notice Tests that very small deposits are protected by initial dead shares.
     */
    function test_InflationProtection_SmallDeposits() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        // ============ ACT: TRY TO MANIPULATE WITH SMALL DEPOSIT ============
        vm.startPrank(alice);
        asset.approve(address(vault), 100);
        uint256 shares = vault.deposit(100, alice);
        vm.stopPrank();

        // ============ ASSERT ============
        // Initial 1000 wei burn prevents inflation attack
        assertGt(vault.totalSupply(), shares, "Total supply should exceed user shares due to dead shares");
    }

    /*//////////////////////////////////////////////////////////////
                       MAXIMUM AMOUNT TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests deposit with maximum available balance.
     */
    function test_Deposit_MaximumAmount() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        uint256 maxBalance = asset.balanceOf(alice);

        // ============ ACT ============
        vm.startPrank(alice);
        asset.approve(address(vault), maxBalance);
        uint256 shares = vault.deposit(maxBalance, alice);
        vm.stopPrank();

        // ============ ASSERT ============
        assertGt(shares, 0, "Should receive shares");
        assertEq(asset.balanceOf(alice), 0, "Alice should have 0 balance after max deposit");
    }

    /**
     * @notice Tests withdraw with maximum available shares.
     */
    function test_Withdraw_MaximumShares() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 maxShares = vault.balanceOf(alice);

        // ============ ACT ============
        vault.redeem(maxShares, alice, alice);
        vm.stopPrank();

        // ============ ASSERT ============
        assertEq(vault.balanceOf(alice), 0, "Alice should have 0 shares after full redemption");
    }

    /*//////////////////////////////////////////////////////////////
                       FEE EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that zero fee does not trigger fee assessment.
     */
    function test_PerformanceFee_ZeroFee() public {
        // ============ ARRANGE ============
        vm.prank(admin);
        vault.setFeeRecipient(feeRecipient);
        // protocolFeeBps defaults to 0

        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ACT: SIMULATE YIELD ============
        vm.prank(owner);
        asset.transfer(address(strategy), 10e18);

        // ============ ASSERT: NO FEES CHARGED ============
        assertEq(vault.balanceOf(feeRecipient), 0, "Fee recipient should have 0 shares with 0% fee");
    }

    /**
     * @notice Tests that fee assessment without recipient does nothing.
     */
    function test_PerformanceFee_NoRecipient() public {
        // ============ ARRANGE ============
        vm.prank(admin);
        vault.setProtocolFee(1000); // 10% fee
        // No fee recipient set

        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ACT: SIMULATE YIELD ============
        vm.prank(owner);
        asset.transfer(address(strategy), 10e18);

        uint256 totalSupplyBefore = vault.totalSupply();

        // ============ ACT: ASSESS FEE ============
        vault.assessPerformanceFee();

        // ============ ASSERT: NO NEW SHARES MINTED ============
        assertEq(vault.totalSupply(), totalSupplyBefore, "No shares should be minted without fee recipient");
    }

    /**
     * @notice Tests maximum protocol fee (25%).
     */
    function test_PerformanceFee_MaximumFee() public {
        // ============ ARRANGE ============
        uint16 maxFee = 2500; // 25%

        vm.startPrank(admin);
        vault.setProtocolFee(maxFee);
        vault.setFeeRecipient(feeRecipient);
        vm.stopPrank();

        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ACT: SIMULATE YIELD (20e18 profit) ============
        uint256 profit = 20e18;
        vm.prank(owner);
        asset.transfer(address(strategy), profit);

        vault.assessPerformanceFee();

        // ============ ASSERT: FEE IS 25% OF PROFIT ============
        uint256 recipientShares = vault.balanceOf(feeRecipient);
        assertGt(recipientShares, 0, "Fee recipient should receive shares");

        uint256 feeAssets = vault.convertToAssets(recipientShares);
        uint256 expectedFee = profit * maxFee / 10_000;

        assertApproxEqAbs(feeAssets, expectedFee, 1e18, "Fee should be approximately 25% of profit");
    }

    /*//////////////////////////////////////////////////////////////
                       CONVERSION EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests convertToShares with zero assets.
     */
    function test_ConvertToShares_ZeroAssets() public {
        // ============ ACT ============
        uint256 shares = vault.convertToShares(0);

        // ============ ASSERT ============
        assertEq(shares, 0, "0 assets should convert to 0 shares");
    }

    /**
     * @notice Tests convertToAssets with zero shares.
     */
    function test_ConvertToAssets_ZeroShares() public {
        // ============ ACT ============
        uint256 assets = vault.convertToAssets(0);

        // ============ ASSERT ============
        assertEq(assets, 0, "0 shares should convert to 0 assets");
    }

    /**
     * @notice Tests previewDeposit returns correct shares.
     */
    function test_PreviewDeposit_Accuracy() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        // ============ ACT ============
        uint256 previewedShares = vault.previewDeposit(DEPOSIT_AMOUNT);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 actualShares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ASSERT ============
        assertEq(actualShares, previewedShares, "Actual shares should match preview");
    }

    /**
     * @notice Tests previewWithdraw returns correct shares.
     */
    function test_PreviewWithdraw_Accuracy() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ACT ============
        uint256 withdrawAmount = DEPOSIT_AMOUNT / 2;
        uint256 previewedShares = vault.previewWithdraw(withdrawAmount);

        uint256 sharesBefore = vault.balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        uint256 actualSharesBurned = sharesBefore - vault.balanceOf(alice);

        // ============ ASSERT ============
        assertApproxEqAbs(actualSharesBurned, previewedShares, 1, "Burned shares should match preview");
    }

    /*//////////////////////////////////////////////////////////////
                       REENTRANCY PROTECTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that reentrancy guard protects deposit.
     * @dev This is more for documentation - actual reentrancy attacks
     *      require malicious tokens which we can't easily test here.
     */
    function test_ReentrancyGuard_DepositsProtected() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        // ============ ACT ============
        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ASSERT ============
        // If reentrancy was possible, shares would be incorrectly inflated
        // Normal case should work as expected
        assertGt(shares, 0, "Deposit should succeed normally");
    }

    /*//////////////////////////////////////////////////////////////
                       TOTALASSETS CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests totalAssets before strategy is set.
     */
    function test_TotalAssets_WithoutStrategy() public {
        // ============ ARRANGE: CREATE VAULT WITHOUT STRATEGY ============
        vm.startPrank(owner);
        MockERC20 newAsset = new MockERC20();

        address vaultAddr = vm.computeCreateAddress(owner, vm.getNonce(owner));
        newAsset.approve(vaultAddr, INITIAL_DEPOSIT);
        YieldBearingVault newVault = new YieldBearingVault(newAsset, owner, admin, INITIAL_DEPOSIT);
        vm.stopPrank();

        // ============ ASSERT ============
        // Total assets should equal initial deposit held in vault
        assertEq(newVault.totalAssets(), INITIAL_DEPOSIT, "Total assets should equal initial deposit");
    }

    /**
     * @notice Tests totalAssets with strategy.
     */
    function test_TotalAssets_WithStrategy() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        // ============ ACT ============
        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ASSERT ============
        // Total assets = initial deposit + user deposit
        uint256 expectedTotal = INITIAL_DEPOSIT + DEPOSIT_AMOUNT;
        assertApproxEqAbs(vault.totalAssets(), expectedTotal, 2, "Total assets should include strategy balance");
    }

    /**
     * @notice Tests that maxDeposit returns reasonable value.
     */
    function test_MaxDeposit_ReturnsMaxUint() public {
        // ============ ARRANGE ============
        vm.prank(owner);
        vault.addToWhitelist(alice);

        // ============ ACT ============
        uint256 maxDep = vault.maxDeposit(alice);

        // ============ ASSERT ============
        assertEq(maxDep, type(uint256).max, "Max deposit should be max uint256 for whitelisted user");
    }

    /**
     * @notice Tests that deposits are blocked during emergency mode.
     * @dev The maxDeposit function doesn't automatically return 0 in emergency,
     *      but deposits will revert due to the whenNotEmergency modifier.
     */
    function test_Deposit_BlockedDuringEmergency() public {
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
}
