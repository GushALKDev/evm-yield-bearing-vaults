// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {YieldBearingVault} from "../src/vaults/YieldBearingVault.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice Simple ERC20 token for testing.
 */
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/**
 * @title YieldFlowTest
 * @notice Unit tests for yield flow mechanics in the vault system.
 * @dev Tests deposit/withdraw flows, share pricing, and performance fees
 *      using a MockStrategy that doesn't interact with external protocols.
 */
contract YieldFlowTest is Test {
    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    MockERC20 public asset;
    YieldBearingVault public vault;
    MockStrategy public strategy;

    address public owner;
    address public alice;
    address public bob;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /** @notice Initial token balance for Alice. */
    uint256 constant INITIAL_SUPPLY_ALICE = 1000e18;

    /** @notice Required initial deposit burned to dead address (inflation protection). */
    uint256 constant INITIAL_DEPOSIT_DEAD = 1000;

    /** @notice Standard deposit amount used in tests. */
    uint256 constant DEPOSIT_AMOUNT = 100e18;

    /** @notice Simulated yield representing 10% gain on DEPOSIT_AMOUNT. */
    uint256 constant YIELD_AMOUNT_10_PERCENT = 10e18;

    /** @notice One share unit for price calculations. */
    uint256 constant ONE_SHARE = 1e18;

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // ============ CREATE TEST ADDRESSES ============
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.startPrank(owner);

        // ============ DEPLOY MOCK ASSET ============
        asset = new MockERC20();

        // ============ DEPLOY VAULT ============
        // Pre-compute vault address to approve initial deposit before deployment
        address vaultAddr = vm.computeCreateAddress(owner, vm.getNonce(owner));
        asset.approve(vaultAddr, INITIAL_DEPOSIT_DEAD);
        vault = new YieldBearingVault(asset, owner, owner, INITIAL_DEPOSIT_DEAD);

        // ============ DEPLOY & CONNECT STRATEGY ============
        strategy = new MockStrategy(asset, address(vault));
        vault.setStrategy(strategy);

        // ============ SETUP ALICE ============
        asset.transfer(alice, INITIAL_SUPPLY_ALICE);
        vault.addToWhitelist(alice);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests complete yield flow: deposit, yield generation, and withdrawal.
     * @dev Verifies that:
     *      - Deposits correctly route funds to strategy
     *      - Simulated yield is reflected in totalAssets
     *      - Withdrawals return principal + proportional yield
     */
    function test_FullYieldFlow() public {
        // ============ ARRANGE ============
        // Alice starts with INITIAL_SUPPLY_ALICE tokens
        // Vault has INITIAL_DEPOSIT_DEAD buffer from construction

        // ============ ACT: DEPOSIT ============
        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ASSERT: POST-DEPOSIT STATE ============
        // Vault retains initial buffer (1000 wei)
        assertEq(asset.balanceOf(address(vault)), INITIAL_DEPOSIT_DEAD, "Vault should hold initial dead assets");
        // Strategy holds all user deposits
        assertEq(asset.balanceOf(address(strategy)), DEPOSIT_AMOUNT, "Strategy should hold user funds");
        // Alice receives 1:1 shares for deposit
        assertEq(vault.balanceOf(alice), DEPOSIT_AMOUNT, "Alice should have shares equal to deposit");

        // ============ ACT: SIMULATE YIELD (10% GAIN) ============
        // Transfer tokens directly to strategy to simulate external protocol yield
        vm.prank(owner);
        asset.transfer(address(strategy), YIELD_AMOUNT_10_PERCENT);

        // ============ ASSERT: YIELD REFLECTED IN TOTAL ASSETS ============
        // Total = User Deposit + Yield + Dead Buffer
        assertApproxEqAbs(
            vault.totalAssets(),
            DEPOSIT_AMOUNT + YIELD_AMOUNT_10_PERCENT + INITIAL_DEPOSIT_DEAD,
            3,
            "Total assets should include yield and dead assets"
        );

        // ============ ACT: FULL WITHDRAWAL ============
        vm.startPrank(alice);
        vault.redeem(DEPOSIT_AMOUNT, alice, alice);
        vm.stopPrank();

        // ============ ASSERT: ALICE RECEIVED PRINCIPAL + YIELD ============
        // Alice should have original balance + yield (minus ~200 wei dust for dead shares)
        assertApproxEqAbs(
            asset.balanceOf(alice), INITIAL_SUPPLY_ALICE + YIELD_AMOUNT_10_PERCENT, 200, "Alice should have profit"
        );
        // Vault retains dead shares worth of assets
        assertGe(vault.totalAssets(), INITIAL_DEPOSIT_DEAD, "Vault should hold dead assets after exit");
    }

    /**
     * @notice Tests that non-whitelisted addresses cannot deposit.
     * @dev Verifies whitelist enforcement on deposit operations.
     */
    function test_RevertIfNotWhitelisted() public {
        // ============ ARRANGE ============
        uint256 smallAmount = 100;

        // Fund Bob (who is NOT whitelisted)
        vm.prank(owner);
        asset.transfer(bob, smallAmount);

        // ============ ACT & ASSERT ============
        vm.startPrank(bob);
        asset.approve(address(vault), smallAmount);

        // Expect revert with NotWhitelisted error
        bytes4 errorSelector = bytes4(keccak256("NotWhitelisted(address)"));
        vm.expectRevert(abi.encodeWithSelector(errorSelector, bob));

        vault.deposit(smallAmount, bob);
        vm.stopPrank();
    }

    /**
     * @notice Tests share price evolution through deposit and yield.
     * @dev Tracks how convertToAssets changes as:
     *      1. Users deposit (dilution)
     *      2. Yield accrues (appreciation)
     *      3. Users withdraw (concentration)
     */
    function test_SharePriceEvolution() public {
        // ============ PHASE 1: INITIAL STATE ============
        console.log("--- Initial State (After Construction) ---");
        console.log("Share Price (Assets per 1 Share):", vault.convertToAssets(ONE_SHARE));
        console.log("Total Assets:", vault.totalAssets());
        console.log("Total Supply:", vault.totalSupply());
        // Share price starts at 1:1 (1e18 assets per 1e18 shares)

        // ============ PHASE 2: ALICE DEPOSITS ============
        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        console.log("\n--- After Alice Deposit (100 assets) ---");
        console.log("Share Price (Assets per 1 Share):", vault.convertToAssets(ONE_SHARE));
        console.log("Total Assets:", vault.totalAssets());
        console.log("Total Supply:", vault.totalSupply());
        // Share price remains 1:1 (no yield yet)

        // ============ PHASE 3: YIELD GENERATION (40%) ============
        uint256 simulatedYield = 40e18;
        vm.prank(owner);
        asset.transfer(address(strategy), simulatedYield);

        console.log("\n--- After 40%% Yield Generation ---");
        console.log("Share Price (Assets per 1 Share):", vault.convertToAssets(ONE_SHARE));
        console.log("Total Assets:", vault.totalAssets());
        console.log("Total Supply:", vault.totalSupply());
        // Share price increases: ~1.4 assets per share

        // ============ PHASE 4: ALICE EXITS ============
        vm.startPrank(alice);
        vault.redeem(DEPOSIT_AMOUNT, alice, alice);
        vm.stopPrank();

        console.log("\n--- After FULL Withdrawal (Alice Exits) ---");
        console.log("Share Price (Assets per 1 Share):", vault.convertToAssets(ONE_SHARE));
        console.log("Total Assets:", vault.totalAssets());
        console.log("Total Supply:", vault.totalSupply());
        // Only dead shares remain, price reflects accumulated yield
    }

    /**
     * @notice Tests performance fee logic with High Water Mark.
     * @dev Verifies that:
     *      - No fees charged on principal deposits
     *      - Fees correctly calculated as % of profit
     *      - High Water Mark prevents double-taxation
     *      - Fees triggered on withdrawal
     */
    function test_PerformanceFeeLogic() public {
        // ============ ARRANGE: SETUP FEES ============
        address feeRecipient = makeAddr("feeRecipient");

        vm.startPrank(owner);
        vault.setFeeRecipient(feeRecipient);
        vault.setProtocolFee(1000); // 10% performance fee (1000 bps)
        vm.stopPrank();

        // ============ ACT: DEPOSIT ============
        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ASSERT: NO FEE ON PRINCIPAL ============
        // Fee recipient should have 0 shares after deposit (no profit yet)
        assertEq(vault.balanceOf(feeRecipient), 0, "No fees should be paid on principal deposit");

        // ============ ACT: GENERATE YIELD (20% GAIN) ============
        uint256 profit = 20e18;
        vm.prank(owner);
        asset.transfer(address(strategy), profit);

        // ============ ACT: TRIGGER FEE ASSESSMENT ============
        vault.assessPerformanceFee();

        // ============ ASSERT: FEE CORRECTLY CALCULATED ============
        // Fee = 10% of 20e18 profit = 2e18 worth of shares
        uint256 recipientShares = vault.balanceOf(feeRecipient);
        assertGt(recipientShares, 0, "Fee recipient should have received shares");

        uint256 feeAssetsApprox = vault.convertToAssets(recipientShares);
        assertApproxEqAbs(feeAssetsApprox, 2e18, 0.1e18, "Fee value should be approx 10% of profit");

        // ============ ASSERT: HIGH WATER MARK PREVENTS DOUBLE-TAXATION ============
        uint256 sharesBeforeSecondAssess = vault.balanceOf(feeRecipient);
        vault.assessPerformanceFee(); // Call again without new profit
        assertEq(vault.balanceOf(feeRecipient), sharesBeforeSecondAssess, "No double counting of fees");

        // ============ ACT: MORE YIELD + WITHDRAWAL ============
        uint256 moreProfit = 10e18;
        vm.prank(owner);
        asset.transfer(address(strategy), moreProfit);

        vm.startPrank(alice);
        vault.redeem(DEPOSIT_AMOUNT, alice, alice);
        vm.stopPrank();

        // ============ ASSERT: WITHDRAWAL TRIGGERED NEW FEE ============
        assertGt(vault.balanceOf(feeRecipient), sharesBeforeSecondAssess, "Withdraw should trigger fee payment");
    }
}
