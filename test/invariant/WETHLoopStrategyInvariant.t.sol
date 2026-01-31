// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {InvariantBase} from "./InvariantBase.sol";
import {WETHLoopStrategyHandler} from "./handlers/WETHLoopStrategyHandler.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "../../src/interfaces/aave/IPool.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {MockAToken} from "../mocks/MockAToken.sol";
import {MockVariableDebtToken} from "../mocks/MockVariableDebtToken.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/**
 * @title WETHLoopStrategyInvariantTest
 * @notice Stateful invariant tests for WETHLoopStrategy leveraged positions.
 * @dev Supports both mock and fork modes via INVARIANT_USE_FORK env variable.
 *
 *      Mock Mode (default): Uses mock contracts to avoid RPC rate limiting.
 *      Fork Mode: Tests against real Aave V3 and Uniswap V4 on mainnet fork.
 *
 *      Usage:
 *      - Mock mode: forge test --match-path "test/invariant/WETHLoopStrategyInvariant.t.sol"
 *      - Fork mode: INVARIANT_USE_FORK=true forge test --match-path "test/invariant/WETHLoopStrategyInvariant.t.sol" --profile fork-invariant
 */
contract WETHLoopStrategyInvariantTest is InvariantBase {
    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint8 constant TARGET_LEVERAGE = 10;
    uint256 constant MIN_HEALTH_FACTOR = 1.02e18;
    uint256 constant TARGET_HEALTH_FACTOR = 1.05e18;
    uint8 constant EMODE_ETH_CORRELATED = 1;

    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    // Mock contracts (used when useFork = false)
    MockWETH public mockWeth;
    MockAavePool public mockAavePool;
    MockAToken public mockAToken;
    MockVariableDebtToken public mockDebtToken;
    MockPoolManager public mockPoolManager;

    // Shared references (point to mocks or real contracts depending on mode)
    IERC20 public weth;
    IPool public aavePool;
    address public aToken;
    address public debtToken;
    address public poolManager;

    YieldBearingVault public vault;
    WETHLoopStrategy public strategy;

    WETHLoopStrategyHandler public strategyHandler;

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        _createActors();
        _detectForkMode();

        if (useFork) {
            _setUpFork();
        } else {
            _setUpMock();
        }

        _deployVaultAndStrategy();
        _configureVault();
        _createHandler();
        _configureInvariantTesting();
    }

    function _setUpFork() internal {
        _createFork();

        weth = IERC20(Constants.ETHEREUM_MAINNET_WETH);
        aavePool = IPool(Constants.ETHEREUM_MAINNET_AAVE_V3_POOL);
        aToken = Constants.ETHEREUM_MAINNET_AAVE_V3_WETH_ATOKEN;
        debtToken = Constants.ETHEREUM_MAINNET_AAVE_V3_WETH_VARIABLE_DEBT;
        poolManager = Constants.UNISWAP_V4_POOL_MANAGER;

        // Fund Uniswap V4 PoolManager for flash loans
        deal(address(weth), poolManager, 10_000 ether);
    }

    function _setUpMock() internal {
        mockWeth = new MockWETH();
        mockAavePool = new MockAavePool();
        mockPoolManager = new MockPoolManager();

        mockAToken = new MockAToken("Aave WETH", "aWETH", address(mockAavePool));
        mockDebtToken = new MockVariableDebtToken("Aave Variable Debt WETH", "variableDebtWETH", address(mockAavePool));

        // Configure mock Aave pool
        mockAavePool.setAToken(address(mockWeth), mockAToken);
        mockAavePool.setDebtToken(address(mockWeth), mockDebtToken);
        mockAavePool.setPrimaryAsset(address(mockWeth));

        // Fund mock pool manager for flash loans
        mockWeth.mint(address(mockPoolManager), 10_000 ether);

        // Fund mock Aave pool for borrows
        mockWeth.mint(address(mockAavePool), 10_000 ether);

        // Set shared references to mocks
        weth = IERC20(address(mockWeth));
        aavePool = IPool(address(mockAavePool));
        aToken = address(mockAToken);
        debtToken = address(mockDebtToken);
        poolManager = address(mockPoolManager);
    }

    function _deployVaultAndStrategy() internal {
        vm.startPrank(owner);

        if (useFork) {
            deal(address(weth), owner, INITIAL_DEPOSIT);
        } else {
            mockWeth.mint(owner, INITIAL_DEPOSIT);
        }

        address predictedVault = vm.computeCreateAddress(owner, vm.getNonce(owner));
        weth.approve(predictedVault, INITIAL_DEPOSIT);
        vault = new YieldBearingVault(weth, owner, admin, INITIAL_DEPOSIT);
        vm.stopPrank();

        strategy = new WETHLoopStrategy(
            weth,
            address(vault),
            poolManager,
            address(aavePool),
            aToken,
            debtToken,
            TARGET_LEVERAGE,
            MIN_HEALTH_FACTOR,
            TARGET_HEALTH_FACTOR,
            EMODE_ETH_CORRELATED
        );
    }

    function _configureVault() internal {
        vm.startPrank(admin);
        vault.setStrategy(strategy);
        vault.setFeeRecipient(feeRecipient);
        vm.stopPrank();

        vm.startPrank(owner);
        for (uint256 i = 0; i < actors.length; i++) {
            vault.addToWhitelist(actors[i]);
        }
        vm.stopPrank();
    }

    function _createHandler() internal {
        strategyHandler = new WETHLoopStrategyHandler(
            vault,
            strategy,
            weth,
            aavePool,
            aToken,
            debtToken,
            actors,
            admin,
            owner
        );
    }

    function _configureInvariantTesting() internal {
        targetContract(address(strategyHandler));

        excludeSender(owner);
        excludeSender(admin);
        excludeSender(feeRecipient);
        excludeSender(address(vault));
        excludeSender(address(strategy));
        excludeSender(DEAD_ADDRESS);
        excludeSender(address(aavePool));
        excludeSender(poolManager);
    }

    /*//////////////////////////////////////////////////////////////
                         INVARIANT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Leverage ratio stays within safe bounds (max 14x).
    function invariant_LeverageWithinBounds() public view {
        uint256 collateral = IERC20(aToken).balanceOf(address(strategy));
        uint256 debt = IERC20(debtToken).balanceOf(address(strategy));

        if (collateral == 0 || collateral <= debt) return;

        uint256 leverage = (collateral * 100) / (collateral - debt);

        assertTrue(leverage <= 1400, "Leverage exceeds 14x maximum");
    }

    /// @notice Health factor never drops below minimum (except during emergency).
    function invariant_HealthFactorSafe() public view {
        if (vault.emergencyMode()) return;

        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(strategy));

        if (healthFactor == 0 || healthFactor == type(uint256).max) return;

        assertGe(healthFactor, MIN_HEALTH_FACTOR - 0.01e18, "Health factor below minimum");
    }

    /// @notice Total assets equals aToken - debt + WETH balance.
    function invariant_TotalAssetsCalculation() public view {
        uint256 aTokenBalance = IERC20(aToken).balanceOf(address(strategy));
        uint256 debtBalance = IERC20(debtToken).balanceOf(address(strategy));
        uint256 wethBalance = weth.balanceOf(address(strategy));

        uint256 expectedAssets;
        if (aTokenBalance > debtBalance) {
            expectedAssets = aTokenBalance - debtBalance + wethBalance;
        } else {
            expectedAssets = wethBalance;
        }

        uint256 reportedAssets = strategy.totalAssets();

        assertApproxEqAbs(reportedAssets, expectedAssets, 100, "Total assets calculation mismatch");
    }

    /// @notice After emergency divest, debt is fully repaid.
    function invariant_EmergencyDivestClosesPosition() public view {
        if (!vault.emergencyMode()) return;

        uint256 debt = IERC20(debtToken).balanceOf(address(strategy));

        assertLt(debt, 100, "Debt remains after emergency divest");
    }

    /// @notice Vault and strategy emergency modes are synchronized.
    function invariant_EmergencyModeSynchronized() public view {
        assertEq(vault.emergencyMode(), strategy.emergencyMode(), "Emergency mode mismatch between vault and strategy");
    }

    /// @notice Strategy only accepts deposits from vault.
    function invariant_StrategyVaultBinding() public view {
        assertEq(strategy.VAULT(), address(vault), "Strategy vault binding incorrect");
    }

    /// @notice Maximum observed leverage is tracked and within bounds.
    function invariant_MaxLeverageTracked() public view {
        uint256 maxLeverage = strategyHandler.ghost_maxLeverageObserved();

        if (maxLeverage > 0) {
            assertLe(maxLeverage, 1400, "Max leverage exceeded 14x");
        }
    }

    /// @notice Position value consistency through operations.
    function invariant_PositionValueConsistency() public view {
        uint256 totalInvested = strategyHandler.ghost_totalInvested();
        uint256 totalDivested = strategyHandler.ghost_totalDivested();
        uint256 currentAssets = strategy.totalAssets();

        if (totalInvested > 0) {
            uint256 minExpected = (totalInvested * 90) / 100;

            assertGe(
                currentAssets + totalDivested + INITIAL_DEPOSIT,
                minExpected > 1 ether ? minExpected - 1 ether : 0,
                "Position value lost unexpectedly"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                         CALL SUMMARY
    //////////////////////////////////////////////////////////////*/

    function invariant_CallSummary() public view {
        console2.log("=== Strategy Handler Stats ===");
        console2.log("Total Invested:", strategyHandler.ghost_totalInvested());
        console2.log("Total Divested:", strategyHandler.ghost_totalDivested());
        console2.log("Health Check Calls:", strategyHandler.ghost_healthCheckCalls());
        console2.log("Health Check Failures:", strategyHandler.ghost_healthCheckFailures());
        console2.log("Emergency Divest Count:", strategyHandler.ghost_emergencyDivestCount());
        console2.log("Max Leverage Observed:", strategyHandler.ghost_maxLeverageObserved());
        console2.log("Min Health Factor Observed:", strategyHandler.ghost_minHealthFactorObserved());
        console2.log("Last Collateral:", strategyHandler.ghost_lastCollateral());
        console2.log("Last Debt:", strategyHandler.ghost_lastDebt());
        console2.log("Last Health Factor:", strategyHandler.ghost_lastHealthFactor());
    }
}
