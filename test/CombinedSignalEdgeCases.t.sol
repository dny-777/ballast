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

/// @title CombinedSignalEdgeCasesTest
/// @notice Two categories of test genuinely missing before now: the
/// "corrective direction, but structurally excessive size" combined
/// signal case (previously flagged, never explicitly verified), and
/// real gas benchmarks for the new JIT liquidity lifecycle hooks
/// (beforeAddLiquidity / afterRemoveLiquidity), which had never been
/// measured — only swap gas costs were benchmarked before.
contract CombinedSignalEdgeCasesTest is Test, Deployers {
    BallastHook hook;
    MockAggregatorV3 oracle;

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
                liquidityDelta: 200 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        oracle = new MockAggregatorV3(8, int256(1 * 10 ** 8));
        hook.configurePool(key, oracle, true, 0);
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    /// @notice The genuinely untested combined case: a swap that is
    /// CORRECTIVE relative to the oracle (Signal 1 would want to
    /// discount it) but ALSO structurally excessive relative to the
    /// pool's own recent activity (Signal 2 flags it). Confirms the
    /// real, current behavior: Signal 2's flag is NOT overridden by
    /// Signal 1's corrective discount — the swap is still charged above
    /// the flat discount, reflecting genuine size-based concern even in
    /// the "helpful" price direction.
    function test_correctiveButStructurallyExcessive_isNotGivenTheFlatDiscount() public {
        // Seed a real, modest baseline first.
        for (uint256 i = 0; i < 3; i++) {
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -0.05 ether,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                _settings(),
                ZERO_BYTES
            );
            vm.roll(block.number + 1);
        }

        // Oracle now shows a lower price than the pool — a swap pushing
        // the pool price DOWN (zeroForOne=true) is the CORRECTIVE
        // direction here.
        oracle.setAnswer(int256(0.7 * 10 ** 8));

        // But make this specific corrective swap disproportionately
        // large relative to the established 0.05 ether baseline.
        SwapParams memory correctiveButHugeParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -10 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint24 fee = hook.previewFee(key, correctiveButHugeParams);

        console.log("Fee for a corrective-direction but structurally excessive swap:", fee);
        console.log("Pure flat discount would be:", hook.DISCOUNTED_FEE());
        console.log("Base fee for reference:", hook.BASE_FEE());

        assertGt(
            fee,
            hook.DISCOUNTED_FEE(),
            "A structurally excessive swap must not receive the flat discount just for being oracle-corrective"
        );
    }

    /// @notice Confirms the opposite, already-expected case still holds
    /// precisely: corrective AND NOT excessive gets exactly the flat
    /// discount, no more, no less — the clean baseline this edge case
    /// is being compared against.
    function test_correctiveAndNotExcessive_getsExactlyTheFlatDiscount() public {
        oracle.setAnswer(int256(0.7 * 10 ** 8));

        SwapParams memory modestCorrectiveParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.01 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint24 fee = hook.previewFee(key, modestCorrectiveParams);
        assertEq(fee, hook.DISCOUNTED_FEE(), "A genuinely modest corrective swap should get exactly the flat discount");
    }

    /// @notice Real gas benchmark: the cost of beforeAddLiquidity's new
    /// position-tracking write — never measured before this.
    function test_gasBenchmark_beforeAddLiquidity() public {
        uint256 gasBefore = gasleft();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(uint256(99))
            }),
            ZERO_BYTES
        );
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used, modifyLiquidity (add) with JIT tracking:", gasUsed);
    }

    /// @notice Real gas benchmark: removal WITHOUT triggering the JIT
    /// penalty (aged position) — the common, non-penalized case.
    function test_gasBenchmark_afterRemoveLiquidity_noPenalty() public {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(uint256(100))
            }),
            ZERO_BYTES
        );
        vm.roll(block.number + 20); // well past the JIT decay window

        uint256 gasBefore = gasleft();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: -10 ether,
                salt: bytes32(uint256(100))
            }),
            ZERO_BYTES
        );
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used, afterRemoveLiquidity, no JIT penalty (aged position):", gasUsed);
    }

    /// @notice Real gas benchmark: removal that DOES trigger the JIT
    /// penalty (same-block) — the more expensive path, including the
    /// real take() + reserve update + potential auto-donate.
    function test_gasBenchmark_afterRemoveLiquidity_withJitPenalty() public {
        // Generate real fees for this position first via an actual swap.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 50 ether,
                salt: bytes32(uint256(101))
            }),
            ZERO_BYTES
        );
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            _settings(),
            ZERO_BYTES
        );

        uint256 gasBefore = gasleft();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: -50 ether,
                salt: bytes32(uint256(101))
            }),
            ZERO_BYTES
        );
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used, afterRemoveLiquidity, WITH JIT penalty (same-block):", gasUsed);
    }
}
