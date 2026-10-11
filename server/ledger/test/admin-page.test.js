// Operator review page (U5): served headers, self-containment, no HTML sinks for listing text, and the admin
// file route the page relies on.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../worker.js';
import { ADMIN_HTML } from '../admin-page.js';
import { sha256hex } from '../ledger.js';
import { MemoryR2, makeSqliteD1, makeDevice, makeSigningKey } from './helpers.js';

const ADMIN = 'admin-secret';
const HOST = 'https://suhyeok.pickuma.com';
const XSS = '<img src=x onerror=alert(1)>';

async function env() {
  return { DB: await makeSqliteD1(), ASSETS: new MemoryR2(), LEDGER_SIGNING_KEY: await makeSigningKey(), LEDGER_ADMIN_TOKEN: ADMIN };
}
const get = (e, path, token, method = 'GET') => worker.fetch(new Request(`${HOST}${path}`, {
  method, headers: token ? { authorization: `Bearer ${token}` } : {},
}), e);
const api = (e, method, path, { body, token, headers = {}, raw } = {}) => worker.fetch(new Request(`${HOST}/ledger/v1${path}`, {
  method,
  headers: { ...(raw ? {} : { 'content-type': 'application/json' }), ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
  body: raw ?? (body === undefined ? undefined : JSON.stringify(body)),
}), e);
const bytesSha = async (b) => [...new Uint8Array(await crypto.subtle.digest('SHA-256', b))].map((x) => x.toString(16).padStart(2, '0')).join('');

/** ok_minimal with a hostile name, alias and description, submitted to pending over HTTP. */
async function pendingListing(e) {
  const base = new URL('./asset-vectors/ok_minimal/', import.meta.url);
  const m = JSON.parse(readFileSync(new URL('manifest.json', base), 'utf8'));
  m.name = XSS;
  const manifest = JSON.stringify(m);
  const files = Object.keys(m.files).map((p) => [p, new Uint8Array(readFileSync(new URL(p, base)))]);

  const dev = await makeDevice();
  const { code } = await (await api(e, 'POST', '/admin/codes', { body: {}, token: ADMIN })).json();
  dev.id = (await (await api(e, 'POST', '/register', { body: { code, key: dev.key } })).json()).device;
  let t = Math.floor(Date.now() / 1000);
  const fields = { alias: '<b>x</b>', description: '<script>alert(2)</script>', manifestSha256: await sha256hex(manifest), price: 300 };
  const dr = await dev.marketRequest('market.draft', fields, t++);
  const created = await api(e, 'POST', '/market/drafts', { body: { ...dr, manifest } });
  assert.equal(created.status, 201);
  const { listingId } = await created.json();
  for (const [path, bytes] of files) {
    const time = t++;
    const r = await dev.marketRequest('market.file', { listingId, path, sha256: await bytesSha(bytes) }, time);
    const up = await api(e, 'PUT', `/market/drafts/${listingId}/files/${path}`, {
      raw: bytes, headers: { 'x-ledger-device': dev.id, 'x-ledger-time': String(time), 'x-ledger-sig': r.sig },
    });
    assert.equal(up.status, 200, path);
  }
  const sub = await dev.marketRequest('market.submit', { listingId }, t++);
  assert.equal((await api(e, 'POST', `/market/drafts/${listingId}/submit`, { body: sub })).status, 200);
  return { listingId, files };
}

/** The inline script of the page. */
const pageScript = (html) => {
  const m = html.match(/<script nonce="([^"]+)">([\s\S]*?)<\/script>/);
  assert.ok(m, 'one nonce script');
  return { nonce: m[1], js: m[2] };
};

