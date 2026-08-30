// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {OracleGuardianReactive} from "../src/OracleGuardianReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";

/// @notice Reactive contracts genuinely deploy to TWO separate places with
/// the same bytecode: the main Reactive Network (where SERVICE_ADDR has
/// real code, so `vm` resolves false, and subscriptions fire) and the
/// ReactVM (where SERVICE_ADDR has NO code, so `vm` resolves true, and
/// react() is callable). We test both real behaviors by deploying two
/// separate instances under each condition.
contract OracleGuardianReactiveTest is Test {
    address constant SERVICE_ADDR = 0x0000000000000000000000000000000000fffFfF;
    bytes32 constant CALLBACK_TOPIC = keccak256("Callback(uint256,address,uint64,bytes)");

    address callbackReceiver = address(0xCAFE);
    address hookAddr = address(0xA11CE);
    address oracleAddr = address(0xFEED);
    address currency0 = address(0);
    address currency1 = address(0xB0B);
    uint24 fee = 8_388_608; // DYNAMIC_FEE_FLAG
    int24 tickSpacing = 60;

    MockSystemContract mockSystem;

    function setUp() public {
        MockSystemContract impl = new MockSystemContract();
        vm.etch(SERVICE_ADDR, address(impl).code);
        mockSystem = MockSystemContract(payable(SERVICE_ADDR));
    }

    function _deployNetworkInstance() internal returns (OracleGuardianReactive) {
        return new OracleGuardianReactive(
            callbackReceiver, hookAddr, oracleAddr, currency0, currency1, fee, tickSpacing
        );
    }

    /// @notice Deploys a "ReactVM instance" by temporarily removing
    /// SERVICE_ADDR's code so `vm` resolves true at construction time,
    /// matching the real ReactVM environment, then restores it.
    function _deployVmInstance() internal returns (OracleGuardianReactive) {
        vm.etch(SERVICE_ADDR, "");
        OracleGuardianReactive guardian = new OracleGuardianReactive(
            callbackReceiver, hookAddr, oracleAddr, currency0, currency1, fee, tickSpacing
        );
        vm.etch(SERVICE_ADDR, address(mockSystem).code);
        return guardian;
    }

    function test_constructor_subscribesToBothEventSources() public {
        _deployNetworkInstance();

        assertEq(mockSystem.subscriptionCount(), 2);

        (uint256 chainId0, address contract0,,,,) = mockSystem.subscriptions(0);
        assertEq(chainId0, 11155111);
        assertEq(contract0, hookAddr, "First subscription should watch the hook");

        (uint256 chainId1, address contract1,,,,) = mockSystem.subscriptions(1);
        assertEq(chainId1, 11155111);
        assertEq(contract1, oracleAddr, "Second subscription should watch the oracle feed");
    }

    function test_callbackReceiver_isSetImmediatelyAndCorrectly() public {
        OracleGuardianReactive networkInstance = _deployNetworkInstance();
        assertEq(networkInstance.callbackReceiver(), callbackReceiver);

        OracleGuardianReactive vmInstance = _deployVmInstance();
        assertEq(
            vmInstance.callbackReceiver(),
            callbackReceiver,
            "Immutable config must be identical across both instances"
        );
    }

    function test_react_onOracleChangeQueued_emitsCallback() public {
        OracleGuardianReactive guardian = _deployVmInstance();

        IReactive.LogRecord memory log = _makeLog(hookAddr, keccak256("OracleChangeQueued(bytes32,address,uint256)"), 0);

        vm.recordLogs();
        guardian.react(log);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == CALLBACK_TOPIC) {
                found = true;
                assertEq(uint256(logs[i].topics[1]), 11155111);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), callbackReceiver);
            }
        }
        assertTrue(found, "Expected a Callback event to be emitted");
    }

    function test_react_onAnomalousPriceJump_emitsCallback() public {
        OracleGuardianReactive guardian = _deployVmInstance();

        vm.recordLogs();
        guardian.react(_makeLog(oracleAddr, keccak256("AnswerUpdated(int256,uint256,uint256)"), uint256(int256(3000 * 10 ** 8))));
        assertFalse(_emittedCallback(), "First-ever price update should not trigger a false alarm");

        vm.recordLogs();
        guardian.react(_makeLog(oracleAddr, keccak256("AnswerUpdated(int256,uint256,uint256)"), uint256(int256(3400 * 10 ** 8))));
        assertTrue(_emittedCallback(), "A >10% single-update jump should trigger the guardian");
    }

    function test_react_onNormalPriceMovement_doesNotEmitCallback() public {
        OracleGuardianReactive guardian = _deployVmInstance();

        vm.recordLogs();
        guardian.react(_makeLog(oracleAddr, keccak256("AnswerUpdated(int256,uint256,uint256)"), uint256(int256(3000 * 10 ** 8))));

        vm.recordLogs();
        guardian.react(_makeLog(oracleAddr, keccak256("AnswerUpdated(int256,uint256,uint256)"), uint256(int256(3050 * 10 ** 8))));
        assertFalse(_emittedCallback(), "A small, ordinary price movement must not trigger a false alarm");
    }

    function _makeLog(address contractAddr, bytes32 topic0, uint256 topic1) internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: 11155111,
            _contract: contractAddr,
            topic_0: uint256(topic0),
            topic_1: topic1,
            topic_2: 0,
            topic_3: 0,
            data: "",
            block_number: 1,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _emittedCallback() internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == CALLBACK_TOPIC) {
                return true;
            }
        }
        return false;
    }
}