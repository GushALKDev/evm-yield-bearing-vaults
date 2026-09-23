// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

/**
 * @title ForkConfig
 * @notice Shared mainnet fork selection for fork tests.
 * @dev Forks at FORK_BLOCK (default 26043110) so results are reproducible.
 *      Set FORK_BLOCK=0 to fork the latest block instead.
 */
library ForkConfig {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant DEFAULT_FORK_BLOCK = 26_043_110;

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates and selects an Ethereum mainnet fork using ETHEREUM_MAINNET_RPC.
     * @return forkId The id of the selected fork.
     */
    function selectMainnetFork() internal returns (uint256 forkId) {
        string memory rpc = VM.envString("ETHEREUM_MAINNET_RPC");
        uint256 blockNumber = VM.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK);
        if (blockNumber == 0) return VM.createSelectFork(rpc);
        return VM.createSelectFork(rpc, blockNumber);
    }
}
