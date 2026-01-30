// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseStrategy} from "../base/BaseStrategy.sol";
import {BaseVault} from "../base/BaseVault.sol";
import {UniswapV4Adapter} from "../adapters/UniswapV4Adapter.sol";
import {AaveAdapter} from "../adapters/AaveAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "../interfaces/aave/IPool.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

/**
 * @title WETHLoopStrategy
 * @author YieldBearingVaults Team
 * @notice Leveraged WETH strategy using Aave V3 E-Mode and Uniswap V4 flash loans.
 * @dev Implements a looping strategy:
 *      1. Takes a flash loan from Uniswap V4
 *      2. Supplies principal + flash loan to Aave as collateral
 *      3. Borrows from Aave to repay the flash loan
 *
 *      Uses E-Mode Category 1 (ETH-correlated assets) for 93% LTV,
 *      enabling leverage up to ~14x theoretical maximum.
 */
contract WETHLoopStrategy is BaseStrategy, UniswapV4Adapter {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    uint8 public immutable E_MODE_CATEGORY_ID;
    address public immutable AAVE_POOL;
    address public immutable A_TOKEN;
    address public immutable VARIABLE_DEBT_TOKEN;
    uint256 public minHealthFactor;
    uint256 public targetHealthFactor;

    /**
     * @dev 10x leverage means: Collateral = 10 * Principal, Debt = 9 * Principal.
     */
    uint8 public targetLeverage;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidLeverage();
    error InvalidHealthFactors();
    error BorrowedAmountMismatch(uint256 borrowed, uint256 expected);
    error InsufficientEquity();
    error WithdrawExceedsEquity(uint256 requested, uint256 available);
    error InsufficientBalanceForFlashRepayment(uint256 balance, uint256 required);
    error EmergencyDivestFailed();
    error InsufficientAaveWithdrawal(uint256 withdrawn, uint256 requested);
    error InsufficientAaveRepayment(uint256 repaid, uint256 requested);
    error StrategyNotHarvestable();

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the WETH loop strategy.
     * @param _asset The WETH token address.
     * @param _vault The parent Vault contract.
     * @param _poolManager The Uniswap V4 PoolManager for flash loans.
     * @param _aavePool The Aave V3 Pool contract.
     * @param _aToken The aWETH token address.
     * @param _variableDebtToken The variable debt WETH token address.
     * @param _targetLeverage Target leverage multiplier (minimum 2x).
     * @param _minHealthFactor Minimum health factor threshold (1e18 scale).
     * @param _targetHealthFactor Target health factor to maintain (1e18 scale).
     * @param _eModeCategoryId Aave E-Mode category (1 for ETH-correlated).
     */
    constructor(
        IERC20 _asset,
        address _vault,
        address _poolManager,
        address _aavePool,
        address _aToken,
        address _variableDebtToken,
        uint8 _targetLeverage,
        uint256 _minHealthFactor,
        uint256 _targetHealthFactor,
        uint8 _eModeCategoryId
    ) BaseStrategy(_asset, _vault, "WETH Loop Strategy", "sWETH-Loop") UniswapV4Adapter(_poolManager) {
        AAVE_POOL = _aavePool;
        A_TOKEN = _aToken;
        VARIABLE_DEBT_TOKEN = _variableDebtToken;

        if (_targetLeverage < 2) revert InvalidLeverage();
        targetLeverage = _targetLeverage;

        if (_minHealthFactor >= _targetHealthFactor) revert InvalidHealthFactors();
        minHealthFactor = _minHealthFactor;
        targetHealthFactor = _targetHealthFactor;
        E_MODE_CATEGORY_ID = _eModeCategoryId;

        _enableEMode(_eModeCategoryId);
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function setLeverage(uint8 _targetLeverage) external onlyVaultAdmin {
        if (_targetLeverage < 2) revert InvalidLeverage();
        targetLeverage = _targetLeverage;
        emit LeverageSet(_targetLeverage);
    }

    function setHealthFactors(uint256 _min, uint256 _target) external onlyVaultAdmin {
        if (_min >= _target) revert InvalidHealthFactors();
        minHealthFactor = _min;
        targetHealthFactor = _target;
        emit HealthFactorsSet(_min, _target);
    }

    function _enableEMode(uint8 categoryId) internal {
        if (categoryId > 0) {
            IPool(AAVE_POOL).setUserEMode(categoryId);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           STRATEGY LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Calculates flash loan amount needed to reach target leverage.
     */
    function _invest(uint256 assets) internal override {
        uint256 principal = assets;
        // Gas: unchecked safe, overflow impossible (principal bounded by token supply, leverage max 255)
        uint256 flashAmount;
        unchecked {
            flashAmount = principal * (targetLeverage - 1);
        }

        address assetAddr = asset();

        if (flashAmount > 0) {
            flashLoan(Currency.wrap(assetAddr), flashAmount, bytes(""));
        } else {
            AaveAdapter.supply(AAVE_POOL, assetAddr, principal);
        }
    }

    /**
     * @dev Deleverages position proportionally using flash loan.
     */
    function _divest(uint256 assets) internal override {
        // Checks
        uint256 totalCollateral = IERC20(A_TOKEN).balanceOf(address(this));
        uint256 totalDebt = IERC20(VARIABLE_DEBT_TOKEN).balanceOf(address(this));

        //slither-disable-next-line incorrect-equality
        // Legitimate check: ERC20 balance can be exactly zero (empty position)
        if (totalCollateral == 0) return;

        // Gas: cache asset to avoid repeated calls
        address assetAddr = asset();

        //slither-disable-next-line incorrect-equality
        // Legitimate check: no debt means no leverage, simple withdrawal
        if (totalDebt == 0) {
            uint256 withdrawn = AaveAdapter.withdraw(AAVE_POOL, assetAddr, assets);
            if (withdrawn < assets) revert InsufficientAaveWithdrawal(withdrawn, assets);
            return;
        }

        // Position underwater or no equity (liquidation/interest accumulation)
        if (totalCollateral <= totalDebt) revert InsufficientEquity();

        // Gas: unchecked safe (totalCollateral > totalDebt validated above)
        uint256 netEquity;
        unchecked {
            netEquity = totalCollateral - totalDebt;
        }
        if (assets > netEquity) revert WithdrawExceedsEquity(assets, netEquity);

        // Effects
        // Calculate proportional amounts directly to avoid precision loss
        uint256 debtToRepay = (totalDebt * assets) / netEquity;
        uint256 collateralToWithdraw = (totalCollateral * assets) / netEquity;

        // Interactions
        flashLoan(Currency.wrap(assetAddr), debtToRepay, abi.encode(true, collateralToWithdraw));
    }

    /**
     * @dev Routes flash loan callback to invest or divest flow.
     */
    function _onFlashLoan(Currency currency, uint256 amount, bytes memory data) internal override {
        address underlying = Currency.unwrap(currency);

        if (data.length == 0) {
            _onFlashLoanInvest(underlying, amount);
        } else {
            (bool isDivest, uint256 collateralToWithdraw) = abi.decode(data, (bool, uint256));
            if (isDivest) {
                _onFlashLoanDivest(underlying, amount, collateralToWithdraw);
            }
        }
    }

    /**
     * @dev Invests by supplying principal + flash loan to Aave, then borrows to repay flash.
     */
    function _onFlashLoanInvest(address underlying, uint256 flashAmount) internal {
        // Checks
        uint256 totalToSupply = IERC20(underlying).balanceOf(address(this));

        // Interactions
        address pool = AAVE_POOL;
        AaveAdapter.supply(pool, underlying, totalToSupply);
        uint256 borrowed = AaveAdapter.borrow(pool, underlying, flashAmount);

        // Invariants
        if (borrowed != flashAmount) revert BorrowedAmountMismatch(borrowed, flashAmount);
    }

    /**
     * @dev Divests by repaying debt with flash loan, withdrawing collateral, then repaying flash.
     */
    function _onFlashLoanDivest(address underlying, uint256 flashAmount, uint256 collateralToWithdraw) internal {
        // Interactions
        address pool = AAVE_POOL;
        uint256 repaid = AaveAdapter.repay(pool, underlying, flashAmount);
        if (repaid < flashAmount) revert InsufficientAaveRepayment(repaid, flashAmount);

        uint256 withdrawn = AaveAdapter.withdraw(pool, underlying, collateralToWithdraw);
        if (withdrawn < collateralToWithdraw) revert InsufficientAaveWithdrawal(withdrawn, collateralToWithdraw);

        // Invariants
        uint256 balance = IERC20(underlying).balanceOf(address(this));
        if (balance < flashAmount) revert InsufficientBalanceForFlashRepayment(balance, flashAmount);
    }

    /**
     * @dev Aave supply yields auto-compound via aToken rebasing.
     */
    function harvest() external view override onlyVaultAdmin {
        revert StrategyNotHarvestable();
    }

    /**
     * @notice Checks strategy health and triggers emergency divest if needed.
     * @dev If healthFactor < minHealthFactor:
     *      1. Divests entire position to close leverage
     *      2. Activates emergency mode on vault to block new deposits
     *      3. Returns false to signal health check failure
     * @return healthy True if health factor is acceptable, false otherwise.
     */
    function checkHealth() external override returns (bool healthy) {
        // Checks
        //slither-disable-next-line unused-return
        // Other return values (collateral, debt, etc.) not needed for health check
        (,,,,, uint256 healthFactor) = IPool(AAVE_POOL).getUserAccountData(address(this));

        if (healthFactor >= minHealthFactor) {
            return true;
        }

        // Effects & Interactions: Emergency divest and activate emergency mode
        _emergencyDivest();

        return false;
    }

    /**
     * @dev Emergency divest: closes entire leveraged position and activates vault emergency mode.
     */
    function _emergencyDivest() internal {
        // Effects: Activate emergency mode on vault first
        BaseVault(VAULT).activateEmergencyMode();

        // Checks
        uint256 totalCollateral = IERC20(A_TOKEN).balanceOf(address(this));
        uint256 totalDebt = IERC20(VARIABLE_DEBT_TOKEN).balanceOf(address(this));

        //slither-disable-next-line incorrect-equality
        // Legitimate check: ERC20 balance can be exactly zero (empty position)
        if (totalCollateral == 0) return;

        // Interactions
        address assetAddr = asset();
        if (totalDebt > 0) {
            // Use flash loan to close entire position
            flashLoan(Currency.wrap(assetAddr), totalDebt, abi.encode(true, totalCollateral));
        } else {
            // No debt, just withdraw all collateral
            uint256 withdrawn = AaveAdapter.withdraw(AAVE_POOL, assetAddr, totalCollateral);
            if (withdrawn < totalCollateral) revert InsufficientAaveWithdrawal(withdrawn, totalCollateral);
        }

        // Invariants: Verify position is closed
        uint256 remainingDebt = IERC20(VARIABLE_DEBT_TOKEN).balanceOf(address(this));
        if (remainingDebt > 0) revert EmergencyDivestFailed();
    }

    /**
     * @dev Returns net equity (collateral - debt).
     */
    function totalAssets() public view override returns (uint256) {
        uint256 totalCollateral = IERC20(A_TOKEN).balanceOf(address(this));
        uint256 totalDebt = IERC20(VARIABLE_DEBT_TOKEN).balanceOf(address(this));

        if (totalCollateral <= totalDebt) return 0;

        // Gas: unchecked safe (already checked totalCollateral > totalDebt)
        unchecked {
            return totalCollateral - totalDebt;
        }
    }
}
