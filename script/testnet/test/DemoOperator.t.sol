// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DemoOperator} from "../DemoOperator.sol";
import {YieldBearingVault} from "../../../src/vaults/YieldBearingVault.sol";
import {BaseVault} from "../../../src/base/BaseVault.sol";
import {BaseStrategy} from "../../../src/base/BaseStrategy.sol";
import {WETHLoopStrategy} from "../../../src/strategies/WETHLoopStrategy.sol";
import {Whitelist} from "../../../src/access/Whitelist.sol";
import {IPool} from "../../../src/interfaces/aave/IPool.sol";
import {VaultDeployer} from "../../../test/utils/VaultDeployer.sol";
import {MockWETH} from "../../../test/mocks/MockWETH.sol";
import {MockAavePool} from "../../../test/mocks/MockAavePool.sol";
import {MockAToken} from "../../../test/mocks/MockAToken.sol";
import {MockVariableDebtToken} from "../../../test/mocks/MockVariableDebtToken.sol";
import {MockPoolManager} from "../../../test/mocks/MockPoolManager.sol";

/**
 * @title DemoOperatorTest
 * @notice The testnet holder of the vault's roles: what strangers can call, the cooldown, the recovery, and that
 *         nothing else is reachable.
 * @dev Run with FOUNDRY_PROFILE=testnet. Uses the repository's mocks, so it needs no RPC; DeployTestnet.t.sol covers
 *      the same flows against Aave and Uniswap on a Base Sepolia fork.
 */
