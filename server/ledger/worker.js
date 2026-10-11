// Crystal ledger issuing server (suhyeok.pickuma.com/ledger/*). Plain ES module, no build step.
// Env: DB (D1), LEDGER_SIGNING_KEY (secret, base64 PKCS#8 Ed25519), LEDGER_ADMIN_TOKEN (secret).
// Logic lives in ledger.js and anchor.js; this file is HTTP routing, the cron entry point, and the D1
// implementation of the storage interfaces.
import { createLedger, createSigner, ConflictError, LedgerError } from './ledger.js';
import { createAnchoring } from './anchor.js';

const PREFIX = '/ledger/v1';
const MAX_BODY = 1 << 20;

// --- D1 storage

const deviceFrom = (r) => r && {
  id: r.id, key: r.key, registeredAt: r.registered_at, revokedAt: r.revoked_at, lastSeq: r.last_seq, lastHash: r.last_hash,
  lastTime: r.last_time, balance: r.balance, pendingClamp: r.pending_clamp, pendingGenesis: r.pending_genesis, lastSpendReq: r.last_spend_req,
};
const codeFrom = (r) => r && { code: r.code, createdAt: r.created_at, expiresAt: r.expires_at, usedAt: r.used_at, device: r.device };
const reservationFrom = (r) => r && {
  serverSeq: r.server_seq, device: r.device, item: r.item, amount: r.amount, reqTime: r.req_time, consumedSeq: r.consumed_seq, body: r.body, sig: r.sig,
};
const genesisFrom = (r) => r && { serverSeq: r.server_seq, device: r.device, dseq: r.dseq, amount: r.amount, approvedSeq: r.approved_seq };
const anchorFrom = (r) => r && {
  id: r.id, seq: r.seq, hash: r.hash, submittedAt: r.submitted_at, calendars: r.calendars, status: r.status, height: r.height,
  upgradedAt: r.upgraded_at, proof: r.proof,
};

export class D1Store {
  constructor(db) { this.db = db; }
  q(sql, ...args) { return this.db.prepare(sql).bind(...args); }

  async getHead() { return this.q('SELECT seq, hash FROM ledger ORDER BY seq DESC LIMIT 1').first(); }
  async getDevice(id) { return deviceFrom(await this.q('SELECT * FROM devices WHERE id = ?', id).first()); }
  async getDeviceByKey(key) { return deviceFrom(await this.q('SELECT * FROM devices WHERE key = ?', key).first()); }
  async getCode(code) { return codeFrom(await this.q('SELECT * FROM codes WHERE code = ?', code).first()); }
  async getEntryHashes(device, from, to) {
    const { results } = await this.q("SELECT dseq, dhash FROM ledger WHERE kind = 'entry' AND device = ? AND dseq BETWEEN ? AND ?", device, from, to).all();
    return new Map(results.map((r) => [r.dseq, r.dhash]));
  }
  async getReceiptCovering(device, dseq) {
    const r = await this.q('SELECT body, sig FROM receipts WHERE device = ? AND dseq >= ? ORDER BY dseq LIMIT 1', device, dseq).first();
    return r && { body: r.body, sig: r.sig };
  }
  async listOpenReservations(device) {
    const { results } = await this.q('SELECT * FROM reservations WHERE device = ? AND consumed_seq IS NULL ORDER BY server_seq', device).all();
    return results.map(reservationFrom);
  }
  async getGenesis(serverSeq) { return genesisFrom(await this.q('SELECT * FROM genesis WHERE server_seq = ?', serverSeq).first()); }
  async listPendingGenesis() {
    const { results } = await this.q('SELECT * FROM genesis WHERE approved_seq IS NULL ORDER BY server_seq').all();
    return results.map(genesisFrom);
  }
  async listLedger() { return (await this.q('SELECT * FROM ledger ORDER BY seq').all()).results; }
  async listDevices() { return (await this.q('SELECT * FROM devices').all()).results.map(deviceFrom); }

