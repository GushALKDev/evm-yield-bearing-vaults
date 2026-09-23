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

    /**
     * @dev Transient slot with the amount owed to the PoolManager while a flash loan is open.
     *      keccak256("yieldbearingvaults.uniswapv4adapter.flashloan.outstanding")
     */
    bytes32 private constant FLASH_LOAN_OUTSTANDING_SLOT = 0xf9710ff79749ff57ca031f5f16dbb0c4aeebed10d7655147a8107dc883064f5b;

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
        IPoolManager poolManager = POOL_MANAGER;
        if (msg.sender != address(poolManager)) revert CallbackUnauthorized();

        (Currency currency, uint256 amount, bytes memory userData) = abi.decode(data, (Currency, uint256, bytes));

        // Effects: record the liability before the borrowed tokens arrive
        _setFlashLoanOutstanding(amount);

        poolManager.take(currency, address(this), amount);
        _onFlashLoan(currency, amount, userData);

        address token = Currency.unwrap(currency);

        // Repay flash loan
        poolManager.sync(currency);
        IERC20(token).safeTransfer(address(poolManager), amount);
        uint256 paid = poolManager.settle();
        if (paid != amount) revert FlashLoanRepaymentFailed(paid, amount);

        _setFlashLoanOutstanding(0);

        return "";
    }

    /*//////////////////////////////////////////////////////////////
                         FLASH LOAN ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Amount currently owed to the PoolManager. Non-zero only inside unlockCallback, so accounting
     *      that reads token balances can subtract borrowed tokens instead of counting them as equity.
     */
    function _flashLoanOutstanding() internal view returns (uint256 amount) {
        bytes32 slot = FLASH_LOAN_OUTSTANDING_SLOT;
        assembly ("memory-safe") {
            amount := tload(slot)
        }
    }

    function _setFlashLoanOutstanding(uint256 amount) private {
        bytes32 slot = FLASH_LOAN_OUTSTANDING_SLOT;
        assembly ("memory-safe") {
            tstore(slot, amount)
        }
    }

    /*//////////////////////////////////////////////////////////////
                           ABSTRACT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Contract must have `amount` tokens available after this call to repay flash loan.
     */
    function _onFlashLoan(Currency currency, uint256 amount, bytes memory userData) internal virtual;
}
