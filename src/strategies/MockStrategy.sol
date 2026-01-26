// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseStrategy} from "../base/BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Mock Strategy
/// @notice A mock strategy for testing purposes.
/// @dev Does NOT interact with any external protocol. Keeps funds in the contract.
///      Allows simulating yield by manually depositing more assets.
contract MockStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IERC20 _asset, address _vault) 
        BaseStrategy(_asset, _vault, "Mock Strategy", "mSTRAT") 
    {}

    /*//////////////////////////////////////////////////////////////
                          IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @dev In a real strategy, this would supply to Aave/Compound.
    /// In this mock, we just keep the tokens here.
    function _invest(uint256 /* assets */) internal override {
        // No-op: Keep funds in this contract.
    }

    /// @dev In a real strategy, this would withdraw from Aave/Compound.
    /// In this mock, funds are already here.
    function _divest(uint256 /* assets */) internal override {
        // No-op: Funds are already in this contract available for transfer.
    }
}
