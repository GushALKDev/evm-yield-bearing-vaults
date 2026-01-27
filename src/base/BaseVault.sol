// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Whitelist} from "../access/Whitelist.sol";
import {BaseStrategy} from "./BaseStrategy.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BaseVault
/// @notice Abstract Vault that integrates with a Strategy and enforces Whitelisting.
abstract contract BaseVault is ERC4626, Whitelist, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    BaseStrategy public strategy;
    
    // Circuit Breaker Status
    bool public emergencyMode;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event StrategySet(address indexed strategy);
    event EmergencyModeSet(bool isOpen);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    
    error VaultInEmergency();

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IERC20 _asset, string memory _name, string memory _symbol, address _owner, uint256 _initialDeposit)
        ERC4626(_asset)
        ERC20(_name, _symbol)
        Whitelist(_owner)
    {
        if (_initialDeposit > 0) {
            // Protect against inflation attack (first depositor front-running)
            // by burning the first shares to a dead address.
            SafeERC20.safeTransferFrom(_asset, msg.sender, address(this), _initialDeposit);
            _mint(address(0x000000000000000000000000000000000000dEaD), _initialDeposit);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier whenNotEmergency() {
        if (emergencyMode) revert VaultInEmergency();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the strategy for this vault.
    /// @dev Beware of funds in old strategy!
    function setStrategy(BaseStrategy _strategy) external onlyOwner {
        strategy = _strategy;
        IERC20(asset()).approve(address(_strategy), type(uint256).max);
        emit StrategySet(address(_strategy));
    }
    
    /// @notice Activates or Deactivates Emergency Mode (Circuit Breaker).
    /// @dev Stops deposits on both Vault and Strategy. Withdrawals remain active.
    /// @param _isOpen True to pause, False to unpause.
    function setEmergencyMode(bool _isOpen) external onlyOwner {
        emergencyMode = _isOpen;
        // Propagate panic to strategy if it exists
        if (address(strategy) != address(0)) {
            strategy.setEmergencyMode(_isOpen);
        }
        emit EmergencyModeSet(_isOpen);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /** @dev See {IERC4626-deposit}. */
    function deposit(uint256 assets, address receiver) public virtual override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    /** @dev See {IERC4626-mint}. */
    function mint(uint256 shares, address receiver) public virtual override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    /** @dev See {IERC4626-withdraw}. */
    function withdraw(uint256 assets, address receiver, address owner) public virtual override nonReentrant returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    /** @dev See {IERC4626-redeem}. */
    function redeem(uint256 shares, address receiver, address owner) public virtual override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    /// @notice Calculates total assets including those in the strategy.
    function totalAssets() public view virtual override returns (uint256) {
        uint256 localBalance = IERC20(asset()).balanceOf(address(this));
        uint256 strategyBalance = 0;
        
        if (address(strategy) != address(0)) {
            strategyBalance = strategy.convertToAssets(strategy.balanceOf(address(this)));
        }
        
        return localBalance + strategyBalance;
    }

    /// @dev Hook called after deposit. Pushes funds to strategy.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override whenNotEmergency {
        // Enforce Whitelist for new depositors
        if (!isWhitelisted[receiver]) revert NotWhitelisted(receiver);
        
        super._deposit(caller, receiver, assets, shares);

        // Push funds to strategy if set
        if (address(strategy) != address(0)) {
            strategy.deposit(assets, address(this));
        }
    }

    /// @dev Hook called before withdrawal. Pulls funds from strategy if needed.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal virtual override {
        uint256 localBalance = IERC20(asset()).balanceOf(address(this));
        
        // If not enough local funds, pull from strategy
        if (localBalance < assets) {
            if (address(strategy) != address(0)) {
                uint256 shortage = assets - localBalance;
                // We withdraw exact assets needed. 
                // Since this is BaseStrategy (ERC4626), withdraw arg is 'assets'.
                strategy.withdraw(shortage, address(this), address(this));
            }
        }
        
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC20 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @dev Hook called on any token transfer (mint, burn, transfer).
    /// Used here to enforce whitelist on transfers.
    function _update(address from, address to, uint256 value) internal virtual override {
        // If it's a transfer between users (not minting/burning)
        if (from != address(0) && to != address(0)) {
            if (!isWhitelisted[to]) revert NotWhitelisted(to);
        }
        super._update(from, to, value);
    }
}


