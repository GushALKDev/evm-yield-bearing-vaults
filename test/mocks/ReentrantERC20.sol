// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ReentrantERC20
 * @notice ERC20 whose next transfer calls back into a target with prepared calldata.
 * @dev The callback runs after the balance update and bubbles up any revert, so a reentrancy guard
 *      in the target makes the outer call revert with the guard's error.
 */
contract ReentrantERC20 is ERC20 {
    address public target;
    bytes public callData;

    constructor() ERC20("Reentrant Token", "REENTER") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Arms a single callback to `target_` on the next transfer.
     */
    function arm(address target_, bytes calldata callData_) external {
        target = target_;
        callData = callData_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        address callTarget = target;
        if (callTarget == address(0) || from == address(0) || to == address(0)) return;

        // Disarm before the call so the callback runs once
        target = address(0);
        (bool success, bytes memory returnData) = callTarget.call(callData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
