// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {BallastHook} from "../../src/BallastHook.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @title BallastHookForkTest
/// @notice Replays real reads and view-calls against REAL, live Sepolia
/// state — the actual deployed PoolManager, the actual deployed
/// BallastHook, the actual live Chainlink feed — rather than a freshly
/// constructed local test deployment. This proves the contract behaves
/// correctly against genuine on-chain conditions, not just a clean-room
/// environment.
///
/// HOW TO RUN THIS (requires a real Sepolia RPC — cannot run offline):
///   forge test --match-path 'test/fork/*' --fork-url $SEPOLIA_RPC_URL -vvv
///
/// NOTE: these are read-only / view-call tests deliberately — they don't
/// submit real transactions, so running them costs no gas and is safe to
/// run repeatedly.
contract BallastHookForkTest is Test {
    // Real, live, already-deployed Sepolia addresses.
    address constant HOOK = 0xB629809f97Fc458A0266f00e5Fa28850716bA0C4;
    address constant DEMO_TOKEN = 0x11aFe39b01189774a5D11f041BB55dfc888098B0;
    address constant ORACLE = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    uint24 constant FEE = 8_388_608; // DYNAMIC_FEE_FLAG
    int24 constant TICK_SPACING = 60;

    BallastHook hook;
    PoolKey key;

    function setUp() public {
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string(""));
        require(bytes(rpcUrl).length > 0, "Set SEPOLIA_RPC_URL to run fork tests");
        vm.createSelectFork(rpcUrl);

        hook = BallastHook(payable(HOOK));
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(DEMO_TOKEN),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });
    }

    /// @notice Proves the real, deployed Chainlink oracle can actually be
    /// read live and returns a sane, non-degenerate ETH/USD price — not
    /// a mock, not an assumption.
    function test_fork_realOracle_returnsPlausiblePrice() public view {
        IAggregatorV3 oracle = IAggregatorV3(ORACLE);
        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        uint8 decimals = oracle.decimals();

        assertGt(answer, 0, "Oracle should report a positive price");
        assertGt(updatedAt, 0, "Oracle should have a real update timestamp");

        // Loose sanity bound: ETH/USD has not plausibly been below $100
        // or above $50,000 at any point relevant to this project — this
        // would only fail if something were fundamentally wrong with
        // which feed we're reading, not a precise price prediction.
        // Safe: answer was just confirmed > 0 above, so this cast from
        // int256 to uint256 cannot lose or misrepresent the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(answer) / (10 ** decimals);
        assertGt(price, 100, "Oracle price implausibly low - wrong feed?");
        assertLt(price, 50_000, "Oracle price implausibly high - wrong feed?");

        console.log("Live ETH/USD price read from the real Sepolia Chainlink feed:", price);
    }

    /// @notice Proves previewFee() runs correctly against REAL, live pool
    /// state (real liquidity, real current price) — the actual state our
    /// deployed contract is operating against right now, not a freshly
    /// constructed test pool.
    function test_fork_previewFee_worksAgainstRealLiveState() public view {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint24 fee = hook.previewFee(key, params);

        assertGe(fee, hook.DISCOUNTED_FEE(), "Fee must respect the real, deployed contract's floor");
        assertLe(fee, hook.MAX_SURCHARGE_FEE(), "Fee must respect the real, deployed contract's ceiling");

        console.log("previewFee() computed against real live Sepolia state:", fee);
    }

    /// @notice Proves the pool is in its expected, un-paused operating
    /// state — the real, live condition documented in this project's
    /// README after OracleGuardian testing.
    function test_fork_hookIsNotCurrentlyPaused() public view {
        PoolId poolId = _toId(key);
        assertFalse(hook.paused(poolId), "Pool should be in its normal, un-paused operating state");
    }

    /// @notice Proves the real, registered guardian is genuinely a
    /// deployed contract (OracleGuardianCallback), not a placeholder or
    /// an EOA — a real, checkable fact about live production state.
    function test_fork_guardianIsRealDeployedContract() public view {
        PoolId poolId = _toId(key);
        address guardian = hook.guardian(poolId);
        assertTrue(guardian.code.length > 0, "Guardian should be a real deployed contract, not an EOA");
        console.log("Real, live guardian contract confirmed at:", guardian);
    }

    function _toId(PoolKey memory k) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(k)));
    }
}
