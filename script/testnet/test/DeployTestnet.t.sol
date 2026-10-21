// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DeployTestnet} from "../DeployTestnet.s.sol";
import {DemoOperator} from "../DemoOperator.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {IAaveV3Testnet, IAaveScaledBalanceToken} from "../interfaces/IAaveV3Testnet.sol";
import {YieldBearingVault} from "../../../src/vaults/YieldBearingVault.sol";
import {BaseVault} from "../../../src/base/BaseVault.sol";
import {BaseStrategy} from "../../../src/base/BaseStrategy.sol";
import {WETHLoopStrategy} from "../../../src/strategies/WETHLoopStrategy.sol";
import {Whitelist} from "../../../src/access/Whitelist.sol";

/**
 * @title DeployTestnetTest
 * @notice Rehearses DeployTestnet.s.sol on a Base Sepolia fork, against the real Aave V3.6 pool, Uniswap V4
 *         PoolManager and WETH, then drives the deployment with the calls the demo app sends.
 * @dev Run with FOUNDRY_PROFILE=testnet. Forks BASE_SEPOLIA_RPC_URL (default https://sepolia.base.org, which serves
 *      historical state) at BASE_SEPOLIA_FORK_BLOCK (default FORK_BLOCK; 0 forks the latest block). Outside a
 *      broadcast the script writes no file.
 */
