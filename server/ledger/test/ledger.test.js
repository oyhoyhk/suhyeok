import { test, describe, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createLedger, createSigner, entryCanonical, sha256hex, CONFIG, LedgerError } from '../ledger.js';
import { D1Store } from '../worker.js';
import { MemoryStore, makeSqliteD1, makeDevice, makeSigningKey, openEnvelope } from './helpers.js';

test('canonical form and hash match the shared vectors (Swift <-> JS)', async () => {
  const { cases } = JSON.parse(readFileSync(new URL('./vectors.json', import.meta.url), 'utf8'));
  for (const c of cases) {
    assert.equal(entryCanonical(c.fields), c.canonical);
    assert.equal(await sha256hex(c.canonical), c.hash);
  }
});

const T0 = 1760140800;
const RATE = CONFIG.EARN_PER_HOUR_PER_AGENT * CONFIG.MAX_PARALLEL_AGENTS + CONFIG.BONUS_PER_HOUR; // 112/h

const stores = [
  ['memory store', async () => {
    const s = new MemoryStore();
    return { store: s, tamper: (seq, f, v) => s.tamper(seq, f, v) };
  }],
  ['D1 store over sqlite', async () => {
    const db = await makeSqliteD1();
    return {
      store: new D1Store(db),
      db,
      tamper: (seq, f, v) => {
        db.raw.exec('DROP TRIGGER ledger_no_update');
        db.raw.prepare(`UPDATE ledger SET ${f} = ? WHERE seq = ?`).run(v, seq);
      },
    };
  }],
];

