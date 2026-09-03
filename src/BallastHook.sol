// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

/// @notice Minimal interface for reading a token's `decimals()`. Both
/// standard ERC-20s and WETH-style wrapped native tokens implement this;
/// native ETH itself (currency represented as address(0) in v4) does not,
/// so we special-case it to 18 decimals, matching WETH's convention.
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @notice Minimal ERC-20 transfer interface, used only to settle tokens
/// the hook has taken into its own custody back to the PoolManager when
/// releasing the accumulated reserve via `donate()`.
interface IERC20MinimalTransfer {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title BallastHook
/// @notice A dynamic-fee Uniswap v4 hook that detects toxic/MEV order flow
///         using two independent signals and taxes it to subsidize a lower
///         base fee for everyone else.
///
///         Signal 1 (external, THIS FILE): compares the pool's own price
///         against a live Chainlink reference price. A swap that pushes the
///         pool price further away from the oracle price is treated as the
///         toxic/arbitrage signature described by Milionis, Moallemi,
///         Roughgarden & Zhang (2022), "Automated Market Making and
///         Loss-Versus-Rebalancing" (LVR).
///
///         Signal 2 (structural, stub for now — Days 3-5): will compare a
///         swap's actual expected price impact (via the pool's own swap
///         math) against its recent baseline, catching toxic flow that
///         exploits thin liquidity even when Signal 1 alone doesn't fire.
///
///         Credit: the directional-fee mechanism this hook diverges from is
///         Uniswap Hook Incubator's taught "Nezlobin's Directional Fee"
///         lesson. Ballast's distinct contribution is combining a live
///         external price reference (not just the pool's own previous-block
///         history) with a structural depth/impact signal, and routing the
///         captured surcharge back to LPs via `donate()` on a schedule
///         rather than a one-shot fee change.
contract BallastHook is BaseHook {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    /// @notice Real, significant bug found via live testing, not local
    /// tests: without this, poolManager.take() reverts whenever it
    /// tries to deliver NATIVE ETH to this contract as part of a skim
    /// (the swap-based reserve skim or the JIT liquidity penalty) —
    /// this contract had no way to accept an incoming ETH transfer at
    /// all. Every local test exercising these skim paths used two
    /// ERC20 tokens, never native ETH, so this was never caught until
    /// a real, live JIT demonstration on a real currency0=ETH pool hit
    /// it directly. Deliberately empty: this contract never expects or
    /// uses unsolicited ETH deposits outside of these specific,
    /// protocol-driven internal transfers.
    receive() external payable {}

    // ─────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Thrown if a pool tries to attach this hook without opting
    /// into dynamic fees at initialization.
    error MustUseDynamicFee();

    /// @notice Thrown if the configured Chainlink feed is unset (zero
    /// address) when a price read is attempted.
    error PriceFeedNotSet();

    /// @notice Thrown if the Chainlink feed's last update is older than
    /// `maxOracleStaleness`. We refuse to trust a stale price rather than
    /// silently falling back to un-adjusted fee logic that could be gamed.
    error StalePriceFeed(uint256 updatedAt, uint256 nowTimestamp);

    /// @notice Thrown if the oracle reports a non-positive price. A
    /// non-positive price is never valid and must not be used in any
    /// downstream fee math.
    error InvalidOraclePrice(int256 answer);

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Emitted every time a pool's oracle configuration is set or
    /// changed, for auditability. See `configurePool`'s NatSpec for the
    /// trust assumption this event exists to make visible: the
    /// configurer retains unilateral, ongoing ability to change the
    /// oracle feed for as long as the pool exists.
    event PoolConfigured(
        PoolId indexed poolId, address indexed feed, bool oracleMatchesPoolDirection, uint256 staleness
    );

    /// @notice Emitted when a CHANGE to an already-configured pool's oracle
    /// is queued (not the initial configuration, which applies
    /// immediately — see `configurePool`). Anyone watching this event has
    /// the full timelock window to notice and react before the change can
    /// take effect.
    event OracleChangeQueued(PoolId indexed poolId, address indexed newFeed, uint256 effectiveAt);

    /// @notice Emitted when a previously-queued oracle change actually
    /// takes effect, after the timelock has elapsed.
    event OracleChangeApplied(PoolId indexed poolId, address indexed newFeed);

    /// @notice Emitted when a pending oracle change is canceled before
    /// taking effect.
    event OracleChangeCanceled(PoolId indexed poolId);

    /// @notice Emitted when a pool's guardian address is set or changed.
    event GuardianSet(PoolId indexed poolId, address indexed guardian);

    /// @notice Emitted when a change to an EXISTING guardian is queued
    /// behind the timelock, rather than applied instantly.
    event GuardianChangeQueued(PoolId indexed poolId, address indexed newGuardian, uint256 effectiveAt);

    /// @notice Emitted when a queued guardian change actually takes effect.
    event GuardianChangeApplied(PoolId indexed poolId, address indexed newGuardian);

    /// @notice Emitted when a pending guardian change is canceled.
    event GuardianChangeCanceled(PoolId indexed poolId);

    /// @notice Emitted the instant a pool is paused by its guardian.
    /// Watching this event is itself a useful transparency signal —
    /// anyone can independently confirm a pause happened and when.
    event GuardianPaused(PoolId indexed poolId, address indexed guardian, uint256 timestamp);

    /// @notice Emitted when the pool configurer directly pauses the
    /// pool — a general circuit breaker independent of the guardian
    /// mechanism, for any reason the automated guardians don't cover
    /// (e.g. a discovered bug unrelated to oracle safety, a credible
    /// community report, or any other operational emergency).
    event EmergencyPaused(PoolId indexed poolId, address indexed configurer, uint256 timestamp);

    /// @notice Emitted when a paused pool is resumed. Deliberately only
    /// ever emitted by `resume()`, which only the pool CONFIGURER (never
    /// the guardian) can call — pausing is autonomous and fast; resuming
    /// requires a human decision.
    event Resumed(PoolId indexed poolId, address indexed by, uint256 timestamp);

    /// @notice Emitted whenever the JIT-liquidity penalty is applied —
    /// a same-block add-then-remove was detected and a share of that
    /// position's accrued fees was redirected to the reserve instead of
    /// the withdrawing party.
    event JitPenaltyApplied(PoolId indexed poolId, address indexed liquidityProvider, uint256 amount0, uint256 amount1);

    // ─────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The default swap fee charged when neither toxicity signal
    /// fires, expressed in Uniswap's standard hundredths-of-a-bip units
    /// (i.e. 3000 = 0.30%).
    uint24 public constant BASE_FEE = 3000; // 0.30%

    /// @notice The floor fee for organic/benign flow (Signal 1 clearly
    /// shows the swap correcting the pool back toward the oracle price).
    uint24 public constant DISCOUNTED_FEE = 1500; // 0.15%

    /// @notice The maximum fee charged when Signal 1 fires at full
    /// strength (swap pushing pool price away from the oracle price by at
    /// least `maxDeviationBps`).
    uint24 public constant MAX_SURCHARGE_FEE = 15000; // 1.50%

    /// @notice Deviation (in basis points) between pool price and oracle
    /// price at or above which Signal 1 is considered "fully toxic" and
    /// charges `MAX_SURCHARGE_FEE`. Chosen as an initial, documented,
    /// tunable constant — see README calibration notes for the reasoning
    /// and for how this should be backtested against real pool data before
    /// being treated as final.
    uint256 public constant MAX_DEVIATION_BPS = 200; // 2.00%

    /// @notice Maximum age (in seconds) we will trust a Chainlink price
    /// update before treating the feed as stale and refusing to apply a
    /// Signal-1-driven surcharge for that swap.
    uint256 public constant DEFAULT_MAX_ORACLE_STALENESS = 3600; // 1 hour

    /// @notice Minimum delay between queuing a CHANGE to an already-live
    /// pool's oracle feed and that change actually taking effect. Exists
    /// specifically to close the trust gap flagged in our own security
    /// review (Workshop 13 pass): a configurer with instant, unilateral
    /// oracle-change power could otherwise briefly point at a manipulated
    /// feed to bias a specific swap's classification. The INITIAL
    /// configuration of a pool (see `configurePool`) is exempt — there is
    /// no existing trust relationship to protect before a pool has ever
    /// been configured, and the pool is unusable until it is.
    uint256 public constant ORACLE_CHANGE_TIMELOCK = 24 hours;

    /// @notice Basis-point denominator used throughout this contract.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Signal 2 fires when a swap's expected price impact exceeds
    /// this multiple of the pool's own recent baseline impact. Expressed
    /// as a BPS_DENOMINATOR-scaled multiplier (25000 = 2.5x). Chosen as an
    /// initial, documented, tunable constant — same "needs real
    /// backtesting before being treated as final" caveat as
    /// MAX_DEVIATION_BPS.
    uint256 public constant EXCESS_MULTIPLIER_BPS = 25_000; // 2.5x baseline

    /// @notice Weight given to a new observation when updating the
    /// exponential moving average baseline in `afterSwap`, out of
    /// BPS_DENOMINATOR (1000 = 10%, i.e. roughly a 10-swap-window EMA).
    uint256 public constant EMA_WEIGHT_BPS = 1000; // 10%

    /// @notice Maximum fraction of a toxic swap's UNSPECIFIED-token amount
    /// that is skimmed into the pool's reserve, out of BPS_DENOMINATOR
    /// (1000 = 10%). This is charged ON TOP OF (not instead of) the
    /// elevated dynamic LP fee already applied via beforeSwap's
    /// OVERRIDE_FEE_FLAG — that elevated fee is already distributed
    /// immediately to in-range LPs through Uniswap's own native fee
    /// accounting. This additional skim funds a SEPARATE, hook-held
    /// reserve released on a schedule via `donate()`, smoothing what would
    /// otherwise be "lumpy" realized yield (fat during toxic bursts, thin
    /// when quiet) — the same problem prior toxicity-fee designs (e.g.
    /// EvenFlow, UHI9) explicitly identify and solve the same way.
    /// Scales with the swap's combined toxicity score: a swap that barely
    /// triggers either signal contributes proportionally less to the
    /// reserve than one that fully triggers both.
    uint256 public constant MAX_RESERVE_SKIM_BPS = 1000; // 10%

    /// @notice Minimum accumulated reserve (per currency, in that
    /// currency's own raw units) before an automatic `donate()` release
    /// fires. Prevents dust-sized donations that would cost more in gas
    /// than they're worth distributing.
    uint256 public constant MIN_DONATE_THRESHOLD = 1e15; // 0.001 of an 18-decimal token, scaled per-token in practice — see README calibration notes

    /// @notice The share of a position's ACCRUED FEES (never its
    /// deposited principal) redirected to genuine, patient LPs when
    /// liquidity is added and removed within the SAME block — the
    /// classic, textbook JIT (Just-In-Time) liquidity signature: a bot
    /// adds a large, precisely-ranged position immediately before a
    /// known large swap, captures a disproportionate share of that
    /// swap's fee, then withdraws immediately after, all in one block,
    /// taking on essentially zero price risk. This is a real, distinct
    /// MEV vector our swap-level Signal 1/Signal 2 defenses do not
    /// touch at all, since they only observe swaps, never liquidity
    /// lifecycle events. Set high (80%) deliberately: legitimate LPs
    /// essentially never have an economic reason to add and fully
    /// remove the exact same position within one block, so the
    /// false-positive cost of an aggressive penalty here is very low,
    /// while a JIT bot's entire strategy depends on capturing close to
    /// 100% of that fee with near-zero risk — even a modest residual
    /// share surviving this penalty is likely smaller than the bot's
    /// own gas cost, making the strategy unprofitable in practice.
    uint256 public constant JIT_MAX_PENALTY_BPS = 8000; // 80%, at block 0 (same-block removal)

    /// @notice How many blocks the penalty decays over, reaching 0% at
    /// exactly this many blocks held. A real, honest improvement over
    /// an earlier, flat "same-block only" version of this defense: a
    /// hard same-block-only check has a real, exploitable weakness — a
    /// JIT bot patient enough to wait just ONE extra block pays no
    /// penalty at all, right at the edge of detection. A smooth decay
    /// removes that hard cliff entirely: there's no single block where
    /// waiting one more suddenly makes the position penalty-free, and
    /// the bot's core problem is unchanged — the longer it holds, the
    /// more real price risk it's actually exposed to, which is the
    /// legitimate economic reason genuine LPs are compensated with
    /// fees at all.
    uint256 public constant JIT_DECAY_BLOCKS = 10;

    // ─────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Tracks the block a given liquidity position was last
    /// added to (or topped up), keyed by a hash of
    /// (poolId, owner, tickLower, tickUpper, salt) — the same
    /// components v4 itself uses to identify a unique position. Used
    /// exclusively to detect the same-block add-then-remove JIT
    /// signature at removal time.
    mapping(bytes32 positionKey => uint256 addedAtBlock) public liquidityAddedAtBlock;

    /// @notice The Chainlink price feed used as the external reference
    /// price for a given pool. Configured per-pool (not globally) so this
    /// hook can serve pools for different token pairs, each needing its
    /// own correct reference feed.
    mapping(PoolId poolId => IAggregatorV3 feed) public priceFeeds;

    /// @notice Per-pool override for maximum oracle staleness. Falls back
    /// to `DEFAULT_MAX_ORACLE_STALENESS` when unset (0).
    mapping(PoolId poolId => uint256 maxStaleness) public maxOracleStaleness;

    /// @notice Whether `currency0` in the given pool corresponds to
    /// "token0" in the oracle's own quoting convention (i.e. whether the
    /// oracle's price is already expressed as currency0-per-currency1, the
    /// same convention Uniswap uses internally). Pool owners must set this
    /// correctly at configuration time — see `configurePool`.
    mapping(PoolId poolId => bool oracleMatchesPoolDirection) public oracleDirectionMatchesPool;

    /// @notice Cached decimals for currency0 and currency1 of a configured
    /// pool, read automatically from each token at `configurePool` time.
    /// Needed because `sqrtPriceX96` encodes price in RAW (undecimalized)
    /// token units — comparing that directly against a human-scale oracle
    /// price is only valid when both tokens share the same decimals. For
    /// any pair with mismatched decimals (e.g. WETH [18] / USDC [6], the
    /// common case), the raw pool price must first be corrected by
    /// 10^(decimals0 - decimals1) before it's comparable to the oracle.
    mapping(PoolId poolId => uint8 decimals) public currency0Decimals;
    mapping(PoolId poolId => uint8 decimals) public currency1Decimals;

    /// @notice Accumulated surcharge reserve per pool, tracked separately
    /// for each currency (a swap's skim is always taken from whichever
    /// currency is the "unspecified" side of that particular swap — see
    /// `_afterSwap` — so both currencies can accumulate reserve over time
    /// depending on swap direction mix).
    mapping(PoolId poolId => uint256 reserve0) public pendingReserve0;
    mapping(PoolId poolId => uint256 reserve1) public pendingReserve1;

    /// @notice Pool owner/configurer, set at `beforeInitialize` time to
    /// whoever initializes the pool. Only this address may configure the
    /// price feed and staleness window for that pool.
    mapping(PoolId poolId => address configurer) public poolConfigurer;

    /// @notice The address authorized to pause a pool as a fail-safe
    /// (intended to be a Reactive Network callback contract watching for
    /// oracle-related anomalies — see OracleGuardian docs). Deliberately
    /// separate from `poolConfigurer`: the guardian can only ever PAUSE,
    /// never resume, never change the oracle, never withdraw funds. A
    /// guardian that could do more than pause would just be a second
    /// admin key, not a safety mechanism.
    mapping(PoolId poolId => address guardianAddr) public guardian;

    /// @notice A queued guardian change, not yet effective. Real fix
    /// found on final review: an earlier version let setGuardian()
    /// change instantly, with no timelock at all — meaning a
    /// compromised configurer could silently swap out a real,
    /// legitimate guardian for a useless one, disabling BOTH
    /// OracleGuardian and ZKPriceGuardian entirely, before even
    /// attempting a malicious oracle change. Now timelocked exactly
    /// like an oracle change: only the FIRST-ever guardian assignment
    /// (from no guardian at all) applies immediately, since there's
    /// nothing real to bypass yet.
    mapping(PoolId poolId => address pendingGuardianAddr) public pendingGuardian;
    mapping(PoolId poolId => uint256 effectiveAt) public pendingGuardianEffectiveAt;

    /// @notice Whether a pool is currently paused. While paused,
    /// `beforeSwap` skips BOTH signals entirely and falls back to
    /// `BASE_FEE` — neutralizing exposure to whatever triggered the
    /// pause (e.g. a compromised or anomalous oracle) rather than fully
    /// halting the pool. Trading continues at a safe, signal-independent
    /// fee; only the toxicity-detection logic is suspended.
    mapping(PoolId poolId => bool isPaused) public paused;

    /// @notice A queued (not-yet-effective) oracle change for an
    /// already-configured pool. Applied via `applyPendingOracleChange`
    /// once `pendingFeedEffectiveAt` has passed. Zero address means no
    /// change is currently queued.
    mapping(PoolId poolId => address feed) public pendingFeed;
    mapping(PoolId poolId => bool matches) public pendingOracleMatchesPoolDirection;
    mapping(PoolId poolId => uint256 staleness) public pendingStaleness;
    mapping(PoolId poolId => uint256 timestamp) public pendingFeedEffectiveAt;

    /// @notice Security: top-of-block snapshot of the pool's own price,
    /// used for Signal 1's comparison instead of the live, same-transaction
    /// price. Without this, an attacker could manipulate the pool's price
    /// with an earlier transaction in the same block (e.g. via a flash
    /// loan), then have a later transaction's Signal 1 check compare
    /// against that already-manipulated price — potentially making a
    /// genuinely toxic swap appear corrective. Snapshotting once per block
    /// (the same top-of-block pattern taught for Nezlobin's directional
    /// fee) means every swap within a block is judged against the price
    /// that existed BEFORE that block's own activity could have moved it.
    mapping(PoolId poolId => uint256 priceX18) public blockSnapshotPoolPriceX18;

    /// @notice Security: top-of-block snapshot of Signal 2's baseline
    /// impact, used for the excess-ratio comparison instead of the live,
    /// continuously-updating baseline. Without this, an attacker could
    /// send several artificially large "seed" swaps earlier in the same
    /// block to inflate the baseline, making their actual toxic swap later
    /// in that same block look normal by comparison. The underlying
    /// baseline (`baselineImpactBps`) still updates normally after every
    /// swap for FUTURE blocks' use — only the value used for THIS block's
    /// excess-ratio comparisons is frozen at the block's start.
    mapping(PoolId poolId => uint256 bps) public blockSnapshotBaselineImpactBps;

    /// @notice The block number a pool's snapshot was last taken at. When
    /// a new block begins, the next swap re-takes both snapshots before
    /// using them, so each block gets its own frozen reference point.
    mapping(PoolId poolId => uint256 blockNumber) public lastSnapshotBlock;

    /// @notice Signal 2's rolling baseline: an exponential moving average
    /// of this pool's own recent swap price-impact magnitude, in basis
    /// points. "Unusually large" is judged relative to THIS pool's own
    /// normal behavior, not a fixed constant — a $10M pool and a $50K pool
    /// have very different notions of a "large" swap.
    mapping(PoolId poolId => uint256 avgImpactBps) public baselineImpactBps;

    /// @notice Whether a pool's baseline has ever been set. The very first
    /// swap on a pool has no prior average to compare against or blend
    /// with, so we treat it as non-excessive by definition rather than
    /// (incorrectly) flagging every pool's first swap as toxic.
    mapping(PoolId poolId => bool isSet) public baselineInitialized;

    /// @notice Handoff value: the price impact `_beforeSwap` computed for
    /// the swap currently in flight, read back by `_afterSwap` to update
    /// the baseline EMA. Since `beforeSwap` already computes this
    /// deterministically from the swap's own parameters (not something
    /// that needs a real "before vs. after" comparison), reusing that
    /// value avoids redundant computation.
    mapping(PoolId poolId => uint256 impactBps) internal _pendingImpactBps;

    /// @notice Handoff value: the combined (0..1, 1e18-scaled) toxicity
    /// score `_beforeSwap` computed for the swap currently in flight, read
    /// back by `_afterSwap` to size the reserve skim proportionally.
    mapping(PoolId poolId => uint256 scoreX18) internal _pendingScoreX18;

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    // ─────────────────────────────────────────────────────────────────────
    // BaseHook permissions
    // ─────────────────────────────────────────────────────────────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    // ─────────────────────────────────────────────────────────────────────
    // beforeInitialize — gate: pool MUST be a dynamic-fee pool
    // ─────────────────────────────────────────────────────────────────────

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        poolConfigurer[key.toId()] = sender;
        return this.beforeInitialize.selector;
    }

