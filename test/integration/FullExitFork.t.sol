// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullExitTestBase} from "../unit/FullExit.t.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title FullExitForkTest
 * @notice Review finding 3 regression tests against Aave V3 and Uniswap V4 at FORK_BLOCK.
 */
contract FullExitForkTest is FullExitTestBase {
    function _useFork() internal pure override returns (bool) {
        return true;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }
}
