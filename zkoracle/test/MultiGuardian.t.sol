// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {MultiGuardian, PoolKeyLite} from "../src/MultiGuardian.sol";

contract MockHook {
    bool public wasPaused;
    address public lastCaller;

    function guardianPause(PoolKeyLite calldata) external {
        wasPaused = true;
        lastCaller = msg.sender;
    }
}

contract MultiGuardianTest is Test {
    MultiGuardian multiGuardian;
    MockHook mockHook;

    address reactiveGuardian = address(0xAAAA);
    address zkGuardian = address(0xBBBB);
    address unauthorizedCaller = address(0xBAD);

    PoolKeyLite key;

    function setUp() public {
        mockHook = new MockHook();
        address[] memory initial = new address[](2);
        initial[0] = reactiveGuardian;
        initial[1] = zkGuardian;
        multiGuardian = new MultiGuardian(address(mockHook), initial);

        key = PoolKeyLite({
            currency0: address(0),
            currency1: address(0xB0B),
            fee: 8_388_608,
            tickSpacing: 60,
            hooks: address(mockHook)
        });
    }

    function test_bothInitialGuardians_areAuthorized() public view {
        assertTrue(multiGuardian.isAuthorizedSubGuardian(reactiveGuardian));
        assertTrue(multiGuardian.isAuthorizedSubGuardian(zkGuardian));
    }

    function test_reactiveGuardian_canTriggerRealPause() public {
        vm.prank(reactiveGuardian);
        multiGuardian.guardianPause(key);

        assertTrue(mockHook.wasPaused());
        assertEq(mockHook.lastCaller(), address(multiGuardian), "Hook should see MultiGuardian as the caller, not the sub-guardian directly");
    }

    function test_zkGuardian_canAlsoTriggerRealPause() public {
        vm.prank(zkGuardian);
        multiGuardian.guardianPause(key);

        assertTrue(mockHook.wasPaused());
    }

    function test_unauthorizedCaller_cannotTriggerPause() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert(bytes("MultiGuardian: caller is not an authorized sub-guardian"));
        multiGuardian.guardianPause(key);

        assertFalse(mockHook.wasPaused());
    }

    function test_owner_canAuthorizeANewSubGuardian() public {
        address newGuardian = address(0xCCCC);
        assertFalse(multiGuardian.isAuthorizedSubGuardian(newGuardian));

        multiGuardian.authorizeSubGuardian(newGuardian); // test contract is the owner (deployer)
        assertTrue(multiGuardian.isAuthorizedSubGuardian(newGuardian));

        vm.prank(newGuardian);
        multiGuardian.guardianPause(key);
        assertTrue(mockHook.wasPaused());
    }

    function test_nonOwner_cannotAuthorizeANewSubGuardian() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert(bytes("MultiGuardian: not owner"));
        multiGuardian.authorizeSubGuardian(address(0xCCCC));
    }

    function test_owner_canRevokeASubGuardian() public {
        multiGuardian.revokeSubGuardian(reactiveGuardian);
        assertFalse(multiGuardian.isAuthorizedSubGuardian(reactiveGuardian));

        vm.prank(reactiveGuardian);
        vm.expectRevert(bytes("MultiGuardian: caller is not an authorized sub-guardian"));
        multiGuardian.guardianPause(key);
    }

    function test_revokingOneGuardian_doesNotAffectTheOther() public {
        multiGuardian.revokeSubGuardian(reactiveGuardian);

        vm.prank(zkGuardian);
        multiGuardian.guardianPause(key);
        assertTrue(mockHook.wasPaused(), "The remaining authorized guardian should still work");
    }
}
