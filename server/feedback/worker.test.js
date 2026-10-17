import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker, { issueFrom, parseReport } from './worker.js';

test('parseReport rejects empty, long and unknown-source reports', () => {
  assert.ok(parseReport(null).error);
  assert.ok(parseReport({ text: '  ', source: 'mac' }).error);
  assert.ok(parseReport({ text: 'x'.repeat(4001), source: 'mac' }).error);
  assert.ok(parseReport({ text: 'hi', source: 'web' }).error);
});

test('parseReport drops long or multi-line context fields', () => {
  const { report } = parseReport({ text: ' 버튼이 안 눌림 ', source: 'phone', version: 'x'.repeat(61), os: 'Android\n14' });
  assert.equal(report.text, '버튼이 안 눌림');
  assert.equal(report.version, undefined);
  assert.equal(report.os, 'Android 14');
});

test('issueFrom titles with the first non-empty line and lists the context', () => {
  const { title, body } = issueFrom({ text: '\n대화창이 멈춤\n자세히…', source: 'mac', version: '0.1.10', agent: 'claude' });
  assert.equal(title, '[피드백] 대화창이 멈춤');
  assert.match(body, /- 보낸 곳: 맥 앱\n- 수혁 버전: 0.1.10\n- 에이전트: claude$/);
  assert.equal(issueFrom({ text: 'a'.repeat(80), source: 'agent' }).title, '[피드백] ' + 'a'.repeat(70) + '…');
});

test('fetch creates the issue and returns its link', async () => {
  const sent = [];
  globalThis.fetch = async (url, init) => {
    sent.push({ url, init });
    return new Response(JSON.stringify({ html_url: 'https://github.com/oyhoyhk/suhyeok/issues/7', number: 7 }), { status: 201 });
  };
  const req = new Request('https://x/', { method: 'POST', body: JSON.stringify({ text: '좋아요', source: 'agent' }) });
  const res = await worker.fetch(req, { GITHUB_TOKEN: 't', LIMIT: { limit: async () => ({ success: true }) } });
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { url: 'https://github.com/oyhoyhk/suhyeok/issues/7', number: 7 });
  assert.equal(sent[0].url, 'https://api.github.com/repos/oyhoyhk/suhyeok/issues');
  assert.deepEqual(JSON.parse(sent[0].init.body).labels, ['feedback']);
});

test('fetch refuses past the rate limit without calling GitHub', async () => {
  globalThis.fetch = async () => assert.fail('GitHub called');
  const req = new Request('https://x/', { method: 'POST', body: JSON.stringify({ text: 'a', source: 'mac' }) });
  const res = await worker.fetch(req, { LIMIT: { limit: async () => ({ success: false }) } });
  assert.equal(res.status, 429);
});
