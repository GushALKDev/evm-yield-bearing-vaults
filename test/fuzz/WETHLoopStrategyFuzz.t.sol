// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "../../src/interfaces/aave/IPool.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";

/**
 * @title WETHLoopStrategyFuzzTest
 * @notice Stateless fuzzing tests for WETHLoopStrategy.
 * @dev Tests leverage mechanics with randomized inputs on forked mainnet.
 *      Requires ETHEREUM_MAINNET_RPC environment variable.
 */
contract WETHLoopStrategyFuzzTest is Test {
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
        vaultOwner = makeAddr("vaultOwner");
        vaultAdmin = makeAddr("vaultAdmin");

        string memory rpc = vm.envString("ETHEREUM_MAINNET_RPC");
        vm.createSelectFork(rpc);

        weth = IERC20(WETH_MAINNET);
        address poolManagerAddress = UNISWAP_V4_POOL_MANAGER;

        require(poolManagerAddress.code.length > 0, "PoolManager has no code");

        deal(address(weth), poolManagerAddress, 10_000 ether);

        (bool success, bytes memory data) = AAVE_ADDRESS_PROVIDER.staticcall(abi.encodeWithSignature("getPool()"));
        require(success, "getPool failed");
        resolvedPool = abi.decode(data, (address));

        vm.startPrank(vaultOwner);
        deal(address(weth), vaultOwner, INITIAL_DEPOSIT);

        address predictedVault = vm.computeCreateAddress(vaultOwner, vm.getNonce(vaultOwner));
        weth.approve(predictedVault, INITIAL_DEPOSIT);
        YieldBearingVault bVault = new YieldBearingVault(weth, vaultOwner, vaultAdmin, INITIAL_DEPOSIT);
        vm.stopPrank();

        vault = address(bVault);

        strategy = new WETHLoopStrategy(
            weth,
            vault,
            poolManagerAddress,
            resolvedPool,
            AWETH_TOKEN,
            VARIABLE_DEBT_WETH,
            TARGET_LEVERAGE,
            MIN_HEALTH_FACTOR,
            TARGET_HEALTH_FACTOR,
            EMODE_ETH_CORRELATED
        );

        vm.prank(vaultAdmin);
        bVault.setStrategy(strategy);

        deal(address(weth), vault, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                       INVESTMENT FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes investment amounts ensuring leverage is correctly established.
     * @param depositAmount Random deposit between 0.1 and 5 ETH.
     */
    function testFuzz_Invest_EstablishesLeverage(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 0.1 ether, 5 ether);

        vm.startPrank(vault);
        weth.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, vault);
        vm.stopPrank();

        (uint256 totalCollateralBase, uint256 totalDebtBase,,,, uint256 healthFactor) =
            IPool(resolvedPool).getUserAccountData(address(strategy));

        assertGe(healthFactor, MIN_HEALTH_FACTOR, "Health factor must be above minimum");
        assertGt(totalCollateralBase, 0, "Should have collateral");
        assertGt(totalDebtBase, 0, "Should have debt");

        uint256 leverageRatio = totalCollateralBase * 100 / (totalCollateralBase - totalDebtBase);
        assertGe(leverageRatio, 900, "Leverage should be at least 9x");
    }

    /**
     * @notice Fuzzes multiple sequential deposits.
     * @param deposit1 First deposit amount (0.1-3 ETH).
     * @param deposit2 Second deposit amount (0.1-3 ETH).
     */
    function testFuzz_Invest_MultipleDeposits(uint256 deposit1, uint256 deposit2) public {
        deposit1 = bound(deposit1, 0.1 ether, 3 ether);
        deposit2 = bound(deposit2, 0.1 ether, 3 ether);

        vm.startPrank(vault);
        weth.approve(address(strategy), deposit1 + deposit2);

        strategy.deposit(deposit1, vault);
        (,,,,, uint256 healthFactorAfterFirst) = IPool(resolvedPool).getUserAccountData(address(strategy));

        strategy.deposit(deposit2, vault);
        (,,,,, uint256 healthFactorAfterSecond) = IPool(resolvedPool).getUserAccountData(address(strategy));

        vm.stopPrank();

        assertGe(healthFactorAfterFirst, MIN_HEALTH_FACTOR, "First deposit should be healthy");
        assertGe(healthFactorAfterSecond, MIN_HEALTH_FACTOR, "Second deposit should be healthy");
    }

    /**
     * @notice Fuzzes investment with different leverage targets.
     * @param leverageTarget Random leverage between 5x and 10x.
     * @param depositAmount Random deposit amount.
     */
    function testFuzz_Invest_DifferentLeverageTargets(uint8 leverageTarget, uint256 depositAmount) public {
        leverageTarget = uint8(bound(leverageTarget, 5, 10));
        depositAmount = bound(depositAmount, 0.5 ether, 2 ether);

        WETHLoopStrategy customStrategy = new WETHLoopStrategy(
            weth,
            vault,
            UNISWAP_V4_POOL_MANAGER,
            resolvedPool,
            AWETH_TOKEN,
            VARIABLE_DEBT_WETH,
            leverageTarget,
            MIN_HEALTH_FACTOR,
            TARGET_HEALTH_FACTOR,
            EMODE_ETH_CORRELATED
        );

        vm.startPrank(vault);
        weth.approve(address(customStrategy), depositAmount);
        customStrategy.deposit(depositAmount, vault);
        vm.stopPrank();

        (uint256 totalCollateralBase, uint256 totalDebtBase,,,, uint256 healthFactor) =
            IPool(resolvedPool).getUserAccountData(address(customStrategy));

        assertGe(healthFactor, MIN_HEALTH_FACTOR, "Health factor must be above minimum");

        uint256 actualLeverage = totalCollateralBase * 100 / (totalCollateralBase - totalDebtBase);
        assertApproxEqRel(
            actualLeverage, uint256(leverageTarget) * 100, 0.15e18, "Leverage should match target within 15%"
        );
    }

    /*//////////////////////////////////////////////////////////////
                       DIVESTMENT FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes partial withdrawals maintaining leverage ratio.
     * @param depositAmount Initial deposit (0.5-5 ETH).
     * @param withdrawRatio Percentage to withdraw (10-90%).
     */
    function testFuzz_Divest_PartialWithdrawal(uint256 depositAmount, uint8 withdrawRatio) public {
        depositAmount = bound(depositAmount, 0.5 ether, 5 ether);
        withdrawRatio = uint8(bound(withdrawRatio, 10, 90));

        vm.startPrank(vault);
        weth.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, vault);
        vm.stopPrank();

        (uint256 initialCollateral, uint256 initialDebt,,,,) =
            IPool(resolvedPool).getUserAccountData(address(strategy));

        uint256 withdrawAmount = (depositAmount * withdrawRatio) / 100;

        uint256 vaultBalanceBefore = weth.balanceOf(vault);
        vm.prank(vault);
        strategy.withdraw(withdrawAmount, vault, vault);

        uint256 receivedAmount = weth.balanceOf(vault) - vaultBalanceBefore;

        (uint256 finalCollateral, uint256 finalDebt,,,, uint256 finalHealthFactor) =
            IPool(resolvedPool).getUserAccountData(address(strategy));

        assertApproxEqAbs(receivedAmount, withdrawAmount, 100, "Should receive withdrawal amount");
        assertGe(finalHealthFactor, MIN_HEALTH_FACTOR, "Health factor should remain healthy");

        if (finalCollateral > 0 && finalDebt > 0) {
            uint256 initialLeverage = initialCollateral * 100 / (initialCollateral - initialDebt);
            uint256 finalLeverage = finalCollateral * 100 / (finalCollateral - finalDebt);

            assertApproxEqRel(finalLeverage, initialLeverage, 0.05e18, "Leverage ratio should be maintained");
        }
    }

    /**
     * @notice Fuzzes full withdrawal (redeem all shares).
     * @param depositAmount Random deposit amount (0.5-5 ETH).
     */
    function testFuzz_Divest_FullWithdrawal(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 0.5 ether, 5 ether);

        vm.startPrank(vault);
        weth.approve(address(strategy), depositAmount);
        uint256 shares = strategy.deposit(depositAmount, vault);
        vm.stopPrank();

        uint256 vaultBalanceBefore = weth.balanceOf(vault);

        vm.prank(vault);
        strategy.redeem(shares, vault, vault);

        uint256 receivedAmount = weth.balanceOf(vault) - vaultBalanceBefore;

        (uint256 finalCollateral, uint256 finalDebt,,,,) = IPool(resolvedPool).getUserAccountData(address(strategy));

        assertApproxEqAbs(receivedAmount, depositAmount, 1000, "Should receive full deposit back");
        assertLt(finalCollateral, 1e6, "Collateral should be minimal");
        assertLt(finalDebt, 1e6, "Debt should be minimal");
    }

    /**
     * @notice Fuzzes multiple users with different deposit/withdrawal orders.
     * @param user1Deposit User 1 deposit (0.5-2 ETH).
     * @param user2Deposit User 2 deposit (0.5-2 ETH).
     * @param user1WithdrawRatio User 1 withdraw percentage (50-100%).
     */
    function testFuzz_Divest_MultipleUsers(uint256 user1Deposit, uint256 user2Deposit, uint8 user1WithdrawRatio)
        public
    {
        user1Deposit = bound(user1Deposit, 0.5 ether, 2 ether);
        user2Deposit = bound(user2Deposit, 0.5 ether, 2 ether);
        user1WithdrawRatio = uint8(bound(user1WithdrawRatio, 50, 100));

        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        vm.startPrank(vaultOwner);
        YieldBearingVault(vault).addToWhitelist(user1);
        YieldBearingVault(vault).addToWhitelist(user2);
        vm.stopPrank();

        deal(address(weth), user1, user1Deposit);
        deal(address(weth), user2, user2Deposit);

        vm.startPrank(user1);
        weth.approve(vault, user1Deposit);
        uint256 user1Shares = YieldBearingVault(vault).deposit(user1Deposit, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        weth.approve(vault, user2Deposit);
        uint256 user2Shares = YieldBearingVault(vault).deposit(user2Deposit, user2);
        vm.stopPrank();

        uint256 user1WithdrawShares = (user1Shares * user1WithdrawRatio) / 100;
        uint256 balanceBefore = weth.balanceOf(user1);

        vm.prank(user1);
        YieldBearingVault(vault).redeem(user1WithdrawShares, user1, user1);

        uint256 received = weth.balanceOf(user1) - balanceBefore;
        assertGt(received, 0, "User1 should receive funds");

        (,,,,, uint256 healthFactor) = IPool(resolvedPool).getUserAccountData(address(strategy));
        assertGe(healthFactor, MIN_HEALTH_FACTOR, "Health factor should remain healthy");

        uint256 user2SharesRemaining = YieldBearingVault(vault).balanceOf(user2);
        assertEq(user2SharesRemaining, user2Shares, "User2 shares should be unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                     HEALTH FACTOR FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes health factor thresholds.
     * @param minHealthFactor Random minimum health factor (1.01-1.05).
     * @param depositAmount Random deposit amount.
     */
    function testFuzz_HealthFactor_CustomThresholds(uint256 minHealthFactor, uint256 depositAmount) public {
        minHealthFactor = bound(minHealthFactor, 1.01e18, 1.05e18);
        depositAmount = bound(depositAmount, 0.5 ether, 2 ether);

        uint256 targetHealthFactor = minHealthFactor + 0.03e18;

        uint8 adjustedLeverage = minHealthFactor > 1.04e18 ? 8 : 10;

        WETHLoopStrategy customStrategy = new WETHLoopStrategy(
            weth,
            vault,
            UNISWAP_V4_POOL_MANAGER,
            resolvedPool,
            AWETH_TOKEN,
            VARIABLE_DEBT_WETH,
            adjustedLeverage,
            minHealthFactor,
            targetHealthFactor,
            EMODE_ETH_CORRELATED
        );

        vm.startPrank(vault);
        weth.approve(address(customStrategy), depositAmount);
        customStrategy.deposit(depositAmount, vault);
        vm.stopPrank();

        (,,,,, uint256 actualHealthFactor) = IPool(resolvedPool).getUserAccountData(address(customStrategy));

        assertGe(actualHealthFactor, minHealthFactor, "Health factor should meet minimum threshold");
    }

    /**
     * @notice Fuzzes emergency divest trigger.
     * @param depositAmount Random deposit amount.
     * @param healthFactorIncrease Random increase to trigger emergency (0.05-0.2).
     */
    function testFuzz_CheckHealth_TriggersEmergency(uint256 depositAmount, uint256 healthFactorIncrease) public {
        depositAmount = bound(depositAmount, 0.5 ether, 2 ether);
        healthFactorIncrease = bound(healthFactorIncrease, 0.05e18, 0.2e18);

        vm.startPrank(vault);
        weth.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, vault);
        vm.stopPrank();

        (,,,,, uint256 initialHealthFactor) = IPool(resolvedPool).getUserAccountData(address(strategy));

        uint256 newMinHealthFactor = initialHealthFactor + healthFactorIncrease;

        vm.prank(vaultAdmin);
        strategy.setHealthFactors(newMinHealthFactor, newMinHealthFactor + 0.03e18);

        bool isHealthy = strategy.checkHealth();

        assertFalse(isHealthy, "checkHealth should return false");
        assertTrue(YieldBearingVault(vault).emergencyMode(), "Emergency mode should be active");

        uint256 finalDebt = IERC20(VARIABLE_DEBT_WETH).balanceOf(address(strategy));
        assertLt(finalDebt, 100, "Debt should be fully repaid");
    }

    /**
     * @notice Fuzzes recovery from emergency mode.
     * @param depositAmount Random deposit amount.
     */
    function testFuzz_Recovery_ReinvestsAfterEmergency(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 0.5 ether, 2 ether);

        address user = makeAddr("user");
        vm.prank(vaultOwner);
        YieldBearingVault(vault).addToWhitelist(user);

        deal(address(weth), user, depositAmount);

        vm.startPrank(user);
        weth.approve(vault, depositAmount);
        YieldBearingVault(vault).deposit(depositAmount, user);
        vm.stopPrank();

        (,,,,, uint256 initialHealthFactor) = IPool(resolvedPool).getUserAccountData(address(strategy));
        uint256 newMinHealthFactor = initialHealthFactor + 0.05e18;

        vm.prank(vaultAdmin);
        strategy.setHealthFactors(newMinHealthFactor, newMinHealthFactor + 0.03e18);
        strategy.checkHealth();

        assertTrue(strategy.emergencyMode(), "Emergency mode should be active");

        vm.prank(vaultAdmin);
        YieldBearingVault(vault).setEmergencyMode(false);

        assertFalse(strategy.emergencyMode(), "Emergency mode should be deactivated");

        uint256 collateralAfterRecovery = IERC20(AWETH_TOKEN).balanceOf(address(strategy));
        uint256 debtAfterRecovery = IERC20(VARIABLE_DEBT_WETH).balanceOf(address(strategy));

        assertGt(collateralAfterRecovery, 0, "Should have collateral after recovery");
        assertGt(debtAfterRecovery, 0, "Should have debt after recovery");
    }

    /*//////////////////////////////////////////////////////////////
                      SHARE CONVERSION FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes share to asset conversions with leverage.
     * @param depositAmount Random deposit amount.
     * @param sharesToConvertRatio Random shares to convert (1-100% of total).
     */
    function testFuzz_ShareConversion_Consistency(uint256 depositAmount, uint8 sharesToConvertRatio) public {
        depositAmount = bound(depositAmount, 0.5 ether, 2 ether);
        sharesToConvertRatio = uint8(bound(sharesToConvertRatio, 1, 100));

        vm.startPrank(vault);
        weth.approve(address(strategy), depositAmount);
        uint256 shares = strategy.deposit(depositAmount, vault);
        vm.stopPrank();

        uint256 sharesToConvert = (shares * sharesToConvertRatio) / 100;

        uint256 assets = strategy.convertToAssets(sharesToConvert);
        uint256 reconvertedShares = strategy.convertToShares(assets);

        assertApproxEqRel(reconvertedShares, sharesToConvert, 0.01e18, "Conversion should be reversible within 1%");
    }

    /**
     * @notice Fuzzes preview functions match actual operations.
     * @param depositAmount Random deposit amount.
     */
    function testFuzz_Preview_MatchesActual(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 0.5 ether, 2 ether);

        uint256 previewedShares = strategy.previewDeposit(depositAmount);

        vm.startPrank(vault);
        weth.approve(address(strategy), depositAmount);
        uint256 actualShares = strategy.deposit(depositAmount, vault);
        vm.stopPrank();

        assertApproxEqRel(actualShares, previewedShares, 0.01e18, "Preview should match actual within 1%");
    }

    /*//////////////////////////////////////////////////////////////
                      INVARIANT FUZZING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzzes total assets calculation invariant.
     * @param depositAmount Random deposit amount.
     */
    function testFuzz_Invariant_TotalAssets(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 0.5 ether, 2 ether);

        vm.startPrank(vault);
        weth.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, vault);
        vm.stopPrank();

        uint256 totalAssets = strategy.totalAssets();
        uint256 aTokenBalance = IERC20(AWETH_TOKEN).balanceOf(address(strategy));
        uint256 debtBalance = IERC20(VARIABLE_DEBT_WETH).balanceOf(address(strategy));
        uint256 wethBalance = weth.balanceOf(address(strategy));

        uint256 calculatedAssets = aTokenBalance - debtBalance + wethBalance;

        assertApproxEqAbs(totalAssets, calculatedAssets, 100, "Total assets should match calculated assets");
    }

    /**
     * @notice Fuzzes leverage ratio stays within safe bounds.
     * @param depositAmount Random deposit amount.
     */
    function testFuzz_Invariant_LeverageWithinBounds(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 0.5 ether, 2 ether);

        vm.startPrank(vault);
        weth.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, vault);
        vm.stopPrank();

        (uint256 totalCollateralBase, uint256 totalDebtBase,,,,) =
            IPool(resolvedPool).getUserAccountData(address(strategy));

        uint256 leverageRatio = totalCollateralBase * 100 / (totalCollateralBase - totalDebtBase);

        assertLe(leverageRatio, 1400, "Leverage should not exceed 14x (E-Mode limit)");
        assertGe(leverageRatio, 500, "Leverage should be at least 5x");
    }
}
