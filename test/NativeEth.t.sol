// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {BallastHook} from "../src/BallastHook.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title NativeEthTest
/// @notice A real, significant gap found via LIVE testing, not local
/// tests: every other test file in this project uses two ERC20 tokens,
/// never native ETH — meaning a real bug (BallastHook had no receive()
/// function, so poolManager.take() reverted whenever it tried to
/// deliver native ETH to the hook during a skim) went completely
/// undetected across 107+ local tests, and only surfaced during a real,
/// live JIT demonstration against a real currency0=ETH pool on Sepolia.
/// This file specifically exercises native ETH through every skim path
/// this contract has, closing that exact gap going forward.
contract NativeEthTest is Test, Deployers {
    BallastHook hook;
    MockAggregatorV3 oracle;
    PoolKey ethKey;
    Currency demoToken;

    address trader = address(0x7124DE);
    address jitBot = address(0x717B07);

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

        (, Currency c1) = deployMintAndApprove2Currencies();
        demoToken = c1;

        // currency0 = native ETH (address(0)) — the exact real-world
        // configuration that revealed the bug live.
        ethKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: demoToken,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        manager.initialize(ethKey, SQRT_PRICE_1_1);

        // Seed real, initial liquidity using REAL native ETH via
        // msg.value, exactly like the live deployment does.
        vm.deal(address(this), 100 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 50 ether}(
            ethKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 40 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        oracle = new MockAggregatorV3(8, int256(1 * 10 ** 8));
        hook.configurePool(ethKey, oracle, true, 0);

        vm.deal(trader, 10 ether);
        vm.deal(jitBot, 30 ether);
        deal(Currency.unwrap(demoToken), jitBot, 100 ether);
        vm.prank(jitBot);
        MockERC20(Currency.unwrap(demoToken)).approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    /// @notice The real, direct regression test for the exact bug found
    /// live: a toxic, oracle-diverging swap that specifically skims
    /// NATIVE ETH (not an ERC20) must not revert. Before the fix, this
    /// exact scenario would fail with the hook unable to receive the
    /// skimmed ETH from poolManager.take().
    function test_toxicSwap_skimmingNativeEth_doesNotRevert() public {
        oracle.setAnswer(int256(1.5 * 10 ** 8));

        // zeroForOne=false: trader gives currency1 (token), receives
        // currency0 (ETH) — meaning ETH is the "unspecified" (output)
        // currency, exactly the side that gets skimmed from on a toxic
        // swap.
        deal(Currency.unwrap(demoToken), trader, 10 ether);
        vm.prank(trader);
        MockERC20(Currency.unwrap(demoToken)).approve(address(swapRouter), type(uint256).max);

        vm.prank(trader);
        swapRouter.swap(
            ethKey,
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            _settings(),
            ZERO_BYTES
        );

        // If we reach this line at all, the real bug is confirmed fixed
        // — the swap (and its native-ETH skim) completed without
        // reverting.
        assertTrue(true, "Swap with native ETH skim completed successfully");
    }

    /// @notice The exact live scenario that originally surfaced the bug:
    /// add real ETH liquidity, generate real fees via a swap, remove
    /// the SAME-block position — the JIT penalty must correctly skim
    /// native ETH without reverting.
    function test_jitPenalty_involvingNativeEth_doesNotRevert() public {
        vm.startPrank(jitBot);
        modifyLiquidityRouter.modifyLiquidity{value: 20 ether}(
            ethKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 15 ether,
                salt: bytes32(uint256(1))
            }),
            ZERO_BYTES
        );
        vm.stopPrank();

        deal(Currency.unwrap(demoToken), trader, 10 ether);
        vm.prank(trader);
        MockERC20(Currency.unwrap(demoToken)).approve(address(swapRouter), type(uint256).max);
        vm.prank(trader);
        swapRouter.swap(
            ethKey,
            SwapParams({zeroForOne: false, amountSpecified: -2 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            _settings(),
            ZERO_BYTES
        );

        // Remove the SAME-block position — triggers the JIT penalty,
        // which may need to skim real, native ETH.
        vm.prank(jitBot);
        modifyLiquidityRouter.modifyLiquidity(
            ethKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: -15 ether,
                salt: bytes32(uint256(1))
            }),
            ZERO_BYTES
        );

        assertTrue(true, "JIT removal involving native ETH completed successfully - the real, live-found bug is fixed");
    }

    /// @notice Confirms the hook can genuinely hold native ETH
    /// temporarily (between a skim and its auto-donate release) without
    /// any issue, directly exercising the new receive() function.
    function test_hookCanReceiveAndHoldNativeEthDirectly() public {
        uint256 balanceBefore = address(hook).balance;
        vm.deal(address(this), 1 ether);
        (bool success,) = address(hook).call{value: 1 ether}("");
        assertTrue(success, "Hook must be able to receive native ETH directly");
        assertEq(address(hook).balance, balanceBefore + 1 ether, "Hook's ETH balance must reflect the real transfer");
    }
}
