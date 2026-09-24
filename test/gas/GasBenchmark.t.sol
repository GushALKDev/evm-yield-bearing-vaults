// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {IPool} from "../../src/interfaces/aave/IPool.sol";
import {VaultDeployer} from "../utils/VaultDeployer.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {MockAToken} from "../mocks/MockAToken.sol";
import {MockVariableDebtToken} from "../mocks/MockVariableDebtToken.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/**
 * @title GasBenchmarkBase
 * @notice Gas benchmark scenarios for the vault and the WETH loop strategy.
 * @dev Measure with: forge test --match-contract <GasBenchmarkMockTest|GasBenchmarkForkTest> --gas-report
 *      setUp opens a 1 WETH position at 10x with vault.mint, so each measured function below
 *      (deposit, withdraw, redeem, setEmergencyMode) is called exactly once per scenario.
 *      checkHealth is called twice (emergency and recovery scenarios), both on the emergency divest path.
 */
abstract contract GasBenchmarkBase is Test {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant INITIAL_DEPOSIT = 1000;
    uint8 internal constant TARGET_LEVERAGE = 10;
    uint256 internal constant MIN_HEALTH_FACTOR = 1.02e18;
    uint256 internal constant TARGET_HEALTH_FACTOR = 1.05e18;
    uint8 internal constant EMODE_ETH_CORRELATED = 1;
    uint256 internal constant POSITION = 1 ether;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    IERC20 internal weth;
    address internal aavePool;
    address internal poolManager;
    address internal aToken;
    address internal debtToken;

    YieldBearingVault internal vault;
    WETHLoopStrategy internal strategy;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function _setUpProtocol() internal virtual;

    function _fund(address account, uint256 amount) internal virtual;

    function setUp() public {
        _setUpProtocol();

        _fund(owner, INITIAL_DEPOSIT);
        vm.startPrank(owner);
        VaultDeployer vaultDeployer = new VaultDeployer();
        weth.approve(address(vaultDeployer), INITIAL_DEPOSIT);
        vault = vaultDeployer.deploy(weth, owner, admin, INITIAL_DEPOSIT);
        vault.addToWhitelist(userA);
        vault.addToWhitelist(userB);
        vm.stopPrank();

        strategy = new WETHLoopStrategy(
            weth, address(vault), poolManager, aavePool, aToken, debtToken, TARGET_LEVERAGE, MIN_HEALTH_FACTOR, TARGET_HEALTH_FACTOR, EMODE_ETH_CORRELATED
        );
        vm.prank(admin);
        vault.setStrategy(strategy);

        _fund(userA, 10 ether);
        _fund(userB, 10 ether);
        vm.prank(userA);
        weth.approve(address(vault), type(uint256).max);
        vm.prank(userB);
        weth.approve(address(vault), type(uint256).max);

        // Opens the benchmark position with mint so the deposit row only contains the measured call
        uint256 shares = vault.previewDeposit(POSITION);
        vm.prank(userA);
        vault.mint(shares, userA);
    }

    /*//////////////////////////////////////////////////////////////
                               SCENARIOS
    //////////////////////////////////////////////////////////////*/

    /// @notice vault.deposit of 1 WETH into an existing 10x position.
    function test_Gas_DepositIntoExistingPosition() public {
        vm.prank(userB);
        vault.deposit(POSITION, userB);
    }

    /// @notice vault.withdraw of 0.5 WETH from a 1 WETH position (proportional deleverage).
    function test_Gas_Withdraw() public {
        vm.prank(userA);
        vault.withdraw(POSITION / 2, userA, userA);
    }

    /// @notice vault.redeem of all shares of the only depositor (full exit, position closed).
    function test_Gas_Redeem() public {
        uint256 shares = vault.balanceOf(userA);
        vm.prank(userA);
        vault.redeem(shares, userA, userA);
    }

    /// @notice strategy.checkHealth below minHealthFactor: emergency divest of 10 WETH collateral / 9 WETH debt.
    function test_Gas_CheckHealthEmergencyDivest() public {
        _raiseMinHealthFactor();
        strategy.checkHealth();
    }

    /// @notice vault.setEmergencyMode(false) after an emergency divest, then vault.reinvest of about 1 WETH at 10x.
    function test_Gas_Recovery() public {
        _raiseMinHealthFactor();
        strategy.checkHealth();
        vm.prank(admin);
        strategy.setHealthFactors(MIN_HEALTH_FACTOR, TARGET_HEALTH_FACTOR);
        vm.prank(admin);
        vault.setEmergencyMode(false);
        vm.prank(admin);
        vault.reinvest();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _raiseMinHealthFactor() internal {
        (,,,,, uint256 healthFactor) = IPool(aavePool).getUserAccountData(address(strategy));
        vm.prank(admin);
        strategy.setHealthFactors(healthFactor + 0.05e18, healthFactor + 0.08e18);
    }
}

/**
 * @title GasBenchmarkMockTest
 * @notice Gas benchmark against the mock Aave pool and mock PoolManager (no RPC needed).
 */
contract GasBenchmarkMockTest is GasBenchmarkBase {
    MockWETH internal mockWeth;

    function _setUpProtocol() internal override {
        mockWeth = new MockWETH();
        MockAavePool pool = new MockAavePool();
        MockPoolManager manager = new MockPoolManager();
        MockAToken mockAToken = new MockAToken("Aave WETH", "aWETH", address(pool));
        MockVariableDebtToken mockDebtToken = new MockVariableDebtToken("Aave Variable Debt WETH", "variableDebtWETH", address(pool));

        pool.setAToken(address(mockWeth), mockAToken);
        pool.setDebtToken(address(mockWeth), mockDebtToken);
        pool.setPrimaryAsset(address(mockWeth));
        mockWeth.mint(address(manager), 10_000 ether);
        mockWeth.mint(address(pool), 10_000 ether);

        weth = IERC20(address(mockWeth));
        aavePool = address(pool);
        poolManager = address(manager);
        aToken = address(mockAToken);
        debtToken = address(mockDebtToken);
    }

    function _fund(address account, uint256 amount) internal override {
        mockWeth.mint(account, amount);
    }
}
