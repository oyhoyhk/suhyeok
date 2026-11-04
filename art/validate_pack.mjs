// Check character packs with the server's own rules (server/ledger/assets.js), before uploading them.
// usage: node art/validate_pack.mjs <pack dir> ...   -> one line per pack; exit 1 when any pack is invalid
import { readFile, readdir } from 'node:fs/promises';
import { join, relative } from 'node:path';

const { validatePack } = await import(new URL('../server/ledger/assets.js', import.meta.url));

async function walk(dir) {
  const out = [];
  for (const e of await readdir(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...(await walk(p)));
    else out.push(p);
  }
  return out;
}

let bad = 0;
for (const dir of process.argv.slice(2)) {
  const files = new Map();
  for (const p of await walk(dir)) {
    const rel = relative(dir, p);
    if (rel !== 'manifest.json') files.set(rel, new Uint8Array(await readFile(p)));
  }
  const errors = await validatePack(await readFile(join(dir, 'manifest.json'), 'utf8'), files);
  if (errors.length) bad++;
  console.log(dir.replace(/\/$/, '').split('/').pop(), errors.length ? JSON.stringify(errors) : 'valid');
}
process.exit(bad ? 1 : 0);
