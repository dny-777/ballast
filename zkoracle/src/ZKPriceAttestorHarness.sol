// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice A standalone copy of ZKPriceAttestor's `_contains()` logic,
/// deliberately NOT inheriting from ZKPriceAttestor itself. Reason: that
/// contract's import chain reaches Reclaim's contracts, which are
/// hard-pinned to EXACTLY Solidity 0.8.4 — incompatible, within one
/// file's import graph, with forge-std (which needs >=0.8.13) used by
/// this harness's own tests. Since `_contains` is pure string logic
/// with no actual dependency on Reclaim's types, duplicating it here
/// (verified identical, byte-for-byte, to the real implementation) lets
/// us unit-test it directly without forcing an unsatisfiable combined
/// pragma requirement.
contract ZKPriceAttestorHarness {
    function containsPublic(string memory haystack, string memory needle) external pure returns (bool) {
        return _contains(haystack, needle);
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