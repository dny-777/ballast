// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "reactive-lib-omni/src/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib-omni/src/interfaces/IPayable.sol";

/// @notice Minimal, ABI-compatible mirror of Uniswap v4's PoolKey struct.
/// Deliberately hand-defined here instead of importing the real v4-core
/// PoolKey type: v4-core pins its compiler to EXACTLY 0.8.26, while this
/// contract (via reactive-lib-omni) requires ^0.8.29 — a hard conflict
/// under one compilation unit (confirmed directly: forge refuses to
/// build both together). Since Solidity ABI-encodes a struct purely by
/// its field layout, not by nominal type identity across separate
/// compilations, this identically-shaped struct calls the real,
/// deployed BallastHook.guardianPause(PoolKey) correctly at the ABI
/// level despite being a "different type" from the compiler's
/// perspective in each project.
struct PoolKeyLite {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @notice Minimal interface into BallastHook — only what this contract
/// actually needs, to keep the dependency surface small and reviewable.
interface IBallastGuardianTarget {
    function guardianPause(PoolKeyLite calldata key) external;
}

/// @title OracleGuardianCallback
/// @notice Deployed on Ethereum Sepolia. Receives the cross-chain pause
/// signal from `OracleGuardianReactive` (on Reactive Lasna) and calls
/// `BallastHook.guardianPause()` for the pool identified in the
/// callback payload.
///
/// TRUST MODEL: this contract IS the `guardian` registered on
/// BallastHook via `setGuardian()`. It can only ever trigger a pause; it
/// has no ability to resume, change the oracle, or touch funds.
/// Authentication is TWO-FACTOR, matching Reactive's documented model
/// (verified against the real reactive-lib-omni source, not assumed
/// from prose): (1) `onlyServiceProvider` (inherited via AbstractPayer)
/// checks msg.sender is the real Sepolia callback proxy, and (2)
/// `onlyCallbackSender` checks the injected `rvmId` parameter matches
/// this contract's configured `_CALLBACK_SENDER` — the deployed
/// `OracleGuardianReactive` address on Lasna. Both checks are enforced
/// by the inherited AbstractCallback/AbstractPayer logic, not
/// hand-rolled here.
contract OracleGuardianCallback is AbstractCallback {
    /// @notice The BallastHook instance this guardian protects.
    address public immutable hook;

    event GuardianPauseRelayed(
        address indexed currency0, address indexed currency1, string reason, uint256 timestamp
    );

    /// @param callbackProxy_ Sepolia's Reactive callback proxy —
    ///        0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA, verified
    ///        directly against Reactive's official "Origins &
    ///        Destinations" documentation page, not assumed.
    /// @param callbackSender_ The deployed OracleGuardianReactive
    ///        contract's address on Lasna.
    /// @param hook_ The BallastHook instance to protect.
    constructor(IPayable callbackProxy_, address callbackSender_, address hook_)
        AbstractCallback(callbackProxy_, callbackSender_)
        payable
    {
        hook = hook_;
    }

    /// @notice Called by the Reactive callback proxy when
    /// OracleGuardianReactive requests a pause.
    /// @param rvmId Injected by the callback proxy itself (per
    ///        reactive-lib-omni's documented convention: "make sure the
    ///        payload reserves its first argument as an address where
    ///        the address of the calling contract will be injected") —
    ///        whatever OracleGuardianReactive encodes for this on the
    ///        Lasna side is overwritten before delivery, so it is
    ///        checked via `onlyCallbackSender`, never trusted blindly.
    /// @param currency0 The pool's currency0 (native ETH is address(0)).
    /// @param currency1 The pool's currency1.
    /// @param fee The pool's fee value (DYNAMIC_FEE_FLAG for Ballast pools).
    /// @param tickSpacing The pool's tick spacing.
    /// @param reason Human-readable reason, purely for on-chain
    ///        transparency (emitted in `GuardianPauseRelayed`) — not
    ///        used in any authorization logic.
    function pause(
        address rvmId,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        string calldata reason
    ) external onlyServiceProvider onlyCallbackSender(rvmId) {
        IBallastGuardianTarget(hook).guardianPause(
            PoolKeyLite({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hook})
        );
        emit GuardianPauseRelayed(currency0, currency1, reason, block.timestamp);
    }
}