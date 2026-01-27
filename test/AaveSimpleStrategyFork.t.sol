// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BetaVault} from "../src/vaults/BetaVault.sol";
import {AaveSimpleLendingStrategy} from "../src/strategies/AaveSimpleLendingStrategy.sol";

import {Constants} from "../src/utils/Constants.sol";

contract AaveSimpleStrategyForkTest is Test {
    
    // Mainnet Addresses via Constants
    address constant USDC = Constants.ETHEREUM_MAINNET_USDC;
    address constant AAVE_POOL = Constants.ETHEREUM_MAINNET_AAVE_V3_POOL;
    address constant A_USDC = Constants.ETHEREUM_MAINNET_AAVE_V3_USDC_ATOKEN;

    BetaVault vault;
    AaveSimpleLendingStrategy strategy;
    IERC20 usdc;
    IERC20 aUsdc;

    address alice = makeAddr("alice");
    address owner = makeAddr("owner");

    uint256 INITIAL_DEPOSIT = 1000e6; // 1000 USDC
    
    function setUp() public {
        // Fork Mainnet;
        vm.createSelectFork(vm.envString("ETHEREUM_MAINNET_RPC"));

        usdc = IERC20(USDC);
        aUsdc = IERC20(A_USDC);

        // Fund Alice and Owner (for initial deposit)
        deal(USDC, alice, 100_000e6);
        deal(USDC, owner, 10_000e6);

        // Deploy Vault
        vm.startPrank(owner);
        // Initial deposit to prevent inflation attack
        uint256 initialDeposit = 1000;
        address vaultAddr = vm.computeCreateAddress(owner, vm.getNonce(owner));
        usdc.approve(vaultAddr, initialDeposit);
        vault = new BetaVault(usdc, owner, initialDeposit);
        
        // Deploy Strategy
        strategy = new AaveSimpleLendingStrategy(
            usdc,
            address(vault),
            AAVE_POOL,
            A_USDC
        );

        // Connect Strategy
        vault.setStrategy(strategy);
        
        // Whitelist Alice
        vault.addToWhitelist(alice);
        vm.stopPrank();
    }

    function test_DepositInvestsInAave() public {
        uint256 depositAmount = 5000e6;

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        // Check Vault State
        uint256 vaultBalance = vault.totalAssets();
        assertApproxEqAbs(vaultBalance, depositAmount + 1000, 2, "Vault total assets should approx match deposit + 1000 wei");
        
        // --- System Invariants Check ---
        
        // Underlying Assets (Physical Balance)
        // Vault holds 1000 wei buffer, Strategy holds 0 (all in Aave)
        assertEq(usdc.balanceOf(address(vault)), 1000, "Vault should hold 1000 wei buffer");
        assertEq(usdc.balanceOf(address(strategy)), 0, "Strategy should hold 0 underlying");

        // Shares Ownership
        assertEq(vault.totalSupply(), vault.balanceOf(alice) + vault.balanceOf(address(0x000000000000000000000000000000000000dEaD)), "Vault Total Supply Invariant");
        assertEq(strategy.totalSupply(), strategy.balanceOf(address(vault)), "Strategy Total Supply Invariant");

        // Managed Assets
        // Vault has Strategy Assets + 1000 wei buffer
        assertApproxEqAbs(vault.totalAssets(), strategy.totalAssets() + 1000, 2, "Vault vs Strategy Assets Invariant (+buffer)");

        console.log("\n--- Final State Report (Deposit) ---");
        
        console.log("Underlying Asset Held (Alice):", usdc.balanceOf(alice));
        console.log("Underlying Asset Held (Vault):", usdc.balanceOf(address(vault)));
        console.log("Underlying Asset Held (Strategy):", usdc.balanceOf(address(strategy)));
        
        console.log("Vault Shares (Alice):", vault.balanceOf(alice));
        console.log("Vault Shares (Dead):", vault.balanceOf(address(0x000000000000000000000000000000000000dEaD)));
        console.log("Strategy Shares (Vault):", strategy.balanceOf(address(vault)));

        console.log("aUSDC Balance (Strategy):", aUsdc.balanceOf(address(strategy)));

        console.log("Vault Total Supply:", vault.totalSupply());
        console.log("Strategy Total Supply:", strategy.totalSupply());

        console.log("Vault Total Managed Assets:", vault.totalAssets());
        console.log("Strategy Total Managed Assets:", strategy.totalAssets());
    }

    function test_WithdrawDivestsFromAave() public {
        uint256 depositAmount = 5000e6;

        // Deposit
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        
        // Check Strategy Balance BEFORE time travel
        uint256 strategyAssetsBefore = strategy.totalAssets();
        console.log("Strategy Total Managed Assets Initial:", strategyAssetsBefore);

        // Time travel to accrue interest
        vm.roll(block.number + 7200); // ~1 day of blocks
        vm.warp(block.timestamp + 1 days); 

        // Check Strategy Balance AFTER time travel
        uint256 strategyAssetsAfter = strategy.totalAssets();
        console.log("Strategy Total Managed Assets After 1 Day:", strategyAssetsAfter);
        console.log("Yield Generated:", strategyAssetsAfter - strategyAssetsBefore);

        // Ensure we actually earned something
        assertGt(strategyAssetsAfter, strategyAssetsBefore, "Should have earned yield");
        
        // Withdraw half
        uint256 withdrawAmount = depositAmount / 2;
        vault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        // Check Specific Logic: Alice Balance
        assertEq(usdc.balanceOf(alice), 100_000e6 - depositAmount + withdrawAmount, "Alice should have correct USDC balance");
        
        // Check Specific Logic: Alice Shares (Profit retention)
        uint256 expectedRemainingSharesMin = 2500e6;
        assertGt(vault.balanceOf(alice), expectedRemainingSharesMin, "Alice should retain slightly more shares due to yield");

        // --- System Invariants Check ---
        
        // Underlying Assets (Physical Balance)
        // Buffer consumed during withdrawal -> Both 0
        assertEq(usdc.balanceOf(address(vault)), 0, "Vault should hold 0 underlying (buffer used)");
        assertEq(usdc.balanceOf(address(strategy)), 0, "Strategy should hold 0 underlying");

        // Shares Ownership
        assertEq(vault.totalSupply(), vault.balanceOf(alice) + vault.balanceOf(address(0x000000000000000000000000000000000000dEaD)), "Vault Total Supply Invariant");
        assertEq(strategy.totalSupply(), strategy.balanceOf(address(vault)), "Strategy Total Supply Invariant");

        // Managed Assets
        // Buffer consumed -> Identical assets (allow 1 wei rounding)
        assertApproxEqAbs(vault.totalAssets(), strategy.totalAssets(), 1, "Vault vs Strategy Assets Invariant (Equal)");

        console.log("\n--- Final State Report (Withdraw) ---");
        
        console.log("Underlying Asset Held (Alice):", usdc.balanceOf(alice));
        console.log("Underlying Asset Held (Vault):", usdc.balanceOf(address(vault)));
        console.log("Underlying Asset Held (Strategy):", usdc.balanceOf(address(strategy)));
        
        console.log("Vault Shares (Alice):", vault.balanceOf(alice));
        console.log("Vault Shares (Dead):", vault.balanceOf(address(0x000000000000000000000000000000000000dEaD)));
        console.log("Strategy Shares (Vault):", strategy.balanceOf(address(vault)));

        console.log("aUSDC Balance (Strategy):", aUsdc.balanceOf(address(strategy)));

        console.log("Vault Total Supply:", vault.totalSupply());
        console.log("Strategy Total Supply:", strategy.totalSupply());

        console.log("Vault Total Managed Assets:", vault.totalAssets());
        console.log("Strategy Total Managed Assets:", strategy.totalAssets());
    }

    function test_RedeemDivestsFromAave() public {
        uint256 depositAmount = 5000e6;

        // Deposit
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        
        // Check Strategy Balance BEFORE time travel
        uint256 strategyAssetsBefore = strategy.totalAssets();
        console.log("Strategy Total Managed Assets Initial:", strategyAssetsBefore);

        // Time travel 1 day
        vm.roll(block.number + 7200);
        vm.warp(block.timestamp + 1 days); 

        // Check Strategy Balance AFTER time travel
        uint256 strategyAssetsAfter = strategy.totalAssets();
        console.log("Strategy Total Managed Assets After 1 Day:", strategyAssetsAfter);
        console.log("Yield Generated:", strategyAssetsAfter - strategyAssetsBefore); 

        // Check Vault has accumulated yield conceptually (via Strategy)
        uint256 assetsPerShare = vault.convertToAssets(1e18);
        assertGt(assetsPerShare, 1e18, "Share price should increase");

        // REDEEM half of shares
        uint256 sharesToRedeem = depositAmount / 2; // 2500 shares
        vault.redeem(sharesToRedeem, alice, alice);
        vm.stopPrank();

        // Check Specific Logic: Alice Balance (Principal + Yield)
        uint256 expectedPrincipal = 2500e6; 
        uint256 aliceBalance = usdc.balanceOf(alice);
        uint256 aliceInitial = 100_000e6;
        uint256 aliceSpent = 5000e6;
        assertGt(aliceBalance, aliceInitial - aliceSpent + expectedPrincipal, "Alice should receive principal + yield");
        
        // Check Specific Logic: Alice Remaining Shares
        assertEq(vault.balanceOf(alice), 2500e6, "Alice should have exactly half shares remaining");

        // --- System Invariants Check ---

        // Underlying Assets (Physical Balance)
        // Buffer consumed (>1000 assets redeemed)
        assertEq(usdc.balanceOf(address(vault)), 0, "Vault should hold 0 underlying (buffer used)");
        assertEq(usdc.balanceOf(address(strategy)), 0, "Strategy should hold 0 underlying");

        // Shares Ownership
        assertEq(vault.totalSupply(), vault.balanceOf(alice) + vault.balanceOf(address(0x000000000000000000000000000000000000dEaD)), "Vault Total Supply Invariant");
        assertEq(strategy.totalSupply(), strategy.balanceOf(address(vault)), "Strategy Total Supply Invariant");

        // Managed Assets
        // Buffer consumed -> Identical assets (allow 1 wei rounding)
        assertApproxEqAbs(vault.totalAssets(), strategy.totalAssets(), 1, "Vault vs Strategy Assets Invariant (Equal)");

        console.log("\n--- Final State Report (Redeem) ---");
        
        console.log("Underlying Asset Held (Alice):", usdc.balanceOf(alice));
        console.log("Underlying Asset Held (Vault):", usdc.balanceOf(address(vault)));
        console.log("Underlying Asset Held (Strategy):", usdc.balanceOf(address(strategy)));
        
        console.log("Vault Shares (Alice):", vault.balanceOf(alice));
        console.log("Vault Shares (Dead):", vault.balanceOf(address(0x000000000000000000000000000000000000dEaD)));
        console.log("Strategy Shares (Vault):", strategy.balanceOf(address(vault)));

        console.log("aUSDC Balance (Strategy):", aUsdc.balanceOf(address(strategy)));

        console.log("Vault Total Supply:", vault.totalSupply());
        console.log("Strategy Total Supply:", strategy.totalSupply());

        console.log("Vault Total Managed Assets:", vault.totalAssets());
        console.log("Strategy Total Managed Assets:", strategy.totalAssets());
    }
}
