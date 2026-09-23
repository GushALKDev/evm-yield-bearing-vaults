// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {YieldBearingVault} from "../../../src/vaults/YieldBearingVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseStrategy} from "../../../src/base/BaseStrategy.sol";

/**
 * @title BaseVaultHandler
 * @notice Handler for vault operations in stateful invariant testing.
 * @dev Executes random deposit/withdraw/transfer operations with ghost variable tracking.
 */
contract BaseVaultHandler is Test {
    /*//////////////////////////////////////////////////////////////
                            GHOST VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalFeesMinted;

    mapping(address => uint256) public ghost_userDeposits;
    mapping(address => uint256) public ghost_userWithdrawals;

    uint256 public ghost_depositCount;
    uint256 public ghost_withdrawCount;
    uint256 public ghost_transferCount;

    /// @dev High-water mark recomputed from its definition in BaseVault (see _applyFeeAssessment).
    uint256 public ghost_expectedHwm;
    /// @dev Assets sent directly to the strategy to simulate yield.
    uint256 public ghost_totalYield;
    uint256 public ghost_yieldCount;

    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    YieldBearingVault public vault;
    IERC20 public asset;
    address[] public actors;
    address public admin;
    address public owner;

    uint256 constant MIN_DEPOSIT = 1;
    uint256 constant MAX_DEPOSIT = 100_000e18;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(YieldBearingVault _vault, IERC20 _asset, address[] memory _actors, address _admin, address _owner) {
        vault = _vault;
        asset = _asset;
        actors = _actors;
        admin = _admin;
        owner = _owner;
        ghost_expectedHwm = _vault.highWaterMark();
    }

    /*//////////////////////////////////////////////////////////////
                          HANDLER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 actorSeed, uint256 amount) external {
        if (vault.emergencyMode()) return;

        address actor = _selectActor(actorSeed);
        amount = bound(amount, MIN_DEPOSIT, MAX_DEPOSIT);

        deal(address(asset), actor, amount);
        _applyFeeAssessment();

        vm.startPrank(actor);
        asset.approve(address(vault), amount);

        uint256 sharesBefore = vault.balanceOf(actor);
        uint256 shares = vault.deposit(amount, actor);
        uint256 sharesAfter = vault.balanceOf(actor);
        vm.stopPrank();

        ghost_totalDeposited += amount;
        ghost_userDeposits[actor] += amount;
        ghost_depositCount++;
        ghost_expectedHwm += amount;

        assert(sharesAfter == sharesBefore + shares);
    }

    function withdraw(uint256 actorSeed, uint256 withdrawBps) external {
        address actor = _selectActor(actorSeed);

        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return;

        withdrawBps = bound(withdrawBps, 1, 10000);
        uint256 sharesToRedeem = (shares * withdrawBps) / 10000;
        if (sharesToRedeem == 0) return;

        uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);
        if (expectedAssets == 0) return;

        _applyFeeAssessment();

        vm.startPrank(actor);
        uint256 balanceBefore = asset.balanceOf(actor);
        uint256 assets = vault.redeem(sharesToRedeem, actor, actor);
        uint256 balanceAfter = asset.balanceOf(actor);
        vm.stopPrank();

        ghost_totalWithdrawn += assets;
        ghost_userWithdrawals[actor] += assets;
        ghost_withdrawCount++;
        ghost_expectedHwm = assets > ghost_expectedHwm ? 0 : ghost_expectedHwm - assets;

        assert(balanceAfter >= balanceBefore + assets - 10);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 transferBps) external {
        address from = _selectActor(fromSeed);
        address to = _selectActor(toSeed);

        if (from == to) return;
        if (!vault.isWhitelisted(to)) return;

        uint256 shares = vault.balanceOf(from);
        if (shares == 0) return;

        transferBps = bound(transferBps, 1, 10000);
        uint256 transferAmount = (shares * transferBps) / 10000;
        if (transferAmount == 0) return;

        uint256 fromBefore = vault.balanceOf(from);
        uint256 toBefore = vault.balanceOf(to);

        vm.prank(from);
        vault.transfer(to, transferAmount);

        ghost_transferCount++;

        assert(vault.balanceOf(from) == fromBefore - transferAmount);
        assert(vault.balanceOf(to) == toBefore + transferAmount);
    }

    function assessFee() external {
        uint256 supplyBefore = vault.totalSupply();
        address feeRecipient = vault.feeRecipient();
        uint256 recipientSharesBefore = feeRecipient != address(0) ? vault.balanceOf(feeRecipient) : 0;

        _applyFeeAssessment();
        vault.assessPerformanceFee();

        uint256 supplyAfter = vault.totalSupply();
        uint256 feesMinted = supplyAfter > supplyBefore ? supplyAfter - supplyBefore : 0;

        ghost_totalFeesMinted += feesMinted;

        if (feesMinted > 0 && feeRecipient != address(0)) {
            assert(vault.balanceOf(feeRecipient) >= recipientSharesBefore + feesMinted);
        }
    }

    /**
     * @notice Sends assets directly to the strategy to simulate yield of up to 10% of its current assets.
     * @dev Skipped while the strategy has no shares outstanding: yield on an empty position would be owned by
     *      the strategy's virtual shares, not by the vault.
     */
    function simulateYield(uint256 amount) external {
        BaseStrategy strategy = vault.strategy();
        uint256 strategyAssets = strategy.totalAssets();
        if (strategy.totalSupply() == 0 || strategyAssets < 10) return;

        amount = bound(amount, 1, strategyAssets / 10);
        deal(address(asset), address(strategy), asset.balanceOf(address(strategy)) + amount);

        ghost_totalYield += amount;
        ghost_yieldCount++;
    }

    /*//////////////////////////////////////////////////////////////
                           HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Mirrors BaseVault._assessPerformanceFee(): with a non-zero fee and a recipient, the HWM is raised to
     *      totalAssets() when assets exceed it. Called right before each vault operation that assesses fees,
     *      while totalAssets() still has its pre-operation value.
     */
    function _applyFeeAssessment() internal {
        if (vault.protocolFeeBps() == 0 || vault.feeRecipient() == address(0)) return;
        uint256 currentAssets = vault.totalAssets();
        if (currentAssets > ghost_expectedHwm) ghost_expectedHwm = currentAssets;
    }

    function _selectActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function getActorCount() external view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 index) external view returns (address) {
        return actors[index];
    }
}
