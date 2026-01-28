// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseVault} from "./BaseVault.sol";

/**
 * @title BaseStrategy
 * @author YieldBearingVaults Team
 * @notice Abstract base class for yield-generating strategies compliant with ERC4626.
 * @dev Strategies are ERC4626 vaults that only accept deposits from their parent Vault.
 *      They implement hooks for investing/divesting assets into external protocols.
 *      Includes emergency mode circuit breaker for pausing deposits while allowing withdrawals.
 */
abstract contract BaseStrategy is ERC4626 {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public immutable vault;
    bool public emergencyMode;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event EmergencyModeSet(bool isOpen);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyVault();
    error NotVaultAdmin();
    error StrategyInEmergency();

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

    modifier whenNotEmergency() {
        if (emergencyMode) revert StrategyInEmergency();
        _;
    }

    modifier onlyVaultAdmin() {
        if (msg.sender != BaseVault(vault).admin()) revert NotVaultAdmin();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Blocked during emergency mode.
     */
    function deposit(uint256 assets, address receiver) public virtual override onlyVault whenNotEmergency returns (uint256) {
        return super.deposit(assets, receiver);
    }

    /**
     * @dev Blocked during emergency mode.
     */
    function mint(uint256 shares, address receiver) public virtual override onlyVault whenNotEmergency returns (uint256) {
        return super.mint(shares, receiver);
    }

    /**
     * @dev Allowed during emergency mode (exit hatch).
     */
    function withdraw(uint256 assets, address receiver, address owner) public virtual override onlyVault returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    /**
     * @dev Allowed during emergency mode (exit hatch).
     */
    function redeem(uint256 shares, address receiver, address owner) public virtual override onlyVault returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setEmergencyMode(bool _isOpen) external onlyVault {
        emergencyMode = _isOpen;
        emit EmergencyModeSet(_isOpen);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Invests deposited assets into the external protocol.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        super._deposit(caller, receiver, assets, shares);
        _invest(assets);
    }

    /**
     * @dev Divests assets from the external protocol before withdrawal.
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal virtual override {
        _divest(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                          ABSTRACT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _invest(uint256 assets) internal virtual;

    /**
     * @dev Must ensure the contract holds `assets` amount after this call.
     */
    function _divest(uint256 assets) internal virtual;

    function harvest() external virtual;
    function checkHealth() external view virtual returns (bool);
}
