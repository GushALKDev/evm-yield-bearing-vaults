// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

/**
 * @title InvariantBase
 * @notice Base contract with shared setup and utilities for invariant tests.
 * @dev Provides actor management, common constants, and fork/mock mode detection.
 *
 *      Fork Mode: Set INVARIANT_USE_FORK=true in .env to test against mainnet fork.
 *      Mock Mode: Default mode using mock contracts to avoid RPC rate limiting.
 */
abstract contract InvariantBase is StdInvariant, Test {
    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 constant INITIAL_DEPOSIT = 1000;
    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 constant ACTOR_COUNT = 5;
    uint256 constant DUST_TOLERANCE = 10;

    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    address[] internal actors;
    address internal owner;
    address internal admin;
    address internal feeRecipient;

    bool internal useFork;

    /*//////////////////////////////////////////////////////////////
                           HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _createActors() internal {
        owner = makeAddr("owner");
        admin = makeAddr("admin");
        feeRecipient = makeAddr("feeRecipient");

        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            actors.push(makeAddr(string(abi.encodePacked("actor", vm.toString(i)))));
        }
    }

    function _detectForkMode() internal {
        try vm.envBool("INVARIANT_USE_FORK") returns (bool value) {
            useFork = value;
        } catch {
            useFork = false;
        }
    }

    function _createFork() internal {
        string memory rpc = vm.envString("ETHEREUM_MAINNET_RPC");
        vm.createSelectFork(rpc);
    }
}
