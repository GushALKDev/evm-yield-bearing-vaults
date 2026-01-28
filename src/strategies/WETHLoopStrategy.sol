// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseStrategy} from "../base/BaseStrategy.sol";
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

    uint8 public immutable eModeCategoryId;
    address public immutable aavePool;
    address public immutable aToken;
    address public immutable variableDebtToken;
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
    error HealthFactorTooLow(uint256 current, uint256 min);
    error InvalidHealthFactors();
    error BorrowedAmountMismatch(uint256 borrowed, uint256 expected);
    error InsufficientEquity();
    error WithdrawExceedsEquity(uint256 requested, uint256 available);
    error InsufficientBalanceForFlashRepayment(uint256 balance, uint256 required);

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
        aavePool = _aavePool;
        aToken = _aToken;
        variableDebtToken = _variableDebtToken;

        if (_targetLeverage < 2) revert InvalidLeverage();
        targetLeverage = _targetLeverage;

        if (_minHealthFactor >= _targetHealthFactor) revert InvalidHealthFactors();
        minHealthFactor = _minHealthFactor;
        targetHealthFactor = _targetHealthFactor;
        eModeCategoryId = _eModeCategoryId;

        _enableEMode(_eModeCategoryId);
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function setLeverage(uint8 _targetLeverage) external onlyVaultAdmin {
        if (_targetLeverage < 2) revert InvalidLeverage();
        targetLeverage = _targetLeverage;
    }

    function setHealthFactors(uint256 _min, uint256 _target) external onlyVaultAdmin {
        if (_min >= _target) revert InvalidHealthFactors();
        minHealthFactor = _min;
        targetHealthFactor = _target;
    }

    function _enableEMode(uint8 categoryId) internal {
        if (categoryId > 0) {
            IPool(aavePool).setUserEMode(categoryId);
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
        uint256 flashAmount = principal * (targetLeverage - 1);

        if (flashAmount > 0) {
            flashLoan(Currency.wrap(address(asset())), flashAmount, bytes(""));
        } else {
            AaveAdapter.supply(aavePool, address(asset()), principal);
        }
    }

    /**
     * @dev Deleverages position proportionally using flash loan.
     */
    function _divest(uint256 assets) internal override {
        // Checks
        uint256 totalCollateral = IERC20(aToken).balanceOf(address(this));
        uint256 totalDebt = IERC20(variableDebtToken).balanceOf(address(this));

        if (totalCollateral == 0) return;

        if (totalDebt == 0) {
            AaveAdapter.withdraw(aavePool, address(asset()), assets);
            return;
        }

        uint256 netEquity = totalCollateral - totalDebt;
        if (netEquity == 0) revert InsufficientEquity();

        // Calculate proportional amounts to maintain leverage ratio
        uint256 withdrawRatio = (assets * 1e18) / netEquity;
        if (withdrawRatio > 1e18) revert WithdrawExceedsEquity(assets, netEquity);

        // Effects
        uint256 debtToRepay = (totalDebt * withdrawRatio) / 1e18;
        uint256 collateralToWithdraw = (totalCollateral * withdrawRatio) / 1e18;

        // Interactions
        flashLoan(Currency.wrap(address(asset())), debtToRepay, abi.encode(true, collateralToWithdraw));
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
        AaveAdapter.supply(aavePool, underlying, totalToSupply);
        uint256 borrowed = AaveAdapter.borrow(aavePool, underlying, flashAmount);

        // Invariants
        if (borrowed != flashAmount) revert BorrowedAmountMismatch(borrowed, flashAmount);
    }

    /**
     * @dev Divests by repaying debt with flash loan, withdrawing collateral, then repaying flash.
     */
    function _onFlashLoanDivest(address underlying, uint256 flashAmount, uint256 collateralToWithdraw) internal {
        // Interactions
        AaveAdapter.repay(aavePool, underlying, flashAmount);
        AaveAdapter.withdraw(aavePool, underlying, collateralToWithdraw);

        // Invariants
        uint256 balance = IERC20(underlying).balanceOf(address(this));
        if (balance < flashAmount) revert InsufficientBalanceForFlashRepayment(balance, flashAmount);
    }

    /**
     * @dev Aave supply yields auto-compound via aToken rebasing.
     */
    function harvest() external view override onlyVaultAdmin {}

    function checkHealth() external view override returns (bool) {
        (,,,,, uint256 healthFactor) = IPool(aavePool).getUserAccountData(address(this));
        return healthFactor >= minHealthFactor;
    }

    /**
     * @dev Returns net equity (collateral - debt).
     */
    function totalAssets() public view override returns (uint256) {
        uint256 totalCollateral = IERC20(aToken).balanceOf(address(this));
        uint256 totalDebt = IERC20(variableDebtToken).balanceOf(address(this));

        if (totalCollateral <= totalDebt) return 0;

        return totalCollateral - totalDebt;
    }
}
