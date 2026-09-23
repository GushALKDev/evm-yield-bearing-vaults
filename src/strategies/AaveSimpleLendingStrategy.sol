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
    error InsufficientAaveWithdrawal(uint256 withdrawn, uint256 requested);

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

    /**
     * @dev Pays from idle assets first and withdraws only the shortfall from Aave.
     */
    function _divest(uint256 assets) internal override {
        address assetAddr = asset();
        uint256 idle = IERC20(assetAddr).balanceOf(address(this));
        if (idle >= assets) return;

        // Gas: unchecked safe (idle < assets checked above)
        uint256 shortfall;
        unchecked {
            shortfall = assets - idle;
        }
        uint256 withdrawn = AaveAdapter.withdraw(AAVE_POOL, assetAddr, shortfall);
        if (withdrawn < shortfall) revert InsufficientAaveWithdrawal(withdrawn, shortfall);
    }

    /**
     * @dev Withdraws the whole Aave supply to idle assets.
     */
    function _exitPosition() internal override {
        if (IERC20(A_TOKEN).balanceOf(address(this)) == 0) return;
        //slither-disable-next-line unused-return
        // Withdrawn amount is the full aToken balance
        AaveAdapter.withdraw(AAVE_POOL, asset(), type(uint256).max);
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
     * @dev aToken balance (includes accrued interest) plus idle assets held by the strategy.
     */
    function totalAssets() public view override returns (uint256) {
        return IERC20(A_TOKEN).balanceOf(address(this)) + IERC20(asset()).balanceOf(address(this));
    }
}
