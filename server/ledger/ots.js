// Minimal OpenTimestamps proof format: parse, serialize, merge, and commitment computation for pending
// attestations. Only what the anchoring cron needs; verification against Bitcoin happens in the app
// (Sources/AgentDeck/Anchor.swift). Uses only WebCrypto, so it runs on Workers and Node alike.
//
// Format, as implemented by python-opentimestamps (opentimestamps/core/{serialize,op,notary,timestamp}.py):
//   file      = HEADER_MAGIC, u8 major version (1), file hash op tag (0x08 sha256), digest, timestamp
//   timestamp = ( 0xff, item )* , item          -- every item but the last is prefixed with 0xff
//   item      = 0x00 attestation | op-tag [varbytes arg for binary ops] timestamp (over the op's result)
//   attestation = 8-byte tag, varbytes payload; pending payload = varbytes(uri), bitcoin payload = varuint(height)
//   varuint   = little-endian base-128, high bit = continuation; varbytes = varuint length + bytes
//
// Ops are kept structurally: parsing never hashes, so ops this module cannot compute (ripemd160, keccak256)
// still parse and round-trip; only commitment computation below them is skipped.

export const HEADER_MAGIC = Uint8Array.from([
  0x00, 0x4f, 0x70, 0x65, 0x6e, 0x54, 0x69, 0x6d, 0x65, 0x73, 0x74, 0x61, 0x6d, 0x70, 0x73, 0x00, // \0OpenTimestamps\0
  0x00, 0x50, 0x72, 0x6f, 0x6f, 0x66, 0x00, 0xbf, 0x89, 0xe2, 0xe8, 0x84, 0xe8, 0x92, 0x94, //       \0Proof\0 + 8 magic bytes
]);
export const MAJOR_VERSION = 1;

export const OP = { sha1: 0x02, ripemd160: 0x03, sha256: 0x08, keccak256: 0x67, append: 0xf0, prepend: 0xf1, reverse: 0xf2, hexlify: 0xf3 };
const UNARY = new Set([OP.sha1, OP.ripemd160, OP.sha256, OP.keccak256, OP.reverse, OP.hexlify]);
const BINARY = new Set([OP.append, OP.prepend]);
export const ATTESTATION = {
  pending: Uint8Array.from([0x83, 0xdf, 0xe3, 0x0d, 0x2e, 0xf9, 0x0c, 0x8e]),
  bitcoin: Uint8Array.from([0x05, 0x88, 0x96, 0x0d, 0x73, 0xd7, 0x19, 0x01]),
};

// Limits from python-opentimestamps.
const MAX_OP_LENGTH = 4096; // op argument and result
const MAX_PAYLOAD = 8192; // attestation payload
const MAX_URI = 1000;
const URI_CHARS = /^[A-Za-z0-9\-._/:]*$/;
const MAX_DEPTH = 256;

export class OtsError extends Error {}

// --- bytes

export const hex = (b) => [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
export function unhex(s) {
  if (typeof s !== 'string' || !/^([0-9a-f]{2})*$/i.test(s)) throw new OtsError('bad hex');
  return Uint8Array.from(s.match(/../g) ?? [], (h) => parseInt(h, 16));
}
const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let i = 0;
  for (const p of parts) { out.set(p, i); i += p.length; }
  return out;
};
const equal = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
function compare(a, b) {
  for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) return a[i] - b[i];
  return a.length - b.length;
}

class Reader {
  constructor(bytes) { this.b = bytes; this.i = 0; }
  bytes(n) {
    if (this.i + n > this.b.length) throw new OtsError('truncated');
    const r = this.b.subarray(this.i, this.i + n);
    this.i += n;
    return r;
  }
  u8() { return this.bytes(1)[0]; }
  varuint() {
    let value = 0, shift = 0;
    for (;;) {
      const b = this.u8();
      if (shift > 49) throw new OtsError('varuint too large');
      value += (b & 0x7f) * 2 ** shift;
      if (!(b & 0x80)) return value;
      shift += 7;
    }
  }
  varbytes(max, min = 0) {
    const n = this.varuint();
    if (n > max || n < min) throw new OtsError(`varbytes length ${n} out of range`);
    return this.bytes(n);
  }
  eof() { if (this.i !== this.b.length) throw new OtsError('trailing bytes'); }
}

