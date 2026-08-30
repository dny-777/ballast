// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Standalone copy of ZKPriceGuardian's pure parsing/matching
/// logic, for the same reason ZKPriceAttestorHarness exists: avoiding
/// an unsatisfiable combined pragma requirement between forge-std
/// (>=0.8.13) and Reclaim's contracts (hard-pinned to exactly 0.8.4)
/// within one test file's import graph.
contract ZKPriceGuardianHarness {
    function parsePriceToScaled8Public(string memory priceStr) external pure returns (uint256) {
        return _parsePriceToScaled8(priceStr);
    }

    function _parsePriceToScaled8(string memory priceStr) internal pure returns (uint256) {
        bytes memory b = bytes(priceStr);
        uint256 dotIndex = b.length;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ".") {
                dotIndex = i;
                break;
            }
        }

        uint256 integerPart = 0;
        for (uint256 i = 0; i < dotIndex; i++) {
            require(b[i] >= "0" && b[i] <= "9", "ZKPriceGuardian: invalid price format");
            // Safe: b[i] confirmed an ASCII digit above.
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

        require(fractionalDigits <= 8, "ZKPriceGuardian: too many decimal places");
        uint256 fractionalScaled = fractionalPart * (10 ** (8 - fractionalDigits));

        return integerPart * 1e8 + fractionalScaled;
    }
}
