// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {OracleGuardianReactive} from "../src/OracleGuardianReactive.sol";

/// @title DeployOracleGuardianReactive
/// @notice Deploys OracleGuardianReactive to Reactive Lasna. This is the
/// FIRST of the two OracleGuardian deployments — see the deployment-
/// ordering NatSpec on OracleGuardianReactive itself for why this must
/// happen before OracleGuardianCallback is deployed on Sepolia.
///
/// Usage:
///   forge script script/DeployOracleGuardianReactive.s.sol \
///     --rpc-url https://lasna-rpc.rnk.dev/ \
///     --private-key $PRIVATE_KEY \
///     --broadcast \
///     --legacy
///
/// NOTE: --legacy is included because some RPC endpoints for newer/less
/// common chains don't yet support EIP-1559 fee estimation the way
/// mainnet/Sepolia do; omit it if your deploy fails with a fee-related
/// error suggesting otherwise, and add it back if you hit issues without
/// it. Confirm behavior empirically rather than assuming either way.
contract DeployOracleGuardianReactive is Script {
    // ── Real, already-deployed Sepolia addresses (from our actual
    // BallastHook deployment) ──
    address constant WATCHED_HOOK = 0xdB7e5dCFFf497A8ED0b0aCDeCaC397F2106cA0c4;
    address constant WATCHED_ORACLE = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // Sepolia Chainlink ETH/USD
    address constant POOL_CURRENCY0 = address(0); // native ETH
    address constant POOL_CURRENCY1 = 0xfBbE3e769c9Bf737a37FC9dDd9b4477Ef22D3357; // demo token
    uint24 constant POOL_FEE = 8_388_608; // DYNAMIC_FEE_FLAG
    int24 constant POOL_TICK_SPACING = 60;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        OracleGuardianReactive guardian = new OracleGuardianReactive(
            WATCHED_HOOK, WATCHED_ORACLE, POOL_CURRENCY0, POOL_CURRENCY1, POOL_FEE, POOL_TICK_SPACING
        );

        vm.stopBroadcast();

        console.log("---");
        console.log("OracleGuardianReactive deployed at:", address(guardian));
        console.log("Watching hook:", WATCHED_HOOK);
        console.log("Watching oracle:", WATCHED_ORACLE);
        console.log("---");
        console.log("NEXT STEP: deploy OracleGuardianCallback on Sepolia,");
        console.log("passing this address as callbackSender_.");
        console.log("Then call setDestinationCallback() back on THIS contract");
        console.log("with the deployed OracleGuardianCallback address.");
    }
}
