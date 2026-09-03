// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {BallastHook} from "../../src/BallastHook.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @title BallastInvariantHandler
/// @notice Performs bounded, randomized SEQUENCES of operations against a
/// real deployed BallastHook — swaps in both directions and sizes,
/// oracle price changes, block advancement — so the invariant suite can
/// check that core properties hold after EVERY step of an arbitrary
/// sequence, not just after a single isolated call. This is meaningfully
/// stronger than our existing fuzz tests, which randomize inputs to one
/// call in isolation.
///
/// Design note: every handler function bounds its own inputs and wraps
/// the actual action in a way that tolerates expected reverts (e.g. a
/// swap that runs out of liquidity) without halting the fuzzer — a
/// handler that lets unrelated reverts kill the run would make the
/// invariant suite far less effective at actually exploring the state
/// space.
contract BallastInvariantHandler is Test {
    BallastHook public hook;
    PoolSwapTest public swapRouter;
    PoolKey public key;
    MockAggregatorV3 public oracle;

    Currency public currency0;
    Currency public currency1;

    // Tracks whether we've ever caused a real, successful swap — used by
    // the invariant contract to skip solvency assertions before there's
    // been any real activity to check.
    uint256 public successfulSwapCount;

    constructor(
        BallastHook hook_,
        PoolSwapTest swapRouter_,
        PoolKey memory key_,
        MockAggregatorV3 oracle_,
        Currency currency0_,
        Currency currency1_
    ) {
        hook = hook_;
        swapRouter = swapRouter_;
        key = key_;
        oracle = oracle_;
        currency0 = currency0_;
        currency1 = currency1_;
    }

    /// @notice Performs a bounded, randomized swap in a randomized
    /// direction. Reverts are caught and ignored — a reverted swap
    /// (e.g. insufficient liquidity at an extreme price) is not itself
    /// an invariant violation; we only care about state after
    /// successful operations.
    function doSwap(bool zeroForOne, uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 0.0001 ether, 5 ether);

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // Safe: amount is bounded to [0.0001, 5] ether above, far
            // below int256's range.
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        try swapRouter.swap(
            key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), new bytes(0)
        ) {
            successfulSwapCount++;
        } catch {
            // Expected occasionally (e.g. extreme price bounds) — not a
            // failure of anything we're testing.
        }
    }

    /// @notice Randomly moves the oracle price within a bounded range,
    /// simulating real market movement between swaps.
    function doOracleMove(uint256 priceSeed) external {
        int256 newPrice = int256(bound(priceSeed, 0.5 ether, 2 ether));
        oracle.setAnswer(newPrice);
    }

    /// @notice Advances the block, refreshing Signal 1/2's top-of-block
    /// snapshots — real usage always involves this, and skipping it
    /// entirely would leave the same-block-manipulation defense
    /// permanently "stuck" on the very first snapshot forever.
    function doAdvanceBlock(uint256 blocksSeed) external {
        uint256 blocksToAdvance = bound(blocksSeed, 1, 5);
        vm.roll(block.number + blocksToAdvance);
    }
}
