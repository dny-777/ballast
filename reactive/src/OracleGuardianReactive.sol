// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";

/// @title OracleGuardianReactive
/// @notice Deployed on Reactive Lasna. Subscribes to two independent event
/// sources related to BallastHook's one openly-documented trust
/// assumption: our own hook's `OracleChangeQueued` event, and Chainlink's
/// own `AnswerUpdated` event for anomalous single-update price jumps.
/// Either trigger fires a cross-chain callback to `OracleGuardianCallback`
/// on Sepolia, which calls `BallastHook.guardianPause()`.
///
/// ARCHITECTURE NOTE — ALL CONFIGURATION IS IMMUTABLE (a real correction,
/// not the original design): an earlier version of this contract used a
/// mutable `callbackReceiver` state variable, settable after deployment
/// via a separate `setDestinationCallback()` call, to solve the circular
/// dependency between this contract and `OracleGuardianCallback` (each
/// needs the other's address). Testing revealed this doesn't work:
/// Reactive contracts genuinely deploy to TWO separately-stored places —
/// the main Reactive Network and a private ReactVM — confirmed directly
/// against real behavior in this project's own test suite. A mutable
/// state change made via a direct call to one copy does NOT propagate to
/// the other's separate storage. Since `react()` only ever runs in the
/// ReactVM copy, a `callbackReceiver` set only on the Network copy would
/// never actually be seen. This version uses ONLY immutable
/// configuration, which IS correctly identical across both copies
/// (baked into the shared bytecode's constructor at deployment).
///
/// LIBRARY CHOICE: uses the older `reactive-lib` (not `reactive-lib-omni`)
/// with a plain `emit Callback(...)` for triggering callbacks — the
/// standard, documented pattern for this library.
contract OracleGuardianReactive is AbstractReactive {
    /// @notice keccak256("OracleChangeQueued(bytes32,address,uint256)") —
    /// BallastHook's own event, fired the moment a CHANGE (not initial
    /// configuration) to a pool's oracle is queued.
    uint256 public constant ORACLE_CHANGE_QUEUED_TOPIC0 =
        uint256(keccak256("OracleChangeQueued(bytes32,address,uint256)"));

    /// @notice keccak256("AnswerUpdated(int256,uint256,uint256)") —
    /// Chainlink's own standard AggregatorV3 event. NOTE: `current` (the
    /// price) is INDEXED — it arrives in `topic_1`, not in `data`.
    uint256 public constant CHAINLINK_ANSWER_UPDATED_TOPIC0 =
        uint256(keccak256("AnswerUpdated(int256,uint256,uint256)"));

    /// @notice The Sepolia chain ID, used both for the subscription's
    /// origin and the callback's destination.
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;

    /// @notice Basis-point threshold beyond which a single Chainlink
    /// price update is considered anomalous enough to trigger a pause.
    uint256 public constant ANOMALY_THRESHOLD_BPS = 1000; // 10%

    /// @notice Gas budget passed to the relayer for the destination call.
    uint64 public constant CALLBACK_GAS_LIMIT = 500_000;

    /// @notice The destination contract on Sepolia — an immutable
    /// constructor argument, correctly identical across both the
    /// Network and ReactVM copies of this contract.
    address public immutable callbackReceiver;

    /// @notice The BallastHook address being watched.
    address public immutable watchedHook;

    /// @notice The Chainlink feed address being watched for anomalies.
    address public immutable watchedOracle;

    /// @notice The specific pool's key fields, needed to reconstruct the
    /// PoolKey the destination-side `pause()` call expects.
    address public immutable poolCurrency0;
    address public immutable poolCurrency1;
    uint24 public immutable poolFee;
    int24 public immutable poolTickSpacing;

    /// @notice Tracks the last seen Chainlink answer, so a fresh
    /// AnswerUpdated event can be compared against it to compute a
    /// percentage jump. NOTE: this is per-instance state — the ReactVM
    /// copy (the only one that ever calls react()) maintains its own
    /// consistent history, which is exactly the copy that needs it.
    int256 public lastSeenAnswer;
    bool public hasSeenFirstAnswer;

    event GuardianTriggered(string reason, uint256 timestamp);

    constructor(
        address callbackReceiver_,
        address watchedHook_,
        address watchedOracle_,
        address poolCurrency0_,
        address poolCurrency1_,
        uint24 poolFee_,
        int24 poolTickSpacing_
    ) {
        callbackReceiver = callbackReceiver_;
        watchedHook = watchedHook_;
        watchedOracle = watchedOracle_;
        poolCurrency0 = poolCurrency0_;
        poolCurrency1 = poolCurrency1_;
        poolFee = poolFee_;
        poolTickSpacing = poolTickSpacing_;

        // Only the Reactive-Network copy subscribes; the ReactVM copy
        // (vm == true) skips this — matching AbstractReactive's own
        // vm-detection, verified directly against its real source.
        if (!vm) {
            service.subscribe(
                SEPOLIA_CHAIN_ID,
                watchedHook_,
                ORACLE_CHANGE_QUEUED_TOPIC0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            service.subscribe(
                SEPOLIA_CHAIN_ID,
                watchedOracle_,
                CHAINLINK_ANSWER_UPDATED_TOPIC0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    /// @notice ReactVM entry point: fires for every matched log.
    function react(LogRecord calldata log) external vmOnly {
        if (log.topic_0 == ORACLE_CHANGE_QUEUED_TOPIC0 && log._contract == watchedHook) {
            _requestPause("OracleChangeQueued detected");
            return;
        }

        if (log.topic_0 == CHAINLINK_ANSWER_UPDATED_TOPIC0 && log._contract == watchedOracle) {
            // Price is INDEXED (topic_1), not in data.
            int256 newAnswer = int256(log.topic_1);

            if (hasSeenFirstAnswer && lastSeenAnswer != 0) {
                uint256 diff;
                if (newAnswer > lastSeenAnswer) {
                    // Safe: newAnswer > lastSeenAnswer in this branch.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    diff = uint256(newAnswer - lastSeenAnswer);
                } else {
                    // Safe: lastSeenAnswer >= newAnswer in this branch.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    diff = uint256(lastSeenAnswer - newAnswer);
                }
                uint256 refAbs = uint256(lastSeenAnswer > 0 ? lastSeenAnswer : -lastSeenAnswer);
                uint256 changeBps = (diff * 10_000) / refAbs;

                if (changeBps >= ANOMALY_THRESHOLD_BPS) {
                    _requestPause("Anomalous Chainlink price jump detected");
                }
            }

            lastSeenAnswer = newAnswer;
            hasSeenFirstAnswer = true;
        }
    }

    /// @notice Requests the cross-chain callback that pauses the pool on
    /// Sepolia, via the proven `emit Callback(...)` mechanism.
    function _requestPause(string memory reason) internal {
        emit GuardianTriggered(reason, block.timestamp);

        bytes memory payload = abi.encodeWithSignature(
            "pause(address,address,address,uint24,int24,string)",
            address(0),
            poolCurrency0,
            poolCurrency1,
            poolFee,
            poolTickSpacing,
            reason
        );

        emit Callback(SEPOLIA_CHAIN_ID, callbackReceiver, CALLBACK_GAS_LIMIT, payload);
    }
}