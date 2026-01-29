// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseStrategy} from "../base/BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AaveAdapter} from "../adapters/AaveAdapter.sol";

/**
 * @title AaveSimpleLendingStrategy
 * @author YieldBearingVaults Team
 * @notice Strategy that deposits assets into Aave V3 to earn lending yield.
 * @dev Simple supply-only strategy without leverage. Interest accrues automatically
 *      via aToken rebasing. No manual harvesting required.
 */
contract AaveSimpleLendingStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public immutable AAVE_POOL;
    address public immutable A_TOKEN;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error StrategyNotHarvestable();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IERC20 _asset, address _vault, address _aavePool, address _aToken)
        BaseStrategy(_asset, _vault, "Aave Strategy", "sAAVE")
    {
        AAVE_POOL = _aavePool;
        A_TOKEN = _aToken;
    }

    /*//////////////////////////////////////////////////////////////
                          STRATEGY LOGIC
    //////////////////////////////////////////////////////////////*/

    function _invest(uint256 assets) internal override {
        AaveAdapter.supply(AAVE_POOL, address(asset()), assets);
    }

    function _divest(uint256 assets) internal override {
        AaveAdapter.withdraw(AAVE_POOL, address(asset()), assets);
    }

    /**
     * @dev Aave lending yields auto-compound via aToken rebasing.
     */
    function harvest() external view override onlyVaultAdmin {
        revert StrategyNotHarvestable();
    }

    /**
     * @dev Always returns true for simple lending (no leverage risk).
     */
    function checkHealth() external pure override returns (bool) {
        return true;
    }

    /**
     * @dev Measured by the aToken balance which includes accrued interest.
     */
    function totalAssets() public view override returns (uint256) {
        return IERC20(A_TOKEN).balanceOf(address(this));
    }
}
