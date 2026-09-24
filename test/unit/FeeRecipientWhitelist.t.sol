// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {VaultDeployer} from "../utils/VaultDeployer.sol";

/**
 * @title FeeRecipientWhitelistTest
 * @notice Fee shares are minted to the fee recipient, so it must be whitelisted when set and cannot be removed from
 *         the whitelist while it is the recipient.
 */
contract FeeRecipientWhitelistTest is Test {
    uint256 internal constant INITIAL_DEPOSIT = 1000;

    MockWETH internal asset;
    YieldBearingVault internal vault;
    MockStrategy internal strategy;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");

    function setUp() public {
        asset = new MockWETH();
        asset.mint(owner, INITIAL_DEPOSIT);
        vm.startPrank(owner);
        VaultDeployer vaultDeployer = new VaultDeployer();
        asset.approve(address(vaultDeployer), INITIAL_DEPOSIT);
        vault = vaultDeployer.deploy(IERC20(address(asset)), owner, admin, INITIAL_DEPOSIT);
        vault.addToWhitelist(alice);
        vm.stopPrank();

        strategy = new MockStrategy(IERC20(address(asset)), address(vault));
        vm.prank(admin);
        vault.setStrategy(strategy);
    }

    /// @notice A fee recipient that is not whitelisted is rejected.
    function test_SetFeeRecipient_RevertIfNotWhitelisted() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("NotWhitelisted(address)", feeRecipient));
        vault.setFeeRecipient(feeRecipient);
    }

    /// @notice A whitelisted fee recipient is accepted.
    function test_SetFeeRecipient_SucceedsIfWhitelisted() public {
        _setWhitelistedFeeRecipient();
        assertEq(vault.feeRecipient(), feeRecipient, "Fee recipient should be set");
    }

    /// @notice The current fee recipient cannot be removed from the whitelist.
    function test_RemoveFromWhitelist_RevertForFeeRecipient() public {
        _setWhitelistedFeeRecipient();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("FeeRecipientNotRemovable(address)", feeRecipient));
        vault.removeFromWhitelist(feeRecipient);

        assertTrue(vault.isWhitelisted(feeRecipient), "Fee recipient should stay whitelisted");
    }

    /// @notice A batch removal that includes the current fee recipient reverts as a whole.
    function test_RemoveBatchFromWhitelist_RevertIfFeeRecipientIncluded() public {
        _setWhitelistedFeeRecipient();
        address[] memory accounts = new address[](2);
        accounts[0] = alice;
        accounts[1] = feeRecipient;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("FeeRecipientNotRemovable(address)", feeRecipient));
        vault.removeBatchFromWhitelist(accounts);

        assertTrue(vault.isWhitelisted(alice), "The batch should not be applied partially");
        assertTrue(vault.isWhitelisted(feeRecipient), "Fee recipient should stay whitelisted");
    }

    /// @notice Once the admin moves the fee to another whitelisted address, the former recipient can be removed.
    function test_RemoveFromWhitelist_FormerFeeRecipient() public {
        _setWhitelistedFeeRecipient();
        vm.prank(admin);
        vault.setFeeRecipient(alice);

        vm.prank(owner);
        vault.removeFromWhitelist(feeRecipient);

        assertFalse(vault.isWhitelisted(feeRecipient), "Former fee recipient should be removable");
    }

    /// @notice Fee shares only reach a whitelisted recipient.
    function test_FeeShares_MintedToWhitelistedRecipient() public {
        // ============ ARRANGE ============
        _setWhitelistedFeeRecipient();
        vm.prank(admin);
        vault.setProtocolFee(1000);
        asset.mint(alice, 100 ether);
        vm.startPrank(alice);
        asset.approve(address(vault), 100 ether);
        vault.deposit(100 ether, alice);
        vm.stopPrank();
        asset.mint(address(strategy), 10 ether);

        // ============ ACT ============
        vault.assessPerformanceFee();

        // ============ ASSERT ============
        assertGt(vault.balanceOf(feeRecipient), 0, "Fee shares should be minted");
        assertTrue(vault.isWhitelisted(feeRecipient), "Fee shares holder should be whitelisted");
    }

    function _setWhitelistedFeeRecipient() internal {
        vm.prank(owner);
        vault.addToWhitelist(feeRecipient);
        vm.prank(admin);
        vault.setFeeRecipient(feeRecipient);
    }
}
