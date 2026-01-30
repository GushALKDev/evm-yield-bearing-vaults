// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {AaveSimpleLendingStrategy} from "../../src/strategies/AaveSimpleLendingStrategy.sol";
import {Constants} from "../../src/utils/Constants.sol";

/**
 * @title AaveSimpleStrategyFuzzTest
 * @notice Stateless fuzzing tests for AaveSimpleLendingStrategy.
 * @dev Tests deposit/withdraw flows with randomized amounts on forked mainnet.
 *      Requires ETHEREUM_MAINNET_RPC environment variable.
 */
contract AaveSimpleStrategyFuzzTest is Test {
    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    YieldBearingVault vault;
    AaveSimpleLendingStrategy strategy;
    IERC20 usdc;
    IERC20 aUsdc;

    address alice;
    address owner;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address constant USDC = Constants.ETHEREUM_MAINNET_USDC;
    address constant AAVE_POOL = Constants.ETHEREUM_MAINNET_AAVE_V3_POOL;
    address constant A_USDC = Constants.ETHEREUM_MAINNET_AAVE_V3_USDC_ATOKEN;
    uint256 constant REQUIRED_DEPOSIT = 1000;
    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        alice = makeAddr("alice");
        owner = makeAddr("owner");

        vm.createSelectFork(vm.envString("ETHEREUM_MAINNET_RPC"));

        usdc = IERC20(USDC);
        aUsdc = IERC20(A_USDC);

        deal(USDC, owner, 1_000_000e6);

        vm.startPrank(owner);

        address vaultAddr = vm.computeCreateAddress(owner, vm.getNonce(owner));
        usdc.approve(vaultAddr, REQUIRED_DEPOSIT);
        vault = new YieldBearingVault(usdc, owner, owner, REQUIRED_DEPOSIT);

        strategy = new AaveSimpleLendingStrategy(usdc, address(vault), AAVE_POOL, A_USDC);

        vault.setStrategy(strategy);
        vault.addToWhitelist(alice);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       DEPOSIT FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes deposit amounts ensuring correct Aave investment.
     * @param depositAmount Random deposit between 100 and 100,000 USDC.
     */
    function testFuzz_Deposit_InvestsInAave(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 100e6, 100_000e6);

        deal(USDC, alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256 vaultBalance = vault.totalAssets();
        assertApproxEqAbs(vaultBalance, depositAmount + REQUIRED_DEPOSIT, 2, "Vault total assets should match");

        assertEq(usdc.balanceOf(address(vault)), REQUIRED_DEPOSIT, "Vault should hold buffer");
        assertEq(usdc.balanceOf(address(strategy)), 0, "Strategy should hold 0 underlying");

        assertEq(
            vault.totalSupply(),
            vault.balanceOf(alice) + vault.balanceOf(DEAD_ADDRESS),
            "Vault supply invariant"
        );
        assertEq(strategy.totalSupply(), strategy.balanceOf(address(vault)), "Strategy supply invariant");
    }

    /**
     * @notice Fuzzes multiple sequential deposits.
     * @param deposit1 First deposit (100-50,000 USDC).
     * @param deposit2 Second deposit (100-50,000 USDC).
     */
    function testFuzz_Deposit_MultipleSequential(uint256 deposit1, uint256 deposit2) public {
        deposit1 = bound(deposit1, 100e6, 50_000e6);
        deposit2 = bound(deposit2, 100e6, 50_000e6);

        deal(USDC, alice, deposit1 + deposit2);

        vm.startPrank(alice);
        usdc.approve(address(vault), deposit1 + deposit2);

        vault.deposit(deposit1, alice);
        uint256 assetsAfterFirst = vault.totalAssets();

        vault.deposit(deposit2, alice);
        uint256 assetsAfterSecond = vault.totalAssets();

        vm.stopPrank();

        assertApproxEqAbs(assetsAfterFirst, deposit1 + REQUIRED_DEPOSIT, 10, "First deposit assets");
        assertApproxEqAbs(assetsAfterSecond, deposit1 + deposit2 + REQUIRED_DEPOSIT, 10, "Second deposit assets");
    }

    /**
     * @notice Fuzzes deposits from multiple users.
     * @param userCount Number of users (2-5).
     * @param baseDeposit Base deposit per user (1,000-10,000 USDC).
     */
    function testFuzz_Deposit_MultipleUsers(uint8 userCount, uint256 baseDeposit) public {
        userCount = uint8(bound(userCount, 2, 5));
        baseDeposit = bound(baseDeposit, 1_000e6, 10_000e6);

        uint256 totalDeposits = 0;

        for (uint256 i = 0; i < userCount; i++) {
            address user = makeAddr(string(abi.encodePacked("user", i)));

            vm.prank(owner);
            vault.addToWhitelist(user);

            deal(USDC, user, baseDeposit);

            vm.startPrank(user);
            usdc.approve(address(vault), baseDeposit);
            vault.deposit(baseDeposit, user);
            vm.stopPrank();

            totalDeposits += baseDeposit;
        }

        assertApproxEqAbs(
            vault.totalAssets(), totalDeposits + REQUIRED_DEPOSIT, uint256(userCount) * 2, "Total deposits match"
        );
    }

    /*//////////////////////////////////////////////////////////////
                      WITHDRAWAL FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes partial withdrawals.
     * @param depositAmount Initial deposit (1,000-100,000 USDC).
     * @param withdrawRatio Percentage to withdraw (10-90%).
     */
    function testFuzz_Withdraw_PartialAmount(uint256 depositAmount, uint8 withdrawRatio) public {
        depositAmount = bound(depositAmount, 1_000e6, 100_000e6);
        withdrawRatio = uint8(bound(withdrawRatio, 10, 90));

        deal(USDC, alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        uint256 withdrawAmount = (depositAmount * withdrawRatio) / 100;
        uint256 balanceBefore = usdc.balanceOf(alice);

        vault.withdraw(withdrawAmount, alice, alice);

        uint256 balanceAfter = usdc.balanceOf(alice);
        vm.stopPrank();

        assertEq(balanceAfter - balanceBefore, withdrawAmount, "Should receive exact withdrawal amount");

        assertEq(usdc.balanceOf(address(vault)), 0, "Vault should use buffer");
        assertEq(usdc.balanceOf(address(strategy)), 0, "Strategy should hold 0 underlying");
    }

    /**
     * @notice Fuzzes full redemption (all shares).
     * @param depositAmount Random deposit amount (1,000-100,000 USDC).
     */
    function testFuzz_Redeem_FullAmount(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1_000e6, 100_000e6);

        deal(USDC, alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);

        uint256 balanceBefore = usdc.balanceOf(alice);
        vault.redeem(shares, alice, alice);
        uint256 balanceAfter = usdc.balanceOf(alice);

        vm.stopPrank();

        assertApproxEqAbs(balanceAfter - balanceBefore, depositAmount, 10, "Should receive full deposit back");
        assertEq(vault.balanceOf(alice), 0, "Alice should have no shares left");
    }

    /**
     * @notice Fuzzes interleaved deposit and withdrawal operations.
     * @param deposit1 First deposit (1,000-50,000 USDC).
     * @param withdrawRatio Withdrawal percentage (20-50%).
     * @param deposit2 Second deposit (1,000-50,000 USDC).
     */
    function testFuzz_InterleavedOperations(uint256 deposit1, uint8 withdrawRatio, uint256 deposit2) public {
        deposit1 = bound(deposit1, 1_000e6, 50_000e6);
        withdrawRatio = uint8(bound(withdrawRatio, 20, 50));
        deposit2 = bound(deposit2, 1_000e6, 50_000e6);

        deal(USDC, alice, deposit1 + deposit2);

        vm.startPrank(alice);
        usdc.approve(address(vault), deposit1 + deposit2);

        vault.deposit(deposit1, alice);

        uint256 withdrawAmount = (deposit1 * withdrawRatio) / 100;
        vault.withdraw(withdrawAmount, alice, alice);

        vault.deposit(deposit2, alice);

        vm.stopPrank();

        uint256 expectedMinAssets = deposit1 - withdrawAmount + deposit2;
        assertGe(vault.totalAssets(), expectedMinAssets, "Total assets should reflect operations");
    }

    /*//////////////////////////////////////////////////////////////
                        YIELD FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes yield accrual with random time periods.
     * @param depositAmount Random deposit (5,000-100,000 USDC).
     * @param daysElapsed Random days elapsed (1-30).
     */
    function testFuzz_Yield_AccruesOverTime(uint256 depositAmount, uint16 daysElapsed) public {
        depositAmount = bound(depositAmount, 5_000e6, 100_000e6);
        daysElapsed = uint16(bound(daysElapsed, 1, 30));

        deal(USDC, alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256 assetsBefore = strategy.totalAssets();

        uint256 blocksToAdvance = uint256(daysElapsed) * 7200;
        uint256 timeToAdvance = uint256(daysElapsed) * 1 days;
        vm.roll(block.number + blocksToAdvance);
        vm.warp(block.timestamp + timeToAdvance);

        uint256 assetsAfter = strategy.totalAssets();

        assertGt(assetsAfter, assetsBefore, "Should have earned yield");

        uint256 yieldGenerated = assetsAfter - assetsBefore;
        console.log("Days Elapsed:", daysElapsed);
        console.log("Yield Generated:", yieldGenerated);
    }

    /**
     * @notice Fuzzes withdrawal after yield accrual.
     * @param depositAmount Random deposit (5,000-50,000 USDC).
     * @param daysElapsed Random days (1-10).
     * @param withdrawRatio Random withdrawal percentage (30-70%).
     */
    function testFuzz_Yield_WithdrawAfterYield(uint256 depositAmount, uint8 daysElapsed, uint8 withdrawRatio) public {
        depositAmount = bound(depositAmount, 5_000e6, 50_000e6);
        daysElapsed = uint8(bound(daysElapsed, 1, 10));
        withdrawRatio = uint8(bound(withdrawRatio, 30, 70));

        deal(USDC, alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256 blocksToAdvance = uint256(daysElapsed) * 7200;
        uint256 timeToAdvance = uint256(daysElapsed) * 1 days;
        vm.roll(block.number + blocksToAdvance);
        vm.warp(block.timestamp + timeToAdvance);

        uint256 withdrawAmount = (depositAmount * withdrawRatio) / 100;
        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        uint256 balanceAfter = usdc.balanceOf(alice);

        assertEq(balanceAfter - balanceBefore, withdrawAmount, "Should receive withdrawal amount");

        uint256 remainingShares = vault.balanceOf(alice);
        assertGt(remainingShares, 0, "Should have remaining shares");
    }

    /**
     * @notice Fuzzes share price increase with yield.
     * @param depositAmount Random deposit (10,000-100,000 USDC).
     * @param daysElapsed Random days (1-30).
     */
    function testFuzz_Yield_SharePriceIncreases(uint256 depositAmount, uint8 daysElapsed) public {
        depositAmount = bound(depositAmount, 10_000e6, 100_000e6);
        daysElapsed = uint8(bound(daysElapsed, 1, 30));

        deal(USDC, alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256 sharePriceBefore = vault.convertToAssets(1e18);

        uint256 blocksToAdvance = uint256(daysElapsed) * 7200;
        uint256 timeToAdvance = uint256(daysElapsed) * 1 days;
        vm.roll(block.number + blocksToAdvance);
        vm.warp(block.timestamp + timeToAdvance);

        uint256 sharePriceAfter = vault.convertToAssets(1e18);

        assertGt(sharePriceAfter, sharePriceBefore, "Share price should increase with yield");
    }

    /*//////////////////////////////////////////////////////////////
                      INVARIANT FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes total supply invariant.
     * @param depositAmount Random deposit amount.
     */
    function testFuzz_Invariant_TotalSupply(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1_000e6, 100_000e6);

        deal(USDC, alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        assertEq(
            vault.totalSupply(),
            vault.balanceOf(alice) + vault.balanceOf(DEAD_ADDRESS),
            "Vault total supply invariant"
        );
        assertEq(strategy.totalSupply(), strategy.balanceOf(address(vault)), "Strategy total supply invariant");
    }

    /**
     * @notice Fuzzes vault-strategy asset consistency.
     * @param depositAmount Random deposit amount.
     */
    function testFuzz_Invariant_VaultStrategyConsistency(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1_000e6, 100_000e6);

        deal(USDC, alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256 vaultAssets = vault.totalAssets();
        uint256 strategyAssets = strategy.totalAssets();

        assertApproxEqAbs(
            vaultAssets, strategyAssets + REQUIRED_DEPOSIT, 2, "Vault assets should equal strategy + buffer"
        );
    }

    /**
     * @notice Fuzzes physical balance invariant.
     * @param depositAmount Random deposit amount.
     */
    function testFuzz_Invariant_PhysicalBalances(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1_000e6, 100_000e6);

        deal(USDC, alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), REQUIRED_DEPOSIT, "Vault should hold only buffer");
        assertEq(usdc.balanceOf(address(strategy)), 0, "Strategy should hold 0 underlying");

        uint256 aUsdcBalance = aUsdc.balanceOf(address(strategy));
        assertGt(aUsdcBalance, 0, "Strategy should hold aUSDC");
    }

    /*//////////////////////////////////////////////////////////////
                      SHARE CONVERSION FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes share to asset conversions.
     * @param depositAmount Random deposit amount.
     * @param sharesToConvertRatio Percentage of shares to convert (1-100%).
     */
    function testFuzz_ShareConversion_Consistency(uint256 depositAmount, uint8 sharesToConvertRatio) public {
        depositAmount = bound(depositAmount, 1_000e6, 100_000e6);
        sharesToConvertRatio = uint8(bound(sharesToConvertRatio, 1, 100));

        deal(USDC, alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256 sharesToConvert = (shares * sharesToConvertRatio) / 100;

        uint256 assets = vault.convertToAssets(sharesToConvert);
        uint256 reconvertedShares = vault.convertToShares(assets);

        assertApproxEqAbs(reconvertedShares, sharesToConvert, 10, "Conversion should be reversible");
    }

    /**
     * @notice Fuzzes preview functions match actual operations.
     * @param depositAmount Random deposit amount.
     */
    function testFuzz_Preview_MatchesActual(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1_000e6, 100_000e6);

        deal(USDC, alice, depositAmount);

        uint256 previewedShares = vault.previewDeposit(depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        uint256 actualShares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        assertEq(actualShares, previewedShares, "Preview should match actual deposit");
    }

    /**
     * @notice Fuzzes preview withdraw matches actual.
     * @param depositAmount Random deposit amount.
     * @param withdrawRatio Percentage to withdraw.
     */
    function testFuzz_PreviewWithdraw_MatchesActual(uint256 depositAmount, uint8 withdrawRatio) public {
        depositAmount = bound(depositAmount, 5_000e6, 100_000e6);
        withdrawRatio = uint8(bound(withdrawRatio, 20, 80));

        deal(USDC, alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256 withdrawAmount = (depositAmount * withdrawRatio) / 100;
        uint256 previewedShares = vault.previewWithdraw(withdrawAmount);

        vm.prank(alice);
        uint256 actualShares = vault.withdraw(withdrawAmount, alice, alice);

        assertApproxEqAbs(actualShares, previewedShares, 10, "Preview withdraw should match actual");
    }
}
