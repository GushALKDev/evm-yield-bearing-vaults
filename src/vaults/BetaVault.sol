// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseVault} from "../base/BaseVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title BetaVault
/// @notice Concrete implementation of a Vault.
contract BetaVault is BaseVault {

    constructor(IERC20 _asset, address _owner, uint256 _initialDeposit)
        BaseVault(_asset, "Beta Vault", "bVAULT", _owner, _initialDeposit)
    {}

    // Future specific logic for BetaVault can go here
}
