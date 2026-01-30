// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Whitelist} from "../access/Whitelist.sol";
import {BaseStrategy} from "./BaseStrategy.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BaseVault
 * @author YieldBearingVaults Team
 * @notice Abstract ERC4626 Vault with whitelisting, strategy integration, and performance fees.
 * @dev Core features:
 *      - Whitelist-gated deposits and transfers
 *      - Pluggable strategy for yield generation
 *      - High Water Mark performance fee mechanism
 *      - Emergency mode circuit breaker
 *      - Inflation attack protection via initial deposit
 */
abstract contract BaseVault is ERC4626, Whitelist, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    // Packed in single slot        // 23 bytes
    BaseStrategy public strategy;   // 20 bytes
    uint16 public protocolFeeBps;   // 2 bytes
    bool public emergencyMode;      // 1 byte

    address public admin;
    address public feeRecipient;

    uint16 constant MAX_BPS = 10_000;
    uint16 constant MAX_PROTOCOL_FEE_BPS = 2500;

    /**
     * @dev Tracks principal plus already-taxed profits.
     */
    uint256 public highWaterMark;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event StrategySet(address indexed strategy);
    event EmergencyModeSet(bool isOpen);
    event ProtocolFeeSet(uint16 feeBps);
    event FeeRecipientSet(address indexed recipient);
    event PerformanceFeePaid(uint256 profit, uint256 feeShares);
    event AdminSet(address indexed newAdmin);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    uint256 constant REQUIRED_INITIAL_DEPOSIT = 1000;

    error VaultInEmergency();
    error NotAdmin();
    error IncorrectInitialDeposit(uint256 provided);
    error InvalidAdmin();
    error ProtocolFeeTooHigh();
    error InvalidRecipient();
    error NotStrategy();
    error InvalidStrategy();
    error InsufficientStrategyShares(uint256 actual, uint256 expected);
    error InsufficientStrategySharesBurned(uint256 actual, uint256 expected);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Burns initial shares to dead address for inflation attack protection.
     */
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _owner,
        address _admin,
        uint256 _initialDeposit
    ) ERC4626(_asset) ERC20(_name, _symbol) Whitelist(_owner) {
        if (_admin == address(0)) revert InvalidAdmin();
        admin = _admin;

        if (_initialDeposit != REQUIRED_INITIAL_DEPOSIT) revert IncorrectInitialDeposit(_initialDeposit);

        SafeERC20.safeTransferFrom(_asset, msg.sender, address(this), _initialDeposit);
        _mint(address(0x000000000000000000000000000000000000dEaD), _initialDeposit);

        highWaterMark = _initialDeposit;
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier whenNotEmergency() {
        _whenNotEmergency();
        _;
    }

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    modifier onlyStrategy() {
        _onlyStrategy();
        _;
    }

    function _whenNotEmergency() internal view {
        if (emergencyMode) revert VaultInEmergency();
    }

    function _onlyAdmin() internal view {
        if (msg.sender != admin) revert NotAdmin();
    }

    function _onlyStrategy() internal view {
        if (msg.sender != address(strategy)) revert NotStrategy();
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert InvalidAdmin();
        admin = _newAdmin;
        emit AdminSet(_newAdmin);
    }

    /**
     * @dev Warning: Ensure funds from old strategy are migrated first.
     */
    function setStrategy(BaseStrategy _strategy) external onlyAdmin {
        if (address(_strategy) == address(0)) revert InvalidStrategy();
        strategy = _strategy;
        SafeERC20.forceApprove(IERC20(asset()), address(_strategy), type(uint256).max);
        emit StrategySet(address(_strategy));
    }

    /**
     * @dev Deposits are blocked but withdrawals remain active.
     */
    function setEmergencyMode(bool _active) external onlyAdmin {
        emergencyMode = _active;
        BaseStrategy cachedStrategy = strategy;
        if (address(cachedStrategy) != address(0)) {
            cachedStrategy.setEmergencyMode(_active);
        }
        emit EmergencyModeSet(_active);
    }

    /**
     * @notice Allows strategy to activate emergency mode when health check fails.
     * @dev Only callable by the strategy contract. Cannot deactivate emergency mode.
     */
    function activateEmergencyMode() external onlyStrategy {
        emergencyMode = true;
        BaseStrategy cachedStrategy = strategy;
        if (address(cachedStrategy) != address(0)) {
            cachedStrategy.setEmergencyMode(true);
        }
        emit EmergencyModeSet(true);
    }

    function setProtocolFee(uint16 _newFeeBps) external onlyAdmin {
        if (_newFeeBps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeTooHigh();
        protocolFeeBps = _newFeeBps;
        emit ProtocolFeeSet(_newFeeBps);
    }

    function setFeeRecipient(address _newRecipient) external onlyAdmin {
        if (_newRecipient == address(0)) revert InvalidRecipient();
        feeRecipient = _newRecipient;
        emit FeeRecipientSet(_newRecipient);
    }

    function assessPerformanceFee() public nonReentrant {
        _assessPerformanceFee();
    }

    /*//////////////////////////////////////////////////////////////
                        ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, address receiver) public virtual override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public virtual override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public virtual override nonReentrant returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public virtual override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    function totalAssets() public view virtual override returns (uint256) {
        uint256 localBalance = IERC20(asset()).balanceOf(address(this));
        uint256 strategyBalance = 0;

        BaseStrategy cachedStrategy = strategy;
        if (address(cachedStrategy) != address(0)) {
            strategyBalance = cachedStrategy.convertToAssets(cachedStrategy.balanceOf(address(this)));
        }

        return localBalance + strategyBalance;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Enforces whitelist, assesses fees, updates HWM, and pushes funds to strategy.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override whenNotEmergency {
        if (!isWhitelisted[receiver]) revert NotWhitelisted(receiver);

        _assessPerformanceFee();

        super._deposit(caller, receiver, assets, shares);

        // Gas: unchecked safe, overflow impossible (HWM bounded by total token supply << uint256.max)
        unchecked {
            highWaterMark += assets;
        }

        BaseStrategy cachedStrategy = strategy;
        if (address(cachedStrategy) != address(0)) {
            uint256 expectedShares = cachedStrategy.previewDeposit(assets);
            uint256 actualShares = cachedStrategy.deposit(assets, address(this));
            if (actualShares < expectedShares) revert InsufficientStrategyShares(actualShares, expectedShares);
        }
    }

    /**
     * @dev Assesses fees, pulls funds from strategy if needed, and updates HWM.
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal virtual override {
        _assessPerformanceFee();

        uint256 localBalance = IERC20(asset()).balanceOf(address(this));

        if (localBalance < assets) {
            BaseStrategy cachedStrategy = strategy;
            if (address(cachedStrategy) != address(0)) {
                uint256 shortage = assets - localBalance;
                uint256 expectedShares = cachedStrategy.previewWithdraw(shortage);
                uint256 actualShares = cachedStrategy.withdraw(shortage, address(this), address(this));
                if (actualShares > expectedShares) revert InsufficientStrategySharesBurned(actualShares, expectedShares);
            }
        }

        super._withdraw(caller, receiver, owner, assets, shares);

        // Unchecked safe (already checked assets <= hwm)
        uint256 hwm = highWaterMark;
        if (assets > hwm) {
            highWaterMark = 0;
        } else {
            unchecked {
                highWaterMark = hwm - assets;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Uses High Water Mark to prevent double-taxing profits.
     *      Fees are minted as new shares, diluting existing holders.
     */
    function _assessPerformanceFee() internal {
        uint16 feeBps = protocolFeeBps;
        address recipient = feeRecipient;

        if (feeBps == 0 || recipient == address(0)) return;

        uint256 currentAssets = totalAssets();
        uint256 hwm = highWaterMark;

        if (currentAssets > hwm) {
            // Unchecked safe (already checked currentAssets > hwm)
            uint256 profit;
            unchecked {
                profit = currentAssets - hwm;
            }
            uint256 feeInAssets = profit * feeBps / MAX_BPS;

            if (feeInAssets > 0) {
                uint256 feeShares = convertToShares(feeInAssets);

                if (feeShares > 0) {
                    _mint(recipient, feeShares);
                    emit PerformanceFeePaid(profit, feeShares);
                }
            }

            highWaterMark = currentAssets;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            ERC20 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Enforces whitelist on transfers between users (not minting/burning).
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0) && to != address(0)) {
            if (!isWhitelisted[to]) revert NotWhitelisted(to);
        }
        super._update(from, to, value);
    }
}
