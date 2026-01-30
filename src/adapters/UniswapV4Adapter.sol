// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title UniswapV4Adapter
 * @author YieldBearingVaults Team
 * @notice Abstract adapter for interacting with Uniswap V4 PoolManager.
 * @dev Implements flash loan functionality through the unlock/callback pattern.
 */
abstract contract UniswapV4Adapter is IUnlockCallback {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    IPoolManager public immutable POOL_MANAGER;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error CallbackUnauthorized();
    error FlashLoanRepaymentFailed(uint256 paid, uint256 expected);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _poolManager) {
        POOL_MANAGER = IPoolManager(_poolManager);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Borrowed funds must be repaid within the same transaction.
     */
    function flashLoan(Currency currency, uint256 amount, bytes memory data) internal {
        //slither-disable-next-line unused-return
        // Return value intentionally ignored per Uniswap V4 design pattern
        POOL_MANAGER.unlock(abi.encode(currency, amount, data));
    }

    /*//////////////////////////////////////////////////////////////
                           CALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Executes flash loan logic and ensures repayment via sync/transfer/settle pattern.
     */
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert CallbackUnauthorized();

        (Currency currency, uint256 amount, bytes memory userData) = abi.decode(data, (Currency, uint256, bytes));

        POOL_MANAGER.take(currency, address(this), amount);
        _onFlashLoan(currency, amount, userData);

        // Repay flash loan
        POOL_MANAGER.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(POOL_MANAGER), amount);
        uint256 paid = POOL_MANAGER.settle();
        if (paid != amount) revert FlashLoanRepaymentFailed(paid, amount);

        return "";
    }

    /*//////////////////////////////////////////////////////////////
                           ABSTRACT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Contract must have `amount` tokens available after this call to repay flash loan.
     */
    function _onFlashLoan(Currency currency, uint256 amount, bytes memory userData) internal virtual;
}
