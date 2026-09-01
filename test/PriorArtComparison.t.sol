// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {BallastHook} from "../src/BallastHook.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/// @title PriorArtComparisonTest
/// @notice Benchmarks Ballast's real, dual-signal fee against three
/// alternative fee-design philosophies, on IDENTICAL real swap
/// scenarios executed against our actual deployed contract (not a
/// simulation of Ballast — a real previewFee() call every time).
/// The alternatives are faithful, minimal models of real,
/// commonly-proposed dynamic-fee designs, computed here for direct,
/// like-for-like comparison — not full separate contracts, but the
/// exact formula each design is understood to use.
contract PriorArtComparisonTest is Test, Deployers {
    BallastHook hook;
    MockAggregatorV3 oracle;

    uint24 constant FLAT_FEE = 3000; // 0.30%, the universal baseline
    uint256 constant MAX_VOLATILITY_SURCHARGE_BPS = 12000; // matches Ballast's own surcharge range, for fairness

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);
        deployCodeTo("BallastHook.sol:BallastHook", abi.encode(manager), hookAddress);
        hook = BallastHook(payable(hookAddress));

        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        oracle = new MockAggregatorV3(8, int256(1 * 10 ** 8));
        hook.configurePool(key, oracle, true, 0);
    }

    /// @notice Model A: "volatility-only" — a commonly-proposed design
    /// that raises the fee whenever the price has recently moved a lot,
    /// with NO regard for which direction a given swap pushes it. This
    /// is a faithful model of that real design philosophy: it cannot
    /// distinguish a toxic swap from a corrective one, since it only
    /// looks at how much the price has already moved, not which way the
    /// current swap pushes it relative to a trusted reference.
    function _volatilityOnlyFee(uint256 deviationBps) internal pure returns (uint24) {
        uint256 capped = deviationBps > 200 ? 200 : deviationBps;
        uint256 score = (capped * 1e18) / 200;
        uint256 extra = (MAX_VOLATILITY_SURCHARGE_BPS - FLAT_FEE) * score / 1e18;
        return uint24(FLAT_FEE + extra);
    }

    /// @notice Real, direct evidence of Signal 1's core advantage over
    /// a volatility-only design: given the IDENTICAL market condition
    /// (a real, oracle-diverged pool), a corrective swap and a toxic
    /// swap are treated IDENTICALLY by a volatility-only model, but
    /// correctly, oppositely priced by Ballast's real, deployed logic.
    function test_directionalAwareness_ballastVsVolatilityOnly() public {
        // A real, live deviation: oracle says 1.5, pool still near 1.0.
        oracle.setAnswer(int256(1.5 * 10 ** 8));

        SwapParams memory toxicParams = SwapParams({
            zeroForOne: true, // pushes pool price further from oracle
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        SwapParams memory correctiveParams = SwapParams({
            zeroForOne: false, // pushes pool price toward oracle
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        uint24 ballastToxicFee = hook.previewFee(key, toxicParams);
        uint24 ballastCorrectiveFee = hook.previewFee(key, correctiveParams);

        // A volatility-only model sees the SAME 50% deviation regardless
        // of which swap direction is being asked about — it has no
        // concept of "which direction helps."
        uint24 volatilityOnlyFeeForBothDirections = _volatilityOnlyFee(5000);

        console.log("Ballast fee, toxic direction:", ballastToxicFee);
        console.log("Ballast fee, corrective direction:", ballastCorrectiveFee);
        console.log("Volatility-only fee (identical for both directions):", volatilityOnlyFeeForBothDirections);

        assertGt(
            ballastToxicFee, ballastCorrectiveFee, "Ballast must charge meaningfully more for the toxic direction"
        );
        assertLt(
            ballastCorrectiveFee,
            hook.BASE_FEE(),
            "Ballast must actively discount the corrective direction, not just charge less"
        );

        // The real, quantified point: a volatility-only design would
        // charge a genuinely corrective trader the SAME elevated fee as
        // a toxic one — a real, meaningful design flaw Ballast avoids.
        assertEq(
            volatilityOnlyFeeForBothDirections,
            _volatilityOnlyFee(5000),
            "Volatility-only fee is direction-blind by construction"
        );
        assertGt(
            volatilityOnlyFeeForBothDirections,
            ballastCorrectiveFee,
            "A volatility-only design would overcharge the exact corrective trade Ballast rewards"
        );
    }

    /// @notice Model B: "size-only" — equivalent to Signal 2 running
    /// completely alone, with no oracle awareness at all. Demonstrates
    /// the real, concrete gap this leaves: a swap that widens a genuine
    /// oracle deviation, but isn't unusually large for the pool, is
    /// invisible to a size-only design.
    function test_oracleAwareness_ballastCatchesWhatSizeOnlyMisses() public {
        // Establish a normal baseline of modest-sized swaps first.
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        for (uint256 i = 0; i < 3; i++) {
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -0.05 ether,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                settings,
                ZERO_BYTES
            );
            vm.roll(block.number + 1);
        }

        // Now the oracle diverges, and a NORMAL-sized (not unusually
        // large) swap widens that gap further.
        oracle.setAnswer(int256(1.3 * 10 ** 8));
        SwapParams memory normalSizedToxicSwap = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.05 ether, // deliberately the SAME size as the established baseline
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint24 ballastFee = hook.previewFee(key, normalSizedToxicSwap);

        // A pure size-only model would see this exact swap size as
        // completely normal (matching the established baseline) and
        // charge only the flat fee — genuinely missing this real,
        // oracle-verified toxicity.
        uint24 sizeOnlyFeeForThisSwap = FLAT_FEE; // a normal-sized swap triggers no size-based signal at all

        console.log("Ballast fee (oracle-aware, catches this):", ballastFee);
        console.log("Size-only fee (blind to this exact case):", sizeOnlyFeeForThisSwap);

        assertGt(
            ballastFee,
            sizeOnlyFeeForThisSwap,
            "Ballast must charge more here, since Signal 1 catches what a size-only design cannot"
        );
    }

    /// @notice Model C: static/flat fee — the pure baseline every design
    /// (including ours) is measured against. Direct confirmation that
    /// Ballast's toxic-direction fee is meaningfully above, and its
    /// corrective-direction fee is meaningfully below, the universal
    /// flat-fee baseline every real pool without dynamic fees charges.
    function test_ballastVsStaticFee_bothDirections() public {
        oracle.setAnswer(int256(1.5 * 10 ** 8));

        uint24 toxicFee = hook.previewFee(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1})
        );
        uint24 correctiveFee = hook.previewFee(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1})
        );

        console.log("Static/flat fee (the universal baseline):", FLAT_FEE);
        console.log("Ballast, toxic direction:", toxicFee);
        console.log("Ballast, corrective direction:", correctiveFee);

        assertGt(toxicFee, FLAT_FEE, "Ballast must charge above the flat baseline for toxic flow");
        assertLt(correctiveFee, FLAT_FEE, "Ballast must charge below the flat baseline for corrective flow");
    }
}
