// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice ABI-compatible mirror of Uniswap v4's PoolKey — see
/// OracleGuardianCallback.sol and ZKPriceGuardian.sol for the same,
/// established rationale used throughout this project.
struct PoolKeyLite {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IBallastHookLite {
    function guardianPause(PoolKeyLite calldata key) external;
}

/// @title MultiGuardian
/// @notice BallastHook supports exactly ONE registered guardian address
/// per pool. This contract IS that one registered guardian, and relays
/// pause authority from MULTIPLE independent underlying safety layers —
/// currently OracleGuardianCallback (Reactive Network-based, fast,
/// fully autonomous) and ZKPriceGuardian (zkTLS-based, independently
/// trust-verified, scheduled) — each of which can trigger a real pause
/// through this single point, without either layer needing to know
/// about the other.
///
/// WHY THIS EXISTS: the two layers protect against genuinely different
/// failure modes (see this project's README/MATH.md for the full
/// comparison) — neither is strictly stronger than the other, so both
/// should be able to act independently. This contract makes that
/// possible without changing BallastHook's own one-guardian design.
///
/// TRUST MODEL: only pre-authorized sub-guardian addresses can trigger
/// a pause through this contract — an arbitrary caller cannot. Like
/// every guardian in this project, MultiGuardian itself can only ever
/// PAUSE, never resume, change the oracle, or touch funds.
contract MultiGuardian {
    address public immutable hook;
    address public immutable owner;

    mapping(address => bool) public isAuthorizedSubGuardian;

    event SubGuardianAuthorized(address indexed subGuardian);
    event SubGuardianRevoked(address indexed subGuardian);
    event PauseRelayed(address indexed fromSubGuardian);

    constructor(address hook_, address[] memory initialSubGuardians) {
        hook = hook_;
        owner = msg.sender;
        for (uint256 i = 0; i < initialSubGuardians.length; i++) {
            isAuthorizedSubGuardian[initialSubGuardians[i]] = true;
            emit SubGuardianAuthorized(initialSubGuardians[i]);
        }
    }

    /// @notice Adds a new authorized sub-guardian — e.g. a future,
    /// additional independent safety layer this project adds later.
    /// Owner-gated: adding a NEW pause-triggering path is exactly the
    /// kind of change that deserves a deliberate, human decision, not
    /// something any existing sub-guardian could grant itself.
    function authorizeSubGuardian(address subGuardian) external {
        require(msg.sender == owner, "MultiGuardian: not owner");
        isAuthorizedSubGuardian[subGuardian] = true;
        emit SubGuardianAuthorized(subGuardian);
    }

    function revokeSubGuardian(address subGuardian) external {
        require(msg.sender == owner, "MultiGuardian: not owner");
        isAuthorizedSubGuardian[subGuardian] = false;
        emit SubGuardianRevoked(subGuardian);
    }

    /// @notice Called by an authorized sub-guardian (matching the exact
    /// same function signature BallastHook itself expects, so
    /// OracleGuardianCallback and ZKPriceGuardian need zero code changes
    /// beyond being deployed with THIS contract's address as their
    /// "hook" — they don't need to know they're calling a relay rather
    /// than the real hook directly).
    function guardianPause(PoolKeyLite calldata key) external {
        require(isAuthorizedSubGuardian[msg.sender], "MultiGuardian: caller is not an authorized sub-guardian");
        IBallastHookLite(hook).guardianPause(key);
        emit PauseRelayed(msg.sender);
    }
}
