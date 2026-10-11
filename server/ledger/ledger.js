// Crystal ledger issuing server: verification and accounting logic, independent of D1 and HTTP.
// Runs on Cloudflare Workers and on Node 20+ (tests): uses only globalThis.crypto (WebCrypto).
//
// Storage interface (see D1Store in worker.js and MemoryStore in test/helpers.js):
//   getHead() -> {seq, hash} | null
//   getDevice(id) / getDeviceByKey(key) -> device | null
//   getCode(code) -> code | null
//   getEntryHashes(device, fromSeq, toSeq) -> Map<deviceSeq, deviceHash>   (from 'entry' ledger rows)
//   getReceiptCovering(device, deviceSeq) -> {body, sig} | null             (receipt with the smallest dseq >= deviceSeq)
//   listOpenReservations(device) -> reservation[]
//   getGenesis(serverSeq) / listPendingGenesis()
//   listLedger() / listDevices()
//   commit({ledger, devices, codes, receipts, reservations, genesis}) -> atomically appends ledger rows and
//     upserts the rest. Throws ConflictError when ledger rows do not start right after the current head.
//
// Concurrency: every operation that writes reads the head FIRST and appends at least one ledger row, so the
// ledger's seq primary key serialises writers (optimistic lock). A losing writer gets ConflictError and is retried.

export const CONFIG = {
  // KTD5 rate cap: crystals per hour of wall-clock time between acknowledged entries. Tune after measuring.
  EARN_PER_HOUR_PER_AGENT: 18, // 3 per 10 minutes of activity
  MAX_PARALLEL_AGENTS: 4,
  BONUS_PER_HOUR: 40, // turn bonus 30 + commit bonus 10
  // First sync of a device: the cap window starts this long before registration (offline earnings before
  // the server was switched on). Older history belongs in a genesis entry, which an admin approves.
  FIRST_SYNC_LOOKBACK_SEC: 7 * 24 * 3600,
  FUTURE_SKEW_SEC: 300, // entries may be at most this far ahead of server time
  SPEND_REQUEST_SKEW_SEC: 300, // spend requests must be signed within this window of server time
  CODE_TTL_SEC: 7 * 24 * 3600,
  MAX_BATCH: 500,
  MAX_STRING: 4096,
  COMMIT_RETRIES: 3,
};

export const ZERO_HASH = '0'.repeat(64);
const KINDS = new Set(['open', 'genesis', 'earn', 'spend', 'adjust']);
const HEX64 = /^[0-9a-f]{64}$/;
const ENTRY_FIELDS = new Set(['seq', 'time', 'kind', 'source', 'amount', 'rule', 'note', 'key', 'prev', 'hash', 'sig']);

