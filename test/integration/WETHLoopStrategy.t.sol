// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "../../src/interfaces/aave/IPool.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";

/**
 * @title WETHLoopStrategyTest
 * @notice Fork tests for the WETH leveraged loop strategy.
 * @dev Tests leverage mechanics using Aave V3 E-Mode and Uniswap V4 flash loans.
 *      Requires ETHEREUM_MAINNET_RPC environment variable to be set.
 *
 *      Strategy Flow:
 *      1. User deposits WETH to strategy
 *      2. Strategy takes flash loan from Uniswap V4
 *      3. Supplies principal + flash loan to Aave as collateral
 *      4. Borrows from Aave to repay flash loan
 *      5. Result: Leveraged position with 10x exposure
 */
contract WETHLoopStrategyTest is Test {
    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    WETHLoopStrategy strategy;
    IERC20 weth;
    address vault;
    address resolvedPool;

    address vaultOwner;
    address vaultAdmin;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /** @notice WETH token address on Ethereum Mainnet. */
    address constant WETH_MAINNET = Constants.ETHEREUM_MAINNET_WETH;

    /** @notice Aave V3 Pool address on Ethereum Mainnet. */
    address constant AAVE_V3_POOL = Constants.ETHEREUM_MAINNET_AAVE_V3_POOL;

    /** @notice aWETH token address (Aave interest-bearing WETH). */
    address constant AWETH_TOKEN = Constants.ETHEREUM_MAINNET_AAVE_V3_WETH_ATOKEN;

    /** @notice Variable debt WETH token address. */
    address constant VARIABLE_DEBT_WETH = Constants.ETHEREUM_MAINNET_AAVE_V3_WETH_VARIABLE_DEBT;

    /** @notice Uniswap V4 PoolManager for flash loans. */
    address constant UNISWAP_V4_POOL_MANAGER = Constants.UNISWAP_V4_POOL_MANAGER;

    /** @notice Aave V3 Pool Address Provider. */
    address constant AAVE_ADDRESS_PROVIDER = Constants.ETHEREUM_MAINNET_AAVE_V3_ADDRESS_PROVIDER;

    /** @notice Required initial deposit for vault (inflation protection). */
    uint256 constant INITIAL_DEPOSIT = 1000;

    /** @notice Target leverage for the strategy (10x). */
    uint8 constant TARGET_LEVERAGE = 10;

    /** @notice Minimum health factor threshold (1.02). */
    uint256 constant MIN_HEALTH_FACTOR = 1.02e18;

    /** @notice Target health factor to maintain (1.05). */
    uint256 constant TARGET_HEALTH_FACTOR = 1.05e18;

    /** @notice E-Mode category for ETH-correlated assets (93% LTV). */
    uint8 constant EMODE_ETH_CORRELATED = 1;

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // ============ CREATE TEST ADDRESSES ============
        vaultOwner = makeAddr("vaultOwner");
        vaultAdmin = makeAddr("vaultAdmin");

        // ============ FORK MAINNET ============
        string memory rpc = vm.envString("ETHEREUM_MAINNET_RPC");
        vm.createSelectFork(rpc);

        weth = IERC20(WETH_MAINNET);
        address poolManagerAddress = UNISWAP_V4_POOL_MANAGER;

        // Verify PoolManager is deployed on forked network
        require(poolManagerAddress.code.length > 0, "Real PoolManager has no code!");

        // ============ FUND UNISWAP V4 FOR FLASH LOANS ============
        // PoolManager needs WETH liquidity to provide flash loans
        deal(address(weth), poolManagerAddress, 10_000 ether);

        // ============ RESOLVE AAVE POOL ADDRESS ============
        // Get the current Pool address from the AddressProvider
        (bool success, bytes memory data) = AAVE_ADDRESS_PROVIDER.staticcall(abi.encodeWithSignature("getPool()"));
        require(success, "getPool failed");
        resolvedPool = abi.decode(data, (address));

        // ============ DEPLOY VAULT ============
        vm.startPrank(vaultOwner);
        deal(address(weth), vaultOwner, INITIAL_DEPOSIT);

        // Pre-compute vault address to approve initial deposit
        address predictedVault = vm.computeCreateAddress(vaultOwner, vm.getNonce(vaultOwner));
        weth.approve(predictedVault, INITIAL_DEPOSIT);
        YieldBearingVault bVault = new YieldBearingVault(weth, vaultOwner, vaultAdmin, INITIAL_DEPOSIT);
        vm.stopPrank();

        vault = address(bVault);

        // ============ DEPLOY STRATEGY ============
        // Configure with E-Mode 1 (ETH-correlated, 93% LTV)
        // This enables up to ~14x leverage, we use 10x for safety
        strategy = new WETHLoopStrategy(
            weth,
            vault,
            poolManagerAddress,
            resolvedPool,
            AWETH_TOKEN,
            VARIABLE_DEBT_WETH,
            TARGET_LEVERAGE,
            MIN_HEALTH_FACTOR,
            TARGET_HEALTH_FACTOR,
            EMODE_ETH_CORRELATED
        );

        // ============ CONNECT STRATEGY TO VAULT ============
        vm.prank(vaultAdmin);
        bVault.setStrategy(strategy);

        // ============ FUND VAULT FOR TESTING ============
        deal(address(weth), vault, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                               TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that investment creates proper leverage.
     * @dev Verifies:
     *      - Health factor remains above minimum threshold
     *      - Collateral and debt are correctly established
     *      - Actual leverage ratio matches target (~10x)
     *
     *      With 10x leverage on 1 ETH deposit:
     *      - Total Collateral: 10 ETH
     *      - Total Debt: 9 ETH
     *      - Net Equity: 1 ETH
     */
    function test_Invest_LeveragesCorrectly() public {
        // ============ ARRANGE ============
        uint256 depositAmount = 1 ether;

        // ============ ACT: DEPOSIT TO STRATEGY ============
        vm.startPrank(vault);
        weth.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, vault);
        vm.stopPrank();

        // ============ FETCH AAVE ACCOUNT DATA ============
        (uint256 totalCollateralBase, uint256 totalDebtBase,,,, uint256 healthFactor) =
            IPool(resolvedPool).getUserAccountData(address(strategy));

        // ============ LOG RESULTS ============
        console.log("=== WETH Loop Strategy Results ===");
        console.log("Deposit Amount (ETH):", depositAmount / 1e18);
        console.log("Target Leverage:", strategy.targetLeverage());
        console.log("Health Factor:", healthFactor);
        console.log("Total Collateral Base (USD 8 dec):", totalCollateralBase);
        console.log("Total Debt Base (USD 8 dec):", totalDebtBase);

        // ============ ASSERT: HEALTH FACTOR ============
        // Health factor must stay above minimum to avoid liquidation
        assertGe(healthFactor, MIN_HEALTH_FACTOR, "Health Factor too low");

        // ============ ASSERT: POSITION ESTABLISHED ============
        assertGt(totalCollateralBase, 0, "Should have collateral");
        assertGt(totalDebtBase, 0, "Should have debt");

        // ============ ASSERT: LEVERAGE RATIO ============
        // Calculate actual leverage: Collateral / (Collateral - Debt)
        // For 10x: 10 / (10 - 9) = 10
        uint256 leverageRatio = totalCollateralBase * 100 / (totalCollateralBase - totalDebtBase);
        console.log("Actual Leverage Ratio (x100):", leverageRatio);

        // Allow some tolerance (9x minimum due to rounding)
        assertGe(leverageRatio, 900, "Leverage should be at least 9x");
    }

    /**
     * @notice Tests multiple sequential deposits maintain healthy position.
     * @dev Verifies that the strategy can handle multiple deposits
     *      without degrading the health factor or breaking leverage.
     */
    function test_Invest_MultipleDeposits() public {
        // ============ ARRANGE ============
        uint256 firstDeposit = 0.5 ether;
        uint256 secondDeposit = 0.5 ether;

        // ============ ACT: FIRST DEPOSIT ============
        vm.startPrank(vault);
        weth.approve(address(strategy), firstDeposit + secondDeposit);

        strategy.deposit(firstDeposit, vault);
        console.log("First deposit completed");

        // ============ ACT: SECOND DEPOSIT ============
        strategy.deposit(secondDeposit, vault);
        console.log("Second deposit completed");
        vm.stopPrank();

        // ============ FETCH FINAL AAVE STATE ============
        (uint256 totalCollateralBase, uint256 totalDebtBase,,,, uint256 healthFactor) =
            IPool(resolvedPool).getUserAccountData(address(strategy));

        // ============ LOG RESULTS ============
        console.log("=== After Multiple Deposits ===");
        console.log("Health Factor:", healthFactor);
        console.log("Total Collateral Base:", totalCollateralBase);
        console.log("Total Debt Base:", totalDebtBase);

        // ============ ASSERT: POSITION REMAINS HEALTHY ============
        // Multiple deposits should not degrade health factor
        assertGe(healthFactor, MIN_HEALTH_FACTOR, "Health Factor should remain healthy");
    }

    /**
     * @notice Tests divest functionality with proportional deleverage.
     * @dev Verifies:
     *      - User can withdraw part of their position
     *      - Debt and collateral are reduced proportionally
     *      - Leverage ratio is maintained after withdrawal
     *      - User receives correct amount
     */
    function test_Divest_PartialWithdrawal() public {
        // ============ ARRANGE ============
        uint256 depositAmount = 1 ether;
        uint256 withdrawAmount = 0.5 ether;

        // Deposit first
        vm.startPrank(vault);
        weth.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, vault);
        vm.stopPrank();

        // Get initial position
        (uint256 initialCollateral, uint256 initialDebt,,,, uint256 initialHealthFactor) =
            IPool(resolvedPool).getUserAccountData(address(strategy));

        console.log("=== Before Withdrawal ===");
        console.log("Collateral (USD):", initialCollateral);
        console.log("Debt (USD):", initialDebt);
        console.log("Health Factor:", initialHealthFactor);

        // ============ ACT: WITHDRAW ============
        uint256 vaultBalanceBefore = weth.balanceOf(vault);

        vm.prank(vault);
        strategy.withdraw(withdrawAmount, vault, vault);

        uint256 vaultBalanceAfter = weth.balanceOf(vault);
        uint256 receivedAmount = vaultBalanceAfter - vaultBalanceBefore;

        // Get final position
        (uint256 finalCollateral, uint256 finalDebt,,,, uint256 finalHealthFactor) =
            IPool(resolvedPool).getUserAccountData(address(strategy));

        console.log("=== After Withdrawal ===");
        console.log("Collateral (USD):", finalCollateral);
        console.log("Debt (USD):", finalDebt);
        console.log("Health Factor:", finalHealthFactor);
        console.log("Received Amount (wei):", receivedAmount);

        // ============ ASSERT: USER RECEIVED CORRECT AMOUNT ============
        assertApproxEqAbs(receivedAmount, withdrawAmount, 10, "User should receive withdrawal amount");

        // ============ ASSERT: POSITION REDUCED PROPORTIONALLY ============
        // Should withdraw ~50% of collateral and debt
        uint256 expectedCollateral = initialCollateral / 2;
        uint256 expectedDebt = initialDebt / 2;

        // Allow 1% tolerance for rounding
        assertApproxEqRel(finalCollateral, expectedCollateral, 0.01e18, "Collateral should be halved");
        assertApproxEqRel(finalDebt, expectedDebt, 0.01e18, "Debt should be halved");

        // ============ ASSERT: LEVERAGE MAINTAINED ============
        uint256 initialLeverage = initialCollateral * 100 / (initialCollateral - initialDebt);
        uint256 finalLeverage = finalCollateral * 100 / (finalCollateral - finalDebt);

        assertApproxEqRel(finalLeverage, initialLeverage, 0.01e18, "Leverage ratio should be maintained");

        // ============ ASSERT: HEALTH FACTOR REMAINS HEALTHY ============
        assertGe(finalHealthFactor, MIN_HEALTH_FACTOR, "Health factor should remain above minimum");
    }

    /**
     * @notice Tests full withdrawal (100% of position).
     * @dev Verifies that user can fully exit their position.
     */
    function test_Divest_FullWithdrawal() public {
        // ============ ARRANGE ============
        uint256 depositAmount = 1 ether;

        // Deposit first
        vm.startPrank(vault);
        weth.approve(address(strategy), depositAmount);
        uint256 shares = strategy.deposit(depositAmount, vault);
        vm.stopPrank();

        // ============ ACT: FULL REDEEM ============
        uint256 vaultBalanceBefore = weth.balanceOf(vault);

        vm.prank(vault);
        uint256 assets = strategy.redeem(shares, vault, vault);

        uint256 vaultBalanceAfter = weth.balanceOf(vault);
        uint256 receivedAmount = vaultBalanceAfter - vaultBalanceBefore;

        console.log("=== Full Withdrawal ===");
        console.log("Assets returned (wei):", assets);
        console.log("Received amount (wei):", receivedAmount);

        // Get final position
        (uint256 finalCollateral, uint256 finalDebt,,,,) = IPool(resolvedPool).getUserAccountData(address(strategy));

        console.log("Remaining Collateral:", finalCollateral);
        console.log("Remaining Debt:", finalDebt);

        // ============ ASSERT: USER RECEIVED FULL AMOUNT ============
        assertApproxEqAbs(receivedAmount, depositAmount, 100, "Should receive full deposit back");

        // ============ ASSERT: POSITION CLOSED ============
        // Small dust amounts are acceptable
        assertLt(finalCollateral, 1e6, "Collateral should be minimal");
        assertLt(finalDebt, 1e6, "Debt should be minimal");
    }

    /**
     * @notice Tests multiple users with deposits and withdrawals in different order.
     * @dev Scenario:
     *      - 3 users deposit different amounts
     *      - 2 users withdraw in different order
     *      - Verifies that withdrawals don't affect other users negatively
     *      - Verifies shares are calculated correctly for each user
     *      - Verifies leverage is maintained throughout
     */
    function test_MultipleUsers_DifferentDepositWithdrawOrder() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        uint256 user1Deposit = 1 ether;
        uint256 user2Deposit = 2 ether;
        uint256 user3Deposit = 1.5 ether;

        uint256 user1Shares;
        uint256 user2Shares;
        uint256 user3Shares;

        // ============ PHASE 1: SETUP AND DEPOSITS ============
        {
            // Whitelist users
            vm.startPrank(vaultOwner);
            YieldBearingVault(vault).addToWhitelist(user1);
            YieldBearingVault(vault).addToWhitelist(user2);
            YieldBearingVault(vault).addToWhitelist(user3);
            vm.stopPrank();

            // Fund users
            deal(address(weth), user1, user1Deposit);
            deal(address(weth), user2, user2Deposit);
            deal(address(weth), user3, user3Deposit);

            console.log("=== Initial Setup ===");
            console.log("User1 Deposit:", user1Deposit / 1e18, "ETH");
            console.log("User2 Deposit:", user2Deposit / 1e18, "ETH");
            console.log("User3 Deposit:", user3Deposit / 1e18, "ETH");

            // User1 deposits
            vm.startPrank(user1);
            weth.approve(vault, user1Deposit);
            user1Shares = YieldBearingVault(vault).deposit(user1Deposit, user1);
            vm.stopPrank();
            console.log("\nUser1 Shares:", user1Shares);

            // User2 deposits
            vm.startPrank(user2);
            weth.approve(vault, user2Deposit);
            user2Shares = YieldBearingVault(vault).deposit(user2Deposit, user2);
            vm.stopPrank();
            console.log("User2 Shares:", user2Shares);

            // User3 deposits
            vm.startPrank(user3);
            weth.approve(vault, user3Deposit);
            user3Shares = YieldBearingVault(vault).deposit(user3Deposit, user3);
            vm.stopPrank();
            console.log("User3 Shares:", user3Shares);

            // Assert shares received
            assertGt(user1Shares, 0, "User1 should receive shares");
            assertGt(user2Shares, 0, "User2 should receive shares");
            assertGt(user3Shares, 0, "User3 should receive shares");
        }

        // ============ PHASE 2: CHECK POSITION AFTER DEPOSITS ============
        {
            (uint256 totalCollateral, uint256 totalDebt,,,, uint256 healthFactor) =
                IPool(resolvedPool).getUserAccountData(address(strategy));

            console.log("\n=== Strategy Position After All Deposits ===");
            console.log("Total Collateral (USD):", totalCollateral);
            console.log("Total Debt (USD):", totalDebt);
            console.log("Health Factor:", healthFactor);

            assertGe(healthFactor, MIN_HEALTH_FACTOR, "Health factor should be healthy");
            assertGt(totalCollateral, 0, "Should have collateral");
            assertGt(totalDebt, 0, "Should have debt");
        }

        // ============ PHASE 3: USER1 WITHDRAWS ============
        {
            uint256 balanceBefore = weth.balanceOf(user1);
            vm.prank(user1);
            YieldBearingVault(vault).redeem(user1Shares, user1, user1);
            uint256 received = weth.balanceOf(user1) - balanceBefore;

            console.log("\n=== After User1 Withdrawal ===");
            console.log("User1 Assets Received:", received);

            // Allow 0.1% tolerance for rounding with leverage operations
            assertApproxEqAbs(received, user1Deposit, 0.001 ether, "User1 should receive deposit back");
            assertEq(YieldBearingVault(vault).balanceOf(user1), 0, "User1 should have no shares left");

            (,,,,, uint256 healthFactor) = IPool(resolvedPool).getUserAccountData(address(strategy));
            assertGe(healthFactor, MIN_HEALTH_FACTOR, "Health factor should remain healthy");
        }

        // ============ PHASE 4: USER3 WITHDRAWS ============
        {
            uint256 balanceBefore = weth.balanceOf(user3);
            vm.prank(user3);
            YieldBearingVault(vault).redeem(user3Shares, user3, user3);
            uint256 received = weth.balanceOf(user3) - balanceBefore;

            console.log("\n=== After User3 Withdrawal ===");
            console.log("User3 Assets Received:", received);

            // Allow 0.1% tolerance for rounding with leverage operations
            assertApproxEqAbs(received, user3Deposit, 0.0015 ether, "User3 should receive deposit back");
            assertEq(YieldBearingVault(vault).balanceOf(user3), 0, "User3 should have no shares left");

            (uint256 totalCollateral, uint256 totalDebt,,,, uint256 healthFactor) =
                IPool(resolvedPool).getUserAccountData(address(strategy));
            assertGe(healthFactor, MIN_HEALTH_FACTOR, "Health factor should remain healthy");

            // Verify leverage is maintained
            if (totalCollateral > 0 && totalDebt > 0) {
                uint256 leverage = totalCollateral * 100 / (totalCollateral - totalDebt);
                console.log("\nFinal Leverage (x100):", leverage);
                assertApproxEqRel(leverage, uint256(TARGET_LEVERAGE) * 100, 0.1e18, "Leverage should be maintained");
            }
        }

        // ============ PHASE 5: VERIFY USER2 IS UNAFFECTED ============
        {
            uint256 user2SharesRemaining = YieldBearingVault(vault).balanceOf(user2);
            assertEq(user2SharesRemaining, user2Shares, "User2 shares should remain unchanged");

            uint256 user2ExpectedAssets = YieldBearingVault(vault).previewRedeem(user2SharesRemaining);
            console.log("\n=== User2 Remaining Position ===");
            console.log("User2 Shares:", user2SharesRemaining);
            console.log("User2 Expected Assets:", user2ExpectedAssets);

            // Allow 0.1% tolerance for user2's position
            assertApproxEqAbs(user2ExpectedAssets, user2Deposit, 0.002 ether, "User2 should still have their deposit value");
        }
    }
}
