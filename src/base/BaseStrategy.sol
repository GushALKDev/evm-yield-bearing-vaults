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

    address public immutable VAULT;
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
        VAULT = _vault;
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyVault() {
        _onlyVault();
        _;
    }

    modifier whenNotEmergency() {
        _whenNotEmergency();
        _;
    }

    modifier onlyVaultAdmin() {
        _onlyVaultAdmin();
        _;
    }

    function _onlyVault() internal view {
        if (msg.sender != VAULT) revert OnlyVault();
    }

    function _whenNotEmergency() internal view {
        if (emergencyMode) revert StrategyInEmergency();
    }

    function _onlyVaultAdmin() internal view {
        if (msg.sender != BaseVault(VAULT).admin()) revert NotVaultAdmin();
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

    function setEmergencyMode(bool _active) external onlyVault {
        bool wasInEmergency = emergencyMode;
        emergencyMode = _active;
        emit EmergencyModeSet(_active);

        // If deactivating emergency mode, reinvest available assets
        if (wasInEmergency && !_active) {
            _reinvest();
        }
    }

    /**
     * @dev Reinvests all available assets after emergency mode is deactivated.
     *      Strategy balance is invested back into the protocol.
     */
    function _reinvest() internal virtual {
        uint256 availableAssets = IERC20(asset()).balanceOf(address(this));
        if (availableAssets > 0) {
            _invest(availableAssets);
        }
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
     *      In emergency mode, skip divest since position is already closed.
     *      Assets are held directly in the strategy after emergency divest,
     *      so we only need to transfer them to the receiver.
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal virtual override {
        // Only divest if not in emergency mode (position already closed during emergency)
        if (!emergencyMode) {
            _divest(assets);
        }
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
    function checkHealth() external virtual returns (bool);
}
