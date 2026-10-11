import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createLedger, createSigner } from '../ledger.js';
import { createAnchoring, CALENDARS, ANCHOR_CONFIG } from '../anchor.js';
import worker, { D1Store } from '../worker.js';
import { CRON_SUBMIT, CRON_UPGRADE } from '../anchor.js';
import { attestations, hex, parseOts, serializeTimestamp, OP } from '../ots.js';
import { makeSqliteD1, makeDevice, makeSigningKey } from './helpers.js';

const T0 = 1760140800;
const ALICE = 'https://alice.btc.calendar.opentimestamps.org';
const BOB = 'https://bob.btc.calendar.opentimestamps.org';
const sha256 = async (b) => new Uint8Array(await crypto.subtle.digest('SHA-256', b));
const cat = (a, b) => Uint8Array.from([...a, ...b]);

/**
 * Fake calendars, shaped like the real ones: POST /digest answers append(nonce) sha256 -> pending(uri);
 * GET /timestamp/<commitment> answers prepend(x) sha256 -> bitcoin(height) once `mined` is set.
 * Calendars listed in `down` throw, those in `hang` never answer (and ignore the abort signal).
 */
function fakeCalendars({ down = [], hang = [], pendingUri = (cal) => (cal.includes('b.pool') ? BOB : ALICE) } = {}) {
  const f = {
    calls: [], mined: null, commitments: new Map(),
    fetch: async (url, init = {}) => {
      const method = init.method ?? 'GET';
      const body = init.body == null ? null : new Uint8Array(init.body);
      f.calls.push({ url, method, body, headers: init.headers });
      const origin = new URL(url).origin;
      if (down.some((d) => url.startsWith(d))) throw new TypeError('network down');
      if (hang.some((d) => url.startsWith(d))) return new Promise(() => {});
      if (method === 'POST' && url === `${origin}/digest`) {
        const nonce = crypto.getRandomValues(new Uint8Array(16));
        const commitment = await sha256(cat(body, nonce));
        const uri = pendingUri(origin);
        f.commitments.set(hex(commitment), uri);
        const ts = { attestations: [], ops: [{ op: { tag: OP.append, arg: nonce }, stamp: { attestations: [], ops: [
          { op: { tag: OP.sha256 }, stamp: { attestations: [{ type: 'pending', uri }], ops: [] } }] } }] };
        return new Response(serializeTimestamp(ts));
      }
      const m = url.match(/\/timestamp\/([0-9a-f]+)$/);
      if (method === 'GET' && m && f.commitments.get(m[1]) === origin && f.mined) {
        const ts = { attestations: [], ops: [{ op: { tag: OP.prepend, arg: Uint8Array.of(1, 2, 3) }, stamp: { attestations: [], ops: [
          { op: { tag: OP.sha256 }, stamp: { attestations: [{ type: 'bitcoin', height: f.mined }], ops: [] } }] } }] };
        return new Response(serializeTimestamp(ts));
      }
      return new Response('Not found', { status: 404 });
    },
  };
  return f;
}

let db, store, ledger, now;
beforeEach(async () => {
  db = await makeSqliteD1();
  store = new D1Store(db);
  now = T0;
  ledger = createLedger({ store, signer: await createSigner(await makeSigningKey()), now: () => now });
});

async function appendRow() {
  const dev = await makeDevice();
  const { code } = await ledger.issueCode({});
  await ledger.register({ code, key: dev.key });
  return store.getHead();
}

const anchoring = (f, extra = {}) => createAnchoring({ store, fetch: f.fetch, now: () => now, ...extra });

