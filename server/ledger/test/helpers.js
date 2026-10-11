// Test fixtures: an in-memory store, a D1 shim over node:sqlite (to exercise the real SQL), and a
// device simulator that writes entries exactly the way Sources/AgentDeck/Ledger.swift does.
import { readFileSync } from 'node:fs';
import { ConflictError, ZERO_HASH, entryCanonical, sha256hex, b64encode, stableStringify } from '../ledger.js';

const clone = (v) => (v == null ? v : structuredClone(v));

/** Minimal in-memory implementation of the storage interface ledger.js expects. */
export class MemoryStore {
  constructor() {
    this.ledger = [];
    this.devices = new Map();
    this.codes = new Map();
    this.receipts = [];
    this.reservations = new Map();
    this.genesis = new Map();
  }
  async getHead() {
    const r = this.ledger.at(-1);
    return r ? { seq: r.seq, hash: r.hash } : null;
  }
  async getDevice(id) { return clone(this.devices.get(id) ?? null); }
  async getDeviceByKey(key) { return clone([...this.devices.values()].find((d) => d.key === key) ?? null); }
  async getCode(code) { return clone(this.codes.get(code) ?? null); }
  async getEntryHashes(device, from, to) {
    const m = new Map();
    for (const r of this.ledger) if (r.kind === 'entry' && r.device === device && r.dseq >= from && r.dseq <= to) m.set(r.dseq, r.dhash);
    return m;
  }
  async getReceiptCovering(device, dseq) {
    const r = this.receipts.filter((x) => x.device === device && x.dseq >= dseq).sort((a, b) => a.dseq - b.dseq)[0];
    return r ? { body: r.body, sig: r.sig } : null;
  }
  async listOpenReservations(device) {
    return [...this.reservations.values()].filter((r) => r.device === device && r.consumedSeq == null)
      .sort((a, b) => a.serverSeq - b.serverSeq).map(clone);
  }
  async getGenesis(serverSeq) { return clone(this.genesis.get(serverSeq) ?? null); }
  async listPendingGenesis() { return [...this.genesis.values()].filter((g) => g.approvedSeq == null).map(clone); }
  async listLedger() { return this.ledger.map(clone); }
  async listDevices() { return [...this.devices.values()].map(clone); }
  async commit(tx) {
    const head = this.ledger.at(-1);
    let next = head ? head.seq + 1 : 0;
    for (const r of tx.ledger ?? []) { if (r.seq !== next++) throw new ConflictError('ledger head moved'); }
    for (const r of tx.receipts ?? []) {
      if (this.receipts.some((x) => x.device === r.device && x.dseq === r.dseq)) throw new ConflictError('receipt exists');
    }
    this.ledger.push(...(tx.ledger ?? []).map(clone));
    for (const d of tx.devices ?? []) this.devices.set(d.id, clone(d));
    for (const c of tx.codes ?? []) this.codes.set(c.code, clone(c));
    for (const r of tx.receipts ?? []) this.receipts.push(clone(r));
    for (const r of tx.reservations ?? []) this.reservations.set(r.serverSeq, clone(r));
    if (tx.approveGenesisOf) {
      for (const g of this.genesis.values()) {
        if (g.device === tx.approveGenesisOf.device && g.approvedSeq == null) g.approvedSeq = tx.approveGenesisOf.approvedSeq;
      }
    }
    for (const g of tx.genesis ?? []) this.genesis.set(g.serverSeq, clone(g));
  }
  /** Simulates an operator editing a ledger row in place. */
  tamper(seq, field, value) { this.ledger.find((r) => r.seq === seq)[field] = value; }
}

/** The subset of the D1 binding API that worker.js uses, backed by node:sqlite. */
export async function makeSqliteD1() {
  const { DatabaseSync } = await import('node:sqlite');
  const db = new DatabaseSync(':memory:');
  db.exec(readFileSync(new URL('../schema.sql', import.meta.url), 'utf8'));
  const stmt = (sql, args = []) => ({
    bind: (...a) => stmt(sql, a),
    first: async () => db.prepare(sql).get(...args) ?? null,
    all: async () => ({ results: db.prepare(sql).all(...args) }),
    run: async () => db.prepare(sql).run(...args),
    _exec: () => db.prepare(sql).run(...args),
  });
  return {
    raw: db,
    prepare: (sql) => stmt(sql),
    batch: async (stmts) => {
      db.exec('BEGIN');
      try { for (const s of stmts) s._exec(); db.exec('COMMIT'); } catch (e) { db.exec('ROLLBACK'); throw e; }
    },
  };
}

/** A device ledger that mirrors Ledger.swift: open entry with the key first, hash chain, raw r||s signatures. */
export async function makeDevice() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const key = b64encode(new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey)));
  const dev = {
    key,
    entries: [],
    get balance() { return this.entries.reduce((s, e) => s + e.amount, 0); },
    async sign(text) {
      const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, pair.privateKey, new TextEncoder().encode(text));
      return b64encode(new Uint8Array(sig));
    },
    /** Builds and signs an entry without appending it (for crafting bad batches). */
    async make(fields) {
      const e = { rule: 1, note: '', source: '', ...fields };
      e.hash = await sha256hex(entryCanonical(e));
      e.sig = await dev.sign(entryCanonical(e));
      return e;
    },
    async append(kind, source, amount, time, note = '') {
      if (dev.entries.length === 0) {
        dev.entries.push(await dev.make({ seq: 0, time, kind: 'open', source: '', amount: 0, key, prev: ZERO_HASH }));
      }
      const e = await dev.make({ seq: dev.entries.length, time, kind, source, amount, note, prev: dev.entries.at(-1).hash });
      dev.entries.push(e);
      return e;
    },
    since(seq) { return dev.entries.filter((e) => e.seq > seq).map(clone); },
    async spendRequest(device, item, amount, time) {
      const sig = await dev.sign(stableStringify({ action: 'spend', amount, device, item, time }));
      return { device, item, amount, time, sig };
    },
  };
  return dev;
}

export async function makeSigningKey() {
  const k = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
  return b64encode(new Uint8Array(await crypto.subtle.exportKey('pkcs8', k.privateKey)));
}

/** Verifies a {body, sig} envelope against the server public key (base64 raw 32 bytes), returns the body. */
export async function openEnvelope(env, publicKeyB64) {
  const raw = Uint8Array.from(atob(publicKeyB64), (c) => c.charCodeAt(0));
  const pub = await crypto.subtle.importKey('raw', raw, { name: 'Ed25519' }, false, ['verify']);
  const sig = Uint8Array.from(atob(env.sig), (c) => c.charCodeAt(0));
  const ok = await crypto.subtle.verify({ name: 'Ed25519' }, pub, sig, new TextEncoder().encode(env.body));
  if (!ok) throw new Error('envelope signature invalid');
  return JSON.parse(env.body);
}