contract DemoOperatorTest is Test {
    uint256 internal constant SEED = 1 ether;

    address internal deployer = makeAddr("deployer");
    address internal visitor = makeAddr("visitor");
    address internal griefer = makeAddr("griefer");

    MockWETH internal weth;
    MockAavePool internal pool;
    YieldBearingVault internal vault;
    WETHLoopStrategy internal strategy;
    DemoOperator internal operator;

    function setUp() public {
        vm.warp(1_800_000_000);
        (vault, strategy, operator) = _deploy(SEED);
    }

    /// @dev The DeployTestnet sequence on mocks: vault, strategy, fee, operator, seed for the operator, roles handed over.
    function _deploy(uint256 seed) internal returns (YieldBearingVault v, WETHLoopStrategy s, DemoOperator o) {
        weth = new MockWETH();
        pool = new MockAavePool();
        MockPoolManager manager = new MockPoolManager();
        MockAToken aToken = new MockAToken("Aave WETH", "aWETH", address(pool));
        MockVariableDebtToken debtToken = new MockVariableDebtToken("Aave Variable Debt WETH", "variableDebtWETH", address(pool));
        pool.setAToken(address(weth), aToken);
        pool.setDebtToken(address(weth), debtToken);
        pool.setPrimaryAsset(address(weth));
        weth.mint(address(manager), 10_000 ether);
        weth.mint(address(pool), 10_000 ether);

        weth.mint(deployer, 1000 + seed);
        vm.startPrank(deployer);
        VaultDeployer vaultDeployer = new VaultDeployer();
        weth.approve(address(vaultDeployer), 1000);
        v = vaultDeployer.deploy(IERC20(address(weth)), deployer, deployer, 1000);
        s = new WETHLoopStrategy(
            IERC20(address(weth)), address(v), address(manager), address(pool), address(aToken), address(debtToken), 10, 1.02e18, 1.05e18, 1
        );
        v.setStrategy(s);
        v.addToWhitelist(deployer);
        v.setFeeRecipient(deployer);
        v.setProtocolFee(1000);
        o = new DemoOperator(v, s, deployer);
        v.addToWhitelist(address(o));
        if (seed > 0) {
            weth.approve(address(v), seed);
            v.deposit(seed, address(o));
        }
        v.setAdmin(address(o));
        v.transferOwnership(address(o));
        vm.stopPrank();
    }

    function _healthFactor() internal view returns (uint256 healthFactor) {
        (,,,,, healthFactor) = IPool(address(pool)).getUserAccountData(address(strategy));
    }

    function _depositAs(address account, uint256 amount) internal {
        weth.mint(account, amount);
        vm.startPrank(account);
        weth.approve(address(vault), amount);
        vault.deposit(amount, account);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                  JOIN
    //////////////////////////////////////////////////////////////*/

    function test_constructor_recordsTheDeploymentThresholds() public view {
        assertEq(operator.DEFAULT_MIN_HEALTH_FACTOR(), 1.02e18, "min");
        assertEq(operator.DEFAULT_TARGET_HEALTH_FACTOR(), 1.05e18, "target");
        assertEq(vault.owner(), address(operator), "owner role");
        assertEq(vault.admin(), address(operator), "admin role");
    }

    function test_join_whitelistsTheCallerOnly() public {
        vm.expectEmit(address(operator));
        emit DemoOperator.Joined(visitor);
        vm.prank(visitor);
        operator.join();

        assertTrue(vault.isWhitelisted(visitor), "caller whitelisted");
        assertFalse(vault.isWhitelisted(griefer), "nobody else");
        _depositAs(visitor, 0.5 ether);
        assertGt(vault.balanceOf(visitor), 0, "can deposit after joining");
    }

    function test_join_isIdempotent() public {
        vm.prank(visitor);
        operator.join();

        vm.recordLogs();
        vm.prank(visitor);
        operator.join();
        assertEq(vm.getRecordedLogs().length, 0, "no event, no write the second time");
        assertTrue(vault.isWhitelisted(visitor), "still whitelisted");
    }

    function test_deposit_revertsBeforeJoining() public {
        weth.mint(visitor, 1 ether);
        vm.startPrank(visitor);
        weth.approve(address(vault), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(Whitelist.NotWhitelisted.selector, visitor));
        vault.deposit(1 ether, visitor);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                 SHOCK
    //////////////////////////////////////////////////////////////*/

    function test_shock_raisesBothThresholdsAboveTheLiveHealthFactor() public {
        uint256 healthFactor = _healthFactor();

        vm.expectEmit(address(operator));
        emit DemoOperator.Shocked(griefer, healthFactor, healthFactor + 0.05e18, healthFactor + 0.08e18);
        vm.prank(griefer);
        operator.shock();

        assertEq(strategy.minHealthFactor(), healthFactor + 0.05e18, "min above the health factor");
        assertEq(strategy.targetHealthFactor(), healthFactor + 0.08e18, "target above min");
        assertEq(operator.lastShockAt(), block.timestamp, "cooldown starts");
        assertFalse(vault.emergencyMode(), "the shock alone does not close the position");
    }

    function test_shock_thenCheckHealthClosesThePosition() public {
        vm.prank(visitor);
        operator.shock();

        vm.prank(griefer);
        assertFalse(strategy.checkHealth(), "unhealthy");

        assertTrue(vault.emergencyMode(), "vault in emergency");
        assertTrue(strategy.emergencyMode(), "strategy in emergency");
        assertEq(pool.getDebt(address(weth), address(strategy)), 0, "debt repaid");
        assertEq(pool.getCollateral(address(weth), address(strategy)), 0, "collateral withdrawn");
        assertEq(weth.balanceOf(address(strategy)), SEED, "equity kept as idle WETH");
    }

    function test_shock_blocksDepositsUntilSomeoneRestores() public {
        vm.prank(visitor);
        operator.join();
        vm.prank(griefer);
        operator.shock();

        assertEq(vault.maxDeposit(visitor), 0, "maxDeposit reports the closed door");
        weth.mint(visitor, 1 ether);
        vm.startPrank(visitor);
        weth.approve(address(vault), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(WETHLoopStrategy.HealthFactorBelowMinimum.selector, _healthFactorAfter(1 ether), strategy.minHealthFactor()));
        vault.deposit(1 ether, visitor);

        // Any visitor can undo a griefer's shock at once
        operator.restore();
        vault.deposit(1 ether, visitor);
        vm.stopPrank();
        assertGt(vault.balanceOf(visitor), 0, "deposits open again");
    }

    /// @dev Health factor of the mock position after investing `amount` more at 10x: collateral * LT / debt.
    function _healthFactorAfter(uint256 amount) internal view returns (uint256) {
        uint256 collateral = pool.getCollateral(address(weth), address(strategy)) + amount * 10;
        uint256 debt = pool.getDebt(address(weth), address(strategy)) + amount * 9;
        return collateral * 9500 * 1e18 / (debt * 10_000);
    }

    function test_shock_revertsDuringTheCooldown() public {
        vm.prank(griefer);
        operator.shock();
        vm.prank(visitor);
        operator.restore();

        uint256 next = block.timestamp + operator.SHOCK_COOLDOWN();
        vm.warp(next - 1);
        vm.prank(griefer);
        vm.expectRevert(abi.encodeWithSelector(DemoOperator.ShockCooldown.selector, next));
        operator.shock();

        vm.warp(next);
        vm.prank(griefer);
        operator.shock();
        assertEq(operator.lastShockAt(), next, "allowed once the cooldown has passed");
    }

    function test_shock_revertsWithoutAnOpenPosition() public {
        (,, DemoOperator empty) = _deploy(0);
        vm.expectRevert(DemoOperator.NoOpenPosition.selector);
        empty.shock();
    }

    function test_shock_revertsDuringEmergency() public {
        vm.prank(griefer);
        operator.shock();
        strategy.checkHealth();

        vm.warp(block.timestamp + operator.SHOCK_COOLDOWN());
        vm.prank(griefer);
        vm.expectRevert(DemoOperator.AlreadyInEmergency.selector);
        operator.shock();
    }

    /*//////////////////////////////////////////////////////////////
                            RESTORE, REINVEST
    //////////////////////////////////////////////////////////////*/

    function test_restore_clearsEmergencyAndResetsTheThresholds() public {
        vm.prank(griefer);
        operator.shock();
        strategy.checkHealth();

        vm.expectEmit(address(operator));
        emit DemoOperator.Restored(visitor, true, true);
        vm.prank(visitor);
        operator.restore();

        assertFalse(vault.emergencyMode(), "vault flag cleared");
        assertFalse(strategy.emergencyMode(), "strategy flag cleared");
        assertEq(strategy.minHealthFactor(), 1.02e18, "min reset");
        assertEq(strategy.targetHealthFactor(), 1.05e18, "target reset");
        assertEq(weth.balanceOf(address(strategy)), SEED, "idle WETH stays idle until reinvest");
    }

    function test_restore_onlyResetsTheThresholdsWhenTheShockWasNotTripped() public {
        vm.prank(griefer);
        operator.shock();

        vm.expectEmit(address(operator));
        emit DemoOperator.Restored(visitor, false, true);
        vm.prank(visitor);
        operator.restore();
        assertEq(strategy.minHealthFactor(), 1.02e18, "min reset");
    }

    function test_restore_revertsWhenThereIsNothingToRestore() public {
        vm.expectRevert(DemoOperator.NothingToRestore.selector);
        operator.restore();
    }

    function test_reinvest_rebuildsThePositionAtOrAboveTarget() public {
        vm.prank(griefer);
        operator.shock();
        strategy.checkHealth();
        operator.restore();

        vm.prank(visitor);
        operator.reinvest();

        assertEq(weth.balanceOf(address(strategy)), 0, "idle WETH invested");
        // vault.reinvest() also moves the vault's own idle balance (the 1,000 wei initial deposit) into the strategy
        assertEq(pool.getDebt(address(weth), address(strategy)), (SEED + 1000) * 9, "10x again");
        assertGe(_healthFactor(), strategy.targetHealthFactor(), "at or above target");
    }

    function test_reinvest_revertsDuringEmergency() public {
        vm.prank(griefer);
        operator.shock();
        strategy.checkHealth();

        vm.expectRevert(BaseVault.VaultInEmergency.selector);
        operator.reinvest();
    }

    function test_withdraw_duringEmergencyIsPaidFromIdleWeth() public {
        vm.prank(visitor);
        operator.join();
        _depositAs(visitor, 1 ether);
        vm.prank(griefer);
        operator.shock();
        strategy.checkHealth();

        uint256 shares = vault.balanceOf(visitor);
        vm.prank(visitor);
        uint256 received = vault.redeem(shares, visitor, visitor);
        assertApproxEqAbs(received, 1 ether, 2, "pro rata equity");
        assertEq(weth.balanceOf(visitor), received, "paid in WETH");
    }

    /*//////////////////////////////////////////////////////////////
                         OWNER, GRIEFING BOUNDS
    //////////////////////////////////////////////////////////////*/

    function test_handBack_movesBothRolesAndEndsTheDemoControls() public {
        address newOwner = makeAddr("newOwner");
        address newAdmin = makeAddr("newAdmin");

        vm.prank(deployer);
        operator.handBack(newOwner, newAdmin);

        assertEq(vault.owner(), newOwner, "owner");
        assertEq(vault.admin(), newAdmin, "admin");
        vm.prank(visitor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(operator)));
        operator.join();
        vm.expectRevert(BaseStrategy.NotVaultAdmin.selector);
        operator.shock();
    }

    function test_handBack_ownerOnly() public {
        vm.prank(griefer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, griefer));
        operator.handBack(griefer, griefer);
    }

    function test_renounceOwnership_isDisabled() public {
        vm.prank(deployer);
        vm.expectRevert(DemoOperator.RenounceOwnershipDisabled.selector);
        operator.renounceOwnership();
    }

    /// @dev The roles sit with the operator, so a stranger calling the vault or the strategy directly gets nothing.
    function test_griefer_cannotReachTheOtherAdminOrOwnerFunctions() public {
        vm.startPrank(griefer);
        vm.expectRevert(BaseVault.NotAdmin.selector);
        vault.setStrategy(strategy);
        vm.expectRevert(BaseVault.NotAdmin.selector);
        vault.setProtocolFee(2500);
        vm.expectRevert(BaseVault.NotAdmin.selector);
        vault.setEmergencyMode(true);
        vm.expectRevert(BaseVault.NotAdmin.selector);
        vault.setAdmin(griefer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, griefer));
        vault.removeFromWhitelist(address(operator));
        vm.expectRevert(BaseStrategy.NotVaultAdmin.selector);
        strategy.setLeverage(50);
        vm.expectRevert(BaseStrategy.NotVaultAdmin.selector);
        strategy.setHealthFactors(1.5e18, 2e18);
        vm.stopPrank();
    }

    /// @dev The seed belongs to the operator, which has no function that moves shares, so the position stays.
    function test_seed_isHeldByTheOperatorWithNoApprovals() public view {
        assertGt(vault.balanceOf(address(operator)), 0, "seed shares");
        assertEq(vault.allowance(address(operator), griefer), 0, "nobody may spend them");
        assertEq(vault.allowance(address(operator), deployer), 0, "not even the deployer");
    }

    /// @dev Repeated shocks are bounded by the cooldown, and each one is undone by anyone's restore.
    function test_griefer_canShockAtMostOncePerCooldown() public {
        vm.startPrank(griefer);
        operator.shock();
        strategy.checkHealth();
        operator.restore();
        operator.reinvest();
        vm.expectRevert(abi.encodeWithSelector(DemoOperator.ShockCooldown.selector, block.timestamp + 1 hours));
        operator.shock();
        vm.stopPrank();
        assertFalse(vault.emergencyMode(), "open for deposits again");
    }

    function test_events_coverTheWholeCycle() public {
        vm.recordLogs();
        operator.shock();
        strategy.checkHealth();
        operator.restore();
        operator.reinvest();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool shocked;
        bool restored;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == DemoOperator.Shocked.selector) shocked = true;
            if (logs[i].topics[0] == DemoOperator.Restored.selector) restored = true;
        }
        assertTrue(shocked && restored, "the app can follow the cycle from logs");
    }
}
