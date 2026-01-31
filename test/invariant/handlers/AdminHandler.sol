// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {YieldBearingVault} from "../../../src/vaults/YieldBearingVault.sol";

/**
 * @title AdminHandler
 * @notice Handler for administrative operations in stateful invariant testing.
 * @dev Executes random whitelist/fee/emergency operations with state tracking.
 */
contract AdminHandler is Test {
    /*//////////////////////////////////////////////////////////////
                            GHOST VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 public ghost_whitelistAdditions;
    uint256 public ghost_whitelistRemovals;
    uint256 public ghost_feeChanges;
    uint256 public ghost_emergencyModeChanges;

    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    YieldBearingVault public vault;
    address public admin;
    address public owner;
    address[] public potentialUsers;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(YieldBearingVault _vault, address _admin, address _owner, address[] memory _potentialUsers) {
        vault = _vault;
        admin = _admin;
        owner = _owner;
        potentialUsers = _potentialUsers;
    }

    /*//////////////////////////////////////////////////////////////
                          HANDLER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function addToWhitelist(uint256 userSeed) external {
        address user = potentialUsers[userSeed % potentialUsers.length];

        if (vault.isWhitelisted(user)) return;

        vm.prank(owner);
        vault.addToWhitelist(user);

        ghost_whitelistAdditions++;

        assert(vault.isWhitelisted(user));
    }

    function removeFromWhitelist(uint256 userSeed) external {
        address user = potentialUsers[userSeed % potentialUsers.length];

        if (!vault.isWhitelisted(user)) return;
        if (vault.balanceOf(user) > 0) return;

        vm.prank(owner);
        vault.removeFromWhitelist(user);

        ghost_whitelistRemovals++;

        assert(!vault.isWhitelisted(user));
    }

    function setProtocolFee(uint256 feeBps) external {
        feeBps = bound(feeBps, 0, 2500);

        vm.prank(admin);
        vault.setProtocolFee(uint16(feeBps));

        ghost_feeChanges++;

        assert(vault.protocolFeeBps() == feeBps);
    }

    function toggleEmergencyMode() external {
        bool currentMode = vault.emergencyMode();

        vm.prank(admin);
        vault.setEmergencyMode(!currentMode);

        ghost_emergencyModeChanges++;

        assert(vault.emergencyMode() == !currentMode);
    }
}
