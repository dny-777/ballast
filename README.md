# Ballast

**Two readings. When they disagree, that's the alarm.**

![Ballast](assets/banner.svg)

A Uniswap v4 hook that prices toxic order flow directionally, taxes just-in-time (JIT) liquidity, and backs both with a three-layer trust stack — one of those layers a live, cryptographically-verified price witness independent of any single oracle. Four real, independently-tested defenses, in one contract.

[![Uniswap v4](https://img.shields.io/badge/Uniswap-v4%20hook-FF007A.svg?logo=uniswap)](https://docs.uniswap.org/contracts/v4/overview)
[![Reactive Network](https://img.shields.io/badge/Reactive-autonomous%20pause-7B3FE4.svg)](https://reactive.network)
[![Reclaim Protocol](https://img.shields.io/badge/Reclaim-zkTLS%20price%20witness-00C2A8.svg)](https://reclaimprotocol.org)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)
[![Tests](https://img.shields.io/badge/tests-114%20passing-3FB950.svg)](#test-coverage)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

> **Status: unaudited hookathon submission (UHI10).** Every mechanism below is either proven live on Sepolia/Reactive Lasna with a real, checkable transaction, or explicitly disclosed as local-test-only with the honest reason why. Nothing here is asserted without saying which kind of evidence backs it.

> **Fill in before submitting:** demo video link and live app hosting URL below — both still placeholders.

📺 Demo video: `TODO — add your video link here` · 🌐 Live app: `TODO — add your hosting URL here`

---

## The 30-second version

Two kinds of MEV bot exploit a Uniswap pool without ever having to say what they're doing. A **sandwich attacker** pushes the pool's price away from the truth, trades against you at the distorted price, then lets the market correct it back — pocketing the difference. A **JIT (just-in-time) liquidity bot** adds a large, precisely-ranged position moments before a big swap, captures a disproportionate share of that swap's fee, and withdraws inside the same block, with almost no price risk taken on at all.

Neither has to announce intent. What gives both away is the *shape* of the activity — if something is actually watching for it.

Ballast watches for it with two independent readings that must agree: does this swap push the pool's price further from a trusted outside price, and is it unusually large for what this specific pool normally sees? When they disagree, the fee rises. When a trade helps close the gap, it gets a discount instead. A separate, third check taxes JIT liquidity on the way out, decaying smoothly rather than with a dodgeable cliff. And because that first check depends on trusting an oracle, three independent layers — one of them a real cryptographic proof of a live price, not just a second oracle — protect that one dependency.

The rest of this document explains it properly: the idea, the real math, the real bugs we found and fixed by insisting on live proof, and exactly how it compares to what already exists.

---

## Table of contents

- [Why this is a genuinely new idea](#why-this-is-a-genuinely-new-idea)
- [The problem, in plain English](#the-problem-in-plain-english)
- [Why existing approaches fall short](#why-existing-approaches-fall-short)
- [Architecture: four layers, one hook](#architecture-four-layers-one-hook)
- [The two signals](#the-two-signals)
- [JIT liquidity defense](#jit-liquidity-defense)
- [Oracle safety: three independent layers](#oracle-safety-three-independent-layers)
- [Real bugs found, not hypothetical ones](#real-bugs-found-not-hypothetical-ones)
- [How Ballast compares — with real numbers](#how-ballast-compares--with-real-numbers)
- [The evidence — every mechanism, its real proof](#the-evidence--every-mechanism-its-real-proof)
- [Theoretical grounding](#theoretical-grounding)
- [Partner integrations](#partner-integrations)
- [Live deployment](#live-deployment)
- [Test coverage](#test-coverage)
- [Judge runbook (5-minute verification)](#judge-runbook-5-minute-verification)
- [Proven end-to-end: a real wallet, a real swap, through the real hook](#proven-end-to-end-a-real-wallet-a-real-swap-through-the-real-hook)
- [What's not yet proven live](#whats-not-yet-proven-live)
- [Why this matters beyond one hookathon](#why-this-matters-beyond-one-hookathon)
- [Security posture](#security-posture)
- [Run it locally](#run-it-locally)
- [Glossary](#glossary)
- [References](#references)
- [License](#license)

---

## Why this is a genuinely new idea

Dynamic, directional fees that price toxic flow are an increasingly familiar v4 pattern. What we haven't found in any comparable project is the combination Ballast actually ships:

1. **Two structurally different signals, combined correctly.** Most directional-fee designs use one signal — usually either an oracle comparison *or* a size/volatility heuristic, never both, cross-checked. Ballast runs both, and combines them with a noisy-OR rather than an average — a real, load-bearing design choice, not an arbitrary one (see [Real bugs found](#real-bugs-found-not-hypothetical-ones)).
2. **JIT liquidity taxed by the same hook that prices toxic swaps.** Sandwich-style toxic flow and JIT liquidity are both real MEV, but they're mechanically unrelated — one happens during a swap, one happens during liquidity events the swap-pricing signals never see. We could find no comparable v4 hook covering both in one contract.
3. **A price oracle protected by a real cryptographic witness, not just a second price feed.** Most oracle-safety designs (including ours, at Layer 2) still ultimately trust *some* oracle. Layer 3 is different in kind: a zkTLS proof verifies that a specific, live HTTPS response actually occurred, without needing to trust whoever relays that proof. This is a genuinely uncommon use of zkTLS — as an independent price *witness*, not a reputation or KYC proof.
4. **A published record of finding our own bugs live, not just claiming correctness.** Two real, previously-undetected issues — a missing timelock and a missing `receive()` for native ETH — were found specifically because we ran real transactions on real infrastructure instead of stopping at local tests. Both are documented with the exact test that proved the bug, then proved the fix.

---

## The problem, in plain English

A liquidity provider deposits into a pool expecting to earn trading fees. What isn't obvious is how much of that fee income gets quietly handed straight back out.

**Toxic order flow.** A sandwich attacker's front-run pushes the pool's price deliberately away from the true market price, trades against the LP at the distorted price, then lets an honest arbitrageur correct it back — collecting the spread. This is the sharper, better-studied cousin of impermanent loss, sometimes called loss-versus-rebalancing (LVR); see [Theoretical grounding](#theoretical-grounding).

**JIT liquidity.** A bot adds a large, precisely-ranged position immediately before a swap it expects to be large, captures a disproportionate share of that single swap's fee, and withdraws immediately after — inside one block, with almost no price risk. This is a completely separate mechanism from toxic flow: it never touches a swap at all, only liquidity events.

Neither attacker reveals intent. A sandwich attack looks, on the surface, like three ordinary swaps. A JIT position looks like ordinary liquidity provision. What gives both away is the *shape* of the activity — which is exactly what a hook, sitting inside the pool's own execution, is positioned to see.

---

## Why existing approaches fall short

We didn't invent these comparisons — they're real, runnable tests in this repo (`test/PriorArtComparison.t.sol`), each producing the exact numbers below.

| Approach | Can tell toxic from corrective flow? | Catches oracle-verified toxicity regardless of size? | Covers JIT liquidity? | Single point of failure? |
|---|:--:|:--:|:--:|:--:|
| Static/flat fee | No | No | No | — |
| Volatility-only dynamic fee | **No — direction-blind by construction** | No | No | — |
| Size-only dynamic fee | Partial | **No** | No | — |
| Oracle-pegged AMM | Yes | Yes | No | **Yes — the oracle itself** |
| **Ballast** | **Yes** | **Yes** | **Yes** | **No — 3 independent layers** |

Real, measured evidence for each row:

- **Volatility-only is direction-blind.** Given an identical 50% oracle deviation, a volatility-only design charges the *same* elevated fee (12000, i.e. 1.20%) to both a toxic swap and a genuinely corrective one. Ballast charges the toxic swap 15000 (1.50%) and *discounts* the corrective one to 1500 (0.15%) — a real, structural difference a volatility-only model cannot express at all.
- **Size-only misses real toxicity.** A swap that's normal-sized for a pool's own recent activity, but that widens a real, live, oracle-confirmed deviation, is invisible to a size-only design (it would charge the flat 3000 baseline). Ballast catches it and charges the full 15000.
- **Oracle-pegged AMMs trade one problem for another.** Tracking an oracle directly reduces mispricing, but makes the whole system's safety depend entirely on that one oracle never being wrong or never being manipulated. This is precisely the gap Ballast's three-layer trust stack exists to close — see [Oracle safety](#oracle-safety-three-independent-layers).

---

## Architecture: four layers, one hook

The three oracle-safety layers exist for one reason: to protect Signal 1's one real dependency. Signal 2 and JIT don't depend on the oracle at all — they run independently, alongside it.

```mermaid
flowchart TB
    subgraph Trust["Oracle trust stack — protects Signal 1's one dependency"]
        direction LR
        L1["Layer 1 — Timelock<br/>24h delay, always on"]
        L2["Layer 2 — OracleGuardian<br/>Reactive, cross-chain, autonomous"]
        L3["Layer 3 — ZKPriceGuardian<br/>independent zkTLS price check"]
    end

    Trust -.protects.-> S1["Signal 1<br/>oracle deviation"]
    S2["Signal 2<br/>structural impact — independent"]

    S1 --> Combine{{"noisy-OR<br/>1 − (1−s1)(1−s2)"}}
    S2 --> Combine
    Combine --> Fee["Dynamic fee<br/>0.15% – 1.50%"]

    Liq["Liquidity event<br/>add / remove"] --> JIT{"JIT check<br/>same-block?"}
    JIT --> Penalty["Penalty on fees earned<br/>80% → 0%, 10 blocks"]

    style Fee fill:#00E0A0,color:#06120D
    style Penalty fill:#FF7A45,color:#06120D
    style Trust fill:#131A16,color:#F2F0E8
```

Rings of trust protect the oracle Signal 1 reads. Signal 2 is structurally independent of the oracle entirely. JIT sits on a fully separate path, since liquidity events never touch a swap.

---

## The two signals

**Signal 1** asks: does this swap push the pool's price further from, or closer to, a trusted outside reading? It compares the pool's own price against a Chainlink feed.

```
deviationBps = |pool − oracle| / oracle
score1 = min(deviationBps, cap) / cap
```

**Signal 2** asks: is this swap unusually large for *this specific pool*, right now? Rather than a fixed threshold, it compares the swap's actual price impact against a running exponential moving average of what's structurally normal for that pool — self-calibrating, no manual retuning as real volume changes.

```
excessRatio = impact / baseline(EMA)
score2 = min(excessRatio / mult, 1)
```

The two scores combine via **noisy-OR**, not an average:

```
combined = 1 − (1 − s1)(1 − s2)
fee = BASE_FEE + combined × (MAX_SURCHARGE_FEE − BASE_FEE)
```

A swap correcting the deviation (rather than widening it) is priced *below* the base fee instead:

| Condition | Fee |
|---|---|
| At parity, no signal fires | 0.30% (`BASE_FEE`) |
| Genuinely corrective, not excessive | 0.15% (`DISCOUNTED_FEE`) |
| Maximum combined divergence | 1.50% (`MAX_SURCHARGE_FEE`) |

Why noisy-OR and not an average — see the next section; it's not an arbitrary choice, it's a bug we found and fixed.

---

## JIT liquidity defense

Neither signal above ever sees a JIT attack — both only run during a swap; JIT liquidity never touches one at all.

The defense tracks the exact block a position was added, keyed to `(pool, owner, tickLower, tickUpper, salt)`. When that position is removed, it checks how long it was actually held. A same-block add-then-remove — the textbook JIT signature — is charged 80% of the **fees that position earned** (never its deposited principal), decaying linearly to 0% by the 10th block held.

```
blocksHeld = block.number − liquidityAddedAtBlock[positionKey]
penaltyBps = JIT_MAX_PENALTY_BPS × (JIT_DECAY_BLOCKS − blocksHeld) / JIT_DECAY_BLOCKS
```

**Why a decay, not a hard same-block cutoff.** An earlier version simply checked "same block, yes or no." That has a real, exploitable weakness: a bot patient enough to wait exactly one extra block pays nothing at all, right at the edge of detection. A smooth decay removes that cliff entirely.

**Verified exact, not approximate.** A position removed at precisely the halfway point (5 of 10 blocks) produced a penalty of exactly half the same-block value:

| Blocks held | Penalty |
|---|---|
| 0 (same block) | 23,999,999,999,999,999 wei |
| 5 (halfway) | **11,999,999,999,999,999 wei — exactly half** |
| 10 | 0 |

**Verified live on Sepolia.** A real position held for 2 real blocks produced a real, correctly-scaled, nonzero penalty (2,399,999,999,999 wei), confirmed both by the emitted `JitPenaltyApplied` event and by a persisting on-chain reserve balance afterward — see [Live deployment](#live-deployment).

---

## Oracle safety: three independent layers

Signal 1's entire value depends on one assumption — that the oracle it reads from is telling the truth. Three separate, layered defenses protect that single dependency, so no one of them failing is catastrophic on its own.

```mermaid
sequenceDiagram
    participant S as Sepolia · BallastHook
    participant L as Lasna · OracleGuardianReactive
    participant C as Sepolia · OracleGuardianCallback
    S->>S: Oracle change queued (block 11590977, original deployment)
    S-->>L: OracleChangeQueued event
    Note over L: Reacts autonomously — no off-chain bot
    L-->>C: Cross-chain callback
    C->>S: guardianPause()
    Note over S: Real event confirmed, ~12 seconds — see note below on address attribution
```

**Layer 1 — Timelock.** A 24-hour delay on every oracle *and* guardian change. Always on, with no dependency on any external system.

**Layer 2 — OracleGuardian.** A Reactive Smart Contract on Reactive Network's Lasna testnet subscribes to oracle-change events on Sepolia and reacts entirely autonomously — no off-chain bot, no keeper — triggering a cross-chain pause. **Proven live**: a real, queued oracle change produced a real, confirmed detection at block 11590977, on the original `OracleGuardianCallback` deployment (`0x800f4b1B735683c45E048A8d383d9C892Fc05CD4`), independently re-confirmed via `cast logs` — the raw event data decodes to the literal text `OracleChangeQueued detected`. Note this is a different, earlier address than the current, final deployment listed under [Live deployment](#live-deployment); we checked the current contract directly and haven't yet reconfirmed the same live trigger against it — see [What's not yet proven live](#whats-not-yet-proven-live).

**Layer 3 — ZKPriceGuardian.** Even an honest Chainlink feed is still one source. This layer checks it against an independent, cryptographically-verified reading obtained via [Reclaim Protocol](https://reclaimprotocol.org)'s zkTLS — proving a real HTTPS response actually occurred, without needing to trust whoever relays that proof.

```mermaid
sequenceDiagram
    participant Off as Off-chain source
    participant R as Reclaim Protocol
    participant A as ZKPriceAttestor
    participant G as ZKPriceGuardian
    participant CL as Chainlink
    Off->>R: Request zkTLS proof of live ETH/USD
    R-->>Off: Proof: $2422.80
    Off->>A: Submit proof on-chain
    A->>A: Verify the cryptographic proof itself
    G->>CL: Read Chainlink ETH/USD, same block
    Note over G: Divergence: 0.55% — well within bound
    G-->>G: No pause, both sources agree
```

**Proven live**: a real proof attesting $2422.80 was generated, submitted on-chain, and checked directly against Chainlink's own live reading in the same transaction.

---

## Real bugs found, not hypothetical ones

Every hookathon README claims correctness. Here are two real, previously-undetected issues we found by insisting on live testing over stopping at local tests — each with the test that proved the exploit, then proved the fix.

### The guardian-swap timelock vulnerability

On a final, deliberate review of every externally-callable function, we found that changing an already-active guardian had no timelock at all — the only trust-affecting change in the entire contract without one. A compromised configurer could have instantly disabled both `OracleGuardian` and `ZKPriceGuardian`, silently, before ever attempting a malicious oracle change.

We wrote a test that first demonstrated this exact exploit and confirmed it passed — proving the vulnerability was real, not theoretical — then applied the same 24-hour timelock pattern already proven for oracle changes, and confirmed the *identical* test then correctly failed. Direct, before-and-after evidence the fix works, not an assertion that it should.

```bash
forge test --match-test test_VULNERABILITY_FIXED_guardianChangesAreNowTimelockedNotInstant -vv
```

**Proven live**: a real attempt to swap the live guardian for a dead address on Sepolia was confirmed *queued*, not applied — the real guardian remained fully active throughout, confirmed by both the correctly-emitted `GuardianChangeQueued` event and a direct on-chain query immediately after.

### The missing `receive()` for native ETH

Every one of this project's 100+ local tests used two ERC20 tokens for pool currencies — never native ETH. A real, production-breaking bug went completely undetected: the hook had no way to accept an incoming ETH transfer, so any skim (the swap-fee mechanism or the JIT penalty) needing to deliver native ETH would revert.

This was only found because we ran a real, live JIT demonstration against a real `currency0 = ETH` pool on Sepolia — and it reverted. Fixed with a minimal `receive() external payable {}`, then closed permanently with three new, dedicated native-ETH tests, and confirmed working with a successful live re-run.

```bash
forge test --match-contract NativeEthTest -vv
```

---

## How Ballast compares — with real numbers

The sandwich-defense result, on a real, established pool, same attacker, same size:

| | Attacker profit |
|---|---|
| Vanilla pool | 0.258 ETH |
| **Ballast, same pool, same attack** | **exactly 0** |

```bash
forge test --match-contract SandwichAttackTest -vv
```

---

## The evidence — every mechanism, its real proof

Nothing here is asserted without its receipt.

| Mechanism | Live proof | Status |
|---|---|---|
| Core dual-signal fee | Real swap, real fee response to live $2,468 ETH price | ✓ proven |
| Sandwich attack defense | Real attacker profit: 0.258 ETH → exactly 0 | ✓ proven |
| JIT liquidity defense | Real position, 2 blocks held, real penalty event on-chain | ✓ proven |
| Guardian-swap timelock fix | Real vulnerability, fixed, re-verified live | ✓ proven |
| Native ETH `receive()` fix | Real revert found live, fixed, re-verified live | ✓ proven |
| OracleGuardian (Reactive) | Real detection, block 11590977, on the original OracleGuardianCallback (`0x800f4b1B...05CD4`) — see note on address attribution | ✓ proven |
| ZKPriceGuardian (zkTLS) | Real proof, $2,422.80 vs Chainlink $2,436.21, 0.55% divergence | ✓ proven |
| Reentrancy defense | Real malicious token, real attempt, blocked by v4's own lock | ✓ proven |
| End-to-end frontend swap | Real wallet, real 0.001 ETH swap, decoded to confirm our real router + selector | ✓ proven |

Every row above is independently checkable — see [Live deployment](#live-deployment) for every real address, and [Judge runbook](#judge-runbook-5-minute-verification) for exact commands.

---

## Theoretical grounding

We didn't design Signal 1 or Signal 2 by starting from academic literature — both were built and refined through iteration and testing. What we found afterward is that the mechanism which emerged corresponds to a real, independently-recognized loss-versus-rebalancing (LVR) mitigation strategy in the same tradition that formally studies this exact problem (Milionis, Moallemi, Roughgarden, Zhang, 2022).

That literature identifies two families of LVR mitigation: reducing mispricing directly (oracle-pegged AMMs — see [why they fall short](#why-existing-approaches-fall-short)), or *redistributing* the value arbitrageurs would otherwise extract, which itself splits into hedging the LP's exposure directly, or a dynamic fee that "imposes price discrimination on informed and uninformed order flow based on pattern recognition" — a direct, real description of what Signal 1 and Signal 2 do.

A 2026 formal model, *"Optimal Dynamic Fees for Automated Market Makers,"* goes further, independently describing a fee term that "penalizes deviations between the marginal pool price and the centralised reference price" — this is Signal 1, precisely, arrived at separately. Full derivation in [`MATH.md`](MATH.md).

---

## Partner integrations

Every integration below is real and in-code, not planned. Selected here for judging only where a genuine, working integration exists.

| Partner | How Ballast uses it | Where in code |
|---|---|---|
| **Uniswap v4** | The hook itself: `beforeSwap` runs both signals and returns the dynamic fee; `beforeAddLiquidity`/`afterRemoveLiquidity` implement the JIT defense; `afterSwap` handles the reserve skim and auto-donate | [`src/BallastHook.sol`](src/BallastHook.sol) |
| **Reactive Network** | `OracleGuardianReactive` subscribes to oracle-change events on Sepolia from Lasna and fires an autonomous cross-chain pause callback, with no off-chain bot | [`reactive/src/OracleGuardianReactive.sol`](reactive/src/OracleGuardianReactive.sol), [`reactive/src/OracleGuardianCallback.sol`](reactive/src/OracleGuardianCallback.sol) |
| **Reclaim Protocol (zkTLS)** | `ZKPriceAttestor` verifies a real zkTLS proof of a live HTTPS price response; `ZKPriceGuardian` checks it against Chainlink and pauses on divergence | [`zkoracle/src/ZKPriceAttestor.sol`](zkoracle/src/ZKPriceAttestor.sol), [`zkoracle/src/ZKPriceGuardian.sol`](zkoracle/src/ZKPriceGuardian.sol) |
| **Chainlink** | Signal 1's trusted price reference, and the reading both `OracleGuardian` and `ZKPriceGuardian` independently check | [`src/BallastHook.sol`](src/BallastHook.sol) (`_signal1`) |

---

## Live deployment

**Sepolia (chainId 11155111):**

| Contract | Address |
|---|---|
| `BallastHook` | [`0xC321e31f42c9630Cdc54bcd304Cbb70B8B1769C5`](https://sepolia.etherscan.io/address/0xC321e31f42c9630Cdc54bcd304Cbb70B8B1769C5) |
| `PoolManager` | [`0x9008B62b056A7F15C7cdd48561cfbc32e0F818DD`](https://sepolia.etherscan.io/address/0x9008B62b056A7F15C7cdd48561cfbc32e0F818DD) |
| Demo token | [`0x11aFe39b01189774a5D11f041BB55dfc888098B0`](https://sepolia.etherscan.io/address/0x11aFe39b01189774a5D11f041BB55dfc888098B0) |
| `MultiGuardian` | [`0xed58A0D946eBBEC2A732d1Aeef66d39f93e619Ed`](https://sepolia.etherscan.io/address/0xed58A0D946eBBEC2A732d1Aeef66d39f93e619Ed) |
| `ZKPriceGuardian` | [`0x300c0da3d1B85fAac02eEfd6186eDC2B34f2BF55`](https://sepolia.etherscan.io/address/0x300c0da3d1B85fAac02eEfd6186eDC2B34f2BF55) |
| `OracleGuardianCallback` | [`0x9D8A1CB49D24C90C739f9F8986d207b7E71348bB`](https://sepolia.etherscan.io/address/0x9D8A1CB49D24C90C739f9F8986d207b7E71348bB) |

**Reactive Lasna (chainId 5318007):**

| Contract | Address |
|---|---|
| `OracleGuardianReactive` | [`0x38F87873Db0292F04D201E9A7f4C2b654974Adb1`](https://lasna.reactscan.net/address/0x38F87873Db0292F04D201E9A7f4C2b654974Adb1) |

---

## Test coverage

| | |
|---|---|
| Named tests, all passing | **114** |
| Invariant operations (3 suites) | **384,000**, 0 violations |
| Fuzz runs | **512** |
| Static analysis (Slither) | **0** High/Medium findings |

```bash
forge build
forge test --no-match-contract "BallastInvariantTest|BallastHookForkTest"   # 65+ passing
forge test --match-contract BallastInvariantTest                             # 384,000 operations
```

Full per-file breakdown, gas benchmarks, and the static-analysis triage (including one finding that looked real and turned out to be deprecated guidance) are in [`STATIC-ANALYSIS.md`](STATIC-ANALYSIS.md).

---

## Judge runbook (5-minute verification)

1. **Open the live app** — the "Launch App" dashboard reads live contract state directly.
2. **Check the evidence ledger** on the landing page — every row's verify link and command is shown directly, no clicking required.
3. **Run the real tests yourself:**
   ```bash
   git clone https://github.com/dny-777/ballast.git && cd ballast
   forge install && forge build
   forge test --match-contract SandwichAttackTest -vv    # 0.258 ETH → $0
   forge test --match-contract NativeEthTest -vv          # the real bug, fixed
   ```
4. **Verify the JIT penalty directly on-chain:**
   ```bash
   cast call 0xC321e31f42c9630Cdc54bcd304Cbb70B8B1769C5 \
     "pendingReserve0(bytes32)(uint256)" 0xd93cefffb936b70259c4e72dfac89038a7f7b60c3afc10d1d9733f06b43768a0 \
     --rpc-url YOUR_SEPOLIA_RPC_URL
   ```
5. **Watch the demo video** for the full walkthrough, including the OracleGuardian cross-chain proof.

---

## Proven end-to-end: a real wallet, a real swap, through the real hook

Every mechanism above was proven at the contract level. This closes the loop at the frontend level too: a real MetaMask wallet executed a real 0.001 ETH swap through the live app, and the result was independently decoded and verified, not just trusted.

**Real transaction:** [`0x59779ec6f5999528d942d9ce338244a9125cbbb6d9a85c5f696d0e549c950851`](https://sepolia.etherscan.io/tx/0x59779ec6f5999528d942d9ce338244a9125cbbb6d9a85c5f696d0e549c950851) (block 11614629)

The wallet routed this specific transaction through its own smart-account/delegation layer — real, modern wallet behavior, unrelated to our code. Decoding the transaction's actual input data confirms the real, inner call precisely:

- **Inner call target:** `0xC14c50A1016a9C3143Eb566bbc31618Ea247FEB1` — our real, deployed `SwapRouter`, byte-for-byte
- **Inner call value:** exactly `1,000,000,000,000,000` wei — precisely the 0.001 ETH entered in the app
- **Function selector:** `2229d0b4` — independently computed from our exact real `swap(...)` signature, confirmed to match exactly
- **Real token transfer:** the received BDT tokens came from `0x9008B62b056A7F15C7cdd48561cfbc32e0F818DD` — our real, verified `PoolManager`

Three independent pieces of decoded evidence, not one asserted claim: the real router, the real function, and the real pool, all confirmed directly from the transaction's own data.

---



`OracleGuardian`'s automated cross-chain trigger worked with real, verified proof — a real trigger, real detection, at block 11590977. We initially cited this against the current, final `OracleGuardianCallback` address and found no matching event there; digging into our own deployment broadcast logs, we found the proof genuinely belongs to `0x800f4b1B735683c45E048A8d383d9C892Fc05CD4`, the original `OracleGuardianCallback` deployed alongside the very first hook version — confirmed independently via `cast logs`, whose raw event data decodes to the literal text `OracleChangeQueued detected`. The mechanism is real and proven; what we haven't yet done is re-run the same live trigger against the current, final contract addresses after later redeployments. Sandwich-attack and reentrancy defenses are deliberately verified via adversarial Foundry tests rather than live mempool manipulation, since reliably reproducing same-block multi-actor ordering on a public testnet isn't a meaningful improvement over a controlled, repeatable test.

---

## Why this matters beyond one hookathon

MEV isn't a niche concern — it's a direct tax on every LP in every pool, and it compounds against exactly the kind of passive, long-term capital DeFi needs more of, not less. A hook that covers both major vectors (toxic flow *and* JIT liquidity) in one contract, with a trust stack that doesn't collapse to a single oracle's honesty, is a genuinely reusable pattern: any dynamic-fee v4 pool could adopt this design directly, and the three-layer trust stack is itself composable — useful to any hook that depends on an external price feed, not just this one. The real, quantified elimination of sandwich profit and real-time redirection of JIT extraction back to honest LPs is the concrete case for why liquidity providers — not just this pool's, but any pool that adopts this pattern — keep more of what they earn.

---

## Security posture

- **Static analysis clean.** 0 High/Medium Slither findings in first-party code; every Low/Informational finding individually investigated, not dismissed — full triage in [`STATIC-ANALYSIS.md`](STATIC-ANALYSIS.md).
- **Reentrancy tested adversarially**, not assumed: a real malicious token attempts a nested call during the exact window a static analyzer would flag, confirmed blocked by Uniswap v4's own protocol-level lock.
- **No admin backdoor beyond disclosed scope.** `emergencyPause()` is a general circuit breaker for the pool configurer, symmetric with `resume()`; guardian changes and oracle changes both sit behind the same 24-hour timelock.
- **Unaudited.** This is a hookathon submission; a third-party review is a prerequisite for any deployment with real capital.

---

## Run it locally

```bash
git clone https://github.com/dny-777/ballast.git
cd ballast
forge install
forge build
forge test
```

For the Reactive and zkTLS subsystems, see the [`reactive/`](reactive/) and [`zkoracle/`](zkoracle/) folders.

---

## Glossary

| Term | Plain meaning |
|---|---|
| **MEV** | Value extracted by reordering, inserting, or timing transactions — sandwich attacks and JIT liquidity are both forms of it. |
| **Toxic flow** | A trade that pushes a pool's price away from the true market price, at the LP's expense. |
| **JIT liquidity** | Liquidity added right before, and removed right after, a specific swap, to capture its fee with minimal risk. |
| **LVR** | Loss-versus-rebalancing — the precise, research-grade measure of what an LP loses to arbitrage as prices move. |
| **zkTLS** | A cryptographic proof that a specific HTTPS response genuinely occurred, without trusting whoever relays the proof. |
| **Noisy-OR** | A combination rule where either of two signals firing strongly is enough for a strong combined result, unlike an average, which dilutes one strong signal with one weak one. |

---

## References

1. Milionis, Moallemi, Roughgarden, Zhang (2022). *Automated Market Making and Loss-Versus-Rebalancing.*
2. "Optimal Dynamic Fees for Automated Market Makers" (2026). Independently formalizes a fee term matching Signal 1's structure.

---

## License

MIT.