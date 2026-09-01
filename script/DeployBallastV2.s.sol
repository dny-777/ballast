// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BallastHook} from "../src/BallastHook.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// @title DeployBallastV2
/// @notice Redeploys BallastHook with its updated permission set (now
/// including beforeAddLiquidity / afterRemoveLiquidity for the new JIT
/// liquidity defense), REUSING the existing, already-deployed
/// PoolManager and demo token — only the hook itself and the pool it
/// serves are new, minimizing the blast radius of this redeployment.
///
/// Usage:
///   forge script script/DeployBallastV2.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract DeployBallastV2 is Script {
    // Reused, already-deployed, real infrastructure — see README for
    // the original deployment records.
    address constant EXISTING_POOL_MANAGER = 0x9008B62b056A7F15C7cdd48561cfbc32e0F818DD;
    address constant EXISTING_DEMO_TOKEN = 0x11aFe39b01189774a5D11f041BB55dfc888098B0;
    address constant SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        IPoolManager manager = IPoolManager(EXISTING_POOL_MANAGER);

        // ---- Mine a valid CREATE2 salt for the UPDATED permission set ----
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(manager);
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        (address minedHookAddress, bytes32 salt) =
            HookMiner.find(create2Deployer, flags, type(BallastHook).creationCode, constructorArgs);

        console.log("Mined new hook address:", minedHookAddress);

        BallastHook hook = new BallastHook{salt: salt}(manager);
        require(address(hook) == minedHookAddress, "Ballast: deployed address does not match mined address");
        console.log("New BallastHook (with JIT defense) deployed at:", address(hook));

        // ---- Initialize a NEW pool with the new hook (a hook's
        // permissions are baked into the pool at initialization, so a
        // new hook genuinely means a new pool) ----
        PoolModifyLiquidityTest modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        Currency currency0 = CurrencyLibrary.ADDRESS_ZERO;
        Currency currency1 = Currency.wrap(EXISTING_DEMO_TOKEN);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        uint160 sqrtPriceX96 = 79228162514264337593543950336; // 1:1 starting price
        manager.initialize(key, sqrtPriceX96);
        console.log("New pool initialized.");

        hook.configurePool(key, IAggregatorV3(SEPOLIA_ETH_USD_FEED), false, 0);
        console.log("Oracle configured on new pool.");

        MockERC20(EXISTING_DEMO_TOKEN).approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity{value: 0.03 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 0.02 ether,
                salt: bytes32(0)
            }),
            ""
        );
        console.log("Initial liquidity added to new pool.");

        vm.stopBroadcast();

        console.log("---");
        console.log("Redeployment complete. NEXT STEPS:");
        console.log("1. Redeploy ZKPriceGuardian with this new hook address");
        console.log("2. Redeploy OracleGuardianCallback/Reactive watching this new hook's events");
        console.log("3. Register a MultiGuardian (or new one) as this new hook's guardian");
        console.log("New BallastHook:", address(hook));
    }
}