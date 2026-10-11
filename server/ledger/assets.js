// Character pack validation (docs/asset-pack-spec.md). The app runs the same rules in AssetPack.swift;
// test/asset-vectors/ keeps the two in step. Header-level only: nothing here decodes pixels.

export const SPEC = {
  FORMAT: 1,
  KINDS: ['character'],
  MAX_MANIFEST: 16 * 1024,
  MAX_FILE: 1024 * 1024,
  MAX_PACK: 4 * 1024 * 1024,
  NAME_MAX: 40,
  MOTIONS: { walk_down: 6, walk_left: 6, walk_up: 6, attack: 6, hammer: 3, read: 3, type: 3, smith: 6, study: 6, write: 6 },
  REQUIRED: ['walk_down', 'walk_left', 'walk_up', 'attack'],
  FRAME_MAX: 256,
  PORTRAIT: { minW: 128, maxW: 1024, minH: 128, maxH: 1365 },
};

const PATH = /^(?:(portrait)\.(jpg|png)|(sprite)\.png|frames\/([a-z_]+)_(\d{1,2})\.png)$/;

/** What a pack path is, or null when the path is not allowed. */
export function classifyPath(path) {
  const m = typeof path === 'string' ? path.match(PATH) : null;
  if (!m) return null;
  if (m[1]) return { role: 'portrait', format: m[2] === 'jpg' ? 'jpeg' : 'png' };
  if (m[3]) return { role: 'sprite', format: 'png' };
  if (!(m[4] in SPEC.MOTIONS) || (m[5].length > 1 && m[5][0] === '0')) return null;
  return { role: 'frame', format: 'png', motion: m[4], index: Number(m[5]) };
}

const err = (code, path = '') => ({ code, path });
const isObj = (v) => v != null && typeof v === 'object' && !Array.isArray(v);
const isCount = (v) => Number.isInteger(v) && v > 0;

/** Parses and checks manifest.json. Returns { manifest, errors }; manifest is null when unusable. */
export function validateManifest(text) {
  if (typeof text !== 'string') return { manifest: null, errors: [err('bad_manifest')] };
  if (new TextEncoder().encode(text).length > SPEC.MAX_MANIFEST) return { manifest: null, errors: [err('too_large', 'manifest.json')] };
  let m;
  try { m = JSON.parse(text); } catch { return { manifest: null, errors: [err('bad_manifest')] }; }
  if (!isObj(m) || !isObj(m.files) || !isObj(m.frames)) return { manifest: null, errors: [err('bad_manifest')] };

  const errors = [];
  if (m.format !== SPEC.FORMAT) errors.push(err('bad_format_version'));
  if (!SPEC.KINDS.includes(m.kind)) errors.push(err('bad_kind'));
  const name = typeof m.name === 'string' ? m.name.trim() : '';
  if (!name || [...name].length > SPEC.NAME_MAX || /[\u0000-\u001f\u007f]/.test(name)) errors.push(err('bad_name'));

  let total = 0;
  const frames = {};
  const portraits = [];
  let sprite = false;
  for (const [path, f] of Object.entries(m.files)) {
    if (!isObj(f) || typeof f.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(f.sha256) || !isCount(f.bytes)) {
      errors.push(err('bad_manifest', path));
      continue;
    }
    const c = classifyPath(path);
    if (!c) { errors.push(err('bad_path', path)); continue; }
    total += f.bytes;
    if (f.bytes > SPEC.MAX_FILE) errors.push(err('too_large', path));
    if (c.role === 'portrait') portraits.push(path);
    if (c.role === 'sprite') sprite = true;
    if (c.role === 'frame') (frames[c.motion] ??= []).push(c.index);
  }
  if (total > SPEC.MAX_PACK) errors.push(err('too_large'));
  if (portraits.length === 0) errors.push(err('missing_file', 'portrait'));
  if (portraits.length > 1) errors.push(err('bad_path', portraits.join(',')));
  if (!sprite) errors.push(err('missing_file', 'sprite.png'));

  // Every motion: the listed files are exactly 0..n-1, n is the spec count, and `frames` says the same.
  const motions = new Set([...Object.keys(frames), ...Object.keys(m.frames), ...SPEC.REQUIRED]);
  for (const motion of motions) {
    const want = SPEC.MOTIONS[motion];
    const have = (frames[motion] ?? []).sort((a, b) => a - b);
    const declared = m.frames[motion];
    const contiguous = have.every((v, i) => v === i);
    if (!want || have.length !== want || !contiguous || declared !== have.length) errors.push(err('frame_count', motion));
  }
  return { manifest: m, errors };
}

