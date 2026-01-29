// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IPool
 * @notice Interface for Aave V3 Pool contract.
 */
interface IPool {
    struct EModeCategory {
        uint16 ltv;
        uint16 liquidationThreshold;
        uint16 liquidationBonus;
        address priceSource;
        string label;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function setUserEMode(uint8 categoryId) external;

    /**
     * @param interestRateMode 1 for Stable, 2 for Variable.
     */
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;

    /**
     * @param interestRateMode 1 for Stable, 2 for Variable.
     * @return The final amount repaid.
     */
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);

    /**
     * @return totalCollateralBase Total collateral in base currency (USD, 8 decimals).
     * @return totalDebtBase Total debt in base currency (USD, 8 decimals).
     * @return availableBorrowsBase Remaining borrowing power in base currency.
     * @return currentLiquidationThreshold Weighted average liquidation threshold.
     * @return ltv Weighted average loan-to-value.
     * @return healthFactor Current health factor (scaled by 1e18).
     */
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );

    function getEModeCategoryData(uint8 id) external view returns (EModeCategory memory);
}
