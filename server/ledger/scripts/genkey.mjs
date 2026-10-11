// Prints a new Ed25519 keypair for the ledger Worker. The private key never goes into the repo:
//   node scripts/genkey.mjs
//   wrangler secret put LEDGER_SIGNING_KEY   (paste the private line)
// The public key is what the app embeds and what GET /ledger/v1/pubkey returns.
const b64 = (buf) => Buffer.from(buf).toString('base64');
const { privateKey, publicKey } = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
console.log('LEDGER_SIGNING_KEY (base64 PKCS#8, secret):');
console.log(b64(await crypto.subtle.exportKey('pkcs8', privateKey)));
console.log('public key (base64 raw 32 bytes, embed in the app):');
console.log(b64(await crypto.subtle.exportKey('raw', publicKey)));
