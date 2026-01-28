// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "../interfaces/aave/IPool.sol";

/**
 * @title AaveAdapter
 * @author YieldBearingVaults Team
 * @notice Library for interacting with Aave V3 Pool.
 */
library AaveAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function supply(address pool, address asset, uint256 amount) internal {
        if (amount == 0) return;

        IERC20(asset).forceApprove(pool, amount);
        IPool(pool).supply(asset, amount, address(this), 0);
    }

    function withdraw(address pool, address asset, uint256 amount) internal returns (uint256 withdrawnAmount) {
        if (amount == 0) return 0;

        return IPool(pool).withdraw(asset, amount, address(this));
    }

    /**
     * @dev Uses variable interest rate mode (mode 2).
     */
    function borrow(address pool, address asset, uint256 amount) internal returns (uint256 borrowedAmount) {
        if (amount == 0) return 0;

        IPool(pool).borrow(asset, amount, 2, 0, address(this));
        return amount;
    }
}
