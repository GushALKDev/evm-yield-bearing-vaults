// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PreviewWithFeeTestBase} from "../unit/PreviewWithFee.t.sol";

/**
 * @title PreviewFeeFuzzTest
 * @notice Fuzzes preview == actual for deposit, mint, withdraw and redeem with a random fee and a random pending profit
 *         (0 means no pending fee).
 */
contract PreviewFeeFuzzTest is PreviewWithFeeTestBase {
    function _arrange(uint256 feeBps, uint256 profitBps) internal {
        _setUpVault(uint16(bound(feeBps, 0, 2500)));
        _deposit(alice, 100 ether);
        _addProfit(100 ether * bound(profitBps, 0, 5000) / 10_000);
    }

    function testFuzz_PreviewDeposit_MatchesDeposit(uint256 feeBps, uint256 profitBps, uint256 amount) public {
        _arrange(feeBps, profitBps);
        _checkDeposit(bound(amount, 1, 1_000 ether));
    }

    function testFuzz_PreviewMint_MatchesMint(uint256 feeBps, uint256 profitBps, uint256 shares) public {
        _arrange(feeBps, profitBps);
        _checkMint(bound(shares, 1, 1_000 ether));
    }

    function testFuzz_PreviewWithdraw_MatchesWithdraw(uint256 feeBps, uint256 profitBps, uint256 assets) public {
        _arrange(feeBps, profitBps);
        _checkWithdraw(bound(assets, 1, vault.maxWithdraw(alice)));
    }

    function testFuzz_PreviewRedeem_MatchesRedeem(uint256 feeBps, uint256 profitBps, uint256 shares) public {
        _arrange(feeBps, profitBps);
        _checkRedeem(bound(shares, 1, vault.balanceOf(alice)));
    }
}
