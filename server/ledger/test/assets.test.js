import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { validatePack, codes, classifyPath, parsePng, parseJpeg } from '../assets.js';

const DIR = new URL('./asset-vectors/', import.meta.url);

for (const name of readdirSync(DIR).filter((n) => existsSync(new URL(`${n}/expected.json`, DIR))).sort()) {
  test(`asset vector ${name}`, async () => {
    const base = new URL(`${name}/`, DIR);
    const expected = JSON.parse(readFileSync(new URL('expected.json', base), 'utf8')).js;
    const manifestText = readFileSync(new URL('manifest.json', base), 'utf8');
    const files = new Map();
    let listed = {};
    try { listed = JSON.parse(manifestText).files ?? {}; } catch { /* bad manifest case */ }
    for (const path of Object.keys(listed)) {
      if (!classifyPath(path)) continue; // never read outside the pack
      const u = new URL(path, base);
      if (existsSync(u)) files.set(path, new Uint8Array(readFileSync(u)));
    }
    assert.deepEqual(codes(await validatePack(manifestText, files)), expected);
  });
}

test('paths outside the layout are refused', () => {
  for (const p of ['../x.png', 'frames/../sprite.png', 'frames/sub/walk_down_0.png', '.hidden.png', 'sprite.svg',
    'frames/walk_down_01.png', 'frames/dance_0.png', 'portrait.jpeg', '/sprite.png']) {
    assert.equal(classifyPath(p), null, p);
  }
  assert.deepEqual(classifyPath('frames/walk_down_5.png'), { role: 'frame', format: 'png', motion: 'walk_down', index: 5 });
});

test('truncated or tampered images are not sound', () => {
  const png = new Uint8Array(readFileSync(new URL('ok_minimal/frames/attack_0.png', DIR)));
  assert.ok(parsePng(png));
  assert.equal(parsePng(png.slice(0, png.length - 4)), null);
  const flipped = png.slice(); flipped[40] ^= 0xff;
  assert.equal(parsePng(flipped), null); // CRC no longer matches
  const jpg = new Uint8Array(readFileSync(new URL('ok_minimal/portrait.jpg', DIR)));
  assert.deepEqual(parseJpeg(jpg), { width: 128, height: 160 });
  assert.equal(parseJpeg(jpg.slice(0, jpg.length - 10)), null);
});
