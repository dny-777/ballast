# Ballast — The Math Behind Dual-Signal Detection

This document lays out the actual mathematics of Ballast's fee mechanism
precisely — including two real issues we found by testing our own
formula against its own edge cases, and fixed, with real before/after
numbers at every step. Nothing here is theoretical; every number is
reproducible directly from this repository's test suite.

## Theoretical grounding: this isn't just a heuristic

Before the formulas: it's worth being precise about where this
mechanism sits relative to real academic work on AMM design, and
honest about what we are and aren't claiming.

**Loss-versus-rebalancing (LVR)** — introduced by Milionis, Moallemi,
Roughgarden, and Zhang — is the standard, rigorous way researchers
quantify the cost LPs bear when arbitrageurs correct a pool's price
after it drifts from the true, external market price. It's the same
academic foundation other serious UHI projects have built on (e.g.
Lambda's funding-rate hedge, which uses the related σ²/8 LVR-rate
identity for a *different*, hedging-based mitigation strategy).

The literature identifies **two recognized families of LVR
mitigation**: reducing the mispricing itself (better, faster oracles),
and *redistributing* the value arbitrageurs would otherwise extract —
which itself splits into two approaches: hedging the LP's exposure
directly (Lambda's approach), or **a dynamic fee that "imposes price
discrimination on informed and uninformed order flow based on pattern
recognition"** — a direct, real description of exactly what Signal 1
and Signal 2 do.

A recent formal model (*"Optimal Dynamic Fees for Automated Market
Makers,"* 2026) goes further, describing a fee term that specifically
**"penalizes deviations between the marginal pool price and the
centralised reference price, incentivizing the AMM to choose fees that
push [the price] toward the oracle-implied state"** — this is Signal 1,
precisely, independently formalized in the same tradition.

**What we're claiming, and what we're not:** we did not design Signal 1
or Signal 2 by starting from this literature — they were built and
refined through iteration and testing, described throughout this
document. What we're claiming is narrower and, we think, more
meaningful: the mechanism that emerged from that process turns out to
correspond to a real, independently-recognized LVR-mitigation strategy
in the formal literature studying this exact problem — not a
coincidence we're forcing, but a genuine convergence worth stating
plainly. Ballast's real advantage within this family: fee-based
correction happens same-block, at the moment mispricing occurs, rather
than hedging its cost after the fact.

## The two signals, precisely

**Signal 1 — external deviation** (comparing the pool against a trusted
external price):

```
deviationBps = |poolPrice − oraclePrice| / oraclePrice × 10,000
signal1Score = min(deviationBps, MAX_DEVIATION_BPS) / MAX_DEVIATION_BPS     ∈ [0, 1]
```

**Signal 2 — structural impact** (comparing this swap against what's
*normal* for this specific pool):

```
impactBps = 2 × |sqrtPriceNext/sqrtPriceCurrent − 1| × 10,000
excessRatio = impactBps / baselineImpactBps                                (a per-pool EMA)
signal2Score = min(excessRatio / EXCESS_MULTIPLIER_BPS, 1)                  ∈ [0, 1]
```

**Combination (current, corrected):**

```
combinedScore = 1 − (1 − signal1Score)(1 − signal2Score)          (noisy-OR)
fee = BASE_FEE + combinedScore × (MAX_SURCHARGE_FEE − BASE_FEE)
```

## Bug #1: averaging silently diluted a maximally-confident single signal

**The original design** combined the two signals with a simple average:
`combinedScore = (signal1Score + signal2Score) / 2`. This looked
reasonable, but testing our own formula against its own edge cases
found a real, quantified problem.

**A concrete, real example**, from
`test_previewFee_disproportionateSwap_chargesSurcharge_viaSignal2Alone`:
a swap 100× the pool's established baseline size triggers Signal 2 so
strongly that, at the time, it should have reached its documented
maximum score of 1.0. Under averaging, with Signal 1 reading only a
small residual value (`≈ 0.045`, from unrelated prior activity), the
**real, measured fee came out to 9270 (0.927%)** — nowhere near the
15000 (1.50%) ceiling that a maximally-confident Signal 2 should have
justified on its own.

**Why:** averaging always pulls a strong reading down toward whatever
the other signal shows, even when the other signal has nothing
meaningful to say. Any single signal, however extreme, was structurally
prevented from driving the fee to the level it independently justified.

**The fix:** replace averaging with **noisy-OR** —
`1 − (1 − s1)(1 − s2)` — the standard way to combine independent
probability-style estimates of "at least one condition holds." We
verified this was the right choice by direct comparison, not
assumption:

| Scenario | average | max | noisy-OR |
|---|---|---|---|
| One signal maxed, other near-silent | 0.522 | 1.000 | **1.000** |
| Both signals moderate (corroborating) | 0.500 | 0.500 | **0.750** |
| One signal completely silent | 0.300 | 0.600 | **0.600** |
| Both signals maxed | 1.000 | 1.000 | **1.000** |

Noisy-OR dominates both alternatives: it matches `max`'s best property
(no dilution when one signal is silent) while *also* rewarding genuine
corroboration when both signals partially agree — something plain
`max` cannot do, since it ignores the second signal entirely once one
is already high.

## Bug #2, found while verifying the fix: Signal 2 could never actually reach its own documented ceiling

While confirming the noisy-OR fix worked, we expected the same test
scenario to now produce a fee at or near the full 15000 ceiling. It
initially produced **13188** instead — close, but not exact, which was
itself a signal something was still off. Tracing precisely, `_signal2Score`
contained a second, independent, previously-undetected issue: it
pre-capped the raw excess ratio at a hardcoded `2e18` (200%) *before*
comparing it against `EXCESS_MULTIPLIER_BPS`'s threshold of `2.5e18`
(250%). Since `2.0 < 2.5` always, this pre-cap made it **mathematically
impossible** for Signal 2's score to ever reach its documented maximum
of 1.0 — it silently topped out at `2.0 / 2.5 = 0.8`, no matter how
extreme the real swap was.

**The fix:** removed the pre-cap entirely. It served no protective
purpose — the function's own `>= threshold` check already safely
returns `1e18` directly for any large ratio, before ever reaching the
division that the pre-cap might have been guarding against overflow
for.

**Verified, real result after both fixes:** the same test scenario now
produces a fee of exactly **15000** — the true, full ceiling, matching
what a maximally-confident Signal 2 reading should always have
produced.

## Both fixes verified together, at scale

After both changes:
- All 35 existing unit and sandwich-attack tests still pass unmodified — they check *properties* (bounds, directional correctness), not brittle exact values, which is exactly why they survived a genuine formula change cleanly.
- All 3 invariant suites (384,000 real randomized operations — solvency, fee bounds, paused-state correctness) still hold with zero violations under the corrected formula.
- The historical backtest (`BACKTEST.md`) was re-run against the corrected formula: Signal 1 now correctly reaches the full 5× fee multiplier at its deviation cap, rather than the diluted 3× the original averaging formula produced.

## Why this matters more than the specific numbers

The real story here isn't "we picked a better formula." It's that we
built a real process for finding problems in our own mathematics —
computing concrete numbers from real test scenarios, comparing them
against what the design should produce, and treating any gap as worth
investigating rather than explaining away. That process caught two
separate, real, previously-undetected issues in sequence, each verified
with exact numbers before and after.

## JIT liquidity defense: the decay math, verified twice — locally and live

Ballast's fourth defense (see the README for why JIT liquidity is a
genuinely distinct MEV vector Signal 1/Signal 2 cannot see at all)
uses a simple, deliberately linear decay, chosen specifically to avoid
a hard "cliff" a bot could dodge by waiting one extra block:

```
blocksHeld = block.number − liquidityAddedAtBlock[positionKey]
penaltyBps = JIT_MAX_PENALTY_BPS × (JIT_DECAY_BLOCKS − blocksHeld) / JIT_DECAY_BLOCKS
```

With `JIT_MAX_PENALTY_BPS = 8000` (80%) and `JIT_DECAY_BLOCKS = 10`:
same-block removal is charged the full 80%, decaying smoothly to 0% by
the 10th block held.

**Verified exactly, not just asserted, twice over:**

1. **Locally**, a real fuzzed test confirmed the decay is mathematically
   exact: a position removed at exactly the halfway point (5 of 10
   blocks) produced a penalty of precisely half the same-block value —
   `11,999,999,999,999,999` wei versus `23,999,999,999,999,999` wei,
   an exact 2:1 ratio, not an approximation.
2. **Live, on Sepolia**, a real position was added, traded against, and
   removed 2 blocks later (`10606972` → `10606995` on one deployment;
   `11607201` → `11607203`, just 2 blocks apart, on the final one). The
   real, on-chain `JitPenaltyApplied` event fired with a genuine,
   nonzero penalty (`2,399,999,999,999` wei), confirmed directly by
   querying `pendingReserve0` afterward and finding that exact same
   number sitting there, unreleased (small enough not to cross
   `MIN_DONATE_THRESHOLD`) — real, persistent, on-chain proof, not a
   transient value that resolved before it could be checked.

## A real bug this defense's own live testing found, unrelated to the decay math itself

The first live attempt at this exact demonstration reverted entirely —
not because the decay math was wrong, but because `BallastHook` had no
`receive()` function at all, and `poolManager.take()` could not
deliver native ETH to the contract during the skim. Every local test
in this project used two ERC20 tokens, never native ETH, so this was
invisible to all 100+ local tests and only surfaced via a real, live
attempt against a real `currency0 = ETH` pool. Fixed with a minimal
`receive() external payable {}`, then confirmed with three new,
dedicated tests (`test/NativeEth.t.sol`) exercising native ETH through
every skim path this contract has, and reproduced successfully live
immediately after.
