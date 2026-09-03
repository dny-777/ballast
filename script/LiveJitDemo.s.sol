// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

/// @title LiveJitDemo
/// @notice Submits add-liquidity, swap, and remove-liquidity as three
/// back-to-back transactions from a single script run — the real,
/// practical fix for demonstrating JIT decay live: manual CLI commands,
/// typed one at a time, naturally take longer than the 10-block decay
/// window to sequence. Running all three from one script submits them
/// as fast as the network allows, giving a genuine shot at landing
/// within the real decay window (or even the same block).
///
/// Usage:
///   forge script script/LiveJitDemo.s.sol --rpc-url $SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY --broadcast --slow
contract LiveJitDemo is Script {
    address constant HOOK = 0xC321e31f42c9630Cdc54bcd304Cbb70B8B1769C5;
    address constant DEMO_TOKEN = 0x11aFe39b01189774a5D11f041BB55dfc888098B0;
    address constant LIQUIDITY_ROUTER = 0x3d76b78337253f279496CAA741DEc7876F4D46f9;
    address constant SWAP_ROUTER = 0xC14c50A1016a9C3143Eb566bbc31618Ea247FEB1;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(DEMO_TOKEN),
            fee: 8_388_608,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        vm.startBroadcast(pk);

        // Step 1: add a real, sizeable liquidity position.
        PoolModifyLiquidityTest(LIQUIDITY_ROUTER).modifyLiquidity{value: 0.03 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 0.02 ether,
                salt: bytes32(uint256(2))
            }),
            ""
        );
        console.log("Step 1: liquidity added.");

        // Step 2: a real swap generating real fees for this position.
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        PoolSwapTest(SWAP_ROUTER).swap{value: 0.006 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -0.005 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ""
        );
        console.log("Step 2: swap executed.");

        // Step 3: remove the SAME position immediately after.
        PoolModifyLiquidityTest(LIQUIDITY_ROUTER)
            .modifyLiquidity(
                key,
                ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: -0.02 ether,
                salt: bytes32(uint256(2))
            }),
                ""
            );
        console.log("Step 3: liquidity removed. Check BallastHook events for JitPenaltyApplied.");

        vm.stopBroadcast();
    }
}
