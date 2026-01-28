// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseStrategy} from "../../src/base/BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockStrategy
 * @notice A mock strategy for testing purposes.
 * @dev Does NOT interact with any external protocol. Keeps funds in the contract.
 *      Useful for testing vault logic without external dependencies.
 *      Yield can be simulated by directly transferring tokens to the strategy.
 */
contract MockStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the mock strategy.
     * @param _asset The underlying asset token.
     * @param _vault The parent vault contract.
     */
    constructor(IERC20 _asset, address _vault) BaseStrategy(_asset, _vault, "Mock Strategy", "mSTRAT") {}

    /*//////////////////////////////////////////////////////////////
                          STRATEGY LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev No-op invest. Funds remain in this contract.
     * @param assets Amount to invest (unused).
     */
    function _invest(uint256 assets) internal override {}

    /**
     * @dev No-op divest. Funds are already available in this contract.
     * @param assets Amount to divest (unused).
     */
    function _divest(uint256 assets) internal override {}

    /**
     * @notice No-op harvest for mock.
     */
    function harvest() external override {}

    /**
     * @notice Always returns healthy for mock.
     * @return Always true.
     */
    function checkHealth() external pure override returns (bool) {
        return true;
    }
}