export class LedgerError extends Error {
  constructor(status, code, message, extra = {}) {
    super(message ?? code);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
  toJSON() { return { error: this.code, message: this.message, ...this.extra }; }
}
export class ConflictError extends Error {}

const fail = (status, code, message, extra) => { throw new LedgerError(status, code, message, extra); };

// --- encoding

const utf8 = (s) => new TextEncoder().encode(s);

export function b64encode(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

export function b64decode(s) {
  try { return Uint8Array.from(atob(s), (c) => c.charCodeAt(0)); } catch { return null; }
}

/** JSON with object keys sorted (UTF-16 order; all keys here are ASCII), no whitespace, JSON.stringify escaping. */
export function stableStringify(v) {
  if (Array.isArray(v)) return '[' + v.map(stableStringify).join(',') + ']';
  if (v !== null && typeof v === 'object') {
    return '{' + Object.keys(v).filter((k) => v[k] !== undefined).sort()
      .map((k) => JSON.stringify(k) + ':' + stableStringify(v[k])).join(',') + '}';
  }
  return JSON.stringify(v);
}

/** The bytes a device entry's hash and signature cover: every field but hash and sig; key only when present. */
export function entryCanonical(e) {
  const f = { amount: e.amount, kind: e.kind, note: e.note, prev: e.prev, rule: e.rule, seq: e.seq, source: e.source, time: e.time };
  if (e.key != null) f.key = e.key;
  return stableStringify(f);
}

export async function sha256hex(text) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', utf8(text)));
  return [...d].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// --- device keys (ECDSA P-256, X9.63 uncompressed, raw r||s signatures)

export async function importDeviceKey(b64) {
  const raw = typeof b64 === 'string' ? b64decode(b64) : null;
  if (!raw || raw.length !== 65 || raw[0] !== 4) return null;
  try {
    return await crypto.subtle.importKey('raw', raw, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
  } catch { return null; }
}

async function verifyDeviceSig(key, text, sigB64) {
  const sig = typeof sigB64 === 'string' ? b64decode(sigB64) : null;
  if (!sig || sig.length !== 64) return false;
  return crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, sig, utf8(text));
}

// --- server signing key (Ed25519)

/**
 * LEDGER_SIGNING_KEY = base64 of the PKCS#8 DER Ed25519 private key (scripts/genkey.mjs prints one).
 * The public key (base64 of the raw 32 bytes) is derived from it via JWK export.
 */
export async function createSigner(pkcs8B64) {
  const der = pkcs8B64 ? b64decode(pkcs8B64) : null;
  if (!der) throw new Error('LEDGER_SIGNING_KEY missing or not base64');
  const priv = await crypto.subtle.importKey('pkcs8', der, { name: 'Ed25519' }, true, ['sign']);
  const { x } = await crypto.subtle.exportKey('jwk', priv);
  const publicKey = btoa(atob(x.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (x.length % 4)) % 4)));
  return {
    publicKey,
    /** A signed response: `body` is the exact signed UTF-8 text, `sig` base64 of the 64-byte Ed25519 signature. */
    async envelope(obj) {
      const body = stableStringify(obj);
      const sig = new Uint8Array(await crypto.subtle.sign({ name: 'Ed25519' }, priv, utf8(body)));
      return { body, sig: b64encode(sig) };
    },
  };
}

// --- server ledger rows

const ROW_DEFAULTS = { device: '', kind: '', amount: 0, dseq: -1, dhash: '', dkind: '', reported: 0, ref: '', note: '' };

export function rowCanonical(r) {
  const { seq, time, device, kind, amount, dseq, dhash, dkind, reported, ref, note, prev } = r;
  return stableStringify({ seq, time, device, kind, amount, dseq, dhash, dkind, reported, ref, note, prev });
}

async function chainRows(head, specs, time) {
  let prev = head ? head.hash : ZERO_HASH;
  let seq = head ? head.seq + 1 : 0;
  const rows = [];
  for (const s of specs) {
    const row = { ...ROW_DEFAULTS, ...s, seq: seq++, time, prev };
    row.hash = await sha256hex(rowCanonical(row));
    rows.push(row);
    prev = row.hash;
  }
  return rows;
}

/** Recomputes the server ledger hash chain. Also derives each device's balance (sum of row amounts). */
export async function verifyServerLedger(rows) {
  const sorted = [...rows].sort((a, b) => a.seq - b.seq);
  const balances = {};
  let prev = ZERO_HASH;
  for (let i = 0; i < sorted.length; i++) {
    const r = sorted[i];
    const broken = (reason) => ({ ok: false, length: sorted.length, brokenAt: i, reason, balances });
    if (r.seq !== i) return broken('seq gap');
    if (r.prev !== prev) return broken('prev mismatch');
    if (r.hash !== (await sha256hex(rowCanonical(r)))) return broken('hash mismatch');
    if (r.device) balances[r.device] = (balances[r.device] ?? 0) + r.amount;
    prev = r.hash;
  }
  return { ok: true, length: sorted.length, head: sorted.length ? prev : null, balances };
}

// --- validation

const isInt = (v) => Number.isSafeInteger(v);
const isStr = (v, max = CONFIG.MAX_STRING) => typeof v === 'string' && v.length <= max;

