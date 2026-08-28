// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {BallastHook} from "../src/BallastHook.sol";

/// @title SwapBallast
/// @notice Executes a single, real, demonstrable swap against an already
/// deployed Ballast pool. Deploys a fresh PoolSwapTest router (stateless,
/// safe to redeploy each run), previews the fee via BallastHook's own
/// `previewFee` BEFORE swapping (so the printed expectation can be
/// compared against the real, executed outcome — good demo-video
/// material), then executes the real swap and prints before/after
/// balances.
///
/// IMPORTANT: update the three addresses below with YOUR actual deployed
/// addresses from DeployBallast's output before running.
///
/// Usage:
///   forge script script/SwapBallast.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract SwapBallast is Script {
    // ── UPDATE THESE THREE WITH YOUR REAL DEPLOYED ADDRESSES ──
    address constant POOL_MANAGER = 0x6538Af3a6D4bC537EF7D2eBBf3c5614a4C6be5ed;
    address constant BALLAST_HOOK = 0xdB7e5dCFFf497A8ED0b0aCDeCaC397F2106cA0c4;
    address constant DEMO_TOKEN = 0xfBbE3e769c9Bf737a37FC9dDd9b4477Ef22D3357;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        IPoolManager manager = IPoolManager(POOL_MANAGER);
        BallastHook hook = BallastHook(BALLAST_HOOK);

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(DEMO_TOKEN),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        // A modest swap: sell 0.001 ETH for the demo token (zeroForOne =
        // true, exact input). Small enough to comfortably fit within the
        // small demo liquidity position deployed earlier.
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Preview the fee BEFORE swapping — a view call, no gas cost, and
        // good evidence for the demo video that the printed expectation
        // matches the swap that's about to actually execute onchain.
        uint24 previewedFee = hook.previewFee(key, params);
        console.log("Previewed fee (hundredths of a bip):", previewedFee);
        console.log("Ballast's BASE_FEE for comparison:", hook.BASE_FEE());

        uint256 tokenBalanceBefore = _tokenBalance(deployer);
        console.log("Demo token balance BEFORE swap:", tokenBalanceBefore);

        vm.startBroadcast(deployerPrivateKey);

        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        console.log("Deployed fresh PoolSwapTest router at:", address(swapRouter));

        swapRouter.swap{value: 0.001 ether}(
            key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        vm.stopBroadcast();

        uint256 tokenBalanceAfter = _tokenBalance(deployer);
        console.log("Demo token balance AFTER swap:", tokenBalanceAfter);
        console.log("Tokens received from this swap:", tokenBalanceAfter - tokenBalanceBefore);
        console.log("---");
        console.log("Swap complete. Check Etherscan for the real transaction and PoolConfigured/Swap events.");
    }

    function _tokenBalance(address account) internal view returns (uint256) {
        (bool success, bytes memory data) =
            DEMO_TOKEN.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        require(success, "Ballast: balanceOf call failed");
        return abi.decode(data, (uint256));
    }
}
