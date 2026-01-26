// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BaseStrategy
/// @notice Abstract base class for strategies compliant with ERC4626.
/// @dev Implements access control for a specific Vault and defines hooks for investment logic.
abstract contract BaseStrategy is ERC4626 {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyVault();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public immutable vault;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IERC20 _asset, address _vault, string memory _name, string memory _symbol) 
        ERC4626(_asset) 
        ERC20(_name, _symbol) 
    {
        vault = _vault;
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           RESTRICTED ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Restrict deposit to the Vault.
     */
    function deposit(uint256 assets, address receiver) public virtual override onlyVault returns (uint256) {
        return super.deposit(assets, receiver);
    }

    /**
     * @dev Restrict mint to the Vault.
     */
    function mint(uint256 shares, address receiver) public virtual override onlyVault returns (uint256) {
        return super.mint(shares, receiver);
    }

    /**
     * @dev Restrict withdraw to the Vault.
     */
    function withdraw(uint256 assets, address receiver, address owner) public virtual override onlyVault returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    /**
     * @dev Restrict redeem to the Vault.
     */
    function redeem(uint256 shares, address receiver, address owner) public virtual override onlyVault returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Internal hook executed after assets are deposited.
     *      Override this to invest the assets into the external protocol.
     *      At this point, the assets are already in this contract.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        super._deposit(caller, receiver, assets, shares);
        _invest(assets);
    }

    /**
     * @dev Internal hook executed before assets are withdrawn.
     *      Override this to divest assets from the external protocol.
     *      Must ensure the contract holds 'assets' amount of tokens after this call.
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal virtual override {
        _divest(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                          ABSTRACT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Logic to invest assets into the underlying protocol.
    function _invest(uint256 assets) internal virtual;

    /// @dev Logic to divest assets from the underlying protocol.
    function _divest(uint256 assets) internal virtual;
}