contract DeployTestnetTest is Test {
    /// @dev Pinned for reproducible figures: at this block the PoolManager holds 1,626.80 WETH, the WETH reserve has
    ///      1,092.55 WETH of variable debt against a 1,200 WETH borrow cap and 1,658.16 WETH supplied against 2,500.
    uint256 internal constant FORK_BLOCK = 48_476_000;

    uint256 internal constant SEED = 0.1 ether;

    address internal visitor = makeAddr("visitor");
    address internal griefer = makeAddr("griefer");

    DeployTestnet internal script;
    DeployTestnet.Wiring internal w;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://sepolia.base.org"));
        uint256 forkBlock = vm.envOr("BASE_SEPOLIA_FORK_BLOCK", FORK_BLOCK);
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);

        script = new DeployTestnet();
        w = script.wiring();
        // The broadcaster of a script called from a test is forge's default sender
        vm.deal(DEFAULT_SENDER, 10 ether);
    }

    function _deploy() internal returns (YieldBearingVault vault, WETHLoopStrategy strategy, DemoOperator operator) {
        return script.deploy(w, SEED);
    }

    function _healthFactor(address strategy) internal view returns (uint256 healthFactor) {
        (,,,,, healthFactor) = IAaveV3Testnet(w.aavePool).getUserAccountData(strategy);
    }

    function _collateral(address strategy) internal view returns (uint256) {
        return IERC20(w.aToken).balanceOf(strategy);
    }

    function _debt(address strategy) internal view returns (uint256) {
        return IERC20(w.variableDebtToken).balanceOf(strategy);
    }

    /// @dev The app's first deposit: join, wrap Ether, approve the vault, deposit to the visitor's own address.
    function _appDeposit(YieldBearingVault vault, DemoOperator operator, uint256 amount) internal returns (uint256 shares) {
        vm.deal(visitor, amount + 1 ether);
        vm.startPrank(visitor);
        operator.join();
        IWETH9(w.weth).deposit{value: amount}();
        IERC20(w.weth).approve(address(vault), amount);
        shares = vault.deposit(amount, visitor);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function test_deploy_wiresTheLoopToAaveAndUniswapAndHandsTheRolesToTheOperator() public {
        (YieldBearingVault vault, WETHLoopStrategy strategy, DemoOperator operator) = _deploy();

        assertEq(vault.asset(), w.weth, "canonical WETH");
        assertEq(address(vault.strategy()), address(strategy), "strategy set");
        assertEq(strategy.VAULT(), address(vault), "strategy bound to the vault");
        assertEq(strategy.AAVE_POOL(), w.aavePool, "Aave pool");
        assertEq(strategy.A_TOKEN(), w.aToken, "aWETH");
        assertEq(strategy.VARIABLE_DEBT_TOKEN(), w.variableDebtToken, "variable debt WETH");
        assertEq(address(strategy.POOL_MANAGER()), w.poolManager, "PoolManager");
        assertEq(strategy.E_MODE_CATEGORY_ID(), 1, "E-Mode category");
        assertEq(IAaveV3Testnet(w.aavePool).getUserEMode(address(strategy)), 1, "E-Mode enabled on Aave");
        assertEq(strategy.targetLeverage(), 10, "10x, as in the test suite");
        assertEq(strategy.minHealthFactor(), 1.02e18, "min health factor");
        assertEq(strategy.targetHealthFactor(), 1.05e18, "target health factor");

        assertEq(vault.owner(), address(operator), "owner role");
        assertEq(vault.admin(), address(operator), "admin role");
        assertEq(operator.owner(), DEFAULT_SENDER, "the deployer owns the operator");
        assertEq(vault.protocolFeeBps(), 1000, "10% performance fee");
        assertEq(vault.feeRecipient(), DEFAULT_SENDER, "fee to the deployer");
        assertTrue(vault.isWhitelisted(DEFAULT_SENDER), "fee recipient whitelisted");
        assertTrue(vault.isWhitelisted(address(operator)), "operator whitelisted");
    }

    function test_deploy_locksASeedPositionAtTenTimes() public {
        (YieldBearingVault vault, WETHLoopStrategy strategy, DemoOperator operator) = _deploy();

        assertGt(vault.balanceOf(address(operator)), 0, "seed shares held by the operator");
        assertApproxEqAbs(_collateral(address(strategy)), SEED * 10, 2, "1 WETH of collateral");
        assertApproxEqAbs(_debt(address(strategy)), SEED * 9, 2, "0.9 WETH of debt");
        assertApproxEqAbs(vault.totalAssets(), SEED + 1000, 4, "seed plus the dead shares' deposit");
        assertGe(_healthFactor(address(strategy)), strategy.targetHealthFactor(), "fresh 10x position above target");
    }

    function test_run_writesNoFileOutsideABroadcast() public {
        string memory file = script.deploymentFile();
        bool existed = vm.exists(file);
        string memory before = existed ? vm.readFile(file) : "";

        script.run();

        assertEq(vm.exists(file), existed, "no file created");
        if (existed) assertEq(vm.readFile(file), before, "file left unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                               PREFLIGHT
    //////////////////////////////////////////////////////////////*/

    function test_preflight_revertsWhenTheBorrowCapLeavesNoRoom() public {
        uint256 config = IAaveV3Testnet(w.aavePool).getReserveData(w.weth).configuration;
        uint256 borrowCap = ((config >> 80) & ((1 << 36) - 1)) * 1e18;
        uint256 headroom = borrowCap - IAaveScaledBalanceToken(w.variableDebtToken).totalSupply();
        uint256 seed = headroom / 9 + 1 ether;

        vm.expectRevert(abi.encodeWithSelector(DeployTestnet.BorrowCapHeadroomTooLow.selector, headroom, seed * 9));
        script.preflight(w, seed);
    }

    function test_preflight_revertsWhenFlashLiquidityIsShort() public {
        deal(w.weth, w.poolManager, 0.5 ether);
        vm.expectRevert(abi.encodeWithSelector(DeployTestnet.InsufficientFlashLiquidity.selector, 0.5 ether, SEED * 9));
        script.preflight(w, SEED);
    }

    function test_preflight_revertsWhenADependencyHasNoCode() public {
        DeployTestnet.Wiring memory broken = w;
        broken.poolManager = address(0xdead);
        vm.expectRevert(abi.encodeWithSelector(DeployTestnet.MissingCode.selector, "PoolManager", address(0xdead)));
        script.preflight(broken, SEED);
    }

    function test_preflight_revertsWhenTheTokensDoNotMatchTheReserve() public {
        DeployTestnet.Wiring memory broken = w;
        broken.aToken = w.variableDebtToken;
        vm.expectRevert(abi.encodeWithSelector(DeployTestnet.WiringMismatch.selector, "aToken", w.aToken, w.variableDebtToken));
        script.preflight(broken, SEED);
    }

    function test_preflight_revertsWhenTheReserveIsFrozen() public {
        IAaveV3Testnet.ReserveDataLegacy memory reserve = IAaveV3Testnet(w.aavePool).getReserveData(w.weth);
        reserve.configuration |= 1 << 57;
        vm.mockCall(w.aavePool, abi.encodeCall(IAaveV3Testnet.getReserveData, (w.weth)), abi.encode(reserve));

        vm.expectRevert(abi.encodeWithSelector(DeployTestnet.ReserveNotUsable.selector, reserve.configuration));
        script.preflight(w, SEED);
    }

    function test_deploy_revertsBeforeBroadcastingWhenFlashLiquidityIsShort() public {
        deal(w.weth, w.poolManager, 0.5 ether);
        vm.expectRevert(abi.encodeWithSelector(DeployTestnet.InsufficientFlashLiquidity.selector, 0.5 ether, SEED * 9));
        script.deploy(w, SEED);
    }

    /*//////////////////////////////////////////////////////////////
                         APP FLOWS (AS THE APP SENDS THEM)
    //////////////////////////////////////////////////////////////*/

    function test_appFlow_depositRevertsBeforeJoining() public {
        (YieldBearingVault vault,,) = _deploy();
        assertEq(vault.maxDeposit(visitor), 0, "maxDeposit is 0 outside the whitelist");

        vm.deal(visitor, 2 ether);
        vm.startPrank(visitor);
        IWETH9(w.weth).deposit{value: 1 ether}();
        IERC20(w.weth).approve(address(vault), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(Whitelist.NotWhitelisted.selector, visitor));
        vault.deposit(1 ether, visitor);
        vm.stopPrank();
    }

    function test_appFlow_joinWrapApproveDepositBuildsTenTimes() public {
        (YieldBearingVault vault, WETHLoopStrategy strategy, DemoOperator operator) = _deploy();
        uint256 collateralBefore = _collateral(address(strategy));
        uint256 debtBefore = _debt(address(strategy));
        uint256 expectedShares = vault.previewDeposit(1 ether);

        uint256 shares = _appDeposit(vault, operator, 1 ether);

        assertEq(shares, expectedShares, "shares as previewed");
        assertEq(vault.balanceOf(visitor), shares, "shares to the visitor");
        assertApproxEqAbs(_collateral(address(strategy)) - collateralBefore, 10 ether, 2, "10 WETH supplied");
        assertApproxEqAbs(_debt(address(strategy)) - debtBefore, 9 ether, 2, "9 WETH borrowed");
        assertApproxEqAbs(vault.maxWithdraw(visitor), 1 ether, 4, "the deposit is withdrawable");
    }

    function test_appFlow_partialWithdrawKeepsTheLeverage() public {
        (YieldBearingVault vault, WETHLoopStrategy strategy, DemoOperator operator) = _deploy();
        _appDeposit(vault, operator, 1 ether);
        uint256 healthBefore = _healthFactor(address(strategy));
        uint256 collateralBefore = _collateral(address(strategy));
        uint256 debtBefore = _debt(address(strategy));

        vm.prank(visitor);
        vault.withdraw(0.5 ether, visitor, visitor);

        assertEq(IERC20(w.weth).balanceOf(visitor), 0.5 ether, "paid");
        // Debt repaid rounds up, so the remaining position is not more leveraged than before
        assertGe(_healthFactor(address(strategy)), healthBefore - 1e9, "health factor kept");
        assertApproxEqRel(collateralBefore - _collateral(address(strategy)), 5 ether, 0.0001e18, "about 5 WETH withdrawn");
        assertApproxEqRel(debtBefore - _debt(address(strategy)), 4.5 ether, 0.0001e18, "about 4.5 WETH repaid");
    }

    function test_appFlow_maxRedeemExitsFully() public {
        (YieldBearingVault vault,, DemoOperator operator) = _deploy();
        _appDeposit(vault, operator, 1 ether);

        vm.startPrank(visitor);
        uint256 shares = vault.maxRedeem(visitor);
        uint256 received = vault.redeem(shares, visitor, visitor);
        IWETH9(w.weth).withdraw(received);
        vm.stopPrank();

        assertEq(vault.balanceOf(visitor), 0, "no shares left");
        assertApproxEqAbs(received, 1 ether, 4, "the deposit back, in the same block");
        assertEq(visitor.balance, 1 ether + received, "unwrapped to Ether");
    }

    function test_appFlow_emergencyCycle() public {
        (YieldBearingVault vault, WETHLoopStrategy strategy, DemoOperator operator) = _deploy();
        _appDeposit(vault, operator, 1 ether);
        uint256 equity = vault.totalAssets();

        // 1. Shock: deposits close until the position is checked or the shock is undone
        vm.prank(griefer);
        operator.shock();
        assertEq(vault.maxDeposit(visitor), 0, "maxDeposit is 0 after the shock");

        // 2. checkHealth, permissionless: closes the position into idle WETH
        vm.prank(griefer);
        assertFalse(strategy.checkHealth(), "unhealthy");
        assertTrue(vault.emergencyMode(), "emergency mode");
        assertEq(_debt(address(strategy)), 0, "debt repaid with a flash loan");
        assertApproxEqAbs(vault.totalAssets(), equity, 4, "equity kept as idle WETH");

        vm.deal(visitor, 1 ether);
        vm.startPrank(visitor);
        IWETH9(w.weth).deposit{value: 0.1 ether}();
        IERC20(w.weth).approve(address(vault), 0.1 ether);
        vm.expectRevert(BaseVault.VaultInEmergency.selector);
        vault.deposit(0.1 ether, visitor);
        // Withdrawals stay open, paid from idle WETH
        vault.withdraw(0.25 ether, visitor, visitor);
        vm.stopPrank();

        // 3. Restore, 4. reinvest: both open to anyone
        vm.startPrank(griefer);
        operator.restore();
        operator.reinvest();
        vm.stopPrank();
        assertFalse(vault.emergencyMode(), "recovered");
        assertGe(_healthFactor(address(strategy)), strategy.targetHealthFactor(), "rebuilt at or above target");
        assertGt(_debt(address(strategy)), 0, "leveraged again");
    }

    /// @dev The exit runs inside try/catch, so gas starvation could leave emergency on with the position open. The
    ///      strategy refuses activation unless exitPosition() gets EXIT_GAS; this checks that EXIT_GAS covers the exit
    ///      on Base Sepolia's Aave 3.6 and that a starved call reverts instead of tripping half way.
    function test_checkHealth_exitFitsInExitGasOnBaseSepolia() public {
        (YieldBearingVault vault, WETHLoopStrategy strategy, DemoOperator operator) = _deploy();
        _appDeposit(vault, operator, 1 ether);
        operator.shock();

        vm.expectPartialRevert(BaseStrategy.InsufficientGasForExit.selector);
        strategy.checkHealth{gas: 400_000}();
        assertFalse(vault.emergencyMode(), "a starved call changes nothing");

        uint256 gasBefore = gasleft();
        strategy.checkHealth();
        uint256 used = gasBefore - gasleft();
        assertTrue(vault.emergencyMode(), "tripped");
        assertEq(_debt(address(strategy)), 0, "closed");
        assertLt(used, strategy.EXIT_GAS(), "the whole trip costs less than the exit budget");
        emit log_named_uint("checkHealth trip gas on Base Sepolia (warm fork)", used);
    }

    /*//////////////////////////////////////////////////////////////
                                GRIEFING
    //////////////////////////////////////////////////////////////*/

    function test_griefing_aShockIsUndoneByAnyVisitorAndBoundedByTheCooldown() public {
        (YieldBearingVault vault,, DemoOperator operator) = _deploy();
        vm.prank(griefer);
        operator.shock();

        vm.prank(visitor);
        operator.restore();
        _appDeposit(vault, operator, 0.2 ether);
        assertGt(vault.balanceOf(visitor), 0, "deposits reopened by a visitor");

        vm.prank(griefer);
        vm.expectRevert(abi.encodeWithSelector(DemoOperator.ShockCooldown.selector, block.timestamp + 1 hours));
        operator.shock();
    }

    function test_griefing_strangersCannotTakeTheRolesOrTouchTheSeed() public {
        (YieldBearingVault vault,, DemoOperator operator) = _deploy();

        vm.startPrank(griefer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, griefer));
        operator.handBack(griefer, griefer);
        vm.expectRevert(BaseVault.NotAdmin.selector);
        vault.setStrategy(WETHLoopStrategy(address(0xbeef)));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, griefer));
        vault.removeFromWhitelist(visitor);
        uint256 seedShares = vault.balanceOf(address(operator));
        vm.expectRevert();
        vault.redeem(seedShares, griefer, address(operator));
        vm.stopPrank();
        assertEq(vault.balanceOf(address(operator)), seedShares, "seed untouched");
    }
}
