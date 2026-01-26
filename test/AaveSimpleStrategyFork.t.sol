// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BetaVault} from "../src/vaults/BetaVault.sol";
import {AaveSimpleLendingStrategy} from "../src/strategies/AaveSimpleLendingStrategy.sol";

import {Constants} from "../src/utils/Constants.sol";

contract AaveSimpleStrategyForkTest is Test {
    
    // Mainnet Addresses via Constants
    address constant USDC = Constants.MAINNET_USDC;
    address constant AAVE_POOL = Constants.MAINNET_AAVE_V3_POOL;
    address constant A_USDC = Constants.MAINNET_AAVE_V3_USDC_ATOKEN;

    BetaVault vault;
    AaveSimpleLendingStrategy strategy;
    IERC20 usdc;
    IERC20 aUsdc;

    address alice = makeAddr("alice");
    address owner = makeAddr("owner");

    uint256 INITIAL_DEPOSIT = 1000e6; // 1000 USDC
    
    function setUp() public {
        // Fork Mainnet
        string memory rpcUrl = vm.envString("ETHEREUM_MAINNET_RPC");
        vm.createSelectFork(rpcUrl);

        usdc = IERC20(USDC);
        aUsdc = IERC20(A_USDC);

        // Fund Alice and Owner (for initial deposit)
        deal(USDC, alice, 100_000e6);
        deal(USDC, owner, 10_000e6);

        // Deploy Vault
        vm.startPrank(owner);
        // Initial deposit is 0, so no need to pre-approve
        vault = new BetaVault(usdc, owner, 0);
        
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

        // Check Vault State (Allow 1-2 wei rounding error)
        assertApproxEqAbs(vault.totalAssets(), depositAmount, 2, "Vault total assets should approx match deposit");
        
        // Check Strategy State (Integration)
        uint256 strategyBalance = strategy.totalAssets();
        assertApproxEqAbs(strategyBalance, depositAmount, 2, "Strategy balance should approx match deposit");

        // Verify tokens are actually in Aave (aToken balance of strategy)
        assertEq(aUsdc.balanceOf(address(strategy)), strategyBalance, "Strategy should hold aTokens");
        
        // Verify Vault holds 0 USDC (all moved to strategy)
        assertEq(usdc.balanceOf(address(vault)), 0, "Vault should hold 0 USDC");
    }

    function test_WithdrawDivestsFromAave() public {
        uint256 depositAmount = 5000e6;

        // Deposit
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        
        // Time travel to accrue some tiny interest (blocks in fork)
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 1200); // 20 mins

        // Check Balance before withdraw
        uint256 shareBalance = vault.balanceOf(alice);
        uint256 assetsBefore = vault.convertToAssets(shareBalance);
        
        // Withdraw half
        uint256 withdrawAmount = depositAmount / 2;
        vault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        // Check Vault still has 0 USDC (funds pulled and sent immediately)
        assertEq(usdc.balanceOf(address(vault)), 0, "Vault should hold 0 USDC after withdraw");

        // Check Alice received funds
        // She started with 100k, deposited 5k, withdrew 2.5k. 
        // Should have 100k - 5k + 2.5k = 97.5k
        assertEq(usdc.balanceOf(alice), 100_000e6 - depositAmount + withdrawAmount, "Alice should have correct USDC balance");
        
        // Check Strategy still has the rest
        uint256 remainingInStrategy = strategy.totalAssets();
        assertGe(remainingInStrategy, depositAmount - withdrawAmount, "Strategy should still have remaining funds");
    }
}
