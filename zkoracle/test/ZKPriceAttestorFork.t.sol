// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";

/// @notice ABI-compatible mirror of Reclaim's real Proof/ClaimInfo/
/// SignedClaim/CompleteClaimData structs — deliberately NOT imported
/// directly from Reclaim's contracts, since those are hard-pinned to
/// exactly Solidity 0.8.4, incompatible within one file's import graph
/// with forge-std (which needs >=0.8.13, required for vm.createSelectFork
/// used by this fork test). Solidity ABI-encodes structs by field
/// layout, not nominal type identity across separate compilations, so
/// these mirrors call the REAL, already-deployed ZKPriceAttestor
/// contract (itself compiled separately, correctly, under 0.8.4 —
/// verified in ZKPriceAttestorUnit.t.sol and by `forge build` directly)
/// correctly at the ABI level. The same technique already proven
/// earlier in this project for OracleGuardianCallback/PoolKeyLite.
struct ClaimInfoLite {
    string provider;
    string parameters;
    string context;
}

struct CompleteClaimDataLite {
    bytes32 identifier;
    address owner;
    uint32 timestampS;
    uint32 epoch;
}

struct SignedClaimLite {
    CompleteClaimDataLite claim;
    bytes[] signatures;
}

struct ProofLite {
    ClaimInfoLite claimInfo;
    SignedClaimLite signedClaim;
}

interface IZKPriceAttestor {
    function submitPriceProof(ProofLite memory proof, string memory claimedPriceStr) external;
    function latestAttestation() external view returns (string memory priceStr, uint256 timestampS, bytes32 identifier);
}

/// @title ZKPriceAttestorForkTest
/// @notice Verifies the REAL, deployed ZKPriceAttestor contract against
/// REAL, live Sepolia state, submitting the user's ACTUAL, genuinely
/// generated zkTLS proof (not a synthetic example) and confirming it is
/// accepted by Reclaim's real, live verifier contract.
///
/// HOW TO RUN THIS (requires a real Sepolia RPC):
///   forge test --match-path 'test/ZKPriceAttestorFork.t.sol' \
///     --fork-url $SEPOLIA_RPC_URL -vvv
contract ZKPriceAttestorForkTest is Test {
    IZKPriceAttestor attestor;

    function setUp() public {
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string(""));
        require(bytes(rpcUrl).length > 0, "Set SEPOLIA_RPC_URL to run this fork test");
        vm.createSelectFork(rpcUrl);

        // Deploy via deployCode — reads the already-compiled artifact
        // (built correctly under solc 0.8.4 in its own pass) without
        // requiring this file to import ZKPriceAttestor.sol's source
        // directly, avoiding the pragma conflict entirely.
        address deployed = deployCode("ZKPriceAttestor.sol:ZKPriceAttestor");
        attestor = IZKPriceAttestor(deployed);
    }

    /// @notice Submits the user's REAL, actually-generated proof
    /// (identifier 0x304caafc..., real price $2453.1, fetched live from
    /// CoinGecko) and confirms Reclaim's real Sepolia verifier accepts
    /// it, and that our contract correctly records the attested price.
    function test_fork_realProof_isAcceptedAndRecorded() public {
        ProofLite memory proof = ProofLite({
            claimInfo: ClaimInfoLite({
                provider: "http",
                parameters: '{"body":"","headers":{"User-Agent":"reclaim/0.0.1","accept":"application/json"},"method":"GET","responseMatches":[{"type":"regex","value":"\\"ethereum\\":\\\\{\\"usd\\":(?<price>[\\\\d.]+)\\\\}"}],"responseRedactions":[{"regex":"\\"ethereum\\":\\\\{\\"usd\\":(?<price>[\\\\d.]+)\\\\}"}],"url":"https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd"}',
                context: '{"extractedParameters":{"price":"2453.1"},"providerHash":"0x5dce30bf220a36eaeae24a953a805f7a8ef81141e37407b9e17b31289e158b7c"}'
            }),
            signedClaim: SignedClaimLite({
                claim: CompleteClaimDataLite({
                    identifier: 0x304caafc3d9b019631341d1222128caeea21029f41107a64fee0786df0400934,
                    owner: 0x8219e08E6ebBa8AD72ef201F84E6E788A096aF03,
                    timestampS: 1788037003,
                    epoch: 1
                }),
                signatures: _realSignatures()
            })
        });

        attestor.submitPriceProof(proof, "2453.1");

        (string memory storedPrice, uint256 storedTimestamp, bytes32 storedIdentifier) = attestor.latestAttestation();

        assertEq(storedPrice, "2453.1", "Stored price should match the real attested value");
        assertEq(storedTimestamp, 1788037003, "Stored timestamp should match the real claim");
        assertEq(
            storedIdentifier,
            bytes32(0x304caafc3d9b019631341d1222128caeea21029f41107a64fee0786df0400934),
            "Stored identifier should match the real claim"
        );

        console.log("Real zkTLS proof accepted on-chain. Attested price:", storedPrice);
    }

    function _realSignatures() internal pure returns (bytes[] memory) {
        bytes[] memory sigs = new bytes[](1);
        sigs[0] =
            hex"c66bd34cec546f0f36eb0a71f6f55ff518a55d9426a3153552f69327333b38f84558042f3ad4acb8617ce1c5a73385561782745d236b84159ddb5971febfa4df1b";
        return sigs;
    }
}