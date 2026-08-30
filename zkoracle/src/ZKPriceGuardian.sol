// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Reclaim} from "@reclaimprotocol/verifier-solidity-sdk/contracts/Reclaim.sol";
import {IAggregatorV3} from "./IAggregatorV3Lite.sol";

/// @notice ABI-compatible mirror of Uniswap v4's PoolKey — see
/// OracleGuardianCallback.sol in this project's reactive/ folder for
/// the identical, established rationale: Solidity ABI-encodes structs
/// by field layout, not nominal type identity, so this calls the real,
/// deployed BallastHook correctly without needing v4-core's own types
/// (which are pinned to a different Solidity version than Reclaim's
/// contracts require here).
struct PoolKeyLite {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IBallastHookLite {
    function guardianPause(PoolKeyLite calldata key) external;
    function priceFeeds(bytes32 poolId) external view returns (address);
}

/// @title ZKPriceGuardian
/// @notice Ballast's third oracle-safety layer, WITH REAL AUTHORITY:
/// verifies a real zkTLS proof (via Reclaim) that a specific price was
/// genuinely returned by CoinGecko's live API, compares it against
/// Chainlink's currently-reported price for the same pool, and — if
/// they diverge beyond a set threshold — actually pauses the pool,
/// exactly the same real authority OracleGuardianCallback has.
///
/// WHY THIS EXISTS, PRECISELY: our first version (ZKPriceAttestor)
/// proved the harder cryptographic half — that a price genuinely came
/// from where it claims to — but had no actual authority to protect
/// anything. This version gives it real teeth: an independent,
/// cryptographically-verified price source that can genuinely trigger
/// a real pause if Chainlink's reported price looks wrong, without
/// trusting Chainlink's own node network to police itself.
///
/// HONEST SCOPE: this is NOT, and should never be, part of the
/// same-transaction MEV-defense mechanism (Signal 1 / Signal 2) — a
/// zkTLS proof takes real time to generate off-chain and cannot react
/// within a single atomic swap. This is correctly scoped as a slower,
/// independent safety net, the same category as the 24-hour timelock
/// and OracleGuardian's cross-chain pause, not a same-block defense.
contract ZKPriceGuardian {
    address public constant RECLAIM_VERIFIER = 0xAe94FB09711e1c6B057853a515483792d8e474d0;

    string public constant EXPECTED_URL =
        "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd";

    /// @notice How far (in basis points) the zkTLS-attested price may
    /// diverge from Chainlink's reported price before this contract
    /// pauses the pool. Documented as a tunable, not-yet-backtested
    /// constant — same honesty standard as every other threshold in
    /// this project (see CALIBRATION.md).
    uint256 public constant DIVERGENCE_THRESHOLD_BPS = 500; // 5%

    /// @notice The REAL BallastHook — used ONLY to read the currently
    /// configured Chainlink feed for comparison. This must be the
    /// actual hook, since it's the only contract that has real oracle
    /// configuration data.
    address public immutable realHook;

    /// @notice The address `guardianPause()` is actually called on —
    /// this is where MultiGuardian goes, NOT the real hook directly,
    /// so the pause is correctly relayed and authorized alongside other
    /// independent guardian layers.
    ///
    /// WHY TWO SEPARATE ADDRESSES (a real bug, found and fixed): an
    /// earlier version of this contract used a single `hook` address
    /// for both purposes. When deployed pointing that one address at
    /// MultiGuardian (correct for pausing), the price-feed READ silently
    /// broke, since MultiGuardian has no `priceFeeds()` function at all
    /// — confirmed directly via a real, reverted on-chain transaction,
    /// not caught in testing beforehand. Two separate, clearly-named
    /// addresses make this class of mistake structurally impossible.
    address public immutable pauseTarget;

    struct Attestation {
        string priceStr;
        uint256 priceScaled8; // parsed, scaled to 8 decimals to match Chainlink's convention
        uint256 timestampS;
        bytes32 identifier;
    }

    Attestation public latestAttestation;

    event PriceAttested(string priceStr, uint256 priceScaled8, uint256 timestampS, bytes32 identifier);
    event DivergenceChecked(uint256 zkPriceScaled8, int256 chainlinkPrice, uint256 divergenceBps, bool paused);

    constructor(address realHook_, address pauseTarget_) {
        realHook = realHook_;
        pauseTarget = pauseTarget_;
    }

    /// @notice Verifies a real zkTLS proof, records the attested price,
    /// then immediately checks it against Chainlink's current price for
    /// the given pool — pausing the pool if they diverge too much.
    function submitProofAndCheck(Reclaim.Proof memory proof, string memory claimedPriceStr, PoolKeyLite calldata key)
        external
    {
        Reclaim(RECLAIM_VERIFIER).verifyProof(proof);

        require(
            _contains(proof.claimInfo.parameters, EXPECTED_URL),
            "ZKPriceGuardian: proof is not for the expected CoinGecko endpoint"
        );

        string memory expectedFragment = string(abi.encodePacked('"price":"', claimedPriceStr, '"'));
        require(
            _contains(proof.claimInfo.context, expectedFragment),
            "ZKPriceGuardian: claimed price does not match the verified proof"
        );

        uint256 priceScaled8 = _parsePriceToScaled8(claimedPriceStr);

        latestAttestation = Attestation({
            priceStr: claimedPriceStr,
            priceScaled8: priceScaled8,
            timestampS: proof.signedClaim.claim.timestampS,
            identifier: proof.signedClaim.claim.identifier
        });

        emit PriceAttested(
            claimedPriceStr, priceScaled8, proof.signedClaim.claim.timestampS, proof.signedClaim.claim.identifier
        );

        _checkDivergenceAndPause(priceScaled8, key);
    }

    function _checkDivergenceAndPause(uint256 zkPriceScaled8, PoolKeyLite calldata key) internal {
        bytes32 poolId = keccak256(abi.encode(key));
        address feedAddr = IBallastHookLite(realHook).priceFeeds(poolId);
        if (feedAddr == address(0)) return; // no oracle configured yet — nothing to compare against

        (, int256 chainlinkPrice,,,) = IAggregatorV3(feedAddr).latestRoundData();
        if (chainlinkPrice <= 0) return; // an invalid Chainlink reading isn't this contract's concern to interpret

        // Safe: chainlinkPrice was just confirmed > 0 above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 chainlinkPriceAbs = uint256(chainlinkPrice);
        uint256 diff = zkPriceScaled8 > chainlinkPriceAbs
            ? zkPriceScaled8 - chainlinkPriceAbs
            : chainlinkPriceAbs - zkPriceScaled8;
        uint256 divergenceBps = (diff * 10_000) / chainlinkPriceAbs;

        bool shouldPause = divergenceBps >= DIVERGENCE_THRESHOLD_BPS;
        if (shouldPause) {
            IBallastHookLite(pauseTarget).guardianPause(key);
        }

        emit DivergenceChecked(zkPriceScaled8, chainlinkPrice, divergenceBps, shouldPause);
    }

    /// @notice Parses a decimal price string (e.g. "2453.1") into a
    /// uint256 scaled to 8 decimals (245310000000), matching Chainlink's
    /// standard convention for direct comparability.
    function _parsePriceToScaled8(string memory priceStr) internal pure returns (uint256) {
        bytes memory b = bytes(priceStr);
        uint256 dotIndex = b.length; // default: no decimal point found
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ".") {
                dotIndex = i;
                break;
            }
        }

