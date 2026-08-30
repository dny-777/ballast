// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ZKPriceGuardianHarness} from "../src/ZKPriceGuardianHarness.sol";

contract ZKPriceGuardianUnitTest is Test {
    ZKPriceGuardianHarness harness;

    function setUp() public {
        harness = new ZKPriceGuardianHarness();
    }

    /// @notice The exact, real price string from the user's actual
    /// generated proof — "2453.1" should become 245310000000 when
    /// scaled to 8 decimals (2453.1 * 1e8).
    function test_parse_realPriceFromActualProof() public view {
        assertEq(harness.parsePriceToScaled8Public("2453.1"), 245310000000);
    }

    function test_parse_wholeNumberNoDecimalPoint() public view {
        assertEq(harness.parsePriceToScaled8Public("2453"), 245300000000);
    }

    function test_parse_singleDecimalDigit() public view {
        assertEq(harness.parsePriceToScaled8Public("100.5"), 10050000000);
    }

    function test_parse_maxEightDecimalDigits() public view {
        assertEq(harness.parsePriceToScaled8Public("1.12345678"), 112345678);
    }

    function test_parse_zeroValue() public view {
        assertEq(harness.parsePriceToScaled8Public("0.0"), 0);
    }

    function test_parse_smallFraction() public view {
        assertEq(harness.parsePriceToScaled8Public("0.01"), 1000000);
    }

    function test_parse_revertsOnTooManyDecimalPlaces() public {
        vm.expectRevert(bytes("ZKPriceGuardian: too many decimal places"));
        harness.parsePriceToScaled8Public("1.123456789");
    }

    function test_parse_revertsOnNonDigitCharacter() public {
        vm.expectRevert(bytes("ZKPriceGuardian: invalid price format"));
        harness.parsePriceToScaled8Public("12a.5");
    }

    function test_parse_largeRealisticEthPrice() public view {
        // A realistic, larger ETH price to confirm no overflow/rounding
        // issues at larger magnitudes.
        assertEq(harness.parsePriceToScaled8Public("4300.75"), 430075000000);
    }
}