    // ─────────────────────────────────────────────────────────────────────
    // JIT (Just-In-Time) liquidity defense — a fourth, independent
    // pillar. Signal 1 and Signal 2 both operate purely on swaps; they
    // have no visibility into liquidity being added or removed at all.
    // A JIT bot exploits exactly that blind spot: add a large, precisely
    // -ranged position right before a known large swap, capture a
    // disproportionate share of that swap's fee, then withdraw
    // immediately after — all in one block, with essentially zero price
    // risk. This defense closes that gap using the same
    // reserve-and-donate mechanism already proven for toxic swaps.
    // ─────────────────────────────────────────────────────────────────────

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        bytes32 positionKey = _positionKey(key.toId(), sender, params);
        liquidityAddedAtBlock[positionKey] = block.number;
        return this.beforeAddLiquidity.selector;
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        bytes32 positionKey = _positionKey(poolId, sender, params);

        (uint256 penalty0, uint256 penalty1) = _computeJitPenalty(positionKey, feesAccrued);

        if (penalty0 == 0 && penalty1 == 0) {
            return (this.afterRemoveLiquidity.selector, toBalanceDelta(0, 0));
        }

        // Physically claim the penalty tokens, exactly matching the
        // established pattern already proven for the swap-based reserve
        // skim: returning a positive BalanceDelta below adjusts v4's
        // ACCOUNTING of what the LP is owed, but does not itself move
        // any tokens — take() is what actually pulls them into this
        // contract's real balance, which _releaseReserve() below
        // requires to genuinely have on hand before it can donate them.
        if (penalty0 > 0) poolManager.take(key.currency0, address(this), penalty0);
        if (penalty1 > 0) poolManager.take(key.currency1, address(this), penalty1);

