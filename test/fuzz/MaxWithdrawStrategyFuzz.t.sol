// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MaxWithdrawFuzzBase} from "./MaxWithdrawFuzz.t.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title MaxWithdrawForkFuzzTest
 * @notice MaxWithdrawFuzzBase against Aave V3 and Uniswap V4 at FORK_BLOCK.
 */
contract MaxWithdrawForkFuzzTest is MaxWithdrawFuzzBase {
    function _useFork() internal pure override returns (bool) {
        return true;
    }

    function setUp() public {
        _setUpProtocol(MockAavePool(address(0)));
    }
}
