// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "../interfaces/aave/IPool.sol";

/// @title AaveAdapter
/// @notice Library for interacting with Aave V3 Pool.
library AaveAdapter {
    using SafeERC20 for IERC20;

    /// @dev Deposits assets into Aave Pool.
    /// @param pool The Aave Pool contract address.
    /// @param asset The address of the underlying asset (e.g. USDC).
    /// @param amount The amount to supply.
    function supply(address pool, address asset, uint256 amount) internal {
        if (amount == 0) return;
        
        // Approve Aave Pool to spend assets
        IERC20(asset).forceApprove(pool, amount);
        
        // Supply to Aave, receiving aTokens on behalf of this contract
        // referralCode = 0
        IPool(pool).supply(asset, amount, address(this), 0);
    }

    /// @dev Withdraws assets from Aave Pool.
    /// @param pool The Aave Pool contract address.
    /// @param asset The address of the underlying asset.
    /// @param amount The amount to withdraw. Use type(uint256).max for all.
    /// @return withdrawnAmount The actual amount withdrawn.
    function withdraw(address pool, address asset, uint256 amount) internal returns (uint256 withdrawnAmount) {
        if (amount == 0) return 0;

        // Withdraw from Aave directly. 
        // If it fails (e.g. paused, not enough liquidity), it will revert.
        return IPool(pool).withdraw(asset, amount, address(this));
    }
}
