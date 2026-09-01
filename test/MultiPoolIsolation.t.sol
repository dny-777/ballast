// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {BallastHook} from "../src/BallastHook.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/// @title MultiPoolIsolationTest
/// @notice A single BallastHook instance serves many real pools
/// simultaneously — that's the actual, intended production usage. This
/// verifies something never explicitly tested before: that toxic
/// activity, oracle configuration, and reserve accounting in ONE pool
/// never leaks into or affects a completely separate pool sharing the
/// same hook contract.
contract MultiPoolIsolationTest is Test, Deployers {
    BallastHook hook;

    MockAggregatorV3 oracleA;
    MockAggregatorV3 oracleB;

    PoolKey keyA;
    PoolKey keyB;

    Currency poolACurrency0;
    Currency poolACurrency1;
    Currency poolBCurrency0;
    Currency poolBCurrency1;

    function setUp() public {
        deployFreshManagerAndRouters();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);
        deployCodeTo("BallastHook.sol:BallastHook", abi.encode(manager), hookAddress);
        hook = BallastHook(payable(hookAddress));

        // Pool A's currencies, captured into their OWN named variables
        // immediately — the exact currency-clobbering bug pattern found
        // and fixed earlier in this project when a second
        // deployMintAndApprove2Currencies() call silently overwrites the
        // shared currency0/currency1 state variables.
        (currency0, currency1) = deployMintAndApprove2Currencies();
        poolACurrency0 = currency0;
        poolACurrency1 = currency1;

        (currency0, currency1) = deployMintAndApprove2Currencies();
        poolBCurrency0 = currency0;
        poolBCurrency1 = currency1;

        (keyA,) = initPool(poolACurrency0, poolACurrency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            keyA,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        (keyB,) = initPool(poolBCurrency0, poolBCurrency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            keyB,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        oracleA = new MockAggregatorV3(8, int256(1 * 10 ** 8));
        oracleB = new MockAggregatorV3(8, int256(1 * 10 ** 8));
        hook.configurePool(keyA, oracleA, true, 0);
        hook.configurePool(keyB, oracleB, true, 0);
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    /// @notice A large, oracle-diverging (toxic) swap in Pool A must not
    /// change Pool B's fee at all — confirmed with a real preview
    /// before and after, not assumed from code inspection.
    function test_toxicActivityInPoolA_doesNotAffectPoolBFee() public {
        SwapParams memory previewParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.5 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint24 poolBFeeBefore = hook.previewFee(keyB, previewParams);

        // Make Pool A's oracle diverge sharply and execute a real toxic
        // swap there.
        oracleA.setAnswer(int256(1.5 * 10 ** 8));
        swapRouter.swap(
            keyA,
            SwapParams({zeroForOne: true, amountSpecified: -5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            _settings(),
            ZERO_BYTES
        );

        uint24 poolBFeeAfter = hook.previewFee(keyB, previewParams);

        assertEq(poolBFeeBefore, poolBFeeAfter, "Pool B's fee must be completely unaffected by Pool A's toxic activity");
        assertEq(poolBFeeAfter, hook.BASE_FEE(), "Pool B, untouched, should still show exactly the base fee");
    }

    /// @notice Reserve captured from a toxic swap in Pool A must never
    /// appear in, or be claimable from, Pool B's reserve accounting.
    function test_reserveCapturedInPoolA_neverAppearsInPoolBReserve() public {
        oracleA.setAnswer(int256(1.5 * 10 ** 8));
        swapRouter.swap(
            keyA,
            SwapParams({zeroForOne: true, amountSpecified: -5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            _settings(),
            ZERO_BYTES
        );

        PoolId poolBId = keyB.toId();
        assertEq(hook.pendingReserve0(poolBId), 0, "Pool B must show zero reserve from Pool A's activity");
        assertEq(hook.pendingReserve1(poolBId), 0, "Pool B must show zero reserve from Pool A's activity");
    }

    /// @notice Each pool's Signal 2 baseline (the EMA of "normal" swap
    /// size) must evolve completely independently — large swaps in Pool
    /// A must not change what counts as "disproportionate" in Pool B.
    function test_signal2Baseline_evolvesIndependentlyPerPool() public {
        // Establish a real, distinct baseline in Pool A with several
        // large swaps.
        for (uint256 i = 0; i < 3; i++) {
            swapRouter.swap(
                keyA,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -2 ether,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                _settings(),
                ZERO_BYTES
            );
            vm.roll(block.number + 1);
        }

        // Pool B has never seen any swaps at all — its baseline should
        // still be completely unset, and a modest swap there should NOT
        // be judged against Pool A's now-large baseline.
        SwapParams memory modestSwap = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        uint24 poolBFee = hook.previewFee(keyB, modestSwap);

        assertEq(
            poolBFee,
            hook.BASE_FEE(),
            "Pool B's first-ever swap should seed its own baseline, not be judged against Pool A's"
        );
    }

    /// @notice Pausing Pool A (a real guardian pause) must have zero
    /// effect on Pool B's operation — a shared guardian address is not
    /// the same as a shared pause state.
    function test_pausingPoolA_doesNotPausePoolB() public {
        address guardianAddr = address(0xCAFE);
        hook.setGuardian(keyA, guardianAddr);
        vm.prank(guardianAddr);
        hook.guardianPause(keyA);

        assertTrue(hook.paused(keyA.toId()), "Pool A should genuinely be paused");
        assertFalse(hook.paused(keyB.toId()), "Pool B must remain completely unaffected");

        // Confirm Pool B still charges its normal, real, dynamic fee —
        // not silently frozen at base fee the way a paused pool would be.
        oracleB.setAnswer(int256(1.5 * 10 ** 8));
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.5 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        uint24 poolBFee = hook.previewFee(keyB, params);
        assertGt(poolBFee, hook.BASE_FEE(), "Pool B should still respond normally to its own toxic conditions");
    }

    /// @notice Changing Pool A's oracle must never affect what oracle
    /// Pool B reads from.
    function test_changingPoolAOracle_doesNotAffectPoolBOracle() public {
        MockAggregatorV3 newOracleA = new MockAggregatorV3(8, int256(2 * 10 ** 8));
        hook.configurePool(keyA, newOracleA, true, 0);

        vm.warp(block.timestamp + hook.ORACLE_CHANGE_TIMELOCK());
        hook.applyPendingOracleChange(keyA);

        assertEq(address(hook.priceFeeds(keyA.toId())), address(newOracleA), "Pool A's oracle should genuinely update");
        assertEq(
            address(hook.priceFeeds(keyB.toId())), address(oracleB), "Pool B's oracle must remain completely untouched"
        );
    }
}
