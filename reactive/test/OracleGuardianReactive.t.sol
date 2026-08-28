// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {OracleGuardianReactive} from "../src/OracleGuardianReactive.sol";
import {OracleGuardianCallback} from "../src/OracleGuardianCallback.sol";
import {IReactive} from "reactive-lib-omni/src/interfaces/IReactive.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";

contract OracleGuardianReactiveTest is Test {
    address constant SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;

    OracleGuardianReactive guardian;
    MockSystemContract mockSystem;

    address hookAddr = address(0xA11CE);
    address oracleAddr = address(0xFEED);
    address currency0 = address(0);
    address currency1 = address(0xB0B);
    uint24 fee = 8_388_608; // DYNAMIC_FEE_FLAG
    int24 tickSpacing = 60;

    function setUp() public {
        // Deploy our mock at the real, hardcoded SYSTEM address the
        // library expects, so AbstractReactive's calls to SYSTEM.subscribe
        // and SYSTEM.requestCallbackV_1_0 resolve to our mock rather than
        // reverting against an empty address — the same vm.etch technique
        // used throughout our BallastHook tests for injecting known,
        // controllable state at a specific address.
        MockSystemContract impl = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(impl).code);
        mockSystem = MockSystemContract(payable(SYSTEM_ADDR));

        guardian = new OracleGuardianReactive(hookAddr, oracleAddr, currency0, currency1, fee, tickSpacing);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Constructor: must subscribe to exactly the two event sources we
    // designed for — proving the actual subscription calls happen, not
    // just that the constructor doesn't revert.
    // ─────────────────────────────────────────────────────────────────────

    function test_constructor_subscribesToBothEventSources() public {
        assertEq(mockSystem.subscriptionCount(), 2);

        (uint256 chainId0, address contract0,,,,) = mockSystem.subscriptions(0);
        assertEq(chainId0, 11155111);
        assertEq(contract0, hookAddr, "First subscription should watch the hook");

        (uint256 chainId1, address contract1,,,,) = mockSystem.subscriptions(1);
        assertEq(chainId1, 11155111);
        assertEq(contract1, oracleAddr, "Second subscription should watch the oracle feed");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Deployment-order safety: react() must NOT revert and must NOT fire a
    // callback before setDestinationCallback has been called — this is a
    // real, designed state (see contract NatSpec), not an oversight.
    // ─────────────────────────────────────────────────────────────────────

    function test_react_beforeDestinationSet_doesNotFireCallback() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chainId: 11155111,
            contractAddress: hookAddr,
            topic0: uint256(keccak256("OracleChangeQueued(bytes32,address,uint256)")),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });

        vm.prank(SYSTEM_ADDR);
        guardian.react(log);

        assertEq(mockSystem.callbackRequestCount(), 0, "Must not fire a callback before destination is configured");
    }

    // ─────────────────────────────────────────────────────────────────────
    // setDestinationCallback: settable exactly once, by the owner only.
    // ─────────────────────────────────────────────────────────────────────

    function test_setDestinationCallback_revertsForNonOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("OracleGuardianReactive: not owner"));
        guardian.setDestinationCallback(address(0xCAFE));
    }

    function test_setDestinationCallback_revertsIfAlreadySet() public {
        guardian.setDestinationCallback(address(0xCAFE));
        vm.expectRevert(bytes("OracleGuardianReactive: already set"));
        guardian.setDestinationCallback(address(0xD00D));
    }

    // ─────────────────────────────────────────────────────────────────────
    // Trigger 1: an OracleChangeQueued event must fire a callback
    // unconditionally, once destination is configured.
    // ─────────────────────────────────────────────────────────────────────

    function test_react_onOracleChangeQueued_firesCallback() public {
        guardian.setDestinationCallback(address(0xCAFE));

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chainId: 11155111,
            contractAddress: hookAddr,
            topic0: uint256(keccak256("OracleChangeQueued(bytes32,address,uint256)")),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });

        vm.prank(SYSTEM_ADDR);
        guardian.react(log);

        assertEq(mockSystem.callbackRequestCount(), 1);
        (uint256 chainId, address recipient,,) = mockSystem.callbackRequests(0);
        assertEq(chainId, 11155111);
        assertEq(recipient, address(0xCAFE));
    }

    // ─────────────────────────────────────────────────────────────────────
    // Trigger 2: an anomalous single-update price jump must fire a
    // callback — and, critically, a NORMAL price update must NOT.
    // ─────────────────────────────────────────────────────────────────────

    function test_react_onAnomalousPriceJump_firesCallback() public {
        guardian.setDestinationCallback(address(0xCAFE));

        // First update establishes the baseline — no prior price to
        // compare against, so no callback should fire yet.
        _sendAnswerUpdated(int256(3000 * 10 ** 8));
        assertEq(mockSystem.callbackRequestCount(), 0, "First-ever price update should not trigger a false alarm");

        // A jump from 3000 to 3400 is a ~13.3% single-update change,
        // above our 10% ANOMALY_THRESHOLD_BPS — should trigger.
        _sendAnswerUpdated(int256(3400 * 10 ** 8));
        assertEq(mockSystem.callbackRequestCount(), 1, "A >10% single-update jump should trigger the guardian");
    }

    function test_react_onNormalPriceMovement_doesNotFireCallback() public {
        guardian.setDestinationCallback(address(0xCAFE));

        _sendAnswerUpdated(int256(3000 * 10 ** 8));
        // A move from 3000 to 3050 is under 2% — well below threshold.
        _sendAnswerUpdated(int256(3050 * 10 ** 8));

        assertEq(mockSystem.callbackRequestCount(), 0, "A small, ordinary price movement must not trigger a false alarm");
    }

    function _sendAnswerUpdated(int256 price) internal {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chainId: 11155111,
            contractAddress: oracleAddr,
            topic0: uint256(keccak256("AnswerUpdated(int256,uint256,uint256)")),
            // Safe: test-only prices are always small positive values;
            // the real contract reverses this cast identically via
            // int256(log_.topic1), so this must round-trip correctly.
            // forge-lint: disable-next-line(unsafe-typecast)
            topic1: uint256(price),
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });

        vm.prank(SYSTEM_ADDR);
        guardian.react(log);
    }
}