// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {OracleGuardianCallback, PoolKeyLite} from "../src/OracleGuardianCallback.sol";
import {IPayable} from "reactive-lib-omni/src/interfaces/IPayable.sol";
import {AbstractPayer} from "reactive-lib-omni/src/base/AbstractPayer.sol";

/// @notice Minimal mock hook, standing in for BallastHook, so these tests
/// exercise OracleGuardianCallback's own logic (authentication + the pause
/// call it makes) without needing v4-core at all — consistent with why
/// OracleGuardianCallback itself avoids importing v4-core.
contract MockHook {
    bool public wasPaused;
    address public lastCurrency0;
    address public lastCurrency1;

    function guardianPause(PoolKeyLite calldata key) external {
        wasPaused = true;
        lastCurrency0 = key.currency0;
        lastCurrency1 = key.currency1;
    }
}

/// @notice Minimal mock callback proxy — just needs to satisfy IPayable so
/// AbstractPayer's constructor accepts it as the service provider.
contract MockCallbackProxy is IPayable {
    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

contract OracleGuardianCallbackTest is Test {
    OracleGuardianCallback callbackContract;
    MockHook mockHook;
    MockCallbackProxy mockProxy;

    address reactiveContract = address(0xABCD); // stand-in for OracleGuardianReactive's real Lasna address

    function setUp() public {
        mockHook = new MockHook();
        mockProxy = new MockCallbackProxy();
        callbackContract =
            new OracleGuardianCallback(IPayable(payable(address(mockProxy))), reactiveContract, address(mockHook));
    }

    // ─────────────────────────────────────────────────────────────────────
    // Layer 1: msg.sender must be the callback proxy (onlyServiceProvider,
    // inherited from AbstractPayer). Even a call with a perfectly correct
    // rvmId must still be rejected if it doesn't come from the proxy.
    // ─────────────────────────────────────────────────────────────────────

    function test_pause_revertsIfCallerIsNotCallbackProxy() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(0xBEEF), address(mockProxy)));
        callbackContract.pause(reactiveContract, address(0), address(0xB0B), 8_388_608, 60, "test");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Layer 2: the injected rvmId parameter must match the real
    // OracleGuardianReactive address, even if the caller IS the correct
    // proxy. This is the exact check that protects against a malicious or
    // compromised proxy-adjacent actor forging a pause instruction claiming
    // to originate from a DIFFERENT reactive contract.
    // ─────────────────────────────────────────────────────────────────────

    function test_pause_revertsIfRvmIdDoesNotMatch() public {
        address wrongRvmId = address(0xBAD1D);
        vm.prank(address(mockProxy));
        vm.expectRevert(
            abi.encodeWithSignature("CallbackNotAuthorized(address,address)", wrongRvmId, reactiveContract)
        );
        callbackContract.pause(wrongRvmId, address(0), address(0xB0B), 8_388_608, 60, "test");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Both layers satisfied: the pause must actually go through and call
    // the hook correctly — proving the real, intended path works, not just
    // that the wrong paths correctly fail.
    // ─────────────────────────────────────────────────────────────────────

    function test_pause_succeedsWhenBothChecksPass() public {
        assertFalse(mockHook.wasPaused());

        vm.prank(address(mockProxy));
        callbackContract.pause(reactiveContract, address(0), address(0xB0B), 8_388_608, 60, "test reason");

        assertTrue(mockHook.wasPaused(), "Hook should have been paused");
        assertEq(mockHook.lastCurrency0(), address(0));
        assertEq(mockHook.lastCurrency1(), address(0xB0B));
    }
}