function validateEntry(e, i) {
  const bad = (why) => fail(400, 'bad_entry', `entry ${i}: ${why}`, { index: i });
  if (!e || typeof e !== 'object' || Array.isArray(e)) bad('not an object');
  for (const k of Object.keys(e)) if (!ENTRY_FIELDS.has(k)) bad(`unknown field ${k}`);
  if (!isInt(e.seq) || e.seq < 0) bad('seq');
  if (!isInt(e.time) || e.time < 0) bad('time');
  if (!KINDS.has(e.kind)) bad('kind');
  if (!isStr(e.source) || !isStr(e.note)) bad('source/note');
  if (!isInt(e.amount) || !isInt(e.rule)) bad('amount/rule');
  if (typeof e.prev !== 'string' || !HEX64.test(e.prev) || typeof e.hash !== 'string' || !HEX64.test(e.hash)) bad('prev/hash');
  if (typeof e.sig !== 'string') bad('sig');
  const isOpen = e.kind === 'open';
  if (isOpen !== (e.seq === 0)) bad('only seq 0 is the open entry');
  if (isOpen ? !(typeof e.key === 'string' && e.amount === 0) : e.key !== undefined) bad('key/open');
  if ((e.kind === 'earn' || e.kind === 'genesis') && e.amount < 0) bad('earn/genesis amount must be >= 0');
  if (e.kind === 'spend' && e.amount > 0) bad('spend amount must be <= 0');
}

// --- service

