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
}
