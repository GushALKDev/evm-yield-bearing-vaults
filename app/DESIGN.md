# Design notes

## Accent and data colors

Accent: **Indigo**, from the demo family table (same OKLCH lightness and chroma as the money market's verdigris).

| Role | Light | Dark |
| :-- | :-- | :-- |
| Accent (primary actions, equity, a positive net APY, selected chips and steps, focus, mark) | #5E5882 | #A6A2CD |
| Accent hover | #4B4669 | #B7B3D9 |
| Accent soft (selected chip, ok status, idle WETH hatch ground) | #E6E5F1 | #2F2D3F |
| Text on the accent | #FFFFFF | #0E1412 |

Data colors of the loop drawing, defined only for what the drawing needs:

| Role | Light | Dark |
| :-- | :-- | :-- |
| Collateral (aWETH held in Aave), also the supply bar of the yield breakdown | #C6C2E0 | #423F56 |
| Debt (variable WETH debt), also the borrow bar of the yield breakdown | #6C9AB0 | #4F859F |
| Equity (what the vault owns) | the accent | the accent |
| Idle WETH (equity outside Aave) | the accent, hatched on accent soft | the same |

Checked with the dataviz skill's validator on the pairs that sit next to each other in the drawing, plus the debt
color against danger and warn (`node scripts/validate_palette.js "<a>,<b>" --mode light --surface "#FFFFFF"`, and
`--mode dark --surface "#151C1A"`; ΔE is Euclidean OKLab distance x100, CVD under protanopia and deuteranopia):

| Pair | Light: normal ΔE / CVD ΔE | Dark: normal ΔE / CVD ΔE |
| :-- | :-- | :-- |
| Debt and equity (the accent) | 18.9 / 17.8 | 15.5 / 12.0 |
| Debt and collateral | 17.4 / 14.6 | 21.8 / 20.7 |
| Debt and danger | 25.6 / 18.6 | 22.2 / 10.1 |
| Debt and warn | 20.0 / 18.3 | 24.9 / 20.2 |

Contrast (the validator's `contrast()`): the debt color is 3.05:1 on the light surface and 4.28:1 on the dark one. The
collateral fill is 1.72:1 and 1.71:1, below 3:1 like the reference's cash segment, so every segment carries a text
label when it is wide enough and the legend under the bars gives each value. Labels on the fills: 9.69:1 and 5.89:1 in
light (collateral, debt), 8.14:1 and 4.60:1 in dark. The family accent itself sits below the validator's chroma floor
(0.067), so the checks that apply are the separations and contrasts above. Greens and teals were left out of the search
on purpose: they read as the money market's verdigris and as a gain.

## Subject

An ERC-4626 vault whose strategy loops WETH ten times on Aave V3 with a Uniswap V4 flash loan, on a testnet, against
the real Aave and Uniswap deployments. Visitors are protocol founders, CTOs and engineers judging the engineering,
plus anyone who wants to deposit. The page has two jobs: let them use the vault without friction, and make the loop's
mechanics visible (leverage built in one call, proportional unwinds, negative carry, exit before liquidation, two-step
recovery).

## The one memorable element

The loop as Aave holds it, drawn as two bars of equal length: what the strategy holds (collateral in Aave and idle
WETH) against what it owes and keeps (debt and equity). Both sides are equal by construction (equity is collateral plus
idle minus debt), so the drawing is the strategy's accounting, projected to the second from Aave's indexes; the equity
sliver is one tenth of the bar at 10x and shrinks every second while the borrow rate exceeds the supply rate. Under it,
the health factor sits on a scale with Aave's liquidation point (1.00), the trip threshold where checkHealth() closes
the position, and the re-arm threshold reinvest() requires. A typed deposit or withdrawal, and the next step of the
emergency cycle, are outlined as dashed bars next to the live ones. Everything else stays quiet.

## Tokens

Shared with the demo family: IBM Plex Sans for everything with tabular figures, IBM Plex Mono only for addresses and
hashes; the reference's grounds, surfaces, ink, rules, danger and warn in both themes; sentence case; no all-caps labels.

## Layout

```
header        wordmark (links to the vault page), network, pages, test ETH, wallet
              pages: Vault, Stress test, How it works, on a second header row below 1024 px
notice        one line: testnet, for educational purposes, not audited, anyone can run the stress test

/             head: headline, deposits status, four figures (net APY, vault value, leverage, safety), the why line
              grid: tabs Overview (the loop, where the yield comes from), Risks, Capacity, Fees, Contracts (left,
              wider) | your position and the action panel, sticky (right; first below 1024 px)
/stress-test  head, the four-step cycle with only the current step open, the loop (left) | the state card (right)
              /emergency, its old path, opens it too
/how-it-works six mechanics + what runs here and what is a stand-in
/legal        legal notice: owner (LSSI-CE), purpose, liability, data and cookies; linked from the footer only

footer
```

Left-aligned throughout. Two columns from 1024 px, one below. Numbered markers only for real sequences: the first-visit
steps, the transactions of a deposit or withdrawal and the stress test cycle.

Two levels of copy. The vault page and the stress test speak in what a depositor sees: safety, the exit line, the
re-entry line, reopen, loop again. The contract names (checkHealth(), minHealthFactor, shock(), restore(), reinvest())
sit next to them in small monospace, in Under the hood, and on How it works, which keeps the contract-level walkthrough.

## Rules

- Copy names what the user does: Deposit, Withdraw, Redeem, Push the line, Run the health check, Reopen the vault,
  Loop again. The button that says Deposit 1 ETH ends in a toast that says WETH deposited; the steps before the last
  report in the stepper instead of toasts of their own.
- Every preview shows before and after, computed with the contracts' and Aave's own rounding.
- Errors say what happened and what to do, decoded from the custom errors of every contract a call reaches.
- Motion only where something changed: bars and the health factor marker ease to new positions, balances tick with
  Aave's interest. Reduced motion turns transitions off.
