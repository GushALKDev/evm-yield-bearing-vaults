# Yield Bearing Vaults

![Status](https://img.shields.io/badge/Status-Beta-yellow)
![License](https://img.shields.io/badge/License-MIT-green)
![Solidity](https://img.shields.io/badge/Solidity-0.8.26-blue)
![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)

A modular ERC-4626 vault system with pluggable yield strategies, featuring leveraged looping via **zero-fee Uniswap V4 flash loans** and Aave V3 E-Mode.

## Status

> **Work In Progress (Beta)** - Core functionality tested. Unaudited. **DO NOT USE IN PRODUCTION.**

## Key Features

- **Modular Architecture** - Decoupled Vault/Strategy pattern enabling atomic pass-through deposits. Funds route instantly (User → Vault → Strategy → Protocol) in a single transaction.

- **Leveraged Loop Strategy** - Atomic **Uniswap V4 Flash Loan** (zero fee) + **Aave V3 E-Mode** strategy to cycle liquidity, maximizing LTV (up to 93%) and capturing yield spread with up to 10x leverage. Uniswap V4 is preferred over other providers because it offers flash loans with no protocol fees.

- **Defensive Security** - Critical protections including **Emergency Circuit Breakers** (pausing), **Reentrancy Guards**, and **Inflation Attack Prevention** (dead shares mechanism).

- **Financial Integrity** - **High Water Mark** accounting ensures performance fees are only charged on net profits, preventing double taxation.

- **ERC-4626 Compliance** - Fully tokenized vault shares for maximum DeFi composability.

## Architecture

```
┌──────────────────────────┐
│           USER           │
└────────────┬─────────────┘
             │    ▲
  Collateral │    │ vShares
             ▼    │
┌──────────────────────────┐
│    YieldBearingVault     │
│  (ERC4626, Whitelist)    │
└────────────┬─────────────┘
             │    ▲
  Collateral │    │ sShares
             ▼    │
┌──────────────────────────┐
│         Strategy         │
│ (AaveSimple / WETHLoop)  │
└────────────┬─────────────┘
             │    ▲
  Collateral │    │ pTokens
             ▼    │
┌──────────────────────────┐
│    External Protocols    │
│   (Aave V3 / Uniswap)    │
└──────────────────────────┘
```

## Contracts

| Contract | Description |
|----------|-------------|
| `YieldBearingVault` | ERC-4626 vault with whitelist, fees, and strategy integration |
| `BaseVault` | Abstract base with core vault logic and HWM fees |
| `BaseStrategy` | Abstract base for all yield strategies |
| `AaveSimpleLendingStrategy` | Simple Aave V3 supply strategy (no leverage) |
| `WETHLoopStrategy` | Leveraged WETH strategy using flash loans + E-Mode |
| `AaveAdapter` | Library for Aave V3 interactions |
| `UniswapV4Adapter` | Abstract adapter for Uniswap V4 flash loans |
| `Whitelist` | Access control for deposits and transfers |

## WETHLoopStrategy Flow

### Investment (Leverage Loop)

```
1. User deposits X WETH to Strategy
2. Strategy requests (X × (leverage - 1)) WETH flash loan from Uniswap V4
3. Strategy supplies (X × leverage) WETH to Aave (E-Mode: 93% LTV)
4. Strategy borrows flash loan amount from Aave
5. Strategy repays flash loan with borrowed WETH
6. Result: (X × leverage) collateral, (X × (leverage - 1)) debt

Example with 10x leverage and 1 WETH deposit:
- Collateral: 10 WETH | Debt: 9 WETH | Net Equity: 1 WETH
```

### Divestment (Deleverage Loop)

```
1. User withdraws Y WETH from Strategy
2. Calculate withdrawal ratio: Y / netEquity
3. Strategy requests (totalDebt × ratio) flash loan from Uniswap V4
4. Strategy repays (totalDebt × ratio) debt to Aave
5. Strategy withdraws (totalCollateral × ratio) from Aave
6. Strategy repays flash loan with withdrawn collateral
7. Result: Proportional reduction maintaining leverage ratio

Example with 50% withdrawal from 10 WETH collateral / 9 WETH debt:
- Withdraw: 5 WETH collateral | Repay: 4.5 WETH debt | Return: 0.5 WETH to user
```

> **Why Uniswap V4?** I utilize Uniswap V4 for flash loans because it is currently **zero-fee**. Unlike other protocols (such as Aave V3 which charges 0.05%), this allows us to maximize the efficiency of leveraged positions without losing yield to flash loan premiums.


## Installation

This project uses [Foundry](https://book.getfoundry.sh/).

```bash
# Clone the repository
git clone https://github.com/GushALKDev/yield-bearing-vaults.git
cd yield-bearing-vaults

# Install dependencies
forge install

# Copy environment file
cp .env_example .env

# Add your Ethereum Mainnet RPC URL to .env
# ETHEREUM_MAINNET_RPC=https://...
```

## Usage

```bash
# Build
forge build

# Test (requires ETHEREUM_MAINNET_RPC for fork tests)
forge test

# Test with verbosity
forge test -vvv

# Gas report
forge test --gas-report
```

## Security Considerations

| Protection | Implementation |
|------------|----------------|
| Inflation Attack | Initial 1000 wei deposit burned to dead address |
| Reentrancy | OpenZeppelin ReentrancyGuard on all entry points |
| Emergency Mode | Circuit breaker pauses deposits, allows withdrawals |
| Access Control | Whitelist for deposits, Admin for configuration |
| Fee Exploitation | High Water Mark prevents fee gaming |

## Tech Stack

- **Solidity** 0.8.26
- **Foundry** (Forge, Cast, Anvil)
- **OpenZeppelin** Contracts v5
- **Aave V3** Protocol
- **Uniswap V4** Core

## Testing

Comprehensive test suite with **135 tests** achieving **93.72% code coverage**.

### Test Statistics
- **Total Tests**: 135 (100% pass rate)
- **Unit Tests**: 100
- **Integration Tests**: 35

### Coverage Metrics
```
Lines:       93.72%  (209/223)   ✅ Target: ≥90%
Statements:  89.70%  (209/233)   ✅ Target: ≥85%
Branches:    67.39%  (31/46)     ✅ Target: ≥60%
Functions:   94.74%  (54/57)     ✅ Target: ≥90%
```

### Perfect Coverage (100%)
- `BaseVault.sol` - All admin functions, emergency mode, HWM, fees
- `AaveSimpleLendingStrategy.sol` - Investment logic, health checks
- `UniswapV4Adapter.sol` - Flash loan mechanics

### Test Commands
```bash
# Run all tests
forge test

# Unit tests only
forge test --match-path "test/unit/*.sol"

# Integration tests only
forge test --match-path "test/integration/*.sol"

# Coverage report
forge coverage --no-match-coverage "(test|script|mock)"

# Gas report
forge test --gas-report
```

See [test/README.md](test/README.md) for detailed test documentation.

## Roadmap

- [x] ERC-4626 Vault implementation
- [x] Aave simple lending strategy
- [x] Leveraged loop strategy (WETH)
- [x] Proportional deleveraging mechanism
- [x] Performance fees with HWM
- [x] Emergency mode circuit breaker
- [x] Comprehensive test suite (135 tests, 93.72% coverage)
- [ ] Multi-asset loop strategies
- [ ] Automatic health factor management
- [ ] Gas optimizations
- [ ] Security audit
- [ ] Mainnet deployment

## License

MIT

---

Built by **GushALKDev**
