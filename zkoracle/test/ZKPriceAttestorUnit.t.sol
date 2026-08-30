// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ZKPriceAttestorHarness} from "../src/ZKPriceAttestorHarness.sol";

contract ZKPriceAttestorUnitTest is Test {
    ZKPriceAttestorHarness harness;

    // The REAL context string from the user's actual, live-generated
    // proof — not a synthetic example.
    string constant REAL_CONTEXT =
        '{"extractedParameters":{"price":"2453.1"},"providerHash":"0x5dce30bf220a36eaeae24a953a805f7a8ef81141e37407b9e17b31289e158b7c"}';

    string constant REAL_PARAMETERS =
        '{"body":"","headers":{"User-Agent":"reclaim/0.0.1","accept":"application/json"},"method":"GET","responseMatches":[{"type":"regex","value":"\\"ethereum\\":\\\\{\\"usd\\":(?<price>[\\\\d.]+)\\\\}"}],"responseRedactions":[{"regex":"\\"ethereum\\":\\\\{\\"usd\\":(?<price>[\\\\d.]+)\\\\}"}],"url":"https://api.coingecko.com/api/v3/simple/price?ids=ethereum\\u0026vs_currencies=usd"}';

    function setUp() public {
        harness = new ZKPriceAttestorHarness();
    }

    function test_contains_findsRealPriceInRealContext() public view {
        assertTrue(harness.containsPublic(REAL_CONTEXT, '"price":"2453.1"'));
    }

    function test_contains_rejectsWrongPrice() public view {
        assertFalse(harness.containsPublic(REAL_CONTEXT, '"price":"9999.9"'));
    }

    function test_contains_findsExpectedUrlInRealParameters() public view {
        assertTrue(
            harness.containsPublic(
                REAL_PARAMETERS, "https://api.coingecko.com/api/v3/simple/price?ids=ethereum"
            )
        );
    }

    function test_contains_rejectsWrongUrl() public view {
        assertFalse(harness.containsPublic(REAL_PARAMETERS, "https://api.binance.com/wrong-endpoint"));
    }

    function test_contains_emptyNeedleAlwaysMatches() public view {
        assertTrue(harness.containsPublic(REAL_CONTEXT, ""));
    }

    function test_contains_needleLongerThanHaystackNeverMatches() public view {
        assertFalse(harness.containsPublic("short", "this needle is definitely longer than the haystack"));
    }

    function test_contains_matchAtVeryEnd() public view {
        assertTrue(harness.containsPublic("hello world", "world"));
    }

    function test_contains_matchAtVeryStart() public view {
        assertTrue(harness.containsPublic("hello world", "hello"));
    }

    function test_contains_exactMatch() public view {
        assertTrue(harness.containsPublic("exact", "exact"));
    }
}