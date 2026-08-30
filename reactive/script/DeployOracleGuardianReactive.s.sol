// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {OracleGuardianReactive} from "../src/OracleGuardianReactive.sol";

/// @title DeployOracleGuardianReactive
/// @notice Deploys OracleGuardianReactive to Reactive Lasna. Run this
/// SECOND, after DeployOracleGuardianCallback — update CALLBACK_RECEIVER
/// below with that real, deployed address first.
///
/// Usage:
///   forge script script/DeployOracleGuardianReactive.s.sol \
///     --rpc-url https://lasna-rpc.rnk.dev/ \
///     --private-key $PRIVATE_KEY \
///     --broadcast \
///     --legacy
contract DeployOracleGuardianReactive is Script {
    // ── UPDATE THIS with the real address from
    // DeployOracleGuardianCallback's output ──
    address constant CALLBACK_RECEIVER = 0x800f4b1B735683c45E048A8d383d9C892Fc05CD4;

    address constant WATCHED_HOOK = 0xB629809f97Fc458A0266f00e5Fa28850716bA0C4;
    address constant WATCHED_ORACLE = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // Sepolia Chainlink ETH/USD
    address constant POOL_CURRENCY0 = address(0); // native ETH
    address constant POOL_CURRENCY1 = 0x11aFe39b01189774a5D11f041BB55dfc888098B0; // demo token
    uint24 constant POOL_FEE = 8_388_608; // DYNAMIC_FEE_FLAG
    int24 constant POOL_TICK_SPACING = 60;

    function run() external {
        require(CALLBACK_RECEIVER != 0x000000000000000000000000000000000000dEaD, "Update CALLBACK_RECEIVER before running this script");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        OracleGuardianReactive guardian = new OracleGuardianReactive(
            CALLBACK_RECEIVER, WATCHED_HOOK, WATCHED_ORACLE, POOL_CURRENCY0, POOL_CURRENCY1, POOL_FEE, POOL_TICK_SPACING
        );

        vm.stopBroadcast();

        console.log("---");
        console.log("OracleGuardianReactive deployed at:", address(guardian));
        console.log("Fund it with lREACT, then trigger a real oracle change on Sepolia to test.");
    }
}