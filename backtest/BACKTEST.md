# Ballast — Historical Backtest

This document tests Ballast's Signal 1 (external oracle deviation)
against a real, well-documented, extreme market event — not a
synthetic or invented scenario — to see what the mechanism would
actually have charged compared to a standard flat-fee pool.

## Honesty boundary, stated up front

- **What's real:** the event, its timeline, and the price levels cited
  below are all real and independently reported by multiple sources
  (linked). The simulation code (`backtest/signal1_backtest.py`) is a
  faithful, line-by-line replica of `BallastHook.sol`'s actual Signal 1
  and fee-combination formulas — not an approximation.
- **What's a stated, reasonable assumption:** we do not have historical
  access to any *specific* pool's actual on-chain price during this
  event, so the exact "pool lag" percentages below are assumptions we
  chose — but they are directly informed by real, documented evidence
  from this exact event (see below), not arbitrary guesses.
- **What's out of scope here:** this backtests Signal 1 only. Signal 2
  (structural price-impact) needs historical per-trade size and
  liquidity-depth data for a specific real pool, which isn't available
  to us. Signal 2 is validated instead by this project's fuzz and
  invariant test suites (384,000+ randomized operations — see
  `BallastInvariant.t.sol`), not backtested against history. Because
  the real combined fee is `(signal1 + signal2) / 2`, setting signal2
  to 0 means **every number below understates** what Ballast would
  likely have actually charged during a crash violent enough to also
  trigger Signal 2 — a conservative simplification, not an inflated
  claim.

## The event: October 10, 2025 crypto flash crash

A real, extensively documented event — over $19 billion in leveraged
positions liquidated within hours, the largest single-day deleveraging
event on record at the time, triggered by a geopolitical tariff
announcement and amplified by a mechanical liquidation cascade.

**Real, cited price levels:**
- Pre-crash: ETH trading near **$4,300** ([BeInCrypto, Oct 11 2025](https://beincrypto.com/ethereum-price-crash-rebound-setup/))
- Crash low: ETH fell to approximately **$3,436**, a real-time move of
  roughly 12% (consistent across [CoinDesk](https://www.coindesk.com/markets/2025/11/04/ether-s-20-freefall-triggers-usd1b-liquidation-cascade-as-crypto-losses-accelerate),
  [insights4vc](https://insights4vc.substack.com/p/inside-the-19b-flash-crash),
  and [datawallet.com](https://www.datawallet.com/crypto/october-10-crypto-crash-explained))
- Real, documented timeline: the sharpest single-minute move occurred
  at **21:15 UTC**, with $3.21 billion liquidated in 60 seconds
  ([Amberdata](https://blog.amberdata.io/how-3.21b-vanished-in-60-seconds-october-2025-crypto-crash-explained-through-7-charts))

**The single most directly relevant, real, documented fact for this
backtest:** during this exact event, real oracle infrastructure
genuinely struggled — *"cross-venue price oracles and index pricing
mechanisms struggled in this environment. Some price oracles misfired,
feeding outlier prices into DeFi platforms. In one case, a major oracle
reportedly published a Bitcoin price nearly 10% away from the real
market mid, causing excessive collateral calls on-chain"* ([insights4vc](https://insights4vc.substack.com/p/inside-the-19b-flash-crash)).

This is not a hypothetical Ballast is defending against — it is a real,
documented instance of exactly the failure mode Signal 1 exists to
detect and price around. Our 9.5%-lag scenario below deliberately
matches this real, reported figure.

## Results

Run via `python3 backtest/signal1_backtest.py`:

| Scenario | ETH price | Pool lag | Real deviationBps | Flat pool fee | Ballast (Signal 1 only) | Multiplier |
|---|---|---|---|---|---|---|
| Pre-crash baseline | $4,300 | — | — | 0.30% | 0.30% | 1.0× |
| Oracle keeping up | $3,900 | 0% | 0 | 0.30% | 0.30% | 1.0× |
| Brief sub-cap lag | $3,700 | 1.0% | 100 | 0.30% | 0.90% | 3.0× |
| Modest lag, peak minute | $3,436 | 3.0% | 299 | 0.30% | 1.50% | 5.0× |
| Severe lag (matches real reported case) | $3,436 | 9.5% | 950 | 0.30% | 1.50% | 5.0× |
| Corrective flow, same severe scenario | $3,436 | 9.5% | 950 | 0.30% | **0.15%** | 0.5× |

**Note on these numbers:** this backtest was originally run against Ballast's first combination formula (a simple average of the two signals), which produced weaker figures here (a 3× ceiling rather than 5×). Testing later found that averaging unnecessarily diluted a single strong signal when the other stayed silent — documented fully in `MATH.md` — and the combination was corrected to a noisy-OR formula. These are the accurate, current numbers after that fix.

## What this shows

1. **Signal 1 stayed silent when the oracle tracked the market
   correctly** (the "oracle keeping up" row) — Ballast doesn't tax
   volatility itself, only detected pool-vs-oracle disagreement.
2. **The response scales smoothly, then correctly saturates.** A 1%
   lag (below Signal 1's 2% deviation cap) produced a graduated 3× fee.
   A 3% lag already *exceeds* that 2% cap, so it produced Signal 1's
   maximum possible response (5×, the full ceiling) — and, correctly,
   the far more severe 9.5% lag (matching the real, reported oracle
   misfire from this exact event) produced the *identical* capped
   result, not an ever-increasing fee. This is the cap working exactly
   as designed: it distinguishes "somewhat off" from "very off," but
   deliberately refuses to keep scaling into an arbitrarily large fee
   for arbitrarily large deviations — a genuinely large deviation and an
   extreme one are both correctly treated as "clearly toxic," without
   the fee spiraling further for no added benefit.
3. **A corrective swap during the same severe-lag scenario was
   discounted, not taxed** — the mechanism actively rewards flow that
   would have helped realign the pool during real, documented market
   stress, exactly when that realignment is most valuable to LPs.

## Connecting this event to OracleGuardian

This backtest so far covers Signal 1 — the hook's own internal
fee response. But there's a direct, honest connection to
`OracleGuardian`, our separate, live, Reactive Network-based safety
layer (see the README's OracleGuardian section for its real,
verified cross-chain deployment): its anomaly detector watches for a
single Chainlink price update jumping by more than
`ANOMALY_THRESHOLD_BPS = 1000` (10%) and, if so, autonomously pauses
the pool.

**The real, documented oracle misfire from this exact event was
reported as "nearly 10%."** That means our current threshold sits
right at the boundary of this real historical case — not a clean,
comfortable margin above it. Whether OracleGuardian's detector would
have actually fired during this specific real event depends on
whether the true figure was, say, 9.4% (below threshold, would not
have fired) or 9.9% (above threshold, would have fired) — a distinction
the source material doesn't resolve precisely enough to say for
certain either way.

**We're stating this plainly rather than picking the more flattering
interpretation.** This is a genuinely useful, honest calibration
finding: it suggests `ANOMALY_THRESHOLD_BPS` may be set closer to the
edge of real-world extreme events than initially assumed, and is a
concrete candidate for reconsideration — perhaps lowering it modestly
— in a future revision, backed by this real data point rather than
guesswork.

## What's next

This backtest could be meaningfully extended with real historical
per-pool trade data (for Signal 2) if such a dataset becomes available,
and with additional real historical events beyond this one crash to
check the mechanism's behavior isn't overfit to a single scenario. Both
are natural next steps, not claimed as already done here.