        uint256 integerPart = 0;
        for (uint256 i = 0; i < dotIndex; i++) {
            require(b[i] >= "0" && b[i] <= "9", "ZKPriceGuardian: invalid price format");
            // Safe: b[i] was just confirmed to be an ASCII digit
            // ('0'-'9'), so this subtraction cannot underflow and the
            // result always fits in a single digit (0-9).
            // forge-lint: disable-next-line(unsafe-typecast)
            integerPart = integerPart * 10 + (uint8(b[i]) - uint8(bytes1("0")));
        }

        uint256 fractionalPart = 0;
        uint256 fractionalDigits = 0;
        for (uint256 i = dotIndex + 1; i < b.length; i++) {
            require(b[i] >= "0" && b[i] <= "9", "ZKPriceGuardian: invalid price format");
            // Safe: same reasoning as above.
            // forge-lint: disable-next-line(unsafe-typecast)
            fractionalPart = fractionalPart * 10 + (uint8(b[i]) - uint8(bytes1("0")));
            fractionalDigits++;
        }

        // Scale the fractional part to exactly 8 decimal places.
        require(fractionalDigits <= 8, "ZKPriceGuardian: too many decimal places");
        uint256 fractionalScaled = fractionalPart * (10 ** (8 - fractionalDigits));

        return integerPart * 1e8 + fractionalScaled;
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory haystackBytes = bytes(haystack);
        bytes memory needleBytes = bytes(needle);

        if (needleBytes.length == 0) return true;
        if (needleBytes.length > haystackBytes.length) return false;

        uint256 lastPossibleStart = haystackBytes.length - needleBytes.length;
        for (uint256 i = 0; i <= lastPossibleStart; i++) {
            bool matched = true;
            for (uint256 j = 0; j < needleBytes.length; j++) {
                if (haystackBytes[i + j] != needleBytes[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
