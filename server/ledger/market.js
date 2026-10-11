// Character market (docs/plans/2026-10-11-002-feat-asset-market-plan.md, U3/U4): seller drafts, per-file
// uploads, admin moderation, purchases paid in crystals, and owner-only downloads. HTTP-free like ledger.js.
//
// Storage interface, in addition to the one documented in ledger.js (D1Store in worker.js, MemoryStore in tests):
//   getListing(id) -> listing | null
//   listListings({status?, seller?}) -> listing[] (oldest first)
//   listListingFiles(listingId) -> [{listingId, path, sha256, bytes}]
//   getOwner(listingId, device) -> owner | null          countOwners(listingId) -> number
//   getToken(token) -> {token, device, listingId, expiresAt} | null
//   commit({..., listings, listingFiles, owners, tokens, pruneTokensBefore})
// listing = {id, seller, kind, name, description, alias, price, status, reason, manifest, createdAt, updatedAt}
// owner = {listingId, device, serverSeq, price, reqTime, body, sig}
//
// Blob storage (R2 binding ASSETS, or a fake in tests): put(key, bytes, {httpMetadata}), get(key) -> {body} | null.
// Keys are always assets/<listingId>/<sha256 of the bytes>: never derived from a path in a request.
//
// Status: draft -> pending -> approved | rejected; approved -> delisted; draft -> withdrawn. Every change
// (creation included) appends a 'moderate' ledger row (amount 0, device = seller, ref '<listingId>:<status>',
// reported = price on the draft row, note = reason), so the history and price are reconstructible from the
// ledger; listings.status is a cache that verify() checks.
//
// Signed requests: P-256 raw r||s over stableStringify({action, ...fields, device, time}) like /spend, with
// time within SPEND_REQUEST_SKEW_SEC of server time. State-changing requests (draft, submit, withdraw, buy)
// must also be strictly newer than the device's previous one (devices.lastMarketReq, separate from the /spend
// guard so a hire and a purchase in the same second do not collide). Reads and the idempotent, content-pinned
// file upload only check the time window.
import { classifyPath, validateFile, validateManifest, SPEC } from './assets.js';
import {
  CONFIG, chainRows, fail, importDeviceKey, isInt, liveDeviceIn, sha256hex, stableStringify, transactWith, verifyDeviceSig,
} from './ledger.js';

export const MARKET = {
  PRICE_MIN: 50,
  PRICE_MAX: 5000,
  SELLER_SHARE_PCT: 90, // the rest of the price is burned
  MAX_OPEN_LISTINGS: 5, // drafts + pending per seller device
  TOKEN_TTL_SEC: 600,
  ALIAS_MAX: 24,
  DESCRIPTION_MAX: 500,
  REASON_MAX: 500,
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const TOKEN = /^[0-9a-f]{64}$/;
const CONTENT_TYPES = { png: 'image/png', jpeg: 'image/jpeg' };

export const blobKey = (listingId, sha256) => `assets/${listingId}/${sha256}`;
export const sellerShare = (price) => Math.floor((price * MARKET.SELLER_SHARE_PCT) / 100);
export const contentTypeOf = (path) => CONTENT_TYPES[classifyPath(path)?.format] ?? null;
export const sellerTag = (device) => device.slice(0, 8);

async function sha256bytes(bytes) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return [...d].map((x) => x.toString(16).padStart(2, '0')).join('');
}

/** Free text from a seller: bounded length, no control characters (newlines allowed when multiline). */
function text(v, max, { multiline = false } = {}) {
  if (v === undefined) return '';
  const ctl = multiline ? /[\u0000-\u0009\u000b-\u001f\u007f]/ : /[\u0000-\u001f\u007f]/;
  if (typeof v !== 'string' || [...v].length > max || ctl.test(v)) return null;
  return v.trim();
}

