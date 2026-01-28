// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {WETHLoopStrategy} from "../src/strategies/WETHLoopStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "../src/interfaces/aave/IPool.sol";
import {Constants} from "../src/utils/Constants.sol";
import {YieldBearingVault} from "../src/vaults/YieldBearingVault.sol";

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

    /** @notice Uniswap V4 PoolManager for flash loans. */
    address constant UNISWAP_V4_POOL_MANAGER = Constants.UNISWAP_V4_POOL_MANAGER;

    /** @notice Aave V3 Pool Address Provider. */
    address constant AAVE_ADDRESS_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

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
}
