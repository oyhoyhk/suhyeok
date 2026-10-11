// Bitcoin anchoring of the server ledger head via OpenTimestamps calendars (R25-R27, KTD9).
// The cron submits the current head hash once a day and upgrades pending proofs every 6 hours. Only the
// 32-byte head hash leaves the server. Network failures are recorded in the run summary and retried on the
// next run; they never throw and never touch the ledger.
//
// Storage interface (D1Store in worker.js):
//   getHead() -> {seq, hash} | null
//   getLatestAnchor() -> anchor | null
//   listAnchors() -> anchor[] (newest first)       getAnchor(id) -> anchor | null
//   listPendingAnchors() -> anchor[] (oldest first)
//   insertAnchor({seq, hash, submittedAt, calendars, status, height, upgradedAt, proof}) -> id
//   updateAnchor(id, {status, height, upgradedAt, proof})
// anchor = {id, seq, hash, submittedAt, calendars, status: 'pending'|'confirmed', height, upgradedAt, proof (base64 .ots)}
import { b64decode, b64encode } from './ledger.js';
import { attestations, hex, isWhitelistedCalendar, mergeTimestamp, parseOts, parseTimestamp, serializeOts, serializeTimestamp, unhex } from './ots.js';

// The official client's default aggregators (python-opentimestamps calendar.py DEFAULT_AGGREGATORS).
export const CALENDARS = [
  'https://a.pool.opentimestamps.org',
  'https://b.pool.opentimestamps.org',
  'https://a.pool.eternitywall.com',
  'https://ots.btc.catallaxy.com',
];

export const ANCHOR_CONFIG = {
  TIMEOUT_MS: 10_000, // per calendar request
  MAX_RESPONSE: 10_000, // bytes, same cap as the official client
  MAX_UPGRADE_REQUESTS: 40, // per run: stays under the Workers subrequest limit (50 on the free plan)
};

const HEADERS = { accept: 'application/vnd.opentimestamps.v1', 'user-agent': 'pickuma-suhyeok-ledger' };

const endpoint = (base, path) => new URL(path, base.endsWith('/') ? base : base + '/').toString();

export function createAnchoring({
  store, fetch = (...a) => globalThis.fetch(...a), now = () => Math.floor(Date.now() / 1000),
  calendars = CALENDARS, config = ANCHOR_CONFIG,
}) {
  /** One calendar request with a hard deadline, even if fetch ignores the abort signal. */
  async function request(url, init = {}) {
    const ac = new AbortController();
    let timer;
    const deadline = new Promise((_, reject) => {
      timer = setTimeout(() => { ac.abort(); reject(new Error('timeout')); }, config.TIMEOUT_MS);
    });
    const call = (async () => {
      const res = await fetch(url, { ...init, headers: HEADERS, signal: ac.signal });
      const body = new Uint8Array(await res.arrayBuffer());
      return { status: res.status, body };
    })();
    try {
      return await Promise.race([call, deadline]);
    } finally {
      clearTimeout(timer);
      call.catch(() => {});
    }
  }

  async function submitTo(calendar, digest) {
    const { status, body } = await request(endpoint(calendar, 'digest'), { method: 'POST', body: digest });
    if (status !== 200) throw new Error(`HTTP ${status}`);
    if (body.length > config.MAX_RESPONSE) throw new Error('response too large');
    return parseTimestamp(body);
  }

  /** Daily: submit the head hash to every calendar; stored as pending when at least one accepted it. */
  async function submit() {
    const head = await store.getHead();
    if (!head) return { submitted: false, reason: 'empty_ledger' };
    const latest = await store.getLatestAnchor();
    if (latest && latest.seq === head.seq) return { submitted: false, reason: 'unchanged', id: latest.id };
    const digest = unhex(head.hash);
    const results = await Promise.allSettled(calendars.map((c) => submitTo(c, digest)));
    const timestamp = { attestations: [], ops: [] };
    const accepted = [], failed = [];
    results.forEach((r, i) => {
      if (r.status === 'fulfilled') { mergeTimestamp(timestamp, r.value); accepted.push(calendars[i]); }
      else failed.push({ calendar: calendars[i], error: String(r.reason?.message ?? r.reason) });
    });
    if (!accepted.length) return { submitted: false, reason: 'no_calendar', failed };
    const id = await store.insertAnchor({
      seq: head.seq, hash: head.hash, submittedAt: now(), calendars: accepted.length,
      status: 'pending', height: null, upgradedAt: null, proof: b64encode(serializeOts({ digest, timestamp })),
    });
    return { submitted: true, id, seq: head.seq, accepted, failed };
  }

  /** Every 6 hours: ask each pending attestation's calendar for the Bitcoin-attested continuation. */
  async function upgrade() {
    const summary = { checked: 0, confirmed: [], errors: [] };
    let budget = config.MAX_UPGRADE_REQUESTS;
    for (const anchor of await store.listPendingAnchors()) {
      if (budget <= 0) break;
      summary.checked++;
      try {
        const { digest, timestamp } = parseOts(b64decode(anchor.proof));
        const before = hex(serializeTimestamp(timestamp));
        for (const { attestation, msg, node } of await attestations(timestamp, digest)) {
          if (attestation.type !== 'pending' || !isWhitelistedCalendar(attestation.uri) || budget <= 0) continue;
          budget--;
          try {
            const { status, body } = await request(endpoint(attestation.uri, `timestamp/${hex(msg)}`));
            if (status !== 200) continue; // 404: not in a Bitcoin block yet
            if (body.length > config.MAX_RESPONSE) throw new Error('response too large');
            mergeTimestamp(node, parseTimestamp(body));
          } catch (e) {
            summary.errors.push({ id: anchor.id, calendar: attestation.uri, error: String(e?.message ?? e) });
          }
        }
        if (hex(serializeTimestamp(timestamp)) === before) continue;
        const heights = (await attestations(timestamp, digest)).filter((a) => a.attestation.type === 'bitcoin').map((a) => a.attestation.height);
        const confirmed = heights.length > 0;
        await store.updateAnchor(anchor.id, {
          status: confirmed ? 'confirmed' : 'pending', height: confirmed ? Math.min(...heights) : null,
          upgradedAt: now(), proof: b64encode(serializeOts({ digest, timestamp })),
        });
        if (confirmed) summary.confirmed.push({ id: anchor.id, height: Math.min(...heights) });
      } catch (e) {
        summary.errors.push({ id: anchor.id, error: String(e?.message ?? e) });
      }
    }
    return summary;
  }

  /** Public view of an anchor (no proof bytes). */
  const view = (a) => ({
    id: a.id, seq: a.seq, hash: a.hash, status: a.status, height: a.height ?? null,
    submittedAt: a.submittedAt, upgradedAt: a.upgradedAt ?? null, calendars: a.calendars, ots: `/ledger/v1/anchors/${a.id}.ots`,
  });

  async function list() { return { anchors: (await store.listAnchors()).map(view) }; }

  /** The complete .ots file (file digest = the anchored head hash), or null. */
  async function proofFile(id) {
    const a = await store.getAnchor(id);
    return a && { seq: a.seq, bytes: b64decode(a.proof) };
  }

  return { submit, upgrade, list, proofFile };
}

// Cron schedules; must match [triggers] crons in wrangler.toml. They live here, not in worker.js, because
// workerd treats every named export of the entry module as a handler and refuses to start on a string.
export const CRON_SUBMIT = '0 3 * * *';
export const CRON_UPGRADE = '0 */6 * * *';
