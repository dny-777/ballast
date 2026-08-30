// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";

/// @notice Minimal, ABI-compatible mirror of Uniswap v4's PoolKey struct —
/// avoids importing the real v4-core type, since Solidity ABI-encodes a
/// struct purely by its field layout, not by nominal type identity across
/// separate compilations.
struct PoolKeyLite {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IBallastGuardianTarget {
    function guardianPause(PoolKeyLite calldata key) external;
}

/// @title OracleGuardianCallback
/// @notice Deployed on Ethereum Sepolia. Receives the cross-chain pause
/// signal from `OracleGuardianReactive` (on Reactive Lasna) and calls
/// `BallastHook.guardianPause()` for the pool identified in the callback
/// payload.
///
/// AUTHENTICATION (two independent layers, both inherited, not
/// hand-rolled): `authorizedSenderOnly` verifies msg.sender is the real
/// Sepolia callback proxy; `rvmIdOnly` verifies the injected first
/// parameter matches `rvm_id` — which this library sets to the ADDRESS
/// THAT DEPLOYED THIS CONTRACT (confirmed directly against this
/// library's source).
contract OracleGuardianCallback is AbstractCallback {
    address public immutable hook;

    event GuardianPauseRelayed(
        address indexed currency0, address indexed currency1, string reason, uint256 timestamp
    );

    /// @param callbackSender_ Sepolia's Reactive callback proxy —
    ///        0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA, verified
    ///        directly against Reactive's official "Origins &
    ///        Destinations" documentation page.
    /// @param hook_ The BallastHook instance to protect.
    constructor(address callbackSender_, address hook_) AbstractCallback(callbackSender_) {
        hook = hook_;
    }

    /// @param rvm_id_ Injected by the callback proxy — compared against
    ///        this contract's `rvm_id` (the deployer's address, per this
    ///        library's convention) via `rvmIdOnly`.
    function pause(
        address rvm_id_,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        string calldata reason
    ) external authorizedSenderOnly rvmIdOnly(rvm_id_) {
        IBallastGuardianTarget(hook).guardianPause(
            PoolKeyLite({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hook})
        );
        emit GuardianPauseRelayed(currency0, currency1, reason, block.timestamp);
    }
}