class Writer {
  constructor() { this.parts = []; }
  bytes(b) { this.parts.push(b); }
  u8(v) { this.parts.push(Uint8Array.of(v)); }
  varuint(v) {
    const out = [];
    do {
      let b = v % 128;
      v = Math.floor(v / 128);
      if (v > 0) b |= 0x80;
      out.push(b);
    } while (v > 0);
    this.parts.push(Uint8Array.from(out));
  }
  varbytes(b) { this.varuint(b.length); this.bytes(b); }
  done() { return concat(...this.parts); }
}

// --- tree
// node = { attestations: attestation[], ops: [{ op, stamp: node }] }
// op = { tag, arg? }   attestation = { type: 'pending', uri } | { type: 'bitcoin', height } | { type: 'unknown', tag, payload }

function readAttestation(r) {
  const tag = r.bytes(8);
  const payload = r.varbytes(MAX_PAYLOAD);
  const p = new Reader(payload);
  let att;
  if (equal(tag, ATTESTATION.pending)) {
    const uri = new TextDecoder().decode(p.varbytes(MAX_URI));
    if (!URI_CHARS.test(uri)) throw new OtsError('invalid pending uri');
    att = { type: 'pending', uri };
  } else if (equal(tag, ATTESTATION.bitcoin)) {
    att = { type: 'bitcoin', height: p.varuint() };
  } else {
    return { type: 'unknown', tag: Uint8Array.from(tag), payload: Uint8Array.from(payload) };
  }
  p.eof();
  return att;
}

function readTimestamp(r, depth = MAX_DEPTH) {
  if (depth === 0) throw new OtsError('recursion limit');
  const node = { attestations: [], ops: [] };
  const item = (tag) => {
    if (tag === 0x00) { node.attestations.push(readAttestation(r)); return; }
    let op;
    if (UNARY.has(tag)) op = { tag };
    else if (BINARY.has(tag)) op = { tag, arg: Uint8Array.from(r.varbytes(MAX_OP_LENGTH, 1)) };
    else throw new OtsError(`unknown op tag 0x${tag.toString(16)}`);
    node.ops.push({ op, stamp: readTimestamp(r, depth - 1) });
  };
  let tag = r.u8();
  while (tag === 0xff) { item(r.u8()); tag = r.u8(); }
  item(tag);
  return node;
}

function attestationBytes(a) {
  const w = new Writer();
  if (a.type === 'unknown') { w.bytes(a.tag); w.varbytes(a.payload); return w.done(); }
  const p = new Writer();
  if (a.type === 'pending') { w.bytes(ATTESTATION.pending); p.varbytes(new TextEncoder().encode(a.uri)); }
  else if (a.type === 'bitcoin') { w.bytes(ATTESTATION.bitcoin); p.varuint(a.height); }
  else throw new OtsError(`unknown attestation type ${a.type}`);
  w.varbytes(p.done());
  return w.done();
}

// Python sorts attestations by tag then value (pending: uri, bitcoin: height) and ops by tag then arg.
// The same order here keeps re-serialised files byte-identical to the reference client's output.
function attestationOrder(a, b) {
  const ta = a.type === 'unknown' ? a.tag : ATTESTATION[a.type], tb = b.type === 'unknown' ? b.tag : ATTESTATION[b.type];
  const c = compare(ta, tb);
  if (c || a.type !== b.type) return c;
  if (a.type === 'pending') return a.uri < b.uri ? -1 : a.uri > b.uri ? 1 : 0;
  if (a.type === 'bitcoin') return a.height - b.height;
  return compare(a.payload, b.payload);
}
const opOrder = (a, b) => (a.op.tag - b.op.tag) || compare(a.op.arg ?? new Uint8Array(), b.op.arg ?? new Uint8Array());

function writeTimestamp(w, node) {
  const atts = [...node.attestations].sort(attestationOrder);
  const ops = [...node.ops].sort(opOrder);
  const items = [...atts.map((a) => ({ a })), ...ops];
  if (!items.length) throw new OtsError('empty timestamp');
  items.forEach((it, i) => {
    if (i < items.length - 1) w.u8(0xff);
    if (it.a) { w.u8(0x00); w.bytes(attestationBytes(it.a)); }
    else { w.u8(it.op.tag); if (it.op.arg) w.varbytes(it.op.arg); writeTimestamp(w, it.stamp); }
  });
}

