// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EmergencyActivationTestBase} from "../unit/EmergencyActivation.t.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title EmergencyActivationForkTest
 * @notice Review finding 2 regression tests against Aave V3 and Uniswap V4 at FORK_BLOCK.
 */
contract EmergencyActivationForkTest is EmergencyActivationTestBase {
    function _useFork() internal pure override returns (bool) {
        return true;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }
}
