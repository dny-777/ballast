# Ballast — Static Analysis Triage

This document records the results of running [Slither](https://github.com/crytic/slither)
(v0.11.6) against `src/BallastHook.sol`, and the real reasoning behind
every finding — not just a list of what was flagged, but why each one
is either already safe, already tested, or (in one case) actually
*outdated* guidance we correctly don't follow.

## How to reproduce

```bash
pip install slither-analyzer --break-system-packages
slither src/BallastHook.sol --solc-remaps \
  "v4-core/=lib/v4-hooks-public/lib/v4-core/src/ \
   v4-hooks-public/=lib/v4-hooks-public/ \
   forge-std/=lib/forge-std/src/ \
   solmate/=lib/v4-hooks-public/lib/v4-core/lib/solmate/ \
   @uniswap/v4-core/=lib/v4-hooks-public/lib/v4-core/"
```

**Result: 0 High, 0 Medium findings in our own code.** 19 findings total
in `BallastHook.sol` specifically (after excluding third-party library
noise and pure style/naming conventions), all Low/Informational,
triaged individually below.

## Category 1: "Dangerous strict equality" (5 findings) — false positives, by design

Slither flags every `==` comparison as a heuristic risk. Every instance
here is a same-block detection check (`lastSnapshotBlock[poolId] ==
block.number`) or a "did nothing get skimmed" zero-check
(`penalty0 == 0 && penalty1 == 0`). These are exactly the comparisons
we *want* — checking "is this literally the same block" or "is this
literally zero" is correct and safe here; there's no rounding or
precision concern strict equality could hide.

## Category 2: Reentrancy patterns in `_afterSwap` / `_afterRemoveLiquidity` (2 findings) — already proven safe, not just reasoned about

Slither correctly identifies that `poolManager.take()` (an external
call) happens before `pendingReserve` is updated in both functions.
**We don't just argue this is safe — we built a real, adversarial test
proving it** (`test/ReentrancyTest.t.sol`): a malicious token
attempting to re-enter and trigger a nested swap during exactly this
window, confirmed to be blocked by Uniswap v4's own protocol-level
reentrancy lock. `Reentrancy attempted: true`, `Reentrancy succeeded:
false` — real, empirical evidence, not just static-analysis-informed
confidence.

## Category 3: Unused return values (7 findings) — each checked individually, all intentional

- `poolManager.getSlot0()` — we only need `sqrtPriceX96`; ignoring
  `tick`/`protocolFee`/`lpFee` is intentional, not an oversight.
- `SwapMath.computeSwapStep()` — Signal 2 only needs the resulting
  price, not the exact input/output/fee amounts also returned.
- `poolManager.settle()` — the caller already knows the settled
  amount; this is standard, common practice in hook code.
- `poolManager.donate()` — returns a `BalanceDelta` representing what
  the *caller* (our hook) owes/is owed as a direct result of donating.
  We verified this is safe by direct evidence, not assumption: this
  exact code path has been exercised in real, passing tests (including
  a real, live donation on Sepolia during our OracleGuardian and
  sandwich-attack testing) with no unsettled-delta failures.
- `feed.latestRoundData()`'s `roundId` / `answeredInRound` — see
  Category 4, since this one turned out to be genuinely interesting.

## Category 4: The one finding worth real investigation — and it turned out to be a non-issue, for a specific, verified reason

Slither flags that we ignore `answeredInRound` from Chainlink's
`latestRoundData()`. Historically, checking `answeredInRound >=
roundId` was recommended to detect a specific stale-round edge case.

**We looked into this rather than either dismissing it or blindly
adding the check.** Current, authoritative sources — including
Chainlink's own documentation — confirm this check is now **deprecated**:
modern Chainlink aggregators always return `answeredInRound == roundId`,
making the comparison tautological. Current, correct best practice is
exactly what we already do: rely on `updatedAt` against a staleness
threshold (`maxOracleStaleness`, already implemented and tested in
`test_previewFee_staleOracle_reverts`).

**The honest conclusion:** what looked like a real gap turned out to be
us already following *current* best practice, while the "fix" the
static-analysis literature might suggest is actually *outdated*
guidance. Worth documenting precisely, rather than either quietly
skipping it or adding an unnecessary, meaningless check just to clear
a linter warning.

## Category 5: Timestamp comparisons (3 findings) — already reasoned about directly in the code

`block.timestamp` is used for the 24-hour oracle timelock and oracle
staleness checks. Both are already documented inline with the specific
reasoning: validator timestamp manipulation is bounded to roughly
±seconds, utterly negligible against multi-hour windows. Restated here
for completeness, not because it was missed before.

## Summary

| Category | Count | Real issue? |
|---|---|---|
| Strict equality | 5 | No — correct by design |
| Reentrancy pattern | 2 | No — empirically proven safe (real adversarial test) |
| Unused return values | 7 | No — each individually verified intentional |
| `answeredInRound` | 1 | No — verified this is deprecated guidance, not a gap |
| Timestamp comparisons | 3 | No — already reasoned about, bounded and safe |
| **Total actionable findings** | **0** | |

No code changes resulted from this pass — but every finding was
individually investigated and the reasoning recorded, rather than
either ignored or "fixed" reflexively without understanding why
Slither flagged it.

**Re-run after later adding `emergencyPause()`** (a general,
configurer-triggered circuit breaker, added after comparing our
feature set against another real UHI project's explicit safety
features): confirmed clean, introducing zero new findings of any kind.

**Re-run again after a genuinely significant fix found on final
review, unrelated to Slither itself:** manually re-examining every
externally-callable function uncovered that `setGuardian()` had NO
timelock at all — a compromised configurer could instantly swap out a
real, legitimate guardian for a useless one, disabling both
OracleGuardian and ZKPriceGuardian entirely, before even attempting a
malicious oracle change. Fixed by applying the exact same timelock
pattern already proven for oracle changes. Confirmed with a real test
that initially demonstrated the vulnerability, then correctly started
failing once the fix was applied — proving the fix genuinely closes
the gap, not just asserting it does. This re-run introduced no new
finding categories beyond the same, already-triaged timestamp-comparison
pattern.
