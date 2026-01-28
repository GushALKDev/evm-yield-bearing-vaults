// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Whitelist
 * @author YieldBearingVaults Team
 * @notice Abstract contract for managing a whitelist of addresses.
 */
abstract contract Whitelist is Ownable {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotWhitelisted(address account);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event WhitelistedAdded(address indexed account);
    event WhitelistedRemoved(address indexed account);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(address => bool) public isWhitelisted;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _initialOwner) Ownable(_initialOwner) {}

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyWhitelisted(address account) {
        if (!isWhitelisted[account]) {
            revert NotWhitelisted(account);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function addToWhitelist(address account) external onlyOwner {
        isWhitelisted[account] = true;
        emit WhitelistedAdded(account);
    }

    function removeFromWhitelist(address account) external onlyOwner {
        isWhitelisted[account] = false;
        emit WhitelistedRemoved(account);
    }
}
