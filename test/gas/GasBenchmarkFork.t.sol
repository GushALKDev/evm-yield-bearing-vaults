// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {ForkConfig} from "../utils/ForkConfig.sol";
import {GasBenchmarkBase} from "./GasBenchmark.t.sol";

/**
 * @title GasBenchmarkForkTest
 * @notice Gas benchmark against Aave V3 and the Uniswap V4 PoolManager on a mainnet fork at FORK_BLOCK.
 * @dev Uses the PoolManager's real WETH balance at the fork block (no deal), which covers the 9 WETH flash loans.
 */
contract GasBenchmarkForkTest is GasBenchmarkBase {
    function _setUpProtocol() internal override {
        ForkConfig.selectMainnetFork();
        weth = IERC20(Constants.ETHEREUM_MAINNET_WETH);
        aavePool = Constants.ETHEREUM_MAINNET_AAVE_V3_POOL;
        poolManager = Constants.UNISWAP_V4_POOL_MANAGER;
        aToken = Constants.ETHEREUM_MAINNET_AAVE_V3_WETH_ATOKEN;
        debtToken = Constants.ETHEREUM_MAINNET_AAVE_V3_WETH_VARIABLE_DEBT;
    }

    function _fund(address account, uint256 amount) internal override {
        deal(address(weth), account, weth.balanceOf(account) + amount);
    }
}