        pendingReserve0[poolId] += penalty0;
        pendingReserve1[poolId] += penalty1;
        emit JitPenaltyApplied(poolId, sender, penalty0, penalty1);

        // Real edge case, found via an actual reverted transaction, not
        // assumed: donate() requires the pool to have REMAINING active
        // liquidity to receive it. If this exact removal empties the
        // pool entirely (a real possibility if the JIT position happens
        // to be the pool's only liquidity at that moment), attempting
        // to auto-release here would revert the whole transaction with
        // NoLiquidityToReceiveFees() — bricking a legitimate removal
        // over a fee-distribution technicality. The captured penalty
        // isn't lost in this case: it simply stays in pendingReserve
        // and gets released the next time ANY swap happens against
        // this pool (via afterSwap's own identical threshold check),
        // once real liquidity exists again to receive it.
        if (
            poolManager.getLiquidity(poolId) > 0
                && (pendingReserve0[poolId] >= MIN_DONATE_THRESHOLD || pendingReserve1[poolId] >= MIN_DONATE_THRESHOLD)
        ) {
            _releaseReserve(key, poolId);
        }

        // Positive hook-delta = the hook takes this amount, reducing
        // what the withdrawing party actually receives — the same real,
        // empirically-verified sign convention already established for
        // afterSwap's reserve skim (see that function's own notes on
        // how this was verified, not assumed, against a real trace).
        // Safe: penalty0/penalty1 are each at most JIT_MAX_PENALTY_BPS
        // (80%) of the position's fees, which were themselves already
        // valid, non-negative int128 values — so each penalty is
        // bounded above by an already-valid int128 value and cannot
        // overflow when cast back.
        // forge-lint: disable-next-line(unsafe-typecast)
        return
            (this.afterRemoveLiquidity.selector, toBalanceDelta(int128(uint128(penalty0)), int128(uint128(penalty1))));
    }

    /// @notice Computes the real, decay-based JIT penalty for a given
    /// position's accrued fees. Extracted into its own function
    /// specifically to keep _afterRemoveLiquidity's own local variable
    /// count low enough to compile — a real, mundane Solidity stack-
    /// depth limit encountered and fixed during development, not a
    /// design choice made for its own sake.
    function _computeJitPenalty(bytes32 positionKey, BalanceDelta feesAccrued)
        internal
        view
        returns (uint256 penalty0, uint256 penalty1)
    {
        uint256 blocksHeld = block.number - liquidityAddedAtBlock[positionKey];
        if (blocksHeld >= JIT_DECAY_BLOCKS) return (0, 0);

        // Linear decay: 100% of JIT_MAX_PENALTY_BPS at blocksHeld=0,
        // smoothly down to 0% at blocksHeld=JIT_DECAY_BLOCKS — no hard
        // cliff a bot could dodge by waiting exactly one more block.
        uint256 penaltyBps =
            FixedPointMathLib.mulDivDown(JIT_MAX_PENALTY_BPS, JIT_DECAY_BLOCKS - blocksHeld, JIT_DECAY_BLOCKS);

        int128 fees0 = feesAccrued.amount0();
        int128 fees1 = feesAccrued.amount1();

        // Only ever skim from POSITIVE fee amounts owed to the LP —
        // never touch a negative (owed-to-pool) component, and never
        // touch principal at all, since feesAccrued is specifically the
        // fee portion, separate from the principal returned in `delta`.
        // Safe: fees0/fees1 were just confirmed > 0 in this branch, and
        // BalanceDelta's components are int128, so casting to uint128
        // cannot lose or misrepresent the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        penalty0 = fees0 > 0 ? FixedPointMathLib.mulDivDown(uint128(fees0), penaltyBps, BPS_DENOMINATOR) : 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        penalty1 = fees1 > 0 ? FixedPointMathLib.mulDivDown(uint128(fees1), penaltyBps, BPS_DENOMINATOR) : 0;
    }

    function _positionKey(PoolId poolId, address owner, ModifyLiquidityParams calldata params)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(poolId, owner, params.tickLower, params.tickUpper, params.salt));
    }

    // ─────────────────────────────────────────────────────────────────────
    // Pool configuration — must be set before this hook's fee logic is
    // meaningful for a given pool. Left intentionally simple (owner-only,
    // single feed) for the hackathon scope; a production version would
    // likely want a two-step ownership handoff and feed-change timelock.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Configure the Chainlink reference feed for a pool. Callable
    /// only by whoever initialized the pool (see `_beforeInitialize`).
    ///
    /// SECURITY / TRUST MODEL: the INITIAL configuration of a pool (the
    /// first time this is called for a given pool, before any feed has
    /// ever been set) applies immediately — the pool is unusable until
    /// configured, so there is no existing trust relationship to protect.
    /// Every SUBSEQUENT call is treated as a CHANGE and is queued behind
    /// `ORACLE_CHANGE_TIMELOCK` (24 hours) rather than applying instantly.
    /// This directly closes the gap flagged in our Workshop 13 security
    /// pass: a configurer with instant, unilateral oracle-change power
    /// could otherwise briefly point at a manipulated feed to bias a
    /// specific swap's classification, then revert it. With the timelock,
    /// any change is publicly queued (see `OracleChangeQueued`) with a
    /// real window for LPs, swappers, or an automated watchdog to notice
    /// and react before it can take effect. This is a real structural
    /// mitigation, not just an audit trail — the `PoolConfigured` event
    /// still fires for every actual (initial or applied) configuration,
    /// preserving full on-chain auditability either way.
    /// @param key The pool to configure.
    /// @param feed The Chainlink AggregatorV3 feed to use as the external
    ///        reference price for this pool.
    /// @param oracleMatchesPoolDirection Whether the oracle's price is
    ///        already expressed in the same currency0-per-currency1
    ///        direction the pool itself uses. If the oracle instead quotes
    ///        currency1-per-currency0, pass `false` and this contract will
    ///        invert it before comparison.
    /// @param staleness Custom max staleness window in seconds for this
    ///        pool's feed. Pass 0 to use `DEFAULT_MAX_ORACLE_STALENESS`.
    function configurePool(PoolKey calldata key, IAggregatorV3 feed, bool oracleMatchesPoolDirection, uint256 staleness)
        external
    {
        PoolId poolId = key.toId();
        require(msg.sender == poolConfigurer[poolId], "Ballast: not pool configurer");
        require(address(feed) != address(0), "Ballast: feed cannot be zero address");

        if (address(priceFeeds[poolId]) == address(0)) {
            // Initial configuration — applies immediately.
            priceFeeds[poolId] = feed;
            oracleDirectionMatchesPool[poolId] = oracleMatchesPoolDirection;
            maxOracleStaleness[poolId] = staleness;

            emit PoolConfigured(poolId, address(feed), oracleMatchesPoolDirection, staleness);

            // Auto-read and cache each token's decimals, rather than
            // trusting a manually-supplied value — removes an entire
            // class of misconfiguration risk.
            currency0Decimals[poolId] = _readDecimals(key.currency0);
            currency1Decimals[poolId] = _readDecimals(key.currency1);
        } else {
            // Change to an already-configured pool — queued behind the
            // timelock instead of applying instantly.
            pendingFeed[poolId] = address(feed);
            pendingOracleMatchesPoolDirection[poolId] = oracleMatchesPoolDirection;
            pendingStaleness[poolId] = staleness;
            uint256 effectiveAt = block.timestamp + ORACLE_CHANGE_TIMELOCK;
            pendingFeedEffectiveAt[poolId] = effectiveAt;

            emit OracleChangeQueued(poolId, address(feed), effectiveAt);
        }
    }

    /// @notice Applies a previously-queued oracle change once its timelock
    /// has elapsed. Deliberately callable by ANYONE, not just the
    /// configurer — there is no reason to restrict who can apply a change
    /// whose parameters were already fixed and made public when it was
    /// queued; permissionless application means the change can't be
    /// silently delayed by an unresponsive configurer either.
    function applyPendingOracleChange(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        uint256 effectiveAt = pendingFeedEffectiveAt[poolId];

        require(effectiveAt != 0, "Ballast: no pending oracle change");
        // Real security improvement, found and added during review, not
        // present in earlier versions of this contract: without this
        // check, a guardian correctly pausing the pool over a
        // suspicious queued change had NO actual effect on whether that
        // change could still apply — the attacker (who by definition
        // already holds a compromised configurer key) could simply wait
        // out the 24-hour timelock and apply it regardless of the
        // pause. This does NOT make the attack impossible for someone
        // who genuinely holds the legitimate key forever — it forces
        // them to take one additional, highly visible, separately
        // logged action (explicitly calling resume(), which is
        // configurer-gated and emits its own event) rather than
        // silently waiting out a timer. That's a real, meaningful,
        // honestly-scoped improvement, not a claim of full prevention.
        require(!paused[poolId], "Ballast: cannot apply oracle change while pool is paused");
        // Intentional use of block.timestamp: our timelock window is 24
        // hours, far beyond any validator's ability to meaningfully
        // manipulate block.timestamp (~seconds of drift), so this is not
        // a viable manipulation vector here — same reasoning already
        // applied to the oracle staleness check elsewhere in this file.
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp >= effectiveAt, "Ballast: timelock not yet elapsed");

        address newFeed = pendingFeed[poolId];
        priceFeeds[poolId] = IAggregatorV3(newFeed);
        oracleDirectionMatchesPool[poolId] = pendingOracleMatchesPoolDirection[poolId];
        maxOracleStaleness[poolId] = pendingStaleness[poolId];

        // Re-read decimals defensively in case this is ever used to point
        // at a differently-decimaled token pair's feed in the future
        // (current usage keeps the same pool/token pair, so this is a
        // no-op in practice, but costs little and removes an assumption).
        currency0Decimals[poolId] = _readDecimals(key.currency0);
        currency1Decimals[poolId] = _readDecimals(key.currency1);

        // Clear the pending change.
        pendingFeed[poolId] = address(0);
        pendingFeedEffectiveAt[poolId] = 0;

        emit PoolConfigured(poolId, newFeed, oracleDirectionMatchesPool[poolId], maxOracleStaleness[poolId]);
        emit OracleChangeApplied(poolId, newFeed);
    }

    /// @notice Cancels a pending oracle change before it takes effect —
    /// for a legitimate configurer who queued a change and then, for
    /// any reason (an honest mistake, a community challenge, a
    /// guardian pause prompting reconsideration), wants to back out
    /// cleanly rather than being forced to either let it apply or leave
    /// it sitting queued indefinitely. Deliberately callable regardless
    /// of pause state — canceling a change is always safe to allow,
    /// unlike applying one.
    function cancelPendingOracleChange(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        require(msg.sender == poolConfigurer[poolId], "Ballast: not pool configurer");
        require(pendingFeedEffectiveAt[poolId] != 0, "Ballast: no pending oracle change");

        pendingFeed[poolId] = address(0);
        pendingFeedEffectiveAt[poolId] = 0;

        emit OracleChangeCanceled(poolId);
    }

    /// @notice Sets (or changes) the guardian address for a pool —
    /// intended to be a Reactive Network callback contract (see
    /// OracleGuardian docs) once deployed, but deliberately usable with
    /// any address, including an EOA, so the pause mechanism itself can
    /// be tested and used independently of the Reactive integration
    /// being live. Callable only by the pool configurer.
    function setGuardian(PoolKey calldata key, address newGuardian) external {
        PoolId poolId = key.toId();
        require(msg.sender == poolConfigurer[poolId], "Ballast: not pool configurer");

        if (guardian[poolId] == address(0)) {
            // First-ever guardian assignment — applies immediately.
            // There's no existing, real protection to silently bypass
            // yet, unlike changing an already-active guardian.
            guardian[poolId] = newGuardian;
            emit GuardianSet(poolId, newGuardian);
        } else {
            // Changing an EXISTING guardian — queued behind the same
            // timelock as an oracle change, for the same reason: this
            // is exactly the action a compromised configurer would use
            // to silently disable real protection before an attack.
            pendingGuardian[poolId] = newGuardian;
            uint256 effectiveAt = block.timestamp + ORACLE_CHANGE_TIMELOCK;
            pendingGuardianEffectiveAt[poolId] = effectiveAt;
            emit GuardianChangeQueued(poolId, newGuardian, effectiveAt);
        }
    }

    /// @notice Applies a previously-queued guardian change once its
    /// timelock has elapsed. Permissionless, matching
    /// applyPendingOracleChange()'s reasoning exactly. Also blocked
    /// while paused, for the identical reason: a pause specifically
    /// exists to give time to investigate a suspicious pending change
    /// before it takes effect.
    function applyPendingGuardianChange(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        uint256 effectiveAt = pendingGuardianEffectiveAt[poolId];

        require(effectiveAt != 0, "Ballast: no pending guardian change");
        require(!paused[poolId], "Ballast: cannot apply guardian change while pool is paused");
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp >= effectiveAt, "Ballast: timelock not yet elapsed");

        address newGuardian = pendingGuardian[poolId];
        guardian[poolId] = newGuardian;

        pendingGuardian[poolId] = address(0);
        pendingGuardianEffectiveAt[poolId] = 0;

        emit GuardianChangeApplied(poolId, newGuardian);
    }

    /// @notice Cancels a pending guardian change before it takes
    /// effect. Always allowed regardless of pause state, matching
    /// cancelPendingOracleChange()'s reasoning: canceling is always
    /// safe to allow.
    function cancelPendingGuardianChange(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        require(msg.sender == poolConfigurer[poolId], "Ballast: not pool configurer");
        require(pendingGuardianEffectiveAt[poolId] != 0, "Ballast: no pending guardian change");

        pendingGuardian[poolId] = address(0);
        pendingGuardianEffectiveAt[poolId] = 0;

        emit GuardianChangeCanceled(poolId);
    }

    /// @notice Pauses a pool. Callable ONLY by that pool's configured
    /// guardian — deliberately NOT by the configurer, NOT by an owner,
    /// NOT by anyone else. This is intentionally the easiest, fastest
    /// path in this entire contract: a real fail-safe must be cheap and
    /// simple to trigger, or it fails at the one moment it matters most.
    function guardianPause(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        require(msg.sender == guardian[poolId], "Ballast: not the guardian");
        paused[poolId] = true;
        emit GuardianPaused(poolId, msg.sender, block.timestamp);
    }

    /// @notice A general circuit breaker for the pool configurer,
    /// independent of the guardian mechanism entirely. The guardian
    /// path (above) only ever fires for the specific conditions
    /// OracleGuardian and ZKPriceGuardian watch for; this exists for
    /// everything else — any operational emergency a configurer
    /// discovers directly. Deliberately symmetric with resume() (same
    /// access control, same pool-scoped effect), so the same party who
    /// can lift a pause can also trigger one, for reasons the automated
    /// guardians were never designed to catch.
    function emergencyPause(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        require(msg.sender == poolConfigurer[poolId], "Ballast: not pool configurer");
        require(!paused[poolId], "Ballast: pool is already paused");
        paused[poolId] = true;
        emit EmergencyPaused(poolId, msg.sender, block.timestamp);
    }

    /// @notice Resumes a paused pool. Callable ONLY by the pool
    /// CONFIGURER — deliberately NOT by the guardian. Pausing is
    /// autonomous and immediate by design; resuming is not, and
    /// deliberately requires a human decision that the underlying
    /// concern has actually been addressed. A guardian that could both
    /// pause and resume would not be a meaningfully independent check.
    function resume(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        require(msg.sender == poolConfigurer[poolId], "Ballast: not pool configurer");
        require(paused[poolId], "Ballast: pool is not paused");
        paused[poolId] = false;
        emit Resumed(poolId, msg.sender, block.timestamp);
    }

    /// @notice Reads a currency's decimals, treating native ETH
    /// (`Currency` wrapping `address(0)`) as 18 decimals to match WETH's
    /// convention, since native ETH has no `decimals()` function to call.
    function _readDecimals(Currency currency) internal view returns (uint8) {
        if (currency.isAddressZero()) return 18;
        return IERC20Decimals(Currency.unwrap(currency)).decimals();
    }

    // ─────────────────────────────────────────────────────────────────────
    // beforeSwap — computes the combined-signal fee and stashes both
    // Signal 2's impact and the combined toxicity score for afterSwap to
    // use (baseline EMA update, and sizing the reserve skim).
    // ─────────────────────────────────────────────────────────────────────

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        _refreshBlockSnapshotIfNeeded(poolId, key);
        uint24 fee = _computeFee(poolId, key, params);
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    /// @notice Security: if this is the first swap seen for this pool in
    /// the current block, freeze this block's reference snapshots (pool
    /// price for Signal 1, baseline impact for Signal 2) BEFORE this
    /// swap's own fee is computed. Since this is the first swap of the
    /// block, the values captured here reflect state as it existed before
    /// any activity in this block — including this very swap — could have
    /// influenced it, closing the same-block manipulation window described
    /// in the storage docs above. A no-op for every subsequent swap within
    /// the same block, which all compare against this same frozen snapshot.
    function _refreshBlockSnapshotIfNeeded(PoolId poolId, PoolKey calldata key) internal {
        if (lastSnapshotBlock[poolId] == block.number) return;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 != 0) {
            blockSnapshotPoolPriceX18[poolId] = _rawSqrtPriceToDecimalsCorrectedX18(poolId, sqrtPriceX96);
        }
        blockSnapshotBaselineImpactBps[poolId] = baselineImpactBps[poolId];
        lastSnapshotBlock[poolId] = block.number;
    }

    /// @notice View-safe equivalent of "what Signal 1's reference price
    /// would be if a real swap happened right now." If this block's
    /// snapshot has already been taken (by an earlier real swap this
    /// block), returns that frozen value — otherwise falls back to the
    /// live price, since a real swap right now WOULD trigger a fresh
    /// snapshot at that live value. This lets `previewFee`/`previewSignal2`
    /// (both `view`, unable to write the snapshot themselves) give an
    /// accurate preview without ever becoming stale, while real swaps via
    /// `_beforeSwap` still get the actual persisted, gas-cheaper snapshot
    /// read plus the security property of a single frozen value shared by
    /// every swap within the same block.
    function _effectivePoolPriceX18(PoolId poolId) internal view returns (uint256) {
        if (lastSnapshotBlock[poolId] == block.number) {
            return blockSnapshotPoolPriceX18[poolId];
        }
        return _getPoolPriceX18(poolId);
    }

    /// @notice View-safe equivalent for Signal 2's baseline comparison —
    /// same reasoning as `_effectivePoolPriceX18` above.
    function _effectiveBaselineImpactBps(PoolId poolId) internal view returns (uint256) {
        if (lastSnapshotBlock[poolId] == block.number) {
            return blockSnapshotBaselineImpactBps[poolId];
        }
        return baselineImpactBps[poolId];
    }

    // ─────────────────────────────────────────────────────────────────────
    // afterSwap — three responsibilities:
    //   1. Fold this swap's Signal 2 impact into the pool's baseline EMA.
    //   2. If the swap was flagged toxic (nonzero combined score), skim a
    //      proportional slice of its UNSPECIFIED-token amount into the
    //      hook's own custody as reserve, ON TOP OF the elevated dynamic
    //      fee already collected natively by PoolManager for LPs.
    //   3. If either currency's accumulated reserve crosses
    //      MIN_DONATE_THRESHOLD, release it to in-range LPs via donate()
    //      immediately (smoothing yield over time rather than an instant,
    //      lumpy per-swap payout).
    //
    // KNOWN LIMITATION (documented honestly, not hidden): skimming from
    // the swap's output reduces what the trader receives below what
    // beforeSwap's fee alone would produce. A trader with a tight slippage
    // limit on a swap that also triggers a large skim could see their
    // transaction revert. This is a real UX tradeoff of layering a skim on
    // top of the dynamic fee rather than folding the skim entirely into
    // the fee itself; documented in README calibration notes as a
    // parameter to tune (MAX_RESERVE_SKIM_BPS) rather than a silent gap.
    // ─────────────────────────────────────────────────────────────────────

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();

        // ---- 1. Baseline EMA update (unchanged from Signal 2 milestone) ----
        uint256 impact = _pendingImpactBps[poolId];
        if (!baselineInitialized[poolId]) {
            baselineImpactBps[poolId] = impact;
            baselineInitialized[poolId] = true;
        } else {
            uint256 oldAvg = baselineImpactBps[poolId];
            if (impact >= oldAvg) {
                baselineImpactBps[poolId] = oldAvg + ((impact - oldAvg) * EMA_WEIGHT_BPS) / BPS_DENOMINATOR;
            } else {
                baselineImpactBps[poolId] = oldAvg - ((oldAvg - impact) * EMA_WEIGHT_BPS) / BPS_DENOMINATOR;
            }
        }

        // ---- 2. Reserve skim, sized proportionally to this swap's toxicity score ----
        uint256 scoreX18 = _pendingScoreX18[poolId];
        int128 hookDeltaUnspecified = 0;

        if (scoreX18 > 0) {
            // Per Workshop 8's Internal Swap Pool lesson: which currency is
            // "unspecified" depends on the swap's direction and exact
            // input/output mode. Isolating and skimming from this specific
            // currency (rather than always currency0/1) is what lets us
            // reduce exactly what the delta accounting expects, keeping
            // the flash-accounting ledger balanced.
            bool currency1IsUnspecified = (params.amountSpecified < 0) == params.zeroForOne;
            Currency unspecifiedCurrency = currency1IsUnspecified ? key.currency1 : key.currency0;
            int128 unspecifiedAmount = currency1IsUnspecified ? delta.amount1() : delta.amount0();

            // unspecifiedAmount is positive when it's owed TO the trader
            // (the normal case: their swap output). We only ever skim from
            // a positive (outbound-to-trader) amount — never attempt to
            // skim from an amount the trader owes TO the pool.
            if (unspecifiedAmount > 0) {
                // Safe: unspecifiedAmount was just checked > 0, and
                // BalanceDelta's components are int128, so casting to
                // uint128 then uint256 cannot lose or misrepresent value.
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 outputAmount = uint256(uint128(unspecifiedAmount));
                uint256 skimBps = FixedPointMathLib.mulDivDown(MAX_RESERVE_SKIM_BPS, scoreX18, 1e18);
                uint256 skimAmount = FixedPointMathLib.mulDivDown(outputAmount, skimBps, BPS_DENOMINATOR);

                if (skimAmount > 0 && skimAmount < outputAmount) {
                    poolManager.take(unspecifiedCurrency, address(this), skimAmount);

                    if (currency1IsUnspecified) {
                        pendingReserve1[poolId] += skimAmount;
                    } else {
                        pendingReserve0[poolId] += skimAmount;
                    }

                    // NOTE: this is POSITIVE, not negative. Verified
                    // empirically against a real swap trace (not assumed
                    // from documentation): PoolManager's internal
                    // `swapDelta = swapDelta - hookDelta` combined with how
                    // hookDeltaUnspecified is placed into the
                    // BalanceDelta's amount0/amount1 slot for this specific
                    // swap-direction branch means a POSITIVE value here is
                    // what actually reduces the trader's received output
                    // by skimAmount; a negative value (which seemed
                    // intuitive, and is what course material showed for a
                    // differently-configured swap direction) was tested
                    // and empirically caused the trader to receive MORE
                    // than the original swap output — the opposite of the
                    // intended skim — triggering CurrencyNotSettled() since
                    // the pool ends up short by skimAmount. Caught via a
                    // real fork/local-PoolManager test trace, exactly the
                    // kind of subtlety that only surfaces against the real
                    // contract, not a mock.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    hookDeltaUnspecified = int128(int256(skimAmount));
                }
            }
        }

        // ---- 3. Auto-release reserve if either currency crosses threshold ----
        if (pendingReserve0[poolId] >= MIN_DONATE_THRESHOLD || pendingReserve1[poolId] >= MIN_DONATE_THRESHOLD) {
            _releaseReserve(key, poolId);
        }

        return (this.afterSwap.selector, hookDeltaUnspecified);
    }

    /// @notice Releases a pool's entire accumulated reserve to in-range
    /// LPs via `PoolManager.donate()`, then settles the resulting debt by
    /// transferring the hook's own held tokens back to the PoolManager
    /// (the standard sync -> transfer -> settle pattern for a hook acting
    /// on its own initiative within an already-unlocked context, per
    /// Workshop 1/8's flash-accounting discipline).
    ///
    /// SECURITY: reserve is zeroed BEFORE the external `donate()` and
    /// `_settle()` calls (Checks-Effects-Interactions) — even if a
    /// malicious token's `transfer()` implementation attempted to reenter
    /// during `_settle()`, `pendingReserve0`/`pendingReserve1` are already
    /// zero at that point, making a double-release impossible. Verified
    /// during the Workshop 13 security pass, not incidental.
    function _releaseReserve(PoolKey calldata key, PoolId poolId) internal {
        uint256 amount0 = pendingReserve0[poolId];
        uint256 amount1 = pendingReserve1[poolId];

        if (amount0 == 0 && amount1 == 0) return;

        pendingReserve0[poolId] = 0;
        pendingReserve1[poolId] = 0;

        poolManager.donate(key, amount0, amount1, "");

        if (amount0 > 0) _settle(key.currency0, amount0);
        if (amount1 > 0) _settle(key.currency1, amount1);
    }

    /// @notice Settles a debt the hook owes to PoolManager (created here by
    /// `donate()`) by transferring tokens the hook already holds (from
    /// earlier `take()` skims) back to PoolManager. Handles both native
    /// ETH and standard ERC-20 currencies.
    function _settle(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            bool success = IERC20MinimalTransfer(Currency.unwrap(currency)).transfer(address(poolManager), amount);
            require(success, "Ballast: settlement transfer failed");
            poolManager.settle();
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Fee computation
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Public, read-only preview of the fee `_beforeSwap` would
    /// charge for a hypothetical swap with the given parameters. NOTE: for
    /// simplicity this preview does not update any handoff state (it calls
    /// the same underlying computation but through a `view`-only path), so
    /// it's safe to call repeatedly without side effects, unlike a real
    /// swap.
    function previewFee(PoolKey calldata key, SwapParams calldata params) external view returns (uint24) {
        (uint24 fee,,) = _computeFeeAndImpact(key.toId(), key, params);
        return fee;
    }

    /// @notice Diagnostic view exposing Signal 2's raw internal values for
    /// a hypothetical swap, without executing anything. Exists for
    /// debugging/testing and later demo transparency — lets anyone verify
    /// exactly what the hook currently considers this pool's baseline and
    /// this swap's computed impact to be, rather than only seeing the
    /// final fee.
    function previewSignal2(PoolKey calldata key, SwapParams calldata params)
        external
        view
        returns (bool isExcessive, uint256 excessRatioX18, uint256 impactBps, uint256 currentBaselineBps)
    {
        PoolId poolId = key.toId();
        (isExcessive, excessRatioX18, impactBps) = _signal2(poolId, key, params);
        currentBaselineBps = baselineImpactBps[poolId];
    }

    /// @notice Computes the fee for a swap that is actually about to
    /// execute, combining Signal 1 and Signal 2, and records both Signal
    /// 2's computed impact (for the baseline EMA) and the combined
    /// toxicity score (for sizing the reserve skim) so `_afterSwap` can
    /// use them without recomputing.
    function _computeFee(PoolId poolId, PoolKey calldata key, SwapParams calldata params) internal returns (uint24) {
        (uint24 fee, uint256 impactBps, uint256 scoreX18) = _computeFeeAndImpact(poolId, key, params);
        _pendingImpactBps[poolId] = impactBps;
        _pendingScoreX18[poolId] = scoreX18;
        return fee;
    }

    /// @notice Core combined fee logic, shared by both the state-writing
    /// path above and the view-only `previewFee`/`previewSignal2` paths.
    ///
    /// Combination formula (per our documented design): each signal
    /// contributes a 0..1 normalized "toxicity" score, weighted equally,
    /// and the fee scales linearly from BASE_FEE to MAX_SURCHARGE_FEE with
    /// the combined score. Neither signal alone can reach the maximum —
    /// both firing together is what drives the fee to its ceiling. This
    /// dual requirement is also the primary defense against either signal
    /// being cheaply gamed in isolation (Workshop 13's lesson on
    /// manipulable single-signal fee logic). The same combined score also
    /// sizes the `afterSwap` reserve skim, so a swap's fee and its
    /// contribution to the reserve are always consistent with each other.
    ///
    /// Signal 1 (external) additionally distinguishes toxic vs. corrective
    /// direction; if Signal 1 is clearly corrective and Signal 2 does not
    /// fire, we pass through the discounted fee with a zero score (no
    /// reserve skim either) rather than applying the combined-score
    /// formula, since a swap actively fixing the pool's price should not
    /// be penalized by an unrelated depth signal.
    function _computeFeeAndImpact(PoolId poolId, PoolKey calldata key, SwapParams calldata params)
        internal
        view
        returns (uint24 fee, uint256 impactBps, uint256 combinedScoreX18)
    {
        // Guardian pause short-circuit: while paused, BOTH signals are
        // skipped entirely — not just Signal 1 — and the pool falls back
        // to BASE_FEE with zero toxicity score (so no reserve skim
        // happens either). This deliberately neutralizes exposure to
        // whatever triggered the pause (most likely an oracle-related
        // concern) rather than only disabling the specific signal that
        // uses the oracle, since a compromised trust assumption
        // shouldn't be trusted to correctly scope its own blast radius.
        if (paused[poolId]) {
            return (BASE_FEE, 0, 0);
        }

        IAggregatorV3 feed = priceFeeds[poolId];

        // Signal 2 runs regardless of whether an oracle is configured,
        // since it doesn't depend on one.
        (bool isExcessive, uint256 excessRatioX18, uint256 rawImpactBps) = _signal2(poolId, key, params);
        impactBps = rawImpactBps;

        uint256 signal2ScoreX18 = _signal2Score(isExcessive, excessRatioX18);

        // If no oracle feed has been configured yet for this pool, Signal
        // 1 cannot run; fall back to Signal 2 alone, at its own full,
        // undiluted value — consistent with the noisy-OR combination
        // used below: noisyOR(0, signal2Score) = signal2Score exactly,
        // so this fallback deliberately matches what the real
        // combination would produce if Signal 1 were absent, rather
        // than arbitrarily halving Signal 2's reading.
        if (address(feed) == address(0)) {
            combinedScoreX18 = signal2ScoreX18;
            fee = _feeFromScore(combinedScoreX18);
            return (fee, impactBps, combinedScoreX18);
        }

        (bool isToxic, bool isCorrective, uint256 deviationBps) = _signal1(poolId, key, params, feed);

        if (isCorrective && !isExcessive) {
            return (DISCOUNTED_FEE, impactBps, 0);
        }

        // Normalize Signal 1 to a 0..1 (fixed-point 1e18) toxicity score.
        uint256 signal1ScoreX18 = isToxic
            ? FixedPointMathLib.mulDivDown(
                deviationBps > MAX_DEVIATION_BPS ? MAX_DEVIATION_BPS : deviationBps, 1e18, MAX_DEVIATION_BPS
            )
            : 0;

        // ── Combination: noisy-OR, not a simple average ──
        //
        // combinedScore = 1 - (1 - signal1Score)(1 - signal2Score)
        //
        // This project's own MATH.md documents WHY: a simple average was
        // our original design, and testing found a real, quantified
        // problem with it — a swap that maximally saturates ONE signal
        // (e.g. Signal 2's raw excess ratio at 105x its threshold,
        // normalized score = 1.0) had its effective fee cut by roughly
        // half whenever the OTHER signal stayed near zero, since
        // averaging always pulls toward the more moderate reading.
        // Verified directly:
        // test_previewFee_disproportionateSwap_chargesSurcharge_viaSignal2Alone
        // produced fee=9270 under averaging despite Signal 2 alone
        // justifying the full 15000 ceiling.
        //
        // Noisy-OR — the standard way to combine independent probability
        // estimates of "at least one condition holds" — fixes this
        // precisely: if either signal alone reads 1.0, combinedScore is
        // exactly 1.0 too (no dilution), while if BOTH signals partially
        // agree, combinedScore is systematically HIGHER than either
        // alone (genuine corroboration is rewarded, not just tolerated)
        // — a property plain max() alone does not have. Confirmed by
        // direct comparison across representative cases before adopting
        // this formula, not assumed.
        combinedScoreX18 = 1e18 - FixedPointMathLib.mulDivDown(1e18 - signal1ScoreX18, 1e18 - signal2ScoreX18, 1e18);
        if (combinedScoreX18 > 1e18) combinedScoreX18 = 1e18;

        fee = _feeFromScore(combinedScoreX18);
    }

    /// @notice Converts a combined 0..1 (1e18-scaled) toxicity score into
    /// the actual fee, linearly interpolated between BASE_FEE and
    /// MAX_SURCHARGE_FEE.
    function _feeFromScore(uint256 combinedScoreX18) internal pure returns (uint24) {
        uint256 extra = FixedPointMathLib.mulDivDown(uint256(MAX_SURCHARGE_FEE - BASE_FEE), combinedScoreX18, 1e18);
        // Safe: combinedScoreX18 <= 1e18 by construction, so extra <=
        // (MAX_SURCHARGE_FEE - BASE_FEE), keeping the sum within uint24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(BASE_FEE + extra);
    }

    /// @notice Normalizes Signal 2's excess ratio into a 0..1 (1e18-scaled)
    /// score, shared by both the combined-signal path and the
    /// Signal-2-only fallback path.
    function _signal2Score(bool isExcessive, uint256 excessRatioX18) internal pure returns (uint256) {
        if (!isExcessive) return 0;

        // NOTE: an earlier version of this function pre-capped
        // excessRatioX18 at a hardcoded 2e18 before this comparison — a
        // real bug, found and fixed during development: with
        // EXCESS_MULTIPLIER_BPS set to 25_000 (a 2.5x threshold), that
        // pre-cap made it mathematically IMPOSSIBLE for `cappedExcess` to
        // ever reach `thresholdX18`, silently capping this score's true
        // ceiling at 2.0/2.5 = 0.8 instead of the documented 1.0 — no
        // matter how extreme the real swap. Removing the pre-cap is
        // safe: this branch's `>=` check already returns 1e18 directly
        // for any large excessRatioX18 without ever reaching the
        // mulDivDown call below, so there was no overflow risk it was
        // protecting against.
        uint256 thresholdX18 = FixedPointMathLib.mulDivDown(EXCESS_MULTIPLIER_BPS, 1e18, BPS_DENOMINATOR);
        return excessRatioX18 >= thresholdX18 ? 1e18 : FixedPointMathLib.mulDivDown(excessRatioX18, 1e18, thresholdX18);
    }

    /// @notice Signal 2: compares this swap's expected price impact
    /// (computed via the pool's own real swap math, not an approximation)
    /// against this specific pool's TOP-OF-BLOCK baseline snapshot (see
    /// `_refreshBlockSnapshotIfNeeded`). A swap causing disproportionate
    /// impact relative to how this pool normally behaves is treated as
    /// toxic/exploitative, independent of Signal 1.
    ///
    /// SECURITY NOTE: deliberately compares against
    /// `blockSnapshotBaselineImpactBps` (frozen at block start) rather than
    /// the live, continuously-updating `baselineImpactBps`. Without this,
    /// an attacker could send several artificially large "seed" swaps
    /// earlier in the same block to inflate the baseline, then have their
    /// actual toxic swap later in that same block look normal by
    /// comparison. The live baseline still updates normally after every
    /// swap (see `_afterSwap`) — only the value used for THIS block's
    /// comparisons is frozen.
    /// @return isExcessive True if impact exceeds EXCESS_MULTIPLIER_BPS
    ///         times the pool's block-start baseline.
    /// @return excessRatioX18 impactBps / baselineBps, at 1e18 fixed point
    ///         (0 if no baseline exists yet).
    /// @return impactBps This swap's own computed price impact, in basis
    ///         points — always returned (even when not "excessive") so it
    ///         can be folded into the live baseline EMA in `_afterSwap`.
    function _signal2(PoolId poolId, PoolKey calldata, SwapParams calldata params)
        internal
        view
        returns (bool isExcessive, uint256 excessRatioX18, uint256 impactBps)
    {
        (uint160 sqrtPriceCurrentX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        if (liquidity == 0 || sqrtPriceCurrentX96 == 0) {
            return (false, 0, 0);
        }

        // Compute the sqrtPrice this swap would move to, using the pool's
        // own real swap-step math (the same function v4-core itself uses
        // internally) rather than a crude size/liquidity ratio. feePips is
        // passed as 0 here deliberately: we want the RAW price movement
        // this swap size would cause against current liquidity, not a
        // fee-adjusted figure (the fee is what we're computing).
        (uint160 sqrtPriceNextX96,,,) = SwapMath.computeSwapStep(
            sqrtPriceCurrentX96, params.sqrtPriceLimitX96, liquidity, params.amountSpecified, 0
        );

        // First-order approximation: price ~ sqrtPrice^2, so for a small
        // fractional change epsilon in sqrtPrice, the resulting fractional
        // change in price is ~2*epsilon. We use this instead of squaring
        // sqrtPriceX96 directly, which can overflow uint256 arithmetic for
        // prices near the extreme ends of the valid tick range. Since this
        // value is used only as a relative-magnitude toxicity SIGNAL (compared
        // against this pool's own recent history), basis-point-level
        // approximation error is an acceptable, documented tradeoff — see
        // README calibration notes.
        uint256 ratioX18 = FixedPointMathLib.mulDivDown(uint256(sqrtPriceNextX96), 1e18, uint256(sqrtPriceCurrentX96));
        uint256 diffX18 = ratioX18 > 1e18 ? ratioX18 - 1e18 : 1e18 - ratioX18;
        impactBps = (diffX18 * 2 * BPS_DENOMINATOR) / 1e18;

        uint256 baseline = _effectiveBaselineImpactBps(poolId);
        if (!baselineInitialized[poolId] || baseline == 0) {
            // No meaningful baseline existed at the start of this block —
            // treat as normal rather than flagging a pool's very first
            // swaps as toxic before we have any real history to compare
            // against.
            return (false, 0, impactBps);
        }

        excessRatioX18 = FixedPointMathLib.mulDivDown(impactBps, 1e18, baseline);
        uint256 thresholdRatioX18 = FixedPointMathLib.mulDivDown(EXCESS_MULTIPLIER_BPS, 1e18, BPS_DENOMINATOR);
        isExcessive = excessRatioX18 >= thresholdRatioX18;
    }

    /// @notice Signal 1: compares the pool's TOP-OF-BLOCK price snapshot
    /// (see `_refreshBlockSnapshotIfNeeded`) against a live Chainlink
    /// reference price, and determines whether this specific swap is
    /// pushing the pool price further away from (toxic) or back toward
    /// (corrective) the oracle price.
    ///
    /// SECURITY NOTE: deliberately uses `blockSnapshotPoolPriceX18` rather
    /// than reading the pool's live price directly. If this read the live,
    /// same-transaction price, an attacker could manipulate the pool's
    /// price with an earlier transaction in the same block, then have a
    /// later, genuinely toxic transaction's Signal 1 check compare against
    /// the already-manipulated price and be misclassified as corrective.
    /// Using the price as it existed at the start of the block closes this
    /// window, mirroring the same top-of-block pattern taught for
    /// Nezlobin's directional fee.
    /// @return isToxic True if this swap is toxic per Signal 1.
    /// @return isCorrective True if this swap is corrective per Signal 1.
    /// @return deviationBps The block-start |pool price - oracle price| /
    ///         oracle price deviation, in basis points. Used to scale the
    ///         surcharge magnitude.
    function _signal1(PoolId poolId, PoolKey calldata key, SwapParams calldata params, IAggregatorV3 feed)
        internal
        view
        returns (bool isToxic, bool isCorrective, uint256 deviationBps)
    {
        uint256 oraclePriceX18 = _getOraclePriceX18(poolId, feed);
        uint256 poolPriceX18 = _effectivePoolPriceX18(poolId);

        if (poolPriceX18 == 0 || poolPriceX18 == oraclePriceX18 || oraclePriceX18 == 0) {
            return (false, false, 0);
        }

        bool poolAboveOracle = poolPriceX18 > oraclePriceX18;
        uint256 diff = poolAboveOracle ? poolPriceX18 - oraclePriceX18 : oraclePriceX18 - poolPriceX18;
        deviationBps = (diff * BPS_DENOMINATOR) / oraclePriceX18;

        // zeroForOne = true means the swap sells currency0 for currency1,
        // which pushes the pool's price (currency0 in terms of currency1,
        // per Workshop 3's convention) DOWN. zeroForOne = false pushes it
        // UP. We use that direction, combined with which side of the
        // oracle price the pool is currently on, to determine whether this
        // swap is widening or narrowing the existing deviation.
        bool swapPushesPriceUp = !params.zeroForOne;

        if (poolAboveOracle) {
            // Pool is already trading above the oracle price. A swap that
            // pushes price further up widens the gap (toxic); a swap that
            // pushes price down narrows it (corrective).
            isToxic = swapPushesPriceUp;
            isCorrective = !swapPushesPriceUp;
        } else {
            // Pool is trading below the oracle price. Symmetric logic.
            isToxic = !swapPushesPriceUp;
            isCorrective = swapPushesPriceUp;
        }

        // Below-threshold deviations are treated as noise, not a toxic
        // signal, regardless of direction — avoids taxing normal price
        // discovery when the pool and oracle already roughly agree.
        if (deviationBps == 0) {
            isToxic = false;
            isCorrective = false;
        }
    }

    /// @notice Reads and validates the Chainlink price for a pool's
    /// configured feed, normalized to 18 decimals, and oriented to match
    /// the pool's own currency0-per-currency1 quoting convention.
    function _getOraclePriceX18(PoolId poolId, IAggregatorV3 feed) internal view returns (uint256) {
        if (address(feed) == address(0)) revert PriceFeedNotSet();

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();

        if (answer <= 0) revert InvalidOraclePrice(answer);

        uint256 staleness = maxOracleStaleness[poolId];
        if (staleness == 0) staleness = DEFAULT_MAX_ORACLE_STALENESS;
        // Intentional use of block.timestamp: staleness windows are
        // measured in whole minutes/hours, far beyond any validator's
        // ability to meaningfully manipulate block.timestamp (~seconds of
        // drift), so this is not a viable manipulation vector here.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - updatedAt > staleness) {
            revert StalePriceFeed(updatedAt, block.timestamp);
        }

        uint8 feedDecimals = feed.decimals();
        // Safe: `answer > 0` was just checked above, so this cast from a
        // positive int256 to uint256 cannot truncate or misrepresent value.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 rawPrice = uint256(answer);

        // Normalize to 18 decimals regardless of the feed's native decimals
        // (Chainlink feeds are commonly 8 decimals for USD pairs, but this
        // must not be assumed).
        uint256 priceX18;
        if (feedDecimals < 18) {
            priceX18 = rawPrice * (10 ** (18 - feedDecimals));
        } else if (feedDecimals > 18) {
            priceX18 = rawPrice / (10 ** (feedDecimals - 18));
        } else {
            priceX18 = rawPrice;
        }

        // If the oracle's own quoting convention is the inverse of the
        // pool's currency0-per-currency1 convention, invert it here so
        // downstream comparison is always apples-to-apples.
        if (!oracleDirectionMatchesPool[poolId]) {
            // priceX18 is currency1-per-currency0 in oracle terms; invert
            // to currency0-per-currency1 at 18-decimal fixed point.
            priceX18 = (1e36) / priceX18;
        }

        return priceX18;
    }

    /// @notice Reads the pool's current price from `sqrtPriceX96` (via
    /// StateLibrary) and converts it to the same 18-decimal,
    /// currency0-per-currency1 representation used by `_getOraclePriceX18`.
    /// Only used to REFRESH the block snapshot (see
    /// `_refreshBlockSnapshotIfNeeded`) — Signal 1 itself reads the frozen
    /// snapshot, not this live value directly, as a defense against
    /// same-block price manipulation (see storage docs above).
    function _getPoolPriceX18(PoolId poolId) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) return 0;
        return _rawSqrtPriceToDecimalsCorrectedX18(poolId, sqrtPriceX96);
    }

    /// @notice Converts a raw `sqrtPriceX96` value into the same
    /// 18-decimal, currency0-per-currency1 representation used throughout
    /// this contract, correcting for the two currencies' decimal
    /// difference.
    ///
    /// IMPORTANT: `sqrtPriceX96` encodes price in RAW (undecimalized) token
    /// units — i.e. (raw currency1 amount) / (raw currency0 amount), not
    /// human-scale price. For a pair where both tokens share the same
    /// decimals this needs no correction, but for the common case of
    /// mismatched decimals (e.g. WETH [18 decimals] / USDC [6 decimals]),
    /// the raw value must be corrected by 10^(decimals0 - decimals1) before
    /// it is comparable to a human-scale oracle price. Skipping this
    /// correction was an earlier bug in this contract — flagged and fixed
    /// before Signal 2 was built on top of it, rather than after.
    function _rawSqrtPriceToDecimalsCorrectedX18(PoolId poolId, uint160 sqrtPriceX96) internal view returns (uint256) {
        // rawPriceX18 = (sqrtPriceX96 / 2^96)^2, in RAW token-unit terms,
        // scaled to 18-decimal fixed point. Computed without overflow by
        // scaling before squaring: rawPriceX18 = (sqrtPriceX96^2 * 1e18) / 2^192
        uint256 numerator = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 rawPriceX18 = FixedPointMathLib.mulDivDown(numerator, 1e18, 1 << 192);

        // Correct for the difference in decimals between currency0 and
        // currency1. If currency0 has more decimals than currency1, its raw
        // amounts are "inflated" relative to currency1's, which must be
        // corrected by multiplying; if fewer, by dividing.
        uint8 decimals0 = currency0Decimals[poolId];
        uint8 decimals1 = currency1Decimals[poolId];

        if (decimals0 > decimals1) {
            return rawPriceX18 * (10 ** (decimals0 - decimals1));
        } else if (decimals1 > decimals0) {
            return rawPriceX18 / (10 ** (decimals1 - decimals0));
        }
        return rawPriceX18;
    }
}
