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

    /**
     * @dev Virtual share offset (OpenZeppelin ERC4626 inflation mitigation). Strategy shares are only held
     *      by the vault, so the vault's dead shares do not protect strategy share pricing. With idle assets
     *      counted in totalAssets(), a donation to an empty strategy would otherwise round the vault's
     *      strategy shares down to zero.
     */
    uint8 private constant DECIMALS_OFFSET = 6;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event EmergencyModeSet(bool isOpen);
    event LeverageSet(uint8 newLeverage);
    event HealthFactorsSet(uint256 minHealth, uint256 targetHealth);
    event EmergencyExitFailed(bytes reason);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyVault();
    error NotVaultAdmin();
    error StrategyInEmergency();
    error OnlySelf();

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
     * @dev Blocked during emergency mode. The limits that maxDeposit() reports are enforced where they apply
     *      (emergency mode by the modifier, strategy-specific checks in _invest()), so the ERC4626 comparison with
     *      maxDeposit() is not repeated here: it would duplicate those reads and hide the specific revert reason.
     */
    function deposit(uint256 assets, address receiver) public virtual override onlyVault whenNotEmergency returns (uint256) {
        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
        return shares;
    }

    /**
     * @dev Blocked during emergency mode. Same limit handling as deposit().
     */
    function mint(uint256 shares, address receiver) public virtual override onlyVault whenNotEmergency returns (uint256) {
        uint256 assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);
        return assets;
    }

    /**
     * @dev 0 during emergency mode, since deposit() reverts.
     */
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        if (emergencyMode) return 0;
        return super.maxDeposit(receiver);
    }

    /**
     * @dev 0 during emergency mode, since mint() reverts.
     */
    function maxMint(address receiver) public view virtual override returns (uint256) {
        if (emergencyMode) return 0;
        return super.maxMint(receiver);
    }

    /**
     * @dev Allowed during emergency mode.
     */
    function withdraw(uint256 assets, address receiver, address owner) public virtual override onlyVault returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    /**
     * @dev Allowed during emergency mode.
     */
    function redeem(uint256 shares, address receiver, address owner) public virtual override onlyVault returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Activation always attempts to close the external position, whoever triggered it (admin or health
     *      check). If the exit reverts, emergency mode stays active, EmergencyExitFailed is emitted and
     *      withdrawals keep working through _divest(). Calling it again with true retries the exit.
     *      Deactivation only clears the flag; idle assets are reinvested in a separate step with reinvest(),
     *      so leaving emergency mode never depends on the reinvestment succeeding.
     */
    function setEmergencyMode(bool _active) external onlyVault {
        // Effects
        emergencyMode = _active;
        emit EmergencyModeSet(_active);

        // Interactions
        if (_active) {
            try this.exitPosition() {}
            catch (bytes memory reason) {
                emit EmergencyExitFailed(reason);
            }
        }
    }

    /**
     * @notice Invests the idle assets into the external protocol.
     * @dev Second step of leaving emergency mode, called by the vault admin through the vault.
     */
    function reinvest() external onlyVault whenNotEmergency {
        _reinvest();
    }

    /**
     * @notice Closes the external position and keeps the proceeds as idle assets.
     * @dev External only so setEmergencyMode() can call it inside try/catch. Callable by the strategy itself only.
     */
    function exitPosition() external {
        if (msg.sender != address(this)) revert OnlySelf();
        _exitPosition();
    }

    /**
     * @dev Invests the whole idle balance. Strategies override it to add post-conditions.
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
     * @dev Divests assets from the external protocol before withdrawal, in every mode.
     *      _divest() pays from idle assets first, so after an emergency exit it does not touch the protocol,
     *      and if the exit failed it deleverages proportionally.
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
     * @dev Closes the external position. Default is a no-op for strategies without one.
     */
    function _exitPosition() internal virtual {}

    /**
     * @dev Must ensure the contract holds `assets` amount after this call.
     */
    function _divest(uint256 assets) internal virtual;

    function harvest() external virtual;
    function checkHealth() external virtual returns (bool);
}
