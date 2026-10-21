import {
  BaseError,
  ContractFunctionRevertedError,
  InsufficientFundsError,
  UserRejectedRequestError,
} from 'viem'
import { chain } from '../config/chain'
import { formatHealth, formatWeth } from './format'

const weth = (v: unknown) => `${formatWeth(v as bigint)} WETH`
const hf = (v: unknown) => formatHealth(v as bigint)

/** The landed transaction reverted after a simulation that passed: nothing changed. */
export const LANDED_REVERT =
  'The transaction reverted when it landed, so nothing changed. The position or Aave may have moved since the check: try again.'

/**
 * Turns a failed simulation or transaction into one sentence that says what happened and, where it helps, what to
 * do. Contract errors are decoded by name from the combined ABI of every contract the call reaches (lib/abi.ts).
 */
export function describeError(err: unknown): string {
  if (err instanceof Error && err.message === LANDED_REVERT) return err.message
  if (!(err instanceof BaseError)) return err instanceof Error ? err.message : 'The request failed.'

  if (err.walk((e) => e instanceof UserRejectedRequestError)) return 'You rejected the request in your wallet.'
  if (err.walk((e) => e instanceof InsufficientFundsError))
    return `Your wallet needs ${chain.name} ETH to pay for gas. Get some from a faucet and try again.`

  const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null
  const name = reverted?.data?.errorName
  const a = (reverted?.data?.args ?? []) as readonly unknown[]

  switch (name) {
    // Vault
    case 'NotWhitelisted':
      return 'This address is not on the vault whitelist yet. Join it first, from your position card.'
    case 'VaultInEmergency':
      return 'The vault is in emergency mode, which closes deposits. Withdrawals stay open; anyone can restore it from the Emergency page.'
    case 'ERC4626ExceededMaxWithdraw':
      return `That is more than the ${weth(a[2])} you can withdraw right now. Equity shrinks a little every second at current Aave rates: use Max to redeem everything.`
    case 'ERC4626ExceededMaxRedeem':
      return 'That is more shares than you hold.'
    case 'InsufficientStrategyShares':
    case 'InsufficientStrategySharesBurned':
      return 'The strategy priced its shares differently from the preview, so the vault stopped the call. Try again.'
    case 'ReentrancyGuardReentrantCall':
      return 'The vault rejected a reentrant call.'
    case 'NotAdmin':
    case 'NotVaultAdmin':
      return 'Only the vault admin can do this.'
    case 'OwnableUnauthorizedAccount':
      return 'The demo operator no longer holds the vault roles, so this public control is closed.'
    case 'ERC20InsufficientBalance':
      return 'A share balance was too low for this transfer.'
    case 'SafeERC20FailedOperation':
      return 'A WETH transfer failed. Check your WETH balance and the approval for the vault.'

    // Strategy
    case 'HealthFactorBelowMinimum':
      return `The position would end at a health factor of ${hf(a[0])}, below the trip threshold of ${hf(a[1])}, so the strategy refuses new investments. Call checkHealth or restore on the Emergency page.`
    case 'HealthFactorBelowTarget':
      return `Reinvesting would leave a health factor of ${hf(a[0])}, below the re-arm threshold of ${hf(a[1])}.`
    case 'StrategyInEmergency':
      return 'The strategy is in emergency mode. Restore it first, from the Emergency page.'
    case 'WithdrawExceedsEquity':
      return `The strategy holds ${weth(a[1])} of equity, less than the ${weth(a[0])} it was asked for.`
    case 'InsufficientEquity':
      return 'The position has no equity left: its debt is at or above its collateral.'
    case 'InsufficientGasForExit':
      return 'Not enough gas was sent for the emergency exit, so nothing changed. The app adds a margin; try again with a higher gas limit.'
    case 'EmergencyDivestFailed':
      return 'The emergency exit left debt behind.'
    case 'InsufficientAaveWithdrawal':
    case 'InsufficientAaveRepayment':
    case 'InsufficientBalanceForFlashRepayment':
    case 'BorrowedAmountMismatch':
      return 'Aave returned a different amount than the strategy expected, so the call reverted.'
    case 'FlashLoanRepaymentFailed':
    case 'CallbackUnauthorized':
      return 'The Uniswap V4 flash loan could not be settled.'

    // Demo operator
    case 'ShockCooldown': {
      const next = new Date(Number(a[0] as bigint) * 1000)
      return `A shock ran less than an hour ago. The next one opens at ${next.toLocaleTimeString()}.`
    }
    case 'NoOpenPosition':
      return 'The strategy has no debt, so there is no health factor to shock. Deposit or reinvest first.'
    case 'AlreadyInEmergency':
      return 'The vault is already in emergency mode. Restore it first.'
    case 'NothingToRestore':
      return 'Nothing to restore: emergency mode is off and the thresholds are at their deployment values.'

    // Aave
    case 'BorrowCapExceeded':
      return "Aave's WETH borrow cap is full, so the loop cannot borrow. It is shared with every Aave user on this testnet; try a smaller amount or later."
    case 'SupplyCapExceeded':
      return "Aave's WETH supply cap is full, so the loop cannot supply. It is shared with every Aave user on this testnet."
    case 'ReserveFrozen':
      return 'Aave has frozen the WETH reserve: no new supply or borrows until it is unfrozen.'
    case 'ReservePaused':
      return 'Aave has paused the WETH reserve: nothing moves in or out until it is unpaused.'
    case 'ReserveInactive':
      return 'The WETH reserve is inactive on Aave.'
    case 'BorrowingNotEnabled':
      return 'Borrowing WETH is disabled on Aave right now.'
    case 'NotEnoughAvailableUserBalance':
      return 'The strategy asked Aave for more collateral than it holds.'
    case 'CollateralCannotCoverNewBorrow':
    case 'LtvValidationFailed':
      return "Aave's loan-to-value check rejected the borrow."
    case 'HealthFactorLowerThanLiquidationThreshold':
      return 'Aave rejected the call because it would take the position below a health factor of 1.'
    case 'InvalidAmount':
      return 'Aave rejected an amount of zero.'

    // Uniswap V4
    case 'WrappedError':
    case 'ERC20TransferFailed':
      return 'The Uniswap V4 PoolManager could not lend that much WETH: the flash loan is limited to what it holds.'
    case 'CurrencyNotSettled':
      return 'The Uniswap V4 flash loan was not repaid in full.'
    case 'ManagerLocked':
    case 'AlreadyUnlocked':
      return 'The Uniswap V4 PoolManager rejected the flash loan.'
  }

  if (reverted) return `The transaction would revert${name ? ` (${name})` : ''}.`
  return err.shortMessage || 'The request failed.'
}
