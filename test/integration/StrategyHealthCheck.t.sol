// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {AaveSimpleLendingStrategy} from "../../src/strategies/AaveSimpleLendingStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "../../src/interfaces/aave/IPool.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";

/**
 * @title StrategyHealthCheckTest
 * @notice Tests for harvest() and checkHealth() functions in strategies.
 * @dev Fork tests that verify strategy health monitoring and harvesting mechanisms.
 */
contract StrategyHealthCheckTest is Test {
    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    WETHLoopStrategy wethStrategy;
    AaveSimpleLendingStrategy usdcStrategy;
    YieldBearingVault wethVault;
    YieldBearingVault usdcVault;

    IERC20 weth;
    IERC20 usdc;
    IPool aavePool;

    address vaultOwner;
    address vaultAdmin;
    address alice;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address constant WETH_MAINNET = Constants.ETHEREUM_MAINNET_WETH;
    address constant USDC_MAINNET = Constants.ETHEREUM_MAINNET_USDC;
    address constant AAVE_V3_POOL = Constants.ETHEREUM_MAINNET_AAVE_V3_POOL;
    address constant AWETH_TOKEN = Constants.ETHEREUM_MAINNET_AAVE_V3_WETH_ATOKEN;
    address constant AUSDC_TOKEN = Constants.ETHEREUM_MAINNET_AAVE_V3_USDC_ATOKEN;
    address constant VARIABLE_DEBT_WETH = Constants.ETHEREUM_MAINNET_AAVE_V3_WETH_VARIABLE_DEBT;
    address constant UNISWAP_V4_POOL_MANAGER = Constants.UNISWAP_V4_POOL_MANAGER;
    address constant AAVE_ADDRESS_PROVIDER = Constants.ETHEREUM_MAINNET_AAVE_V3_ADDRESS_PROVIDER;

    uint256 constant INITIAL_DEPOSIT = 1000;
    uint256 constant DEPOSIT_AMOUNT = 1 ether;
    uint256 constant USDC_DEPOSIT = 5000e6;

    uint8 constant TARGET_LEVERAGE = 10;
    uint256 constant MIN_HEALTH_FACTOR = 1.02e18;
    uint256 constant TARGET_HEALTH_FACTOR = 1.05e18;
    uint8 constant EMODE_ETH_CORRELATED = 1;

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // ============ CREATE TEST ADDRESSES ============
        vaultOwner = makeAddr("vaultOwner");
        vaultAdmin = makeAddr("vaultAdmin");
        alice = makeAddr("alice");

        // ============ FORK MAINNET ============
        vm.createSelectFork(vm.envString("ETHEREUM_MAINNET_RPC"));

        weth = IERC20(WETH_MAINNET);
        usdc = IERC20(USDC_MAINNET);
        aavePool = IPool(AAVE_V3_POOL);

        // ============ FUND UNISWAP V4 FOR FLASH LOANS ============
        deal(address(weth), UNISWAP_V4_POOL_MANAGER, 10_000 ether);

        // ============ DEPLOY WETH VAULT & STRATEGY ============
        vm.startPrank(vaultOwner);
        deal(address(weth), vaultOwner, INITIAL_DEPOSIT);
        address wethVaultAddr = vm.computeCreateAddress(vaultOwner, vm.getNonce(vaultOwner));
        weth.approve(wethVaultAddr, INITIAL_DEPOSIT);
        wethVault = new YieldBearingVault(weth, vaultOwner, vaultAdmin, INITIAL_DEPOSIT);
        vm.stopPrank();

        (bool success, bytes memory data) = AAVE_ADDRESS_PROVIDER.staticcall(abi.encodeWithSignature("getPool()"));
        require(success, "getPool failed");
        address resolvedPool = abi.decode(data, (address));

        wethStrategy = new WETHLoopStrategy(
            weth,
            address(wethVault),
            UNISWAP_V4_POOL_MANAGER,
            resolvedPool,
            AWETH_TOKEN,
            VARIABLE_DEBT_WETH,
            TARGET_LEVERAGE,
            MIN_HEALTH_FACTOR,
            TARGET_HEALTH_FACTOR,
            EMODE_ETH_CORRELATED
        );

        vm.prank(vaultAdmin);
        wethVault.setStrategy(wethStrategy);

        // ============ DEPLOY USDC VAULT & STRATEGY ============
        vm.startPrank(vaultOwner);
        deal(address(usdc), vaultOwner, INITIAL_DEPOSIT);
        address usdcVaultAddr = vm.computeCreateAddress(vaultOwner, vm.getNonce(vaultOwner));
        usdc.approve(usdcVaultAddr, INITIAL_DEPOSIT);
        usdcVault = new YieldBearingVault(usdc, vaultOwner, vaultAdmin, INITIAL_DEPOSIT);
        vm.stopPrank();

        usdcStrategy = new AaveSimpleLendingStrategy(usdc, address(usdcVault), AAVE_V3_POOL, AUSDC_TOKEN);

        vm.prank(vaultAdmin);
        usdcVault.setStrategy(usdcStrategy);

        // ============ SETUP ALICE ============
        vm.startPrank(vaultOwner);
        wethVault.addToWhitelist(alice);
        usdcVault.addToWhitelist(alice);
        vm.stopPrank();

        deal(address(weth), alice, 10 ether);
        deal(address(usdc), alice, 50_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                       WETH STRATEGY HEALTH TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that checkHealth() returns true for healthy position.
     */
    function test_WETHStrategy_CheckHealth_Healthy() public {
        // ============ ARRANGE: DEPOSIT ============
        vm.startPrank(alice);
        weth.approve(address(wethVault), DEPOSIT_AMOUNT);
        wethVault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ACT ============
        bool isHealthy = wethStrategy.checkHealth();

        // ============ ASSERT ============
        assertTrue(isHealthy, "Position should be healthy");

        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(wethStrategy));
        console.log("Health Factor:", healthFactor);
        assertGe(healthFactor, MIN_HEALTH_FACTOR, "Health factor should be above minimum");
    }

    /**
     * @notice Tests harvest function on WETH strategy reverts (Aave auto-compounds via aToken rebasing).
     * @dev Harvest should revert with StrategyNotHarvestable to signal backend not to call periodically.
     */
    function test_WETHStrategy_Harvest_Reverts() public {
        // ============ ARRANGE: DEPOSIT ============
        vm.startPrank(alice);
        weth.approve(address(wethVault), DEPOSIT_AMOUNT);
        wethVault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ACT & ASSERT: HARVEST REVERTS ============
        vm.prank(vaultAdmin);
        vm.expectRevert(abi.encodeWithSignature("StrategyNotHarvestable()"));
        wethStrategy.harvest();
    }

    /**
     * @notice Tests totalAssets calculation for WETH strategy.
     */
    function test_WETHStrategy_TotalAssets() public {
        // ============ ARRANGE: DEPOSIT ============
        vm.startPrank(alice);
        weth.approve(address(wethVault), DEPOSIT_AMOUNT);
        wethVault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // ============ ACT ============
        uint256 totalAssets = wethStrategy.totalAssets();

        // ============ ASSERT ============
        // Total assets should be approximately the deposited amount
        // Allow for small deviations due to leverage mechanics
        assertApproxEqAbs(totalAssets, DEPOSIT_AMOUNT, 0.01 ether, "Total assets should match deposit");
    }

    /*//////////////////////////////////////////////////////////////
                       USDC STRATEGY HEALTH TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that checkHealth() returns true for USDC strategy.
     */
    function test_USDCStrategy_CheckHealth() public {
        // ============ ARRANGE: DEPOSIT ============
        vm.startPrank(alice);
        usdc.approve(address(usdcVault), USDC_DEPOSIT);
        usdcVault.deposit(USDC_DEPOSIT, alice);
        vm.stopPrank();

        // ============ ACT ============
        bool isHealthy = usdcStrategy.checkHealth();

        // ============ ASSERT ============
        assertTrue(isHealthy, "USDC strategy should be healthy");
    }

    /**
     * @notice Tests harvest function on USDC strategy reverts.
     * @dev USDC strategy doesn't need harvest (aToken rebasing).
     */
    function test_USDCStrategy_Harvest_Reverts() public {
        // ============ ARRANGE: DEPOSIT ============
        vm.startPrank(alice);
        usdc.approve(address(usdcVault), USDC_DEPOSIT);
        usdcVault.deposit(USDC_DEPOSIT, alice);
        vm.stopPrank();

        // ============ ACT & ASSERT: HARVEST REVERTS ============
        vm.prank(vaultAdmin);
        vm.expectRevert(abi.encodeWithSignature("StrategyNotHarvestable()"));
        usdcStrategy.harvest();
    }

    /**
     * @notice Tests totalAssets calculation for USDC strategy.
     */
    function test_USDCStrategy_TotalAssets() public {
        // ============ ARRANGE: DEPOSIT ============
        vm.startPrank(alice);
        usdc.approve(address(usdcVault), USDC_DEPOSIT);
        usdcVault.deposit(USDC_DEPOSIT, alice);
        vm.stopPrank();

        // ============ ACT ============
        uint256 totalAssets = usdcStrategy.totalAssets();

        // ============ ASSERT ============
        // Total assets should match deposited amount (simple strategy, no leverage)
        assertApproxEqAbs(totalAssets, USDC_DEPOSIT, 10, "Total assets should match deposit");
    }

    /**
     * @notice Tests totalAssets increases with yield over time.
     */
    function test_USDCStrategy_TotalAssets_IncreasesWithYield() public {
        // ============ ARRANGE: DEPOSIT ============
        vm.startPrank(alice);
        usdc.approve(address(usdcVault), USDC_DEPOSIT);
        usdcVault.deposit(USDC_DEPOSIT, alice);
        vm.stopPrank();

        uint256 assetsBefore = usdcStrategy.totalAssets();

        // ============ ACT: TIME TRAVEL ============
        vm.roll(block.number + 7200); // ~1 day
        vm.warp(block.timestamp + 1 days);

        // ============ ASSERT ============
        uint256 assetsAfter = usdcStrategy.totalAssets();
        assertGt(assetsAfter, assetsBefore, "Assets should increase with yield");
    }

    /*//////////////////////////////////////////////////////////////
                       STRATEGY COMPARISON TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Compares behavior of both strategies.
     */
    function test_Strategies_BothHealthy() public {
        // ============ ARRANGE: DEPOSIT TO BOTH ============
        vm.startPrank(alice);
        weth.approve(address(wethVault), DEPOSIT_AMOUNT);
        wethVault.deposit(DEPOSIT_AMOUNT, alice);

        usdc.approve(address(usdcVault), USDC_DEPOSIT);
        usdcVault.deposit(USDC_DEPOSIT, alice);
        vm.stopPrank();

        // ============ ACT ============
        bool wethHealthy = wethStrategy.checkHealth();
        bool usdcHealthy = usdcStrategy.checkHealth();

        // ============ ASSERT ============
        assertTrue(wethHealthy, "WETH strategy should be healthy");
        assertTrue(usdcHealthy, "USDC strategy should be healthy");
    }

    /**
     * @notice Tests harvest behavior on both strategies (both use Aave, both auto-compound).
     * @dev Both strategies revert with StrategyNotHarvestable since Aave auto-compounds via aToken rebasing.
     */
    function test_Strategies_HarvestBehavior() public {
        // ============ ARRANGE: DEPOSIT TO BOTH ============
        vm.startPrank(alice);
        weth.approve(address(wethVault), DEPOSIT_AMOUNT);
        wethVault.deposit(DEPOSIT_AMOUNT, alice);

        usdc.approve(address(usdcVault), USDC_DEPOSIT);
        usdcVault.deposit(USDC_DEPOSIT, alice);
        vm.stopPrank();

        // ============ ACT & ASSERT: BOTH HARVEST REVERT ============
        vm.prank(vaultAdmin);
        vm.expectRevert(abi.encodeWithSignature("StrategyNotHarvestable()"));
        wethStrategy.harvest();

        vm.prank(vaultAdmin);
        vm.expectRevert(abi.encodeWithSignature("StrategyNotHarvestable()"));
        usdcStrategy.harvest();
    }
}
