// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Whitelist
/// @notice Abstract contract for managing a whitelist of addresses.
/// @dev Used by Vaults to restrict deposit/transfer permissions.
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
                               LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts if the account is not whitelisted.
    modifier onlyWhitelisted(address account) {
        if (!isWhitelisted[account]) {
            revert NotWhitelisted(account);
        }
        _;
    }

    /// @notice Adds an account to the whitelist.
    /// @param account The address to whitelist.
    function addToWhitelist(address account) external onlyOwner {
        isWhitelisted[account] = true;
        emit WhitelistedAdded(account);
    }

    /// @notice Removes an account from the whitelist.
    /// @param account The address to remove.
    function removeFromWhitelist(address account) external onlyOwner {
        isWhitelisted[account] = false;
        emit WhitelistedRemoved(account);
    }
}
