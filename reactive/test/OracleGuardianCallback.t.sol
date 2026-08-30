// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleGuardianCallback, PoolKeyLite} from "../src/OracleGuardianCallback.sol";

/// @notice Minimal mock hook, standing in for BallastHook.
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

contract OracleGuardianCallbackTest is Test {
    OracleGuardianCallback callbackContract;
    MockHook mockHook;

    address callbackProxy = address(0xBEEF); // stand-in for the real Sepolia callback proxy
    address deployerAddr = address(this); // this test contract IS the deployer

    function setUp() public {
        mockHook = new MockHook();
        // Deployed BY this test contract, so rvm_id == address(this) —
        // matching this library's real convention.
        callbackContract = new OracleGuardianCallback(callbackProxy, address(mockHook));
    }

    function test_pause_revertsIfCallerIsNotAuthorizedSender() public {
        vm.prank(address(0xBAD1));
        vm.expectRevert(bytes("Authorized sender only"));
        callbackContract.pause(deployerAddr, address(0), address(0xB0B), 8_388_608, 60, "test");
    }

    function test_pause_revertsIfRvmIdDoesNotMatch() public {
        vm.prank(callbackProxy);
        vm.expectRevert(bytes("Authorized RVM ID only"));
        callbackContract.pause(address(0xBAD1D), address(0), address(0xB0B), 8_388_608, 60, "test");
    }

    function test_pause_succeedsWhenBothChecksPass() public {
        assertFalse(mockHook.wasPaused());

        vm.prank(callbackProxy);
        callbackContract.pause(deployerAddr, address(0), address(0xB0B), 8_388_608, 60, "test reason");

        assertTrue(mockHook.wasPaused(), "Hook should have been paused");
        assertEq(mockHook.lastCurrency0(), address(0));
        assertEq(mockHook.lastCurrency1(), address(0xB0B));
    }
}