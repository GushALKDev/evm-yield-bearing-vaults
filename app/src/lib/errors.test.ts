import { ContractFunctionRevertedError, encodeErrorResult, parseAbi } from 'viem'
import { describe, expect, it } from 'vitest'
import { describeError } from './errors'

const panicAbi = parseAbi(['error Panic(uint256 code)'])

describe('describeError', () => {
  // F6: an arithmetic panic inside Aave (its virtual balance underflowing) only read "would revert (Panic)"
  it('turns a panic into a sentence', () => {
    const data = encodeErrorResult({ abi: panicAbi, errorName: 'Panic', args: [0x11n] })
    const err = new ContractFunctionRevertedError({ abi: [], data, functionName: 'deposit' })
    expect(describeError(err)).toMatch(/arithmetic check/)
  })
})
