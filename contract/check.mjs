#!/usr/bin/env node
// Contract check for a 수혁 server (contract/README.md): pairs once, then checks the read API's shapes and the
// security rules (host, origin, auth). It never calls the endpoints that change sessions.
// Usage: node contract/check.mjs --base http://127.0.0.1:4380 --secret <32hex> --approve '<shell command>'
import { execSync } from "node:child_process";
import http from "node:http";

const arg = name => { const i = process.argv.indexOf("--" + name); return i > 0 ? process.argv[i + 1] : undefined; };
const base = (arg("base") || "http://127.0.0.1:4380").replace(/\/$/, "");
const secret = arg("secret"), approve = arg("approve");
const host = new URL(base).host;
let failed = 0, cookie = "";
const ok = (name, cond, detail = "") => { console.log(`${cond ? "PASS" : "FAIL"} ${name}${!cond && detail ? " — " + detail : ""}`); if (!cond) failed++; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const req = (path, { method = "GET", headers = {}, body } = {}) =>
  fetch(base + path, { method, headers: { Host: host, ...(cookie ? { Cookie: cookie } : {}), ...headers }, body, redirect: "manual" });
const get = async path => { const r = await req(path); return { status: r.status, type: r.headers.get("content-type") || "", json: await r.json().catch(() => null) }; };

// Field types: "s" string, "n" number, "b" boolean, "a" array, "o" object, "s?" optional string, "s|null".
function shape(name, obj, spec) {
  if (!obj || typeof obj !== "object") return ok(name, false, "not an object");
  const bad = [];
  for (const [k, t] of Object.entries(spec)) {
    const optional = t.endsWith("?"), want = t.replace("?", ""), v = obj[k];
    if (v === undefined) { if (!optional) bad.push(k + " missing"); continue; }
    const kinds = want.split("|"), actual = v === null ? "null" : Array.isArray(v) ? "a" : { string: "s", number: "n", boolean: "b", object: "o" }[typeof v];
    if (!kinds.includes(actual)) bad.push(`${k}: ${actual} != ${want}`);
  }
  ok(name, bad.length === 0, bad.join(", "));
}

// --- no auth ---
{
  const r = await req("/desk"); const t = await r.text();
  ok("GET /desk is HTML", r.status === 200 && (r.headers.get("content-type") || "").startsWith("text/html"));
  ok("/desk lang filled in", /<html lang="(ko|en)">/.test(t), t.slice(0, 60));
  ok("security headers", r.headers.get("x-frame-options") === "DENY" && r.headers.get("cache-control") === "no-store"
    && (r.headers.get("content-security-policy") || "").includes("default-src 'self'"));
}
{
  // fetch() ignores a Host override, so this one goes through node:http.
  const u = new URL(base + "/api/state");
  const { status, body } = await new Promise((resolve, reject) => {
    const r = http.request({ hostname: u.hostname, port: u.port, path: u.pathname, headers: { Host: "evil.example" } }, res => {
      let b = ""; res.on("data", c => b += c); res.on("end", () => resolve({ status: res.statusCode, body: b }));
    });
    r.on("error", reject); r.end();
  });
  ok("foreign Host -> 421", status === 421 && body.includes('"host"'), status + " " + body);
}
ok("no cookie -> 401 pair", (await get("/api/state")).status === 401);
{
  const r = await req("/api/send", { method: "POST", headers: { "Content-Type": "text/plain" }, body: "{}" });
  ok("non-JSON POST -> 403 origin", r.status === 403);
  const r2 = await req("/api/send", { method: "POST", headers: { "Content-Type": "application/json", "Sec-Fetch-Site": "cross-site" }, body: "{}" });
  ok("cross-site POST -> 403 origin", r2.status === 403);
}
{
  const r = await req("/pair", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ secret: "0".repeat(32) }) });
  ok("wrong pairing secret -> 403", r.status === 403);
}

