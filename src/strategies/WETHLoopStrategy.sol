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
        uint8 _targetLeverage,
        uint256 _minHealthFactor,
        uint256 _targetHealthFactor,
        uint8 _eModeCategoryId
    ) BaseStrategy(_asset, _vault, "WETH Loop Strategy", "sWETH-Loop") UniswapV4Adapter(_poolManager) {
        aavePool = _aavePool;
        aToken = _aToken;

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
     * @dev Supplies principal + flash loan to Aave, then borrows to repay flash loan.
     */
    function _onFlashLoan(Currency currency, uint256 amount, bytes memory) internal override {
        address underlying = Currency.unwrap(currency);

        // Supply Principal + Flash Loan to Aave
        uint256 totalToSupply = IERC20(underlying).balanceOf(address(this));
        AaveAdapter.supply(aavePool, underlying, totalToSupply);

        // Borrow to repay flash loan
        uint256 borrowed = AaveAdapter.borrow(aavePool, underlying, amount);

        if (borrowed != amount) revert BorrowedAmountMismatch(borrowed, amount);
    }

    /**
     * @dev Simplified implementation. Production requires full deleverage loop.
     */
    function _divest(uint256 assets) internal override {
        AaveAdapter.withdraw(aavePool, address(asset()), assets);
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
     * @dev Returns aToken balance. For precise net equity, subtract debt.
     */
    function totalAssets() public view override returns (uint256) {
        return IERC20(aToken).balanceOf(address(this));
    }
}
