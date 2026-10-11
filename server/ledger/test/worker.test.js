import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker from '../worker.js';
import { makeSqliteD1, makeDevice, makeSigningKey, openEnvelope } from './helpers.js';

async function env() {
  return { DB: await makeSqliteD1(), LEDGER_SIGNING_KEY: await makeSigningKey(), LEDGER_ADMIN_TOKEN: 'admin-secret' };
}
const call = (e, method, path, body, token) => worker.fetch(new Request(`https://suhyeok.pickuma.com${path}`, {
  method,
  headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
  body: body === undefined ? undefined : JSON.stringify(body),
}), e);

test('paths outside /ledger/ are not handled; unknown /ledger/ paths are JSON 404', async () => {
  const e = await env();
  const outside = await call(e, 'GET', '/');
  assert.equal(outside.status, 404);
  assert.equal(await outside.text(), 'Not Found');
  for (const p of ['/ledgerx', '/api/sessions']) assert.equal((await call(e, 'GET', p)).status, 404);
  const inside = await call(e, 'GET', '/ledger/v1/nope');
  assert.equal(inside.status, 404);
  assert.deepEqual(await inside.json(), { error: 'not_found' });
  assert.equal((await call(e, 'GET', '/ledger/v2/pubkey')).status, 404);
});

test('admin endpoints require the bearer token', async () => {
  const e = await env();
  assert.equal((await call(e, 'POST', '/ledger/v1/admin/codes', {})).status, 401);
  assert.equal((await call(e, 'POST', '/ledger/v1/admin/codes', {}, 'wrong')).status, 401);
  assert.equal((await call(e, 'POST', '/ledger/v1/admin/codes', {}, 'admin-secret')).status, 201);
});

test('end to end over HTTP: code, register, sync, signed balance', async () => {
  const e = await env();
  const { key } = await (await call(e, 'GET', '/ledger/v1/pubkey')).json();
  const { code } = await (await call(e, 'POST', '/ledger/v1/admin/codes', {}, 'admin-secret')).json();
  const dev = await makeDevice();
  const reg = await call(e, 'POST', '/ledger/v1/register', { code, key: dev.key });
  assert.equal(reg.status, 201);
  const { device } = await reg.json();
  await dev.append('earn', 's1', 3, Math.floor(Date.now() / 1000));
  const s = await call(e, 'POST', '/ledger/v1/sync', { device, entries: dev.since(-1) });
  assert.equal(s.status, 200);
  assert.equal((await openEnvelope(await s.json(), key)).balance, 3);
  const b = await openEnvelope(await (await call(e, 'GET', `/ledger/v1/balance/${device}`)).json(), key);
  assert.equal(b.balance, 3);
  // A retried registration (lost response) gets the same device back.
  const again = await call(e, 'POST', '/ledger/v1/register', { code, key: dev.key });
  assert.equal((await again.json()).device, device);
  const v = await (await call(e, 'GET', '/ledger/v1/admin/verify', undefined, 'admin-secret')).json();
  assert.equal(v.ok, true);
  assert.equal(v.balancesMatch, true);
});