export function createMarket({
  store, signer, blobs, now = () => Math.floor(Date.now() / 1000), config = CONFIG, market = MARKET, base = '/ledger/v1',
}) {
  const transact = (fn) => transactWith(fn, config.COMMIT_RETRIES);

  async function checkSig(dev, action, fields, time, sig) {
    if (!isInt(time) || typeof sig !== 'string') fail(400, 'bad_request', 'time (unix seconds) and sig required');
    const canon = stableStringify({ ...fields, action, device: dev.id, time });
    if (!(await verifyDeviceSig(await importDeviceKey(dev.key), canon, sig))) fail(422, 'bad_signature');
  }

  function checkFresh(dev, time, { monotonic }) {
    const t = now();
    if (Math.abs(time - t) > config.SPEND_REQUEST_SKEW_SEC) fail(422, 'bad_time', 'request time too far from server time', { serverTime: t });
    if (monotonic && time <= (dev.lastMarketReq ?? 0)) fail(409, 'replay', 'request time must be newer than the previous market request');
  }

  async function sellersListing(dev, listingId) {
    const l = typeof listingId === 'string' && UUID.test(listingId) ? await store.getListing(listingId) : null;
    if (!l) fail(404, 'not_found');
    if (l.seller !== dev.id) fail(403, 'not_seller');
    return l;
  }

  const moderateRow = (l, status, note = '') => ({
    kind: 'moderate', device: l.seller, ref: `${l.id}:${status}`, note, reported: status === 'draft' ? l.price : 0,
  });

  /** Paths the manifest lists that have not been uploaded yet. */
  async function missingFiles(l) {
    const listed = Object.entries(JSON.parse(l.manifest).files);
    const have = new Map((await store.listListingFiles(l.id)).map((f) => [f.path, f.sha256]));
    return listed.filter(([path, f]) => have.get(path) !== f.sha256).map(([path]) => path).sort();
  }

  /** One state change: a moderate row plus the cached status. `head` must be read before the listing. */
  async function transition(head, l, status, { reason = '', dev = null, time = null } = {}) {
    const t = now();
    const rows = await chainRows(head, [moderateRow(l, status, reason)], t);
    await store.commit({
      ledger: rows,
      listings: [{ ...l, status, reason, updatedAt: t }],
      devices: dev ? [{ ...dev, lastMarketReq: time }] : [],
    });
    return { listingId: l.id, status, reason, serverSeq: rows[0].seq };
  }

  // --- seller (U3)

  async function createDraft({ device, manifest, price, alias, description, time, sig } = {}) {
    return transact(async () => {
      const head = await store.getHead();
      const dev = await liveDeviceIn(store, device);
      const a = text(alias, market.ALIAS_MAX);
      const d = text(description, market.DESCRIPTION_MAX, { multiline: true });
      if (typeof manifest !== 'string' || !isInt(price) || a === null || d === null) {
        fail(400, 'bad_request', 'manifest (manifest.json text), price (int), optional alias/description strings required');
      }
      const manifestSha256 = await sha256hex(manifest);
      await checkSig(dev, 'market.draft', { alias: alias ?? '', description: description ?? '', manifestSha256, price }, time, sig);
      checkFresh(dev, time, { monotonic: true });
      if (price < market.PRICE_MIN || price > market.PRICE_MAX) {
        fail(400, 'bad_price', `price must be ${market.PRICE_MIN}..${market.PRICE_MAX}`, { min: market.PRICE_MIN, max: market.PRICE_MAX });
      }
      const { manifest: m, errors } = validateManifest(manifest);
      if (!m || errors.length) fail(422, 'invalid_pack', 'manifest does not meet the pack spec', { errors });
      const open = (await store.listListings({ seller: dev.id })).filter((l) => l.status === 'draft' || l.status === 'pending');
      if (open.length >= market.MAX_OPEN_LISTINGS) fail(429, 'too_many_open', `at most ${market.MAX_OPEN_LISTINGS} drafts or pending listings`);
      const t = now();
      const l = {
        id: crypto.randomUUID(), seller: dev.id, kind: m.kind, name: m.name.trim(), description: d, alias: a, price,
        status: 'draft', reason: '', manifest, createdAt: t, updatedAt: t,
      };
      const rows = await chainRows(head, [moderateRow(l, 'draft')], t);
      await store.commit({ ledger: rows, listings: [l], devices: [{ ...dev, lastMarketReq: time }] });
      return { listingId: l.id, status: 'draft', serverSeq: rows[0].seq, missing: Object.keys(m.files).sort() };
    });
  }

  async function uploadFile({ listingId, path, bytes, device, time, sig } = {}) {
    const dev = await liveDeviceIn(store, device);
    if (!(bytes instanceof Uint8Array) || typeof path !== 'string') fail(400, 'bad_request');
    if (bytes.length > SPEC.MAX_FILE) fail(413, 'too_large', `at most ${SPEC.MAX_FILE} bytes per file`);
    const l = await sellersListing(dev, listingId);
    const sha256 = await sha256bytes(bytes);
    await checkSig(dev, 'market.file', { listingId: l.id, path, sha256 }, time, sig);
    checkFresh(dev, time, { monotonic: false });
    if (l.status !== 'draft') fail(409, 'bad_state', `listing is ${l.status}`, { status: l.status });
    const { manifest } = validateManifest(l.manifest);
    const errors = await validateFile(manifest, path, bytes);
    if (errors.length) fail(422, 'invalid_file', 'file does not match the manifest or the pack spec', { errors });
    await blobs.put(blobKey(l.id, sha256), bytes, { httpMetadata: { contentType: contentTypeOf(path) } });
    await store.commit({ listingFiles: [{ listingId: l.id, path, sha256, bytes: bytes.length }] });
    return { listingId: l.id, path, sha256, bytes: bytes.length, missing: await missingFiles(l) };
  }

  async function submit({ listingId, device, time, sig } = {}) {
    return transact(async () => {
      const head = await store.getHead();
      const dev = await liveDeviceIn(store, device);
      const l = await sellersListing(dev, listingId);
      await checkSig(dev, 'market.submit', { listingId: l.id }, time, sig);
      checkFresh(dev, time, { monotonic: true });
      if (l.status !== 'draft') fail(409, 'bad_state', `listing is ${l.status}`, { status: l.status });
      const missing = await missingFiles(l);
      if (missing.length) fail(409, 'missing_files', `${missing.length} listed files not uploaded`, { missing });
      return transition(head, l, 'pending', { dev, time });
    });
  }

  async function withdraw({ listingId, device, time, sig } = {}) {
    return transact(async () => {
      const head = await store.getHead();
      const dev = await liveDeviceIn(store, device);
      const l = await sellersListing(dev, listingId);
      await checkSig(dev, 'market.withdraw', { listingId: l.id }, time, sig);
      checkFresh(dev, time, { monotonic: true });
      if (l.status !== 'draft') fail(409, 'bad_state', `listing is ${l.status}`, { status: l.status });
      return transition(head, l, 'withdrawn', { dev, time });
    });
  }

  async function mine({ device, time, sig } = {}) {
    const dev = await liveDeviceIn(store, device);
    await checkSig(dev, 'market.mine', {}, time, sig);
    checkFresh(dev, time, { monotonic: false });
    const listings = [];
    for (const l of await store.listListings({ seller: dev.id })) {
      const sales = await store.countOwners(l.id);
      listings.push({
        id: l.id, kind: l.kind, name: l.name, description: l.description, alias: l.alias, price: l.price, status: l.status,
        reason: l.reason, createdAt: l.createdAt, updatedAt: l.updatedAt, sales, earned: sales * sellerShare(l.price),
        missing: l.status === 'draft' ? await missingFiles(l) : [],
      });
    }
    return { device: dev.id, balance: dev.balance, pendingIncome: dev.pendingIncome ?? 0, listings: listings.reverse() };
  }

  // --- public catalogue

  const previewPath = (l, role) => {
    const path = Object.keys(JSON.parse(l.manifest).files).find((p) => classifyPath(p)?.role === role);
    return `${base}/market/preview/${l.id}/${path}`;
  };

  async function listings() {
    const out = [];
    for (const l of (await store.listListings({ status: 'approved' })).reverse()) {
      out.push({
        id: l.id, kind: l.kind, name: l.name, description: l.description, price: l.price,
        seller: { tag: sellerTag(l.seller), alias: l.alias }, sales: await store.countOwners(l.id), approvedAt: l.updatedAt,
        previews: { portrait: previewPath(l, 'portrait'), sprite: previewPath(l, 'sprite') },
      });
    }
    return { listings: out };
  }

  /** A listing file for display. Public: portrait and sprite of approved listings. Admin: any file, any status. */
  async function preview(listingId, path, { admin = false } = {}) {
    const l = typeof listingId === 'string' && UUID.test(listingId) ? await store.getListing(listingId) : null;
    const role = classifyPath(path)?.role;
    if (!l || !role || (!admin && (l.status !== 'approved' || role === 'frame'))) fail(404, 'not_found');
    return blobFor(l.id, path);
  }

  async function blobFor(listingId, path) {
    const f = (await store.listListingFiles(listingId)).find((x) => x.path === path);
    const obj = f ? await blobs.get(blobKey(listingId, f.sha256)) : null;
    if (!obj) fail(404, 'not_found');
    return { body: obj.body, contentType: contentTypeOf(path), sha256: f.sha256, bytes: f.bytes };
  }

  // --- buyer (U4)

  async function buy({ device, listingId, price, time, sig } = {}) {
    return transact(async () => {
      const head = await store.getHead();
      const t = now();
      const dev = await liveDeviceIn(store, device);
      if (typeof listingId !== 'string' || !UUID.test(listingId) || !isInt(price)) fail(400, 'bad_request', 'listingId (uuid) and price (int) required');
      await checkSig(dev, 'market.buy', { listingId, price }, time, sig);
      const l = await store.getListing(listingId);
      if (!l) fail(404, 'not_found');
      const owned = await store.getOwner(l.id, dev.id);
      if (owned) {
        // A retry of the request that bought it (lost response) gets the same receipt; anything else is a re-buy.
        if (owned.reqTime === time && owned.price === price) return { body: owned.body, sig: owned.sig };
        fail(409, 'already_owned');
      }
      checkFresh(dev, time, { monotonic: true });
      if (l.seller === dev.id) fail(409, 'own_listing');
      if (l.status !== 'approved') fail(409, 'not_for_sale', `listing is ${l.status}`, { status: l.status });
      if (price !== l.price) fail(409, 'price_mismatch', `listing price is ${l.price}`, { price: l.price });
      const seller = await store.getDevice(l.seller);
      if (!seller || seller.revokedAt != null) fail(409, 'not_for_sale', 'seller device is revoked', { status: l.status });
      if (dev.balance < price) fail(409, 'insufficient', `balance ${dev.balance}`, { balance: dev.balance });

      const item = `market:${l.id}`;
      const credit = sellerShare(price);
      const burned = price - credit;
      const rows = await chainRows(head, [
        { kind: 'reserve', device: dev.id, amount: -price, reported: price, ref: item },
        { kind: 'sale', device: seller.id, amount: credit, reported: price, ref: item },
        { kind: 'burn', device: '', amount: burned, reported: price, ref: item, note: `buyer:${dev.id}` },
      ], t);
      const balance = dev.balance - price;
      const env = await signer.envelope({
        type: 'buy', device: dev.id, listingId: l.id, item, amount: price, balance, seller: seller.id, sellerCredit: credit,
        burned, serverSeq: rows[0].seq, head: rows.at(-1).hash, time: t,
      });
      await store.commit({
        ledger: rows,
        devices: [
          { ...dev, balance, lastMarketReq: time },
          { ...seller, balance: seller.balance + credit, pendingIncome: (seller.pendingIncome ?? 0) + credit },
        ],
        reservations: [{ serverSeq: rows[0].seq, device: dev.id, item, amount: price, reqTime: time, consumedSeq: null, ...env }],
        owners: [{ listingId: l.id, device: dev.id, serverSeq: rows[0].seq, price, reqTime: time, ...env }],
      });
      return env;
    });
  }

  async function download({ listingId, device, time, sig } = {}) {
    const dev = await liveDeviceIn(store, device);
    const l = typeof listingId === 'string' && UUID.test(listingId) ? await store.getListing(listingId) : null;
    if (!l) fail(404, 'not_found');
    await checkSig(dev, 'market.download', { listingId: l.id }, time, sig);
    checkFresh(dev, time, { monotonic: false });
    // Owners keep access after a delisting (R17). The seller may fetch their own pack.
    if (l.seller !== dev.id && !(await store.getOwner(l.id, dev.id))) fail(403, 'not_owner');
    const t = now();
    const token = [...crypto.getRandomValues(new Uint8Array(32))].map((b) => b.toString(16).padStart(2, '0')).join('');
    const expiresAt = t + market.TOKEN_TTL_SEC;
    await store.commit({ tokens: [{ token, device: dev.id, listingId: l.id, expiresAt }], pruneTokensBefore: t });
    const files = (await store.listListingFiles(l.id)).map((f) => ({
      path: f.path, sha256: f.sha256, bytes: f.bytes, url: `${base}/market/files/${token}/${f.path}`,
    }));
    return { listingId: l.id, token, expiresAt, manifest: l.manifest, files };
  }

  async function fileByToken(token, path) {
    const tok = typeof token === 'string' && TOKEN.test(token) ? await store.getToken(token) : null;
    if (!tok) fail(403, 'bad_token');
    if (now() > tok.expiresAt) fail(403, 'token_expired');
    if (!classifyPath(path)) fail(404, 'not_found');
    return blobFor(tok.listingId, path);
  }

  // --- admin (U3)

  async function listPending() {
    const out = [];
    for (const l of await store.listListings({ status: 'pending' })) {
      const history = { approved: 0, rejected: 0, delisted: 0, pending: 0 };
      for (const x of await store.listListings({ seller: l.seller })) if (x.status in history) history[x.status] += 1;
      const files = (await store.listListingFiles(l.id)).map((f) => ({
        path: f.path, sha256: f.sha256, bytes: f.bytes, url: `${base}/admin/market/${l.id}/files/${f.path}`,
      }));
      out.push({
        id: l.id, kind: l.kind, name: l.name, description: l.description, price: l.price, seller: l.seller,
        sellerTag: sellerTag(l.seller), alias: l.alias, submittedAt: l.updatedAt, history, manifest: JSON.parse(l.manifest), files,
      });
    }
    return { pending: out };
  }

  const MODERATION = {
    approve: { from: 'pending', to: 'approved', reason: false },
    reject: { from: 'pending', to: 'rejected', reason: true },
    delist: { from: 'approved', to: 'delisted', reason: true },
  };

  async function moderate(listingId, action, { reason } = {}) {
    const rule = MODERATION[action];
    if (!rule) fail(400, 'bad_request');
    let why = '';
    if (rule.reason) {
      why = text(reason, market.REASON_MAX, { multiline: true });
      if (!why) fail(400, 'reason_required', `a reason (1..${market.REASON_MAX} chars) is required to ${action}`);
    }
    return transact(async () => {
      const head = await store.getHead();
      const l = typeof listingId === 'string' && UUID.test(listingId) ? await store.getListing(listingId) : null;
      if (!l) fail(404, 'not_found');
      if (l.status !== rule.from) fail(409, 'bad_state', `listing is ${l.status}`, { status: l.status });
      return transition(head, l, rule.to, { reason: why });
    });
  }

  return { createDraft, uploadFile, submit, withdraw, mine, listings, preview, buy, download, fileByToken, listPending, moderate };
}
