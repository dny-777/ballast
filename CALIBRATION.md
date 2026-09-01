# Ballast — Calibration Notes

This document explains the reasoning behind every tunable constant in
`BallastHook.sol`. It exists so that no number is a black box: each one
below has a stated rationale, and each one's *behavior at its boundary*
is exercised by a real, named test — not just asserted in prose.

**Honesty boundary, stated up front:** these constants are *reasoned
defaults, validated against our fuzz and invariant test suites* (over
384,000 randomized real operations — see `BallastInvariant.t.sol`). They
are **not** yet validated against real historical market data — that is
a distinct, larger effort (a full backtest against historical Chainlink
and swap data) tracked separately, not claimed here. Where a number
below is "chosen by reasoning" rather than "derived from data," that
distinction is stated plainly.

---

## Fee tier constants

| Constant | Value | Basis points |
|---|---|---|
| `BASE_FEE` | 3000 | 0.30% |
| `DISCOUNTED_FEE` | 1500 | 0.15% |
| `MAX_SURCHARGE_FEE` | 15000 | 1.50% |

**`BASE_FEE` = 0.30%** is the industry-standard default fee tier
popularized by Uniswap v2 and carried through v3 as the most common
tier for volatile pairs. Choosing anything unusual here would make
Ballast harder to compare against a normal pool for the exact
apples-to-apples comparison our own tests rely on (see
`test_ballastLP_endsUpWithMoreValue_thanVanillaLP_afterToxicSwaps`,
which explicitly deploys a vanilla 0.30% pool as the baseline).

**`DISCOUNTED_FEE` = half of base (0.15%)** is deliberately a
meaningful, noticeable discount — large enough that a bot correcting a
price deviation actually captures a real, worthwhile incentive to do
so — while not being so close to zero that discounted swaps become a
new attack surface (e.g., wash-trading to repeatedly claim minimal
fees). Halving base is a simple, legible ratio rather than an
arbitrarily fine-tuned number, which matters for a constant whose
exact value has low sensitivity: the *direction* of the incentive
(reward correction) matters far more than its precise magnitude.

**`MAX_SURCHARGE_FEE` = 5x base (1.50%)** is the ceiling both signals
combined can ever reach. 5x is high enough to meaningfully tax a
genuinely toxic swap — enough to erase most of the profit motive for
small-edge MEV extraction — while remaining bounded far below fee
levels that would make the pool practically unusable for real traders
(a v3 pool's most expensive standard tier is 1%; ours can reach 1.5%
only under the worst detected conditions, decaying back to 0.30% the
moment conditions normalize). **Tested at its exact boundary**: the
fuzz test `testFuzz_previewFee_alwaysWithinDesignedBounds` (256 runs)
and the invariant `invariant_feeAlwaysWithinBounds` (256 sequences ×
500 operations = 128,000 calls) both directly assert `previewFee()`
never exceeds this value under any circumstance the fuzzer or handler
could construct.

---

## Signal 1 (external oracle deviation) constants

| Constant | Value |
|---|---|
| `MAX_DEVIATION_BPS` | 200 (2.00%) |

**Why 2%:** for a liquid, actively-arbitraged pair, a pool-vs-oracle
deviation beyond roughly 2% is already a large dislocation — one that
either reflects a genuine, fast-moving market event (where further
distinguishing "2.5% off" from "4% off" adds little useful signal) or
an already-serious manipulation attempt (where the fee should already
be near its ceiling regardless of exactly how far off it is). Capping
the signal here means Signal 1's score saturates smoothly rather than
scaling unboundedly with an increasingly extreme (and increasingly
rare) deviation. **Tested:** `test_previewFee_toxicDirection_chargesSurcharge`
and `test_previewFee_correctiveDirection_chargesDiscount` both exercise
real deviations in this range; the fuzz suite additionally randomizes
oracle price across a wide range including deviations both inside and
outside this cap.

---

## Signal 2 (structural price-impact) constants

| Constant | Value |
|---|---|
| `EXCESS_MULTIPLIER_BPS` | 25,000 (2.5×) |
| `EMA_WEIGHT_BPS` | 1000 (10%) |

**Why a 2.5× multiplier over the trailing baseline, not 1.5× or 5×:** a
disproportionate swap needs to be *clearly* abnormal relative to that
specific pool's own recent activity, not just modestly larger than
average — pools naturally see real variance in trade sizes. 2.5× was
chosen as a middle point: high enough that ordinary size variance
(a trader doing 1.5-2x their usual size) doesn't trigger a false
positive, low enough that genuinely disproportionate, MEV-shaped swaps
(5x, 10x normal size) are caught well before reaching the ceiling.
**This specific ratio is reasoned, not yet backtested** against real
trade-size distributions — a natural first candidate for the planned
historical-data backtest.

