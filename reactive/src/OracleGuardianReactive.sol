// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-omni/src/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib-omni/src/interfaces/ISystemContract.sol";
import {IReactive} from "reactive-lib-omni/src/interfaces/IReactive.sol";

/// @title OracleGuardianReactive
/// @notice Deployed on Reactive Lasna. Subscribes to two independent
/// event sources related to BallastHook's one openly-documented trust
/// assumption (the pool configurer's ability to change the oracle feed —
/// see BallastHook's ORACLE_CHANGE_TIMELOCK docs): our own hook's
/// `OracleChangeQueued` event, and Chainlink's own `AnswerUpdated` event
/// for anomalous single-update price jumps. Either trigger fires a
/// cross-chain callback to `OracleGuardianCallback` on Sepolia, which
/// calls `BallastHook.guardianPause()`.
///
/// DEPLOYMENT ORDERING (a real circular dependency, resolved
/// deliberately, not accidentally): this contract needs to know
/// `OracleGuardianCallback`'s address to send it callbacks, but that
/// contract's own constructor needs THIS contract's address first (as
/// its `_CALLBACK_SENDER`). The resolution: deploy this contract first
/// (without a destination), deploy `OracleGuardianCallback` second (now
/// that this contract's address is known), then call
/// `setDestinationCallback()` here to complete the wiring. `react()`
/// safely no-ops until that final step happens, rather than reverting
/// or misbehaving in the interim.
///
/// SECURITY NOTE (verified against the real reactive-lib-omni source,
/// not assumed from documentation): in this library version,
/// `AbstractCallback`'s `_CALLBACK_SENDER` on the destination side is
/// simply this contract's own deployed address — no deployer-identity
/// indirection, unlike the older, pre-"Omni fork" library several past
/// projects described working around.
contract OracleGuardianReactive is AbstractReactive {
    /// @notice keccak256("OracleChangeQueued(bytes32,address,uint256)") —
    /// BallastHook's own event, fired the moment a CHANGE (not initial
    /// configuration) to a pool's oracle is queued.
    uint256 public constant ORACLE_CHANGE_QUEUED_TOPIC0 =
        uint256(keccak256("OracleChangeQueued(bytes32,address,uint256)"));

    /// @notice keccak256("AnswerUpdated(int256,uint256,uint256)") —
    /// Chainlink's own standard AggregatorV3 event:
    /// `event AnswerUpdated(int256 indexed current, uint256 indexed
    /// roundId, uint256 updatedAt)`. NOTE: `current` (the price) is
    /// INDEXED — it arrives in `topic1`, not in `data`. Verified against
    /// Chainlink's real, standard event signature; getting this backwards
    /// (reading from `data` instead) was an actual bug caught during
    /// development, before ever touching a testnet.
    uint256 public constant CHAINLINK_ANSWER_UPDATED_TOPIC0 =
        uint256(keccak256("AnswerUpdated(int256,uint256,uint256)"));

    /// @notice The Sepolia chain ID, used both for the subscription's
    /// origin and the callback's destination.
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;

    /// @notice Basis-point threshold beyond which a single Chainlink
    /// price update is considered anomalous enough to trigger a pause.
    /// Documented as a tunable, not-yet-backtested constant — same
    /// "calibrated, not proven optimal" caveat applied to every other
    /// threshold in this project.
    uint256 public constant ANOMALY_THRESHOLD_BPS = 1000; // 10%

    /// @notice Whoever deployed this contract — the only address allowed
    /// to complete the destination-wiring step below.
    address public immutable owner;

    /// @notice The destination contract on Sepolia that will actually
    /// receive our callback and call `guardianPause()`. Zero until
    /// `setDestinationCallback` is called — see deployment-ordering note
    /// above.
    address public callbackReceiver;

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
    /// percentage jump.
    int256 public lastSeenAnswer;
    bool public hasSeenFirstAnswer;

    event GuardianTriggered(string reason, uint256 timestamp);
    event DestinationCallbackSet(address indexed callbackReceiver);

    constructor(
        address watchedHook_,
        address watchedOracle_,
        address poolCurrency0_,
        address poolCurrency1_,
        uint24 poolFee_,
        int24 poolTickSpacing_
    ) payable {
        owner = msg.sender;
        watchedHook = watchedHook_;
        watchedOracle = watchedOracle_;
        poolCurrency0 = poolCurrency0_;
        poolCurrency1 = poolCurrency1_;
        poolFee = poolFee_;
        poolTickSpacing = poolTickSpacing_;

        SYSTEM.subscribe(
            SEPOLIA_CHAIN_ID,
            watchedHook_,
            ORACLE_CHANGE_QUEUED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        SYSTEM.subscribe(
            SEPOLIA_CHAIN_ID,
            watchedOracle_,
            CHAINLINK_ANSWER_UPDATED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Completes deployment wiring — see the deployment-ordering
    /// NatSpec above. Settable exactly once: a guardian whose destination
    /// could be silently redirected later by a compromised deployer key
    /// would defeat the point of an independent safety mechanism.
    function setDestinationCallback(address callbackReceiver_) external {
        require(msg.sender == owner, "OracleGuardianReactive: not owner");
        require(callbackReceiver == address(0), "OracleGuardianReactive: already set");
        callbackReceiver = callbackReceiver_;
        emit DestinationCallbackSet(callbackReceiver_);
    }

    /// @notice Entry point called by the Reactive system contract
    /// whenever a subscribed event fires.
    function react(LogRecord calldata log_) external onlySystem {
        // Safely no-op until deployment wiring is complete — see
        // deployment-ordering NatSpec above. Not an error state; just an
        // expected, temporary condition right after this contract is
        // first deployed.
        if (callbackReceiver == address(0)) {
            return;
        }

        if (log_.topic0 == ORACLE_CHANGE_QUEUED_TOPIC0 && log_.contractAddress == watchedHook) {
            _requestPause("OracleChangeQueued detected");
            return;
        }

        if (log_.topic0 == CHAINLINK_ANSWER_UPDATED_TOPIC0 && log_.contractAddress == watchedOracle) {
            // Price is INDEXED (topic1), not in data — see
            // CHAINLINK_ANSWER_UPDATED_TOPIC0's NatSpec.
            int256 newAnswer = int256(log_.topic1);

            if (hasSeenFirstAnswer && lastSeenAnswer != 0) {
                uint256 diff;
                if (newAnswer > lastSeenAnswer) {
                    // Safe: newAnswer > lastSeenAnswer in this branch, so
                    // the subtraction is always non-negative before cast.
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
    /// Sepolia. The first payload argument is a placeholder address —
    /// per reactive-lib-omni's documented convention, the callback proxy
    /// injects our real address there for the destination contract's
    /// `onlyCallbackSender` check, overwriting whatever we encode here.
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

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: SEPOLIA_CHAIN_ID,
                recipient: callbackReceiver,
                gasLimit: 500_000,
                payload: payload
            })
        );
    }
}