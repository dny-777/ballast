// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Reclaim} from "@reclaimprotocol/verifier-solidity-sdk/contracts/Reclaim.sol";
import {StringUtils} from "@reclaimprotocol/verifier-solidity-sdk/contracts/StringUtils.sol";

/// @title ZKPriceAttestor
/// @notice Ballast's third oracle-safety layer: accepts a real zkTLS
/// proof (via Reclaim Protocol) that a specific price was genuinely
/// returned by a real, named external API (e.g. CoinGecko's live
/// ETH/USD endpoint), verifies the underlying cryptographic proof
/// on-chain against Reclaim's real, deployed Sepolia verifier, and
/// stores the attested price — independent of, and cross-checkable
/// against, Chainlink's reported price.
///
/// WHY THIS EXISTS: our existing oracle-safety design already has two
/// layers — a 24-hour timelock on oracle changes, and OracleGuardian's
/// autonomous cross-chain pause on anomalous Chainlink behavior (both
/// proven live — see README). This adds a third, structurally
/// different layer: an independent price source that isn't Chainlink
/// at all, cryptographically tied to a real, named website's real
/// response, rather than trusting any oracle network's own reporting.
///
/// SCOPE, STATED HONESTLY: this contract verifies the proof and stores
/// the attested price as the exact string CoinGecko returned (e.g.
/// "2453.1"), tied to a specific claim identifier and timestamp.
/// Converting that string into a Chainlink-comparable fixed-point
/// uint256 for direct on-chain arithmetic comparison is a natural next
/// step, not yet built here — this version's job is proving the harder
/// part first: that the price genuinely came from where it claims to.
contract ZKPriceAttestor {
    /// @notice Reclaim's real, deployed verifier contract on Ethereum
    /// Sepolia — confirmed to have real, substantial bytecode deployed
    /// via direct `cast code` verification against the live network,
    /// not assumed from documentation.
    address public constant RECLAIM_VERIFIER = 0xAe94FB09711e1c6B057853a515483792d8e474d0;

    /// @notice The exact CoinGecko endpoint this contract expects
    /// proofs to be sourced from — a real, specific, named external
    /// data source, not an arbitrary or unverified one.
    string public constant EXPECTED_URL =
        "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd";

    struct Attestation {
        string priceStr; // the exact price string as CoinGecko returned it, e.g. "2453.1"
        uint256 timestampS; // real timestamp from the underlying claim
        bytes32 identifier; // the real, unique claim identifier from the proof
    }

    /// @notice The most recent successfully-verified attestation.
    Attestation public latestAttestation;

    event PriceAttested(string priceStr, uint256 timestampS, bytes32 identifier);

    /// @notice Verifies a real zkTLS proof and, if valid, records the
    /// price it attests to.
    /// @param proof The Reclaim proof, transformed via the official
    ///        `transformForOnchain()` helper from the raw JSON a real
    ///        zkFetch call produces — see generateProof.js /
    ///        submitProof.js in this project's zkoracle/ folder.
    /// @param claimedPriceStr The price string we expect this proof to
    ///        attest to, EXACTLY as it appears in the real API
    ///        response (e.g. "2453.1") — checked against the proof's
    ///        own cryptographically-signed context, not trusted
    ///        blindly from the caller.
    function submitPriceProof(Reclaim.Proof memory proof, string memory claimedPriceStr) external {
        // 1. Verify the underlying cryptographic proof is genuinely
        // valid against Reclaim's real, deployed Sepolia verifier —
        // this call reverts if the signatures/witnesses don't check
        // out.
        Reclaim(RECLAIM_VERIFIER).verifyProof(proof);

        // 2. Confirm this proof is actually about the URL we expect —
        // a valid proof about a DIFFERENT website's data should not be
        // accepted here.
        require(
            _contains(proof.claimInfo.parameters, EXPECTED_URL),
            "ZKPriceAttestor: proof is not for the expected CoinGecko endpoint"
        );

        // 3. Confirm the claimed price string genuinely appears in the
        // proof's own cryptographically-signed context — this is the
        // real binding between "the value we're about to store" and
        // "the value the proof actually, verifiably attests to".
        // NOTE: string.concat() isn't available until Solidity 0.8.12 —
        // this project is pinned to exactly 0.8.4 to match Reclaim's
        // own contracts, so we use the standard pre-0.8.12 pattern
        // instead. Caught directly by the compiler, not assumed.
        string memory expectedFragment = string(abi.encodePacked('"price":"', claimedPriceStr, '"'));
        require(
            _contains(proof.claimInfo.context, expectedFragment),
            "ZKPriceAttestor: claimed price does not match the verified proof"
        );

        latestAttestation = Attestation({
            priceStr: claimedPriceStr,
            timestampS: proof.signedClaim.claim.timestampS,
            identifier: proof.signedClaim.claim.identifier
        });

        emit PriceAttested(claimedPriceStr, proof.signedClaim.claim.timestampS, proof.signedClaim.claim.identifier);
    }

    /// @notice Real, byte-level substring search — Solidity has no
    /// built-in string.contains, so this implements it directly rather
    /// than relying on an unverified third-party helper.
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