**Why a 10% EMA weight:** this determines how quickly the "what's
normal for this pool" baseline adapts. 10% means each new swap
contributes a tenth of the weight to the running average — slow enough
that a single large (possibly toxic) swap doesn't immediately redefine
"normal" and mask the next similarly-sized swap, but responsive enough
that genuine, sustained shifts in trading pattern (e.g., a pool
becoming more actively traded over weeks) aren't permanently
mismeasured against a stale early baseline. **Tested:**
`test_previewFee_firstSwap_seedsBaseline_notFlaggedExcessive` and
`test_previewFee_disproportionateSwap_chargesSurcharge_viaSignal2Alone`
directly exercise the seeding and flagging behavior this weight
produces.

---

## Reserve mechanism constants

| Constant | Value |
|---|---|
| `MAX_RESERVE_SKIM_BPS` | 1000 (10%) |
| `MIN_DONATE_THRESHOLD` | 1e15 (0.001 of an 18-decimal token) |

**Why cap the skim at 10% of a toxic swap's output:** the reserve
mechanism exists to redirect value from toxic flow to LPs, but a
trader — even one triggering our toxicity detection — must always walk
away with the large majority of their expected output. A skim with no
ceiling could, in a worst-case combination of extreme signals, leave a
trader with a token amount that doesn't reflect a good-faith swap at
all. 10% is a firm ceiling well below that threshold, deliberately
conservative. **Tested at its exact boundary:**
`testFuzz_reserveSkim_neverExceedsMaxBps` (256 runs) directly asserts
the trader always receives nonzero, bounded output, and
`invariant_reserveNeverExceedsActualBalance` (128,000 operations)
confirms the resulting reserve accounting always stays solvent no
matter what sequence of swaps produced it.

**Why auto-release at 0.001 tokens, not immediately or at a much
higher threshold:** releasing on every single skim, however tiny,
would mean paying a `donate()` call's gas cost far more often than
necessary — real, wasted cost for LPs. Waiting for a much larger
threshold would mean LPs' earned value sits idle in the contract for
longer than needed. 0.001 of an 18-decimal token is small enough that
LPs see their earned reserve realized promptly under normal trading
volume, while large enough that we're not triggering a donation for
economically negligible dust. **Tested:**
`test_reserveCrossingThreshold_triggersAutomaticRelease` and
`test_manyToxicSwaps_neverRevertsOrDesyncs` (a 30-swap sequence)
directly exercise crossing this threshold multiple times.

---

## Governance / trust-model constants

| Constant | Value |
|---|---|
| `ORACLE_CHANGE_TIMELOCK` | 24 hours |
| `ANOMALY_THRESHOLD_BPS` (OracleGuardian) | 1000 (10%) |

**Why 24 hours, not 1 hour or 7 days:** this is the window during which
a queued oracle change sits visible on-chain (via the
`OracleChangeQueued` event) before taking effect, giving anyone —
LPs, other protocols, automated monitors like OracleGuardian —
time to notice and react to a suspicious change before it can affect
real fee calculations. 24 hours is long enough to comfortably exceed
any reasonable human reaction time across time zones, while short
enough that a legitimate operational change (e.g., migrating to a
better oracle) isn't paralyzed for an excessive period. **Tested:**
`test_configurePool_changeIsQueuedNotImmediate`,
`test_applyPendingOracleChange_revertsBeforeTimelockElapses`, and
`test_applyPendingOracleChange_succeedsAfterTimelockElapses` directly
exercise this exact boundary.

**Why a 10% single-update threshold for OracleGuardian's anomaly
detection:** a single Chainlink update moving by more than 10% in one
round is either a genuine, rare, extreme market event or a sign of
oracle malfunction/manipulation — either way, worth an independent,
automatic pause while it's investigated. 10% is set comfortably above
ordinary volatility (even fast-moving markets rarely move this much in
a single Chainlink round, which updates far more frequently than every
10% price move) so the guardian doesn't fire on routine volatility, but
low enough to catch a genuinely abnormal single jump quickly. **Tested:**
`test_react_onAnomalousPriceJump_emitsCallback` and
`test_react_onNormalPriceMovement_doesNotEmitCallback` in
`OracleGuardianReactive.t.sol` directly exercise both sides of this
boundary. **Also verified live**: this exact mechanism has been proven
end-to-end on real Sepolia + Reactive Lasna infrastructure — see the
README's OracleGuardian section for the real transaction evidence.

