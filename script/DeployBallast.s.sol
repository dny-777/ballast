// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
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

/// @title DeployBallast
/// @notice Real, complete deployment script for Ballast: deploys a fresh
/// PoolManager (see contract-level NatSpec for why we deploy our own
/// rather than attaching to an unverified "official" testnet address),
/// mines a valid CREATE2 salt for BallastHook using the real HookMiner
/// (not the deployCodeTo test shortcut), deploys the hook, deploys a demo
/// token, initializes a real dynamic-fee ETH/TOKEN pool, configures the
/// Chainlink oracle, and seeds initial liquidity — one command, fully
/// verifiable onchain.
///
/// PRAGMATIC CHOICE (documented honestly): liquidity is added via v4-core's
/// own `PoolModifyLiquidityTest` router for simplicity in this demo/testnet
/// script, rather than the full `PositionManager` a production launch
/// would use. This is a reasonable choice for a testnet demo, not
/// something to carry into a real mainnet launch — noted here rather than
/// silently assumed.
///
/// Usage:
///   forge script script/DeployBallast.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
///
/// Omit --broadcast for a dry run / simulation first (strongly
/// recommended before spending real testnet gas).
contract DeployBallast is Script {
    // Sepolia's real, confirmed Chainlink ETH/USD feed — see README for
    // sourcing. Update this constant if deploying to a different network.
    address constant SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    // Chainlink's ETH/USD feed reports price with 8 decimals, e.g. a price
    // of "3000.00000000" USD per ETH is represented as 300000000000.
    // Native ETH's own pool-side price is inherently in 18-decimal terms,
    // so the oracle does NOT already match the pool's currency0-per-
    // currency1 direction without inversion — see configurePool's
    // `oracleMatchesPoolDirection` parameter below.

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // ---- 1. Deploy a fresh PoolManager ----
        PoolManager manager = new PoolManager(deployer);
        console.log("PoolManager deployed at:", address(manager));

        // ---- 2. Mine a valid CREATE2 salt for BallastHook ----
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(manager);
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        (address minedHookAddress, bytes32 salt) =
            HookMiner.find(create2Deployer, flags, type(BallastHook).creationCode, constructorArgs);

        console.log("Mined hook address:", minedHookAddress);

        // ---- 3. Deploy BallastHook to the mined address via CREATE2 ----
        BallastHook hook = new BallastHook{salt: salt}(manager);
        require(address(hook) == minedHookAddress, "Ballast: deployed address does not match mined address");
        console.log("BallastHook deployed at:", address(hook));

        // ---- 4. Deploy a demo token to pair against native ETH ----
        MockERC20 token = new MockERC20("Ballast Demo Token", "BDT", 18);
        token.mint(deployer, 1_000_000 ether);
        console.log("Demo token deployed at:", address(token));

        // ---- 5. Deploy the liquidity router and initialize the pool ----
        PoolModifyLiquidityTest modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Native ETH (address(0)) always sorts as currency0 (Workshop 3's
        // Token0/Token1 sorting rule — native token is always address(0),
        // the lexicographically smallest possible address).
        Currency currency0 = CurrencyLibrary.ADDRESS_ZERO;
        Currency currency1 = Currency.wrap(address(token));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        // Initialize at an arbitrary starting price; the oracle deviation
        // will reflect this until real swaps move it. SQRT_PRICE_1_1
        // equivalent — a real launch would choose this deliberately based
        // on actual market price at deployment time.
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // 1:1 in raw terms
        manager.initialize(key, sqrtPriceX96);
        console.log("Pool initialized.");

        // ---- 6. Configure the Chainlink oracle for this pool ----
        // oracleMatchesPoolDirection = false: Chainlink's ETH/USD feed
        // reports USD-per-ETH, which is the INVERSE of this pool's
        // currency0(ETH)-per-currency1(TOKEN) convention, so the hook
        // must invert it internally (see _getOraclePriceX18's handling).
        hook.configurePool(key, IAggregatorV3(SEPOLIA_ETH_USD_FEED), false, 0);
        console.log("Oracle configured.");

        // ---- 7. Seed initial liquidity ----
        // NOTE: liquidityDelta is not a direct token amount (Workshop 5/10)
        // — confirmed via real local testing that a liquidityDelta of
        // 1 ether requires close to 1 ETH of actual currency0 to back it
        // at this starting price. Scaled down here to a small demo-sized
        // position (0.02 ether liquidityDelta) so this fits comfortably
        // within realistic testnet faucet amounts — a real launch would
        // size this deliberately based on actual deployment goals, not
        // faucet availability.
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
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
        console.log("Initial liquidity added.");

        vm.stopBroadcast();

        console.log("---");
        console.log("Deployment complete.");
        console.log("PoolManager:", address(manager));
        console.log("BallastHook:", address(hook));
        console.log("Demo token:", address(token));
    }
}
