/**
 * generateAndSubmitProof.js
 *
 * The automated version of the two-step process we proved manually:
 * generates a real zkTLS proof of the live ETH/USD price, then submits
 * it directly to the real, deployed ZKPriceGuardian contract on
 * Sepolia — a single, unattended run suitable for a scheduled job.
 *
 * HONEST NOTE ON WHAT "AUTOMATIC" MEANS HERE: unlike OracleGuardian
 * (genuinely bot-free, via Reactive Network watching events), zkTLS
 * proof generation inherently requires a real HTTP fetch and real
 * client-side cryptographic computation — there is no way to do this
 * from pure on-chain code, for any team, ever. "Automatic" here means
 * this script runs unattended on a schedule (see the accompanying
 * GitHub Actions workflow), not that no off-chain computation is
 * involved at all.
 *
 * Required environment variables:
 *   RECLAIM_APP_ID, RECLAIM_APP_SECRET  - from your Reclaim dashboard
 *   SEPOLIA_RPC_URL, PRIVATE_KEY        - same as the rest of this project
 *   ZK_GUARDIAN_ADDRESS                  - the deployed ZKPriceGuardian address
 *   POOL_CURRENCY0, POOL_CURRENCY1,
 *   POOL_FEE, POOL_TICK_SPACING, POOL_HOOKS - the real pool being protected
 */

const { ReclaimClient } = require('@reclaimprotocol/zk-fetch');
const { transformForOnchain } = require('@reclaimprotocol/js-sdk');
const { ethers } = require('ethers');

// ABI verified directly against the real, compiled ZKPriceGuardian
// artifact (out/ZKPriceGuardian.sol/ZKPriceGuardian.json) — an earlier
// draft of this ABI incorrectly split the `proof` parameter into two
// separate top-level arguments; it is actually ONE combined tuple
// containing claimInfo and signedClaim together, exactly matching
// Reclaim's real Proof struct.
const ZK_GUARDIAN_ABI = [
  'function submitProofAndCheck(((string provider, string parameters, string context) claimInfo, ((bytes32 identifier, address owner, uint32 timestampS, uint32 epoch) claim, bytes[] signatures) signedClaim) proof, string claimedPriceStr, (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key) external',
];

async function main() {
  const { RECLAIM_APP_ID, RECLAIM_APP_SECRET, SEPOLIA_RPC_URL, PRIVATE_KEY, ZK_GUARDIAN_ADDRESS } = process.env;

  const required = { RECLAIM_APP_ID, RECLAIM_APP_SECRET, SEPOLIA_RPC_URL, PRIVATE_KEY, ZK_GUARDIAN_ADDRESS };
  for (const [key, value] of Object.entries(required)) {
    if (!value) {
      console.error(`Missing required environment variable: ${key}`);
      process.exit(1);
    }
  }

  console.log('Step 1/3: Generating a fresh zkTLS proof of the live ETH/USD price...');
  const client = new ReclaimClient(RECLAIM_APP_ID, RECLAIM_APP_SECRET, false);
  const proof = await client.zkFetch(
    'https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd',
    { method: 'GET', headers: { accept: 'application/json' } },
    {
      responseMatches: [{ type: 'regex', value: '"ethereum":\\{"usd":(?<price>[\\d.]+)\\}' }],
      responseRedactions: [{ regex: '"ethereum":\\{"usd":(?<price>[\\d.]+)\\}' }],
    }
  );

  if (!proof) {
    console.error('Proof generation failed.');
    process.exit(1);
  }

  const priceStr = proof.extractedParameterValues.price;
  console.log(`Real price attested: $${priceStr}`);

  console.log('Step 2/3: Transforming proof for on-chain submission...');
  const onchainProof = transformForOnchain(proof);

  console.log('Step 3/3: Submitting to ZKPriceGuardian on Sepolia...');
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  const guardian = new ethers.Contract(ZK_GUARDIAN_ADDRESS, ZK_GUARDIAN_ABI, wallet);

  const poolKey = {
    currency0: process.env.POOL_CURRENCY0 || '0x0000000000000000000000000000000000000000',
    currency1: process.env.POOL_CURRENCY1,
    fee: process.env.POOL_FEE || 8388608,
    tickSpacing: process.env.POOL_TICK_SPACING || 60,
    hooks: process.env.POOL_HOOKS,
  };

  const claimInfoTuple = [onchainProof.claimInfo.provider, onchainProof.claimInfo.parameters, onchainProof.claimInfo.context];
  const signedClaimTuple = [
    [
      onchainProof.signedClaim.claim.identifier,
      onchainProof.signedClaim.claim.owner,
      onchainProof.signedClaim.claim.timestampS,
      onchainProof.signedClaim.claim.epoch,
    ],
    onchainProof.signedClaim.signatures,
  ];
  const proofTuple = [claimInfoTuple, signedClaimTuple];
  const keyTuple = [poolKey.currency0, poolKey.currency1, poolKey.fee, poolKey.tickSpacing, poolKey.hooks];

  const tx = await guardian.submitProofAndCheck(proofTuple, priceStr, keyTuple);
  console.log('Transaction submitted:', tx.hash);

  const receipt = await tx.wait();
  console.log('Confirmed in block:', receipt.blockNumber);
  console.log(`\nDone. Real price ($${priceStr}) attested and checked on-chain.`);
}

main().catch((err) => {
  console.error('Error:', err);
  process.exit(1);
});