/** A bare timestamp (no file header), as calendars return it. */
export function parseTimestamp(bytes) {
  const r = new Reader(bytes);
  const node = readTimestamp(r);
  r.eof();
  return node;
}

export function serializeTimestamp(node) {
  const w = new Writer();
  writeTimestamp(w, node);
  return w.done();
}

/** A detached timestamp file (.ots). Only sha256 file digests are accepted: the ledger head is a sha256. */
export function parseOts(bytes) {
  const r = new Reader(bytes);
  if (!equal(r.bytes(HEADER_MAGIC.length), HEADER_MAGIC)) throw new OtsError('bad magic');
  if (r.u8() !== MAJOR_VERSION) throw new OtsError('unsupported major version');
  const hashOp = r.u8();
  if (hashOp !== OP.sha256) throw new OtsError(`unsupported file hash op 0x${hashOp.toString(16)}`);
  const digest = Uint8Array.from(r.bytes(32));
  const timestamp = readTimestamp(r);
  r.eof();
  return { digest, timestamp };
}

export function serializeOts({ digest, timestamp }) {
  if (digest.length !== 32) throw new OtsError('digest must be 32 bytes');
  const w = new Writer();
  w.bytes(HEADER_MAGIC);
  w.u8(MAJOR_VERSION);
  w.u8(OP.sha256);
  w.bytes(digest);
  writeTimestamp(w, timestamp);
  return w.done();
}

/** Adds the other timestamp's ops and attestations (same message) into node, deduplicated. Returns node. */
export function mergeTimestamp(node, other) {
  const attKey = (a) => hex(attestationBytes(a));
  const have = new Set(node.attestations.map(attKey));
  for (const a of other.attestations) if (!have.has(attKey(a))) { node.attestations.push(a); have.add(attKey(a)); }
  for (const { op, stamp } of other.ops) {
    const mine = node.ops.find((x) => x.op.tag === op.tag && equal(x.op.arg ?? new Uint8Array(), op.arg ?? new Uint8Array()));
    if (mine) mergeTimestamp(mine.stamp, stamp);
    else node.ops.push({ op, stamp });
  }
  return node;
}

// --- ops

const digest = async (alg, msg) => new Uint8Array(await crypto.subtle.digest(alg, msg));

/** The op's result, or null when this module cannot compute it (ripemd160, keccak256). */
export async function applyOp(op, msg) {
  if (msg.length > MAX_OP_LENGTH) throw new OtsError('message too long');
  let out;
  switch (op.tag) {
    case OP.sha256: out = await digest('SHA-256', msg); break;
    case OP.sha1: out = await digest('SHA-1', msg); break;
    case OP.append: out = concat(msg, op.arg); break;
    case OP.prepend: out = concat(op.arg, msg); break;
    case OP.reverse: if (!msg.length) throw new OtsError('reverse of empty message'); out = Uint8Array.from(msg).reverse(); break;
    case OP.hexlify: if (!msg.length) throw new OtsError('hexlify of empty message'); out = new TextEncoder().encode(hex(msg)); break;
    default: return null;
  }
  if (out.length > MAX_OP_LENGTH) throw new OtsError('result too long');
  return out;
}

/**
 * Every attestation reachable from msg, with the message it commits to: [{attestation, msg, node}].
 * Subtrees under ops this module cannot compute are skipped.
 */
export async function attestations(node, msg) {
  const out = node.attestations.map((attestation) => ({ attestation, msg, node }));
  for (const { op, stamp } of node.ops) {
    const next = await applyOp(op, msg);
    if (next) out.push(...(await attestations(stamp, next)));
  }
  return out;
}

// --- calendars

/** Calendars the official client trusts for upgrades (python-opentimestamps DEFAULT_CALENDAR_WHITELIST). */
const CALENDAR_HOSTS = [/^[a-z0-9.-]+\.calendar\.opentimestamps\.org$/, /^[a-z0-9.-]+\.calendar\.eternitywall\.com$/, /^[a-z0-9.-]+\.calendar\.catallaxy\.com$/];

export function isWhitelistedCalendar(uri) {
  let u;
  try { u = new URL(uri); } catch { return false; }
  return u.protocol === 'https:' && (u.pathname === '/' || u.pathname === '') && !u.search && !u.hash && !u.port
    && CALENDAR_HOSTS.some((re) => re.test(u.hostname));
}
