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

        vm.startPrank(actor);
        uint256 assets = vault.redeem(sharesToRedeem, actor, actor);
        vm.stopPrank();

        ghost_totalDivested += assets;

        _updatePositionSnapshot();
    }

    function checkHealth() external {
        ghost_healthCheckCalls++;

        bool isHealthy = strategy.checkHealth();

        if (!isHealthy) {
            ghost_healthCheckFailures++;
            ghost_emergencyDivestCount++;
        }

        _updatePositionSnapshot();
    }

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1 hours, 7 days);
        vm.warp(block.timestamp + seconds_);

        _updatePositionSnapshot();
    }

    /*//////////////////////////////////////////////////////////////
                           HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
