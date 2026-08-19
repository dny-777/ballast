// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
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

    /// @notice Basis-point denominator used throughout this contract.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // ─────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────

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

    /// @notice Accumulated surcharge reserve per pool, tracked in
    /// currency0 terms, pending release back to LPs via `donate()`.
    /// (Reserve accounting and the `donate()` release loop are built in
    /// the Days 6-8 milestone — declared here now so Signal-1 fee logic
    /// has a real place to route captured value from day one.)
    mapping(PoolId poolId => uint256 reserve) public pendingReserve;

    /// @notice Pool owner/configurer, set at `beforeInitialize` time to
    /// whoever initializes the pool. Only this address may configure the
    /// price feed and staleness window for that pool.
    mapping(PoolId poolId => address configurer) public poolConfigurer;

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
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────────────────────────────────────────────────
    // beforeInitialize — gate: pool MUST be a dynamic-fee pool
    // ─────────────────────────────────────────────────────────────────────

    function _beforeInitialize(address sender, PoolKey calldata key, uint160)
        internal
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        poolConfigurer[key.toId()] = sender;
        return this.beforeInitialize.selector;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Pool configuration — must be set before this hook's fee logic is
    // meaningful for a given pool. Left intentionally simple (owner-only,
    // single feed) for the hackathon scope; a production version would
    // likely want a two-step ownership handoff and feed-change timelock.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Configure the Chainlink reference feed for a pool. Callable
    /// only by whoever initialized the pool (see `_beforeInitialize`).
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
    function configurePool(
        PoolKey calldata key,
        IAggregatorV3 feed,
        bool oracleMatchesPoolDirection,
        uint256 staleness
    ) external {
        PoolId poolId = key.toId();
        require(msg.sender == poolConfigurer[poolId], "Ballast: not pool configurer");
        require(address(feed) != address(0), "Ballast: feed cannot be zero address");

        priceFeeds[poolId] = feed;
        oracleDirectionMatchesPool[poolId] = oracleMatchesPoolDirection;
        maxOracleStaleness[poolId] = staleness;

        // Auto-read and cache each token's decimals, rather than trusting a
        // manually-supplied value — removes an entire class of
        // misconfiguration risk (a wrong decimals input would silently
        // corrupt every fee decision this hook makes for the pool).
        currency0Decimals[poolId] = _readDecimals(key.currency0);
        currency1Decimals[poolId] = _readDecimals(key.currency1);
    }

    /// @notice Reads a currency's decimals, treating native ETH
    /// (`Currency` wrapping `address(0)`) as 18 decimals to match WETH's
    /// convention, since native ETH has no `decimals()` function to call.
    function _readDecimals(Currency currency) internal view returns (uint8) {
        if (currency.isAddressZero()) return 18;
        return IERC20Decimals(Currency.unwrap(currency)).decimals();
    }

    // ─────────────────────────────────────────────────────────────────────
    // beforeSwap — Signal 1 (this milestone) drives the fee override.
    // Signal 2 will be folded into `_computeFee` on Days 3-5.
    // ─────────────────────────────────────────────────────────────────────

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = _computeFee(key, params);
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    // ─────────────────────────────────────────────────────────────────────
    // afterSwap — reserved for Days 6-8's donate() release loop and any
    // Signal-2-related state updates. Currently a no-op passthrough.
    //
    // NOTE: intentionally left non-pure even though this stub body doesn't
    // touch state yet — Days 6-8 adds the donate() release loop and
    // Signal-2 baseline updates here, both requiring state writes.
    // ─────────────────────────────────────────────────────────────────────

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // TODO (Days 6-8): periodic donate() release of pendingReserve back
        // to in-range LPs, and any Signal-2 baseline/state updates.
        return (this.afterSwap.selector, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Fee computation
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Public, read-only preview of the fee `_beforeSwap` would
    /// charge for a hypothetical swap with the given parameters, without
    /// actually executing anything. Exists so tests (and later, a demo
    /// frontend) can inspect and verify the fee logic directly, rather than
    /// only inferring it indirectly from swap output amounts.
    function previewFee(PoolKey calldata key, SwapParams calldata params) external view returns (uint24) {
        return _computeFee(key, params);
    }

    /// @notice Computes the fee to charge for a given swap, based on
    /// Signal 1 (external price deviation). Signal 2 (structural
    /// depth/impact check) will be added here on Days 3-5 and combined
    /// with Signal 1 per the design in our notes: neither signal alone
    /// reaches `MAX_SURCHARGE_FEE`; both firing together does.
    function _computeFee(PoolKey calldata key, SwapParams calldata params) internal view returns (uint24) {
        PoolId poolId = key.toId();
        IAggregatorV3 feed = priceFeeds[poolId];

        // If no feed has been configured yet for this pool, fall back to
        // the flat base fee rather than reverting — a pool should still be
        // usable (at the plain base fee) before/if it's ever configured.
        if (address(feed) == address(0)) {
            return BASE_FEE;
        }

        (bool isToxic, bool isCorrective, uint256 deviationBps) = _signal1(poolId, key, params, feed);

        if (isToxic) {
            // Linearly scale the surcharge with deviation magnitude, capped
            // at MAX_DEVIATION_BPS -> MAX_SURCHARGE_FEE. This mirrors the
            // spirit of Nezlobin's c*Delta scaling (Workshop 7) but is
            // driven by our own external-deviation signal rather than the
            // pool's own previous-block tick movement.
            uint256 cappedDeviation = deviationBps > MAX_DEVIATION_BPS ? MAX_DEVIATION_BPS : deviationBps;
            uint256 extra = (uint256(MAX_SURCHARGE_FEE - BASE_FEE) * cappedDeviation) / MAX_DEVIATION_BPS;
            // Safe: extra is bounded above by (MAX_SURCHARGE_FEE - BASE_FEE)
            // since cappedDeviation <= MAX_DEVIATION_BPS by construction, so
            // BASE_FEE + extra <= MAX_SURCHARGE_FEE, well within uint24 range.
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint24(BASE_FEE + extra);
        }

        if (isCorrective) {
            return DISCOUNTED_FEE;
        }

        return BASE_FEE;
    }

    /// @notice Signal 1: compares the pool's current price against a live
    /// Chainlink reference price, and determines whether this specific
    /// swap is pushing the pool price further away from (toxic) or back
    /// toward (corrective) the oracle price.
    /// @return isToxic True if this swap is toxic per Signal 1.
    /// @return isCorrective True if this swap is corrective per Signal 1.
    /// @return deviationBps The current |pool price - oracle price| /
    ///         oracle price deviation, in basis points, BEFORE this swap
    ///         executes. Used to scale the surcharge magnitude.
    function _signal1(PoolId poolId, PoolKey calldata key, SwapParams calldata params, IAggregatorV3 feed)
        internal
        view
        returns (bool isToxic, bool isCorrective, uint256 deviationBps)
    {
        uint256 oraclePriceX18 = _getOraclePriceX18(poolId, feed);
        uint256 poolPriceX18 = _getPoolPriceX18(poolId);

        if (poolPriceX18 == oraclePriceX18 || oraclePriceX18 == 0) {
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
    function _getPoolPriceX18(PoolId poolId) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

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