// --- file contents

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(bytes, start, end) {
  let c = 0xffffffff;
  for (let i = start; i < end; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

const PNG_SIG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const PNG_DEPTHS = { 0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16] };

/** Walks the PNG chunk structure (lengths, CRCs, IHDR first, IEND last). null when it is not a sound PNG. */
export function parsePng(b) {
  if (b.length < 8 + 25 + 12 || PNG_SIG.some((v, i) => b[i] !== v)) return null;
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  let i = 8, info = null, trns = false, idat = false, chunks = 0;
  while (i + 12 <= b.length) {
    const len = dv.getUint32(i);
    const type = String.fromCharCode(b[i + 4], b[i + 5], b[i + 6], b[i + 7]);
    const end = i + 8 + len;
    if (len > 0x7fffffff || end + 4 > b.length || ++chunks > 4096) return null;
    if (crc32(b, i + 4, end) !== dv.getUint32(end)) return null;
    if (!info) {
      if (type !== 'IHDR' || len !== 13) return null;
      info = { width: dv.getUint32(i + 8), height: dv.getUint32(i + 12), depth: b[i + 16], colorType: b[i + 17] };
      if (!PNG_DEPTHS[info.colorType]?.includes(info.depth) || !info.width || !info.height) return null;
    } else if (type === 'tRNS') {
      if (idat) return null;
      trns = true;
    } else if (type === 'IDAT') {
      idat = true;
    } else if (type === 'IEND') {
      return idat && end + 4 === b.length ? { ...info, trns } : null;
    }
    i = end + 4;
  }
  return null;
}

/** Finds the frame size in a baseline or progressive JPEG. null when it is not a sound JPEG. */
export function parseJpeg(b) {
  if (b.length < 4 || b[0] !== 0xff || b[1] !== 0xd8 || b[b.length - 2] !== 0xff || b[b.length - 1] !== 0xd9) return null;
  let i = 2, size = null;
  while (i + 4 <= b.length) {
    if (b[i] !== 0xff) return null;
    let marker = b[i + 1];
    while (marker === 0xff && i + 2 < b.length) { i++; marker = b[i + 1]; }
    if (marker === 0xd9) break;
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { i += 2; continue; }
    const len = (b[i + 2] << 8) | b[i + 3];
    if (len < 2 || i + 2 + len > b.length) return null;
    const sof = marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker);
    if (sof) {
      if (len < 8) return null;
      size = { height: (b[i + 5] << 8) | b[i + 6], width: (b[i + 7] << 8) | b[i + 8] };
    }
    if (marker === 0xda) break; // entropy-coded data follows; the size must already be known
    i += 2 + len;
  }
  return size && size.width && size.height ? size : null;
}

async function sha256hex(bytes) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return [...d].map((x) => x.toString(16).padStart(2, '0')).join('');
}

/** Checks one file against its manifest entry and the spec for its role. */
export async function validateFile(manifest, path, bytes) {
  const f = manifest?.files?.[path];
  const c = classifyPath(path);
  if (!f || !c) return [err('bad_path', path)];
  if (bytes.length > SPEC.MAX_FILE) return [err('too_large', path)];
  if (bytes.length !== f.bytes || (await sha256hex(bytes)) !== f.sha256) return [err('hash_mismatch', path)];
  const img = c.format === 'png' ? parsePng(bytes) : parseJpeg(bytes);
  if (!img) return [err('bad_format', path)];
  const errors = [];
  if (c.role === 'portrait') {
    const p = SPEC.PORTRAIT;
    if (img.width < p.minW || img.width > p.maxW || img.height < p.minH || img.height > p.maxH) errors.push(err('bad_dimensions', path));
  } else {
    if (img.width > SPEC.FRAME_MAX || img.height > SPEC.FRAME_MAX) errors.push(err('bad_dimensions', path));
    if (!(img.colorType === 6 || (img.colorType === 3 && img.trns))) errors.push(err('no_transparency', path));
  }
  return errors;
}

/** A whole pack: manifest text plus a Map of path → bytes. Returns every problem found. */
export async function validatePack(manifestText, files) {
  const { manifest, errors } = validateManifest(manifestText);
  if (!manifest) return errors;
  for (const path of Object.keys(manifest.files)) {
    if (!classifyPath(path)) continue; // already reported as bad_path
    const bytes = files.get(path);
    if (!bytes) { errors.push(err('missing_file', path)); continue; }
    errors.push(...(await validateFile(manifest, path, bytes)));
  }
  return errors;
}

/** Sorted, unique error codes: the form the shared vectors record. */
export const codes = (errors) => [...new Set(errors.map((e) => e.code))].sort();
