// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockVariableDebtToken
 * @notice Mock Aave variable debt token for testing.
 * @dev Simplified ERC20 that can be minted/burned by the pool.
 */
contract MockVariableDebtToken is ERC20 {
    address public pool;

    error OnlyPool();

    modifier onlyPool() {
        if (msg.sender != pool) revert OnlyPool();
        _;
    }

    constructor(string memory name, string memory symbol, address _pool) ERC20(name, symbol) {
        pool = _pool;
    }

    function mint(address to, uint256 amount) external onlyPool {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyPool {
        _burn(from, amount);
    }
}
