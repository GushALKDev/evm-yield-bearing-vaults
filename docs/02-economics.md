# Guide 2: Economics of the WETH Loop

**Previous:** [Guide 1: Architecture and Flows](./01-architecture.md)
**Next:** [Guide 3: Security](./03-security.md)

---

In an Aave reserve, suppliers receive the interest paid by borrowers minus the reserve factor:

```
s = r * U * (1 - RF)

s  = supply rate of the reserve
r  = variable borrow rate of the same reserve
U  = utilization of the reserve
RF = reserve factor
```

Since `U <= 1` and `RF > 0`, `s < r`. The WETH loop supplies WETH and borrows WETH from the same reserve, so the collateral earns `s` and the debt costs `r`.

Return on equity at leverage `L` (per unit of equity, ignoring rewards, gas and flash loan fees):

```
ROE = L * s - (L - 1) * r
```

Illustrative example (rates change constantly): `U = 80%`, `RF = 15%`, `L = 10`:

```
s   = 0.80 * 0.85 * r = 0.68 * r
ROE = 10 * 0.68 * r - 9 * r = 6.8r - 9r = -2.2r
r = 2.5%  ->  ROE = -5.5% per year
```

With the WETH reserve rates at the pinned block 26043110 (supply 1.41%, variable borrow 2.02%), the same formula gives about -4.1% per year at 10x.

Consequence for the health factor. Debt grows at `r` and collateral grows at `s < r`, so the health factor drifts down over time even if prices do not move. Collateral and debt are both WETH, so a WETH price move does not change the health factor; interest accrual and changes to Aave's risk parameters do.

```
HF    = collateral * LT / debt
HF_0  = L * LT / (L - 1)
HF(t) ~ HF_0 * exp(-(r - s) * t)
t     = ln(HF_0 / HF_min) / (r - s)      (time until HF reaches HF_min)
```

With the E-Mode liquidation threshold at the pinned block (`LT = 95%`, checked by `LeverageBoundsForkTest`):

- `L = 10`: `HF_0 = 10 * 0.95 / 9 = 1.0556`.
- `L = 14`: `HF_0 = 14 * 0.95 / 13 = 1.0231`, close to the `minHealthFactor` of 1.02 used in the tests.

Illustrative drift at 10x with `minHealthFactor = 1.02`: with `r - s = 0.8` percentage points (the example above), HF reaches 1.02 after about 4.3 years and 1.00 after about 6.8 years. With the rates at the pinned block (`r - s = 0.61` points), HF reaches 1.02 after about 5.6 years. A sustained spread of 5 percentage points (for example during a utilization spike) reaches 1.02 in about 8 months. This is why the emergency divest path, and someone calling `checkHealth()` in time, matters.

The reserve rates can be read at the pinned block with the command below. The third field is the supply (liquidity) rate and the fifth the variable borrow rate, both in ray (1e27 = 100%).

```bash
cast call 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 "getReserveData(address)((uint256,uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128))" 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 --block 26043110 --rpc-url $ETHEREUM_MAINNET_RPC
```
