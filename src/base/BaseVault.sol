// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Whitelist} from "../access/Whitelist.sol";
import {BaseStrategy} from "./BaseStrategy.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
    error FeeRecipientNotRemovable(address account);

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
     * @dev Warning: Ensure funds from old strategy are migrated first. Blocked during emergency mode, since the new
     *      strategy would start with its flag off while the vault's is on.
     */
    function setStrategy(BaseStrategy _strategy) external onlyAdmin whenNotEmergency {
        if (address(_strategy) == address(0)) revert InvalidStrategy();
        strategy = _strategy;
        SafeERC20.forceApprove(IERC20(asset()), address(_strategy), type(uint256).max);
        emit StrategySet(address(_strategy));
    }

    /**
     * @dev Deposits are blocked but withdrawals remain active. Deactivation does not reinvest, see reinvest().
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

    /**
     * @notice Reinvests idle assets, the second step of leaving emergency mode.
     * @dev Deposits the vault's own idle balance (initial deposit, donations, rounding) into the strategy, then has
     *      the strategy invest its whole idle balance. totalAssets() does not change.
     */
    function reinvest() external onlyAdmin whenNotEmergency {
        // Checks
        BaseStrategy cachedStrategy = strategy;
        if (address(cachedStrategy) == address(0)) revert InvalidStrategy();

        // Interactions
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle > 0) {
            uint256 expectedShares = cachedStrategy.previewDeposit(idle);
            uint256 actualShares = cachedStrategy.deposit(idle, address(this));
            if (actualShares < expectedShares) revert InsufficientStrategyShares(actualShares, expectedShares);
        }
        cachedStrategy.reinvest();
    }

    function setProtocolFee(uint16 _newFeeBps) external onlyAdmin {
        if (_newFeeBps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeTooHigh();
        protocolFeeBps = _newFeeBps;
        emit ProtocolFeeSet(_newFeeBps);
    }

    /**
     * @dev The recipient receives fee shares, so it must be whitelisted like any other share holder.
     */
    function setFeeRecipient(address _newRecipient) external onlyAdmin {
        if (_newRecipient == address(0)) revert InvalidRecipient();
        if (!isWhitelisted[_newRecipient]) revert NotWhitelisted(_newRecipient);
        feeRecipient = _newRecipient;
        emit FeeRecipientSet(_newRecipient);
    }

    function assessPerformanceFee() public nonReentrant {
        _assessPerformanceFee();
    }

    /*//////////////////////////////////////////////////////////////
                        ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The performance fee is assessed before ERC4626 prices the operation, so shares and assets are
     *      converted at the post-fee share price. Same for mint, withdraw and redeem. Every limit that maxDeposit()
     *      and maxMint() report is enforced where it applies (emergency mode and the whitelist by the modifiers,
     *      the minimum health factor by the strategy), so the ERC4626 comparison with maxDeposit()/maxMint() is not
     *      repeated here: it would add the strategy's health factor reads to every deposit and replace
     *      HealthFactorBelowMinimum with ERC4626ExceededMaxDeposit.
     */
    function deposit(uint256 assets, address receiver) public virtual override nonReentrant whenNotEmergency onlyWhitelisted(receiver) returns (uint256) {
        _assessPerformanceFee();
        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
        return shares;
    }

    function mint(uint256 shares, address receiver) public virtual override nonReentrant whenNotEmergency onlyWhitelisted(receiver) returns (uint256) {
        _assessPerformanceFee();
        uint256 assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public virtual override nonReentrant returns (uint256) {
        _assessPerformanceFee();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public virtual override nonReentrant returns (uint256) {
        _assessPerformanceFee();
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

    /**
     * @dev 0 when deposit() could revert, see _depositsOpen().
     */
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        if (!_depositsOpen(receiver)) return 0;
        return super.maxDeposit(receiver);
    }

    /**
     * @dev 0 when mint() could revert, see _depositsOpen().
     */
    function maxMint(address receiver) public view virtual override returns (uint256) {
        if (!_depositsOpen(receiver)) return 0;
        return super.maxMint(receiver);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Updates HWM and pushes funds to strategy. Emergency mode, whitelist and fees are handled by the entry points.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
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
     * @dev Pulls funds from strategy if needed and updates HWM. Fees are assessed by the entry points.
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal virtual override {
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
     * @dev False during emergency mode, for receivers that are not whitelisted, and when the strategy's maxDeposit()
     *      for the vault is 0 (for the WETH loop, when an investment could end below minHealthFactor). The strategies
     *      report either 0 or type(uint256).max, so their limit is used as all-or-nothing.
     */
    function _depositsOpen(address receiver) internal view returns (bool) {
        if (emergencyMode || !isWhitelisted[receiver]) return false;
        BaseStrategy cachedStrategy = strategy;
        return address(cachedStrategy) == address(0) || cachedStrategy.maxDeposit(address(this)) > 0;
    }

    /**
     * @dev Uses High Water Mark to prevent double-taxing profits.
     *      Fees are minted as new shares, diluting existing holders.
     */
    function _assessPerformanceFee() internal {
        (uint256 feeShares, uint256 currentAssets, uint256 profit) = _pendingFee();
        if (profit == 0) return;

        if (feeShares > 0) {
            _mint(feeRecipient, feeShares);
            emit PerformanceFeePaid(profit, feeShares);
        }

        highWaterMark = currentAssets;
    }

    /**
     * @dev What the next _assessPerformanceFee() would do, without state changes: the fee shares it would mint, the
     *      totalAssets() it would record as the high-water mark and the profit above the mark (all 0 when no fee is
     *      configured or there is no profit).
     */
    function _pendingFee() internal view returns (uint256 feeShares, uint256 currentAssets, uint256 profit) {
        uint16 feeBps = protocolFeeBps;
        if (feeBps == 0 || feeRecipient == address(0)) return (0, 0, 0);

        currentAssets = totalAssets();
        uint256 hwm = highWaterMark;
        if (currentAssets <= hwm) return (0, currentAssets, 0);

        // Unchecked safe (already checked currentAssets > hwm)
        unchecked {
            profit = currentAssets - hwm;
        }
        uint256 feeInAssets = profit * feeBps / MAX_BPS;

        // Priced against assets net of the fee, so the minted shares are worth feeInAssets after minting
        // (convertToShares would price them before the mint dilutes them). Offsets match ERC4626 (+1, +1).
        if (feeInAssets > 0) feeShares = Math.mulDiv(feeInAssets, totalSupply() + 1, currentAssets - feeInAssets + 1);
    }

    /**
     * @dev Conversions count the fee shares that deposit, mint, withdraw and redeem mint before pricing, so
     *      convertTo*, preview* and max* match those calls exactly. totalAssets() needs no change: the fee is paid in
     *      shares, not assets.
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual override returns (uint256) {
        (uint256 feeShares,,) = _pendingFee();
        return Math.mulDiv(assets, totalSupply() + feeShares + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual override returns (uint256) {
        (uint256 feeShares,,) = _pendingFee();
        return Math.mulDiv(shares, totalAssets() + 1, totalSupply() + feeShares + 10 ** _decimalsOffset(), rounding);
    }

    /*//////////////////////////////////////////////////////////////
                          WHITELIST OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The current fee recipient cannot be removed: later fee shares would be minted to a non-whitelisted
     *      address. Reverting is the only option that neither breaks that property nor changes the fee silently
     *      (skipping the mint or clearing the recipient would); the admin first moves the fee to another
     *      whitelisted address with setFeeRecipient().
     */
    function _beforeRemoval(address account) internal view override {
        if (account == feeRecipient) revert FeeRecipientNotRemovable(account);
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