export function createLedger({ store, signer, now = () => Math.floor(Date.now() / 1000), config = CONFIG }) {
  const ratePerHour = config.EARN_PER_HOUR_PER_AGENT * config.MAX_PARALLEL_AGENTS + config.BONUS_PER_HOUR;

  async function transact(fn) {
    for (let attempt = 0; ; attempt++) {
      try { return await fn(); } catch (e) {
        if (!(e instanceof ConflictError) || attempt + 1 >= config.COMMIT_RETRIES) {
          if (e instanceof ConflictError) fail(409, 'busy', 'concurrent write, retry');
          throw e;
        }
      }
    }
  }

  async function liveDevice(id) {
    const dev = typeof id === 'string' ? await store.getDevice(id) : null;
    if (!dev) fail(404, 'unknown_device');
    if (dev.revokedAt != null) fail(403, 'revoked');
    return dev;
  }

  async function issueCode({ ttlSec } = {}) {
    const ttl = isInt(ttlSec) && ttlSec > 0 ? ttlSec : config.CODE_TTL_SEC;
    const alphabet = 'ABCDEFGHJKMNPQRSTVWXYZ23456789';
    const bytes = crypto.getRandomValues(new Uint8Array(12));
    const chars = [...bytes].map((b) => alphabet[b % alphabet.length]).join('');
    const code = `${chars.slice(0, 4)}-${chars.slice(4, 8)}-${chars.slice(8)}`;
    const t = now();
    await store.commit({ codes: [{ code, createdAt: t, expiresAt: t + ttl, usedAt: null, device: null }] });
    return { code, expiresAt: t + ttl };
  }

  async function register({ code, key } = {}) {
    if (code == null || code === '') fail(400, 'code_required');
    if (!isStr(code, 64) || !isStr(key, 200)) fail(400, 'bad_request');
    if (!(await importDeviceKey(key))) fail(400, 'bad_key', 'key must be base64 of a 65-byte X9.63 P-256 point');
    return transact(async () => {
      const head = await store.getHead();
      const t = now();
      const c = await store.getCode(code);
      if (!c) fail(403, 'invalid_code');
      if (c.usedAt != null) fail(409, 'code_used');
      if (t > c.expiresAt) fail(403, 'code_expired');
      if (await store.getDeviceByKey(key)) fail(409, 'key_registered');
      const id = crypto.randomUUID();
      const rows = await chainRows(head, [{ kind: 'register', device: id, ref: key }], t);
      await store.commit({
        ledger: rows,
        devices: [{ id, key, registeredAt: t, revokedAt: null, lastSeq: -1, lastHash: ZERO_HASH, lastTime: null,
          balance: 0, pendingClamp: 0, pendingGenesis: 0, lastSpendReq: 0 }],
        codes: [{ ...c, usedAt: t, device: id }],
      });
      return { device: id, serverSeq: rows[0].seq };
    });
  }

  async function sync({ device, entries } = {}) {
    return transact(async () => {
      const head = await store.getHead();
      const t = now();
      // 1. registered and not revoked
      const dev = await liveDevice(device);
      if (!Array.isArray(entries) || entries.length === 0) fail(400, 'bad_request', 'entries must be a non-empty array');
      if (entries.length > config.MAX_BATCH) fail(413, 'batch_too_large', `at most ${config.MAX_BATCH} entries`);
      entries.forEach(validateEntry);

      // 2. every entry's hash and signature, against the registered key
      const pub = await importDeviceKey(dev.key);
      for (const e of entries) {
        const canon = entryCanonical(e);
        if ((await sha256hex(canon)) !== e.hash) fail(422, 'bad_hash', `entry ${e.seq}`, { seq: e.seq });
        if (!(await verifyDeviceSig(pub, canon, e.sig))) fail(422, 'bad_signature', `entry ${e.seq}`, { seq: e.seq });
      }

      // 3. chain continuity: inside the batch, then to the last acknowledged entry
      for (let i = 1; i < entries.length; i++) {
        if (entries[i].seq !== entries[i - 1].seq + 1 || entries[i].prev !== entries[i - 1].hash) {
          fail(409, 'chain_break', `entry ${entries[i].seq}`, { seq: entries[i].seq });
        }
      }
      const last = entries.at(-1);
      let fresh = entries;
      if (entries[0].seq <= dev.lastSeq) {
        // Retry: the acknowledged part must be exactly what was acknowledged.
        const upTo = Math.min(last.seq, dev.lastSeq);
        const known = await store.getEntryHashes(dev.id, entries[0].seq, upTo);
        for (const e of entries) {
          if (e.seq <= upTo && known.get(e.seq) !== e.hash) fail(409, 'fork', `entry ${e.seq} differs from the acknowledged one`, { seq: e.seq });
        }
        if (last.seq <= dev.lastSeq) {
          const receipt = await store.getReceiptCovering(dev.id, last.seq);
          if (!receipt) fail(500, 'receipt_missing');
          return receipt;
        }
        fresh = entries.filter((e) => e.seq > dev.lastSeq);
      }
      const first = fresh[0];
      if (dev.lastSeq === -1) {
        if (first.seq !== 0 || first.prev !== ZERO_HASH) fail(409, 'chain_break', 'first sync must start at the open entry (seq 0)', { seq: first.seq });
        if (first.key !== dev.key) fail(409, 'key_mismatch', 'open entry key differs from the registered key');
      } else if (first.seq !== dev.lastSeq + 1 || first.prev !== dev.lastHash) {
        fail(409, 'chain_break', `expected seq ${dev.lastSeq + 1} after ${dev.lastHash}`, { seq: first.seq, expectedSeq: dev.lastSeq + 1 });
      }

      // 4. time sanity
      let prevTime = dev.lastTime ?? -Infinity;
      for (const e of fresh) {
        if (e.time > t + config.FUTURE_SKEW_SEC) fail(422, 'future_time', `entry ${e.seq}`, { seq: e.seq, serverTime: t });
        if (e.time < prevTime) fail(422, 'time_backwards', `entry ${e.seq}`, { seq: e.seq });
        prevTime = e.time;
      }

      // 5. rate cap and accounting
      const windowStart = dev.lastSeq === -1 ? dev.registeredAt - config.FIRST_SYNC_LOOKBACK_SEC : dev.lastTime;
      let remaining = Math.max(0, Math.floor(((fresh.at(-1).time - windowStart) * ratePerHour) / 3600));
      let { balance, pendingClamp, pendingGenesis } = dev;
      let reported = 0, accepted = 0, pending = 0;
      const open = await store.listOpenReservations(dev.id);
      const consumed = [];
      const specs = [];
      for (const e of fresh) {
        let credited = 0;
        let ref = '';
        if (e.kind === 'genesis') {
          pending += e.amount; // not counted until approved; outside the cap
        } else if (e.amount > 0) { // earn, or a positive adjust: capped
          credited = Math.min(e.amount, remaining);
          remaining -= credited;
          reported += e.amount;
          accepted += credited;
        } else if (e.kind === 'adjust' && e.amount < 0) {
          // The device's answer to an earlier clamp: the server never credited that part, so absorb it.
          const absorb = Math.min(pendingClamp, -e.amount);
          pendingClamp -= absorb;
          credited = e.amount + absorb;
          if (absorb) ref = `clamp:${absorb}`;
        } else if (e.kind === 'spend' && e.amount < 0) {
          const i = open.findIndex((r) => r.item === e.source && r.amount === -e.amount);
          if (i >= 0) { // already deducted when the spend was confirmed
            const [r] = open.splice(i, 1);
            consumed.push(r);
            ref = `reserve:${r.serverSeq}`;
          } else {
            credited = e.amount;
          }
        }
        balance += credited;
        if (balance < 0) fail(409, 'insufficient', `entry ${e.seq} overdraws the balance`, { seq: e.seq, balance: balance - credited });
        specs.push({ kind: 'entry', device: dev.id, dseq: e.seq, dhash: e.hash, dkind: e.kind, reported: e.amount, amount: credited, ref });
      }
      const clamped = reported - accepted;
      pendingClamp += clamped;
      pendingGenesis += pending;

      // 6. append, sign, store
      const rows = await chainRows(head, specs, t);
      const top = rows.at(-1);
      const env = await signer.envelope({
        type: 'sync', device: dev.id, fromSeq: first.seq, deviceSeq: last.seq, deviceHash: last.hash,
        reported, accepted, clamped, pending, balance, pendingClamp,
        serverSeq: top.seq, head: top.hash, time: t,
      });
      const genesis = rows.filter((r) => r.dkind === 'genesis')
        .map((r) => ({ serverSeq: r.seq, device: dev.id, dseq: r.dseq, amount: r.reported, approvedSeq: null }));
      const reservations = consumed.map((r) => ({ ...r, consumedSeq: rows.find((x) => x.ref === `reserve:${r.serverSeq}`).seq }));
      await store.commit({
        ledger: rows,
        devices: [{ ...dev, lastSeq: last.seq, lastHash: last.hash, lastTime: last.time, balance, pendingClamp, pendingGenesis }],
        receipts: [{ device: dev.id, dseq: last.seq, ...env }],
        genesis,
        reservations,
      });
      return env;
    });
  }

  /** Spend confirmation: the device asks before writing its local spend entry; the server deducts now. */
  async function requestSpend({ device, item, amount, time, sig } = {}) {
    return transact(async () => {
      const head = await store.getHead();
      const t = now();
      const dev = await liveDevice(device);
      if (!isStr(item, 200) || item === '' || !isInt(amount) || amount <= 0 || !isInt(time) || typeof sig !== 'string') {
        fail(400, 'bad_request', 'item (non-empty string), amount (positive int), time (unix seconds), sig required');
      }
      const canon = stableStringify({ action: 'spend', amount, device: dev.id, item, time });
      if (!(await verifyDeviceSig(await importDeviceKey(dev.key), canon, sig))) fail(422, 'bad_signature');
      const existing = (await store.listOpenReservations(dev.id)).find((r) => r.item === item);
      if (existing) {
        if (existing.amount !== amount) fail(409, 'reservation_mismatch', `open reservation for ${item} is ${existing.amount}`);
        return { body: existing.body, sig: existing.sig };
      }
      if (Math.abs(time - t) > config.SPEND_REQUEST_SKEW_SEC) fail(422, 'bad_time', 'request time too far from server time', { serverTime: t });
      if (time <= dev.lastSpendReq) fail(409, 'replay', 'request time must be newer than the previous spend request');
      if (dev.balance < amount) fail(409, 'insufficient', `balance ${dev.balance}`, { balance: dev.balance });
      const balance = dev.balance - amount;
      const rows = await chainRows(head, [{ kind: 'reserve', device: dev.id, amount: -amount, reported: amount, ref: item }], t);
      const env = await signer.envelope({
        type: 'spend', device: dev.id, item, amount, balance, serverSeq: rows[0].seq, head: rows[0].hash, time: t,
      });
      await store.commit({
        ledger: rows,
        devices: [{ ...dev, balance, lastSpendReq: time }],
        reservations: [{ serverSeq: rows[0].seq, device: dev.id, item, amount, reqTime: time, consumedSeq: null, ...env }],
      });
      return env;
    });
  }

  async function balance(device) {
    const head = await store.getHead();
    const dev = typeof device === 'string' ? await store.getDevice(device) : null;
    if (!dev) fail(404, 'unknown_device');
    const reservations = (await store.listOpenReservations(dev.id)).map((r) => ({ item: r.item, amount: r.amount, serverSeq: r.serverSeq }));
    return signer.envelope({
      type: 'balance', device: dev.id, balance: dev.balance, pendingClamp: dev.pendingClamp, pendingGenesis: dev.pendingGenesis,
      reservations, deviceSeq: dev.lastSeq, deviceHash: dev.lastHash, revoked: dev.revokedAt != null,
      serverSeq: head ? head.seq : -1, head: head ? head.hash : ZERO_HASH, time: now(),
    });
  }

  async function listPendingGenesis() {
    return (await store.listPendingGenesis()).map(({ serverSeq, device, dseq, amount }) => ({ serverSeq, device, dseq, amount }));
  }

  async function approveGenesis(serverSeq) {
    return transact(async () => {
      const head = await store.getHead();
      const g = isInt(serverSeq) ? await store.getGenesis(serverSeq) : null;
      if (!g) fail(404, 'not_found', 'no genesis entry at that server seq');
      if (g.approvedSeq != null) fail(409, 'already_approved');
      const dev = await store.getDevice(g.device);
      const rows = await chainRows(head, [{ kind: 'approve', device: dev.id, amount: g.amount, reported: g.amount, ref: String(serverSeq) }], now());
      const balance = dev.balance + g.amount;
      await store.commit({
        ledger: rows,
        devices: [{ ...dev, balance, pendingGenesis: dev.pendingGenesis - g.amount }],
        genesis: [{ ...g, approvedSeq: rows[0].seq }],
      });
      return { serverSeq: rows[0].seq, device: dev.id, balance };
    });
  }

  async function revoke(device, note = '') {
    return transact(async () => {
      const head = await store.getHead();
      const dev = typeof device === 'string' ? await store.getDevice(device) : null;
      if (!dev) fail(404, 'unknown_device');
      if (dev.revokedAt != null) fail(409, 'already_revoked');
      const t = now();
      const rows = await chainRows(head, [{ kind: 'revoke', device: dev.id, note: isStr(note, 500) ? note : '' }], t);
      await store.commit({ ledger: rows, devices: [{ ...dev, revokedAt: t }] });
      return { serverSeq: rows[0].seq, device: dev.id };
    });
  }

  async function correct({ device, amount, note } = {}) {
    if (!isInt(amount) || amount === 0 || !isStr(note, 500) || note.trim() === '') {
      fail(400, 'bad_request', 'amount (non-zero int) and note (reason) required');
    }
    return transact(async () => {
      const head = await store.getHead();
      const dev = typeof device === 'string' ? await store.getDevice(device) : null;
      if (!dev) fail(404, 'unknown_device');
      const balance = dev.balance + amount;
      if (balance < 0) fail(409, 'insufficient', `balance ${dev.balance}`);
      const rows = await chainRows(head, [{ kind: 'correct', device: dev.id, amount, reported: amount, note }], now());
      await store.commit({ ledger: rows, devices: [{ ...dev, balance }] });
      return { serverSeq: rows[0].seq, device: dev.id, balance };
    });
  }

  /** Recomputes the chain and checks the cached device balances against the ledger. */
  async function verify() {
    const res = await verifyServerLedger(await store.listLedger());
    const devices = await store.listDevices();
    res.balancesMatch = devices.every((d) => (res.balances[d.id] ?? 0) === d.balance);
    return res;
  }

  return {
    publicKey: async () => ({ alg: 'Ed25519', key: signer.publicKey }),
    issueCode, register, sync, requestSpend, balance, listPendingGenesis, approveGenesis, revoke, correct, verify,
  };
}
