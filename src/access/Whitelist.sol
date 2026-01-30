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
    error EmptyArray();

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
        _onlyWhitelisted(account);
        _;
    }

    function _onlyWhitelisted(address account) internal view {
        if (!isWhitelisted[account]) {
            revert NotWhitelisted(account);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function addToWhitelist(address account) external onlyOwner {
        // Skip if already whitelisted
        if (isWhitelisted[account]) return;
        isWhitelisted[account] = true;
        emit WhitelistedAdded(account);
    }

    function removeFromWhitelist(address account) external onlyOwner {
        // Skip if not whitelisted
        if (!isWhitelisted[account]) return;
        isWhitelisted[account] = false;
        emit WhitelistedRemoved(account);
    }

    /// @notice Amortizes fixed tx costs (~23k per address) across batch
    function addBatchToWhitelist(address[] calldata accounts) external onlyOwner {
        uint256 length = accounts.length;
        if (length == 0) revert EmptyArray();

        for (uint256 i; i < length;) {
            address account = accounts[i];
            if (!isWhitelisted[account]) {
                isWhitelisted[account] = true;
                emit WhitelistedAdded(account);
            }
            unchecked { ++i; }
        }
    }

    /// @notice Amortizes fixed tx costs (~23k per address) across batch
    function removeBatchFromWhitelist(address[] calldata accounts) external onlyOwner {
        uint256 length = accounts.length;
        if (length == 0) revert EmptyArray();

        for (uint256 i; i < length;) {
            address account = accounts[i];
            if (isWhitelisted[account]) {
                isWhitelisted[account] = false;
                emit WhitelistedRemoved(account);
            }
            unchecked { ++i; }
        }
    }
}