for (const [name, makeStore] of stores) {
  describe(name, () => {
    let ctx, ledger, signer, now;
    const at = (t) => { now = t; };

    beforeEach(async () => {
      ctx = await makeStore();
      signer = await createSigner(await makeSigningKey());
      now = T0;
      ledger = createLedger({ store: ctx.store, signer, now: () => now });
    });

    const rejects = (p, status, code) => assert.rejects(p, (e) => {
      assert.ok(e instanceof LedgerError, `expected LedgerError, got ${e}`);
      assert.equal(e.code, code);
      assert.equal(e.status, status);
      return true;
    });
    const open = (env) => openEnvelope(env, signer.publicKey);

    async function registered() {
      const dev = await makeDevice();
      const { code } = await ledger.issueCode({});
      const { device } = await ledger.register({ code, key: dev.key });
      dev.id = device;
      return dev;
    }
    const sync = (dev, entries) => ledger.sync({ device: dev.id, entries });
    const serverBalance = async (dev) => (await open(await ledger.balance(dev.id))).balance;

    // --- registration (R16)

    test('register with a valid code; the same code again is rejected', async () => {
      const dev = await makeDevice();
      const { code } = await ledger.issueCode({});
      const r = await ledger.register({ code, key: dev.key });
      assert.match(r.device, /^[0-9a-f-]{36}$/);
      const other = await makeDevice();
      await rejects(ledger.register({ code, key: other.key }), 409, 'code_used');
    });

    test('register without a code, or with an unknown or expired code, is rejected', async () => {
      const dev = await makeDevice();
      await rejects(ledger.register({ key: dev.key }), 400, 'code_required');
      await rejects(ledger.register({ code: 'NOPE-NOPE', key: dev.key }), 403, 'invalid_code');
      const { code } = await ledger.issueCode({ ttlSec: 60 });
      at(T0 + 61);
      await rejects(ledger.register({ code, key: dev.key }), 403, 'code_expired');
    });

    test('a key that is not a P-256 X9.63 point, or one already registered, is rejected', async () => {
      const { code } = await ledger.issueCode({});
      await rejects(ledger.register({ code, key: btoa('short') }), 400, 'bad_key');
      const dev = await registered();
      const { code: c2 } = await ledger.issueCode({});
      await rejects(ledger.register({ code: c2, key: dev.key }), 409, 'key_registered');
    });

    // --- sync (R17, R18, R22)

    test('three valid entries are accepted, credited, and the receipt verifies with the server key', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 3, T0);
      await dev.append('earn', 's1', 3, T0 + 600);
      at(T0 + 700);
      const env = await sync(dev, dev.since(-1));
      const r = await open(env);
      assert.equal(r.type, 'sync');
      assert.equal(r.device, dev.id);
      assert.equal(r.fromSeq, 0);
      assert.equal(r.deviceSeq, 2);
      assert.equal(r.deviceHash, dev.entries[2].hash);
      assert.equal(r.accepted, 6);
      assert.equal(r.clamped, 0);
      assert.equal(r.balance, 6);
      assert.equal(r.head, (await ctx.store.getHead()).hash);
      assert.equal(await serverBalance(dev), 6);
      const pub = await ledger.publicKey();
      assert.equal(pub.key, signer.publicKey);
    });

    test('one bad signature rejects the whole batch', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 3, T0);
      await dev.append('earn', 's1', 3, T0 + 600);
      const batch = dev.since(-1);
      const sig = atob(batch[1].sig);
      batch[1].sig = btoa(String.fromCharCode(sig.charCodeAt(0) ^ 1) + sig.slice(1));
      at(T0 + 700);
      await rejects(sync(dev, batch), 422, 'bad_signature');
      assert.equal(await serverBalance(dev), 0);
      assert.equal((await ctx.store.getDevice(dev.id)).lastSeq, -1);
    });

    test('an edited amount (hash no longer matches) rejects the batch', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 3, T0);
      const batch = dev.since(-1);
      batch[1].amount = 300;
      await rejects(sync(dev, batch), 422, 'bad_hash');
    });

    test('an entry that does not chain to the last acknowledged hash is rejected', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 3, T0);
      await sync(dev, dev.since(-1));
      // Validly signed, but prev points elsewhere.
      const forged = await dev.make({ seq: 2, time: T0 + 60, kind: 'earn', source: 's1', amount: 1, prev: 'ab'.repeat(32) });
      await rejects(sync(dev, [forged]), 409, 'chain_break');
      // Skipping a seq is also a break.
      const skip = await dev.make({ seq: 3, time: T0 + 60, kind: 'earn', source: 's1', amount: 1, prev: dev.entries[1].hash });
      await rejects(sync(dev, [skip]), 409, 'chain_break');
    });

    test('the first sync must start with the open entry carrying the registered key', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 3, T0);
      await rejects(sync(dev, dev.since(0)), 409, 'chain_break');
      const other = await makeDevice();
      const wrongKey = await dev.make({ seq: 0, time: T0, kind: 'open', source: '', amount: 0, key: other.key, prev: '0'.repeat(64) });
      await rejects(sync(dev, [wrongKey]), 409, 'key_mismatch');
    });

    test('500 reported after one hour is clamped to the hourly cap; the receipt shows the clamp', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 3, T0);
      await sync(dev, dev.since(-1));
      await dev.append('earn', 's1', 500, T0 + 3600);
      at(T0 + 3600);
      const r = await open(await sync(dev, dev.since(1)));
      assert.equal(r.reported, 500);
      assert.equal(r.accepted, RATE);
      assert.equal(r.clamped, 500 - RATE);
      assert.equal(r.balance, 3 + RATE);
      assert.equal(r.pendingClamp, 500 - RATE);
    });

    test('the device adjust entry for a clamp is not applied a second time (R19)', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 3, T0);
      await sync(dev, dev.since(-1));
      await dev.append('earn', 's1', 500, T0 + 3600);
      at(T0 + 3600);
      const r = await open(await sync(dev, dev.since(1)));
      // What LedgerSync.swift does with the receipt:
      await dev.append('adjust', `receipt:${r.serverSeq}`, -r.clamped, T0 + 3660);
      at(T0 + 3660);
      const r2 = await open(await sync(dev, dev.since(r.deviceSeq)));
      assert.equal(r2.balance, 3 + RATE, 'server balance unchanged by the matching adjust');
      assert.equal(r2.pendingClamp, 0);
      assert.equal(dev.balance, r2.balance, 'local balance == server balance');
    });

    test('a negative adjust larger than the outstanding clamp reduces the balance by the excess only', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 3, T0);
      await sync(dev, dev.since(-1));
      await dev.append('earn', 's1', 200, T0 + 3600);
      at(T0 + 3600);
      const r = await open(await sync(dev, dev.since(1))); // clamped 88
      await dev.append('adjust', 'manual', -r.clamped - 10, T0 + 3600);
      const r2 = await open(await sync(dev, dev.since(r.deviceSeq)));
      assert.equal(r2.balance, 3 + RATE - 10);
      assert.equal(dev.balance, r2.balance);
    });

    test('an entry 10 minutes in the future is rejected; so is one older than the last acknowledged', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 3, T0 + 600);
      await rejects(sync(dev, dev.since(-1)), 422, 'future_time');
      at(T0 + 600);
      await sync(dev, dev.since(-1));
      const back = await dev.make({ seq: 2, time: T0 + 599, kind: 'earn', source: 's1', amount: 1, prev: dev.entries[1].hash });
      await rejects(sync(dev, [back]), 422, 'time_backwards');
    });

    test('re-sending an acknowledged batch returns the same receipt and never double counts', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 3, T0);
      await dev.append('earn', 's1', 4, T0 + 600);
      at(T0 + 600);
      const a = await sync(dev, dev.since(-1));
      const b = await sync(dev, dev.since(-1));
      assert.deepEqual(b, a);
      const len = (await ctx.store.listLedger()).length;
      // A retry that carries the old batch plus a new entry: only the new entry is processed.
      await dev.append('earn', 's1', 5, T0 + 1200);
      at(T0 + 1200);
      const c = await open(await sync(dev, dev.since(-1)));
      assert.equal(c.fromSeq, 3);
      assert.equal(c.balance, 12);
      assert.equal((await ctx.store.listLedger()).length, len + 1);
      // A resend that disagrees with what was acknowledged is a fork.
      const fork = await dev.make({ seq: 1, time: T0, kind: 'earn', source: 's1', amount: 9, prev: dev.entries[0].hash });
      await rejects(sync(dev, [fork]), 409, 'fork');
    });

    test('genesis is pending until an admin approves it (R20) and is outside the cap', async () => {
      const dev = await registered();
      await dev.append('genesis', 'history', 5000, T0);
      const r = await open(await sync(dev, dev.since(-1)));
      assert.equal(r.pending, 5000);
      assert.equal(r.balance, 0);
      assert.equal(r.clamped, 0);
      const pending = await ledger.listPendingGenesis();
      assert.equal(pending.length, 1);
      assert.equal(pending[0].amount, 5000);
      const ap = await ledger.approveGenesis(pending[0].serverSeq);
      assert.equal(ap.balance, 5000);
      assert.equal(await serverBalance(dev), 5000);
      await rejects(ledger.approveGenesis(pending[0].serverSeq), 409, 'already_approved');
      assert.equal((await ledger.listPendingGenesis()).length, 0);
    });

    test('a revoked device cannot sync; its balance stays readable', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 3, T0);
      await sync(dev, dev.since(-1));
      await ledger.revoke(dev.id, 'lost mac');
      await dev.append('earn', 's1', 3, T0 + 600);
      at(T0 + 600);
      await rejects(sync(dev, dev.since(1)), 403, 'revoked');
      const b = await open(await ledger.balance(dev.id));
      assert.equal(b.revoked, true);
      assert.equal(b.balance, 3);
    });

    test('an unknown device cannot sync', async () => {
      const dev = await makeDevice();
      await dev.append('earn', 's1', 3, T0);
      await rejects(ledger.sync({ device: crypto.randomUUID(), entries: dev.since(-1) }), 404, 'unknown_device');
    });

    // --- spending (KTD4)

    test('spend confirmation reserves the amount; the later local spend entry consumes it, not the balance', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 3, T0);
      await sync(dev, dev.since(-1));
      await dev.append('earn', 's1', 100, T0 + 3600);
      at(T0 + 3600);
      await sync(dev, dev.since(1)); // balance 103

      const req = await dev.spendRequest(dev.id, 'knight', 50, now);
      const s = await open(await ledger.requestSpend(req));
      assert.equal(s.type, 'spend');
      assert.equal(s.item, 'knight');
      assert.equal(s.balance, 53);
      assert.deepEqual(await ledger.requestSpend(req).then(open), s, 'retrying the same request is idempotent');

      await dev.append('spend', 'knight', -50, now);
      const r = await open(await sync(dev, dev.since(2)));
      assert.equal(r.balance, 53, 'the synced spend consumed the reservation');
      assert.equal(dev.balance, 53);
      const b = await open(await ledger.balance(dev.id));
      assert.deepEqual(b.reservations, []);

      await rejects(ledger.requestSpend(req), 409, 'replay');
      const big = await dev.spendRequest(dev.id, 'dragon', 54, now + 1);
      await rejects(ledger.requestSpend(big), 409, 'insufficient');
      const forged = { ...(await dev.spendRequest(dev.id, 'mage', 10, now + 2)), amount: 1 };
      await rejects(ledger.requestSpend(forged), 422, 'bad_signature');
    });

    test('a spend entry without a reservation is deducted; one that overdraws rejects the batch', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 30, T0);
      await sync(dev, dev.since(-1));
      await dev.append('spend', 'knight', -20, T0);
      assert.equal((await open(await sync(dev, dev.since(1)))).balance, 10);
      await dev.append('spend', 'mage', -11, T0);
      await rejects(sync(dev, dev.since(2)), 409, 'insufficient');
      assert.equal(await serverBalance(dev), 10);
    });

    test('the balance response is signed and lists open reservations', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 30, T0);
      await sync(dev, dev.since(-1));
      await ledger.requestSpend(await dev.spendRequest(dev.id, 'knight', 20, now));
      const b = await open(await ledger.balance(dev.id));
      assert.equal(b.type, 'balance');
      assert.equal(b.balance, 10);
      assert.equal(b.deviceSeq, 1);
      assert.deepEqual(b.reservations.map((x) => [x.item, x.amount]), [['knight', 20]]);
    });

    // --- server ledger (R21)

    test('admin corrections are appended as rows, and the server ledger verifies', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 30, T0);
      await sync(dev, dev.since(-1));
      const c = await ledger.correct({ device: dev.id, amount: -5, note: 'double counted transcript' });
      assert.equal(c.balance, 25);
      await rejects(ledger.correct({ device: dev.id, amount: -26, note: 'x' }), 409, 'insufficient');
      await rejects(ledger.correct({ device: dev.id, amount: 5, note: '' }), 400, 'bad_request');
      const v = await ledger.verify();
      assert.equal(v.ok, true);
      assert.equal(v.balancesMatch, true);
      const kinds = (await ctx.store.listLedger()).map((r) => r.kind);
      assert.deepEqual(kinds, ['register', 'entry', 'entry', 'correct']);
    });

    test('editing a server ledger row in place is detected by verify', async () => {
      const dev = await registered();
      await dev.append('earn', 's1', 3, T0);
      await dev.append('earn', 's1', 4, T0 + 600);
      at(T0 + 600);
      await sync(dev, dev.since(-1));
      assert.equal((await ledger.verify()).ok, true);
      ctx.tamper(2, 'amount', 400);
      const v = await ledger.verify();
      assert.equal(v.ok, false);
      assert.equal(v.brokenAt, 2);
    });

    if (name.startsWith('D1')) {
      test('the D1 schema refuses UPDATE and DELETE on ledger rows', async () => {
        const dev = await registered();
        assert.throws(() => ctx.db.raw.prepare('UPDATE ledger SET amount = 9 WHERE seq = 0').run(), /append-only/);
        assert.throws(() => ctx.db.raw.prepare('DELETE FROM ledger WHERE seq = 0').run(), /append-only/);
        assert.ok(dev.id);
      });
    }
  });
}
