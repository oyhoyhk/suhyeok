// Operator review page for the character market (U5), served by worker.js at /ledger/admin/.
// Kept as a JS module so wrangler bundles it with no module rules or build step, and node tests can import it.
// String.raw keeps the page's backslashes literal; the page must never contain a dollar-brace sequence.
// Rules for the page script: listing text goes into the DOM only through textContent (no innerHTML and friends),
// images are fetched with the Authorization header and shown as blob: URLs, and the token lives only in
// sessionStorage. worker.js replaces __CSP_NONCE__ with a per-response nonce.
export const ADMIN_HTML = String.raw`<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>마켓 심사</title>
<style>
:root {
  --bg: #f4f2ee; --card: #ffffff; --line: #ddd8cf; --fg: #23211d; --muted: #6f6a61;
  --acc: #2f6f6a; --ok: #2e7d32; --bad: #b3261e; --stage: #e9e5dc;
}
@media (prefers-color-scheme: dark) {
  :root { --bg: #16181a; --card: #1f2225; --line: #33383d; --fg: #e8e6e1; --muted: #9a968e;
    --acc: #6cc0b8; --ok: #7bc47f; --bad: #f2867d; --stage: #2a2e32; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg);
  font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Malgun Gothic", sans-serif; }
header { position: sticky; top: 0; z-index: 1; background: var(--bg); border-bottom: 1px solid var(--line);
  padding: 12px 16px; display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: center; }
h1 { font-size: 16px; margin: 0; }
nav { display: flex; gap: 4px; }
.spacer { flex: 1; }
button { font: inherit; border: 1px solid var(--line); background: var(--card); color: var(--fg);
  border-radius: 6px; padding: 6px 12px; cursor: pointer; }
button:disabled { opacity: .45; cursor: not-allowed; }
button.tab[aria-selected="true"] { background: var(--acc); border-color: var(--acc); color: var(--bg); }
button.approve { border-color: var(--ok); color: var(--ok); }
button.danger { border-color: var(--bad); color: var(--bad); }
main { padding: 16px; max-width: 1200px; margin: 0 auto; }
#lock { max-width: 360px; margin: 15vh auto; display: flex; flex-direction: column; gap: 10px; }
#lock p { margin: 0; color: var(--muted); }
input, textarea, select { font: inherit; color: var(--fg); background: var(--card); border: 1px solid var(--line);
  border-radius: 6px; padding: 6px 8px; width: 100%; }
textarea { resize: vertical; min-height: 56px; }
.status { color: var(--muted); margin: 0 0 12px; }
.status.err, .msg.err { color: var(--bad); }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); gap: 16px; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 14px;
  display: flex; flex-direction: column; gap: 10px; min-width: 0; }
.card.done { opacity: .6; }
.media { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px; }
.media figure { margin: 0; display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.media figcaption { font-size: 12px; color: var(--muted); }
.stage { background: var(--stage); border-radius: 6px; aspect-ratio: 1; display: flex; align-items: center;
  justify-content: center; overflow: hidden; }
.stage img { max-width: 100%; max-height: 100%; object-fit: contain; }
.stage.pixel img { image-rendering: pixelated; width: 100%; height: 100%; }
.stage .ph { font-size: 12px; color: var(--muted); padding: 4px; text-align: center; }
.name { font-size: 16px; font-weight: 600; margin: 0; overflow-wrap: anywhere; }
.desc { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; }
.desc.empty { color: var(--muted); }
dl { margin: 0; display: grid; grid-template-columns: auto 1fr; gap: 2px 12px; font-size: 13px; }
dt { color: var(--muted); }
dd { margin: 0; overflow-wrap: anywhere; }
.actions { display: flex; flex-direction: column; gap: 8px; border-top: 1px solid var(--line); padding-top: 10px; }
.row { display: flex; gap: 8px; flex-wrap: wrap; }
.msg { margin: 0; font-size: 13px; overflow-wrap: anywhere; }
.msg.ok { color: var(--ok); }
.hidden { display: none !important; }
@media (max-width: 420px) { .grid { grid-template-columns: 1fr; } }
</style>
</head>
<body>
<header id="bar" class="hidden">
  <h1>마켓 심사</h1>
  <nav role="tablist">
    <button class="tab" role="tab" data-tab="pending" aria-selected="true">심사 대기 <span id="count-pending"></span></button>
    <button class="tab" role="tab" data-tab="approved" aria-selected="false">판매 중 <span id="count-approved"></span></button>
  </nav>
  <span class="spacer"></span>
  <button id="refresh">새로 고침</button>
  <button id="logout">잠그기</button>
</header>
<main>
  <section id="lock" class="hidden">
    <h1>마켓 심사</h1>
    <p>관리자 토큰을 입력. 토큰은 이 탭의 sessionStorage에만 저장되고, 탭을 닫으면 사라짐</p>
    <input id="token" type="password" autocomplete="off" spellcheck="false" placeholder="관리자 토큰">
    <button id="unlock">열기</button>
    <p id="lock-msg" class="msg err"></p>
  </section>
  <section id="view" class="hidden">
    <p id="status" class="status"></p>
    <div id="list" class="grid"></div>
  </section>
</main>
<script nonce="__CSP_NONCE__">
(function () {
  'use strict';
  var API = '/ledger/v1';
  var KEY = 'suhyeok.market.adminToken';
  var REQUIRED = ['walk_down', 'walk_left', 'walk_up', 'attack'];
  var OPTIONAL = ['hammer', 'read', 'type', 'smith', 'study', 'write'];
  var MOTION_LABEL = { walk_down: '걷기 (아래)', walk_left: '걷기 (왼쪽)', walk_up: '걷기 (위)', attack: '공격',
    hammer: '망치질', read: '읽기', type: '타자', smith: '대장일', study: '공부', write: '쓰기' };
  var STATUS_LABEL = { draft: '초안', pending: '심사 대기', approved: '판매 중', rejected: '거절됨',
    delisted: '판매 중지', withdrawn: '철회됨' };
  var DONE_LABEL = { approve: '승인함', reject: '거절함', delist: '판매 중지함' };
  var FPS = 8;

  var $ = function (id) { return document.getElementById(id); };
  var state = { tab: 'pending', gen: 0, urls: [], players: [] };

  function getToken() { try { return sessionStorage.getItem(KEY) || ''; } catch (e) { return ''; } }
  function setToken(t) {
    try { if (t) sessionStorage.setItem(KEY, t); else sessionStorage.removeItem(KEY); } catch (e) { /* storage blocked */ }
  }

  /** Builds an element. Text is only ever assigned through textContent. */
  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = String(text);
    return n;
  }

  function ApiError(status, data) {
    this.status = status;
    this.code = (data && typeof data.error === 'string') ? data.error : 'http_' + status;
    this.data = data || {};
  }

  function describe(err) {
    if (!(err instanceof ApiError)) return '서버에 연결하지 못함';
    if (err.code === 'reason_required') return '사유를 입력해야 함';
    if (err.code === 'bad_state') {
      var s = err.data.status;
      return '이미 처리된 항목 (현재 상태: ' + (STATUS_LABEL[s] || String(s)) + ')';
    }
    if (err.code === 'not_found') return '항목을 찾을 수 없음';
    if (err.code === 'market_unavailable') return '마켓 저장소가 연결되지 않음 (503)';
    if (err.code === 'unauthorized') return '토큰이 맞지 않음';
    return '오류: ' + err.code + ' (' + err.status + ')';
  }

  function headers(json) {
    var h = { authorization: 'Bearer ' + getToken() };
    if (json) h['content-type'] = 'application/json';
    return h;
  }

  /** Same-origin API call with the bearer token. A 401 locks the page. */
  async function api(method, path, body) {
    var res = await fetch(API + path, {
      method: method, headers: headers(body !== undefined), cache: 'no-store', credentials: 'omit',
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    var data = null;
    try { data = await res.json(); } catch (e) { data = null; }
    if (res.status === 401) { lock('토큰이 맞지 않음'); throw new ApiError(401, data); }
    if (!res.ok) throw new ApiError(res.status, data);
    return data;
  }

  /** Fetches an image with the token and returns an object URL owned by the current view generation. */
  async function imageUrl(path) {
    var gen = state.gen;
    if (typeof path !== 'string' || path.indexOf(API + '/') !== 0) throw new ApiError(0, { error: 'bad_url' });
    var res = await fetch(path, { headers: headers(false), cache: 'no-store', credentials: 'omit' });
    if (res.status === 401) { lock('토큰이 맞지 않음'); throw new ApiError(401, null); }
    if (!res.ok) throw new ApiError(res.status, null);
    var blob = await res.blob();
    if (!/^image\/(png|jpeg)$/.test(blob.type)) throw new ApiError(0, { error: 'not_image' });
    var url = URL.createObjectURL(blob);
    if (gen !== state.gen) { URL.revokeObjectURL(url); throw new ApiError(0, { error: 'stale' }); }
    state.urls.push(url);
    return url;
  }

  function resetView() {
    state.gen += 1;
    state.urls.forEach(function (u) { URL.revokeObjectURL(u); });
    state.urls = [];
    state.players = [];
    $('list').replaceChildren();
  }

  setInterval(function () {
    state.players.forEach(function (p) {
      if (!p.frames.length) return;
      p.i = (p.i + 1) % p.frames.length;
      p.img.src = p.frames[p.i];
    });
  }, 1000 / FPS);

  // --- views

  function lock(msg) {
    setToken('');
    resetView();
    $('bar').classList.add('hidden');
    $('view').classList.add('hidden');
    $('lock').classList.remove('hidden');
    $('lock-msg').textContent = msg || '';
    $('token').value = '';
    $('token').focus();
  }

  function unlock() {
    var t = $('token').value.trim();
    if (!t) { $('lock-msg').textContent = '토큰을 입력해야 함'; return; }
    setToken(t);
    $('token').value = '';
    showApp();
  }

  function showApp() {
    $('lock').classList.add('hidden');
    $('bar').classList.remove('hidden');
    $('view').classList.remove('hidden');
    load();
  }

  function selectTab(tab) {
    state.tab = tab;
    Array.prototype.forEach.call(document.querySelectorAll('button.tab'), function (b) {
      b.setAttribute('aria-selected', String(b.getAttribute('data-tab') === tab));
    });
    load();
  }

  function setStatus(text, isErr) {
    $('status').textContent = text;
    $('status').className = 'status' + (isErr ? ' err' : '');
  }

  function setCount(tab, n) { $('count-' + tab).textContent = n == null ? '' : '(' + n + ')'; }

  async function load() {
    resetView();
    var tab = state.tab, gen = state.gen;
    setStatus('불러오는 중…');
    try {
      var items;
      if (tab === 'pending') items = (await api('GET', '/admin/market/pending')).pending || [];
      else items = (await api('GET', '/market/listings')).listings || [];
      if (gen !== state.gen) return;
      setCount(tab, items.length);
      setStatus(items.length ? '' : (tab === 'pending' ? '심사 대기 중인 캐릭터 없음' : '판매 중인 캐릭터 없음'));
      items.forEach(function (it) {
        if (it.kind && it.kind !== 'character') return; // maps are not reviewed here yet
        $('list').appendChild(tab === 'pending' ? pendingCard(it) : approvedCard(it));
      });
    } catch (err) {
      if (gen === state.gen && !(err instanceof ApiError && err.status === 401)) setStatus(describe(err), true);
    }
  }

  // --- cards

  function fmtTime(sec) {
    if (typeof sec !== 'number') return '-';
    return new Date(sec * 1000).toLocaleString('ko-KR');
  }

  function figure(caption, pixel) {
    var f = el('figure');
    var stage = el('div', 'stage' + (pixel ? ' pixel' : ''));
    var ph = el('span', 'ph', '불러오는 중…');
    var img = el('img');
    img.alt = caption;
    img.classList.add('hidden');
    stage.appendChild(ph);
    stage.appendChild(img);
    f.appendChild(stage);
    var cap = el('figcaption', null, caption);
    f.appendChild(cap);
    return { root: f, img: img, ph: ph, cap: cap };
  }

  function showImage(fig, path) {
    if (!path) { fig.ph.textContent = '파일 없음'; return; }
    imageUrl(path).then(function (u) {
      fig.img.src = u;
      fig.img.classList.remove('hidden');
      fig.ph.classList.add('hidden');
    }, function (err) { if (err.code !== 'stale') fig.ph.textContent = '불러오기 실패'; });
  }

  /**
   * Portrait, sprite and an animation player. frameUrl(motion, i) returns the file URL or null;
   * motions maps motion -> frame count.
   */
  function media(card, portraitUrl, spriteUrl, motions, frameUrl) {
    var box = el('div', 'media');
    var portrait = figure('초상화', false);
    var sprite = figure('스프라이트', true);
    var anim = figure('동작', true);
    box.appendChild(portrait.root);
    box.appendChild(sprite.root);
    box.appendChild(anim.root);
    showImage(portrait, portraitUrl);
    showImage(sprite, spriteUrl);

    var names = REQUIRED.concat(OPTIONAL).filter(function (m) { return motions[m] > 0; });
    var select = el('select');
    select.setAttribute('aria-label', '재생할 동작');
    names.forEach(function (m) {
      var o = el('option', null, (MOTION_LABEL[m] || m) + ' · ' + motions[m] + '장');
      o.value = m;
      select.appendChild(o);
    });
    anim.cap.replaceChildren(select);

    var player = { img: anim.img, frames: [], i: 0 };
    var cache = {};
    var gen = state.gen;
    state.players.push(player);
    function play(m) {
      player.frames = [];
      anim.img.classList.add('hidden');
      anim.ph.classList.remove('hidden');
      anim.ph.textContent = '불러오는 중…';
      if (!cache[m]) {
        var jobs = [];
        for (var i = 0; i < motions[m]; i++) jobs.push(imageUrl(frameUrl(m, i)));
        cache[m] = Promise.all(jobs);
        cache[m].catch(function () { delete cache[m]; });
      }
      cache[m].then(function (urls) {
        if (gen !== state.gen || select.value !== m) return;
        player.frames = urls;
        player.i = 0;
        anim.img.src = urls[0];
        anim.img.classList.remove('hidden');
        anim.ph.classList.add('hidden');
      }, function (err) { if (err.code !== 'stale' && select.value === m) anim.ph.textContent = '프레임 불러오기 실패'; });
    }
    select.addEventListener('change', function () { play(select.value); });
    if (names.length) play(names[0]); else anim.ph.textContent = '동작 없음';
    card.appendChild(box);
  }

  function info(card, rows) {
    var dl = el('dl');
    rows.forEach(function (r) { dl.appendChild(el('dt', null, r[0])); dl.appendChild(el('dd', null, r[1])); });
    card.appendChild(dl);
  }

  function heading(card, it) {
    card.appendChild(el('p', 'name', it.name));
    var d = typeof it.description === 'string' ? it.description : '';
    card.appendChild(el('p', 'desc' + (d ? '' : ' empty'), d || '설명 없음'));
  }

  function seller(alias, tag) { return (alias ? alias + ' · ' : '') + '기기 ' + tag; }

  /** Action buttons; a reason box is shown when any action needs one, and those buttons stay disabled until it has text. */
  function actions(card, id, spec) {
    var box = el('div', 'actions');
    var reason = null;
    if (spec.some(function (s) { return s.needsReason; })) {
      reason = el('textarea');
      reason.maxLength = 500;
      reason.placeholder = spec.length > 1 ? '거절 사유 (거절할 때 필수)' : '판매 중지 사유 (필수)';
      box.appendChild(reason);
    }
    var row = el('div', 'row');
    var msg = el('p', 'msg');
    var buttons = spec.map(function (s) {
      var b = el('button', s.cls, s.label);
      b.addEventListener('click', function () { run(s); });
      row.appendChild(b);
      return { b: b, s: s };
    });
    function sync() {
      var has = !!(reason && reason.value.trim());
      buttons.forEach(function (x) { x.b.disabled = x.s.needsReason && !has; });
    }
    function run(s) {
      buttons.forEach(function (x) { x.b.disabled = true; });
      if (reason) reason.disabled = true;
      msg.className = 'msg';
      msg.textContent = '처리 중…';
      var body = s.needsReason ? { reason: reason.value.trim() } : {};
      api('POST', '/admin/market/' + encodeURIComponent(id) + '/' + s.action, body).then(function (r) {
        card.classList.add('done');
        row.remove();
        if (reason) reason.remove();
        msg.className = 'msg ok';
        msg.textContent = DONE_LABEL[s.action] + ' · 장부 #' + r.serverSeq + (r.reason ? ' · 사유: ' + r.reason : '');
        var n = $('count-' + state.tab);
        n.textContent = '(' + $('list').querySelectorAll('.card:not(.done)').length + ')';
      }, function (err) {
        if (reason) reason.disabled = false;
        sync();
        msg.className = 'msg err';
        msg.textContent = describe(err);
        if (err.code === 'bad_state') card.classList.add('done');
      });
    }
    if (reason) reason.addEventListener('input', sync);
    sync();
    box.appendChild(row);
    box.appendChild(msg);
    card.appendChild(box);
  }

  function pendingCard(it) {
    var card = el('article', 'card');
    var files = {};
    (it.files || []).forEach(function (f) { files[f.path] = f.url; });
    var portrait = Object.keys(files).filter(function (p) { return /^portrait\.(png|jpg)$/.test(p); })[0];
    var motions = (it.manifest && it.manifest.frames) || {};
    media(card, files[portrait], files['sprite.png'], motions, function (m, i) { return files['frames/' + m + '_' + i + '.png']; });
    heading(card, it);
    var h = it.history || {};
    info(card, [
      ['가격', it.price + ' 결정'],
      ['판매자', seller(it.alias, it.sellerTag)],
      ['이력', '승인 ' + (h.approved || 0) + ' · 거절 ' + (h.rejected || 0) + ' · 판매 중지 ' + (h.delisted || 0) + ' · 대기 ' + (h.pending || 0)],
      ['제출', fmtTime(it.submittedAt)],
    ]);
    actions(card, it.id, [
      { action: 'approve', label: '승인', cls: 'approve', needsReason: false },
      { action: 'reject', label: '거절', cls: 'danger', needsReason: true },
    ]);
    return card;
  }

  function approvedCard(it) {
    var card = el('article', 'card');
    var base = API + '/admin/market/' + encodeURIComponent(it.id) + '/files/';
    var pv = it.previews || {};
    var tail = function (u) { return typeof u === 'string' ? u.slice(u.lastIndexOf('/') + 1) : ''; };
    var portrait = tail(pv.portrait);
    var motions = {};
    REQUIRED.forEach(function (m) { motions[m] = 6; });
    media(card, /^portrait\.(png|jpg)$/.test(portrait) ? base + portrait : null, base + 'sprite.png', motions,
      function (m, i) { return base + 'frames/' + m + '_' + i + '.png'; });
    heading(card, it);
    var s = it.seller || {};
    info(card, [
      ['가격', it.price + ' 결정'],
      ['판매자', seller(s.alias, s.tag)],
      ['판매', (it.sales || 0) + '건'],
      ['승인', fmtTime(it.approvedAt)],
    ]);
    actions(card, it.id, [{ action: 'delist', label: '판매 중지', cls: 'danger', needsReason: true }]);
    return card;
  }

  // --- wiring

  $('unlock').addEventListener('click', unlock);
  $('token').addEventListener('keydown', function (e) { if (e.key === 'Enter') unlock(); });
  $('logout').addEventListener('click', function () { lock(''); });
  $('refresh').addEventListener('click', load);
  Array.prototype.forEach.call(document.querySelectorAll('button.tab'), function (b) {
    b.addEventListener('click', function () { selectTab(b.getAttribute('data-tab')); });
  });
  if (getToken()) showApp(); else lock('');
})();
</script>
</body>
</html>
`;
