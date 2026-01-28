// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "../../src/interfaces/aave/IPool.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";

/**
 * @title WETHLoopStrategyErrorPathsTest
 * @notice Tests error paths and edge cases for WETHLoopStrategy.
 * @dev Focuses on error handling, invalid states, and boundary conditions.
 */
contract WETHLoopStrategyErrorPathsTest is Test {
    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    WETHLoopStrategy strategy;
    YieldBearingVault vault;
    IERC20 weth;
    address resolvedPool;

    address vaultOwner;
    address vaultAdmin;
    address attacker;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address constant WETH_MAINNET = Constants.ETHEREUM_MAINNET_WETH;
    address constant AAVE_V3_POOL = Constants.ETHEREUM_MAINNET_AAVE_V3_POOL;
    address constant AWETH_TOKEN = Constants.ETHEREUM_MAINNET_AAVE_V3_WETH_ATOKEN;
    address constant VARIABLE_DEBT_WETH = Constants.ETHEREUM_MAINNET_AAVE_V3_WETH_VARIABLE_DEBT;
    address constant UNISWAP_V4_POOL_MANAGER = Constants.UNISWAP_V4_POOL_MANAGER;
    address constant AAVE_ADDRESS_PROVIDER = Constants.ETHEREUM_MAINNET_AAVE_V3_ADDRESS_PROVIDER;

    uint256 constant INITIAL_DEPOSIT = 1000;
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
        attacker = makeAddr("attacker");

        // ============ FORK MAINNET ============
        vm.createSelectFork(vm.envString("ETHEREUM_MAINNET_RPC"));

        weth = IERC20(WETH_MAINNET);

        // ============ FUND UNISWAP V4 ============
        deal(address(weth), UNISWAP_V4_POOL_MANAGER, 10_000 ether);

        // ============ DEPLOY VAULT ============
        vm.startPrank(vaultOwner);
        deal(address(weth), vaultOwner, INITIAL_DEPOSIT);
        address vaultAddr = vm.computeCreateAddress(vaultOwner, vm.getNonce(vaultOwner));
        weth.approve(vaultAddr, INITIAL_DEPOSIT);
        vault = new YieldBearingVault(weth, vaultOwner, vaultAdmin, INITIAL_DEPOSIT);
        vm.stopPrank();

        // ============ RESOLVE AAVE POOL ============
        (bool success, bytes memory data) = AAVE_ADDRESS_PROVIDER.staticcall(abi.encodeWithSignature("getPool()"));
        require(success, "getPool failed");
        resolvedPool = abi.decode(data, (address));

        // ============ DEPLOY STRATEGY ============
        strategy = new WETHLoopStrategy(
            weth,
            address(vault),
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
        vault.setStrategy(strategy);
    }

    /*//////////////////////////////////////////////////////////////
                       FLASH LOAN CALLBACK TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that unlockCallback reverts if not called by pool manager.
     */
    function test_UnlockCallback_RevertIfNotPoolManager() public {
        // ============ ACT & ASSERT ============
        vm.prank(attacker);
        vm.expectRevert();
        strategy.unlockCallback(abi.encode(address(strategy), 1 ether, true));
    }

    /*//////////////////////////////////////////////////////////////
                       WITHDRAWAL ERROR PATHS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests withdrawal when strategy has no position reverts.
     */
    function test_Withdraw_WithNoPosition_Reverts() public {
        // ============ ARRANGE: FUND VAULT ============
        deal(address(weth), address(vault), 1 ether);

        // ============ ACT & ASSERT: WITHDRAWAL REVERTS ============
        vm.prank(address(vault));
        vm.expectRevert();
        strategy.withdraw(0.1 ether, address(vault), address(vault));
    }

    /**
     * @notice Tests redeem when strategy has no shares.
     */
    function test_Redeem_WithNoShares() public {
        // ============ ACT ============
        vm.prank(address(vault));
        uint256 assets = strategy.redeem(0, address(vault), address(vault));

        // ============ ASSERT ============
        assertEq(assets, 0, "Should return 0 assets when redeeming 0 shares");
    }

    /*//////////////////////////////////////////////////////////////
                       TOTAL ASSETS EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests totalAssets when strategy has no position.
     */
    function test_TotalAssets_NoPosition() public {
        // ============ ACT ============
        uint256 totalAssets = strategy.totalAssets();

        // ============ ASSERT ============
        assertEq(totalAssets, 0, "Total assets should be 0 with no position");
    }

    /**
     * @notice Tests totalAssets calculation with debt.
     */
    function test_TotalAssets_WithDebt() public {
        // ============ ARRANGE: CREATE POSITION ============
        deal(address(weth), address(vault), 1 ether);

        vm.startPrank(address(vault));
        weth.approve(address(strategy), 1 ether);
        strategy.deposit(1 ether, address(vault));
        vm.stopPrank();

        // ============ ACT ============
        uint256 totalAssets = strategy.totalAssets();

        // ============ ASSERT ============
        // Should return approximately the deposited amount (net position)
        assertApproxEqAbs(totalAssets, 1 ether, 0.01 ether, "Total assets should reflect net position");
    }

    /*//////////////////////////////////////////////////////////////
                       PREVIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests previewDeposit with zero amount.
     */
    function test_PreviewDeposit_Zero() public {
        // ============ ACT ============
        uint256 shares = strategy.previewDeposit(0);

        // ============ ASSERT ============
        assertEq(shares, 0, "Preview deposit of 0 should return 0 shares");
    }

    /**
     * @notice Tests previewWithdraw with zero amount.
     */
    function test_PreviewWithdraw_Zero() public {
        // ============ ACT ============
        uint256 shares = strategy.previewWithdraw(0);

        // ============ ASSERT ============
        assertEq(shares, 0, "Preview withdraw of 0 should return 0 shares");
    }

    /**
     * @notice Tests previewMint with zero shares.
     */
    function test_PreviewMint_Zero() public {
        // ============ ACT ============
        uint256 assets = strategy.previewMint(0);

        // ============ ASSERT ============
        assertEq(assets, 0, "Preview mint of 0 shares should require 0 assets");
    }

    /**
     * @notice Tests previewRedeem with zero shares.
     */
    function test_PreviewRedeem_Zero() public {
        // ============ ACT ============
        uint256 assets = strategy.previewRedeem(0);

        // ============ ASSERT ============
        assertEq(assets, 0, "Preview redeem of 0 shares should return 0 assets");
    }

    /*//////////////////////////////////////////////////////////////
                       MAX FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests maxDeposit returns max uint256.
     */
    function test_MaxDeposit() public {
        // ============ ACT ============
        uint256 maxDep = strategy.maxDeposit(address(vault));

        // ============ ASSERT ============
        assertEq(maxDep, type(uint256).max, "Max deposit should be max uint256");
    }

    /**
     * @notice Tests maxMint returns max uint256.
     */
    function test_MaxMint() public {
        // ============ ACT ============
        uint256 maxMnt = strategy.maxMint(address(vault));

        // ============ ASSERT ============
        assertEq(maxMnt, type(uint256).max, "Max mint should be max uint256");
    }

    /**
     * @notice Tests maxWithdraw when strategy has position.
     */
    function test_MaxWithdraw_WithPosition() public {
        // ============ ARRANGE: CREATE POSITION ============
        deal(address(weth), address(vault), 1 ether);

        vm.startPrank(address(vault));
        weth.approve(address(strategy), 1 ether);
        strategy.deposit(1 ether, address(vault));
        vm.stopPrank();

        // ============ ACT ============
        uint256 maxWith = strategy.maxWithdraw(address(vault));

        // ============ ASSERT ============
        assertGt(maxWith, 0, "Max withdraw should be greater than 0 with position");
    }

    /**
     * @notice Tests maxRedeem when strategy has shares.
     */
    function test_MaxRedeem_WithShares() public {
        // ============ ARRANGE: CREATE POSITION ============
        deal(address(weth), address(vault), 1 ether);

        vm.startPrank(address(vault));
        weth.approve(address(strategy), 1 ether);
        strategy.deposit(1 ether, address(vault));
        vm.stopPrank();

        // ============ ACT ============
        uint256 maxRed = strategy.maxRedeem(address(vault));

        // ============ ASSERT ============
        assertGt(maxRed, 0, "Max redeem should be greater than 0 with shares");
        assertEq(maxRed, strategy.balanceOf(address(vault)), "Max redeem should equal balance");
    }

    /*//////////////////////////////////////////////////////////////
                       CONVERT FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests convertToShares with zero assets.
     */
    function test_ConvertToShares_Zero() public {
        // ============ ACT ============
        uint256 shares = strategy.convertToShares(0);

        // ============ ASSERT ============
        assertEq(shares, 0, "Convert 0 assets should return 0 shares");
    }

    /**
     * @notice Tests convertToAssets with zero shares.
     */
    function test_ConvertToAssets_Zero() public {
        // ============ ACT ============
        uint256 assets = strategy.convertToAssets(0);

        // ============ ASSERT ============
        assertEq(assets, 0, "Convert 0 shares should return 0 assets");
    }

    /**
     * @notice Tests conversion accuracy after deposit.
     */
    function test_ConvertAccuracy_AfterDeposit() public {
        // ============ ARRANGE: CREATE POSITION ============
        deal(address(weth), address(vault), 1 ether);

        vm.startPrank(address(vault));
        weth.approve(address(strategy), 1 ether);
        uint256 shares = strategy.deposit(1 ether, address(vault));
        vm.stopPrank();

        // ============ ACT ============
        uint256 assets = strategy.convertToAssets(shares);

        // ============ ASSERT ============
        // Should convert back to approximately the original deposit
        assertApproxEqAbs(assets, 1 ether, 0.01 ether, "Conversion should be accurate");
    }

    /*//////////////////////////////////////////////////////////////
                       IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that immutable values are set correctly.
     */
    function test_ImmutableValues() public {
        // ============ ASSERT ============
        assertEq(strategy.vault(), address(vault), "Vault address should be set");
        assertEq(address(strategy.asset()), WETH_MAINNET, "Asset should be WETH");
        assertEq(strategy.targetLeverage(), TARGET_LEVERAGE, "Target leverage should be set");
        assertEq(strategy.minHealthFactor(), MIN_HEALTH_FACTOR, "Min health factor should be set");
        assertEq(strategy.targetHealthFactor(), TARGET_HEALTH_FACTOR, "Target health factor should be set");
    }

    /**
     * @notice Tests emergency mode propagation.
     */
    function test_EmergencyMode_Propagates() public {
        // ============ ACT: SET EMERGENCY MODE ============
        vm.prank(vaultAdmin);
        vault.setEmergencyMode(true);

        // ============ ASSERT ============
        assertTrue(vault.emergencyMode(), "Vault emergency mode should be true");
        assertTrue(strategy.emergencyMode(), "Strategy emergency mode should be true");
    }
}
