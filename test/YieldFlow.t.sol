// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {BetaVault} from "../src/vaults/BetaVault.sol";
import {MockStrategy} from "../src/strategies/MockStrategy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mock ERC20
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 1_000_000e18);
    }
}

contract YieldFlowTest is Test {
    MockERC20 public asset;
    BetaVault public vault;
    MockStrategy public strategy;
    
    // Constants for test values
    uint256 constant INITIAL_SUPPLY_ALICE = 1000e18;
    uint256 constant INITIAL_DEPOSIT_DEAD = 1000; // Small amoount in wei
    uint256 constant DEPOSIT_AMOUNT = 100e18;
    uint256 constant YIELD_AMOUNT_10_PERCENT = 10e18;
    uint256 constant ONE_SHARE = 1e18;
    
    address public owner;
    address public alice;
    address public bob;

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy Asset
        asset = new MockERC20();

        // Calculate Future Vault Address to approve initial deposit
        // Note: standard forge-std computeCreateAddress usage
        address vaultAddr = computeCreateAddress(address(this), vm.getNonce(address(this)));
        
        // Approve and Deploy
        asset.approve(vaultAddr, INITIAL_DEPOSIT_DEAD);
        vault = new BetaVault(asset, owner, INITIAL_DEPOSIT_DEAD);

        // Deploy Strategy
        strategy = new MockStrategy(asset, address(vault));

        // Connect Strategy to Vault
        vault.setStrategy(strategy);

        // Setup Alice
        asset.transfer(alice, INITIAL_SUPPLY_ALICE);
        vm.prank(owner);
        vault.addToWhitelist(alice);
    }

    function test_FullYieldFlow() public {
        // --- DEPOSIT ---
        // Expect 1:1 shares
        
        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // Vault should hold the initial dead assets
        assertEq(asset.balanceOf(address(vault)), INITIAL_DEPOSIT_DEAD, "Vault should hold initial dead assets");
        // Strategy should hold user funds
        assertEq(asset.balanceOf(address(strategy)), DEPOSIT_AMOUNT, "Strategy should hold user funds");
        // Alice has shares (1:1 ratio maintained)
        assertEq(vault.balanceOf(alice), DEPOSIT_AMOUNT, "Alice should have shares");

        // --- SIMULATE YIELD (10% Gain) ---
        asset.transfer(address(strategy), YIELD_AMOUNT_10_PERCENT);

        // Total Assets should be user deposit + yield + initial dead assets
        assertApproxEqAbs(vault.totalAssets(), DEPOSIT_AMOUNT + YIELD_AMOUNT_10_PERCENT + INITIAL_DEPOSIT_DEAD, 3, "Total assets should include yield and dead assets");

        // --- WITHDRAW ---
        vm.startPrank(alice);
        vault.redeem(DEPOSIT_AMOUNT, alice, alice); // Redeeming all shares
        vm.stopPrank();

        // Alice gets principal + yield (approx 200 wei error due to dead shares dilution)
        assertApproxEqAbs(asset.balanceOf(alice), INITIAL_SUPPLY_ALICE + YIELD_AMOUNT_10_PERCENT, 200, "Alice should have profit");
        // Vault should still hold initial dead assets (plus accumulated yield for dead shares)
        assertGe(vault.totalAssets(), INITIAL_DEPOSIT_DEAD, "Vault should hold dead assets after exit");
    }

    function test_RevertIfNotWhitelisted() public {
        // Fund Bob first
        uint256 smallAmount = 100;
        asset.transfer(bob, smallAmount);

        vm.startPrank(bob); // Bob is not whitelisted
        asset.approve(address(vault), smallAmount);
        
        // Use selector for custom error: NotWhitelisted(address)
        bytes4 errorSelector = bytes4(keccak256("NotWhitelisted(address)"));
        vm.expectRevert(abi.encodeWithSelector(errorSelector, bob));
        
        vault.deposit(smallAmount, bob);
        vm.stopPrank();
    }

    function test_SharePriceEvolution() public {
        console.log("--- Initial State (After Construction) ---");
        console.log("Share Price (Assets per 1 Share):", vault.convertToAssets(ONE_SHARE));
        console.log("Total Assets:", vault.totalAssets());
        console.log("Total Supply:", vault.totalSupply());

        // INVEST (Deposit)
        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        console.log("\n--- After Alice Deposit (100 assets) ---");
        console.log("Share Price (Assets per 1 Share):", vault.convertToAssets(ONE_SHARE));
        console.log("Total Assets:", vault.totalAssets());
        console.log("Total Supply:", vault.totalSupply());

        // YIELD GENERATION (Simulated)
        // Add 40% yield to strategy
        uint256 simulatedYield = 40e18;
        asset.transfer(address(strategy), simulatedYield);

        console.log("\n--- After 40% Yield Generation ---");
        console.log("Share Price (Assets per 1 Share):", vault.convertToAssets(ONE_SHARE));
        console.log("Total Assets:", vault.totalAssets());
        console.log("Total Supply:", vault.totalSupply());

        // DIVEST / WITHDRAW FULL (Everything)
        // Alice withdraws ALL her shares (DEPOSIT_AMOUNT)
        vm.startPrank(alice);
        vault.redeem(DEPOSIT_AMOUNT, alice, alice);
        vm.stopPrank();

        console.log("\n--- After FULL Withdrawal (Alice Exits) ---");
        console.log("Share Price (Assets per 1 Share):", vault.convertToAssets(ONE_SHARE));
        console.log("Total Assets:", vault.totalAssets());
        console.log("Total Supply:", vault.totalSupply());
    }
    function test_PerformanceFeeLogic() public {
        // 1. Setup Fees
        address feeRecipient = makeAddr("feeRecipient");
        vault.setFeeRecipient(feeRecipient);
        vault.setProtocolFee(1000); // 10% on profit

        // 2. Deposit
        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // 3. Verify No Fee on Principal
        // Fees are assessed on deposit, but HWM should match Total Assets initially (plus deposit logic)
        // No profit generated yet.
        assertEq(vault.balanceOf(feeRecipient), 0, "No fees should be paid on principal deposit");

        // 4. Generate Yield (Profit)
        uint256 profit = 20e18; // 20% gain
        asset.transfer(address(strategy), profit);
        
        // 5. Trigger Fee Assessment (Manual)
        vault.assessPerformanceFee();

        // 6. Verify Fee Payment
        // Fee = 10% of 20 = 2 assets worth of shares.
        // Shares minted will be relative to current share price.
        uint256 recipientShares = vault.balanceOf(feeRecipient);
        assertGt(recipientShares, 0, "Fee recipient should have received shares");
        
        uint256 feeAssetsApprox = vault.convertToAssets(recipientShares);
        assertApproxEqAbs(feeAssetsApprox, 2e18, 0.1e18, "Fee value should be approx 10% of profit");

        // 7. Verify High Watermark Updated
        // Second assessment should yield 0 fees unless new profit
        uint256 sharesBeforeOnly = vault.balanceOf(feeRecipient);
        vault.assessPerformanceFee();
        assertEq(vault.balanceOf(feeRecipient), sharesBeforeOnly, "No double counting of fees");

        // 8. Withdraw Trigger
        // Generate more yield
        uint256 moreProfit = 10e18;
        asset.transfer(address(strategy), moreProfit);
        
        vm.startPrank(alice);
        // Withdraw should convert shares. 
        // Note: Alice's shares are now diluted by the fee shares, so she gets slightly less of the "total pie" than 100%, 
        // but she gets her principal + 90% of profit.
        vault.redeem(DEPOSIT_AMOUNT, alice, alice); 
        vm.stopPrank();

        // Verify fees increased again during withdraw trigger
        assertGt(vault.balanceOf(feeRecipient), sharesBeforeOnly, "Withdraw should have triggered 2nd fee payment");
    }
}
