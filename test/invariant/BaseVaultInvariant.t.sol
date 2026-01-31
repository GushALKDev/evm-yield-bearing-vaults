// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {InvariantBase} from "./InvariantBase.sol";
import {BaseVaultHandler} from "./handlers/BaseVaultHandler.sol";
import {AdminHandler} from "./handlers/AdminHandler.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 1_000_000_000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title BaseVaultInvariantTest
 * @notice Stateful invariant tests for BaseVault functionality.
 * @dev Uses mock strategy to isolate vault logic from external protocols.
 */
contract BaseVaultInvariantTest is InvariantBase {
    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    MockERC20 public asset;
    YieldBearingVault public vault;
    MockStrategy public strategy;

    BaseVaultHandler public vaultHandler;
    AdminHandler public adminHandler;

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        _createActors();

        vm.startPrank(owner);
        asset = new MockERC20();

        address vaultAddr = vm.computeCreateAddress(owner, vm.getNonce(owner));
        asset.approve(vaultAddr, INITIAL_DEPOSIT);
        vault = new YieldBearingVault(IERC20(address(asset)), owner, admin, INITIAL_DEPOSIT);

        strategy = new MockStrategy(IERC20(address(asset)), address(vault));
        vm.stopPrank();

        vm.prank(admin);
        vault.setStrategy(strategy);

        vm.prank(admin);
        vault.setFeeRecipient(feeRecipient);

        vm.prank(admin);
        vault.setProtocolFee(1000);

        vm.startPrank(owner);
        for (uint256 i = 0; i < actors.length; i++) {
            vault.addToWhitelist(actors[i]);
        }
        vm.stopPrank();

        vaultHandler = new BaseVaultHandler(vault, IERC20(address(asset)), actors, admin, owner);
        adminHandler = new AdminHandler(vault, admin, owner, actors);

        targetContract(address(vaultHandler));
        targetContract(address(adminHandler));

        excludeSender(owner);
        excludeSender(admin);
        excludeSender(feeRecipient);
        excludeSender(address(vault));
        excludeSender(address(strategy));
        excludeSender(DEAD_ADDRESS);
    }

    /*//////////////////////////////////////////////////////////////
                         INVARIANT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Total supply equals sum of user shares + dead shares + fee recipient shares.
    function invariant_TotalSupplyConsistency() public view {
        uint256 totalSupply = vault.totalSupply();
        uint256 deadShares = vault.balanceOf(DEAD_ADDRESS);
        uint256 feeRecipientShares = vault.balanceOf(feeRecipient);

        uint256 userShares = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            userShares += vault.balanceOf(actors[i]);
        }

        assertEq(totalSupply, userShares + deadShares + feeRecipientShares, "Total supply != user + dead + fee shares");
    }

    /// @notice Dead address always holds exactly INITIAL_DEPOSIT shares.
    function invariant_DeadSharesConstant() public view {
        assertEq(vault.balanceOf(DEAD_ADDRESS), INITIAL_DEPOSIT, "Dead shares should be constant");
    }

    /// @notice Share-to-asset conversion is reversible within dust tolerance.
    function invariant_ConversionReversibility() public view {
        uint256 totalSupply = vault.totalSupply();
        if (totalSupply == 0) return;

        uint256 testShares = totalSupply / 10;
        if (testShares == 0) return;

        uint256 assets = vault.convertToAssets(testShares);
        uint256 reconvertedShares = vault.convertToShares(assets);

        assertApproxEqAbs(reconvertedShares, testShares, DUST_TOLERANCE, "Conversion not reversible");
    }

    /// @notice Vault and strategy emergency modes are synchronized.
    function invariant_EmergencyModeSynchronized() public view {
        assertEq(vault.emergencyMode(), strategy.emergencyMode(), "Vault and strategy emergency modes must match");
    }

    /// @notice Total assets matches vault + strategy holdings.
    function invariant_TotalAssetsConsistency() public view {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 strategyAssets = strategy.totalAssets();
        uint256 vaultTotalAssets = vault.totalAssets();

        assertApproxEqAbs(vaultTotalAssets, vaultBalance + strategyAssets, DUST_TOLERANCE, "Total assets mismatch");
    }

    /// @notice Non-whitelisted addresses cannot hold shares.
    function invariant_WhitelistEnforcement() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 balance = vault.balanceOf(actor);

            if (balance > 0) {
                assertTrue(vault.isWhitelisted(actor), "Non-whitelisted address holds shares");
            }
        }
    }

    /// @notice High water mark never exceeds total assets significantly.
    function invariant_HighWaterMarkBounded() public view {
        uint256 hwm = vault.highWaterMark();
        uint256 totalAssets = vault.totalAssets();

        assertLe(hwm, totalAssets + (totalAssets / 10) + INITIAL_DEPOSIT, "HWM significantly exceeds total assets");
    }

    /// @notice Protocol fee is within valid bounds.
    function invariant_ProtocolFeeBounded() public view {
        assertLe(vault.protocolFeeBps(), 2500, "Protocol fee exceeds maximum");
    }

    /*//////////////////////////////////////////////////////////////
                         CALL SUMMARY
    //////////////////////////////////////////////////////////////*/

    function invariant_CallSummary() public view {
        console2.log("=== Vault Handler Stats ===");
        console2.log("Deposits:", vaultHandler.ghost_depositCount());
        console2.log("Withdrawals:", vaultHandler.ghost_withdrawCount());
        console2.log("Transfers:", vaultHandler.ghost_transferCount());
        console2.log("Total Deposited:", vaultHandler.ghost_totalDeposited());
        console2.log("Total Withdrawn:", vaultHandler.ghost_totalWithdrawn());
        console2.log("Total Fees Minted:", vaultHandler.ghost_totalFeesMinted());

        console2.log("\n=== Admin Handler Stats ===");
        console2.log("Whitelist Additions:", adminHandler.ghost_whitelistAdditions());
        console2.log("Whitelist Removals:", adminHandler.ghost_whitelistRemovals());
        console2.log("Fee Changes:", adminHandler.ghost_feeChanges());
        console2.log("Emergency Mode Changes:", adminHandler.ghost_emergencyModeChanges());
    }
}
