// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseStrategy} from "../base/BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AaveAdapter} from "../adapters/AaveAdapter.sol";
import {IPool} from "../interfaces/aave/IPool.sol"; // Typically needed if we want to query balances directly or something, but Adapter covers most.

/// @title AaveSimpleLendingStrategy
/// @notice Strategy that invests assets into Aave V3.
contract AaveSimpleLendingStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public immutable aavePool;
    address public immutable aToken; // The receipt token from Aave (e.g. aUSDC)

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IERC20 _asset, 
        address _vault, 
        address _aavePool,
        address _aToken
    ) 
        BaseStrategy(_asset, _vault, "Aave Strategy", "sAAVE") 
    {
        aavePool = _aavePool;
        aToken = _aToken;
    }

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error StrategyNotHarvestable();

    /*//////////////////////////////////////////////////////////////
                          STRATEGY LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Invests assets into Aave.
    function _invest(uint256 assets) internal override {
        AaveAdapter.supply(aavePool, address(asset()), assets);
    }

    /// @dev Divests assets from Aave.
    function _divest(uint256 assets) internal override {
        AaveAdapter.withdraw(aavePool, address(asset()), assets);
    }

    /// @dev Harvests rewards. No-op for standard Aave lending (auto-compounding).
    function harvest() external view override onlyVault {
        revert StrategyNotHarvestable();
    }

    /// @dev Checks if the strategy is healthy.
    function checkHealth() external pure override returns (bool) {
        return true;
    }

    /// @dev Total assets managed by this strategy (aToken balance).
    function totalAssets() public view override returns (uint256) {
        return IERC20(aToken).balanceOf(address(this));
    }
}
