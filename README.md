# Yield Bearing Vaults (Beta)

![Status](https://img.shields.io/badge/Status-Work_In_Progress-yellow)
![License](https://img.shields.io/badge/License-MIT-green)
![Solidity](https://img.shields.io/badge/Solidity-0.8.33-blue)
![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)

## ⚠️ Disclaimer: Under Construction

**This protocol is currently in the early stages of development.** 

Please note the following before reviewing:
- **Audit Status**: Unaudited. 
- **Tests**: Core functionality is tested, but comprehensive coverage (including complex edge cases and invariant tests) is still in progress.
- **Gas Optimization**: The current focus is on logic and security correctness. Gas optimizations (assembly/Yul) will be addressed in future iterations.
- **Strategies**: Currently supports simple lending strategies (Aave). More complex strategies are planned.

**DO NOT USE IN PRODUCTION.**

---

## Overview

**Yield Bearing Vaults** is a modular ERC-4626 implementation designed to separate yield generation logic (Strategies) from the vault's core accounting (Vaults).

The system allows liquidity providers to deposit assets into a Vault, which then delegates those funds to a specific `Strategy` to earn yield across various DeFi protocols (e.g., Aave).

## Key Features

- **ERC-4626 Compliance**: Standardized Tokenized Vault structure for composability.
- **Modular Strategy Architecture**: Vaults can switch strategies seamlessly.
- **Access Control (Whitelist)**: Strictly controlled access for depositors and transfers.
- **Circuit Breaker (Emergency Mode)**: Admin ability to pause deposits and complex strategy logic in case of emergency, protecting user funds.
- **Inflation Attack Protection**: Native mitigation against the "first depositor" inflation attack by managing the initial deposit state when total supply is zero.
- **Performance Fees**: High Water Mark mechanism ensuring fees are only charged on net profits, preventing double taxation on principal.

## Architecture

* **BetaVault**: The core vault contract handling user deposits, withdrawals, and share minting/burning.
* **BaseStrategy**: Abstract base class ensuring all strategies adhere to a standard interface.
* **AaveSimpleLendingStrategy**: A concrete strategy implementation that supplies assets to Aave V3 to earn lending yield.

## Roadmap

- [ ] **Testing**: Achieve 100% branch coverage and add Fuzz/Invariant tests.
- [ ] **Gas**: Optimize heavy operations using assembly/Yul.
- [ ] **Security**: Complete internal audit and bug bounty setup.
- [ ] **Strategies**: Implement Leveraged Yield Farming and other complex yield sources.
- [ ] **Governance**: Decentralize parameters control.

## Installation & Usage

This project uses [Foundry](https://book.getfoundry.sh/).

### Configuration

To run the full suite of tests (including Mainnet Fork tests), you must configure your RPC URL:

1. Copy the example environment file:
    ```shell
    cp .env_example .env
    ```
2. Open `.env` and add your Ethereum Mainnet RPC URL to the variable `MAINNET_RPC_URL`.

    *Note: Without a valid RPC URL, fork tests will fail.*

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Deploy

```shell
$ forge script script/Deploy.s.sol:DeployScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

---

Arquitected by **GushALKDev** with ❤️