test('the review page is served at /ledger/admin/ with a locked-down CSP and security headers', async () => {
  const e = await env();
  const r = await get(e, '/ledger/admin/');
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('content-type'), 'text/html; charset=utf-8');
  assert.equal(r.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(r.headers.get('referrer-policy'), 'no-referrer');
  assert.equal(r.headers.get('cache-control'), 'no-store');
  const csp = Object.fromEntries(r.headers.get('content-security-policy').split(';').map((d) => {
    const [k, ...v] = d.trim().split(/\s+/);
    return [k, v.join(' ')];
  }));
  const html = await r.text();
  const { nonce } = pageScript(html);
  assert.notEqual(nonce, '__CSP_NONCE__');
  assert.deepEqual(csp, {
    'default-src': "'none'", 'script-src': `'nonce-${nonce}'`, 'style-src': "'unsafe-inline'", 'img-src': 'blob:',
    'connect-src': "'self'", 'frame-ancestors': "'none'", 'base-uri': "'none'", 'form-action': "'none'",
  });
  // A fresh nonce per response.
  assert.notEqual(pageScript(await (await get(e, '/ledger/admin/')).text()).nonce, nonce);

  const redirect = await get(e, '/ledger/admin');
  assert.equal(redirect.status, 308);
  assert.equal(redirect.headers.get('location'), '/ledger/admin/');
  const head = await get(e, '/ledger/admin/', undefined, 'HEAD');
  assert.equal(head.status, 200);
  assert.equal((await get(e, '/ledger/admin/', undefined, 'POST')).status, 405);
  // The page does not need the ledger secrets or the market binding.
  assert.equal((await get({}, '/ledger/admin/')).status, 200);
});

test('the page is self-contained and never writes listing text as HTML', () => {
  assert.doesNotMatch(ADMIN_HTML, /https?:\/\//, 'no absolute URLs');
  assert.doesNotMatch(ADMIN_HTML, /<(link|iframe|object|embed|form)\b/i);
  assert.equal((ADMIN_HTML.match(/<script\b/g) ?? []).length, 1, 'only the inline script');
  assert.doesNotMatch(ADMIN_HTML, /<script[^>]*\ssrc=/i);
  assert.doesNotMatch(ADMIN_HTML, /\son[a-z]+=/i, 'no inline event handler attributes');
  const css = ADMIN_HTML.match(/<style>([\s\S]*?)<\/style>/)[1];
  assert.doesNotMatch(css, /@import|url\(/i, 'no CSS fetches');
  const { js } = pageScript(ADMIN_HTML);
  for (const sink of ['innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(', 'new Function', 'srcdoc']) {
    assert.ok(!js.includes(sink), sink);
  }
  assert.ok(js.includes('.textContent ='), 'text goes through textContent');
  assert.ok(!js.includes('localStorage'), 'token stays in sessionStorage');
  assert.ok(js.includes('sessionStorage.setItem'));
  assert.doesNotThrow(() => new Function(js), 'page script parses');
});

test('admin file route: 401 without the token, every file of a pending listing with it; listing text is returned verbatim as JSON', async () => {
  const e = await env();
  const { listingId, files } = await pendingListing(e);
  const pending = await api(e, 'GET', '/admin/market/pending', { token: ADMIN });
  assert.equal(pending.status, 200);
  const [item] = (await pending.json()).pending;
  assert.equal(item.id, listingId);
  assert.equal(item.name, XSS);
  assert.equal(item.alias, '<b>x</b>');
  assert.equal(item.description, '<script>alert(2)</script>');
  assert.equal(pending.headers.get('content-type'), 'application/json; charset=utf-8');

  assert.equal(item.files.length, files.length);
  for (const f of item.files) {
    assert.ok(f.url.startsWith('/ledger/v1/admin/market/'), f.url);
    assert.equal((await get(e, f.url)).status, 401, `${f.path} without token`);
    assert.equal((await get(e, f.url, 'wrong')).status, 401, `${f.path} wrong token`);
    const r = await get(e, f.url, ADMIN);
    assert.equal(r.status, 200, f.path);
    assert.match(r.headers.get('content-type'), /^image\/(png|jpeg)$/);
    assert.equal(r.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(await bytesSha(new Uint8Array(await r.arrayBuffer())), f.sha256);
  }

  // The page's actions map onto the U3 moderation API.
  const reject = await api(e, 'POST', `/admin/market/${listingId}/reject`, { body: { reason: '  ' }, token: ADMIN });
  assert.equal(reject.status, 400);
  assert.equal((await reject.json()).error, 'reason_required');
  const ok = await (await api(e, 'POST', `/admin/market/${listingId}/approve`, { body: {}, token: ADMIN })).json();
  assert.deepEqual([ok.listingId, ok.status], [listingId, 'approved']);
  const again = await api(e, 'POST', `/admin/market/${listingId}/approve`, { body: {}, token: ADMIN });
  assert.equal(again.status, 409);
  assert.equal((await again.json()).status, 'approved');
  // Approved listings stay readable through the admin route (the page's 판매 중 tab).
  assert.equal((await get(e, `/ledger/v1/admin/market/${listingId}/files/frames/walk_down_0.png`, ADMIN)).status, 200);
});
