// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {BaseVault} from "../../src/base/BaseVault.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {ReentrantERC20} from "../mocks/ReentrantERC20.sol";
import {VaultDeployer} from "../utils/VaultDeployer.sol";

/**
 * @title ReentrancyTest
 * @notice Re-enters the vault from an asset transfer callback and checks that nonReentrant rejects it.
 */
contract ReentrancyTest is Test {
    uint256 internal constant INITIAL_DEPOSIT = 1000;
    uint256 internal constant AMOUNT = 10 ether;

    ReentrantERC20 internal token;
    YieldBearingVault internal vault;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");

    function setUp() public {
        token = new ReentrantERC20();
        token.mint(owner, INITIAL_DEPOSIT);
        vm.startPrank(owner);
        VaultDeployer vaultDeployer = new VaultDeployer();
        token.approve(address(vaultDeployer), INITIAL_DEPOSIT);
        vault = vaultDeployer.deploy(IERC20(address(token)), owner, admin, INITIAL_DEPOSIT);
        vault.addToWhitelist(alice);
        vault.addToWhitelist(address(token));
        vm.stopPrank();

        MockStrategy strategy = new MockStrategy(IERC20(address(token)), address(vault));
        vm.prank(admin);
        vault.setStrategy(strategy);

        token.mint(alice, 2 * AMOUNT);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
    }

    /// @notice Re-entering deposit() from the asset transfer inside deposit() reverts.
    function test_Reentrancy_DepositDuringDeposit_Reverts() public {
        token.arm(address(vault), abi.encodeCall(IERC4626.deposit, (1, alice)));

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.deposit(AMOUNT, alice);
    }

    /// @notice Re-entering mint() from the asset transfer inside deposit() reverts.
    function test_Reentrancy_MintDuringDeposit_Reverts() public {
        token.arm(address(vault), abi.encodeCall(IERC4626.mint, (1, alice)));

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.deposit(AMOUNT, alice);
    }

    /// @notice Re-entering withdraw() from the asset transfer inside withdraw() reverts.
    function test_Reentrancy_WithdrawDuringWithdraw_Reverts() public {
        vm.prank(alice);
        vault.deposit(AMOUNT, alice);
        vm.prank(alice);
        vault.transfer(address(token), 1 ether);

        token.arm(address(vault), abi.encodeCall(IERC4626.withdraw, (1, address(token), address(token))));

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.withdraw(1 ether, alice, alice);
    }

    /// @notice Re-entering redeem() from the asset transfer inside redeem() reverts.
    function test_Reentrancy_RedeemDuringRedeem_Reverts() public {
        vm.prank(alice);
        vault.deposit(AMOUNT, alice);
        vm.prank(alice);
        vault.transfer(address(token), 1 ether);

        token.arm(address(vault), abi.encodeCall(IERC4626.redeem, (1, address(token), address(token))));

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.redeem(1 ether, alice, alice);
    }

    /// @notice Re-entering assessPerformanceFee() from the asset transfer inside deposit() reverts.
    function test_Reentrancy_AssessFeeDuringDeposit_Reverts() public {
        token.arm(address(vault), abi.encodeCall(BaseVault.assessPerformanceFee, ()));

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.deposit(AMOUNT, alice);
    }

    /// @notice Control: the same callback outside a vault call succeeds, so the reverts above come from the guard.
    function test_Reentrancy_CallbackOutsideVaultCall_Succeeds() public {
        token.arm(address(vault), abi.encodeCall(BaseVault.assessPerformanceFee, ()));

        vm.prank(alice);
        token.transfer(owner, 1);

        assertEq(token.target(), address(0), "Callback ran and disarmed");
    }
}
