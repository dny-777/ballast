/**
 * generateProof.js
 *
 * Generates a REAL zkTLS proof (via Reclaim Protocol's zkFetch) that a
 * specific ETH/USD price was genuinely returned by CoinGecko's real,
 * live public API — cryptographically verifiable on-chain without
 * trusting us, or Reclaim, to report it honestly.
 *
 * This is the off-chain half of Ballast's third oracle-safety layer
 * (see ZKORACLE.md): an independent, cryptographically-attested price
 * source that can be cross-checked against Chainlink's reported price,
 * on top of the existing timelock and OracleGuardian layers.
 *
 * Usage:
 *   RECLAIM_APP_ID=... RECLAIM_APP_SECRET=... node generateProof.js
 */

const { ReclaimClient } = require('@reclaimprotocol/zk-fetch');

async function main() {
  const appId = process.env.RECLAIM_APP_ID;
  const appSecret = process.env.RECLAIM_APP_SECRET;

  if (!appId || !appSecret) {
    console.error('Set RECLAIM_APP_ID and RECLAIM_APP_SECRET before running this script.');
    process.exit(1);
  }

  const client = new ReclaimClient(appId, appSecret, true /* logs */);

  console.log('Requesting a real zkTLS proof of the live ETH/USD price from CoinGecko...');
  console.log('(This calls a real external API and generates a real cryptographic proof —');
  console.log(' it may take a several seconds to a couple of minutes.)');

  const proof = await client.zkFetch(
    'https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd',
    {
      method: 'GET',
      headers: { accept: 'application/json' },
    },
    {
      responseMatches: [
        {
          type: 'regex',
          value: '"ethereum":\\{"usd":(?<price>[\\d.]+)\\}',
        },
      ],
      responseRedactions: [
        {
          regex: '"ethereum":\\{"usd":(?<price>[\\d.]+)\\}',
        },
      ],
    }
  );

  if (!proof) {
    console.error('Proof generation failed — no proof returned.');
    process.exit(1);
  }

  console.log('\n=== REAL PROOF GENERATED ===');
  console.log('Identifier:', proof.identifier);
  console.log('Extracted price:', proof.extractedParameterValues);
  console.log('Provider:', proof.claimData.provider);
  console.log('Timestamp (unix):', proof.claimData.timestampS);
  console.log('Number of attestor signatures:', proof.signatures.length);

  const fs = require('fs');
  fs.writeFileSync('proof.json', JSON.stringify(proof, null, 2));
  console.log('\nFull proof saved to proof.json — this is the real, complete artifact');
  console.log('needed for on-chain verification in the next step.');
}

main().catch((err) => {
  console.error('Error generating proof:', err);
  process.exit(1);
});