// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "reactive-lib-omni/src/interfaces/ISystemContract.sol";

/// @notice Minimal mock of Reactive's real system contract, deployed at the
/// hardcoded SYSTEM address (0x8888...8888) via vm.etch in tests. Lets us
/// test OracleGuardianReactive's subscribe-on-construct and
/// requestCallbackV_1_0-on-trigger logic entirely locally, without any
/// access to the real Lasna network — mirroring exactly how we tested
/// BallastHook against a real (not mocked) PoolManager locally before ever
/// touching Sepolia gas.
contract MockSystemContract is ISystemContract {
    struct Subscription {
        uint256 chainId;
        address contractAddr;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    struct CallbackRequest {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Subscription[] public subscriptions;
    CallbackRequest[] public callbackRequests;

    function subscribe(uint256 chainId_, address contract_, uint256 topic0_, uint256 topic1_, uint256 topic2_, uint256 topic3_)
        external
    {
        subscriptions.push(Subscription(chainId_, contract_, topic0_, topic1_, topic2_, topic3_));
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallback(CallbackVersion, bytes memory) external {}

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external {
        callbackRequests.push(CallbackRequest(config_.chainId, config_.recipient, config_.gasLimit, config_.payload));
    }

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function callbackRequestCount() external view returns (uint256) {
        return callbackRequests.length;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}