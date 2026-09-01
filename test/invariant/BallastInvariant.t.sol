// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BallastHook} from "../../src/BallastHook.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {BallastInvariantHandler} from "./BallastInvariantHandler.sol";

/// @title BallastInvariantTest
/// @notice Real, stateful invariant tests: Foundry drives the Handler
/// through long, RANDOMIZED SEQUENCES of many different calls (swaps in
/// both directions, oracle price moves, block advancement, in random
/// order and random counts), and after EVERY single step, checks that
/// the properties below still hold. This is meaningfully stronger than
/// our existing fuzz tests (which randomize inputs to one isolated
/// call): a bug that only manifests after a specific SEQUENCE of
/// operations — not from any single call in isolation — is exactly what
/// this catches and fuzz tests cannot.
///
/// Run with: forge test --match-contract BallastInvariantTest -vvv
/// (configure runs/depth in foundry.toml's [invariant] section, or via
/// FOUNDRY_INVARIANT_RUNS / FOUNDRY_INVARIANT_DEPTH env vars)
contract BallastInvariantTest is StdInvariant, Test, Deployers {
    BallastHook hook;
    MockAggregatorV3 oracle;
    BallastInvariantHandler handler;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
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

        handler = new BallastInvariantHandler(hook, swapRouter, key, oracle, currency0, currency1);

        // Grant the handler the tokens and approvals it needs to
        // actually execute swaps against the real pool.
        deal(Currency.unwrap(currency0), address(handler), 1000 ether);
        deal(Currency.unwrap(currency1), address(handler), 1000 ether);
        vm.startPrank(address(handler));
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Only fuzz calls into the handler — never directly into the
        // hook or PoolManager, which would bypass the handler's careful
        // input-bounding and likely just spend the whole run reverting.
        targetContract(address(handler));
    }

    /// @notice INVARIANT 1 — Solvency: the hook must never claim to hold
    /// more in pending reserve than it actually holds in real token
    /// balance, no matter what sequence of swaps, oracle moves, and
    /// block advancement produced the current state. A violation here
    /// would mean the reserve accounting can be made to promise more
    /// than physically exists — the single most serious class of bug
    /// this contract could have.
    function invariant_reserveNeverExceedsActualBalance() public view {
        PoolId poolId = key.toId();
        uint256 actualBalance0 = currency0.balanceOf(address(hook));
        uint256 actualBalance1 = currency1.balanceOf(address(hook));

        assertGe(
            actualBalance0,
            hook.pendingReserve0(poolId),
            "Hook claims more pending reserve0 than it actually holds"
        );
        assertGe(
            actualBalance1,
            hook.pendingReserve1(poolId),
            "Hook claims more pending reserve1 than it actually holds"
        );
    }

    /// @notice INVARIANT 2 — Fee bounds always hold, after ANY sequence
    /// of operations, not just in isolation. Confirms our fuzz-tested
    /// bound (previewFee always in [DISCOUNTED_FEE, MAX_SURCHARGE_FEE])
    /// survives arbitrary sequences of state changes, not just
    /// individually-randomized single calls.
    function invariant_feeAlwaysWithinBounds() public view {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.01 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint24 fee = hook.previewFee(key, params);
        assertGe(fee, hook.DISCOUNTED_FEE(), "Fee fell below the discounted floor after a real sequence");
        assertLe(fee, hook.MAX_SURCHARGE_FEE(), "Fee exceeded the surcharge ceiling after a real sequence");
    }

    /// @notice INVARIANT 3 — A paused pool always charges exactly
    /// BASE_FEE, no matter what sequence of operations happened before
    /// the pause (previously verified only immediately after pausing).
    function invariant_pausedPoolAlwaysChargesBaseFee() public view {
        PoolId poolId = key.toId();
        if (!hook.paused(poolId)) return; // not applicable this run

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.01 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        assertEq(hook.previewFee(key, params), hook.BASE_FEE(), "Paused pool charged a non-base fee");
    }
}
