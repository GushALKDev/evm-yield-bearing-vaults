// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {YieldBearingVault} from "../../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../../src/strategies/WETHLoopStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "../../../src/interfaces/aave/IPool.sol";

/**
 * @title WETHLoopStrategyHandler
 * @notice Handler for leveraged strategy operations in stateful invariant testing.
 * @dev Executes random deposit/withdraw/health check operations with position tracking.
 */
contract WETHLoopStrategyHandler is Test {
    /*//////////////////////////////////////////////////////////////
                            GHOST VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 public ghost_maxLeverageObserved;
    uint256 public ghost_minHealthFactorObserved;
    uint256 public ghost_emergencyDivestCount;

    uint256 public ghost_totalInvested;
    uint256 public ghost_totalDivested;

    uint256 public ghost_healthCheckCalls;
    uint256 public ghost_healthCheckFailures;

    uint256 public ghost_lastCollateral;
    uint256 public ghost_lastDebt;
    uint256 public ghost_lastHealthFactor;

    /// @dev Strategy equity expected from deposits, withdrawals and measured interest.
    uint256 public ghost_expectedEquity;
    /// @dev Net interest (supply minus borrow) measured across time warps.
    int256 public ghost_interest;
    /// @dev Operations that touch Aave, each allowed a few wei of Aave rounding.
    uint256 public ghost_equityOps;

    uint256 public ghost_emergencyRedeems;
    uint256 public ghost_maxEmergencyRedeemError;
    uint256 public ghost_recoveries;

    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    YieldBearingVault public vault;
    WETHLoopStrategy public strategy;
    IERC20 public weth;
    IPool public aavePool;
    address public aToken;
    address public debtToken;

    address[] public actors;
    address public admin;
    address public owner;

    uint256 constant MIN_DEPOSIT = 1;
    uint256 constant MAX_DEPOSIT = 100 ether;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        YieldBearingVault _vault,
        WETHLoopStrategy _strategy,
        IERC20 _weth,
        IPool _aavePool,
        address _aToken,
        address _debtToken,
        address[] memory _actors,
        address _admin,
        address _owner
    ) {
        vault = _vault;
        strategy = _strategy;
        weth = _weth;
        aavePool = _aavePool;
        aToken = _aToken;
        debtToken = _debtToken;
        actors = _actors;
        admin = _admin;
        owner = _owner;

        ghost_minHealthFactorObserved = type(uint256).max;
    }

    /*//////////////////////////////////////////////////////////////
                          HANDLER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 actorSeed, uint256 amount) external {
        if (vault.emergencyMode()) return;

        address actor = _selectActor(actorSeed);
        amount = bound(amount, MIN_DEPOSIT, MAX_DEPOSIT);

        deal(address(weth), actor, amount);

        vm.startPrank(actor);
        weth.approve(address(vault), amount);
        vault.deposit(amount, actor);
        vm.stopPrank();

        ghost_totalInvested += amount;
        // The vault forwards the whole deposit to the strategy
        ghost_expectedEquity += amount;
        ghost_equityOps++;

        _updatePositionSnapshot();
    }

    function withdraw(uint256 actorSeed, uint256 withdrawBps) external {
        address actor = _selectActor(actorSeed);

        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return;

        withdrawBps = bound(withdrawBps, 100, 10000);
        uint256 sharesToRedeem = (shares * withdrawBps) / 10000;
        if (sharesToRedeem == 0) return;

        uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);
        if (expectedAssets == 0) return;

        bool inEmergency = vault.emergencyMode();
        uint256 proportionalShare = sharesToRedeem * _rawEquity() / vault.totalSupply();
        uint256 vaultIdleBefore = weth.balanceOf(address(vault));
        uint256 balanceBefore = weth.balanceOf(actor);

        vm.startPrank(actor);
        uint256 assets = vault.redeem(sharesToRedeem, actor, actor);
        vm.stopPrank();

        uint256 received = weth.balanceOf(actor) - balanceBefore;
        if (inEmergency) {
            uint256 error = received > proportionalShare ? received - proportionalShare : proportionalShare - received;
            if (error > ghost_maxEmergencyRedeemError) ghost_maxEmergencyRedeemError = error;
            ghost_emergencyRedeems++;
        }

        // The vault pays from its idle balance first and pulls the rest from the strategy
        uint256 pulledFromStrategy = assets - (vaultIdleBefore - weth.balanceOf(address(vault)));
        ghost_expectedEquity -= pulledFromStrategy;
        ghost_equityOps++;

        ghost_totalDivested += assets;

        _updatePositionSnapshot();
    }

    function checkHealth() external {
        ghost_healthCheckCalls++;

        bool isHealthy = strategy.checkHealth();

        if (!isHealthy) {
            ghost_healthCheckFailures++;
            ghost_emergencyDivestCount++;
            ghost_equityOps++;
        }

        _updatePositionSnapshot();
    }

    /**
     * @notice Makes the position unhealthy relative to the thresholds and runs checkHealth(), then restores them.
     */
    function triggerEmergency() external {
        if (vault.emergencyMode()) return;
        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(strategy));
        if (healthFactor == type(uint256).max) return;

        uint256 minHealthFactor = strategy.minHealthFactor();
        uint256 targetHealthFactor = strategy.targetHealthFactor();

        vm.prank(admin);
        strategy.setHealthFactors(healthFactor + 1, healthFactor + 2);
        bool isHealthy = strategy.checkHealth();
        vm.prank(admin);
        strategy.setHealthFactors(minHealthFactor, targetHealthFactor);

        ghost_healthCheckCalls++;
        if (!isHealthy) {
            ghost_healthCheckFailures++;
            ghost_emergencyDivestCount++;
            ghost_equityOps++;
        }

        _updatePositionSnapshot();
    }

    /**
     * @notice Admin deactivates emergency mode and then reinvests the idle WETH.
     */
    function recover() external {
        if (!vault.emergencyMode()) return;

        vm.startPrank(admin);
        vault.setEmergencyMode(false);
        vault.reinvest();
        vm.stopPrank();

        ghost_recoveries++;
        ghost_equityOps++;
        _updatePositionSnapshot();
    }

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1 hours, 7 days);
        uint256 equityBefore = strategy.totalAssets();
        vm.warp(block.timestamp + seconds_);

        // Interest is external to the strategy's accounting: record it so equity checks stay exact
        uint256 equityAfter = strategy.totalAssets();
        int256 interest = int256(equityAfter) - int256(equityBefore);
        ghost_interest += interest;
        ghost_expectedEquity = uint256(int256(ghost_expectedEquity) + interest);

        _updatePositionSnapshot();
    }

    /*//////////////////////////////////////////////////////////////
                           HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Vault equity from raw balances: vault idle + strategy collateral + strategy idle - strategy debt.
     */
    function _rawEquity() internal view returns (uint256) {
        uint256 assets = weth.balanceOf(address(vault)) + IERC20(aToken).balanceOf(address(strategy)) + weth.balanceOf(address(strategy));
        uint256 debt = IERC20(debtToken).balanceOf(address(strategy));
        return assets > debt ? assets - debt : 0;
    }

    function _selectActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _updatePositionSnapshot() internal {
        ghost_lastCollateral = IERC20(aToken).balanceOf(address(strategy));
        ghost_lastDebt = IERC20(debtToken).balanceOf(address(strategy));

        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(strategy));
        ghost_lastHealthFactor = healthFactor;

        if (healthFactor > 0 && healthFactor < ghost_minHealthFactorObserved) {
            ghost_minHealthFactorObserved = healthFactor;
        }

        if (ghost_lastCollateral > 0 && ghost_lastCollateral > ghost_lastDebt) {
            uint256 netEquity = ghost_lastCollateral - ghost_lastDebt;
            uint256 leverage = (ghost_lastCollateral * 100) / netEquity;
            if (leverage > ghost_maxLeverageObserved) {
                ghost_maxLeverageObserved = leverage;
            }
        }
    }

    function getActorCount() external view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 index) external view returns (address) {
        return actors[index];
    }
}
