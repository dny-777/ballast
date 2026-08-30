// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {OracleGuardianCallback} from "../src/OracleGuardianCallback.sol";

/// @title DeployOracleGuardianCallback
/// @notice Deploys OracleGuardianCallback to Ethereum Sepolia. Deployed
/// FIRST — this contract has no dependency on OracleGuardianReactive's
/// address at all: `rvm_id` (used for authorization) is set to the
/// DEPLOYER's own address at construction time, per this library's real,
/// confirmed convention. Only after this is deployed do we deploy
/// OracleGuardianReactive, passing this contract's now-known real
/// address as its immutable `callbackReceiver_` constructor argument.
///
/// Usage:
///   forge script script/DeployOracleGuardianCallback.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract DeployOracleGuardianCallback is Script {
    // Sepolia's real, confirmed Reactive callback proxy.
    address constant CALLBACK_PROXY = 0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA;

    // Your real, live BallastHook on Sepolia.
    address constant HOOK = 0xB629809f97Fc458A0266f00e5Fa28850716bA0C4;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        OracleGuardianCallback callback = new OracleGuardianCallback(CALLBACK_PROXY, HOOK);

        vm.stopBroadcast();

        console.log("---");
        console.log("OracleGuardianCallback deployed at:", address(callback));
        console.log("NEXT STEP: deploy OracleGuardianReactive on Lasna,");
        console.log("passing this address as callbackReceiver_.");
    }
}