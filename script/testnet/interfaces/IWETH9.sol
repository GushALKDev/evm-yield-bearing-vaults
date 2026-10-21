// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IWETH9
 * @notice Canonical wrapped Ether (0x4200000000000000000000000000000000000006 on Base Sepolia), used by the testnet
 *         deployment to wrap the seed and by the demo app to wrap and unwrap visitors' Ether.
 */
interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
