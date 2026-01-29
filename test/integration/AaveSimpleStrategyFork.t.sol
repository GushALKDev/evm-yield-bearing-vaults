// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {AaveSimpleLendingStrategy} from "../../src/strategies/AaveSimpleLendingStrategy.sol";
import {Constants} from "../../src/utils/Constants.sol";

/**
 * @title AaveSimpleStrategyForkTest
 * @notice Fork tests for the Aave V3 simple lending strategy.
 * @dev Tests deposit, withdraw, and redeem flows with real Aave integration.
 *      Requires ETHEREUM_MAINNET_RPC environment variable to be set.
 *
 *      Strategy Flow:
 *      1. User deposits USDC to vault
 *      2. Vault forwards to strategy
 *      3. Strategy supplies to Aave, receives aUSDC
 *      4. Interest accrues via aToken rebasing
 *      5. User withdraws principal + yield
 */
contract AaveSimpleStrategyForkTest is Test {
    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice USDC token address on Ethereum Mainnet (6 decimals).
     */
    address constant USDC = Constants.ETHEREUM_MAINNET_USDC;

    /**
     * @notice Aave V3 Pool address on Ethereum Mainnet.
     */
    address constant AAVE_POOL = Constants.ETHEREUM_MAINNET_AAVE_V3_POOL;

    /**
     * @notice aUSDC token address (Aave interest-bearing USDC).
     */
    address constant A_USDC = Constants.ETHEREUM_MAINNET_AAVE_V3_USDC_ATOKEN;

    /**
     * @notice Required initial deposit for vault (inflation protection).
     */
    uint256 constant REQUIRED_DEPOSIT = 1000;

    /**
     * @notice Initial USDC balance for Alice (100,000 USDC).
     */
    uint256 constant ALICE_INITIAL_BALANCE = 100_000e6;

    /**
     * @notice Initial USDC balance for Owner (10,000 USDC).
     */
    uint256 constant OWNER_INITIAL_BALANCE = 10_000e6;

    /**
     * @notice Standard deposit amount for tests (5,000 USDC).
     */
    uint256 constant DEPOSIT_AMOUNT = 5000e6;

    /**
     * @notice Dead address that holds burned shares.
     */
    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

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
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // ============ CREATE TEST ADDRESSES ============
        alice = makeAddr("alice");
        owner = makeAddr("owner");

        // ============ FORK MAINNET ============
        vm.createSelectFork(vm.envString("ETHEREUM_MAINNET_RPC"));

        usdc = IERC20(USDC);
        aUsdc = IERC20(A_USDC);

        // ============ FUND TEST ACCOUNTS ============
        deal(USDC, alice, ALICE_INITIAL_BALANCE);
        deal(USDC, owner, OWNER_INITIAL_BALANCE);

        // ============ DEPLOY VAULT ============
        vm.startPrank(owner);

        // Pre-compute vault address to approve initial deposit
        address vaultAddr = vm.computeCreateAddress(owner, vm.getNonce(owner));
        usdc.approve(vaultAddr, REQUIRED_DEPOSIT);
        vault = new YieldBearingVault(usdc, owner, owner, REQUIRED_DEPOSIT);

        // ============ DEPLOY STRATEGY ============
        strategy = new AaveSimpleLendingStrategy(usdc, address(vault), AAVE_POOL, A_USDC);

        // ============ CONNECT STRATEGY & WHITELIST ============
        vault.setStrategy(strategy);
        vault.addToWhitelist(alice);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that deposits are correctly invested into Aave.
     * @dev Verifies:
     *      - Vault total assets matches deposit + buffer
     *      - Strategy holds 0 underlying (all in Aave)
     *      - System invariants are maintained
     */
    function test_DepositInvestsInAave() public {
        // ============ ACT: DEPOSIT ============
        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ASSERT: VAULT STATE ============
        uint256 vaultBalance = vault.totalAssets();
        // Total = Deposit + Initial Buffer (1000 wei)
        assertApproxEqAbs(vaultBalance, DEPOSIT_AMOUNT + REQUIRED_DEPOSIT, 2, "Vault total assets mismatch");

        // ============ ASSERT: PHYSICAL BALANCES ============
        // Vault holds only the initial buffer
        assertEq(usdc.balanceOf(address(vault)), REQUIRED_DEPOSIT, "Vault should hold 1000 wei buffer");
        // Strategy holds 0 underlying (all deposited to Aave)
        assertEq(usdc.balanceOf(address(strategy)), 0, "Strategy should hold 0 underlying");

        // ============ ASSERT: SHARE OWNERSHIP INVARIANTS ============
        // Vault shares = Alice + Dead
        assertEq(
            vault.totalSupply(), vault.balanceOf(alice) + vault.balanceOf(DEAD_ADDRESS), "Vault Total Supply Invariant"
        );
        // Strategy shares = Vault's holdings
        assertEq(strategy.totalSupply(), strategy.balanceOf(address(vault)), "Strategy Total Supply Invariant");

        // ============ ASSERT: MANAGED ASSETS INVARIANT ============
        // Vault assets = Strategy assets + Buffer
        assertApproxEqAbs(
            vault.totalAssets(), strategy.totalAssets() + REQUIRED_DEPOSIT, 2, "Vault vs Strategy Assets Invariant"
        );

        _logState("Deposit");
    }

    /**
     * @notice Tests that withdrawals correctly divest from Aave with yield.
     * @dev Verifies:
     *      - Yield accrues over time via aToken rebasing
     *      - Withdrawals return correct amount
     *      - Remaining position is healthy
     */
    function test_WithdrawDivestsFromAave() public {
        // ============ ARRANGE: DEPOSIT ============
        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 strategyAssetsBefore = strategy.totalAssets();
        console.log("Strategy Total Managed Assets Initial:", strategyAssetsBefore);

        // ============ ACT: TIME TRAVEL (1 DAY) ============
        // Simulate 1 day passing for yield accrual
        // ~7200 blocks at 12s/block = 1 day
        vm.roll(block.number + 7200);
        vm.warp(block.timestamp + 1 days);

        // ============ ASSERT: YIELD GENERATED ============
        uint256 strategyAssetsAfter = strategy.totalAssets();
        uint256 yieldGenerated = strategyAssetsAfter - strategyAssetsBefore;

        console.log("Strategy Total Managed Assets After 1 Day:", strategyAssetsAfter);
        console.log("Yield Generated:", yieldGenerated);

        assertGt(strategyAssetsAfter, strategyAssetsBefore, "Should have earned yield from Aave");

        // ============ ACT: WITHDRAW HALF ============
        uint256 withdrawAmount = DEPOSIT_AMOUNT / 2; // 2,500 USDC
        vault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        // ============ ASSERT: ALICE BALANCE ============
        // Alice should have: Initial - Deposit + Withdrawn
        assertEq(
            usdc.balanceOf(alice),
            ALICE_INITIAL_BALANCE - DEPOSIT_AMOUNT + withdrawAmount,
            "Alice should have correct USDC balance"
        );

        // ============ ASSERT: ALICE SHARES (PROFIT RETENTION) ============
        // Alice keeps more shares than half due to yield
        uint256 expectedRemainingSharesMin = 2500e6;
        assertGt(vault.balanceOf(alice), expectedRemainingSharesMin, "Alice should retain shares");

        // ============ ASSERT: SYSTEM INVARIANTS ============
        assertEq(usdc.balanceOf(address(vault)), 0, "Vault should hold 0 underlying (buffer used)");
        assertEq(usdc.balanceOf(address(strategy)), 0, "Strategy should hold 0 underlying");

        assertEq(
            vault.totalSupply(), vault.balanceOf(alice) + vault.balanceOf(DEAD_ADDRESS), "Vault Total Supply Invariant"
        );
        assertEq(strategy.totalSupply(), strategy.balanceOf(address(vault)), "Strategy Total Supply Invariant");

        assertApproxEqAbs(vault.totalAssets(), strategy.totalAssets(), 1, "Vault vs Strategy Assets Invariant");

        _logState("Withdraw");
    }

    /**
     * @notice Tests that redeem correctly divests from Aave and includes yield.
     * @dev Verifies:
     *      - Share price increases with yield
     *      - Redeem returns principal + proportional yield
     *      - Remaining shares correctly calculated
     */
    function test_RedeemDivestsFromAave() public {
        // ============ ARRANGE: DEPOSIT ============
        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 strategyAssetsBefore = strategy.totalAssets();
        console.log("Strategy Total Managed Assets Initial:", strategyAssetsBefore);

        // ============ ACT: TIME TRAVEL (1 DAY) ============
        vm.roll(block.number + 7200);
        vm.warp(block.timestamp + 1 days);

        uint256 strategyAssetsAfter = strategy.totalAssets();
        uint256 yieldGenerated = strategyAssetsAfter - strategyAssetsBefore;

        console.log("Strategy Total Managed Assets After 1 Day:", strategyAssetsAfter);
        console.log("Yield Generated:", yieldGenerated);

        // ============ ASSERT: SHARE PRICE INCREASED ============
        // 1e18 shares should now be worth more than 1e18 assets
        uint256 assetsPerShare = vault.convertToAssets(1e18);
        assertGt(assetsPerShare, 1e18, "Share price should increase with yield");

        // ============ ACT: REDEEM HALF OF SHARES ============
        uint256 sharesToRedeem = DEPOSIT_AMOUNT / 2; // 2,500e6 shares
        vault.redeem(sharesToRedeem, alice, alice);
        vm.stopPrank();

        // ============ ASSERT: ALICE RECEIVED PRINCIPAL + YIELD ============
        uint256 expectedPrincipal = 2500e6;
        uint256 aliceBalance = usdc.balanceOf(alice);

        // Alice should receive more than just principal back
        assertGt(
            aliceBalance,
            ALICE_INITIAL_BALANCE - DEPOSIT_AMOUNT + expectedPrincipal,
            "Alice should receive principal + yield"
        );

        // ============ ASSERT: REMAINING SHARES ============
        // Alice should have exactly half her shares remaining
        assertEq(vault.balanceOf(alice), 2500e6, "Alice should have exactly half shares remaining");

        // ============ ASSERT: SYSTEM INVARIANTS ============
        assertEq(usdc.balanceOf(address(vault)), 0, "Vault should hold 0 underlying (buffer used)");
        assertEq(usdc.balanceOf(address(strategy)), 0, "Strategy should hold 0 underlying");

        assertEq(
            vault.totalSupply(), vault.balanceOf(alice) + vault.balanceOf(DEAD_ADDRESS), "Vault Total Supply Invariant"
        );
        assertEq(strategy.totalSupply(), strategy.balanceOf(address(vault)), "Strategy Total Supply Invariant");

        assertApproxEqAbs(vault.totalAssets(), strategy.totalAssets(), 1, "Vault vs Strategy Assets Invariant");

        _logState("Redeem");
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Logs the current state of the system for debugging.
     * @param action The action that triggered this log (Deposit/Withdraw/Redeem).
     */
    function _logState(string memory action) internal view {
        console.log("");
        console.log("--- Final State Report (%s) ---", action);

        // Physical token balances
        console.log("Underlying Asset Held (Alice):", usdc.balanceOf(alice));
        console.log("Underlying Asset Held (Vault):", usdc.balanceOf(address(vault)));
        console.log("Underlying Asset Held (Strategy):", usdc.balanceOf(address(strategy)));

        // Share balances
        console.log("Vault Shares (Alice):", vault.balanceOf(alice));
        console.log("Vault Shares (Dead):", vault.balanceOf(DEAD_ADDRESS));
        console.log("Strategy Shares (Vault):", strategy.balanceOf(address(vault)));

        // Aave position
        console.log("aUSDC Balance (Strategy):", aUsdc.balanceOf(address(strategy)));

        // Totals
        console.log("Vault Total Supply:", vault.totalSupply());
        console.log("Strategy Total Supply:", strategy.totalSupply());
        console.log("Vault Total Managed Assets:", vault.totalAssets());
        console.log("Strategy Total Managed Assets:", strategy.totalAssets());
    }
}
