// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EmergencyExitGasTestBase} from "../unit/EmergencyExitGas.t.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title EmergencyExitGasForkTest
 * @notice Emergency exit gas griefing tests against Aave V3 and Uniswap V4 at FORK_BLOCK.
 */
contract EmergencyExitGasForkTest is EmergencyExitGasTestBase {
    function _useFork() internal pure override returns (bool) {
        return true;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }
}