  async getLatestAnchor() { return anchorFrom(await this.q('SELECT * FROM anchors ORDER BY id DESC LIMIT 1').first()); }
  async getAnchor(id) { return anchorFrom(await this.q('SELECT * FROM anchors WHERE id = ?', id).first()); }
  async listAnchors() { return (await this.q('SELECT * FROM anchors ORDER BY id DESC').all()).results.map(anchorFrom); }
  async listPendingAnchors() { return (await this.q("SELECT * FROM anchors WHERE status = 'pending' ORDER BY id").all()).results.map(anchorFrom); }
  async insertAnchor(a) {
    const r = await this.q(`INSERT INTO anchors (seq, hash, submitted_at, calendars, status, height, upgraded_at, proof)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?) RETURNING id`, a.seq, a.hash, a.submittedAt, a.calendars, a.status, a.height, a.upgradedAt, a.proof).first();
    return r.id;
  }
  async updateAnchor(id, a) {
    await this.q('UPDATE anchors SET status = ?, height = ?, upgraded_at = ?, proof = ? WHERE id = ?', a.status, a.height, a.upgradedAt, a.proof, id).run();
  }

  async commit(tx) {
    // Ledger rows go first: a seq primary-key collision aborts the whole batch (optimistic lock).
    const s = [];
    for (const r of tx.ledger ?? []) {
      s.push(this.q(`INSERT INTO ledger (seq, time, device, kind, amount, dseq, dhash, dkind, reported, ref, note, prev, hash)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      r.seq, r.time, r.device, r.kind, r.amount, r.dseq, r.dhash, r.dkind, r.reported, r.ref, r.note, r.prev, r.hash));
    }
    for (const d of tx.devices ?? []) {
      s.push(this.q(`INSERT INTO devices (id, key, registered_at, revoked_at, last_seq, last_hash, last_time, balance, pending_clamp, pending_genesis, last_spend_req)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET revoked_at = excluded.revoked_at, last_seq = excluded.last_seq, last_hash = excluded.last_hash,
          last_time = excluded.last_time, balance = excluded.balance, pending_clamp = excluded.pending_clamp,
          pending_genesis = excluded.pending_genesis, last_spend_req = excluded.last_spend_req`,
      d.id, d.key, d.registeredAt, d.revokedAt, d.lastSeq, d.lastHash, d.lastTime, d.balance, d.pendingClamp, d.pendingGenesis, d.lastSpendReq));
    }
    for (const c of tx.codes ?? []) {
      s.push(this.q(`INSERT INTO codes (code, created_at, expires_at, used_at, device) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(code) DO UPDATE SET used_at = excluded.used_at, device = excluded.device`,
      c.code, c.createdAt, c.expiresAt, c.usedAt, c.device));
    }
    for (const r of tx.receipts ?? []) {
      s.push(this.q('INSERT INTO receipts (device, dseq, body, sig) VALUES (?, ?, ?, ?)', r.device, r.dseq, r.body, r.sig));
    }
    for (const r of tx.reservations ?? []) {
      s.push(this.q(`INSERT INTO reservations (server_seq, device, item, amount, req_time, consumed_seq, body, sig) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(server_seq) DO UPDATE SET consumed_seq = excluded.consumed_seq`,
      r.serverSeq, r.device, r.item, r.amount, r.reqTime, r.consumedSeq, r.body, r.sig));
    }
    for (const g of tx.genesis ?? []) {
      s.push(this.q(`INSERT INTO genesis (server_seq, device, dseq, amount, approved_seq) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(server_seq) DO UPDATE SET approved_seq = excluded.approved_seq`,
      g.serverSeq, g.device, g.dseq, g.amount, g.approvedSeq));
    }
    if (!s.length) return;
    try {
      await this.db.batch(s);
    } catch (e) {
      if (/UNIQUE|PRIMARY KEY|constraint/i.test(String(e?.message ?? e))) throw new ConflictError(String(e?.message ?? e));
      throw e;
    }
  }
}

// --- HTTP

const json = (data, status = 200) => new Response(JSON.stringify(data), {
  status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
});
const notFound = () => json({ error: 'not_found' }, 404);

async function readJson(request) {
  const len = Number(request.headers.get('content-length') ?? 0);
  if (len > MAX_BODY) throw new LedgerError(413, 'too_large');
  const text = await request.text();
  if (text.length > MAX_BODY) throw new LedgerError(413, 'too_large');
  try { return text ? JSON.parse(text) : {}; } catch { throw new LedgerError(400, 'bad_json'); }
}

/** Constant-time comparison of the bearer token (both sides hashed to equal length first). */
async function isAdmin(request, env) {
  const expected = env.LEDGER_ADMIN_TOKEN;
  if (!expected) return false;
  const given = (request.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([given, expected].map((s) => crypto.subtle.digest('SHA-256', enc.encode(s))));
  const x = new Uint8Array(a), y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

let signerCache = { key: null, signer: null };
async function signerFor(env) {
  if (signerCache.key !== env.LEDGER_SIGNING_KEY) {
    signerCache = { key: env.LEDGER_SIGNING_KEY, signer: await createSigner(env.LEDGER_SIGNING_KEY) };
  }
  return signerCache.signer;
}

async function route(request, env, path) {
  const method = request.method;
  let m;
  if (method === 'GET' && path === '/anchors') return json(await createAnchoring({ store: new D1Store(env.DB) }).list());
  if (method === 'GET' && (m = path.match(/^\/anchors\/(\d{1,15})\.ots$/))) {
    const file = await createAnchoring({ store: new D1Store(env.DB) }).proofFile(Number(m[1]));
    if (!file) return notFound();
    return new Response(file.bytes, {
      headers: {
        'content-type': 'application/octet-stream', 'cache-control': 'no-store',
        'content-disposition': `attachment; filename="suhyeok-ledger-${file.seq}.ots"`,
      },
    });
  }

  const signer = await signerFor(env);
  if (method === 'GET' && path === '/pubkey') return json({ alg: 'Ed25519', key: signer.publicKey });

  const ledger = createLedger({ store: new D1Store(env.DB), signer });
  if (method === 'POST' && path === '/register') return json(await ledger.register(await readJson(request)), 201);
  if (method === 'POST' && path === '/sync') return json(await ledger.sync(await readJson(request)));
  if (method === 'POST' && path === '/spend') return json(await ledger.requestSpend(await readJson(request)));
  if (method === 'GET' && (m = path.match(/^\/balance\/([0-9a-f-]{36})$/))) return json(await ledger.balance(m[1]));

  if (path.startsWith('/admin/')) {
    if (!(await isAdmin(request, env))) return json({ error: 'unauthorized' }, 401);
    if (method === 'POST' && path === '/admin/codes') return json(await ledger.issueCode(await readJson(request)), 201);
    if (method === 'GET' && path === '/admin/genesis') return json({ pending: await ledger.listPendingGenesis() });
    if (method === 'POST' && (m = path.match(/^\/admin\/genesis\/(\d+)\/approve$/))) return json(await ledger.approveGenesis(Number(m[1])));
    if (method === 'POST' && (m = path.match(/^\/admin\/devices\/([0-9a-f-]{36})\/revoke$/))) {
      return json(await ledger.revoke(m[1], (await readJson(request)).note ?? ''));
    }
    if (method === 'POST' && path === '/admin/corrections') return json(await ledger.correct(await readJson(request)), 201);
    if (method === 'GET' && path === '/admin/verify') return json(await ledger.verify());
  }
  return notFound();
}

// Must match [triggers] crons in wrangler.toml.
export const CRON_SUBMIT = '0 3 * * *';
export const CRON_UPGRADE = '0 */6 * * *';

export default {
  /** Anchoring cron: daily submit, 6-hourly upgrade. Failures are logged; the next run retries. */
  async scheduled(controller, env, ctx) {
    const anchoring = createAnchoring({ store: new D1Store(env.DB) });
    const job = controller.cron === CRON_SUBMIT ? anchoring.submit()
      : controller.cron === CRON_UPGRADE ? anchoring.upgrade()
        : Promise.resolve({ ignored: controller.cron });
    const done = job.then(
      (r) => { console.log('anchor', controller.cron, JSON.stringify(r)); return r; },
      (e) => { console.error('anchor error', e?.stack ?? e); return { error: String(e?.message ?? e) }; },
    );
    ctx.waitUntil(done);
    return done;
  },

  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    // Only /ledger/* is routed to this Worker in production; anything else is not ours.
    if (pathname !== '/ledger' && !pathname.startsWith('/ledger/')) return new Response('Not Found', { status: 404 });
    if (!pathname.startsWith(PREFIX + '/')) return notFound();
    try {
      return await route(request, env, pathname.slice(PREFIX.length));
    } catch (e) {
      if (e instanceof LedgerError) return json(e.toJSON(), e.status);
      console.error('ledger error', e?.stack ?? e);
      return json({ error: 'internal' }, 500);
    }
  },
};