---

---

## JIT liquidity defense constants

| Constant | Value |
|---|---|
| `JIT_MAX_PENALTY_BPS` | 8000 (80%, at same-block removal) |
| `JIT_DECAY_BLOCKS` | 10 |

**Why 80% at the maximum, not 100%:** the penalty applies only to
accrued fees, never to a position's principal — LPs always get their
deposited capital back in full. An 80% cap is deliberately not 100%,
leaving a small residual even in the worst case, as a defensive buffer
against the rare chance the same-block detection catches an edge case
that isn't genuinely JIT — while 80% is still high enough that a real
JIT bot's entire strategy (capturing close to 100% of a fee with
near-zero risk) becomes unprofitable against realistic gas costs.

**Why a 10-block decay window, not a hard same-block-only cutoff:** an
earlier version of this defense used a hard cutoff — full penalty at
block 0, zero penalty at block 1. That has a real, exploitable
weakness: a bot patient enough to wait exactly one extra block pays
nothing at all, right at the edge of detection. A smooth, 10-block
linear decay removes that cliff entirely — there's no single block
where waiting one more suddenly makes a position penalty-free, and the
longer a position is genuinely held, the more real price risk it has
actually taken on, which is the legitimate economic basis for earning
fees at all. **Tested exactly, not approximately:** a position removed
at precisely the halfway point (5 of 10 blocks) produced a penalty of
exactly half the same-block value (`11,999,999,999,999,999` wei vs.
`23,999,999,999,999,999` wei) — see
`test_jitDecay_partialHoldingPeriod_getsProportionallyReducedPenalty`.
**Also verified live** on real Sepolia infrastructure: a real position
held for 2 real blocks produced a real, nonzero, correctly-scaled
penalty, confirmed by both the emitted event and a persistent
on-chain reserve balance — see the README's JIT section for the full
transaction evidence.

---

## Two governance mechanisms added on final review, not part of the original design

**`emergencyPause()` — a general circuit breaker for the pool
configurer.** Added after comparing this project's feature set against
another real UHI project's explicit safety features, which included a
general admin pause independent of any specific automated trigger.
Before this, the *only* way to pause a pool was through the guardian
mechanism — meaning a configurer who discovered an emergency the
guardians weren't designed to catch (an unrelated bug, a credible
community report) had no direct way to act. Deliberately symmetric
with the existing `resume()`: same access control, same pool-scoped
effect. **Tested:** `test_emergencyPause_succeedsForConfigurer`,
`test_emergencyPause_revertsForNonConfigurer`,
`test_emergencyPause_worksIndependentlyOfGuardian`. **Verified live**
on real Sepolia infrastructure, including confirming the fee correctly
collapses to `BASE_FEE` while paused via this new path, exactly as it
does under a guardian-triggered pause.

**A 24-hour timelock on changing an existing guardian — a real,
significant vulnerability found on final review.** The original
`setGuardian()` had no timelock at all: a compromised configurer could
instantly swap out a real, working guardian for a useless one,
completely disabling both `OracleGuardian` and `ZKPriceGuardian`
*before* even attempting a malicious oracle change — meaning neither
safety layer would ever get a chance to fire, a real gap worse than
the already-disclosed pause/timelock interaction earlier in this
document. Fixed by applying the exact same timelock pattern already
proven for oracle changes: only the *first-ever* guardian assignment
for a pool applies immediately (there's nothing real to bypass yet);
any change to an *existing* guardian is queued behind the same 24-hour
window. **Proven, not just fixed:** a test was written that first
demonstrated the real vulnerability (confirmed passing, proving the
exploit was genuine), then the fix was applied, and the *same* test
was rewritten to confirm the fix — `test_VULNERABILITY_FIXED_guardianChangesAreNowTimelockedNotInstant`.
**Verified live**: an actual attempt to swap the real, live guardian
for a dead address on Sepolia was confirmed queued, not applied — the
real guardian remained fully active, directly proven by both the
correctly-emitted `GuardianChangeQueued` event (checked against its
exact real signature, not assumed) and a direct `guardian()` query
immediately after.

---

## What's genuinely still open

Every number above has a stated rationale and a test that exercises its
boundary. What none of them have yet is validation against **real
historical market data** — i.e., replaying actual past Chainlink price
histories and actual past swap volumes through these exact thresholds
to see how they would have performed during a real, known volatile
period. That is a distinct, planned next step, not something this
document claims to have already done.
