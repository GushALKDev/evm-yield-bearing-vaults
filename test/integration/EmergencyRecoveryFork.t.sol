// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EmergencyRecoveryTestBase} from "../unit/EmergencyRecovery.t.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title EmergencyRecoveryForkTest
 * @notice Two-step exit from emergency mode against Aave V3 and Uniswap V4 at FORK_BLOCK.
 */
contract EmergencyRecoveryForkTest is EmergencyRecoveryTestBase {
    function _useFork() internal pure override returns (bool) {
        return true;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }
}
