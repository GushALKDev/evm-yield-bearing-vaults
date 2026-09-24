// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";

/**
 * @title VaultDeployer
 * @notice Test helper that deploys YieldBearingVault instances with CREATE2.
 * @dev The caller approves this deployed helper instead of a predicted vault address.
 *      The CREATE2 address depends only on this contract, the salt and the init code,
 *      not on account nonces, so it is stable in gas report (isolation) mode.
 */
contract VaultDeployer {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 private deployments;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error VaultAddressMismatch(address deployed, address expected);

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pulls `initialDeposit` from the caller and deploys a vault that burns it as dead shares.
     */
    function deploy(IERC20 asset, address owner, address admin, uint256 initialDeposit) external returns (YieldBearingVault vault) {
        // Checks
        bytes32 salt = bytes32(++deployments);
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(YieldBearingVault).creationCode, abi.encode(asset, owner, admin, initialDeposit)));
        address expected = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));

        // Interactions
        asset.safeTransferFrom(msg.sender, address(this), initialDeposit);
        asset.forceApprove(expected, initialDeposit);
        vault = new YieldBearingVault{salt: salt}(asset, owner, admin, initialDeposit);

        // Invariants
        if (address(vault) != expected) revert VaultAddressMismatch(address(vault), expected);
    }
}
