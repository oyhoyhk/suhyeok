/// The phone page served by MobileServer: the hunting field on a canvas, tap an agent to talk to it.
enum MobilePage {
    static let html = #"""
<!doctype html>
<html lang="ko"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="theme-color" content="#120f1c">
<title>수혁</title>
<link rel="apple-touch-icon" href="/art/sprites/knight.png">
<style>
  :root { --bg:#120f1c; --panel:#1d1829; --line:#3a3150; --gold:#e0b44a; --fg:#ece6f5; --muted:#a99fbb;
          --me:#8a6a1e; --ok:#4cc38a; --warn:#e5534b; }
  * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
  html,body { margin:0; height:100%; background:var(--bg); color:var(--fg);
              font:15px -apple-system, "Apple SD Gothic Neo", system-ui, sans-serif; overflow:hidden; }
  #map { position:fixed; inset:0; width:100%; height:100%; touch-action:none; }
  .bar { position:fixed; left:0; right:0; top:0; padding:calc(env(safe-area-inset-top) + 8px) 12px 8px;
         display:flex; gap:10px; align-items:center; background:linear-gradient(#120f1cee, #120f1c00); pointer-events:none; }
  .bar b { color:var(--gold); font-size:17px; letter-spacing:.02em; }
  .pill { margin-left:auto; display:flex; gap:8px; font-size:12px; background:#000a; border:1px solid #e0b44a99;
          border-radius:99px; padding:5px 10px; white-space:nowrap; min-width:0; }
  .pill span { display:flex; gap:4px; align-items:center; font-variant-numeric:tabular-nums; }
  .dot { width:8px; height:8px; border-radius:50%; display:inline-block; }
  #sheet { position:fixed; left:0; right:0; bottom:0; max-height:78%; display:flex; flex-direction:column; overflow:hidden;
           background:var(--panel); border-top:2px solid var(--gold); border-radius:16px 16px 0 0;
           transform:translateY(105%); transition:transform .25s; padding-bottom:env(safe-area-inset-bottom); }
  #sheet.open { transform:none; }
  .head { display:flex; gap:10px; align-items:center; padding:12px 14px 8px; border-bottom:1px solid var(--line); }
  .head img { width:44px; height:44px; object-fit:contain; image-rendering:pixelated; }
  .head .t { flex:1; min-width:0; }
  .head .n { font-weight:700; color:var(--gold); }
  .head .s { font-size:12px; color:var(--muted); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .x { background:none; border:0; color:var(--muted); font-size:22px; padding:4px 8px; }
  #log { flex:1; overflow-y:auto; padding:10px 12px; display:flex; flex-direction:column; gap:8px; min-height:120px; }
  .m { max-width:86%; padding:8px 10px; border-radius:10px; white-space:pre-wrap; word-break:break-word; line-height:1.45; }
  .m.me { align-self:flex-end; background:var(--me); }
  .m.agent { align-self:flex-start; background:#ffffff14; }
  .m.tool { align-self:flex-start; background:none; color:var(--muted); font-size:12px; padding:0 2px; }
  .live { font:11.5px ui-monospace, Menlo, monospace; background:#000a; border:1px solid #4cc38a66; border-radius:8px;
          padding:8px; white-space:pre; overflow-x:auto; color:#ddd; max-width:100%; min-width:0; flex-shrink:0; }
  #log > * { max-width:100%; }
  .menu { border:1.5px solid var(--gold); border-radius:10px; padding:8px; display:flex; flex-direction:column; gap:6px; }
  .menu button { text-align:left; background:#ffffff10; color:var(--fg); border:0; border-radius:8px; padding:10px; font-size:14px; }
  .menu small { display:block; color:var(--muted); }
  .input { display:flex; gap:8px; padding:8px 12px 10px; border-top:1px solid var(--line); }
  .input textarea { flex:1; min-width:0; resize:none; height:42px; max-height:120px; background:#0008; color:var(--fg);
                    border:1px solid var(--line); border-radius:10px; padding:10px; font:15px inherit; }
  .input button, .keys button { background:var(--gold); color:#1a1408; border:0; border-radius:10px; font-weight:700; padding:0 14px; }
  .keys { display:flex; gap:6px; padding:0 12px 8px; }
  .keys button { background:#ffffff14; color:var(--fg); font-weight:600; padding:7px 12px; font-size:13px; }
  #pair { position:fixed; inset:0; display:none; place-items:center; background:var(--bg); padding:24px; }
  #pair.show { display:grid; }
  #pair form { width:100%; max-width:340px; display:grid; gap:14px; text-align:center; }
  #pair h1 { margin:0; color:var(--gold); font-size:24px; }
  #pair p { margin:0; color:var(--muted); line-height:1.5; }
  #pair input { font:28px ui-monospace, Menlo, monospace; letter-spacing:.3em; text-align:center; padding:12px;
                background:#0008; color:var(--fg); border:1px solid var(--line); border-radius:12px; }
  #pair button { padding:14px; border:0; border-radius:12px; background:var(--gold); color:#1a1408; font-weight:700; font-size:16px; }
  #pairErr { color:var(--warn); min-height:1.2em; }
  .toast { position:fixed; left:50%; top:calc(env(safe-area-inset-top) + 52px); transform:translateX(-50%);
           background:#000c; padding:8px 14px; border-radius:99px; font-size:13px; display:none; }
</style></head>
<body>
<canvas id="map"></canvas>
<div class="bar"><b>수혁</b><div class="pill" id="counts"></div></div>
<div class="toast" id="toast"></div>

<div id="sheet">
  <div class="head">
    <img id="hImg" alt="">
    <div class="t"><div class="n" id="hName"></div><div class="s" id="hSub"></div></div>
    <button class="x" id="close" aria-label="닫기">✕</button>
  </div>
  <div id="log"></div>
  <div class="keys">
    <button data-k="escape">Esc</button><button data-k="up">↑</button><button data-k="down">↓</button>
    <button data-k="enter">⏎</button>
  </div>
  <div class="input">
    <textarea id="msg" placeholder="지시하기"></textarea>
    <button id="send">보내기</button>
  </div>
</div>

<div id="pair"><form id="pairForm">
  <h1>수혁 연결</h1>
  <p>Mac의 수혁 → 설정(⌘,) → 모바일 접속에 보이는 6자리 코드를 입력하세요.</p>
  <input id="code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="000000">
  <div id="pairErr"></div>
  <button type="submit">연결</button>
</form></div>

<script>
const $ = id => document.getElementById(id);
const cv = $("map"), ctx = cv.getContext("2d");
let W = 0, H = 0, dpr = Math.min(2, devicePixelRatio || 1);
let world = { w: 1, h: 0.5625 }, avatar = 0.034, agents = [], bosses = [], crystals = 0;
const pos = {}, facing = {}, imgs = {};
let cam = { x: 0.5, y: 0.28, s: 0 }, selected = null, fitted = false;

function img(src) {
  if (!imgs[src]) { const i = new Image(); i.src = "/art/" + src; imgs[src] = i; }
  return imgs[src];
}
const mapImg = img("field.jpg");

function resize() {
  W = innerWidth; H = innerHeight;
  cv.width = W * dpr; cv.height = H * dpr;
  if (!cam.s) fit(); else clamp();
}
// The map always covers the screen (no empty bands); a phone held upright sees one region at a time.
function minScale() { return Math.max(W / world.w, H / world.h); }
function fit() {
  cam.s = minScale();
  // Start where the action is: the first working agent, else the camp.
  const busy = agents.find(a => a.status === "busy");
  const at = busy || agents.find(a => !a.tier) || { x: 0.25, y: 0.15 };
  cam.x = at.x; cam.y = at.y; clamp();
}
function clamp() {
  cam.s = Math.min(Math.max(cam.s, minScale()), W * 6);
  const hw = W / cam.s / 2, hh = H / cam.s / 2;
  cam.x = hw * 2 >= world.w ? world.w / 2 : Math.min(Math.max(cam.x, hw), world.w - hw);
  cam.y = hh * 2 >= world.h ? world.h / 2 : Math.min(Math.max(cam.y, hh), world.h - hh);
}
const sx = x => (x - cam.x) * cam.s + W / 2, sy = y => (y - cam.y) * cam.s + H / 2;

// Touch: one finger drags the map (or taps an agent), two fingers pinch-zoom.
let touches = {}, gesture = null;
cv.addEventListener("pointerdown", e => { cv.setPointerCapture(e.pointerId); touches[e.pointerId] = { x: e.clientX, y: e.clientY, x0: e.clientX, y0: e.clientY, t: Date.now() }; startGesture(); });
cv.addEventListener("pointermove", e => { if (!touches[e.pointerId]) return; touches[e.pointerId].x = e.clientX; touches[e.pointerId].y = e.clientY; moveGesture(); });
cv.addEventListener("pointerup", e => {
  const t = touches[e.pointerId]; delete touches[e.pointerId];
  if (t && Math.hypot(t.x - t.x0, t.y - t.y0) < 8 && Date.now() - t.t < 400) tap(t.x, t.y);
  startGesture();
});
cv.addEventListener("pointercancel", e => { delete touches[e.pointerId]; startGesture(); });
function startGesture() {
  const p = Object.values(touches);
  gesture = p.length ? { cx: cam.x, cy: cam.y, s: cam.s, p: p.map(t => ({ x: t.x, y: t.y })) } : null;
}
function moveGesture() {
  if (!gesture) return;
  const p = Object.values(touches);
  if (p.length === 1 && gesture.p.length === 1) {
    cam.x = gesture.cx - (p[0].x - gesture.p[0].x) / cam.s;
    cam.y = gesture.cy - (p[0].y - gesture.p[0].y) / cam.s;
  } else if (p.length >= 2 && gesture.p.length >= 2) {
    const d0 = Math.hypot(gesture.p[0].x - gesture.p[1].x, gesture.p[0].y - gesture.p[1].y);
    const d1 = Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y);
    const mx = (p[0].x + p[1].x) / 2, my = (p[0].y + p[1].y) / 2;
    const m0x = (gesture.p[0].x + gesture.p[1].x) / 2, m0y = (gesture.p[0].y + gesture.p[1].y) / 2;
    const wx = gesture.cx + (m0x - W / 2) / gesture.s, wy = gesture.cy + (m0y - H / 2) / gesture.s;
    cam.s = gesture.s * d1 / d0; clamp();
    cam.x = wx - (mx - W / 2) / cam.s; cam.y = wy - (my - H / 2) / cam.s;
  }
  clamp();
}
function tap(x, y) {
  let best = null, bd = 1e9;
  for (const a of agents) {
    const p = pos[a.id] || a; const d = Math.hypot(sx(p.x) - x, sy(p.y) - avatar * cam.s * 0.4 - y);
    if (d < bd) { bd = d; best = a; }
  }
  if (best && bd < Math.max(36, avatar * cam.s)) open(best.id); else close();
}

// Walking: along x first, then y (four directions only), at map speed.
function step(dt) {
  for (const a of agents) {
    let p = pos[a.id]; if (!p) { pos[a.id] = { x: a.x, y: a.y }; continue; }
    const v = 0.12 * dt; const dx = a.x - p.x, dy = a.y - p.y;
    if (Math.abs(dx) > 1e-4) { const m = Math.sign(dx) * Math.min(Math.abs(dx), v); p.x += m; facing[a.id] = dx < 0 ? "left" : "right"; p.walk = true; }
    else if (Math.abs(dy) > 1e-4) { const m = Math.sign(dy) * Math.min(Math.abs(dy), v); p.y += m; facing[a.id] = dy < 0 ? "up" : "down"; p.walk = true; }
    else p.walk = false;
  }
}

const beat = [0, 0, 1, 1, 2, 3, 3, 4, 5, 5, 0, 0];
function frameOf(a, p, t) {
  const ph = (a.id.length * 7) % 10 / 10;
  if (p.walk) {
    const f = Math.floor(t * 10) % 6, d = facing[a.id] || "down";
    return [d === "right" ? "walk_left_" + f : "walk_" + d + "_" + f, d === "right"];
  }
  if (a.tier) {
    const boss = bosses.find(b => b.key === a.tier); const right = boss && p.x < boss.x;
    if (a.status === "busy") return ["attack_" + beat[Math.floor((t + ph) * 10) % beat.length], right];
    return ["walk_left_2", right];
  }
  return ["walk_down_2", false];
}

let last = performance.now();
function draw(now) {
  const dt = Math.min(0.25, (now - last) / 1000); last = now; const t = now / 1000;
  step(dt);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.imageSmoothingEnabled = false;
  ctx.fillStyle = "#120f1c"; ctx.fillRect(0, 0, W, H);
  if (mapImg.complete) ctx.drawImage(mapImg, sx(0), sy(0), world.w * cam.s, world.h * cam.s);
  for (const b of bosses) {
    const i = img("bosses/" + b.key + "_" + (Math.floor(t * 6) % 6) + ".png");
    const h = b.h * cam.s * 1.25;
    if (i.complete && i.naturalHeight) { const w = h * i.naturalWidth / i.naturalHeight; ctx.drawImage(i, sx(b.x) - w / 2, sy(b.y) + b.h * cam.s / 2 - h, w, h); }
    ctx.font = "bold 12px -apple-system"; ctx.textAlign = "center"; ctx.fillStyle = "#fff";
    ctx.fillText(b.name, sx(b.x), sy(b.y) - b.h * cam.s * 0.95);
  }
  const list = agents.map(a => [a, pos[a.id] || a]).sort((u, v) => u[1].y - v[1].y);
  for (const [a, p] of list) {
    const [name, mirror] = frameOf(a, p, t);
    const i = img("frames/" + a.character + "/" + name + ".png");
    const base = avatar * cam.s, x = sx(p.x), y = sy(p.y) + base * 0.5;
    ctx.fillStyle = "#0005"; ctx.beginPath(); ctx.ellipse(x, y, base * 0.22, base * 0.06, 0, 0, 7); ctx.fill();
    if (i.complete && i.naturalHeight) {
      const h = base * i.naturalHeight / 128, w = h * i.naturalWidth / i.naturalHeight;
      ctx.save(); ctx.translate(x, y); if (mirror) ctx.scale(-1, 1);
      if (a.id === selected) { ctx.shadowColor = "#ffd34d"; ctx.shadowBlur = 12; }
      ctx.drawImage(i, -w / 2, -h, w, h); ctx.restore();
    }
    if (a.status === "waiting") bubble(x + base * 0.25, y - base * 1.1, "!", "#e5534b", "#fff");
    ctx.font = "bold 11px -apple-system"; ctx.textAlign = "center";
    const tw = ctx.measureText(a.name).width + 10;
    ctx.fillStyle = "#3b5bdbcc"; roundRect(x - tw / 2, y + 2, tw, 16, 8); ctx.fill();
    ctx.fillStyle = "#fff"; ctx.fillText(a.name, x, y + 14);
  }
  requestAnimationFrame(draw);
}
function bubble(x, y, s, bg, fg) { ctx.fillStyle = bg; roundRect(x - 8, y - 9, 16, 18, 8); ctx.fill(); ctx.fillStyle = fg; ctx.font = "bold 12px -apple-system"; ctx.textAlign = "center"; ctx.fillText(s, x, y + 4); }
function roundRect(x, y, w, h, r) { ctx.beginPath(); ctx.roundRect(x, y, w, h, r); }

async function api(path, body) {
  const r = await fetch(path, body ? { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body), credentials: "same-origin" } : { credentials: "same-origin" });
  if (r.status === 401) { $("pair").classList.add("show"); throw new Error("pair"); }
  return r.json();
}
async function poll() {
  try {
    const s = await api("/api/state");
    $("pair").classList.remove("show");
    world = s.world; avatar = s.avatar; agents = s.agents; bosses = s.bosses; crystals = s.crystals;
    const n = k => agents.filter(a => (a.tier || "camp") === k).length;
    $("counts").innerHTML = `<span title="대기소"><i class="dot" style="background:#888"></i>${n("camp")}</span>` +
      `<span title="하급"><i class="dot" style="background:#4cc38a"></i>${n("low")}</span><span title="중급"><i class="dot" style="background:#4dd0e1"></i>${n("mid")}</span>` +
      `<span title="상급"><i class="dot" style="background:#f0883e"></i>${n("high")}</span><span>💎 ${crystals}</span>`;
    if (!fitted && agents.length) {
      fit(); fitted = true;
      // Deep link: #a-<agent id> opens that agent's chat (used by the Mac's "폰에서 열기").
      const want = decodeURIComponent(location.hash.slice(3));
      if (location.hash.startsWith("#a-") && agents.some(a => a.id === want)) open(want);
    }
    if (selected) header();
  } catch (e) {}
  setTimeout(poll, 1500);
}

function header() {
  const a = agents.find(a => a.id === selected); if (!a) return close();
  $("hImg").src = "/art/frames/" + a.character + "/walk_down_2.png";
  $("hName").textContent = a.name + " · " + a.title;
  $("hSub").textContent = (a.status === "busy" ? "작업 중" : a.status === "waiting" ? "선택 기다리는 중" : a.activity) + " · " + a.hunt;
  $("msg").disabled = !a.canSend; $("msg").placeholder = a.canSend ? a.name + "에게 지시하기" : "이 터미널은 입력을 받을 수 없음";
}
let chatTimer = null, lastLog = "";
function open(id) { selected = id; lastLog = ""; header(); $("sheet").classList.add("open"); loadChat(); }
function close() { selected = null; $("sheet").classList.remove("open"); clearTimeout(chatTimer); }
$("close").onclick = close;
async function loadChat() {
  clearTimeout(chatTimer); if (!selected) return;
  try {
    const c = await api("/api/chat?id=" + encodeURIComponent(selected));
    const key = JSON.stringify(c);
    if (key !== lastLog) {
      lastLog = key;
      const log = $("log"), stick = log.scrollTop + log.clientHeight > log.scrollHeight - 40;
      log.innerHTML = "";
      for (const it of c.items || []) { const d = document.createElement("div"); d.className = "m " + it.role; d.textContent = it.role === "tool" ? "🔨 " + it.text : it.text; log.appendChild(d); }
      if (c.live) { const d = document.createElement("div"); d.className = "live"; d.textContent = c.live; log.appendChild(d); }
      if (c.menu) {
        const m = document.createElement("div"); m.className = "menu";
        m.innerHTML = "<b style='color:var(--gold)'>선택해 주세요</b>";
        c.menu.forEach((o, i) => { const b = document.createElement("button"); b.innerHTML = (i + 1) + ". " + esc(o.label) + (o.detail ? "<small>" + esc(o.detail) + "</small>" : ""); b.onclick = () => choose(i); m.appendChild(b); });
        log.appendChild(m);
      }
      if (stick || !log.dataset.seen) log.scrollTop = log.scrollHeight;
      log.dataset.seen = 1;
    }
  } catch (e) {}
  chatTimer = setTimeout(loadChat, 1200);
}
const esc = s => s.replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
function toast(s) { const t = $("toast"); t.textContent = s; t.style.display = "block"; clearTimeout(t._h); t._h = setTimeout(() => t.style.display = "none", 2200); }
async function send() {
  const text = $("msg").value.trim(); if (!text || !selected) return;
  $("msg").value = "";
  const r = await api("/api/send", { id: selected, text }).catch(() => ({}));
  toast(r.ok ? "보냄" : "보내지 못함");
  loadChat();
}
async function choose(i) { const r = await api("/api/choose", { id: selected, index: i }).catch(() => ({})); toast(r.ok ? "선택함" : "선택하지 못함"); loadChat(); }
$("send").onclick = send;
document.querySelectorAll(".keys button").forEach(b => b.onclick = () => api("/api/key", { id: selected, key: b.dataset.k }).then(loadChat));
$("pairForm").onsubmit = async e => {
  e.preventDefault();
  const r = await fetch("/pair", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ code: $("code").value }), credentials: "same-origin" });
  const j = await r.json().catch(() => ({}));
  if (r.ok) { $("pair").classList.remove("show"); $("pairErr").textContent = ""; } else $("pairErr").textContent = j.error || "연결하지 못함";
};
addEventListener("resize", resize);
resize(); poll(); requestAnimationFrame(draw);
</script>
</body></html>
"""#
}
