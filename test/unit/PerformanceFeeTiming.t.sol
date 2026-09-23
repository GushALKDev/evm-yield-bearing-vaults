// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {VaultDeployer} from "../utils/VaultDeployer.sol";

/**
 * @title PerformanceFeeTimingTest
 * @notice Regression tests for review finding 5: the performance fee was assessed inside _deposit/_withdraw,
 *         after ERC4626 had already priced the operation, so an exiting user skipped the fee and a new depositor
 *         paid the pre-fee share price; the fee shares then diluted the remaining holders.
 */
contract PerformanceFeeTimingTest is Test {
    uint256 internal constant INITIAL_DEPOSIT = 1000;
    uint16 internal constant FEE_BPS = 1000;

    MockWETH internal asset;
    YieldBearingVault internal vault;
    MockStrategy internal strategy;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        asset = new MockWETH();
        asset.mint(owner, INITIAL_DEPOSIT);
        vm.startPrank(owner);
        VaultDeployer vaultDeployer = new VaultDeployer();
        asset.approve(address(vaultDeployer), INITIAL_DEPOSIT);
        vault = vaultDeployer.deploy(IERC20(address(asset)), owner, admin, INITIAL_DEPOSIT);
        vault.addToWhitelist(alice);
        vault.addToWhitelist(bob);
        vm.stopPrank();

        strategy = new MockStrategy(IERC20(address(asset)), address(vault));
        vm.startPrank(admin);
        vault.setStrategy(strategy);
        vault.setFeeRecipient(feeRecipient);
        vault.setProtocolFee(FEE_BPS);
        vm.stopPrank();

        _deposit(alice, 100 ether);
        // 10 WETH of yield on alice's 100 WETH position
        asset.mint(address(strategy), 10 ether);
    }

    /// @notice An exiting user pays the performance fee on their share of the profit.
    function test_Redeem_AfterProfit_ExitingUserPaysFee() public {
        // ============ ACT ============
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 received = vault.redeem(shares, alice, alice);

        // ============ ASSERT ============
        // Profit 10 WETH, fee 10%: alice keeps 100 + 9 (minus her tiny dilution by the dead shares)
        assertApproxEqRel(received, 109 ether, 1e12, "Exiting user should pay the fee on their profit");
        uint256 feeValue = vault.previewRedeem(vault.balanceOf(feeRecipient));
        assertApproxEqRel(feeValue, 1 ether, 1e12, "Fee recipient should hold 10% of the profit");
    }

    /// @notice A depositor entering after a profit is not diluted by the fee on that profit.
    function test_Deposit_AfterProfit_NewDepositorNotDiluted() public {
        // ============ ACT ============
        uint256 shares = _deposit(bob, 100 ether);

        // ============ ASSERT ============
        assertApproxEqAbs(vault.previewRedeem(shares), 100 ether, 2, "New depositor should keep the deposited value");
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        asset.mint(user, amount);
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }
}
