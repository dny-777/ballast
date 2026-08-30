// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @notice Minimal mock of Reactive's real system contract, deployed at the
/// hardcoded SERVICE_ADDR (0x0000...fffFfF) via vm.etch in tests — the
/// same address independently confirmed via `cast code` against the real
/// live Lasna network.
contract MockSystemContract is ISystemContract {
    struct Subscription {
        uint256 chainId;
        address contractAddr;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    Subscription[] public subscriptions;

    function subscribe(uint256 chain_id, address _contract, uint256 topic_0, uint256 topic_1, uint256 topic_2, uint256 topic_3)
        external
    {
        subscriptions.push(Subscription(chain_id, _contract, topic_0, topic_1, topic_2, topic_3));
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}