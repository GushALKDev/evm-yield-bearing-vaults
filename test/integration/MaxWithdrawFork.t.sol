// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MaxWithdrawTestBase} from "../unit/MaxWithdraw.t.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title MaxWithdrawForkTest
 * @notice maxWithdraw() and maxRedeem() against Aave V3 and Uniswap V4 at FORK_BLOCK.
 */
contract MaxWithdrawForkTest is MaxWithdrawTestBase {
    function _useFork() internal pure override returns (bool) {
        return true;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }
}