test('submit sends exactly the 32-byte head hash to every calendar and stores a pending proof', async () => {
  const head = await appendRow();
  const f = fakeCalendars();
  const r = await anchoring(f).submit();
  assert.equal(r.submitted, true);
  assert.equal(r.accepted.length, CALENDARS.length);
  assert.ok(CALENDARS.length >= 2);
  assert.deepEqual(f.calls.map((c) => c.url).sort(), CALENDARS.map((c) => `${c}/digest`).sort());
  for (const c of f.calls) {
    assert.equal(c.method, 'POST');
    assert.equal(c.body.length, 32); // R27: nothing but the hash leaves the server
    assert.equal(hex(c.body), head.hash);
    assert.equal(c.headers.accept, 'application/vnd.opentimestamps.v1');
  }
  const [a] = await store.listAnchors();
  assert.deepEqual({ seq: a.seq, hash: a.hash, status: a.status, height: a.height, calendars: a.calendars },
    { seq: head.seq, hash: head.hash, status: 'pending', height: null, calendars: 4 });
  const p = parseOts(Uint8Array.from(atob(a.proof), (c) => c.charCodeAt(0)));
  assert.equal(hex(p.digest), head.hash);
  const pend = await attestations(p.timestamp, p.digest);
  assert.equal(pend.length, 4); // one branch per calendar (separate nonces)
  assert.deepEqual([...new Set(pend.map((x) => x.attestation.uri))].sort(), [ALICE, BOB]);
});

test('submit skips an empty ledger and an unchanged head', async () => {
  const f = fakeCalendars();
  assert.deepEqual(await anchoring(f).submit(), { submitted: false, reason: 'empty_ledger' });
  await appendRow();
  await anchoring(f).submit();
  const calls = f.calls.length;
  assert.equal((await anchoring(f).submit()).reason, 'unchanged');
  assert.equal(f.calls.length, calls);
  await appendRow();
  assert.equal((await anchoring(f).submit()).submitted, true);
  assert.equal((await store.listAnchors()).length, 2);
});

test('one or more calendars failing does not fail the run', async () => {
  await appendRow();
  const f = fakeCalendars({ down: [CALENDARS[0]], hang: [CALENDARS[2]] });
  const r = await anchoring(f, { config: { ...ANCHOR_CONFIG, TIMEOUT_MS: 30 } }).submit();
  assert.equal(r.submitted, true);
  assert.deepEqual(r.accepted, [CALENDARS[1], CALENDARS[3]]);
  assert.deepEqual(r.failed.map((x) => x.calendar), [CALENDARS[0], CALENDARS[2]]);
  assert.match(r.failed[1].error, /timeout/);
  assert.equal((await store.getLatestAnchor()).calendars, 2);
});

test('all calendars timing out: nothing stored, no exception', async () => {
  await appendRow();
  const f = fakeCalendars({ hang: CALENDARS });
  const r = await anchoring(f, { config: { ...ANCHOR_CONFIG, TIMEOUT_MS: 30 } }).submit();
  assert.equal(r.submitted, false);
  assert.equal(r.reason, 'no_calendar');
  assert.equal(r.failed.length, 4);
  assert.deepEqual(await store.listAnchors(), []);
});

test('upgrade: pending stays pending until mined, then confirmed with the Bitcoin attestation merged in', async () => {
  const head = await appendRow();
  const f = fakeCalendars();
  await anchoring(f).submit();
  const before = await store.getLatestAnchor();

  f.calls.length = 0;
  const r1 = await anchoring(f).upgrade();
  assert.deepEqual(r1, { checked: 1, confirmed: [], errors: [] });
  assert.deepEqual(await store.getLatestAnchor(), before); // 404s change nothing
  // GET <pending uri>/timestamp/<hex commitment>, one per pending attestation
  assert.equal(f.calls.length, 4);
  for (const c of f.calls) {
    assert.equal(c.method, 'GET');
    const [, uri, commitment] = c.url.match(/^(https:\/\/[^/]+)\/timestamp\/([0-9a-f]{64})$/);
    assert.equal(f.commitments.get(commitment), uri);
  }

  f.mined = 912345;
  now = T0 + 6 * 3600;
  const r2 = await anchoring(f).upgrade();
  assert.deepEqual(r2.confirmed, [{ id: before.id, height: 912345 }]);
  const a = await store.getLatestAnchor();
  assert.equal(a.status, 'confirmed');
  assert.equal(a.height, 912345);
  assert.equal(a.upgradedAt, now);
  assert.equal(a.seq, head.seq);
  const p = parseOts(Uint8Array.from(atob(a.proof), (c) => c.charCodeAt(0)));
  assert.equal(hex(p.digest), head.hash);
  const types = (await attestations(p.timestamp, p.digest)).map((x) => x.attestation.type);
  assert.equal(types.filter((t) => t === 'bitcoin').length, 4);
  assert.equal(types.filter((t) => t === 'pending').length, 4); // kept, as the official client does

  f.calls.length = 0;
  assert.deepEqual(await anchoring(f).upgrade(), { checked: 0, confirmed: [], errors: [] });
  assert.equal(f.calls.length, 0);
});

