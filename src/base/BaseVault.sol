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

    BaseStrategy public strategy;
    bool public emergencyMode;
    address public admin;
    address public feeRecipient;

    uint16 public protocolFeeBps;
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
        if (emergencyMode) revert VaultInEmergency();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
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
        strategy = _strategy;
        IERC20(asset()).approve(address(_strategy), type(uint256).max);
        emit StrategySet(address(_strategy));
    }

    /**
     * @dev Deposits are blocked but withdrawals remain active.
     */
    function setEmergencyMode(bool _isOpen) external onlyAdmin {
        emergencyMode = _isOpen;
        if (address(strategy) != address(0)) {
            strategy.setEmergencyMode(_isOpen);
        }
        emit EmergencyModeSet(_isOpen);
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

        if (address(strategy) != address(0)) {
            strategyBalance = strategy.convertToAssets(strategy.balanceOf(address(this)));
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

        highWaterMark += assets;

        if (address(strategy) != address(0)) {
            strategy.deposit(assets, address(this));
        }
    }

    /**
     * @dev Assesses fees, pulls funds from strategy if needed, and updates HWM.
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal virtual override {
        _assessPerformanceFee();

        uint256 localBalance = IERC20(asset()).balanceOf(address(this));

        if (localBalance < assets) {
            if (address(strategy) != address(0)) {
                uint256 shortage = assets - localBalance;
                strategy.withdraw(shortage, address(this), address(this));
            }
        }

        super._withdraw(caller, receiver, owner, assets, shares);

        if (assets > highWaterMark) {
            highWaterMark = 0;
        } else {
            highWaterMark -= assets;
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
        if (protocolFeeBps == 0 || feeRecipient == address(0)) return;

        uint256 currentAssets = totalAssets();

        if (currentAssets > highWaterMark) {
            uint256 profit = currentAssets - highWaterMark;
            uint256 feeInAssets = profit * protocolFeeBps / MAX_BPS;

            if (feeInAssets > 0) {
                uint256 feeShares = convertToShares(feeInAssets);

                if (feeShares > 0) {
                    _mint(feeRecipient, feeShares);
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
