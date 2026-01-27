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

    // Fees
    uint16 public protocolFeeBps; // Basis Points (10000 = 100%)
    address public feeRecipient;
    uint16 constant MAX_BPS = 10_000;
    uint16 constant MAX_PROTOCOL_FEE_BPS = 5000; // Cap fees at 50% for safety
    
    // Performance Fee Accounting
    uint256 public highWaterMark; // Tracks [Principal + Taxed Profits]

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event StrategySet(address indexed strategy);
    event EmergencyModeSet(bool isOpen);
    event ProtocolFeeSet(uint16 feeBps);
    event FeeRecipientSet(address indexed recipient);
    event PerformanceFeePaid(uint256 profit, uint256 feeShares);

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
            
            // Initial deposit counts as principal
            highWaterMark = _initialDeposit;
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

    /// @notice Set the protocol fee basis points.
    /// @param _newFeeBps New fee in BPS (max 2500 = 25%).
    function setProtocolFee(uint16 _newFeeBps) external onlyOwner {
        if (_newFeeBps > MAX_PROTOCOL_FEE_BPS) revert("Fee too high");
        protocolFeeBps = _newFeeBps;
        emit ProtocolFeeSet(_newFeeBps);
    }

    /// @notice Set the recipient of protocol fees.
    /// @param _newRecipient Address to receive fees.
    function setFeeRecipient(address _newRecipient) external onlyOwner {
        if (_newRecipient == address(0)) revert("Invalid recipient");
        feeRecipient = _newRecipient;
        emit FeeRecipientSet(_newRecipient);
    }

    /// @notice Manually trigger performance fee assessment.
    /// @dev Can be called by anyone (e.g., keepers).
    function assessPerformanceFee() public nonReentrant {
        _assessPerformanceFee();
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
        
        // Assess and collect fees on pending profits before state change
        _assessPerformanceFee();

        // Perform Deposit
        super._deposit(caller, receiver, assets, shares);

        // Update High Water Mark with new principal
        highWaterMark += assets;

        // Push funds to strategy if set
        if (address(strategy) != address(0)) {
            strategy.deposit(assets, address(this));
        }
    }

    /// @dev Hook called before withdrawal. Pulls funds from strategy if needed.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal virtual override {
        // Assess and collect fees on pending profits before withdrawal
        _assessPerformanceFee();

        uint256 localBalance = IERC20(asset()).balanceOf(address(this));
        
        // Pull funds from strategy if local balance is insufficient
        if (localBalance < assets) {
            if (address(strategy) != address(0)) {
                uint256 shortage = assets - localBalance;
                strategy.withdraw(shortage, address(this), address(this));
            }
        }
        
        // Perform Withdraw
        super._withdraw(caller, receiver, owner, assets, shares);

        // Update High Water Mark reducing principal. 
        // Reset to 0 if assets exceed HWM (e.g. profit withdrawal when fees are inactive).
        if (assets > highWaterMark) {
            highWaterMark = 0;
        } else {
            highWaterMark -= assets;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Calculates and processes performance fees based on High Water Mark.
    function _assessPerformanceFee() internal {
        if (protocolFeeBps == 0 || feeRecipient == address(0)) return;

        uint256 currentAssets = totalAssets();
        
        if (currentAssets > highWaterMark) {
            uint256 profit = currentAssets - highWaterMark;
            uint256 feeInAssets = profit * protocolFeeBps / MAX_BPS;

            if (feeInAssets > 0) {
                // Calculate fee shares at current rate (dilution)
                uint256 feeShares = convertToShares(feeInAssets);
                
                if (feeShares > 0) {
                    _mint(feeRecipient, feeShares);
                    emit PerformanceFeePaid(profit, feeShares);
                }
            }
            
            // Reset High Water Mark to current assets after fee consolidation
            highWaterMark = currentAssets;
        }
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


