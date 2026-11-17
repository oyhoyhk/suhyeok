#!/usr/bin/env node
// Compares two 수혁 servers on the same machine field by field (/api/state agents, /api/sidebar, one /api/chat).
// Each server is paired first. Usage:
//   node contract/compare.mjs A=<base>,<secret>,<approve cmd> B=<base>,<secret>,<approve cmd>
import { execSync } from "node:child_process";

const sleep = ms => new Promise(r => setTimeout(r, ms));
async function pair(base, secret, approve) {
  const r = await fetch(base + "/pair", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ secret }) });
  const { pending } = await r.json();
  execSync(approve, { shell: "/bin/sh", stdio: "ignore" });
  for (let i = 0; i < 40; i++) {
    const s = await fetch(base + "/pair/status?id=" + pending);
    const c = s.headers.get("set-cookie");
    if (c) return c.split(";")[0];
    await sleep(250);
  }
  throw new Error("pairing failed: " + base);
}
const servers = process.argv.slice(2).map(a => { const [name, rest] = a.split("="); const [base, secret, approve] = rest.split(","); return { name, base, secret, approve }; });
for (const s of servers) s.cookie = await pair(s.base, s.secret, s.approve);
const get = (s, p) => fetch(s.base + p, { headers: { Cookie: s.cookie } }).then(r => r.json());
const [A, B] = servers;
const [sa, sb] = await Promise.all([get(A, "/api/state"), get(B, "/api/state")]);

let diffs = 0;
const report = (what, a, b) => { diffs++; console.log(`DIFF ${what}\n  ${A.name}: ${JSON.stringify(a)}\n  ${B.name}: ${JSON.stringify(b)}`); };
const byId = l => Object.fromEntries(l.map(x => [x.id, x]));
const ia = byId(sa.agents), ib = byId(sb.agents);
const onlyA = Object.keys(ia).filter(k => !ib[k]), onlyB = Object.keys(ib).filter(k => !ia[k]);
if (onlyA.length || onlyB.length) report("agent ids", onlyA, onlyB);
const fields = ["name", "title", "project", "cwd", "agent", "status", "activity", "activityCode", "character", "charName", "x", "y", "tier",
  "hunt", "action", "actionSymbol", "canClone", "canFork", "color", "estimated", "started", "updated", "lastUser", "lastAssistant", "parent", "last"];
// Same value: numbers within 1e-6, objects compared with sorted keys (key order and float tails do not matter).
const canon = v => Array.isArray(v) ? v.map(canon) : v && typeof v === "object"
  ? Object.fromEntries(Object.keys(v).sort().map(k => [k, canon(v[k])])) : typeof v === "number" ? Math.round(v * 1e6) / 1e6 : v;
const near = (x, y) => JSON.stringify(canon(x)) === JSON.stringify(canon(y));
const counts = {};
for (const id of Object.keys(ia).filter(k => ib[k])) {
  for (const f of fields) {
    // "last"/"updated" move with every refresh; a 10 s window is the same moment for two servers polled together.
    const same = (f === "last" || f === "updated" || f === "started") ? Math.abs((ia[id][f] || 0) - (ib[id][f] || 0)) < 10 : near(ia[id][f], ib[id][f]);
    if (!same) { counts[f] = (counts[f] || 0) + 1; if (counts[f] <= 2) report(`${id}.${f}`, ia[id][f], ib[id][f]); }
  }
}
for (const k of ["crystals", "avatar"]) if (!near(sa[k], sb[k])) report(k, sa[k], sb[k]);
if (!near(sa.world, sb.world)) report("world", sa.world, sb.world);
if (!near(sa.bosses, sb.bosses)) report("bosses", sa.bosses, sb.bosses);

const [da, db] = await Promise.all([get(A, "/api/sidebar"), get(B, "/api/sidebar")]);
// Hosted (수혁's own terminals) and external rows together: a server that cannot see tmux yet lists hosted agents as external.
const order = d => [...d.hosted, ...d.external].flatMap(g => g.items.map(i => i.id || i.key)).sort();
if (JSON.stringify(order(da)) !== JSON.stringify(order(db))) report("sidebar agents", order(da), order(db));
const rec = d => d.recent.map(r => r.id);
if (JSON.stringify(rec(da)) !== JSON.stringify(rec(db))) report("sidebar recent ids", rec(da), rec(db));

const one = Object.keys(ia).find(k => ib[k] && ia[k].agent === "Claude");
if (one) {
  const [ca, cb] = await Promise.all([get(A, "/api/chat?id=" + one), get(B, "/api/chat?id=" + one)]);
  const ta = ca.items.map(i => i.role + ":" + i.text), tb = cb.items.map(i => i.role + ":" + i.text);
  const sameItems = ta.length === tb.length && ta.every((t, i) => t === tb[i]);
  if (!sameItems) report(`chat ${one} items (${ta.length} vs ${tb.length})`, ta.find((t, i) => t !== tb[i]), tb.find((t, i) => t !== ta[i]));
  if (!near(ca.usage ?? null, cb.usage ?? null)) report(`chat ${one} usage`, ca.usage, cb.usage);
}
console.log(`\n${Object.keys(ia).length}/${Object.keys(ib).length} agents; field mismatch counts: ${JSON.stringify(counts)}; ${diffs} diff line(s)`);
