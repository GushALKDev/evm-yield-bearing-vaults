// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IVault
 * @notice Vault functions that strategies call on their parent vault.
 */
interface IVault {
    function admin() external view returns (address);

    function activateEmergencyMode() external;
}
