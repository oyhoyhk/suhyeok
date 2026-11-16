import Foundation

/// The desktop page served by MobileServer at /desk: Windows 수혁 (a Tauri window around this page) and PC browsers.
/// Same API and pairing as the phone page (MobilePage), laid out for a wide screen: the session list beside the chat,
/// and a terminal tab for 수혁's tmux sessions.
enum DesktopPage {
    /// UI strings, localized on the Mac and handed to the script as one object (JSONSerialization escapes "/", so the
    /// text cannot close the script tag).
    private static var strings: String {
        let t: [String: String] = [
            "app": String(localized: "수혁"),
            "pairTitle": String(localized: "수혁 연결"),
            "pairHelp": String(localized: "Mac의 수혁 → 설정(⌘,) → 모바일 접속에서 '연결 시작'을 누르고, 'PC용 링크 복사'로 받은 링크를 60초 안에 붙여넣으세요."),
            "pairButton": String(localized: "연결"),
            "pairSending": String(localized: "연결 요청을 보내는 중…"),
            "pairAllow": String(localized: "Mac에서 [허용]을 눌러 주세요. 2분 안에 허용하지 않으면 만료됨."),
            "pairBad": String(localized: "링크에서 연결 코드를 찾지 못함"),
            "pairFail": String(localized: "연결하지 못함"),
            "offline": String(localized: "Mac의 수혁에 연결할 수 없음 — Mac과 수혁이 켜져 있는지 확인"),
            "chat": String(localized: "대화"),
            "terminal": String(localized: "터미널"),
            "newSession": String(localized: "새 세션"),
            "crystals": String(localized: "결정"),
            "pick": String(localized: "왼쪽 목록에서 에이전트를 고르세요"),
            "noAgents": String(localized: "실행 중인 세션 없음"),
            "send": String(localized: "보내기"),
            "sendTo": String(localized: "{name}에게 지시하기 (Enter 보내기 · Shift+Enter 줄바꿈)"),
            "cannotSend": String(localized: "이 터미널은 입력을 받을 수 없음"),
            "sent": String(localized: "보냄"),
            "sendFail": String(localized: "보내지 못함"),
            "choose": String(localized: "선택해 주세요"),
            "chosen": String(localized: "선택함"),
            "chooseFail": String(localized: "선택하지 못함"),
            "typeAnswer": String(localized: "직접 입력"),
            "typed": String(localized: "입력함"),
            "attach": String(localized: "파일 첨부"),
            "uploading": String(localized: "올리는 중…"),
            "uploadFail": String(localized: "올리지 못함"),
            "tooBig": String(localized: "25MB보다 큰 파일은 보낼 수 없음"),
            "screen": String(localized: "화면 보기"),
            "tool": String(localized: "도구"),
            "copy": String(localized: "복사"),
            "copied": String(localized: "복사함"),
            "manage": String(localized: "관리"),
            "rename": String(localized: "이름 바꾸기"),
            "clone": String(localized: "클론"),
            "clear": String(localized: "새 대화로 다시 시작"),
            "clearConfirm": String(localized: "이 Claude 세션을 새 대화로 다시 시작할까요?"),
            "end": String(localized: "종료"),
            "endConfirm": String(localized: "이 세션을 종료할까요?"),
            "working": String(localized: "작업 중"),
            "waiting": String(localized: "선택 기다리는 중"),
            "context": String(localized: "컨텍스트"),
            "newShell": String(localized: "새 셸"),
            "noTerminals": String(localized: "수혁 터미널 없음"),
            "termHelp": String(localized: "화면을 클릭한 뒤 입력하면 이 터미널로 보내짐"),
            "termGone": String(localized: "터미널이 닫힘"),
            "agent": String(localized: "에이전트"),
            "folder": String(localized: "작업 폴더"),
            "prompt": String(localized: "첫 지시 (비워도 됨)"),
            "start": String(localized: "시작"),
            "ok": String(localized: "확인"),
            "cancel": String(localized: "취소"),
            "started": String(localized: "시작함"),
            "failed": String(localized: "실패함"),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: t)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static var html: String {
        #"""
<!doctype html>
<html lang="\#(L10n.english ? "en" : "ko")"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#120f1c">
<title>\#(String(localized: "수혁"))</title>
<style>
  :root { --bg:#120f1c; --panel:#1d1829; --panel2:#251f34; --line:#3a3150; --gold:#e0b44a; --fg:#ece6f5; --muted:#a99fbb;
          --me:#3d3157; --ok:#4cc38a; --warn:#e5534b;
          --mono: "Cascadia Mono", Consolas, "D2Coding", ui-monospace, Menlo, monospace; }
  * { box-sizing:border-box; }
  html, body { margin:0; height:100%; background:var(--bg); color:var(--fg);
               font:14px system-ui, "Segoe UI", "Malgun Gothic", -apple-system, "Apple SD Gothic Neo", sans-serif; }
  body { display:grid; grid-template-rows:auto 1fr; overflow:hidden; }
  button { font:inherit; color:inherit; background:var(--panel2); border:1px solid var(--line); border-radius:6px;
           padding:5px 10px; cursor:pointer; }
  button:hover { border-color:var(--gold); }
  button.primary { background:var(--gold); color:#1a1408; border-color:var(--gold); font-weight:600; }
  input, textarea, select { font:inherit; color:var(--fg); background:var(--bg); border:1px solid var(--line);
                            border-radius:6px; padding:7px 9px; }
  input:focus, textarea:focus, select:focus { outline:none; border-color:var(--gold); }
  img.px { image-rendering:pixelated; }

  header { display:flex; align-items:center; gap:14px; padding:8px 14px; border-bottom:1px solid var(--line); background:var(--panel); }
  header b { color:var(--gold); font-size:16px; letter-spacing:.02em; }
  .tabs { display:flex; gap:4px; }
  .tabs button { background:none; border-color:transparent; color:var(--muted); }
  .tabs button.on { color:var(--fg); border-color:var(--line); background:var(--panel2); }
  header .right { margin-left:auto; display:flex; align-items:center; gap:12px; color:var(--muted); font-size:13px; }
  #offline { display:none; background:#5a1f1c; color:#ffd9d6; padding:6px 14px; font-size:13px; }
  #offline.show { display:block; }

  main { display:grid; grid-template-columns:300px 1fr; min-height:0; }
  main.term { grid-template-columns:1fr; }
  main.term aside { display:none; }
  aside { border-right:1px solid var(--line); overflow-y:auto; background:var(--panel); }
  .row { display:grid; grid-template-columns:36px 1fr; gap:10px; padding:9px 12px; border-bottom:1px solid #2a2338; cursor:pointer; }
  .row:hover { background:var(--panel2); }
  .row.on { background:var(--me); }
  .row img, .ph { width:36px; height:36px; }
  .ph { display:grid; place-items:center; border:1px solid var(--line); border-radius:6px; color:var(--muted); font:12px var(--mono); }
  .row .n { display:flex; align-items:center; gap:6px; font-weight:600; min-width:0; }
  .row .n span { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .row .t, .row .s { color:var(--muted); font-size:12px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .dot { width:8px; height:8px; border-radius:50%; flex:none; background:#6e6787; }
  .dot.busy { background:var(--ok); }
  .dot.waiting { background:var(--warn); }
  .empty { color:var(--muted); padding:24px; text-align:center; }

  section.view { display:none; min-width:0; min-height:0; }
  section.view.on { display:grid; }
  #chatView { grid-template-rows:auto 1fr auto; }
  .chead { display:flex; align-items:center; gap:10px; padding:10px 16px; border-bottom:1px solid var(--line); min-width:0; }
  .chead img { width:40px; height:40px; }
  .chead .who { min-width:0; flex:1; }
  .chead .who div:first-child { font-weight:600; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .chead .who div:last-child { color:var(--muted); font-size:12px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .usage { color:var(--muted); font-size:12px; white-space:nowrap; }
  .menuBox { position:relative; }
  .menuBox .pop { display:none; position:absolute; right:0; top:110%; z-index:5; background:var(--panel2); border:1px solid var(--line);
                  border-radius:8px; padding:4px; min-width:180px; }
  .menuBox.open .pop { display:grid; }
  .pop button { border:0; text-align:left; background:none; }
  .pop button:hover { background:var(--me); }

  #log { overflow-y:auto; padding:16px 20px; display:flex; flex-direction:column; gap:10px; min-height:0; }
  .m { max-width:min(900px, 92%); line-height:1.55; white-space:pre-wrap; word-break:break-word; }
  .m.me { align-self:flex-end; background:var(--me); padding:8px 12px; border-radius:12px 12px 2px 12px; }
  .m.agent { align-self:flex-start; }
  .m.tool { align-self:flex-start; color:var(--muted); font:12px var(--mono); white-space:nowrap; overflow:hidden;
            text-overflow:ellipsis; max-width:100%; cursor:pointer; }
  .m.tool.open { white-space:pre-wrap; }
  .m.tool i { font-style:normal; color:var(--gold); margin-right:6px; }
  .m a { color:#79b8ff; }
  .m code { font:13px var(--mono); background:var(--panel2); padding:1px 4px; border-radius:4px; }
  .code { position:relative; background:#0d0b14; border:1px solid var(--line); border-radius:8px; margin:6px 0; }
  .code pre { margin:0; padding:10px 12px; overflow-x:auto; font:13px var(--mono); white-space:pre; }
  .code button { position:absolute; top:6px; right:6px; font-size:11px; padding:2px 8px; }
  .live { color:var(--muted); border-left:2px solid var(--ok); padding-left:10px; white-space:pre-wrap; }
  .card { border:1px solid var(--gold); border-radius:10px; padding:12px; display:grid; gap:8px; max-width:720px; background:var(--panel); }
  .card b { color:var(--gold); }
  .card pre { margin:0; white-space:pre-wrap; color:var(--muted); font:12px var(--mono); }
  .card button { text-align:left; }
  .card small { display:block; color:var(--muted); }
  .scr { font:12px var(--mono); white-space:pre; overflow-x:auto; background:#0d0b14; border:1px solid var(--line);
         border-radius:8px; padding:10px; margin:0; }

  .composer { border-top:1px solid var(--line); padding:10px 16px 12px; display:grid; gap:8px; }
  .composer textarea { width:100%; min-height:64px; max-height:40vh; resize:vertical; line-height:1.5; }
  .composer.drop textarea { border-color:var(--gold); }
  .bar2 { display:flex; gap:6px; align-items:center; flex-wrap:wrap; }
  .bar2 .keys button { font:12px var(--mono); padding:3px 8px; }
  .bar2 .grow { flex:1; }
  .pickHint { display:grid; place-items:center; color:var(--muted); }

  #termView { grid-template-columns:240px 1fr; }
  #termList { border-right:1px solid var(--line); overflow-y:auto; }
  #termList .tools { padding:10px 12px; border-bottom:1px solid var(--line); }
  #termPane { display:grid; grid-template-rows:auto 1fr; min-width:0; min-height:0; }
  #termPane .hint { color:var(--muted); font-size:12px; padding:8px 14px; border-bottom:1px solid var(--line); }
  #term { margin:0; padding:10px 14px; overflow:auto; font:13px/1.35 var(--mono); white-space:pre; background:#0d0b14; outline:none; }
  #term:focus-within, #term.focus { box-shadow:inset 0 0 0 1px var(--gold); }
  #term .cur { background:var(--fg); color:#0d0b14; }
  #termIn { position:fixed; left:-1000px; top:0; width:10px; height:10px; opacity:0; }

  #toast { position:fixed; right:16px; bottom:16px; background:#000d; border:1px solid var(--line); padding:9px 14px;
           border-radius:8px; display:none; max-width:420px; cursor:pointer; z-index:20; }
  .modal { position:fixed; inset:0; background:#000a; display:none; place-items:center; z-index:30; }
  .modal.show { display:grid; }
  .modal .box { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:20px; width:min(520px, 92vw);
                display:grid; gap:12px; }
  .modal h2 { margin:0; color:var(--gold); font-size:18px; }
  .modal p { margin:0; color:var(--muted); line-height:1.5; }
  .modal .btns { display:flex; justify-content:flex-end; gap:8px; }
  .modal label { display:grid; gap:4px; color:var(--muted); font-size:12px; }
  #pairErr { color:var(--warn); min-height:1.2em; }
</style></head><body>
<header>
  <b>수혁</b>
  <div class="tabs"><button id="tabChat" class="on"></button><button id="tabTerm"></button></div>
  <div class="right"><span id="crystals"></span><button id="newBtn"></button></div>
</header>
<div style="display:grid;grid-template-rows:auto 1fr;min-height:0">
<div id="offline"></div>
<main>
  <aside id="list"></aside>
  <section id="chatView" class="view on">
    <div class="chead" id="chead" style="display:none">
      <img class="px" id="hImg" alt="">
      <div class="who"><div id="hName"></div><div id="hSub"></div></div>
      <span class="usage" id="usage"></span>
      <button id="screenBtn"></button>
      <div class="menuBox" id="manage"><button id="manageBtn"></button><div class="pop" id="managePop"></div></div>
    </div>
    <div id="log"><div class="pickHint" id="pickHint" style="flex:1"></div></div>
    <div class="composer" id="composer" style="display:none">
      <textarea id="msg"></textarea>
      <div class="bar2">
        <span class="keys">
          <button data-k="Escape">Esc</button><button data-k="Up">↑</button><button data-k="Down">↓</button>
          <button data-k="Enter">⏎</button><button data-k="Tab">Tab</button>
          <button data-k="1">1</button><button data-k="2">2</button><button data-k="3">3</button>
        </span>
        <span class="grow"></span>
        <input type="file" id="file" multiple hidden>
        <button id="attachBtn"></button>
        <button id="sendBtn" class="primary"></button>
      </div>
    </div>
  </section>
  <section id="termView" class="view">
    <div id="termList"></div>
    <div id="termPane"><div class="hint" id="termHint"></div><pre id="term" tabindex="0"></pre></div>
  </section>
</main>
</div>
<textarea id="termIn" autocomplete="off" autocapitalize="off" spellcheck="false"></textarea>
<div id="toast"></div>

<div class="modal" id="pair"><div class="box">
  <h2 id="pairTitle"></h2>
  <p id="pairMsg"></p>
  <input id="pairLink" placeholder="https://…/desk#pair=…">
  <div id="pairErr"></div>
  <div class="btns"><button class="primary" id="pairBtn"></button></div>
</div></div>

<div class="modal" id="ask"><div class="box">
  <h2 id="askTitle"></h2>
  <div id="askBody" style="display:grid;gap:10px"></div>
  <div class="btns"><button id="askNo"></button><button class="primary" id="askYes"></button></div>
</div></div>

<script>
const T = \#(strings);
const $ = id => document.getElementById(id);
const esc = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
// A character's sprite, or a plain box for a terminal without one.
const face = (c, cls = "") => c ? '<img class="px ' + cls + '" src="/art/frames/' + encodeURIComponent(c) + '/walk_down_2.png" alt="">' : '<div class="ph ' + cls + '">&gt;_</div>';

$("tabChat").textContent = T.chat; $("tabTerm").textContent = T.terminal; $("newBtn").textContent = "+ " + T.newSession;
$("offline").textContent = T.offline; $("pickHint").textContent = T.pick; $("screenBtn").textContent = T.screen;
$("manageBtn").textContent = T.manage; $("attachBtn").textContent = T.attach; $("sendBtn").textContent = T.send;
$("termHint").textContent = T.termHelp; $("pairTitle").textContent = T.pairTitle; $("pairBtn").textContent = T.pairButton;
$("askNo").textContent = T.cancel;

let agents = [], selected = null, tab = "chat", offline = false;

// MARK: network
async function api(path, body) {
  let r;
  try {
    r = await fetch(path, body ? { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body), credentials: "same-origin" }
                               : { credentials: "same-origin", cache: "no-store" });
  } catch (e) { setOffline(true); throw e; }
  if (r.status === 401) { setOffline(false); showPair(); throw new Error("pair"); }
  // The tunnel answers with its own HTML error page when the Mac is off: not JSON.
  const j = await r.json().catch(() => null);
  if (j === null) { setOffline(true); throw new Error("offline"); }
  setOffline(false);
  return j;
}
function setOffline(v) { if (v !== offline) { offline = v; $("offline").classList.toggle("show", v); } }
function toast(s, onclick) {
  const t = $("toast"); t.textContent = s; t.style.display = "block"; t.onclick = () => { t.style.display = "none"; if (onclick) onclick(); };
  clearTimeout(t._h); t._h = setTimeout(() => t.style.display = "none", onclick ? 6000 : 2200);
}

// MARK: dialogs (no window.prompt/confirm: the Windows app's webview may not show them)
function ask(title, opts = {}) {
  return new Promise(done => {
    $("askTitle").textContent = title;
    const body = $("askBody"); body.innerHTML = "";
    let input = null;
    if (opts.text) { const p = document.createElement("p"); p.textContent = opts.text; body.appendChild(p); }
    if (opts.input !== undefined) {
      input = document.createElement("input"); input.value = opts.input; body.appendChild(input);
      input.onkeydown = e => { if (e.key === "Enter" && !e.isComposing) finish(true); };
    }
    $("askYes").textContent = opts.yes || T.ok;
    const finish = ok => { $("ask").classList.remove("show"); done(ok ? (input ? input.value : true) : null); };
    $("askYes").onclick = () => finish(true); $("askNo").onclick = () => finish(false);
    $("ask").classList.add("show");
    if (input) setTimeout(() => input.focus(), 0);
  });
}

// MARK: pairing — the link from the Mac ("PC용 링크 복사") carries a one-time secret after #pair=
function showPair() {
  if ($("pair").classList.contains("show")) return;
  $("pairMsg").textContent = T.pairHelp; $("pairErr").textContent = ""; $("pairLink").value = "";
  $("pair").classList.add("show"); setTimeout(() => $("pairLink").focus(), 0);
}
async function pair(secret) {
  $("pair").classList.add("show"); $("pairErr").textContent = ""; $("pairMsg").textContent = T.pairSending;
  const r = await fetch("/pair", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ secret }), credentials: "same-origin" }).catch(() => null);
  const j = r ? await r.json().catch(() => ({})) : {};
  if (!r || !r.ok) { $("pairMsg").textContent = T.pairHelp; $("pairErr").textContent = j.error || T.pairFail; return; }
  $("pairMsg").textContent = T.pairAllow;
  for (;;) {
    await new Promise(res => setTimeout(res, 1500));
    const s = await fetch("/pair/status?id=" + encodeURIComponent(j.pending), { credentials: "same-origin" }).catch(() => null);
    const k = s ? await s.json().catch(() => ({})) : {};
    if (s && s.ok && k.ok) { $("pair").classList.remove("show"); refresh(); return; }
    if (!s || !s.ok) { $("pairMsg").textContent = T.pairHelp; $("pairErr").textContent = k.error || T.pairFail; return; }
  }
}
$("pairBtn").onclick = () => {
  const m = $("pairLink").value.match(/(?:#pair=)?([0-9a-f]{32})/);
  if (!m) { $("pairErr").textContent = T.pairBad; return; }
  pair(m[1]);
};
$("pairLink").onkeydown = e => { if (e.key === "Enter") $("pairBtn").click(); };

// MARK: session list
const rank = a => a.status === "waiting" ? 0 : a.status === "busy" ? 1 : 2;
async function refresh() {
  try {
    const s = await api("/api/state");
    $("pair").classList.remove("show");
    agents = (s.agents || []).slice().sort((a, b) => rank(a) - rank(b) || (b.last || 0) - (a.last || 0));
    $("crystals").textContent = T.crystals + " " + (s.crystals || 0);
    renderList();
    if (selected && !agents.some(a => a.id === selected)) select(null);
    else if (selected) header();
    const want = decodeURIComponent(location.hash.slice(3));
    if (!selected && location.hash.startsWith("#a-") && agents.some(a => a.id === want)) select(want);
  } catch (e) {}
}
function renderList() {
  const list = $("list");
  if (!agents.length) { list.innerHTML = '<div class="empty">' + esc(T.noAgents) + "</div>"; return; }
  list.innerHTML = agents.map(a =>
    '<div class="row' + (a.id === selected ? " on" : "") + '" data-id="' + esc(a.id) + '">' +
      face(a.character) +
      '<div style="min-width:0"><div class="n"><i class="dot ' + esc(a.status) + '"></i><span>' + esc(a.name) + "</span></div>" +
      '<div class="t">' + esc(a.title || "") + "</div>" +
      '<div class="s">' + esc((a.project || "") + " · " + statusText(a)) + "</div></div></div>").join("");
  list.querySelectorAll(".row").forEach(r => r.onclick = () => { setTab("chat"); select(r.dataset.id); });
}
const statusText = a => a.status === "busy" ? T.working : a.status === "waiting" ? T.waiting : (a.activity || "");

// MARK: chat
let chatTimer = null, lastChat = "", showScreen = false;
function select(id) {
  selected = id; lastChat = ""; clearTimeout(chatTimer);
  history.replaceState(null, "", id ? "#a-" + encodeURIComponent(id) : location.pathname);
  $("chead").style.display = id ? "" : "none"; $("composer").style.display = id ? "" : "none";
  $("log").innerHTML = id ? "" : '<div class="pickHint" style="flex:1">' + esc(T.pick) + "</div>";
  delete $("log").dataset.seen;
  renderList();
  if (id) { header(); loadChat(); $("msg").focus(); }
}
function header() {
  const a = agents.find(a => a.id === selected); if (!a) return;
  $("hImg").src = "/art/frames/" + encodeURIComponent(a.character) + "/walk_down_2.png"; $("hImg").style.visibility = a.character ? "" : "hidden";
  $("hName").textContent = a.name + " · " + (a.title || "");
  $("hSub").textContent = [statusText(a), a.action, a.cwd].filter(Boolean).join(" · ");
  $("msg").disabled = !a.canSend;
  $("msg").placeholder = a.canSend ? T.sendTo.replace("{name}", a.name) : T.cannotSend;
}
async function loadChat() {
  clearTimeout(chatTimer); if (!selected) return;
  const id = selected;
  try {
    const c = await api("/api/chat?id=" + encodeURIComponent(id) + (showScreen ? "&screen=1" : ""));
    if (id !== selected) return;
    const key = JSON.stringify(c);
    if (key !== lastChat) { lastChat = key; renderChat(c); }
  } catch (e) {}
  if (id === selected) chatTimer = setTimeout(loadChat, document.hidden ? 4000 : 1200);
}
function renderChat(c) {
  const log = $("log"), stick = log.scrollTop + log.clientHeight > log.scrollHeight - 60;
  const open = new Set([...log.querySelectorAll(".m.tool.open")].map(d => d.dataset.i));
  log.innerHTML = "";
  (c.items || []).forEach((it, i) => {
    const d = document.createElement("div"); d.className = "m " + it.role; d.dataset.i = i;
    if (it.role === "tool") {
      d.innerHTML = "<i>" + esc(T.tool) + "</i>" + esc(it.text);
      if (open.has(String(i))) d.classList.add("open");
      d.onclick = () => d.classList.toggle("open");
    } else d.innerHTML = rich(it.text, it.files);
    log.appendChild(d);
  });
  if (c.live) { const d = document.createElement("div"); d.className = "live"; d.textContent = c.live; log.appendChild(d); }
  if (c.menu) {
    const m = document.createElement("div"); m.className = "card";
    m.innerHTML = "<b>" + esc(c.menuQuestion || T.choose) + "</b>" + (c.menuContext ? "<pre>" + esc(c.menuContext) + "</pre>" : "");
    c.menu.forEach((o, i) => {
      const b = document.createElement("button");
      b.innerHTML = (i + 1) + ". " + esc(o.label) + (o.detail ? "<small>" + esc(o.detail) + "</small>" : "");
      b.onclick = async () => {
        if (!o.free) return choose(i);
        const t = ((await ask(T.typeAnswer, { input: "" })) || "").trim();
        if (t) choose(i, t);
      };
      m.appendChild(b);
    });
    log.appendChild(m);
  }
  if (c.screen) { const p = document.createElement("pre"); p.className = "scr"; p.textContent = c.screen; log.appendChild(p); }
  wireCode(log);
  $("usage").textContent = usageText(c.usage);
  if (stick || !log.dataset.seen) log.scrollTop = log.scrollHeight;
  log.dataset.seen = 1;
}
function usageText(u) {
  if (!u) return "";
  const parts = [u.model, u.effort].filter(Boolean);
  if (u.contextPercent != null) parts.push(T.context + " " + Math.round(u.contextPercent) + "%");
  for (const l of u.limits || []) parts.push(l.label + " " + Math.round(l.percent) + "%");
  return parts.join(" · ");
}
// Message text as HTML: ``` blocks, `code`, **bold**, links (http(s) only) and paths that exist on the Mac
// (`files`: token → path, opened through /api/file). Everything else is escaped, so a reply cannot inject markup.
function rich(text, files) {
  return String(text).split(/```[^\n]*\n?([\s\S]*?)(?:```|$)/).map((part, i) =>
    i % 2 ? '<div class="code"><button>' + esc(T.copy) + "</button><pre>" + esc(part.replace(/\n$/, "")) + "</pre></div>"
          : inline(part, files || {})).join("");
}
function inline(text, files) {
  const keys = Object.keys(files).sort((a, b) => b.length - a.length).map(k => k.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  const re = new RegExp("\\[([^\\]\\n]+)\\]\\((https?://[^\\s)]+)\\)|`([^`\\n]+)`|\\*\\*([^*\\n]+)\\*\\*|https?://[^\\s<>\"'`)\\]]+" +
                        (keys.length ? "|" + keys.join("|") : ""), "g");
  const fileLink = (token, label) => '<a href="/api/file?path=' + encodeURIComponent(files[token]) + '" target="_blank">' + label + "</a>";
  let out = "", last = 0, m;
  while ((m = re.exec(text))) {
    out += esc(text.slice(last, m.index));
    if (m[2]) out += '<a href="' + esc(m[2]) + '" target="_blank" rel="noopener noreferrer">' + esc(m[1]) + "</a>";
    else if (m[3] !== undefined) out += files[m[3]] ? fileLink(m[3], "<code>" + esc(m[3]) + "</code>") : "<code>" + esc(m[3]) + "</code>";
    else if (m[4] !== undefined) out += "<b>" + esc(m[4]) + "</b>";
    else if (files[m[0]]) out += fileLink(m[0], esc(m[0]));
    else {
      let url = m[0], tail = (url.match(/[.,;:!?]+$/) || [""])[0];
      if (tail) url = url.slice(0, -tail.length);
      out += '<a href="' + esc(url) + '" target="_blank" rel="noopener noreferrer">' + esc(url) + "</a>" + esc(tail);
    }
    last = m.index + m[0].length;
  }
  return out + esc(text.slice(last));
}
function wireCode(root) {
  root.querySelectorAll(".code button").forEach(b => b.onclick = e => {
    e.stopPropagation();
    navigator.clipboard.writeText(b.nextElementSibling.textContent).then(() => toast(T.copied), () => {});
  });
}
async function send() {
  const text = $("msg").value.trim(); if (!text || !selected) return;
  $("msg").value = "";
  const r = await api("/api/send", { id: selected, text }).catch(() => ({}));
  if (!r.ok) $("msg").value = text;
  toast(r.ok ? T.sent : T.sendFail);
  loadChat();
}
async function choose(i, text) {
  const r = await api("/api/choose", text ? { id: selected, index: i, text } : { id: selected, index: i }).catch(() => ({}));
  toast(r.ok ? (text ? T.typed : T.chosen) : T.chooseFail); loadChat();
}
$("sendBtn").onclick = send;
$("msg").onkeydown = e => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); send(); } };
document.querySelectorAll(".keys button").forEach(b => b.onclick = () => selected && api("/api/key", { id: selected, key: b.dataset.k }).then(loadChat, () => {}));
$("screenBtn").onclick = () => { showScreen = !showScreen; $("screenBtn").classList.toggle("primary", showScreen); lastChat = ""; loadChat(); };

// Files: chosen, dropped or pasted; each goes to the Mac (POST /api/upload) and its path joins the message.
async function upload(files) {
  for (const f of files) {
    if (f.size > 25 * 1024 * 1024) { toast(T.tooBig); continue; }
    toast(T.uploading);
    const r = await fetch("/api/upload?name=" + encodeURIComponent(f.name || "paste.png"), { method: "POST", headers: { "Content-Type": "application/octet-stream" }, body: f, credentials: "same-origin" }).catch(() => null);
    const j = r && r.ok ? await r.json().catch(() => ({})) : {};
    if (!j.path) { toast(T.uploadFail); continue; }
    const v = $("msg").value; $("msg").value = v + (v && !/\s$/.test(v) ? " " : "") + j.path + " ";
  }
  $("msg").focus();
}
$("attachBtn").onclick = () => $("file").click();
$("file").onchange = () => { upload([...$("file").files]); $("file").value = ""; };
const comp = $("composer");
comp.ondragover = e => { e.preventDefault(); comp.classList.add("drop"); };
comp.ondragleave = () => comp.classList.remove("drop");
comp.ondrop = e => { e.preventDefault(); comp.classList.remove("drop"); upload([...e.dataTransfer.files]); };
$("msg").onpaste = e => { const f = [...(e.clipboardData?.files || [])]; if (f.length) { e.preventDefault(); upload(f); } };

// Manage menu: the Mac's right-click menu (POST /api/action).
$("manageBtn").onclick = e => {
  e.stopPropagation();
  const a = agents.find(a => a.id === selected); if (!a) return;
  const items = [["rename", T.rename]];
  if (a.canClone && a.canFork) items.push(["clone", T.clone]);
  if (a.agent === "Claude") items.push(["clear", T.clear]);
  items.push(["end", T.end]);
  $("managePop").innerHTML = items.map(([k, l]) => '<button data-a="' + k + '">' + esc(l) + "</button>").join("");
  $("managePop").querySelectorAll("button").forEach(b => b.onclick = () => { $("manage").classList.remove("open"); act(a, b.dataset.a); });
  $("manage").classList.toggle("open");
};
document.addEventListener("click", () => $("manage").classList.remove("open"));
async function act(a, action) {
  const body = { id: a.id, action };
  if (action === "rename") {
    const t = await ask(T.rename, { input: a.title || "" }); if (t === null) return; body.text = t;
  } else if (action === "clear" || action === "end") {
    if (!(await ask(action === "end" ? T.end : T.clear, { text: action === "end" ? T.endConfirm : T.clearConfirm, yes: action === "end" ? T.end : T.ok }))) return;
  }
  const r = await api("/api/action", body).catch(() => ({}));
  toast(r.message || (r.ok ? T.ok : T.failed)); refresh();
}

// MARK: new session
$("newBtn").onclick = async () => {
  const f = await api("/api/folders").catch(() => null); if (!f) return;
  const body = $("askBody");
  const pending = ask(T.newSession, { yes: T.start });
  body.innerHTML =
    "<label>" + esc(T.agent) + '<select id="nAgent"><option>Claude</option><option>Codex</option><option>Antigravity</option></select></label>' +
    "<label>" + esc(T.folder) + '<input id="nCwd" list="nFolders"><datalist id="nFolders">' +
      (f.folders || []).map(d => '<option value="' + esc(d) + '">').join("") + "</datalist></label>" +
    "<label>" + esc(T.prompt) + '<textarea id="nPrompt" rows="3"></textarea></label>';
  $("nCwd").value = (f.folders || [])[0] || f.home || "";
  if (!(await pending)) return;
  const r = await api("/api/new", { agent: $("nAgent").value, cwd: $("nCwd").value.trim(), prompt: $("nPrompt").value }).catch(() => ({}));
  toast(r.ok ? T.started : (r.message || T.failed)); setTimeout(refresh, 1500);
};

// MARK: terminal tab — 수혁's tmux sessions as screens with colors; keys typed here go to the selected one.
let terms = [], term = null, termTimer = null, termList = 0, lastTerm = "";
function setTab(t) {
  tab = t;
  $("tabChat").classList.toggle("on", t === "chat"); $("tabTerm").classList.toggle("on", t === "term");
  $("chatView").classList.toggle("on", t === "chat"); $("termView").classList.toggle("on", t === "term");
  document.querySelector("main").classList.toggle("term", t === "term");
  clearTimeout(termTimer);
  if (t === "term") { loadTerms(); loadTerm(); }
}
$("tabChat").onclick = () => setTab("chat"); $("tabTerm").onclick = () => setTab("term");
async function loadTerms() {
  try { terms = (await api("/api/terminals")).terminals || []; } catch (e) { return; }
  const el = $("termList");
  el.innerHTML = '<div class="tools"><button id="shellBtn">+ ' + esc(T.newShell) + "</button></div>" +
    (terms.length ? terms.map(t =>
      '<div class="row' + (t.name === term ? " on" : "") + '" data-n="' + esc(t.name) + '">' + face(t.character) +
      '<div style="min-width:0"><div class="n"><span>' + esc(t.title || t.name) + '</span></div><div class="t">' + esc(t.kind) + '</div><div class="s">' + esc(t.cwd || "") + "</div></div></div>").join("")
     : '<div class="empty">' + esc(T.noTerminals) + "</div>");
  el.querySelectorAll(".row").forEach(r => r.onclick = () => { term = r.dataset.n; lastTerm = ""; loadTerms(); loadTerm(); focusTerm(); });
  $("shellBtn").onclick = async () => {
    const r = await api("/api/term-new", {}).catch(() => ({}));
    if (r.ok) { term = r.name; lastTerm = ""; loadTerms(); loadTerm(); focusTerm(); } else toast(T.failed);
  };
  if (!term && terms.length) { term = terms[terms.length - 1].name; loadTerms(); }
}
async function loadTerm() {
  clearTimeout(termTimer); if (tab !== "term") return;
  if (++termList % 8 === 0) loadTerms();
  if (term) {
    try {
      const s = await api("/api/term?name=" + encodeURIComponent(term) + "&history=300");
      if (s.error) { $("term").textContent = T.termGone; term = null; lastTerm = ""; loadTerms(); }
      else {
        const key = JSON.stringify(s);
        if (key !== lastTerm) { lastTerm = key; renderTerm(s); }
      }
    } catch (e) {}
  }
  termTimer = setTimeout(loadTerm, document.hidden ? 3000 : 600);
}
function renderTerm(s) {
  const el = $("term"), stick = el.scrollTop + el.clientHeight > el.scrollHeight - 30;
  const curLine = Math.max(0, s.lines.length - s.height) + s.cy;
  // Blank rows under the cursor would push the prompt out of a viewport shorter than the pane: stop at the last
  // row with text or the cursor, whichever is lower.
  let end = s.lines.length;
  while (end - 1 > curLine && !s.lines[end - 1].replace(/\x1b\[[0-9;:]*m/g, "").trim()) end--;
  el.innerHTML = s.lines.slice(0, end).map((l, i) => ansi(l, i === curLine ? s.cx : -1)).join("\n");
  if (stick) el.scrollTop = el.scrollHeight;
}
// tmux capture-pane -e: SGR color codes only; other escapes are dropped.
const PAL = ["#1b1726","#e5534b","#4cc38a","#e0b44a","#539bf5","#c678dd","#4dd0e1","#d7d0e3",
             "#6e6787","#ff7b72","#7ee2a8","#f0c674","#79b8ff","#d2a8ff","#76e3ea","#ffffff"];
function c256(n) {
  if (n < 16) return PAL[n];
  if (n >= 232) { const v = 8 + (n - 232) * 10; return "rgb(" + v + "," + v + "," + v + ")"; }
  n -= 16; const s = [0, 95, 135, 175, 215, 255];
  return "rgb(" + s[Math.floor(n / 36)] + "," + s[Math.floor(n / 6) % 6] + "," + s[n % 6] + ")";
}
const wide = ch => /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]/.test(ch) || ch.codePointAt(0) > 0xffff;
function ansi(line, cur) {
  line = line.replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "").replace(/\x1b\[[0-9;?]*[A-Za-ln-z]/g, "");
  const parts = line.split(/\x1b\[([0-9;:]*)m/);
  let st = {}, out = "", col = 0;
  for (let p = 0; p < parts.length; p++) {
    if (p % 2) { st = sgr(st, parts[p]); continue; }
    if (!parts[p]) continue;
    let fg = st.fg, bg = st.bg; if (st.inv) { [fg, bg] = [bg || "#0d0b14", fg || "#ece6f5"]; }
    const css = (fg ? "color:" + fg + ";" : "") + (bg ? "background:" + bg + ";" : "") + (st.b ? "font-weight:700;" : "") +
                (st.dim ? "opacity:.6;" : "") + (st.it ? "font-style:italic;" : "") + (st.u ? "text-decoration:underline;" : "");
    let chunk = "";
    for (const ch of parts[p]) {
      chunk += col === cur ? '<span class="cur">' + esc(ch) + "</span>" : esc(ch);
      col += wide(ch) ? 2 : 1;
    }
    out += css ? '<span style="' + css + '">' + chunk + "</span>" : chunk;
  }
  if (cur >= col) out += " ".repeat(cur - col) + '<span class="cur"> </span>';
  return out;
}
function sgr(st, codes) {
  st = Object.assign({}, st);
  const c = codes === "" ? [0] : codes.split(/[;:]/).map(Number);
  for (let i = 0; i < c.length; i++) {
    const n = c[i];
    if (n === 0) st = {};
    else if (n === 1) st.b = true; else if (n === 2) st.dim = true; else if (n === 3) st.it = true;
    else if (n === 4) st.u = true; else if (n === 7) st.inv = true;
    else if (n === 22) { st.b = false; st.dim = false; } else if (n === 23) st.it = false;
    else if (n === 24) st.u = false; else if (n === 27) st.inv = false;
    else if (n >= 30 && n <= 37) st.fg = PAL[n - 30]; else if (n >= 90 && n <= 97) st.fg = PAL[n - 82];
    else if (n >= 40 && n <= 47) st.bg = PAL[n - 40]; else if (n >= 100 && n <= 107) st.bg = PAL[n - 92];
    else if (n === 39) delete st.fg; else if (n === 49) delete st.bg;
    else if (n === 38 || n === 48) {
      let v = null;
      if (c[i + 1] === 5) { v = c256(c[i + 2]); i += 2; }
      else if (c[i + 1] === 2) { v = "rgb(" + c[i + 2] + "," + c[i + 3] + "," + c[i + 4] + ")"; i += 4; }
      if (v) st[n === 38 ? "fg" : "bg"] = v;
    }
  }
  return st;
}
// Typing: a hidden textarea takes the keys so Korean IME composition works; text is sent in small batches, keys in order.
const tin = $("termIn"); let typed = "", typeTimer = null, chain = Promise.resolve();
function focusTerm() { if (!getSelection().toString()) { tin.focus(); $("term").classList.add("focus"); } }
$("term").onmouseup = focusTerm;
tin.onblur = () => $("term").classList.remove("focus");
function queue(fn) { chain = chain.then(fn, fn); }
function flushTyped() {
  clearTimeout(typeTimer);
  if (!typed || !term) { typed = ""; return; }
  const text = typed, name = term; typed = "";
  queue(() => api("/api/term-input", { name, text }).catch(() => {}));
}
function type(text) { typed += text; clearTimeout(typeTimer); typeTimer = setTimeout(() => { flushTyped(); setTimeout(loadTerm, 80); }, 25); }
function key(k) { flushTyped(); const name = term; if (!name) return; queue(() => api("/api/term-input", { name, key: k }).catch(() => {})); setTimeout(loadTerm, 120); }
const KEYS = { Enter: "Enter", Tab: "Tab", Backspace: "BSpace", Delete: "DC", Escape: "Escape", ArrowUp: "Up", ArrowDown: "Down",
               ArrowLeft: "Left", ArrowRight: "Right", Home: "Home", End: "End", PageUp: "PageUp", PageDown: "PageDown" };
tin.onkeydown = e => {
  if (e.isComposing || e.keyCode === 229) return;
  if (e.key === "Tab" && e.shiftKey) { e.preventDefault(); return key("BTab"); }
  if (KEYS[e.key]) { e.preventDefault(); return key(KEYS[e.key]); }
  if (e.ctrlKey && !e.altKey && !e.metaKey && /^[a-z]$/i.test(e.key) && e.key.toLowerCase() !== "v") { e.preventDefault(); return key("C-" + e.key.toLowerCase()); }
};
tin.addEventListener("input", e => {
  if (e.isComposing || e.inputType === "insertCompositionText") return;
  if (e.data) type(e.data);
  tin.value = "";
});
tin.addEventListener("compositionend", e => { if (e.data) type(e.data); tin.value = ""; });
tin.addEventListener("paste", e => { e.preventDefault(); const t = e.clipboardData.getData("text"); if (t) type(t); });

// MARK: events — "asking" and "done" from the Mac's Notifier, as a toast (and a system notification when hidden).
let boot = null, seq = 0, unread = 0;
async function events() {
  try {
    const e = await api("/api/events?boot=" + encodeURIComponent(boot || "") + "&after=" + seq);
    if (boot === e.boot) for (const ev of e.events) {
      const line = ev.name + ": " + (ev.text || ev.title || "");
      toast(line, () => { setTab("chat"); select(ev.id); });
      if (document.hidden) {
        unread++; document.title = "(" + unread + ") " + T.app;
        try { if (window.Notification && Notification.permission === "granted") new Notification(T.app, { body: line }); } catch (x) {}
      }
    }
    boot = e.boot; seq = e.seq;
  } catch (x) {}
  setTimeout(events, 3000);
}
document.addEventListener("visibilitychange", () => { if (!document.hidden) { unread = 0; document.title = T.app; } });
document.addEventListener("click", () => { try { if (window.Notification && Notification.permission === "default") Notification.requestPermission(); } catch (x) {} }, { once: true });

// MARK: start — a link opened with #pair=<secret> pairs first.
function loop() { refresh().finally(() => setTimeout(loop, document.hidden ? 5000 : 2000)); }
const m = location.hash.match(/^#pair=([0-9a-f]{32})$/);
if (m) { history.replaceState(null, "", location.pathname); pair(m[1]).finally(() => { loop(); events(); }); }
else { loop(); events(); }
</script>
</body></html>
"""#
    }
}
