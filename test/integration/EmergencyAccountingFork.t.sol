// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EmergencyAccountingTestBase} from "../unit/EmergencyAccounting.t.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title EmergencyAccountingForkTest
 * @notice Review finding 1 regression tests against Aave V3 and Uniswap V4 at FORK_BLOCK.
 */
contract EmergencyAccountingForkTest is EmergencyAccountingTestBase {
    function _useFork() internal pure override returns (bool) {
        return true;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }
}
