// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice A malicious ERC20 with a transfer hook that attempts to
/// re-enter an arbitrary target contract during transfer() — simulating
/// a real, non-standard token (e.g. ERC777-style, or a deliberately
/// malicious one) used as a pool currency, to adversarially test
/// whether BallastHook's reserve-skim logic is actually exploitable
/// during the window between its poolManager.take() call and its
/// subsequent pendingReserve state update (see BallastHook.sol's
/// _afterSwap — the external call and the state update are NOT in
/// strict Checks-Effects-Interactions order there).
contract MaliciousReentrantToken is MockERC20 {
    address public reentryTarget;
    bytes public reentryCalldata;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor() MockERC20("Malicious", "EVIL", 18) {}

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryCalldata = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _tryReenter();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _tryReenter();
        return super.transferFrom(from, to, amount);
    }

    function _tryReenter() internal {
        if (reentryTarget != address(0) && !reentryAttempted) {
            reentryAttempted = true;
            (bool success,) = reentryTarget.call(reentryCalldata);
            reentrySucceeded = success;
        }
    }
}