// --- pairing ---
if (!secret) { console.log("SKIP authenticated checks (no --secret)"); process.exit(failed ? 1 : 0); }
{
  const r = await req("/pair", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ secret }) });
  const j = await r.json().catch(() => ({}));
  ok("POST /pair -> pending id", r.status === 200 && typeof j.pending === "string", JSON.stringify(j));
  if (approve) execSync(approve, { stdio: "ignore", shell: "/bin/sh" });
  for (let i = 0; i < 40 && !cookie; i++) {
    const s = await req("/pair/status?id=" + encodeURIComponent(j.pending || ""));
    const setCookie = s.headers.get("set-cookie") || "";
    const body = await s.json().catch(() => ({}));
    if (body.ok && setCookie.startsWith("sh=")) {
      cookie = setCookie.split(";")[0];
      ok("cookie flags", /HttpOnly/i.test(setCookie) && /Secure/i.test(setCookie) && /SameSite=Strict/i.test(setCookie), setCookie);
    } else if (!body.waiting) { ok("pair status", false, s.status + " " + JSON.stringify(body)); break; }
    else await sleep(250);
  }
  ok("paired", !!cookie);
  if (!cookie) process.exit(1);
}

// --- authenticated reads ---
const state = await get("/api/state");
ok("GET /api/state 200 JSON", state.status === 200 && state.type.startsWith("application/json"));
shape("state", state.json, { agents: "a", bosses: "a", crystals: "n", world: "o", avatar: "n", prompts: "a" });
shape("state.world", state.json?.world, { w: "n", h: "n" });
for (const b of (state.json?.bosses || []).slice(0, 1)) shape("state.bosses[0]", b, { key: "s", name: "s", x: "n", y: "n", w: "n", h: "n" });
const agent = state.json?.agents?.[0];
if (agent) {
  shape("state.agents[0]", agent, {
    id: "s", name: "s", title: "s", project: "s", cwd: "s", agent: "s", status: "s", activity: "s", activityCode: "s",
    character: "s", x: "n", y: "n", tier: "s|null", hunt: "s", action: "s", last: "n", canSend: "b", hosted: "b",
    canClone: "b", canFork: "b", color: "n", estimated: "b", charName: "s", started: "n", updated: "n",
    lastUser: "s", lastAssistant: "s", parent: "s", actionSymbol: "s", term: "s?",
  });
  ok("agents[].color in 0..9", state.json.agents.every(a => Number.isInteger(a.color) && a.color >= 0 && a.color <= 9));
  const chat = await get("/api/chat?id=" + encodeURIComponent(agent.id));
  shape("chat", chat.json, { items: "a", status: "s", activity: "s", activityCode: "s", action: "s", usage: "o?", menu: "a?", live: "s?" });
  for (const it of (chat.json?.items || []).slice(-1)) shape("chat.items[-1]", it, { role: "s", text: "s" });
} else console.log("SKIP agent and chat shapes (server has no sessions)");
ok("chat unknown id -> 404 gone", (await get("/api/chat?id=__none__")).status === 404);

const side = await get("/api/sidebar");
shape("sidebar", side.json, { hosted: "a", shells: "a", external: "a", recent: "a", sorts: "a", sort: "s", ascending: "b", panel: "b" });
for (const g of [...(side.json?.hosted || []), ...(side.json?.external || [])].slice(0, 1)) shape("sidebar group", g, { folder: "s", items: "a" });
for (const r of (side.json?.recent || []).slice(0, 1)) shape("sidebar.recent[0]", r, { id: "s", agent: "s", title: "s", folder: "s", updated: "n" });

const ev = await get("/api/events?after=0&boot=__none__");
shape("events", ev.json, { boot: "s", seq: "n", events: "a" });
ok("events with another boot -> empty", Array.isArray(ev.json?.events) && ev.json.events.length === 0);

shape("terminals", (await get("/api/terminals")).json, { terminals: "a" });
shape("folders", (await get("/api/folders")).json, { home: "s", folders: "a" });
shape("files roots", (await get("/api/files")).json, { home: "s", folders: "a" });
{
  const r = await get("/api/nope");
  ok("unknown path -> 404 not found", r.status === 404 && r.json?.error === "not found");
}

console.log(failed ? `\n${failed} check(s) failed` : "\nall checks passed");
process.exit(failed ? 1 : 0);
