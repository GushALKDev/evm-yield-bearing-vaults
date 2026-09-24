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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

    /**
     * @dev A withdrawal that would leave less equity than this closes the whole position instead.
     *      Aave values debt rounding up and collateral rounding down in its 8-decimal base currency, so a dust
     *      position (for example 10,000 wei collateral / 9,000 wei debt) has a health factor of 0 and the
     *      collateral withdrawal reverts. 1e12 wei keeps the remaining debt at thousands of base units or more
     *      for any ETH price above 1 USD.
     */
    uint256 public constant MIN_REMAINING_EQUITY = 1e12;

    /**
     * @dev Aave liquidates at a health factor below 1e18, so minHealthFactor must be strictly above it.
     */
    uint256 public constant HEALTH_FACTOR_FLOOR = 1e18;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidLeverage();
    error InvalidHealthFactors(uint256 minHealthFactor, uint256 targetHealthFactor);
    error BorrowedAmountMismatch(uint256 borrowed, uint256 expected);
    error InsufficientEquity();
    error WithdrawExceedsEquity(uint256 requested, uint256 available);
    error InsufficientBalanceForFlashRepayment(uint256 balance, uint256 required);
    error EmergencyDivestFailed();
    error InsufficientAaveWithdrawal(uint256 withdrawn, uint256 requested);
    error InsufficientAaveRepayment(uint256 repaid, uint256 requested);
    error StrategyNotHarvestable();
    error HealthFactorBelowTarget(uint256 healthFactor, uint256 targetHealthFactor);
    error HealthFactorBelowMinimum(uint256 healthFactor, uint256 minHealthFactor);

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
     * @param _minHealthFactor Health factor below which checkHealth() triggers emergency mode (1e18 scale, > 1e18).
     * @param _targetHealthFactor Minimum health factor after reinvest() (1e18 scale, > _minHealthFactor).
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

        if (_minHealthFactor <= HEALTH_FACTOR_FLOOR || _minHealthFactor >= _targetHealthFactor) revert InvalidHealthFactors(_minHealthFactor, _targetHealthFactor);
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
        if (_min <= HEALTH_FACTOR_FLOOR || _min >= _target) revert InvalidHealthFactors(_min, _target);
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
     * @dev Calculates flash loan amount needed to reach target leverage. Only `assets` is supplied: idle WETH is
     *      invested by reinvest(), which checks the resulting health factor. Reverts if the position ends below
     *      minHealthFactor, so a deposit never opens a position that checkHealth() would close right away.
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
            flashLoan(Currency.wrap(assetAddr), flashAmount, abi.encode(false, principal));
        } else {
            AaveAdapter.supply(AAVE_POOL, assetAddr, principal);
        }

        // Invariants
        //slither-disable-next-line unused-return
        (,,,,, uint256 healthFactor) = IPool(AAVE_POOL).getUserAccountData(address(this));
        uint256 minimum = minHealthFactor;
        if (healthFactor < minimum) revert HealthFactorBelowMinimum(healthFactor, minimum);
    }

    /**
     * @dev Pays from idle WETH first, then deleverages the position proportionally using a flash loan.
     */
    function _divest(uint256 assets) internal override {
        // Checks
        // Gas: cache asset to avoid repeated calls
        address assetAddr = asset();

        uint256 idle = IERC20(assetAddr).balanceOf(address(this));
        if (idle >= assets) return;
        // Gas: unchecked safe (idle < assets checked above)
        unchecked {
            assets -= idle;
        }

        uint256 totalCollateral = IERC20(A_TOKEN).balanceOf(address(this));
        uint256 totalDebt = IERC20(VARIABLE_DEBT_TOKEN).balanceOf(address(this));

        //slither-disable-next-line incorrect-equality
        // Legitimate check: ERC20 balance can be exactly zero (empty position)
        if (totalCollateral == 0) return;

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
        uint256 debtToRepay;
        uint256 collateralToWithdraw;
        // Gas: unchecked safe (assets <= netEquity validated above)
        uint256 remainingEquity;
        unchecked {
            remainingEquity = netEquity - assets;
        }
        if (remainingEquity < MIN_REMAINING_EQUITY) {
            // Close fully; any equity above `assets` stays as idle WETH, counted by totalAssets()
            debtToRepay = totalDebt;
            collateralToWithdraw = totalCollateral;
        } else {
            // Debt rounds up so the remaining position is never more leveraged than before.
            // Collateral is derived from it so the remaining equity is exactly netEquity - assets.
            debtToRepay = Math.mulDiv(totalDebt, assets, netEquity, Math.Rounding.Ceil);
            collateralToWithdraw = debtToRepay + assets;
        }

        // Interactions
        flashLoan(Currency.wrap(assetAddr), debtToRepay, abi.encode(true, collateralToWithdraw));
    }

    /**
     * @dev Routes flash loan callback to invest or divest flow.
     */
    function _onFlashLoan(Currency currency, uint256 amount, bytes memory data) internal override {
        address underlying = Currency.unwrap(currency);

        // Invest: principal. Divest: collateral to withdraw.
        (bool isDivest, uint256 param) = abi.decode(data, (bool, uint256));
        if (isDivest) {
            _onFlashLoanDivest(underlying, amount, param);
        } else {
            _onFlashLoanInvest(underlying, amount, param);
        }
    }

    /**
     * @dev Invests by supplying principal + flash loan to Aave, then borrows to repay flash.
     */
    function _onFlashLoanInvest(address underlying, uint256 flashAmount, uint256 principal) internal {
        // Checks
        uint256 totalToSupply = principal + flashAmount;

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
     * @notice Checks strategy health and triggers an emergency divest if needed.
     * @dev If healthFactor < minHealthFactor, activates emergency mode on the vault. The vault propagates it to
     *      this strategy, whose setEmergencyMode() closes the position (see BaseStrategy). If the position is
     *      still open because an earlier exit failed, calling this again retries the exit only while the health
     *      factor is still below minHealthFactor; otherwise it returns true and the admin retries it instead.
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

        // Interactions: activation blocks deposits and closes the position
        BaseVault(VAULT).activateEmergencyMode();

        return false;
    }

    /**
     * @dev Re-arms only into a position at or above targetHealthFactor, while checkHealth() trips below
     *      minHealthFactor. The check covers the whole position; with no debt Aave reports type(uint256).max.
     */
    function _reinvest() internal override {
        // Interactions
        super._reinvest();

        // Invariants
        //slither-disable-next-line unused-return
        (,,,,, uint256 healthFactor) = IPool(AAVE_POOL).getUserAccountData(address(this));
        uint256 target = targetHealthFactor;
        if (healthFactor < target) revert HealthFactorBelowTarget(healthFactor, target);
    }

    /**
     * @dev Emergency divest: repays all debt with a flash loan and withdraws all collateral to idle WETH.
     */
    function _exitPosition() internal override {
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
     * @dev Returns net equity: collateral + idle WETH - debt - outstanding flash loan.
     *      Idle WETH is what an emergency divest leaves in the strategy. The outstanding flash loan
     *      is subtracted so borrowed WETH is not counted as equity while a loan is open.
     */
    function totalAssets() public view override returns (uint256) {
        uint256 assets = IERC20(A_TOKEN).balanceOf(address(this)) + IERC20(asset()).balanceOf(address(this));
        uint256 liabilities = IERC20(VARIABLE_DEBT_TOKEN).balanceOf(address(this)) + _flashLoanOutstanding();

        if (assets <= liabilities) return 0;

        // Gas: unchecked safe (already checked assets > liabilities)
        unchecked {
            return assets - liabilities;
        }
    }
}
