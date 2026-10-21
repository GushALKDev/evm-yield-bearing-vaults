// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {IPool} from "../../src/interfaces/aave/IPool.sol";

/**
 * @title DemoOperator
 * @author GushALKDev
 * @notice Testnet-only holder of the vault's owner and admin roles, so that visitors of the public demo can join the
 *         whitelist and run the emergency cycle themselves. Never give it the roles of a vault with real value.
 * @dev What anyone can call, and what each call can and cannot do:
 *      - join(): whitelists the caller, nobody else. Idempotent, like the vault's addToWhitelist().
 *      - shock(): raises minHealthFactor above the strategy's live health factor (and targetHealthFactor above that),
 *        which is how the test suite simulates an unhealthy position. It changes nothing else: the position is closed
 *        only when someone calls the strategy's permissionless checkHealth(). At most once per SHOCK_COOLDOWN, only
 *        while the strategy has debt and emergency mode is off. Until checkHealth() or restore() runs, deposits revert
 *        with HealthFactorBelowMinimum.
 *      - restore(): clears emergency mode and puts both health factor thresholds back to their deployment values.
 *        Open to anyone at any time, so a shock keeps deposits closed only until someone calls it.
 *      - reinvest(): the vault's reinvest(), which the strategy reverts unless the position ends at or above
 *        targetHealthFactor.
 *      The owner of this contract (the deployer) can hand both roles to other addresses with handBack(), which ends
 *      the demo controls. Nothing else is reachable: setStrategy, setProtocolFee, setFeeRecipient, setLeverage,
 *      setAdmin and whitelist removals have no path through this contract.
 *      Vault shares held by this contract stay here, since it has no function to redeem or transfer them. The deploy
 *      script uses that to lock the seed position.
 */
contract DemoOperator is Ownable {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ShockCooldown(uint256 nextShockAt);
    error NoOpenPosition();
    error AlreadyInEmergency();
    error NothingToRestore();
    error RenounceOwnershipDisabled();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Joined(address indexed account);
    event Shocked(address indexed caller, uint256 healthFactor, uint256 minHealthFactor, uint256 targetHealthFactor);
    event Restored(address indexed caller, bool clearedEmergency, bool resetThresholds);
    event HandedBack(address indexed newOwner, address indexed newAdmin);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Minimum time between two shocks.
     */
    uint256 public constant SHOCK_COOLDOWN = 1 hours;

    /**
     * @notice Offsets added to the live health factor by shock(), the same as the test suite's _makeUnhealthy().
     */
    uint256 public constant SHOCK_MIN_OFFSET = 0.05e18;
    uint256 public constant SHOCK_TARGET_OFFSET = 0.08e18;

    YieldBearingVault public immutable VAULT;
    WETHLoopStrategy public immutable STRATEGY;

    /**
     * @notice Thresholds restore() puts back: the strategy's values when this contract was deployed.
     */
    uint256 public immutable DEFAULT_MIN_HEALTH_FACTOR;
    uint256 public immutable DEFAULT_TARGET_HEALTH_FACTOR;

    /**
     * @notice Timestamp of the last shock (0 before the first one).
     */
    uint256 public lastShockAt;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(YieldBearingVault _vault, WETHLoopStrategy _strategy, address _owner) Ownable(_owner) {
        VAULT = _vault;
        STRATEGY = _strategy;
        DEFAULT_MIN_HEALTH_FACTOR = _strategy.minHealthFactor();
        DEFAULT_TARGET_HEALTH_FACTOR = _strategy.targetHealthFactor();
    }

    /*//////////////////////////////////////////////////////////////
                           PUBLIC DEMO CONTROLS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds the caller to the vault's whitelist, so it can receive vault shares.
     */
    function join() external {
        // Skip if already whitelisted, as the vault's addToWhitelist() does
        if (VAULT.isWhitelisted(msg.sender)) return;
        VAULT.addToWhitelist(msg.sender);
        emit Joined(msg.sender);
    }

    /**
     * @notice Raises the strategy's thresholds above its live health factor, so checkHealth() closes the position.
     */
    function shock() external {
        // Checks
        if (VAULT.emergencyMode()) revert AlreadyInEmergency();
        uint256 last = lastShockAt;
        if (last != 0 && block.timestamp < last + SHOCK_COOLDOWN) revert ShockCooldown(last + SHOCK_COOLDOWN);
        //slither-disable-next-line unused-return
        (,,,,, uint256 healthFactor) = IPool(STRATEGY.AAVE_POOL()).getUserAccountData(address(STRATEGY));
        // Aave reports type(uint256).max without debt: there is no position to make unhealthy
        if (healthFactor == type(uint256).max) revert NoOpenPosition();

        // Effects
        lastShockAt = block.timestamp;

        // Interactions
        uint256 minimum = healthFactor + SHOCK_MIN_OFFSET;
        uint256 target = healthFactor + SHOCK_TARGET_OFFSET;
        STRATEGY.setHealthFactors(minimum, target);
        emit Shocked(msg.sender, healthFactor, minimum, target);
    }

    /**
     * @notice Clears emergency mode and resets the thresholds, the first step of the recovery. Idle WETH stays idle.
     */
    function restore() external {
        // Checks
        bool emergency = VAULT.emergencyMode();
        bool shocked = STRATEGY.minHealthFactor() != DEFAULT_MIN_HEALTH_FACTOR || STRATEGY.targetHealthFactor() != DEFAULT_TARGET_HEALTH_FACTOR;
        if (!emergency && !shocked) revert NothingToRestore();

        // Interactions
        if (emergency) VAULT.setEmergencyMode(false);
        if (shocked) STRATEGY.setHealthFactors(DEFAULT_MIN_HEALTH_FACTOR, DEFAULT_TARGET_HEALTH_FACTOR);
        emit Restored(msg.sender, emergency, shocked);
    }

    /**
     * @notice The vault's reinvest(), the second step of the recovery.
     */
    function reinvest() external {
        VAULT.reinvest();
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER ONLY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Hands the vault's admin and owner roles to other addresses, which ends the public demo controls.
     */
    function handBack(address newOwner, address newAdmin) external onlyOwner {
        VAULT.setAdmin(newAdmin);
        VAULT.transferOwnership(newOwner);
        emit HandedBack(newOwner, newAdmin);
    }

    /**
     * @dev Disabled: without an owner the roles could never be handed back.
     */
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }
}
