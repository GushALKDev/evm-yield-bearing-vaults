// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {AaveSimpleLendingStrategy} from "../../src/strategies/AaveSimpleLendingStrategy.sol";
import {IPool} from "../../src/interfaces/aave/IPool.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {VaultDeployer} from "./VaultDeployer.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {MockAToken} from "../mocks/MockAToken.sol";
import {MockVariableDebtToken} from "../mocks/MockVariableDebtToken.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/**
 * @title StrategyTestBase
 * @notice Shared setup for strategy regression tests that run in both mock and fork mode.
 * @dev Mock mode uses the contracts in test/mocks. Fork mode uses Aave V3 and the Uniswap V4
 *      PoolManager at FORK_BLOCK, with the PoolManager's real WETH balance (no deal).
 */
abstract contract StrategyTestBase is Test {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant INITIAL_DEPOSIT = 1000;
    uint8 internal constant TARGET_LEVERAGE = 10;
    uint256 internal constant MIN_HEALTH_FACTOR = 1.02e18;
    uint256 internal constant TARGET_HEALTH_FACTOR = 1.05e18;
    uint8 internal constant EMODE_ETH_CORRELATED = 1;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    IERC20 internal weth;
    address internal aavePool;
    address internal poolManager;
    address internal aToken;
    address internal debtToken;

    MockWETH internal mockWeth;
    MockAavePool internal mockPool;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function _useFork() internal pure virtual returns (bool);

    /**
     * @dev Mock mode deploys MockAavePool unless a test passes its own pool subclass.
     */
    function _setUpProtocol(MockAavePool customPool) internal {
        if (_useFork()) {
            ForkConfig.selectMainnetFork();
            weth = IERC20(Constants.ETHEREUM_MAINNET_WETH);
            aavePool = Constants.ETHEREUM_MAINNET_AAVE_V3_POOL;
            poolManager = Constants.UNISWAP_V4_POOL_MANAGER;
            aToken = Constants.ETHEREUM_MAINNET_AAVE_V3_WETH_ATOKEN;
            debtToken = Constants.ETHEREUM_MAINNET_AAVE_V3_WETH_VARIABLE_DEBT;
            return;
        }

        mockWeth = new MockWETH();
        mockPool = address(customPool) == address(0) ? new MockAavePool() : customPool;
        MockPoolManager manager = new MockPoolManager();
        MockAToken mockAToken = new MockAToken("Aave WETH", "aWETH", address(mockPool));
        MockVariableDebtToken mockDebtToken = new MockVariableDebtToken("Aave Variable Debt WETH", "variableDebtWETH", address(mockPool));

        mockPool.setAToken(address(mockWeth), mockAToken);
        mockPool.setDebtToken(address(mockWeth), mockDebtToken);
        mockPool.setPrimaryAsset(address(mockWeth));
        mockWeth.mint(address(manager), 10_000 ether);
        mockWeth.mint(address(mockPool), 10_000 ether);

        weth = IERC20(address(mockWeth));
        aavePool = address(mockPool);
        poolManager = address(manager);
        aToken = address(mockAToken);
        debtToken = address(mockDebtToken);
    }

    /*//////////////////////////////////////////////////////////////
                               DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function _deployVault() internal returns (YieldBearingVault vault) {
        _fund(owner, INITIAL_DEPOSIT);
        vm.startPrank(owner);
        VaultDeployer vaultDeployer = new VaultDeployer();
        weth.approve(address(vaultDeployer), INITIAL_DEPOSIT);
        vault = vaultDeployer.deploy(weth, owner, admin, INITIAL_DEPOSIT);
        vault.addToWhitelist(alice);
        vault.addToWhitelist(bob);
        vm.stopPrank();
    }

    function _deployWethLoop() internal returns (YieldBearingVault vault, WETHLoopStrategy strategy) {
        vault = _deployVault();
        strategy = new WETHLoopStrategy(weth, address(vault), poolManager, aavePool, aToken, debtToken, TARGET_LEVERAGE, MIN_HEALTH_FACTOR, TARGET_HEALTH_FACTOR, EMODE_ETH_CORRELATED);
        vm.prank(admin);
        vault.setStrategy(strategy);
    }

    function _deployAaveSimple() internal returns (YieldBearingVault vault, AaveSimpleLendingStrategy strategy) {
        vault = _deployVault();
        strategy = new AaveSimpleLendingStrategy(weth, address(vault), aavePool, aToken);
        vm.prank(admin);
        vault.setStrategy(strategy);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fund(address account, uint256 amount) internal {
        if (_useFork()) {
            deal(address(weth), account, weth.balanceOf(account) + amount);
        } else {
            mockWeth.mint(account, amount);
        }
    }

    function _deposit(YieldBearingVault vault, address user, uint256 amount) internal returns (uint256 shares) {
        _fund(user, amount);
        vm.startPrank(user);
        weth.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _redeemAll(YieldBearingVault vault, address user) internal returns (uint256 received) {
        uint256 balanceBefore = weth.balanceOf(user);
        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        vault.redeem(shares, user, user);
        received = weth.balanceOf(user) - balanceBefore;
    }

    /**
     * @dev Raises minHealthFactor above the current health factor so checkHealth() triggers an emergency divest.
     */
    function _makeUnhealthy(WETHLoopStrategy strategy) internal {
        (,,,,, uint256 healthFactor) = IPool(aavePool).getUserAccountData(address(strategy));
        vm.prank(admin);
        strategy.setHealthFactors(healthFactor + 0.05e18, healthFactor + 0.08e18);
    }

    /**
     * @dev Vault equity from raw balances: vault idle + strategy collateral + strategy idle - strategy debt.
     */
    function _rawEquity(YieldBearingVault vault, address strategy) internal view returns (uint256) {
        uint256 assets = weth.balanceOf(address(vault)) + IERC20(aToken).balanceOf(strategy) + weth.balanceOf(strategy);
        uint256 debt = IERC20(debtToken).balanceOf(strategy);
        return assets > debt ? assets - debt : 0;
    }
}