test('upgrade: calendar timeout leaves the anchor unchanged and does not throw', async () => {
  await appendRow();
  await anchoring(fakeCalendars()).submit();
  const before = await store.getLatestAnchor();
  const f = fakeCalendars({ hang: [ALICE], down: [BOB] });
  const r = await anchoring(f, { config: { ...ANCHOR_CONFIG, TIMEOUT_MS: 30 } }).upgrade();
  assert.equal(r.checked, 1);
  assert.equal(r.errors.length, 4);
  assert.deepEqual(await store.getLatestAnchor(), before);
});

test('upgrade only contacts whitelisted calendars', async () => {
  await appendRow();
  await anchoring(fakeCalendars({ pendingUri: () => 'https://evil.example' })).submit();
  const f = fakeCalendars();
  await anchoring(f).upgrade();
  assert.equal(f.calls.length, 0);
});

test('anchors are never deleted and their anchored values never change', async () => {
  await appendRow();
  await anchoring(fakeCalendars()).submit();
  assert.throws(() => db.raw.exec('DELETE FROM anchors'), /append-only/);
  assert.throws(() => db.raw.exec("UPDATE anchors SET hash = 'x'"), /fixed/);
  db.raw.exec("UPDATE anchors SET status = 'confirmed', height = 1");
  assert.throws(() => db.raw.exec("UPDATE anchors SET status = 'pending'"), /stay confirmed/);
});

test('cron and public endpoints', async () => {
  const signingKey = await makeSigningKey();
  const env = { DB: db, LEDGER_SIGNING_KEY: signingKey, LEDGER_ADMIN_TOKEN: 'admin-secret' };
  const head = await appendRow();
  const f = fakeCalendars();
  const realFetch = globalThis.fetch;
  globalThis.fetch = f.fetch;
  const waited = [];
  try {
    const r = await worker.scheduled({ cron: CRON_SUBMIT }, env, { waitUntil: (p) => waited.push(p) });
    assert.equal(r.submitted, true);
    f.mined = 900000;
    const u = await worker.scheduled({ cron: CRON_UPGRADE }, env, { waitUntil: (p) => waited.push(p) });
    assert.equal(u.confirmed.length, 1);
    assert.deepEqual(await worker.scheduled({ cron: '* * * * *' }, env, { waitUntil: () => {} }), { ignored: '* * * * *' });
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.equal(waited.length, 2);

  const get = (path) => worker.fetch(new Request(`https://suhyeok.pickuma.com${path}`), env);
  const list = await (await get('/ledger/v1/anchors')).json();
  assert.equal(list.anchors.length, 1);
  const [a] = list.anchors;
  assert.deepEqual({ ...a, submittedAt: 0, upgradedAt: 0 }, {
    id: a.id, seq: head.seq, hash: head.hash, status: 'confirmed', height: 900000, submittedAt: 0, upgradedAt: 0,
    calendars: 4, ots: `/ledger/v1/anchors/${a.id}.ots`,
  });
  const res = await get(a.ots);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-type'), 'application/octet-stream');
  const bytes = new Uint8Array(await res.arrayBuffer());
  assert.equal(hex(parseOts(bytes).digest), head.hash);
  assert.equal(btoa(String.fromCharCode(...bytes)), (await store.getAnchor(a.id)).proof);
  assert.equal((await get('/ledger/v1/anchors/999.ots')).status, 404);
  assert.equal((await get('/ledger/v1/anchors/abc.ots')).status, 404);
});
