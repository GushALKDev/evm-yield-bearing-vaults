// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPool} from "../../src/interfaces/aave/IPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockAToken} from "./MockAToken.sol";
import {MockVariableDebtToken} from "./MockVariableDebtToken.sol";

/**
 * @title MockAavePool
 * @notice Mock Aave V3 Pool for testing without RPC dependency.
 * @dev Simulates supply, borrow, repay, withdraw with realistic health factor calculation.
 */
contract MockAavePool is IPool {
    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    mapping(address => MockAToken) public aTokens;
    mapping(address => MockVariableDebtToken) public debtTokens;
    mapping(address => uint8) public userEModes;

    address public primaryAsset;

    uint256 public constant LTV_BASE = 9300; // 93% LTV for E-Mode
    /// @dev Liquidation threshold in bps (95%), used for E-Mode, the reserve configuration and the health factor.
    uint256 public liquidationThreshold = 9500;
    uint256 public constant HEALTH_FACTOR_DECIMALS = 1e18;
    uint256 public constant RAY = 1e27;

    /// @dev Liquidity index reported by getReserveNormalizedIncome(). Supplies that scale to 0 revert, as in Aave.
    uint256 public normalizedIncome = RAY;

    error InvalidMintAmount();

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {}

    /*//////////////////////////////////////////////////////////////
                          CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function setAToken(address asset, MockAToken aToken) external {
        aTokens[asset] = aToken;
    }

    function setDebtToken(address asset, MockVariableDebtToken debtToken) external {
        debtTokens[asset] = debtToken;
    }

    function setPrimaryAsset(address asset) external {
        primaryAsset = asset;
    }

    function setNormalizedIncome(uint256 income) external {
        normalizedIncome = income;
    }

    function setLiquidationThreshold(uint256 threshold) external {
        liquidationThreshold = threshold;
    }

    /*//////////////////////////////////////////////////////////////
                          POOL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) public virtual override {
        if (amount * RAY / normalizedIncome == 0) revert InvalidMintAmount();
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        aTokens[asset].mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        MockAToken aToken = aTokens[asset];
        uint256 balance = aToken.balanceOf(msg.sender);
        uint256 withdrawAmount = amount > balance ? balance : amount;

        aToken.burn(msg.sender, withdrawAmount);
        IERC20(asset).transfer(to, withdrawAmount);

        return withdrawAmount;
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external override {
        debtTokens[asset].mint(onBehalfOf, amount);
        IERC20(asset).transfer(msg.sender, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external override returns (uint256) {
        MockVariableDebtToken debtToken = debtTokens[asset];
        uint256 debt = debtToken.balanceOf(onBehalfOf);
        uint256 repayAmount = amount > debt ? debt : amount;

        IERC20(asset).transferFrom(msg.sender, address(this), repayAmount);
        debtToken.burn(onBehalfOf, repayAmount);

        return repayAmount;
    }

    function setUserEMode(uint8 categoryId) external override {
        userEModes[msg.sender] = categoryId;
    }

    function getReserveNormalizedIncome(address) external view override returns (uint256) {
        return normalizedIncome;
    }

    function getUserAccountData(address user)
        external
        view
        override
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        totalCollateralBase = _getTotalCollateral(user);
        totalDebtBase = _getTotalDebt(user);
        currentLiquidationThreshold = liquidationThreshold;
        ltv = LTV_BASE;

        if (totalDebtBase == 0) {
            healthFactor = type(uint256).max;
            availableBorrowsBase = (totalCollateralBase * ltv) / 10000;
        } else {
            healthFactor = (totalCollateralBase * currentLiquidationThreshold * HEALTH_FACTOR_DECIMALS) / (totalDebtBase * 10000);
            uint256 maxBorrow = (totalCollateralBase * ltv) / 10000;
            availableBorrowsBase = maxBorrow > totalDebtBase ? maxBorrow - totalDebtBase : 0;
        }
    }

    function getEModeCategoryCollateralConfig(uint8) external view override returns (CollateralConfig memory) {
        return CollateralConfig({ltv: uint16(LTV_BASE), liquidationThreshold: uint16(liquidationThreshold), liquidationBonus: 10100});
    }

    function getConfiguration(address) external view override returns (uint256) {
        return LTV_BASE | (liquidationThreshold << 16);
    }

    function getEModeCategoryData(uint8) external view override returns (EModeCategory memory) {
        return EModeCategory({
            ltv: uint16(LTV_BASE),
            liquidationThreshold: uint16(liquidationThreshold),
            liquidationBonus: 10100,
            priceSource: address(0),
            label: "ETH correlated"
        });
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getTotalCollateral(address user) internal view returns (uint256) {
        if (primaryAsset == address(0)) return 0;
        MockAToken aToken = aTokens[primaryAsset];
        if (address(aToken) == address(0)) return 0;
        return aToken.balanceOf(user);
    }

    function _getTotalDebt(address user) internal view returns (uint256) {
        if (primaryAsset == address(0)) return 0;
        MockVariableDebtToken debtToken = debtTokens[primaryAsset];
        if (address(debtToken) == address(0)) return 0;
        return debtToken.balanceOf(user);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function getCollateral(address asset, address user) external view returns (uint256) {
        return aTokens[asset].balanceOf(user);
    }

    function getDebt(address asset, address user) external view returns (uint256) {
        return debtTokens[asset].balanceOf(user);
    }
}
