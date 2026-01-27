// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library Constants {
    /*//////////////////////////////////////////////////////////////
                            ETHEREUM MAINNET
    //////////////////////////////////////////////////////////////*/

    // Tokens
    address internal constant ETHEREUM_MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ETHEREUM_MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Aave V3
    // Pool Address Provider: 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e
    // Pool: 0x87870Bca3F3f63459e7cf3644f7db747184223C2
    address internal constant ETHEREUM_MAINNET_AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    
    // Aave V3 aTokens
    address internal constant ETHEREUM_MAINNET_AAVE_V3_USDC_ATOKEN = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
}
