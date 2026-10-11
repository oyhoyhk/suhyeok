import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { OtsError, attestations, hex, isWhitelistedCalendar, mergeTimestamp, parseOts, parseTimestamp, serializeOts, serializeTimestamp } from '../ots.js';

// Official examples from opentimestamps-client/examples (see fixtures/README.md). Expected values were
// cross-checked with python-opentimestamps 0.4 (DetachedTimestampFile.deserialize + all_attestations).
const fixture = (name) => new Uint8Array(readFileSync(new URL(`./fixtures/${name}`, import.meta.url)));
const reversed = (h) => h.match(/../g).reverse().join('');

test('every official example parses and re-serialises byte for byte', () => {
  const names = readdirSync(new URL('./fixtures/', import.meta.url)).filter((n) => n.endsWith('.ots'));
  assert.ok(names.length >= 5);
  for (const n of names) {
    const bytes = fixture(n);
    assert.equal(hex(serializeOts(parseOts(bytes))), hex(bytes), n);
  }
});

test('confirmed example: replayed ops reach the Bitcoin block merkle root', async () => {
  const p = parseOts(fixture('gdp2q25-2nd.pdf.ots'));
  assert.equal(hex(p.digest), 'c70972a12908b73c2407d9cc6842ba2a02203a690f3090cd29f30c45f0cfd93d');
  const btc = (await attestations(p.timestamp, p.digest)).filter((a) => a.attestation.type === 'bitcoin');
  assert.equal(btc.length, 1);
  assert.equal(btc[0].attestation.height, 912095);
  // Esplora shows block 912095's merkle_root in display (reversed) byte order.
  assert.equal(hex(btc[0].msg), reversed('936131994129988e1932d8c1c6a9780fd42ae4c87204cfb0ac852be1250039ae'));
});

test('pending examples: commitments per calendar', async () => {
  const one = parseOts(fixture('incomplete.txt.ots'));
  const [a] = await attestations(one.timestamp, one.digest);
  assert.deepEqual(a.attestation, { type: 'pending', uri: 'https://alice.btc.calendar.opentimestamps.org' });
  assert.equal(hex(a.msg), '57cfa5c46716df9bd9e83595bce439c58108d8fcc1678f30d4c6731c3f1fa6c79ed712c66fb1ac8d4e4eb0e7');

  const two = parseOts(fixture('two-calendars.txt.ots'));
  const got = (await attestations(two.timestamp, two.digest)).map((x) => [x.attestation.uri, hex(x.msg)]).sort();
  assert.deepEqual(got, [
    ['https://alice.btc.calendar.opentimestamps.org', '57d46515fdd8c2334c77b1f204338bb2178d73e523988d7dcda13259d3a099f31623755deadd66b1688d5574'],
    ['https://bob.btc.calendar.opentimestamps.org', '57d4651676e9ac3b3b57c1584828ea5162979c96483a03c87c69a1b8614d1cbaf387e0f5647b90ea1b270a97'],
  ]);
});

test('unknown attestations and uncomputable ops parse; their subtrees are skipped, not fatal', async () => {
  const k = parseOts(fixture('known-and-unknown-notary.txt.ots'));
  assert.deepEqual((await attestations(k.timestamp, k.digest)).map((x) => x.attestation.type).sort(), ['pending', 'unknown']);
  const h = parseOts(fixture('hello-world.txt.ots')); // its Bitcoin path goes through ripemd160
  assert.equal(hex(h.digest), '03ba204e50d126e4674c005e04d82e84c21366780af1f43bd54a37816b6ab340');
  assert.deepEqual(await attestations(h.timestamp, h.digest), []);
});

test('one changed byte: parse failure or a different merkle root', async () => {
  const bytes = fixture('gdp2q25-2nd.pdf.ots');
  const flipped = (i) => { const b = Uint8Array.from(bytes); b[i] ^= 0x01; return b; };
  assert.throws(() => parseOts(flipped(3)), OtsError); // magic
  assert.throws(() => parseOts(bytes.subarray(0, bytes.length - 1)), OtsError); // truncated
  assert.throws(() => parseOts(Uint8Array.from([...bytes, 0])), OtsError); // trailing garbage
  const p = parseOts(flipped(40)); // inside the file digest
  const [btc] = (await attestations(p.timestamp, p.digest)).filter((a) => a.attestation.type === 'bitcoin');
  assert.notEqual(hex(btc.msg), reversed('936131994129988e1932d8c1c6a9780fd42ae4c87204cfb0ac852be1250039ae'));
});

test('merge is idempotent and adds new branches', async () => {
  const p = parseOts(fixture('two-calendars.txt.ots'));
  const before = hex(serializeTimestamp(p.timestamp));
  mergeTimestamp(p.timestamp, parseTimestamp(serializeTimestamp(p.timestamp)));
  assert.equal(hex(serializeTimestamp(p.timestamp)), before);
  mergeTimestamp(p.timestamp, { attestations: [{ type: 'bitcoin', height: 1 }], ops: [] });
  assert.ok((await attestations(p.timestamp, p.digest)).some((a) => a.attestation.type === 'bitcoin' && a.msg === p.digest));
});

test('calendar whitelist matches the official client defaults only', () => {
  for (const ok of ['https://alice.btc.calendar.opentimestamps.org', 'https://finney.calendar.eternitywall.com', 'https://btc.calendar.catallaxy.com/']) {
    assert.ok(isWhitelistedCalendar(ok), ok);
  }
  for (const bad of ['http://alice.btc.calendar.opentimestamps.org', 'https://evil.example', 'https://calendar.opentimestamps.org.evil.example',
    'https://alice.btc.calendar.opentimestamps.org/x', 'https://alice.btc.calendar.opentimestamps.org:8443', 'not a url']) {
    assert.ok(!isWhitelistedCalendar(bad), bad);
  }
});
