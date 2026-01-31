// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockPoolManager
 * @notice Mock Uniswap V4 PoolManager for testing flash loans without RPC dependency.
 * @dev Implements the unlock/callback pattern for zero-fee flash loans.
 */
contract MockPoolManager {
    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    bool private _unlocked;
    Currency private _currentCurrency;
    uint256 private _currentAmount;
    uint256 private _balanceBefore;

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error AlreadyUnlocked();
    error NotSettled();

    /*//////////////////////////////////////////////////////////////
                          FLASH LOAN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function unlock(bytes calldata data) external returns (bytes memory) {
        if (_unlocked) revert AlreadyUnlocked();
        _unlocked = true;

        (Currency currency, uint256 amount,) = abi.decode(data, (Currency, uint256, bytes));
        _currentCurrency = currency;
        _currentAmount = amount;

        address token = Currency.unwrap(currency);
        _balanceBefore = IERC20(token).balanceOf(address(this));

        bytes memory result = IUnlockCallback(msg.sender).unlockCallback(data);

        _unlocked = false;
        _currentCurrency = Currency.wrap(address(0));
        _currentAmount = 0;

        return result;
    }

    function take(Currency currency, address to, uint256 amount) external {
        address token = Currency.unwrap(currency);
        IERC20(token).transfer(to, amount);
    }

    function sync(Currency) external pure {
        // No-op in mock - just records the currency for settlement
    }

    function settle() external view returns (uint256 paid) {
        address token = Currency.unwrap(_currentCurrency);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        if (balanceAfter < _balanceBefore) revert NotSettled();

        paid = balanceAfter - _balanceBefore + _currentAmount;
    }
}
