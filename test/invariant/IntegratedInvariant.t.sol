// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {InvariantBase} from "./InvariantBase.sol";
import {BaseVaultHandler} from "./handlers/BaseVaultHandler.sol";
import {WETHLoopStrategyHandler} from "./handlers/WETHLoopStrategyHandler.sol";
import {AdminHandler} from "./handlers/AdminHandler.sol";
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
import {VaultDeployer} from "../utils/VaultDeployer.sol";

/**
 * @title IntegratedInvariantTest
 * @notice Full system integration invariant tests.
 * @dev Supports both mock and fork modes via INVARIANT_USE_FORK env variable.
 *
 *      Mock Mode (default): Uses mock contracts to avoid RPC rate limiting.
 *      Fork Mode: Tests against real Aave V3 and Uniswap V4 on mainnet fork.
 *
 *      Usage:
 *      - Mock mode: forge test --match-path "test/invariant/IntegratedInvariant.t.sol"
 *      - Fork mode: INVARIANT_USE_FORK=true forge test --match-path "test/invariant/IntegratedInvariant.t.sol" --profile fork-invariant
 */
contract IntegratedInvariantTest is InvariantBase {
    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint8 constant TARGET_LEVERAGE = 10;
    uint256 constant MIN_HEALTH_FACTOR = 1.02e18;
    uint256 constant TARGET_HEALTH_FACTOR = 1.05e18;
    uint8 constant EMODE_ETH_CORRELATED = 1;
    /// @dev Aave rounds scaled balances by up to 1 wei per supply, borrow, repay or withdraw. Exact in mock mode.
    uint256 constant AAVE_ROUNDING_PER_OP = 4;

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

    BaseVaultHandler public vaultHandler;
    WETHLoopStrategyHandler public strategyHandler;
    AdminHandler public adminHandler;

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
        _createHandlers();
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

        VaultDeployer vaultDeployer = new VaultDeployer();
        weth.approve(address(vaultDeployer), INITIAL_DEPOSIT);
        vault = vaultDeployer.deploy(weth, owner, admin, INITIAL_DEPOSIT);
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
        vm.prank(owner);
        vault.addToWhitelist(feeRecipient);

        vm.startPrank(admin);
        vault.setStrategy(strategy);
        vault.setFeeRecipient(feeRecipient);
        vault.setProtocolFee(1000);
        vm.stopPrank();

        vm.startPrank(owner);
        for (uint256 i = 0; i < actors.length; i++) {
            vault.addToWhitelist(actors[i]);
        }
        vm.stopPrank();
    }

    function _createHandlers() internal {
        vaultHandler = new BaseVaultHandler(vault, weth, actors, admin, owner);
        strategyHandler = new WETHLoopStrategyHandler(vault, strategy, weth, aavePool, aToken, debtToken, actors, admin, owner);
        adminHandler = new AdminHandler(vault, admin, owner, actors, aavePool);
    }

    function _configureInvariantTesting() internal {
        targetContract(address(vaultHandler));
        targetContract(address(strategyHandler));
        targetContract(address(adminHandler));

        bytes4[] memory vaultSelectors = new bytes4[](5);
        vaultSelectors[0] = BaseVaultHandler.deposit.selector;
        vaultSelectors[1] = BaseVaultHandler.withdraw.selector;
        vaultSelectors[2] = BaseVaultHandler.transfer.selector;
        vaultSelectors[3] = BaseVaultHandler.assessFee.selector;
        vaultSelectors[4] = BaseVaultHandler.simulateYield.selector;
        targetSelector(FuzzSelector({addr: address(vaultHandler), selectors: vaultSelectors}));

        bytes4[] memory strategySelectors = new bytes4[](6);
        strategySelectors[0] = WETHLoopStrategyHandler.deposit.selector;
        strategySelectors[1] = WETHLoopStrategyHandler.withdraw.selector;
        strategySelectors[2] = WETHLoopStrategyHandler.checkHealth.selector;
        strategySelectors[3] = WETHLoopStrategyHandler.warpTime.selector;
        strategySelectors[4] = WETHLoopStrategyHandler.triggerEmergency.selector;
        strategySelectors[5] = WETHLoopStrategyHandler.recover.selector;
        targetSelector(FuzzSelector({addr: address(strategyHandler), selectors: strategySelectors}));

        bytes4[] memory adminSelectors = new bytes4[](7);
        adminSelectors[0] = AdminHandler.addToWhitelist.selector;
        adminSelectors[1] = AdminHandler.removeFromWhitelist.selector;
        adminSelectors[2] = AdminHandler.setProtocolFee.selector;
        adminSelectors[3] = AdminHandler.toggleEmergencyMode.selector;
        adminSelectors[4] = AdminHandler.reinvest.selector;
        adminSelectors[5] = AdminHandler.setFeeRecipient.selector;
        adminSelectors[6] = AdminHandler.removeFeeRecipient.selector;
        targetSelector(FuzzSelector({addr: address(adminHandler), selectors: adminSelectors}));

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
                         INTEGRATED INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Vault total assets = vault idle balance + strategy total assets, within share conversion rounding.
    function invariant_VaultStrategyValueConsistency() public view {
        uint256 vaultAssets = vault.totalAssets();
        uint256 expected = weth.balanceOf(address(vault)) + strategy.totalAssets();

        assertApproxEqAbs(vaultAssets, expected, DUST_TOLERANCE, "Vault cannot account for strategy value");
    }

    /// @notice System-wide emergency mode consistency.
    function invariant_SystemEmergencyConsistency() public view {
        assertEq(vault.emergencyMode(), strategy.emergencyMode(), "System emergency mode inconsistent");
    }

    /// @notice Current assets + withdrawals = initial deposit + deposits + simulated yield + measured interest,
    ///         within rounding. Fees are paid in shares and do not change totalAssets().
    function invariant_NoValueLeak() public view {
        int256 inflows = int256(INITIAL_DEPOSIT + vaultHandler.ghost_totalDeposited() + strategyHandler.ghost_totalInvested() + vaultHandler.ghost_totalYield())
            + strategyHandler.ghost_interest();
        int256 outflows = int256(vaultHandler.ghost_totalWithdrawn() + strategyHandler.ghost_totalDivested());
        int256 accounted = int256(vault.totalAssets()) + outflows;

        uint256 operations = vaultHandler.ghost_depositCount() + vaultHandler.ghost_withdrawCount() + strategyHandler.ghost_equityOps()
            + adminHandler.ghost_emergencyModeChanges() + adminHandler.ghost_reinvests();
        uint256 tolerance = DUST_TOLERANCE + operations * AAVE_ROUNDING_PER_OP;

        assertApproxEqAbs(accounted, inflows, tolerance, "Value leaked from system");
    }

    /// @notice A successful reinvest leaves the health factor at or above targetHealthFactor.
    function invariant_ReinvestMeetsTargetHealthFactor() public view {
        assertEq(adminHandler.ghost_reinvestsBelowTarget(), 0, "Reinvest left the health factor below target");
    }

    /// @notice Protocol fee collection is bounded.
    function invariant_FeeBounded() public view {
        assertLe(vault.protocolFeeBps(), 2500, "Fee exceeds maximum");
    }

    /// @notice Whitelist integrity maintained.
    function invariant_WhitelistIntegrity() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            if (vault.balanceOf(actors[i]) > 0) {
                assertTrue(vault.isWhitelisted(actors[i]), "Non-whitelisted holds shares");
            }
        }
        // Fee shares, with no exception: the fee recipient holds them and must be whitelisted
        if (vault.balanceOf(feeRecipient) > 0) {
            assertTrue(vault.isWhitelisted(feeRecipient), "Non-whitelisted fee recipient holds shares");
        }
        address currentRecipient = vault.feeRecipient();
        if (currentRecipient != address(0)) {
            assertTrue(vault.isWhitelisted(currentRecipient), "Current fee recipient is not whitelisted");
        }
    }

    /// @notice Total supply consistency across system.
    function invariant_TotalSupplyConsistency() public view {
        uint256 totalSupply = vault.totalSupply();
        uint256 deadShares = vault.balanceOf(DEAD_ADDRESS);
        uint256 feeShares = vault.balanceOf(feeRecipient);

        uint256 userShares = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            userShares += vault.balanceOf(actors[i]);
        }

        assertEq(totalSupply, userShares + deadShares + feeShares, "Total supply mismatch");
    }

    /// @notice Leverage bounds in integrated environment.
    function invariant_LeverageWithinBounds() public view {
        uint256 collateral = IERC20(aToken).balanceOf(address(strategy));
        uint256 debt = IERC20(debtToken).balanceOf(address(strategy));

        if (collateral == 0 || collateral <= debt) return;

        uint256 leverage = (collateral * 100) / (collateral - debt);
        assertTrue(leverage <= 1400, "Leverage exceeds 14x maximum");
    }

    /// @notice Health factor safe in integrated environment.
    function invariant_HealthFactorSafe() public view {
        if (vault.emergencyMode()) return;

        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(strategy));
        if (healthFactor == 0 || healthFactor == type(uint256).max) return;

        assertGe(healthFactor, MIN_HEALTH_FACTOR - 0.01e18, "Health factor below minimum");
    }

    /*//////////////////////////////////////////////////////////////
                         CALL SUMMARY
    //////////////////////////////////////////////////////////////*/

    /// @notice Logs handler statistics after each run (Foundry hook, not an invariant).
    function afterInvariant() public view {
        console2.log("=== Integrated System Stats ===");
        console2.log("\n-- Vault Handler --");
        console2.log("Deposits:", vaultHandler.ghost_depositCount());
        console2.log("Withdrawals:", vaultHandler.ghost_withdrawCount());
        console2.log("Total Deposited:", vaultHandler.ghost_totalDeposited());
        console2.log("Total Withdrawn:", vaultHandler.ghost_totalWithdrawn());

        console2.log("\n-- Strategy Handler --");
        console2.log("Total Invested:", strategyHandler.ghost_totalInvested());
        console2.log("Total Divested:", strategyHandler.ghost_totalDivested());
        console2.log("Health Checks:", strategyHandler.ghost_healthCheckCalls());
        console2.log("Emergency Divests:", strategyHandler.ghost_emergencyDivestCount());
        console2.log("Max Leverage:", strategyHandler.ghost_maxLeverageObserved());

        console2.log("\n-- Admin Handler --");
        console2.log("Emergency Mode Changes:", adminHandler.ghost_emergencyModeChanges());
        console2.log("Reinvests:", adminHandler.ghost_reinvests());
        console2.log("Fee Changes:", adminHandler.ghost_feeChanges());
        console2.log("Whitelist Additions:", adminHandler.ghost_whitelistAdditions());
    }
}
