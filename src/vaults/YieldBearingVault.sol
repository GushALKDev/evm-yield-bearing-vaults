// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseVault} from "../base/BaseVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title YieldBearingVault
 * @author YieldBearingVaults Team
 * @notice Concrete implementation of an ERC4626-compliant yield-bearing vault.
 * @dev Inherits all functionality from BaseVault including:
 *      - Whitelist-gated deposits
 *      - Strategy integration for yield generation
 *      - High Water Mark performance fees
 *      - Emergency mode circuit breaker
 */
contract YieldBearingVault is BaseVault {
    constructor(IERC20 _asset, address _owner, address _admin, uint256 _initialDeposit)
        BaseVault(_asset, "YieldBearingVault", "YBV", _owner, _admin, _initialDeposit)
    {}
}
