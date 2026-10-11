// Character market (U3 upload/moderation, U4 purchase/download, U7 income), against both stores, plus the
// HTTP routes, the R2 key discipline, and the live-DB migration.
import { test, describe, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { createLedger, createSigner, sha256hex, LedgerError, CONFIG } from '../ledger.js';
import { createMarket, MARKET } from '../market.js';
import worker, { D1Store } from '../worker.js';
import { MemoryStore, MemoryR2, makeSqliteD1, makeDevice, makeSigningKey, openEnvelope } from './helpers.js';

const VECTORS = new URL('./asset-vectors/', import.meta.url);
const T0 = 1760140800;

/** A pack from test/asset-vectors: manifest text plus every file it lists that exists on disk. */
function loadPack(name) {
  const base = new URL(`${name}/`, VECTORS);
  const manifest = readFileSync(new URL('manifest.json', base), 'utf8');
  const files = new Map();
  for (const path of Object.keys(JSON.parse(manifest).files)) {
    try { files.set(path, new Uint8Array(readFileSync(new URL(path, base)))); } catch { /* missing on purpose */ }
  }
  return { manifest, files };
}
const PACK = loadPack('ok_minimal');
const bytesSha = async (b) => [...new Uint8Array(await crypto.subtle.digest('SHA-256', b))].map((x) => x.toString(16).padStart(2, '0')).join('');
const R2_KEY = /^assets\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/[0-9a-f]{64}$/;

const stores = [
  ['memory store', async () => {
    const s = new MemoryStore();
    return { store: s, setStatus: (id, status) => { s.listings.get(id).status = status; } };
  }],
  ['D1 store over sqlite', async () => {
    const db = await makeSqliteD1();
    return { store: new D1Store(db), db, setStatus: (id, status) => db.raw.prepare('UPDATE listings SET status = ? WHERE id = ?').run(status, id) };
  }],
];

for (const [name, makeStore] of stores) {
  describe(`market: ${name}`, () => {
    let ctx, ledger, market, signer, blobs, now;
    const tick = () => ++now;

    beforeEach(async () => {
      ctx = await makeStore();
      signer = await createSigner(await makeSigningKey());
      blobs = new MemoryR2();
      now = T0;
      ledger = createLedger({ store: ctx.store, signer, now: () => now });
      market = createMarket({ store: ctx.store, signer, blobs, now: () => now });
    });

    const rejects = (p, status, code) => assert.rejects(p, (e) => {
      assert.ok(e instanceof LedgerError, `expected LedgerError, got ${e?.stack ?? e}`);
      assert.equal(e.code, code, e.message);
      assert.equal(e.status, status);
      return true;
    });
    const open = (env) => openEnvelope(env, signer.publicKey);
    const serverBalance = async (dev) => open(await ledger.balance(dev.id));
    const kinds = async () => (await ctx.store.listLedger()).map((r) => r.kind);

    async function registered() {
      const dev = await makeDevice();
      const { code } = await ledger.issueCode({});
      dev.id = (await ledger.register({ code, key: dev.key })).device;
      return dev;
    }
    /** Earn `amount` on the device and sync it, so local and server balances agree. */
    async function earn(dev, amount) {
      await dev.append('earn', 'work', amount, now);
      return open(await ledger.sync({ device: dev.id, entries: dev.since(dev.synced ?? -1) })).then((r) => { dev.synced = r.deviceSeq; return r; });
    }
    async function syncDev(dev) {
      const r = await open(await ledger.sync({ device: dev.id, entries: dev.since(dev.synced ?? -1) }));
      dev.synced = r.deviceSeq;
      return r;
    }

    const draftReq = async (dev, { pack = PACK, price = 300, alias = 'Ari', description = '' } = {}) => ({
      ...(await dev.marketRequest('market.draft', { alias, description, manifestSha256: await sha256hex(pack.manifest), price }, tick())),
      manifest: pack.manifest,
    });
    const draft = async (dev, opts) => market.createDraft(await draftReq(dev, opts));
    async function upload(dev, listingId, path, bytes) {
      const req = await dev.marketRequest('market.file', { listingId, path, sha256: await bytesSha(bytes) }, tick());
      return market.uploadFile({ ...req, path, bytes });
    }
    async function uploadAll(dev, listingId, pack = PACK) {
      let r;
      for (const [path, bytes] of pack.files) r = await upload(dev, listingId, path, bytes);
      return r;
    }
    const submit = async (dev, listingId) => market.submit(await dev.marketRequest('market.submit', { listingId }, tick()));
    async function published(dev, opts) {
      const d = await draft(dev, opts);
      await uploadAll(dev, d.listingId, opts?.pack);
      await submit(dev, d.listingId);
      await market.moderate(d.listingId, 'approve');
      return d.listingId;
    }
    const buyReq = (dev, listingId, price) => dev.marketRequest('market.buy', { listingId, price }, tick());
    const downloadReq = (dev, listingId) => dev.marketRequest('market.download', { listingId }, tick());
    const mine = async (dev) => market.mine(await dev.marketRequest('market.mine', {}, tick()));

    // --- U3: upload, submit, moderation

    test('a valid pack uploads and submits to pending, with a moderate row per state change', async () => {
      const a = await registered();
      const d = await draft(a);
      assert.equal(d.status, 'draft');
      assert.deepEqual(d.missing, Object.keys(JSON.parse(PACK.manifest).files).sort());
      const last = await uploadAll(a, d.listingId);
      assert.deepEqual(last.missing, []);
      const s = await submit(a, d.listingId);
      assert.equal(s.status, 'pending');
      const rows = (await ctx.store.listLedger()).filter((r) => r.kind === 'moderate');
      assert.deepEqual(rows.map((r) => [r.ref, r.amount, r.device, r.reported]),
        [[`${d.listingId}:draft`, 0, a.id, 300], [`${d.listingId}:pending`, 0, a.id, 0]]);
      for (const key of blobs.puts) assert.match(key, R2_KEY);
      const v = await ledger.verify();
      assert.equal(v.ok, true);
      assert.equal(v.listingsMatch, true);
      assert.equal(v.balancesMatch, true);
      assert.equal((await market.listPending()).pending[0].id, d.listingId);
    });

    test('unregistered, wrongly signed and revoked devices cannot draft', async () => {
      const stranger = await makeDevice();
      stranger.id = crypto.randomUUID();
      await rejects(draft(stranger), 404, 'unknown_device');
      const a = await registered();
      const forged = { ...(await draftReq(a)), price: 5000 };
      await rejects(market.createDraft(forged), 422, 'bad_signature');
      const other = { ...(await draftReq(a)), manifest: loadPack('ok_knight').manifest };
      await rejects(market.createDraft(other), 422, 'bad_signature', 'the signature covers the manifest hash');
      await ledger.revoke(a.id, 'test');
      await rejects(draft(a), 403, 'revoked');
    });

    test('a file that differs from the manifest, or an SVG named sprite.png, is refused at upload (AE3)', async () => {
      const a = await registered();
      const svg = loadPack('svg_sprite');
      const d = await draft(a, { pack: svg });
      await rejects(upload(a, d.listingId, 'sprite.png', svg.files.get('sprite.png')), 422, 'invalid_file');
      const wrong = PACK.files.get('frames/attack_0.png');
      await rejects(upload(a, d.listingId, 'portrait.jpg', wrong), 422, 'invalid_file');
      for (const [path, bytes] of svg.files) if (path !== 'sprite.png') await upload(a, d.listingId, path, bytes);
      await rejects(submit(a, d.listingId), 409, 'missing_files');
      assert.equal((await ctx.store.getListing(d.listingId)).status, 'draft', 'never reaches pending');
      assert.equal(blobs.puts.length, svg.files.size - 1, 'refused files are not stored');
    });

    test('submitting with a file missing is refused and names it', async () => {
      const a = await registered();
      const d = await draft(a);
      for (const [path, bytes] of PACK.files) if (path !== 'sprite.png') await upload(a, d.listingId, path, bytes);
      await rejects(submit(a, d.listingId), 409, 'missing_files');
      try { await submit(a, d.listingId); } catch (e) { assert.deepEqual(e.extra.missing, ['sprite.png']); }
    });

    test('rejecting needs a reason; the seller sees it and the market does not show the listing (AE2)', async () => {
      const a = await registered();
      const d = await draft(a);
      await uploadAll(a, d.listingId);
      await submit(a, d.listingId);
      await rejects(market.moderate(d.listingId, 'reject', {}), 400, 'reason_required');
      await rejects(market.moderate(d.listingId, 'reject', { reason: '   ' }), 400, 'reason_required');
      const r = await market.moderate(d.listingId, 'reject', { reason: '기존 게임 캐릭터 복제' });
      assert.equal(r.status, 'rejected');
      const m = await mine(a);
      assert.deepEqual(m.listings.map((l) => [l.status, l.reason]), [['rejected', '기존 게임 캐릭터 복제']]);
      assert.deepEqual((await market.listings()).listings, []);
      await rejects(market.preview(d.listingId, 'sprite.png'), 404, 'not_found');
      const row = (await ctx.store.listLedger()).at(-1);
      assert.deepEqual([row.kind, row.ref, row.note], ['moderate', `${d.listingId}:rejected`, '기존 게임 캐릭터 복제']);
      await rejects(market.moderate(d.listingId, 'approve'), 409, 'bad_state');
    });

    test('approving lists it with previews; delisting needs a reason and removes it', async () => {
      const a = await registered();
      const id = await published(a, { alias: 'Ari' });
      const { listings } = await market.listings();
      assert.equal(listings.length, 1);
      assert.equal(listings[0].price, 300);
      assert.deepEqual(listings[0].seller, { tag: a.id.slice(0, 8), alias: 'Ari' });
      assert.deepEqual(listings[0].previews, {
        portrait: `/ledger/v1/market/preview/${id}/portrait.jpg`, sprite: `/ledger/v1/market/preview/${id}/sprite.png`,
      });
      const p = await market.preview(id, 'sprite.png');
      assert.equal(p.contentType, 'image/png');
      await rejects(market.preview(id, 'frames/walk_down_0.png'), 404, 'not_found', 'frames are not public');
      await rejects(market.moderate(id, 'delist', {}), 400, 'reason_required');
      await market.moderate(id, 'delist', { reason: 'copyright report' });
      assert.deepEqual((await market.listings()).listings, []);
      await rejects(market.preview(id, 'sprite.png'), 404, 'not_found');
      assert.ok(await market.preview(id, 'sprite.png', { admin: true }), 'admins still see it');
      const v = await ledger.verify();
      assert.equal(v.ok, true);
      assert.equal(v.listingsMatch, true);
    });

    test('moderation only follows the state machine', async () => {
      const a = await registered();
      const d = await draft(a);
      await rejects(market.moderate(d.listingId, 'approve'), 409, 'bad_state');
      await rejects(market.moderate(d.listingId, 'delist', { reason: 'x' }), 409, 'bad_state');
      await rejects(market.moderate(crypto.randomUUID(), 'approve'), 404, 'not_found');
      await rejects(market.moderate(d.listingId, 'publish'), 400, 'bad_request');
    });

    test('prices outside 50..5000 are refused', async () => {
      const a = await registered();
      await rejects(draft(a, { price: 49 }), 400, 'bad_price');
      await rejects(draft(a, { price: 5001 }), 400, 'bad_price');
      assert.equal((await draft(a, { price: 50 })).status, 'draft');
      assert.equal((await draft(a, { price: 5000 })).status, 'draft');
    });

    test('a sixth open draft is refused; withdrawing one frees a slot', async () => {
      const a = await registered();
      const ids = [];
      for (let i = 0; i < MARKET.MAX_OPEN_LISTINGS; i++) ids.push((await draft(a)).listingId);
      await rejects(draft(a), 429, 'too_many_open');
      await market.withdraw(await a.marketRequest('market.withdraw', { listingId: ids[0] }, tick()));
      assert.equal((await draft(a)).status, 'draft');
      assert.equal((await ledger.verify()).listingsMatch, true);
    });

    test('kind map (or any other kind) is refused as unsupported (AE8)', async () => {
      const a = await registered();
      await assert.rejects(draft(a, { pack: loadPack('map_kind') }), (e) => {
        assert.equal(e.code, 'invalid_pack');
        assert.ok(e.extra.errors.some((x) => x.code === 'bad_kind'));
        return true;
      });
    });

    test('state-changing requests are replay-protected; uploads are only for the seller and only in draft', async () => {
      const a = await registered();
      const b = await registered();
      const req = await draftReq(a);
      const d = await market.createDraft(req);
      await rejects(market.createDraft(req), 409, 'replay');
      const late = await a.marketRequest('market.mine', {}, now - CONFIG.SPEND_REQUEST_SKEW_SEC - 1);
      await rejects(market.mine(late), 422, 'bad_time');
      const [path, bytes] = [...PACK.files][0];
      await rejects(upload(b, d.listingId, path, bytes), 403, 'not_seller');
      await uploadAll(a, d.listingId);
      await submit(a, d.listingId);
      await rejects(upload(a, d.listingId, path, bytes), 409, 'bad_state');
      await rejects(submit(a, d.listingId), 409, 'bad_state');
    });

    test('verify notices a listing status that no moderate row explains', async () => {
      const a = await registered();
      const d = await draft(a);
      assert.equal((await ledger.verify()).listingsMatch, true);
      ctx.setStatus(d.listingId, 'approved');
      assert.equal((await ledger.verify()).listingsMatch, false);
    });

    // --- U4: purchase, ownership, download

    test('B (500) buys A\'s 300 listing: B -300, A +270, 30 burned, rows sum to zero (AE1)', async () => {
      const a = await registered();
      const b = await registered();
      await earn(b, 500);
      const id = await published(a);
      const receipt = await open(await market.buy(await buyReq(b, id, 300)));
      assert.equal(receipt.type, 'buy');
      assert.deepEqual([receipt.item, receipt.amount, receipt.balance, receipt.sellerCredit, receipt.burned, receipt.seller],
        [`market:${id}`, 300, 200, 270, 30, a.id]);
      const purchase = (await ctx.store.listLedger()).filter((r) => r.ref === `market:${id}`);
      assert.deepEqual(purchase.map((r) => [r.kind, r.device, r.amount]), [['reserve', b.id, -300], ['sale', a.id, 270], ['burn', '', 30]]);
      assert.equal(purchase.reduce((s, r) => s + r.amount, 0), 0);
      const bb = await serverBalance(b);
      assert.equal(bb.balance, 200);
      assert.deepEqual(bb.reservations.map((r) => [r.item, r.amount]), [[`market:${id}`, 300]]);
      const ab = await serverBalance(a);
      assert.equal(ab.balance, 270);
      assert.equal(ab.pendingIncome, 270);
      const v = await ledger.verify();
      assert.deepEqual([v.ok, v.balancesMatch, v.pendingIncomeMatch, v.listingsMatch, v.burned], [true, true, true, true, 30]);
      assert.equal((await mine(a)).listings[0].sales, 1);
      assert.equal((await market.listings()).listings[0].sales, 1);
    });

    test('the buyer\'s local spend consumes the purchase reservation: no double deduction (AE5 server half)', async () => {
      const a = await registered();
      const b = await registered();
      await earn(b, 500);
      const id = await published(a);
      await market.buy(await buyReq(b, id, 300));
      await b.append('spend', `market:${id}`, -300, now, '마켓 구매');
      const r = await syncDev(b);
      assert.equal(r.balance, 200);
      assert.equal(b.balance, 200, 'local equals server');
      assert.deepEqual((await serverBalance(b)).reservations, []);
      assert.equal((await ledger.verify()).balancesMatch, true);
    });

    test('buying again is already_owned with no charge; retrying the same request returns the same receipt (AE4)', async () => {
      const a = await registered();
      const b = await registered();
      await earn(b, 1000);
      const id = await published(a);
      const req = await buyReq(b, id, 300);
      const first = await market.buy(req);
      const length = (await ctx.store.listLedger()).length;
      assert.deepEqual(await market.buy(req), first, 'lost-response retry is idempotent');
      await rejects(market.buy(await buyReq(b, id, 300)), 409, 'already_owned');
      assert.equal((await ctx.store.listLedger()).length, length);
      assert.equal((await serverBalance(b)).balance, 700);
    });

    test('two concurrent purchases of the same listing charge once', async () => {
      const a = await registered();
      const b = await registered();
      await earn(b, 1000);
      const id = await published(a);
      const reqs = [await buyReq(b, id, 300), await buyReq(b, id, 300)];
      const results = await Promise.allSettled(reqs.map((r) => market.buy(r)));
      assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
      const lost = results.find((r) => r.status === 'rejected').reason;
      assert.ok(['already_owned', 'replay'].includes(lost.code), lost.code);
      assert.equal((await serverBalance(b)).balance, 700);
      assert.equal((await ledger.verify()).balancesMatch, true);
    });

    test('own listings, wrong prices, tampered prices and short balances are refused without rows', async () => {
      const a = await registered();
      const b = await registered();
      await earn(a, 1000);
      await earn(b, 299);
      const id = await published(a);
      const length = (await ctx.store.listLedger()).length;
      await rejects(market.buy(await buyReq(a, id, 300)), 409, 'own_listing');
      await rejects(market.buy(await buyReq(b, id, 250)), 409, 'price_mismatch', 'a stale or lowered price');
      const tampered = { ...(await buyReq(b, id, 300)), price: 50 };
      await rejects(market.buy(tampered), 422, 'bad_signature');
      await rejects(market.buy(await buyReq(b, id, 300)), 409, 'insufficient');
      await rejects(market.buy(await buyReq(b, crypto.randomUUID(), 300)), 404, 'not_found');
      assert.equal((await ctx.store.listLedger()).length, length);
      assert.equal((await serverBalance(b)).balance, 299);
    });

    test('mine lists the device\'s purchases, delisted ones included, so they can be downloaded again', async () => {
      const a = await registered();
      const b = await registered();
      await earn(b, 1000);
      const id = await published(a);
      await market.buy(await buyReq(b, id, 300));
      await market.moderate(id, 'delist', { reason: 'copyright report' });
      assert.deepEqual((await mine(b)).purchases, [{ id, name: 'Tester', price: 300, status: 'delisted' }]);
      assert.deepEqual((await mine(a)).purchases, []);
    });

    test('a revoked seller\'s listings leave the catalogue', async () => {
      const a = await registered();
      const c = await registered();
      const id = await published(a);
      const other = await published(c);
      await ledger.revoke(a.id, 'test');
      assert.deepEqual((await market.listings()).listings.map((l) => l.id), [other]);
    });

    test('pending, rejected and delisted listings cannot be bought', async () => {
      const a = await registered();
      const b = await registered();
      await earn(b, 5000);
      const pending = await draft(a);
      await uploadAll(a, pending.listingId);
      await submit(a, pending.listingId);
      await rejects(market.buy(await buyReq(b, pending.listingId, 300)), 409, 'not_for_sale');
      const rejected = await draft(a);
      await uploadAll(a, rejected.listingId);
      await submit(a, rejected.listingId);
      await market.moderate(rejected.listingId, 'reject', { reason: 'x' });
      await rejects(market.buy(await buyReq(b, rejected.listingId, 300)), 409, 'not_for_sale');
      const delisted = await published(a);
      await market.moderate(delisted, 'delist', { reason: 'y' });
      await rejects(market.buy(await buyReq(b, delisted, 300)), 409, 'not_for_sale');
    });

    test('only owners get a download token; owners keep it after a delisting (AE6); tokens expire', async () => {
      const a = await registered();
      const b = await registered();
      const c = await registered();
      await earn(b, 500);
      const id = await published(a);
      await rejects(market.download(await downloadReq(c, id)), 403, 'not_owner');
      await market.buy(await buyReq(b, id, 300));
      await market.moderate(id, 'delist', { reason: 'copyright report' });
      const dl = await market.download(await downloadReq(b, id));
      assert.equal(dl.manifest, PACK.manifest);
      assert.match(dl.token, /^[0-9a-f]{64}$/);
      assert.equal(dl.expiresAt, now + MARKET.TOKEN_TTL_SEC);
      assert.deepEqual(dl.files.map((f) => f.path).sort(), [...PACK.files.keys()].sort());
      for (const f of dl.files) {
        assert.equal(f.url, `/ledger/v1/market/files/${dl.token}/${f.path}`);
        const got = await market.fileByToken(dl.token, f.path);
        const bytes = new Uint8Array(await new Response(got.body).arrayBuffer());
        assert.deepEqual(bytes, PACK.files.get(f.path));
      }
      await rejects(market.fileByToken(dl.token, 'manifest.json'), 404, 'not_found');
      await rejects(market.fileByToken(dl.token, '../sprite.png'), 404, 'not_found');
      await rejects(market.fileByToken('0'.repeat(64), 'sprite.png'), 403, 'bad_token');
      await rejects(market.fileByToken('../../etc', 'sprite.png'), 403, 'bad_token');
      now += MARKET.TOKEN_TTL_SEC + 1;
      await rejects(market.fileByToken(dl.token, 'sprite.png'), 403, 'token_expired');
      assert.ok((await market.download(await downloadReq(a, id))).token, 'the seller may fetch their own pack');
    });

    test('a token is bound to its listing: another listing\'s file is not reachable with it', async () => {
      const a = await registered();
      const b = await registered();
      await earn(b, 500);
      const id = await published(a);
      const knight = loadPack('ok_knight');
      const other = await published(a, { pack: knight });
      await market.buy(await buyReq(b, id, 300));
      const dl = await market.download(await downloadReq(b, id));
      // Both packs list sprite.png with different bytes; the token serves only its own listing's file.
      assert.notDeepEqual(PACK.files.get('sprite.png'), knight.files.get('sprite.png'));
      const got = await market.fileByToken(dl.token, 'sprite.png');
      assert.deepEqual(new Uint8Array(await new Response(got.body).arrayBuffer()), PACK.files.get('sprite.png'));
      await rejects(market.download(await downloadReq(b, other)), 403, 'not_owner');
    });

    // --- U7: sale income booked on the seller's device

    test('the seller books income +270 on the next sync; local balance equals server balance (AE7)', async () => {
      const a = await registered();
      const b = await registered();
      await earn(a, 10);
      await earn(b, 500);
      const id = await published(a);
      await market.buy(await buyReq(b, id, 300));
      const before = await serverBalance(a);
      assert.deepEqual([before.balance, before.pendingIncome], [280, 270]);
      assert.notEqual(a.balance, before.balance, 'not yet booked locally');
      await a.append('income', `market:${id}`, 270, now, '판매 수익');
      const r = await syncDev(a);
      assert.deepEqual([r.balance, r.pendingIncome, r.accepted, r.clamped], [280, 0, 0, 0]);
      assert.equal(a.balance, r.balance, 'local equals server');
      const row = (await ctx.store.listLedger()).at(-1);
      assert.deepEqual([row.kind, row.dkind, row.amount, row.reported, row.ref], ['entry', 'income', 0, 270, 'income']);
      const v = await ledger.verify();
      assert.deepEqual([v.ok, v.balancesMatch, v.pendingIncomeMatch], [true, true, true]);
    });

    test('income beyond the outstanding pendingIncome rejects the batch', async () => {
      const a = await registered();
      const b = await registered();
      await earn(a, 10);
      await earn(b, 500);
      const id = await published(a);
      await market.buy(await buyReq(b, id, 300));
      await a.append('income', `market:${id}`, 271, now);
      await rejects(ledger.sync({ device: a.id, entries: a.since(a.synced) }), 409, 'income_mismatch');
      const s = await serverBalance(a);
      assert.deepEqual([s.balance, s.pendingIncome, s.deviceSeq], [280, 270, a.synced]);
      const c = await registered();
      await c.append('income', 'forged', 1, now);
      await rejects(ledger.sync({ device: c.id, entries: c.since(-1) }), 409, 'income_mismatch');
    });

    test('income is outside the hourly cap and split income entries add up', async () => {
      const a = await registered();
      const b = await registered();
      await earn(a, 10);
      await earn(b, 1000);
      const id = await published(a, { price: 1000 });
      await market.buy(await buyReq(b, id, 1000));
      // Same timestamp as the last acknowledged entry: the cap window is empty, so the earn is clamped entirely.
      const t = (await ctx.store.getDevice(a.id)).lastTime;
      await a.append('income', `market:${id}`, 500, t);
      await a.append('earn', 'work', 50, t);
      await a.append('income', `market:${id}`, 400, t);
      const r = await syncDev(a);
      assert.deepEqual([r.accepted, r.clamped, r.pendingIncome, r.balance], [0, 50, 0, 910]);
    });

    test('an income entry must be positive', async () => {
      const a = await registered();
      await a.append('income', 'x', 0, now);
      await rejects(ledger.sync({ device: a.id, entries: a.since(-1) }), 400, 'bad_entry');
    });

    test('a plain spend cannot create a market reservation', async () => {
      const b = await registered();
      await earn(b, 500);
      await rejects(ledger.requestSpend(await b.spendRequest(b.id, `market:${crypto.randomUUID()}`, 300, tick())), 400, 'bad_request');
    });
  });
}

// --- HTTP

const ADMIN = 'admin-secret';
async function httpEnv() {
  return { DB: await makeSqliteD1(), ASSETS: new MemoryR2(), LEDGER_SIGNING_KEY: await makeSigningKey(), LEDGER_ADMIN_TOKEN: ADMIN };
}
const req = (e, method, path, { body, token, headers = {}, raw } = {}) => worker.fetch(new Request(`https://suhyeok.pickuma.com/ledger/v1${path}`, {
  method,
  headers: { ...(raw ? {} : { 'content-type': 'application/json' }), ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
  body: raw ?? (body === undefined ? undefined : JSON.stringify(body)),
}), e);
const nowSec = () => Math.floor(Date.now() / 1000);

describe('market over HTTP', () => {
  let e, seq = 0;
  const t = () => nowSec() + (seq++ % 200); // strictly increasing within the skew window

  async function device() {
    const dev = await makeDevice();
    const { code } = await (await req(e, 'POST', '/admin/codes', { body: {}, token: ADMIN })).json();
    dev.id = (await (await req(e, 'POST', '/register', { body: { code, key: dev.key } })).json()).device;
    return dev;
  }
  async function put(dev, id, encodedPath, path, bytes) {
    const time = t();
    const r = await dev.marketRequest('market.file', { listingId: id, path, sha256: await bytesSha(bytes) }, time);
    return req(e, 'PUT', `/market/drafts/${id}/files/${encodedPath}`, {
      raw: bytes, headers: { 'x-ledger-device': dev.id, 'x-ledger-time': String(time), 'x-ledger-sig': r.sig },
    });
  }

  beforeEach(async () => { e = await httpEnv(); });

  test('every admin market route requires the bearer token', async () => {
    const id = crypto.randomUUID();
    const routes = [['GET', '/admin/market/pending'], ['GET', `/admin/market/${id}/files/sprite.png`],
      ['POST', `/admin/market/${id}/approve`], ['POST', `/admin/market/${id}/reject`], ['POST', `/admin/market/${id}/delist`]];
    for (const [m, p] of routes) {
      for (const token of [undefined, 'wrong']) {
        const r = await req(e, m, p, { body: m === 'POST' ? { reason: 'x' } : undefined, token });
        assert.equal(r.status, 401, `${m} ${p} ${token}`);
      }
    }
    assert.equal((await req(e, 'GET', '/admin/market/pending', { token: ADMIN })).status, 200);
  });

  test('upload, approve, buy, download end to end; R2 keys never come from request paths', async () => {
    const { key } = await (await req(e, 'GET', '/pubkey')).json();
    const a = await device();
    const b = await device();
    await req(e, 'POST', '/admin/corrections', { body: { device: b.id, amount: 500, note: 'test funds' }, token: ADMIN });

    const dr = await a.marketRequest('market.draft', { alias: '', description: 'hi', manifestSha256: await sha256hex(PACK.manifest), price: 300 }, t());
    const created = await req(e, 'POST', '/market/drafts', { body: { ...dr, manifest: PACK.manifest } });
    assert.equal(created.status, 201);
    const { listingId: id } = await created.json();

    // Traversal-shaped paths are refused before anything is stored.
    const sprite = PACK.files.get('sprite.png');
    for (const [enc, path] of [['..%2F..%2Fsprite.png', '../../sprite.png'], ['frames%2F..%2Fsprite.png', 'frames/../sprite.png'],
      ['%2Fsprite.png', '/sprite.png'], ['sprite.png%00', 'sprite.png\u0000']]) {
      const r = await put(a, id, enc, path, sprite);
      assert.equal(r.status, 422, enc);
      assert.equal((await r.json()).error, 'invalid_file');
    }
    assert.equal((await put(a, id, '%E0%A4%A', 'x', sprite)).status, 400, 'undecodable path');
    assert.equal(e.ASSETS.puts.length, 0);

    for (const [path, bytes] of PACK.files) {
      // Literal and %2F-encoded slashes are both accepted.
      const r = await put(a, id, path.startsWith('frames/') && path.endsWith('0.png') ? path.replace('/', '%2F') : path, path, bytes);
      assert.equal(r.status, 200, path);
    }
    for (const k of e.ASSETS.puts) assert.match(k, R2_KEY);
    const big = await req(e, 'PUT', `/market/drafts/${id}/files/sprite.png`, { raw: new Uint8Array(1024 * 1024 + 1) });
    assert.equal(big.status, 413);

    const sub = await a.marketRequest('market.submit', { listingId: id }, t());
    assert.equal((await req(e, 'POST', `/market/drafts/${id}/submit`, { body: sub })).status, 200);
    assert.equal((await req(e, 'GET', `/market/preview/${id}/sprite.png`)).status, 404, 'pending previews are not public');
    const adminView = await req(e, 'GET', `/admin/market/${id}/files/frames/walk_down_0.png`, { token: ADMIN });
    assert.equal(adminView.status, 200);
    assert.equal(adminView.headers.get('content-type'), 'image/png');
    const pending = await (await req(e, 'GET', '/admin/market/pending', { token: ADMIN })).json();
    assert.equal(pending.pending[0].id, id);
    assert.equal((await req(e, 'POST', `/admin/market/${id}/reject`, { body: {}, token: ADMIN })).status, 400);
    assert.equal((await req(e, 'POST', `/admin/market/${id}/approve`, { body: {}, token: ADMIN })).status, 200);

    const { listings } = await (await req(e, 'GET', '/market/listings')).json();
    assert.equal(listings[0].id, id);
    const pv = await req(e, 'GET', listings[0].previews.sprite.replace('/ledger/v1', ''));
    assert.equal(pv.status, 200);
    assert.equal(pv.headers.get('x-content-type-options'), 'nosniff');
    assert.deepEqual(new Uint8Array(await pv.arrayBuffer()), sprite);

    const buy = await b.marketRequest('market.buy', { listingId: id, price: 300 }, t());
    const bought = await req(e, 'POST', '/market/buy', { body: buy });
    assert.equal(bought.status, 200);
    assert.equal((await openEnvelope(await bought.json(), key)).balance, 200);
    const again = await req(e, 'POST', '/market/buy', { body: await b.marketRequest('market.buy', { listingId: id, price: 300 }, t()) });
    assert.equal(again.status, 409);
    assert.equal((await again.json()).error, 'already_owned');

    const dl = await (await req(e, 'POST', `/market/download/${id}`, { body: await b.marketRequest('market.download', { listingId: id }, t()) })).json();
    for (const f of dl.files) {
      const r = await worker.fetch(new Request(`https://suhyeok.pickuma.com${f.url}`), e);
      assert.equal(r.status, 200, f.path);
      assert.equal(await bytesSha(new Uint8Array(await r.arrayBuffer())), f.sha256);
    }
    for (const p of [`/market/files/${dl.token}/..%2Fmanifest.json`, `/market/files/${dl.token}/frames%2F..%2F..%2Fsprite.png`,
      `/market/files/${dl.token}/manifest.json`]) {
      assert.equal((await req(e, 'GET', p)).status, 404, p);
    }
    assert.equal((await req(e, 'GET', `/market/files/${'a'.repeat(64)}/sprite.png`)).status, 403);

    const mineRes = await (await req(e, 'POST', '/market/mine', { body: await a.marketRequest('market.mine', {}, t()) })).json();
    assert.deepEqual([mineRes.pendingIncome, mineRes.listings[0].sales, mineRes.listings[0].earned], [270, 1, 270]);
    const bal = await openEnvelope(await (await req(e, 'GET', `/balance/${a.id}`)).json(), key);
    assert.equal(bal.pendingIncome, 270);

    const v = await (await req(e, 'GET', '/admin/verify', { token: ADMIN })).json();
    assert.deepEqual([v.ok, v.balancesMatch, v.pendingIncomeMatch, v.listingsMatch, v.burned], [true, true, true, true, 30]);
  });

  test('without the ASSETS binding the market answers 503 and the ledger still works', async () => {
    delete e.ASSETS;
    assert.equal((await req(e, 'GET', '/market/listings')).status, 503);
    assert.equal((await req(e, 'GET', '/pubkey')).status, 200);
  });
});

// --- migration

test('migrations/0002_market.sql brings a pre-market database to the fresh schema', async () => {
  const { DatabaseSync } = await import('node:sqlite');
  const fresh = readFileSync(new URL('../schema.sql', import.meta.url), 'utf8');
  const migration = readFileSync(new URL('../migrations/0002_market.sql', import.meta.url), 'utf8');
  // The pre-market schema: no market tables, no new device columns.
  const marker = fresh.indexOf('-- Character market');
  assert.ok(marker > 0);
  const old = fresh.slice(0, marker)
    .replace(/\n\s*pending_income[^\n]*\n\s*last_market_req[^\n]*/, '')
    .replace('last_spend_req  INTEGER NOT NULL,', 'last_spend_req  INTEGER NOT NULL');
  assert.ok(!old.includes('pending_income'));

  const describeDb = (db) => {
    const objects = db.prepare("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").all();
    const columns = objects.filter((o) => o.type === 'table')
      .map((o) => [o.name, db.prepare(`PRAGMA table_info(${o.name})`).all().map((c) => [c.name, c.type, c.notnull, c.dflt_value, c.pk])]);
    return { objects: objects.map((o) => `${o.type}:${o.name}`), columns };
  };
  const a = new DatabaseSync(':memory:');
  a.exec(fresh);
  const b = new DatabaseSync(':memory:');
  b.exec(old);
  b.prepare(`INSERT INTO devices (id, key, registered_at, revoked_at, last_seq, last_hash, last_time, balance, pending_clamp, pending_genesis, last_spend_req)
    VALUES ('d', 'k', 1, NULL, -1, '', NULL, 5, 0, 0, 0)`).run();
  b.exec(migration);
  const fa = describeDb(a), fb = describeDb(b);
  assert.deepEqual(fb.objects, fa.objects);
  // Column order differs only where ALTER appends; compare as sets per table.
  const norm = (cols) => Object.fromEntries(cols.map(([t, c]) => [t, c.map((x) => JSON.stringify(x)).sort()]));
  assert.deepEqual(norm(fb.columns), norm(fa.columns));
  assert.deepEqual({ ...b.prepare('SELECT pending_income, last_market_req, balance FROM devices').get() }, { pending_income: 0, last_market_req: 0, balance: 5 });
});

test('the asset vectors used here exist', () => {
  for (const n of ['ok_minimal', 'ok_knight', 'svg_sprite', 'map_kind']) assert.ok(readdirSync(VECTORS).includes(n), n);
});
