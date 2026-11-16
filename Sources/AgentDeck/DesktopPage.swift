import Foundation

/// The desktop page served by MobileServer at /desk: Windows 수혁 (a Tauri window around this page) and PC browsers.
/// Laid out like the Mac app (WorkspaceView): the sidebar (sort, 월드·목록·길드·마켓, 수혁 세션, 터미널, 다른 터미널,
/// 최근 대화), the world map with its overlays, the list, the RPG dialogue and the terminal. It runs on the phone's API
/// plus DesktopAPI; what only the Mac can do (voice, guild ledger, market purchases, worktrees, moving sessions) keeps
/// its place on screen and says so when pressed.
enum DesktopPage {
    static var html: String {
        #"""
<!doctype html>
<html lang="\#(L10n.english ? "en" : "ko")"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#232129">
<title>수혁</title>
<style>
  /* Pretendard (SIL OFL 1.1, art/out/fonts), served by the Mac so a PC without it installed shows the same type. */
  @font-face { font-family:"Pretendard Variable"; font-weight:45 920; font-style:normal; font-display:swap;
               src:url(/art/fonts/PretendardVariable.woff2) format("woff2-variations"), url(/art/fonts/PretendardVariable.woff2) format("woff2"); }
  :root { --side:#232129; --sel:#3d3a46; --bg:#18161d; --well:#0f0e14; --fg:#ece9f2; --muted:#9a96a6; --line:#34313c;
          --gold:#d9ad40; --gold2:#ffd966; --green:#30d158; --orange:#ff9f0a; --gray:#8e8e93; --red:#ff453a; --cyan:#64d2ff;
          --mono:"Cascadia Mono", Consolas, "D2Coding", ui-monospace, Menlo, monospace; }
  * { box-sizing:border-box; }
  html, body { margin:0; height:100%; background:var(--bg); color:var(--fg); overflow:hidden;
               font:13px "Pretendard Variable", Pretendard, "Segoe UI", "Malgun Gothic", system-ui, -apple-system, "Apple SD Gothic Neo", sans-serif; }
  button { font:inherit; color:inherit; cursor:pointer; }
  svg.i { width:16px; height:16px; fill:none; stroke:currentColor; stroke-width:1.7; stroke-linecap:round; stroke-linejoin:round; flex:none; }
  .btn { background:#ffffff14; border:1px solid #ffffff1c; border-radius:6px; padding:4px 10px; white-space:nowrap; }
  .btn:hover { background:#ffffff22; }
  .btn.small { padding:2px 8px; font-size:12px; }
  .btn:disabled { opacity:.45; cursor:default; }
  .ghost { background:none; border:0; padding:4px; border-radius:6px; color:var(--muted); display:inline-flex; align-items:center; }
  .ghost:hover { background:#ffffff14; color:var(--fg); }
  .dot { width:8px; height:8px; border-radius:50%; flex:none; display:inline-block; }
  .mono { font-family:var(--mono); }

  /* window: sidebar | detail */
  #app { display:grid; grid-template-columns:300px 1fr; height:100%; }
  #app.noside { grid-template-columns:0 1fr; }
  #app.noside aside { display:none; }
  aside { background:var(--side); border-right:1px solid #00000066; display:flex; flex-direction:column; min-height:0; }
  .tb { height:46px; display:flex; align-items:center; gap:6px; padding:0 12px; flex:none; }
  aside .tb { justify-content:flex-end; }
  .sortbar { display:flex; align-items:center; justify-content:space-between; padding:4px 14px 6px; position:relative; }
  .sortbar .cur { background:none; border:0; display:flex; align-items:center; gap:5px; font-size:14px; font-weight:600; color:var(--fg); padding:2px 0; }
  .pop { position:absolute; z-index:40; background:#2e2b35; border:1px solid #ffffff1f; border-radius:8px; padding:4px; box-shadow:0 8px 24px #000a; display:none; min-width:170px; }
  .pop.open { display:grid; }
  .pop button { background:none; border:0; text-align:left; padding:6px 10px; border-radius:5px; display:flex; align-items:center; gap:8px; }
  .pop button:hover { background:#0a84ff; }
  .scroll { overflow-y:auto; flex:1; min-height:0; padding:0 10px 14px; }
  .nav { display:flex; align-items:center; gap:10px; padding:7px 10px; border-radius:7px; color:#cfcbd8; cursor:pointer; font-size:14px; }
  .nav:hover { background:#ffffff0d; }
  .nav.on { background:var(--sel); color:var(--fg); }
  .sec { display:flex; align-items:center; justify-content:space-between; color:var(--muted); font-size:12px; font-weight:600; padding:16px 6px 4px; }
  .sec button { background:none; border:0; color:var(--muted); font-size:11.5px; padding:0; }
  .sec button:hover { color:var(--fg); }
  .folder { display:flex; gap:5px; align-items:center; color:var(--muted); font-size:11.5px; font-weight:700; padding:6px 6px 2px; }
  .row { display:flex; align-items:center; gap:8px; padding:5px 8px; border-radius:7px; cursor:pointer; min-width:0; }
  .row:hover { background:#ffffff0d; }
  .row.on { background:var(--sel); }
  .row .body { min-width:0; flex:1; }
  .row .l1 { display:flex; align-items:center; gap:4px; min-width:0; font-size:14px; }
  .row .l1 .t { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; color:#c9c5d3; }
  .row .l2 { color:var(--muted); font-size:11.5px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .row .ago { font-size:11px; font-variant-numeric:tabular-nums; white-space:nowrap; color:var(--muted); }
  .row .ago.fresh { color:var(--fg); }
  .row .ago.busy { color:var(--green); font-weight:600; }
  .pill { color:#fff; font-weight:700; font-size:13px; padding:0 6px; border-radius:99px; white-space:nowrap; flex:none; }
  .sub { padding:2px 8px 2px 34px; color:var(--muted); font-size:11.5px; display:flex; gap:5px; min-width:0; white-space:nowrap; align-items:center; }
  .sub b { color:var(--fg); overflow:hidden; text-overflow:ellipsis; }
  .sub span { overflow:hidden; text-overflow:ellipsis; }
  .row.sub { padding-left:30px; }
  .hint { color:var(--muted); font-size:11.5px; padding:4px 8px; }
  .recent { display:flex; align-items:center; gap:8px; padding:5px 8px; }
  .recent .body { flex:1; min-width:0; }
  .recent .t { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; color:#c9c5d3; font-size:14px; }
  .recent .l2 { color:var(--muted); font-size:11.5px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }

  #detail { display:flex; flex-direction:column; min-width:0; min-height:0; }
  #detail .tb { border-bottom:1px solid #00000055; position:relative; }
  #detail .tb .title { color:var(--muted); font-size:15px; font-weight:600; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; max-width:36%; }
  .talk { position:absolute; left:50%; transform:translateX(-50%); display:flex; align-items:center; gap:6px; background:#ffffff12;
          border:1px solid #ffffff1c; border-radius:99px; padding:4px 14px; color:#d6d2de; }
  .seg { margin-left:auto; display:flex; background:#ffffff12; border-radius:7px; padding:2px; }
  .seg button { background:none; border:0; padding:3px 12px; border-radius:5px; color:var(--muted); }
  .seg button.on { background:#ffffff26; color:var(--fg); }
  #pane { flex:1; min-height:0; position:relative; }
  #offline { display:none; background:#5a1f1c; color:#ffd9d6; padding:6px 14px; font-size:12.5px; }
  #offline.show { display:block; }

  /* world */
  .world { position:absolute; inset:12px; border-radius:10px; overflow:hidden; background:var(--well); }
  .world > canvas { position:absolute; inset:0; width:100%; height:100%; cursor:grab; }
  .world > canvas.drag { cursor:grabbing; }
  .wait { position:absolute; left:14px; top:14px; width:324px; background:#0d0b10e6; border:1px solid var(--gold); border-radius:8px; z-index:5; }
  .wait .h { display:flex; align-items:center; gap:7px; padding:8px 12px; font-weight:700; font-size:12.5px; cursor:pointer; }
  .wait .n { background:#ffffff1f; border-radius:99px; padding:0 7px; font-size:11px; font-weight:600; }
  .wait .h .chev { margin-left:auto; color:var(--muted); display:flex; }
  .wait .b { border-top:1px solid #d9ad4055; padding:8px 12px; font-size:11.5px; color:#cfcbd8; display:grid; gap:6px; }
  .wait.closed .b { display:none; }
  .wait .w { display:flex; gap:6px; align-items:center; cursor:pointer; overflow:hidden; white-space:nowrap; }
  .wait .w span:last-child { overflow:hidden; text-overflow:ellipsis; }
  .counts { position:absolute; right:14px; top:14px; z-index:5; display:flex; gap:12px; align-items:center; background:#0d0b10e6;
            border:1px solid var(--gold); border-radius:99px; padding:5px 12px; font-size:12px; font-weight:600; font-variant-numeric:tabular-nums; }
  .counts > span { display:flex; align-items:center; gap:4px; }
  .counts .k { color:#cfcbd8; font-weight:500; }
  .zoom { position:absolute; left:14px; bottom:14px; z-index:5; display:grid; gap:6px; }
  .zoom button { width:30px; height:24px; border-radius:6px; background:#1d1b22e6; border:1px solid #ffffff1c; color:#ddd; display:grid; place-items:center; padding:0; }
  .mini { position:absolute; right:14px; bottom:14px; z-index:5; border:2px solid var(--gold); border-radius:6px; overflow:hidden; cursor:pointer; background:#000; }
  .mini canvas { display:block; }
  .hover { position:absolute; z-index:8; width:240px; background:#2b2832f2; border-radius:8px; padding:10px; box-shadow:0 4px 14px #0009; pointer-events:none;
           display:none; font-size:12px; line-height:1.45; }
  .hover .n { font-weight:700; font-size:14px; display:flex; align-items:center; gap:6px; }
  .hover .t { font-weight:600; font-size:13px; }
  .card { position:absolute; z-index:9; width:320px; overflow:hidden; background:#2b2832f5; border-radius:10px; padding:12px; box-shadow:0 8px 24px #000b; display:grid; gap:8px; }
  .card .top { display:flex; gap:10px; align-items:flex-start; }
  .card .por { width:64px; height:80px; border-radius:6px; object-fit:cover; background:#ffffff14; image-rendering:pixelated; }
  .card .nm { font-size:18px; font-weight:700; }
  .card .en { color:var(--muted); font-size:11.5px; }
  .card .st { display:flex; align-items:center; gap:5px; font-size:11.5px; font-weight:700; flex-wrap:wrap; }
  .chip { background:#ffffff1f; border-radius:99px; padding:0 6px; font-size:10.5px; font-weight:500; color:var(--fg); }
  .card .up { color:var(--muted); font-size:10.5px; font-variant-numeric:tabular-nums; }
  .card hr { border:0; border-top:1px solid #ffffff1f; margin:0; }
  .card .tt { font-weight:600; font-size:13px; }
  .ln { display:flex; gap:6px; align-items:flex-start; font-size:13px; line-height:1.4; }
  .ln svg { width:12px; height:12px; margin-top:3px; color:var(--muted); }
  .ln span { min-width:0; overflow-wrap:anywhere; }
  .clamp2 { display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; overflow:hidden; }
  .clamp3 { display:-webkit-box; -webkit-line-clamp:3; -webkit-box-orient:vertical; overflow:hidden; }
  .clamp4 { display:-webkit-box; -webkit-line-clamp:4; -webkit-box-orient:vertical; overflow:hidden; }
  .card .go { display:flex; justify-content:center; gap:8px; align-items:center; padding:8px; border-radius:8px; background:#ffffff1c; border:1px solid #ffffff22; }
  .card .go:hover { background:#ffffff2a; }
  .hunt { color:var(--cyan); font-size:11.5px; font-weight:600; display:flex; gap:5px; align-items:center; }
  .floatDlg { position:absolute; z-index:10; left:31%; right:1.6%; top:7%; bottom:17%; }

  /* dialogue */
  .dlg { position:relative; display:flex; height:100%; border:3px solid var(--gold); border-radius:12px; overflow:hidden; background:#121a38; }
  .dlg::before { content:""; position:absolute; inset:0; background:url(/art/backdrop.jpg) center/cover; opacity:.12; pointer-events:none; }
  .dlg > * { position:relative; }
  .dlg .side { width:178px; flex:none; padding:14px; background:#00000040; display:flex; flex-direction:column; align-items:center; gap:8px; text-align:center; }
  .dlg.panel .side { width:218px; }
  .dlg .side img { width:100%; border-radius:8px; image-rendering:pixelated; }
  .dlg .side .nm { color:var(--gold2); font-size:19px; font-weight:700; }
  .dlg .side .st { display:flex; align-items:center; gap:5px; font-size:11.5px; }
  .dlg .side .act { color:var(--muted); font-size:10.5px; }
  .dlg .main { flex:1; min-width:0; display:flex; flex-direction:column; }
  .dlg .head { display:flex; align-items:center; gap:8px; padding:10px 14px; background:#00000033; }
  .dlg .head .tt { font-weight:700; font-size:15px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .dlg .head .pj { color:var(--muted); font:12px var(--mono); white-space:nowrap; }
  .dlg .head .sp { flex:1; }
  .dlg .log { flex:1; overflow-y:auto; padding:12px 16px; display:flex; flex-direction:column; gap:10px; min-height:0; }
  .msg.me { align-self:flex-end; max-width:calc(100% - 60px); background:#8c6b1f; padding:10px; border-radius:10px; white-space:pre-wrap; word-break:break-word; line-height:1.45; font-size:14px; }
  .msg.agent { margin-right:60px; display:grid; gap:3px; }
  .msg.agent .who { color:var(--gold2); font-size:11.5px; font-weight:700; }
  .msg.agent .bub { background:#ffffff14; border-radius:10px; padding:10px 12px; font-size:14.5px; line-height:1.5; word-break:break-word; }
  .msg.tool { color:var(--muted); font-size:11.5px; display:flex; gap:6px; align-items:center; white-space:nowrap; overflow:hidden; cursor:pointer; }
  .msg.tool span { overflow:hidden; text-overflow:ellipsis; }
  .msg.tool.open { white-space:pre-wrap; align-items:flex-start; }
  .msg.tool svg { width:12px; height:12px; }
  .live { color:#cfcbd8; border-left:2px solid var(--green); padding-left:10px; white-space:pre-wrap; font-size:13px; }
  .bub p { margin:4px 0; white-space:pre-wrap; }
  .bub .h1, .bub .h2 { font-size:20px; font-weight:700; margin:10px 0 6px; }
  .bub .h3, .bub .h4, .bub .h5, .bub .h6 { font-size:16.5px; font-weight:700; margin:8px 0 4px; }
  .bub .li { display:flex; gap:6px; margin:2px 0; }
  .bub .li .b { color:var(--muted); flex:none; }
  .bub .li > span:last-child { white-space:pre-wrap; }
  .bub table { border-collapse:collapse; margin:6px 0; background:#ffffff0a; border-radius:8px; }
  .bub th { text-align:left; font-weight:700; padding:6px 14px; border-bottom:1px solid #ffffff26; }
  .bub td { padding:5px 14px; }
  .bub blockquote { margin:4px 0; padding-left:10px; border-left:3px solid #ffffff33; color:#cfcbd8; white-space:pre-wrap; }
  .bub hr { border:0; border-top:1px solid #ffffff26; }
  .bub a, .msg.me a { color:#79b8ff; }
  .bub code { font:13px var(--mono); background:#00000040; padding:1px 4px; border-radius:4px; }
  .code { position:relative; background:#00000059; border-radius:8px; margin:6px 0; }
  .code pre { margin:0; padding:10px 12px; overflow-x:auto; font:12.5px var(--mono); white-space:pre; }
  .code button { position:absolute; top:6px; right:6px; }
  .menu { border:1px solid var(--gold); background:#0d0b10cc; border-radius:10px; padding:12px; display:grid; gap:8px; max-width:720px; }
  .menu b { color:var(--gold2); }
  .menu pre { margin:0; white-space:pre-wrap; color:var(--muted); font:12px var(--mono); }
  .menu button { text-align:left; background:#ffffff12; border:1px solid #ffffff22; border-radius:7px; padding:7px 10px; }
  .menu button:hover { border-color:var(--gold); }
  .menu small { display:block; color:var(--muted); }
  .screen { margin:0 14px 6px; max-height:38%; overflow:auto; font:12px var(--mono); white-space:pre; background:#000000a0; border-radius:8px; padding:10px; flex:none; }
  .inbar { padding:8px 14px 10px; display:grid; gap:6px; }
  .inrow { display:flex; gap:8px; align-items:flex-end; }
  .inrow textarea { flex:1; resize:none; background:#00000059; color:var(--fg); border:0; border-radius:8px; padding:9px 10px; font:inherit; font-size:14px;
                    line-height:1.4; max-height:9em; min-height:38px; outline:none; }
  .inrow textarea::placeholder { white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .inrow .ib { width:42px; height:36px; border-radius:8px; background:#ffffff14; border:1px solid #ffffff1c; display:grid; place-items:center; padding:0; }
  .inrow .send { height:36px; padding:0 14px; border-radius:8px; background:#ffffff14; border:1px solid #ffffff1c; }
  .inrow .send:not(:disabled) { background:#0a84ff; border-color:#0a84ff; }
  .inrow .send:disabled { color:#ffffff66; cursor:default; }
  .inrow .stop { height:36px; padding:0 12px; border-radius:8px; background:var(--red); border:0; color:#fff; display:flex; align-items:center; gap:5px; }
  .tools { display:flex; gap:4px; align-items:center; flex-wrap:wrap; }
  .tools .keys { display:flex; gap:4px; flex-wrap:wrap; flex:1; min-width:0; }
  .tools .btn { display:flex; align-items:center; gap:5px; font-size:12px; padding:3px 10px; }
  .tools .btn.on { background:#0a84ff; border-color:#0a84ff; }
  .usage { padding:0 16px 10px; font:11px var(--mono); white-space:nowrap; overflow:hidden; color:var(--muted); display:flex; gap:10px; }
  .usage .m { color:#d999ff; font-weight:700; }
  .notice { color:var(--orange); font-size:12px; }
  .notice:empty { display:none; }
  .dropzone { position:absolute; inset:0; z-index:20; border-radius:10px; background:#d9ad4026; display:none; place-items:center; font-size:18px; font-weight:700; pointer-events:none; }
  .dlg.drop .dropzone { display:grid; }
  .page { position:absolute; inset:12px; }

  /* list */
  .board { position:absolute; inset:0; display:flex; flex-direction:column; }
  .board::before { content:""; position:absolute; inset:0; background:url(/art/backdrop.jpg) center/cover; opacity:.08; pointer-events:none; }
  .board > * { position:relative; }
  .bhead { display:flex; align-items:center; gap:14px; padding:10px 14px; border-bottom:1px solid var(--line); font-variant-numeric:tabular-nums; }
  .bhead .sp { flex:1; }
  .bhead label { display:flex; align-items:center; gap:6px; color:var(--muted); }
  .grid { flex:1; overflow-y:auto; padding:12px; display:grid; grid-template-columns:repeat(auto-fill, minmax(320px, 1fr)); gap:12px; align-content:start; }
  .scard { background:#ffffff0d; border-radius:10px; padding:12px; min-height:150px; display:flex; flex-direction:column; gap:8px; border:1.5px solid; cursor:pointer; }
  .scard .h { display:flex; align-items:center; gap:6px; font-size:11.5px; font-weight:700; }
  .scard .h .sp { flex:1; }
  .scard .t { font-size:15px; font-weight:700; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .scard .p { color:var(--muted); font:11.5px var(--mono); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }

  /* terminal */
  .tpage { position:absolute; inset:12px; display:flex; flex-direction:column; border-radius:10px; overflow:hidden; background:#000; }
  .thead { display:flex; align-items:center; gap:8px; padding:8px 12px; background:#1d1b22; }
  .thead .t { font-weight:600; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .thead .sp { flex:1; }
  .termbox { position:relative; flex:1; min-height:0; display:flex; }
  .term { flex:1; margin:0; padding:8px 12px; overflow:auto; font:13px/1.35 var(--mono); white-space:pre; background:#000; color:#e6e6e6; outline:none; }
  .term.focus { box-shadow:inset 0 0 0 1px #0a84ff; }
  .term .cur { background:#e6e6e6; color:#000; }
  .termIn { position:absolute; left:-9999px; top:0; width:10px; height:10px; opacity:0; }
  #bottom { flex:none; height:34%; min-height:120px; border-top:1px solid #000; display:none; flex-direction:column; background:#000; }
  #bottom.open { display:flex; }

  /* other panes */
  .macOnly { position:absolute; inset:12px; border-radius:10px; display:grid; place-items:center; text-align:center; background:var(--well); overflow:hidden; }
  .macOnly::before { content:""; position:absolute; inset:0; background:url(/art/backdrop.jpg) center/cover; opacity:.1; }
  .macOnly div { position:relative; display:grid; gap:10px; max-width:420px; }
  .macOnly h2 { margin:0; color:var(--gold2); }
  .macOnly p { margin:0; color:var(--muted); line-height:1.6; }

  #toast { position:fixed; left:50%; bottom:24px; transform:translateX(-50%); background:#2e2b35f2; border:1px solid #ffffff22; padding:9px 16px;
           border-radius:10px; display:none; max-width:520px; cursor:pointer; z-index:60; box-shadow:0 6px 20px #000a; }
  .modal { position:fixed; inset:0; background:#000a; display:none; place-items:center; z-index:70; }
  .modal.show { display:grid; }
  .modal .box { background:#2b2832; border:1px solid #ffffff22; border-radius:12px; padding:20px; width:min(520px, 92vw); display:grid; gap:12px; }
  .modal h2 { margin:0; font-size:17px; }
  .modal p { margin:0; color:var(--muted); line-height:1.5; }
  .modal .btns { display:flex; justify-content:flex-end; gap:8px; }
  .modal label { display:grid; gap:4px; color:var(--muted); font-size:12px; }
  .modal input, .modal textarea, .modal select { font:inherit; color:var(--fg); background:#1d1b22; border:1px solid #ffffff22; border-radius:6px; padding:7px 9px; }
  .modal .primary { background:#0a84ff; border-color:#0a84ff; }
  #pairErr { color:var(--red); min-height:1.2em; }
</style></head><body>
<div id="app">
  <aside>
    <div class="tb">
      <button class="ghost" id="newBtn" title="새 세션"><svg class="i" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg></button>
      <button class="ghost" id="sideBtn" title="사이드바"><svg class="i" viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M9 5v14"/></svg></button>
    </div>
    <div class="sortbar">
      <button class="cur" id="sortBtn"></button>
      <button class="ghost" id="ascBtn" title="정렬 방향"></button>
      <div class="pop" id="sortPop" style="left:12px;top:30px"></div>
    </div>
    <div class="scroll" id="side"></div>
  </aside>
  <div id="detail">
    <div class="tb">
      <button class="ghost" id="sideBtn2" title="사이드바" style="display:none"><svg class="i" viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M9 5v14"/></svg></button>
      <span class="title" id="title">수혁</span>
      <button class="talk" id="talkBtn"></button>
      <div class="seg" id="modeSeg" style="display:none"><button data-m="dialogue">대화</button><button data-m="terminal">터미널</button></div>
    </div>
    <div id="offline">Mac의 수혁에 연결할 수 없음 — Mac과 수혁이 켜져 있는지 확인</div>
    <div id="pane"></div>
    <div id="bottom"></div>
  </div>
</div>
<div id="toast"></div>
<div class="modal" id="pair"><div class="box">
  <h2>수혁 연결</h2>
  <p id="pairMsg"></p>
  <input id="pairLink" placeholder="https://…/desk#pair=…">
  <div id="pairErr"></div>
  <div class="btns"><button class="btn primary" id="pairBtn">연결</button></div>
</div></div>
<div class="modal" id="ask"><div class="box">
  <h2 id="askTitle"></h2>
  <div id="askBody" style="display:grid;gap:10px"></div>
  <div class="btns"><button class="btn" id="askNo">취소</button><button class="btn primary" id="askYes"></button></div>
</div></div>

<script>
"use strict";
// MARK: basics
const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const svg = (d, style) => '<svg class="i" viewBox="0 0 24 24"' + (style ? ' style="' + style + '"' : "") + ">" + d + "</svg>";
const P = {
  map: '<path d="M9 4 3 6v14l6-2 6 2 6-2V4l-6 2-6-2zM9 4v14M15 6v14"/>',
  list: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 9h10M7 13h10M7 17h6"/>',
  diamond: '<path d="M12 3 21 12 12 21 3 12z"/>',
  bag: '<path d="M5 8h14l-1 12H6L5 8zM9 8V6a3 3 0 0 1 6 0v2"/>',
  clock: '<path d="M3 12a9 9 0 1 0 3-6.7L3 8M3 3v5h5M12 7v5l3 2"/>',
  folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  cal: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4M12 13v5M9.5 15.5h5"/>',
  text: '<path d="M4 7V5h16v2M12 5v14M9 19h6"/>',
  half: '<circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 0 0 18z" fill="currentColor"/>',
  chev: '<path d="m6 9 6 6 6-6"/>', chevUp: '<path d="m6 15 6-6 6 6"/>', chevRight: '<path d="m9 6 6 6-6 6"/>',
  down: '<path d="M12 4v16M6 14l6 6 6-6"/>', up: '<path d="M12 20V4M6 10l6-6 6 6"/>',
  mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
  micOff: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3M4 4l16 16"/>',
  clip: '<path d="m21 11-8.5 8.5a5 5 0 0 1-7-7L14 4a3.5 3.5 0 0 1 5 5l-8.5 8.5a2 2 0 0 1-3-3L15 7"/>',
  muted: '<path d="M11 5 6 9H3v6h3l5 4zM16 9l5 5M21 9l-5 5"/>',
  x: '<path d="M6 6l12 12M18 6 6 18"/>',
  shrink: '<path d="M4 14h6v6M20 10h-6V4M14 10l7-7M3 21l7-7"/>',
  hourglass: '<path d="M6 3h12M6 21h12M7 3c0 5 10 6 10 9s-10 4-10 9M17 3c0 5-10 6-10 9s10 4 10 9"/>',
  person: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  sparkle: '<path d="M12 3c1 5 4 8 9 9-5 1-8 4-9 9-1-5-4-8-9-9 5-1 8-4 9-9z"/>',
  hammer: '<path d="m14 6 4 4M3 21l9-9M12 4l8 8-3 3-8-8z"/>',
  gem: '<path d="M12 3 21 12 12 21 3 12z" fill="currentColor"/>',
  bubbles: '<path d="M4 5h11a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2H9l-4 3v-3H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2zM19 9h1a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2h-1v3l-4-3h-4"/>',
  stop: '<rect x="6" y="6" width="12" height="12" rx="1" fill="currentColor"/>',
  plus: '<path d="M12 5v14M5 12h14"/>', minus: '<path d="M5 12h14"/>',
  fit: '<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/>',
  term: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3M13 15h4"/>',
};
const ic = (k, style) => svg(P[k], style);
const small = "width:12px;height:12px";
// SwiftUI's colors in dark mode: projectColor's palette (index from DesktopAPI.colorIndex) and Activity's colors.
const PALETTE = ["#0a84ff", "#ff375f", "#40c8e0", "#ff9f0a", "#bf5af2", "#66d4cf", "#ffd60a", "#ff453a", "#64d2ff", "#5e5ce6"];
const ACT = { working: ["#30d158", "작업 중"], waiting: ["#ff9f0a", "대기 중"], resting: ["#8e8e93", "휴식 중"] };
const actColor = a => (ACT[a && a.activityCode] || ACT.resting)[0];
const projColor = i => PALETTE[(i || 0) % PALETTE.length];
const pillHTML = a => '<span class="pill" style="background:' + projColor(a.color) + 'd9">' + esc(a.name) + "</span>";
function ago(ts) {
  const m = Math.max(0, Math.floor((Date.now() / 1000 - ts) / 60));
  return m < 1 ? "방금" : m < 60 ? m + "분 전" : m < 1440 ? Math.floor(m / 60) + "시간 전" : Math.floor(m / 1440) + "일 전";
}
function dur(ts) {
  const s = Math.max(0, Math.floor(Date.now() / 1000 - ts));
  return s < 60 ? s + "초" : s < 3600 ? Math.floor(s / 60) + "분" : s < 86400 ? Math.floor(s / 3600) + "시간 " + Math.floor(s % 3600 / 60) + "분" : Math.floor(s / 86400) + "일";
}
const tilde = p => String(p || "").replace(/^\/Users\/[^/]+/, "~");
const portrait = c => "/art/portraits/" + encodeURIComponent(c) + ".jpg";
const frame = (c, f) => "/art/frames/" + encodeURIComponent(c) + "/" + f + ".png";
const store = { get(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : JSON.parse(v); } catch (e) { return d; } },
                set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} } };

// MARK: state and network
const S = { agents: [], bosses: [], world: { w: 1, h: 0.5625 }, avatar: 0.034, crystals: 0, side: null,
            pane: "world", sel: null, mode: "dialogue", lastRefresh: 0 };
let offline = false;
async function api(path, body) {
  let r;
  try {
    r = await fetch(path, body ? { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body), credentials: "same-origin" }
                               : { credentials: "same-origin", cache: "no-store" });
  } catch (e) { setOffline(true); throw e; }
  if (r.status === 401) { setOffline(false); showPair(); throw new Error("pair"); }
  const j = await r.json().catch(() => null);  // the tunnel answers with its own HTML page when the Mac is off
  if (j === null) { setOffline(true); throw new Error("offline"); }
  setOffline(false);
  return j;
}
function setOffline(v) { if (v !== offline) { offline = v; $("offline").classList.toggle("show", v); } }
function toast(s, onclick) {
  const t = $("toast"); t.textContent = s; t.style.display = "block";
  t.onclick = () => { t.style.display = "none"; if (onclick) onclick(); };
  clearTimeout(t._h); t._h = setTimeout(() => t.style.display = "none", onclick ? 6000 : 2400);
}
const macOnly = what => toast(what + " — Mac의 수혁에서 사용할 수 있음");
function ask(title, opts) {  // no window.prompt/confirm: the Windows webview may not show them
  opts = opts || {};
  return new Promise(done => {
    $("askTitle").textContent = title;
    const body = $("askBody"); body.innerHTML = "";
    let input = null;
    const finish = ok => { $("ask").classList.remove("show"); done(ok ? (input ? input.value : true) : null); };
    if (opts.text) { const p = document.createElement("p"); p.textContent = opts.text; body.appendChild(p); }
    if (opts.input !== undefined) {
      input = document.createElement("input"); input.value = opts.input; body.appendChild(input);
      input.onkeydown = e => { if (e.key === "Enter" && !e.isComposing) finish(true); };
    }
    $("askYes").textContent = opts.yes || "확인";
    $("askYes").onclick = () => finish(true); $("askNo").onclick = () => finish(false);
    $("ask").classList.add("show");
    if (input) setTimeout(() => input.focus(), 0);
  });
}

// MARK: pairing — the Mac's "PC용 링크 복사" link carries a one-time secret after #pair=
function showPair() {
  if ($("pair").classList.contains("show")) return;
  $("pairMsg").textContent = "Mac의 수혁 → 설정(⌘,) → 모바일 접속에서 '연결 시작'을 누르고, 'PC용 링크 복사'로 받은 링크를 60초 안에 붙여넣으세요.";
  $("pairErr").textContent = ""; $("pairLink").value = "";
  $("pair").classList.add("show"); setTimeout(() => $("pairLink").focus(), 0);
}
async function pair(secret) {
  $("pair").classList.add("show"); $("pairErr").textContent = ""; $("pairMsg").textContent = "연결 요청을 보내는 중…";
  const r = await fetch("/pair", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ secret }), credentials: "same-origin" }).catch(() => null);
  const j = r ? await r.json().catch(() => ({})) : {};
  if (!r || !r.ok) { $("pairErr").textContent = j.error || "연결하지 못함"; return; }
  $("pairMsg").textContent = "Mac에서 [허용]을 눌러 주세요. 2분 안에 허용하지 않으면 만료됨.";
  for (;;) {
    await new Promise(res => setTimeout(res, 1500));
    const s = await fetch("/pair/status?id=" + encodeURIComponent(j.pending), { credentials: "same-origin" }).catch(() => null);
    const k = s ? await s.json().catch(() => ({})) : {};
    if (s && s.ok && k.ok) { $("pair").classList.remove("show"); refresh(); refreshSide(); return; }
    if (!s || !s.ok) { $("pairErr").textContent = k.error || "연결하지 못함"; return; }
  }
}
$("pairBtn").onclick = () => {
  const m = $("pairLink").value.match(/(?:#pair=)?([0-9a-f]{32})/);
  if (!m) { $("pairErr").textContent = "링크에서 연결 코드를 찾지 못함"; return; }
  pair(m[1]);
};
$("pairLink").onkeydown = e => { if (e.key === "Enter") $("pairBtn").click(); };

// MARK: navigation — #world, #list, #guild, #market, #s=<session id>, #t=<tmux name>
function go(pane, sel, mode) {
  S.pane = pane; S.sel = sel || null; if (mode) S.mode = mode;
  const h = pane === "session" ? "#s=" + encodeURIComponent(sel) : pane === "shell" ? "#t=" + encodeURIComponent(sel) : "#" + pane;
  if (location.hash !== h) history.replaceState(null, "", h);
  render();
}
function fromHash() {
  const h = decodeURIComponent(location.hash);
  if (h.startsWith("#s=")) return go("session", h.slice(3));
  if (h.startsWith("#t=")) return go("shell", h.slice(3));
  go(["world", "list", "guild", "market"].includes(h.slice(1)) ? h.slice(1) : "world");
}
function toggleSide() {
  const hidden = $("app").classList.toggle("noside"); store.set("side", !hidden);
  $("sideBtn2").style.display = hidden ? "" : "none"; sizeWorld();
}
$("sideBtn").onclick = toggleSide; $("sideBtn2").onclick = toggleSide;
$("talkBtn").innerHTML = ic("micOff") + "<span>대화 모드</span>";
$("talkBtn").onclick = () => macOnly("음성 대화 모드");
document.querySelectorAll("#modeSeg button").forEach(b => b.onclick = () => { S.mode = b.dataset.m; render(); });

// MARK: sidebar (WorkspaceView's List)
const SORT_IC = { folder: "folder", lastActivity: "clock", created: "cal", name: "text", status: "half" };
let sort = store.get("sort", "lastActivity"), asc = store.get("asc", false), recentOpen = store.get("recentOpen", false);
async function refreshSide() {
  try { S.side = await api("/api/sidebar?sort=" + encodeURIComponent(sort) + "&asc=" + (asc ? 1 : 0)); renderSide(); } catch (e) {}
}
function renderSort() {
  const sorts = (S.side && S.side.sorts) || [];
  const cur = sorts.find(s => s.key === sort) || { key: sort, label: "마지막 응답 순" };
  $("sortBtn").innerHTML = ic(SORT_IC[cur.key] || "clock") + "<span>" + esc(cur.label) + "</span>" + ic("chev", small);
  $("ascBtn").innerHTML = ic(asc ? "up" : "down");
  $("sortPop").innerHTML = sorts.map(s => '<button data-k="' + s.key + '">' + ic(SORT_IC[s.key] || "clock") + esc(s.label) + "</button>").join("");
  $("sortPop").querySelectorAll("button").forEach(b => b.onclick = () => { sort = b.dataset.k; store.set("sort", sort); $("sortPop").classList.remove("open"); refreshSide(); });
}
$("sortBtn").onclick = e => { e.stopPropagation(); $("sortPop").classList.toggle("open"); };
$("ascBtn").onclick = () => { asc = !asc; store.set("asc", asc); refreshSide(); };
document.addEventListener("click", () => document.querySelectorAll(".pop.open").forEach(p => p.classList.remove("open")));

function rowHTML(it) {
  const on = (S.pane === "session" && it.id && it.id === S.sel) || (S.pane === "shell" && !it.id && it.term === S.sel);
  let right = "";
  if (it.working) right = '<span class="ago">' + esc(it.working) + "</span>";
  else if (it.id) right = it.status === "busy" ? '<span class="ago busy">작업 중</span>'
    : it.last ? '<span class="ago' + (Date.now() / 1000 - it.last < 3600 ? " fresh" : "") + '">' + ago(it.last) + "</span>" : "";
  let html = '<div class="row' + (on ? " on" : "") + '" data-id="' + esc(it.id || "") + '" data-term="' + esc(it.term || "") + '">' +
    '<i class="dot" style="background:' + (it.id ? actColor(it) : "#8e8e93") + '"></i><div class="body"><div class="l1">' +
    (it.id ? pillHTML(it) : "") + '<span class="t">' + esc(it.title) + '</span></div><div class="l2">' + esc(it.subtitle) + "</div></div>" + right + "</div>";
  for (const c of it.children || []) html += '<div class="row sub" data-id="' + esc(c.id) + '" data-term=""><i class="dot" style="background:' + actColor(c) + '"></i><b>' + esc(c.name) + "</b><span>" + esc(c.title) + "</span></div>";
  for (const w of it.subagents || []) html += '<div class="sub">ㄴ <b>' + esc(w.title) + "</b>" + (w.detail ? "<span>- " + esc(w.detail) + "</span>" : "") + "</div>";
  return html;
}
const groupsHTML = gs => gs.map(g => (g.folder ? '<div class="folder">' + ic("folder", small) + esc(g.folder) + "</div>" : "") + g.items.map(rowHTML).join("")).join("");
function renderSide() {
  renderSort();
  const d = S.side || { hosted: [], shells: [], external: [], recent: [] };
  const nav = [["world", "map", "월드"], ["list", "list", "목록"], ["guild", "diamond", "길드 · 결정"], ["market", "bag", "캐릭터 마켓"]];
  const empty = gs => !gs.some(g => g.items.length);
  $("side").innerHTML =
    nav.map(([k, i, l]) => '<div class="nav' + (S.pane === k ? " on" : "") + '" data-nav="' + k + '">' + ic(i) + "<span>" + l + "</span></div>").join("") +
    '<div class="sec"><span>수혁 세션</span><button data-mac="워크트리">워크트리…</button></div>' +
    (empty(d.hosted) ? '<div class="hint">＋ 버튼으로 새 세션 시작</div>' : groupsHTML(d.hosted)) +
    (empty(d.shells) ? "" : '<div class="sec"><span>터미널</span></div>' + groupsHTML(d.shells)) +
    '<div class="sec"><span>다른 터미널</span><button data-mac="수혁으로 옮기기">수혁으로 옮기기…</button></div>' + groupsHTML(d.external) +
    '<div class="sec" data-recent style="cursor:pointer"><span>최근 대화</span>' + ic(recentOpen ? "chev" : "chevRight", small) + "</div>" +
    (recentOpen ? d.recent.map(r => '<div class="recent"><div class="body"><div class="t">' + esc(r.title) + '</div><div class="l2">' +
      esc(r.agent + " · " + r.folder + " · " + dur(r.updated) + " 전") + '</div></div><button class="btn small" data-resume="' + esc(r.id) + '">이어서</button></div>').join("") : "");
  const side = $("side");
  side.querySelectorAll("[data-nav]").forEach(n => n.onclick = () => go(n.dataset.nav));
  side.querySelectorAll(".row").forEach(r => r.onclick = () => r.dataset.id ? go("session", r.dataset.id) : go("shell", r.dataset.term));
  side.querySelectorAll("[data-mac]").forEach(b => b.onclick = () => macOnly(b.dataset.mac));
  side.querySelector("[data-recent]").onclick = () => { recentOpen = !recentOpen; store.set("recentOpen", recentOpen); renderSide(); };
  side.querySelectorAll("[data-resume]").forEach(b => b.onclick = async () => {
    const r = await api("/api/resume", { id: b.dataset.resume }).catch(() => ({}));
    toast(r.ok ? "이어서 여는 중" : "열지 못함"); setTimeout(refreshSide, 1500);
  });
}

// MARK: main render
let cleanup = [];
function render() {
  cleanup.forEach(f => f()); cleanup = [];
  const pane = $("pane"); pane.innerHTML = "";
  const a = S.agents.find(x => x.id === S.sel);
  $("title").textContent = S.pane === "session" ? (a ? a.title : "종료된 세션") : S.pane === "shell" ? termTitle(S.sel) : "수혁";
  $("modeSeg").style.display = S.pane === "session" ? "" : "none";
  document.querySelectorAll("#modeSeg button").forEach(b => b.classList.toggle("on", b.dataset.m === S.mode));
  if (S.pane === "world") mountWorld(pane);
  else if (S.pane === "list") mountList(pane);
  else if (S.pane === "guild") mountMacOnly(pane, "길드 · 결정", "캐릭터 라인업, 결정 장부와 공증은 이 Mac의 지갑과 묶여 있어 Mac의 수혁에서 관리함.");
  else if (S.pane === "market") mountMacOnly(pane, "캐릭터 마켓", "캐릭터 구매·설치·판매는 Mac의 수혁에서 함. 산 캐릭터는 이 화면에도 그대로 나옴.");
  else if (S.pane === "session") {
    if (!a) pane.innerHTML = '<div class="macOnly"><div><p>종료된 세션</p></div></div>';
    else if (S.mode === "terminal") mountSessionTerminal(pane, a);
    else {
      const host = document.createElement("div"); host.className = "page"; pane.appendChild(host);
      const d = new Dialogue(host, a.id, { large: true }); cleanup.push(() => d.stop());
    }
  } else if (S.pane === "shell") mountShell(pane, S.sel);
  renderSide();
}
function termTitle(name) {
  for (const g of (S.side && S.side.shells) || []) for (const it of g.items) if (it.term === name) return it.title;
  return name || "터미널";
}
function mountMacOnly(pane, title, text) {
  pane.innerHTML = '<div class="macOnly"><div><h2>' + esc(title) + "</h2><p>" + esc(text) + '</p><p style="color:var(--orange)">Mac의 수혁에서 사용할 수 있음</p></div></div>';
}

// MARK: world (WorldView): the same map, bosses and walking, drawn on a canvas, with its overlays.
const imgs = {};
function img(src) { if (!imgs[src]) { const i = new Image(); i.src = src; imgs[src] = i; } return imgs[src]; }
const pos = {}, facing = {};
let W = null;  // the mounted world, if any
function sizeWorld() { if (W) setTimeout(() => W && W.resize(), 0); }
addEventListener("resize", sizeWorld);
function mountWorld(pane) {
  pane.innerHTML = '<div class="world"><canvas></canvas>' +
    '<div class="wait"><div class="h">' + ic("hourglass", "color:var(--gold)") + '<span>입력 기다리는 에이전트</span><span class="n">0</span><span class="chev">' + ic("chevUp", small) + '</span></div><div class="b"></div></div>' +
    '<div class="counts"></div><div class="zoom"><button data-z="in">' + ic("plus") + '</button><button data-z="out">' + ic("minus") + '</button><button data-z="fit">' + ic("fit") + "</button></div>" +
    '<div class="mini"><canvas></canvas></div><div class="hover"></div></div>';
  const box = pane.querySelector(".world"), cv = box.querySelector(":scope > canvas"), ctx = cv.getContext("2d");
  const mini = box.querySelector(".mini canvas"), mctx = mini.getContext("2d");
  const wait = box.querySelector(".wait"); if (store.get("waitClosed", false)) wait.classList.add("closed");
  wait.querySelector(".h").onclick = () => { wait.classList.toggle("closed"); store.set("waitClosed", wait.classList.contains("closed")); };
  let cw = 0, ch = 0, cam = null, hoverId = null, cardId = null, alive = true, dlg = null;
  const dpr = Math.min(2, devicePixelRatio || 1);
  const fitScale = () => Math.min(cw / S.world.w, ch / S.world.h);
  const fit = () => { cam = { x: S.world.w / 2, y: S.world.h / 2, s: fitScale() }; };
  function clamp() {
    cam.s = Math.min(Math.max(cam.s, fitScale()), fitScale() * 6);
    const hw = cw / cam.s / 2, hh = ch / cam.s / 2;
    cam.x = hw * 2 >= S.world.w ? S.world.w / 2 : Math.min(Math.max(cam.x, hw), S.world.w - hw);
    cam.y = hh * 2 >= S.world.h ? S.world.h / 2 : Math.min(Math.max(cam.y, hh), S.world.h - hh);
  }
  const sx = x => (x - cam.x) * cam.s + cw / 2, sy = y => (y - cam.y) * cam.s + ch / 2;
  W = { dlgId: null };
  W.resize = () => {
    cw = box.clientWidth; ch = box.clientHeight; cv.width = cw * dpr; cv.height = ch * dpr;
    const mw = Math.min(260, cw * 0.2), mh = mw * S.world.h / S.world.w;
    mini.width = mw * dpr; mini.height = mh * dpr; mini.style.width = mw + "px"; mini.style.height = mh + "px";
    if (!cam) fit(); clamp();
  };
  W.resize();
  box.querySelectorAll(".zoom button").forEach(b => b.onclick = () => {
    if (b.dataset.z === "fit") fit(); else cam.s *= b.dataset.z === "in" ? 1.4 : 1 / 1.4;
    clamp();
  });
  cv.addEventListener("wheel", e => {
    e.preventDefault();
    const r = cv.getBoundingClientRect(), mx = e.clientX - r.left, my = e.clientY - r.top;
    const wx = cam.x + (mx - cw / 2) / cam.s, wy = cam.y + (my - ch / 2) / cam.s;
    cam.s *= Math.exp(-e.deltaY * 0.0015); clamp();
    cam.x = wx - (mx - cw / 2) / cam.s; cam.y = wy - (my - ch / 2) / cam.s; clamp();
  }, { passive: false });
  let drag = null;
  cv.addEventListener("pointerdown", e => { cv.setPointerCapture(e.pointerId); drag = { x: e.clientX, y: e.clientY, cx: cam.x, cy: cam.y, moved: false }; });
  cv.addEventListener("pointermove", e => {
    const r = cv.getBoundingClientRect();
    if (drag) {
      if (Math.hypot(e.clientX - drag.x, e.clientY - drag.y) > 4) { drag.moved = true; cv.classList.add("drag"); }
      if (drag.moved) { cam.x = drag.cx - (e.clientX - drag.x) / cam.s; cam.y = drag.cy - (e.clientY - drag.y) / cam.s; clamp(); }
    }
    const a = hit(e.clientX - r.left, e.clientY - r.top);
    hoverId = a ? a.id : null; showHover(a, e.clientX - r.left, e.clientY - r.top);
  });
  cv.addEventListener("pointerleave", () => { hoverId = null; showHover(null); });
  cv.addEventListener("pointerup", e => {
    cv.classList.remove("drag");
    if (drag && !drag.moved) { const r = cv.getBoundingClientRect(), a = hit(e.clientX - r.left, e.clientY - r.top); openCard(a ? a.id : null); }
    drag = null;
  });
  mini.parentElement.onclick = e => {
    const r = mini.getBoundingClientRect();
    cam.x = (e.clientX - r.left) / r.width * S.world.w; cam.y = (e.clientY - r.top) / r.height * S.world.h; clamp();
  };
  function hit(x, y) {
    let best = null, bd = 1e9; const base = S.avatar * cam.s;
    for (const a of S.agents) {
      const p = pos[a.id] || a, d = Math.hypot(sx(p.x) - x, sy(p.y) - base * 0.1 - y);
      if (d < bd) { bd = d; best = a; }
    }
    return best && bd < Math.max(22, base * 0.55) ? best : null;
  }
  function showHover(a, x, y) {  // HoverCard
    const hv = box.querySelector(".hover");
    if (!a || a.id === cardId) { hv.style.display = "none"; return; }
    hv.innerHTML = '<div class="n">' + esc(a.name) + '<i class="dot" style="width:7px;height:7px;background:' + actColor(a) + '"></i><span style="font-weight:400;color:var(--muted);font-size:11.5px">' + esc(a.activity) + "</span></div>" +
      '<div class="t clamp2">' + esc(a.title) + '</div><div class="mono" style="font-size:11.5px;color:' + projColor(a.color) + '">' + esc(a.project) + "</div>" +
      (a.hunt ? '<div class="hunt">' + ic("gem", small) + esc(a.hunt) + "</div>" : "") +
      (a.activityCode === "working" && a.action ? '<div style="font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">' + esc(a.action) + "</div>" : "") +
      (a.lastUser ? '<div style="color:var(--muted)" class="clamp2">지시: ' + esc(a.lastUser) + "</div>" : "");
    hv.style.display = "block";
    hv.style.left = Math.min(x + 16, cw - 250) + "px"; hv.style.top = Math.max(8, Math.min(y + 12, ch - hv.offsetHeight - 8)) + "px";
  }
  function wireCard(c, a) {
    c.querySelector("[data-close]").onclick = () => openCard(null);
    c.querySelector(".go").onclick = () => { openCard(null); openDlg(a.id); };
    c.querySelectorAll("img.por").forEach(i => i.onerror = () => { i.onerror = null; i.src = frame(a.character, "walk_down_2"); });
  }
  // StatusCard next to the clicked agent; "대화하기" opens the dialogue over the map.
  function openCard(id) {
    box.querySelectorAll(".card").forEach(c => c.remove()); cardId = id; showHover(null);
    const a = S.agents.find(x => x.id === id); if (!a) return;
    const p = pos[a.id] || a, x = sx(p.x), y = sy(p.y);
    const c = document.createElement("div"); c.className = "card"; c.innerHTML = cardHTML(a); box.appendChild(c);
    c.style.left = (x + 40 + 330 < cw ? x + 40 : Math.max(10, x - 360)) + "px";
    c.style.top = Math.max(10, Math.min(y - 120, ch - c.offsetHeight - 10)) + "px";
    wireCard(c, a);
  }
  function openDlg(id) {
    closeDlg();
    const host = document.createElement("div"); host.className = "floatDlg"; box.appendChild(host);
    dlg = new Dialogue(host, id, { panel: true, onClose: closeDlg, onExpand: () => go("session", id, "dialogue") });
    W.dlgId = id;
  }
  function closeDlg() { if (dlg) { dlg.stop(); dlg.host.remove(); dlg = null; W && (W.dlgId = null); } }
  W.updateOverlays = () => {
    const waiting = S.agents.filter(a => a.status === "waiting");
    wait.querySelector(".n").textContent = waiting.length;
    wait.querySelector(".b").innerHTML = waiting.length ? waiting.map(a => '<div class="w" data-id="' + esc(a.id) + '">' + pillHTML(a) + "<span>" + esc(a.title) + "</span></div>").join("")
      : "기다리는 에이전트 없음 — 모두 일하는 중이거나 쉬는 중";
    wait.querySelectorAll(".w").forEach(w => w.onclick = () => openDlg(w.dataset.id));
    const n = k => S.agents.filter(a => (a.tier || "camp") === k).length;
    box.querySelector(".counts").innerHTML =
      '<span><i class="dot" style="background:#8e8e93"></i><span class="k">대기소</span>' + n("camp") + "</span>" +
      '<span><i class="dot" style="background:#30d158"></i><span class="k">하</span>' + n("low") + "</span>" +
      '<span><i class="dot" style="background:#64d2ff"></i><span class="k">중</span>' + n("mid") + "</span>" +
      '<span><i class="dot" style="background:#ff9f0a"></i><span class="k">상</span>' + n("high") + "</span>" +
      '<span style="color:var(--cyan)">' + ic("gem", small) + '<span style="color:var(--fg)">' + S.crystals.toLocaleString() + "</span></span>";
    const c = box.querySelector(".card"), a = S.agents.find(x => x.id === cardId);
    if (c && a) { c.innerHTML = cardHTML(a); wireCard(c, a); } else if (cardId && !a) openCard(null);
  };
  W.updateOverlays();

  // Walking: along x, then y (four directions), as the Mac's Walker does.
  function step(dt) {
    for (const a of S.agents) {
      const p = pos[a.id]; if (!p) { pos[a.id] = { x: a.x, y: a.y }; continue; }
      const v = 0.12 * dt, dx = a.x - p.x, dy = a.y - p.y;
      if (Math.abs(dx) > 1e-4) { p.x += Math.sign(dx) * Math.min(Math.abs(dx), v); facing[a.id] = dx < 0 ? "left" : "right"; p.walk = true; }
      else if (Math.abs(dy) > 1e-4) { p.y += Math.sign(dy) * Math.min(Math.abs(dy), v); facing[a.id] = dy < 0 ? "up" : "down"; p.walk = true; }
      else p.walk = false;
    }
  }
  const beat = [0, 0, 1, 1, 2, 3, 3, 4, 5, 5, 0, 0], TIER = { low: 0, mid: 1, high: 2 };
  function frameOf(a, p, t) {
    const ph = (a.id.length * 7) % 10 / 10;
    if (p.walk) { const f = Math.floor(t * 10) % 6, d = facing[a.id] || "down"; return [d === "right" ? "walk_left_" + f : "walk_" + d + "_" + f, d === "right"]; }
    if (a.tier) {
      const boss = S.bosses.find(b => b.key === a.tier), right = boss && p.x < boss.x;
      if (a.status === "busy") return ["attack_" + beat[Math.floor((t + ph) * 10) % beat.length], right];
      return ["walk_left_2", right];
    }
    return ["walk_down_2", false];
  }
  const rr = (x, y, w, h, r) => { ctx.beginPath(); ctx.roundRect(x, y, Math.max(0, w), h, r); };
  const font = px => "bold " + px + "px 'Pretendard Variable', 'Segoe UI', 'Malgun Gothic', sans-serif";
  let last = performance.now();
  function draw(now) {
    if (!alive) return;
    const dt = Math.min(0.25, (now - last) / 1000); last = now; const t = now / 1000;
    step(dt);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = "#0f0e14"; ctx.fillRect(0, 0, cw, ch);
    const big = img("/art/field_4k.jpg"), m = big.complete && big.naturalWidth ? big : img("/art/field.jpg");
    if (m.complete && m.naturalWidth) { ctx.imageSmoothingEnabled = true; ctx.drawImage(m, sx(0), sy(0), S.world.w * cam.s, S.world.h * cam.s); }
    ctx.imageSmoothingEnabled = false;
    for (const b of S.bosses) {
      const i = img("/art/bosses/" + b.key + "_" + (Math.floor(t * 6) % 6) + ".png"), h = b.h * cam.s * 1.25;
      if (i.complete && i.naturalHeight) { const w = h * i.naturalWidth / i.naturalHeight; ctx.drawImage(i, sx(b.x) - w / 2, sy(b.y) + b.h * cam.s / 2 - h, w, h); }
      // HP falls with every blow of the working agents here and refills (BossView.hp).
      const attackers = S.agents.filter(a => a.tier === b.key && a.status === "busy").length;
      const per = [0.04, 0.025, 0.015][TIER[b.key] || 0], hp = attackers ? 1 - ((attackers * t / 1.2 * per) % 1) : 1;
      const bw = b.w * cam.s * 1.1, bh = Math.max(4, b.h * cam.s * 0.05), bx = sx(b.x) - bw / 2, by = sy(b.y) - b.h * cam.s;
      ctx.font = font(Math.max(10, b.h * cam.s * 0.12)); ctx.textAlign = "center";
      ctx.fillStyle = "#000"; ctx.fillText(b.name, sx(b.x) + 1, by - 5); ctx.fillStyle = "#fff"; ctx.fillText(b.name, sx(b.x), by - 6);
      ctx.fillStyle = "#0009"; rr(bx, by, bw, bh, bh / 2); ctx.fill();
      const g = ctx.createLinearGradient(bx, 0, bx + bw, 0); g.addColorStop(0, "#ff453a"); g.addColorStop(1, "#ff9f0a");
      ctx.fillStyle = g; rr(bx, by, bw * hp, bh, bh / 2); ctx.fill();
    }
    const list = S.agents.map(a => [a, pos[a.id] || a]).sort((u, v) => u[1].y - v[1].y), base = S.avatar * cam.s;
    for (const [a, p] of list) {
      const [name, mirror] = frameOf(a, p, t), i = img(frame(a.character, name));
      const x = sx(p.x), y = sy(p.y) + base * 0.5;
      ctx.fillStyle = "#0005"; ctx.beginPath(); ctx.ellipse(x, y, base * 0.22, base * 0.06, 0, 0, 7); ctx.fill();
      if (i.complete && i.naturalHeight) {
        const h = base * i.naturalHeight / 128, w = h * i.naturalWidth / i.naturalHeight;
        ctx.save(); ctx.translate(x, y); if (mirror) ctx.scale(-1, 1);
        if (a.id === hoverId || a.id === cardId || a.id === W.dlgId) { ctx.shadowColor = "#ffd34d"; ctx.shadowBlur = 14; }
        ctx.drawImage(i, -w / 2, -h, w, h); ctx.restore();
      }
      if (a.activityCode === "resting") {  // z z rising over a resting head
        ctx.font = font(Math.max(9, base * 0.16)); ctx.textAlign = "left"; ctx.fillStyle = "#e8e8f0";
        for (let k = 0; k < 2; k++) {
          const ph = (t * 0.5 + k * 0.5 + a.id.length * 0.13) % 1;
          ctx.globalAlpha = 1 - ph; ctx.fillText("z", x + base * (0.25 + ph * 0.15), y - base * (0.9 + ph * 0.35));
        }
        ctx.globalAlpha = 1;
      }
      if (a.status === "waiting") {
        ctx.fillStyle = "#ff453a"; rr(x + base * 0.2, y - base * 1.15, 16, 18, 8); ctx.fill();
        ctx.fillStyle = "#fff"; ctx.font = font(12); ctx.textAlign = "center"; ctx.fillText("!", x + base * 0.2 + 8, y - base * 1.15 + 13);
      }
      ctx.font = font(Math.max(10, Math.min(13, base * 0.17))); ctx.textAlign = "center";
      const tw = ctx.measureText(a.name).width + 12;
      ctx.fillStyle = projColor(a.color) + "d9"; rr(x - tw / 2, y + 3, tw, 17, 8.5); ctx.fill();
      ctx.fillStyle = "#fff"; ctx.fillText(a.name, x, y + 15.5);
    }
    drawMini();
    requestAnimationFrame(draw);
  }
  function drawMini() {
    const w = mini.width, h = mini.height, m = img("/art/field.jpg"), k = w / S.world.w;
    mctx.setTransform(1, 0, 0, 1, 0, 0);
    if (m.complete && m.naturalWidth) mctx.drawImage(m, 0, 0, w, h); else { mctx.fillStyle = "#222"; mctx.fillRect(0, 0, w, h); }
    for (const a of S.agents) {
      const p = pos[a.id] || a;
      mctx.fillStyle = a.tier ? "#30d158" : "#d9d9d9"; mctx.strokeStyle = "#0008"; mctx.lineWidth = dpr;
      mctx.beginPath(); mctx.arc(p.x * k, p.y * k, 3 * dpr, 0, 7); mctx.fill(); mctx.stroke();
    }
    if (cam.s > fitScale() * 1.01) {
      mctx.strokeStyle = "#ffd966"; mctx.lineWidth = 1.5 * dpr;
      mctx.strokeRect((cam.x - cw / cam.s / 2) * k, (cam.y - ch / cam.s / 2) * k, cw / cam.s * k, ch / cam.s * k);
    }
  }
  requestAnimationFrame(draw);
  cleanup.push(() => { alive = false; closeDlg(); W = null; });
}
function cardHTML(a) {
  return '<div class="top"><img class="por" src="' + portrait(a.character) + '" alt=""><div style="flex:1;min-width:0;display:grid;gap:3px">' +
    '<div class="nm">' + esc(a.name) + "</div>" + (a.charName ? '<div class="en">' + esc(a.charName) + "</div>" : "") +
    '<div class="st"><i class="dot" style="background:' + actColor(a) + '"></i><span style="color:' + actColor(a) + '">' +
      esc(a.status === "waiting" ? "선택 기다리는 중" : a.activity + (a.status === "shell" ? " · 백그라운드 셸 실행 중" : "")) + '</span><span class="chip">' + esc(a.agent + (a.estimated ? " · 추정" : "")) + "</span></div>" +
    (a.started ? '<div class="up">가동 ' + dur(a.started) + " · 현재 상태 " + dur(a.updated || a.started) + "째</div>" : "") +
    '</div><button class="ghost" data-close>' + ic("x") + "</button></div><hr>" +
    '<div class="tt clamp2">' + esc(a.title) + "</div>" +
    (a.activityCode === "working" && a.action ? '<div class="ln" style="font-weight:600;font-size:12px">' + ic("hammer") + '<span class="clamp2">지금: ' + esc(a.action) + "</span></div>" : "") +
    '<div class="mono" style="font-size:11.5px;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' + esc(tilde(a.cwd)) + "</div>" +
    (a.hunt ? '<div class="hunt">' + ic("gem", small) + esc(a.hunt) + "</div>" : "") +
    (a.lastUser ? '<div class="ln">' + ic("person") + '<span class="clamp2">' + esc(a.lastUser) + "</span></div>" : "") +
    (a.lastAssistant ? '<div class="ln">' + ic("sparkle") + '<span class="clamp4">' + esc(a.lastAssistant) + "</span></div>" : "") +
    '<button class="go">' + ic("bubbles") + "<span>대화하기</span></button>";
}

// MARK: list (BoardView): counts, "작업 중만", cards
let busyOnly = store.get("busyOnly", false);
function mountList(pane) {
  pane.innerHTML = '<div class="board"><div class="bhead"></div><div class="grid"></div></div>';
  let lastKey = "";
  const draw = () => {
    if (!pane.querySelector(".board")) return;
    const n = k => S.agents.filter(a => a.activityCode === k).length;
    pane.querySelector(".bhead").innerHTML = Object.entries(ACT).map(([k, v]) => '<span style="color:' + v[0] + ';display:flex;gap:5px;align-items:center"><i class="dot" style="background:' + v[0] + '"></i>' + v[1] + " " + n(k) + "</span>").join("") +
      '<span class="sp"></span><label><input type="checkbox" id="busyOnly"' + (busyOnly ? " checked" : "") + '>작업 중만</label><span style="color:var(--muted);font-size:12px">갱신 ' + Math.max(0, Math.round(Date.now() / 1000 - S.lastRefresh)) + "초 전</span>";
    $("busyOnly").onchange = e => { busyOnly = e.target.checked; store.set("busyOnly", busyOnly); lastKey = ""; draw(); };
    const vis = S.agents.filter(a => !busyOnly || a.activityCode === "working");
    const html = vis.length ? vis.map(a => '<div class="scard" data-id="' + esc(a.id) + '" style="border-color:' + actColor(a) + (a.activityCode === "working" ? "b3" : "26") + '">' +
      '<div class="h"><i class="dot" style="background:' + actColor(a) + '"></i><span style="color:' + actColor(a) + '">' + esc((ACT[a.activityCode] || ACT.resting)[1]) + '</span><span class="chip">' + esc(a.agent + (a.estimated ? " · 추정" : "")) + '</span><span class="sp"></span>' +
        (a.updated ? '<span style="color:var(--muted);font-weight:400">' + ago(a.updated) + "</span>" : "") + "</div>" +
      '<div class="t">' + esc(a.title) + '</div><div class="p">' + esc(tilde(a.cwd)) + "</div>" +
      (a.lastUser ? '<div class="ln">' + ic("person") + '<span class="clamp2">' + esc(a.lastUser) + "</span></div>" : "") +
      (a.lastAssistant ? '<div class="ln">' + ic("sparkle") + '<span class="clamp3">' + esc(a.lastAssistant) + "</span></div>" : "") +
      "</div>").join("") : '<div style="grid-column:1/-1;text-align:center;color:var(--muted);padding:40px">떠 있는 세션 없음</div>';
    if (html !== lastKey) {
      lastKey = html; pane.querySelector(".grid").innerHTML = html;
      pane.querySelectorAll(".scard").forEach(c => c.onclick = () => go("session", c.dataset.id, "dialogue"));
    }
  };
  draw();
  const timer = setInterval(draw, 1000);
  cleanup.push(() => clearInterval(timer));
}

// MARK: markdown (MarkdownView): headings, lists, tables, quotes, code blocks; inline code, bold, italic, links, files.
function md(text, files) {
  const lines = String(text).replace(/\r/g, "").split("\n"), para = [];
  let out = "", i = 0;
  const flush = () => { if (para.length) { out += "<p>" + inl(para.join("\n"), files) + "</p>"; para.length = 0; } };
  const cells = l => l.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map(c => c.trim());
  while (i < lines.length) {
    const l = lines[i]; let m;
    if (/^\s*```/.test(l)) {
      flush(); const buf = []; i++;
      while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) buf.push(lines[i++]);
      i++; out += '<div class="code"><button class="btn small">복사</button><pre>' + esc(buf.join("\n")) + "</pre></div>"; continue;
    }
    if ((m = l.match(/^(#{1,6})\s+(.*)$/))) { flush(); out += '<div class="h' + m[1].length + '">' + inl(m[2], files) + "</div>"; i++; continue; }
    if (/^\s*\|.*\|\s*$/.test(l) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
      flush(); const head = cells(l), rows = []; i += 2;
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) rows.push(cells(lines[i++]));
      out += "<table><tr>" + head.map(c => "<th>" + inl(c, files) + "</th>").join("") + "</tr>" +
        rows.map(r => "<tr>" + r.map(c => "<td>" + inl(c, files) + "</td>").join("") + "</tr>").join("") + "</table>"; continue;
    }
    if ((m = l.match(/^(\s*)([-*+]|\d+[.)])\s+(.*)$/))) {
      flush(); const depth = Math.floor(m[1].replace(/\t/g, "  ").length / 2), mark = /\d/.test(m[2]) ? m[2] : "•";
      out += '<div class="li" style="padding-left:' + depth * 1.4 + 'em"><span class="b">' + esc(mark) + "</span><span>" + inl(m[3], files) + "</span></div>"; i++; continue;
    }
    if (/^\s*>\s?/.test(l)) {
      flush(); const buf = [];
      while (i < lines.length && /^\s*>\s?/.test(lines[i])) buf.push(lines[i++].replace(/^\s*>\s?/, ""));
      out += "<blockquote>" + inl(buf.join("\n"), files) + "</blockquote>"; continue;
    }
    if (/^\s*(-{3,}|\*{3,}|_{3,})\s*$/.test(l)) { flush(); out += "<hr>"; i++; continue; }
    if (!l.trim()) { flush(); i++; continue; }
    para.push(l); i++;
  }
  flush(); return out;
}
function inl(text, files) {
  files = files || {};
  const keys = Object.keys(files).sort((a, b) => b.length - a.length).map(k => k.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  const re = new RegExp("\\[([^\\]\\n]+)\\]\\((https?://[^\\s)]+)\\)|`([^`\\n]+)`|\\*\\*([^*\\n]+)\\*\\*|(?<![\\w*])\\*([^*\\n]+)\\*(?![\\w*])|https?://[^\\s<>\"'`)\\]]+" +
                        (keys.length ? "|" + keys.join("|") : ""), "g");
  const fileLink = (token, label) => '<a href="/api/file?path=' + encodeURIComponent(files[token]) + '" target="_blank">' + label + "</a>";
  let out = "", last = 0, m;
  while ((m = re.exec(text))) {
    out += esc(text.slice(last, m.index));
    if (m[2]) out += '<a href="' + esc(m[2]) + '" target="_blank" rel="noopener noreferrer">' + esc(m[1]) + "</a>";
    else if (m[3] !== undefined) out += files[m[3]] ? fileLink(m[3], "<code>" + esc(m[3]) + "</code>") : "<code>" + esc(m[3]) + "</code>";
    else if (m[4] !== undefined) out += "<b>" + inl(m[4], files) + "</b>";
    else if (m[5] !== undefined) out += "<i>" + esc(m[5]) + "</i>";
    else if (files[m[0]]) out += fileLink(m[0], esc(m[0]));
    else {
      let url = m[0]; const tail = (url.match(/[.,;:!?]+$/) || [""])[0];
      if (tail) url = url.slice(0, -tail.length);
      out += '<a href="' + esc(url) + '" target="_blank" rel="noopener noreferrer">' + esc(url) + "</a>" + esc(tail);
    }
    last = m.index + m[0].length;
  }
  return out + esc(text.slice(last));
}

// MARK: dialogue (DialogueView): portrait, header, conversation, input bar, usage line.
class Dialogue {
  constructor(host, id, opts) {
    this.host = host; this.id = id; this.opts = opts || {}; this.alive = true; this.lastKey = ""; this.screen = false; this.timer = null;
    host.innerHTML = '<div class="dlg' + (this.opts.panel ? " panel" : "") + '"><div class="side"></div><div class="main">' +
      '<div class="head"><span class="tt"></span><span class="pj"></span><span class="sp"></span>' +
        (this.opts.panel ? '<button class="ghost" data-a="expand" title="크게 보기">' + ic("shrink") + "</button>" : "") +
        '<button class="btn small" data-a="clear">새 대화 (/clear)</button><button class="btn small" data-a="terminal">터미널로</button>' +
        '<button class="ghost" data-a="close">' + ic("x") + "</button></div>" +
      '<div class="log"></div><pre class="screen" style="display:none"></pre>' +
      '<div class="inbar"><div class="notice"></div><div class="inrow"><textarea rows="1"></textarea>' +
        '<button class="stop" style="display:none">' + ic("stop") + "중단</button>" +
        '<button class="ib" data-a="attach" title="파일·이미지 첨부 — 붙여넣기나 끌어 놓기도 됨">' + ic("clip") + "</button>" +
        '<button class="ib" data-a="mic" title="말로 지시하기">' + ic("mic") + "</button>" +
        '<button class="send">보내기</button><input type="file" multiple hidden></div>' +
        '<div class="tools"><span class="keys"></span>' +
        '<button class="btn" data-a="voice" style="display:none">Codex 음성 대화</button>' +
        '<button class="btn" data-a="read">' + ic("muted") + '답변 읽어 주기</button><button class="btn" data-a="screen">화면 보기</button></div></div>' +
      '<div class="usage"></div></div><div class="dropzone">' + ic("clip") + "&nbsp;놓으면 지시에 첨부</div></div>";
    const q = s => host.querySelector(s);
    this.el = { dlg: q(".dlg"), side: q(".side"), tt: q(".head .tt"), pj: q(".head .pj"), log: q(".log"), screen: q(".screen"), notice: q(".notice"),
                ta: q("textarea"), stop: q(".stop"), send: q(".send"), file: q("input[type=file]"), keys: q(".keys"), usage: q(".usage") };
    host.querySelectorAll("[data-a]").forEach(b => b.onclick = e => { e.stopPropagation(); this.action(b.dataset.a); });
    const ta = this.el.ta;
    ta.oninput = () => { ta.style.height = "auto"; ta.style.height = Math.min(ta.scrollHeight, 150) + "px"; this.el.send.disabled = !ta.value.trim(); };
    ta.onkeydown = e => {
      if (e.isComposing || e.keyCode === 229) return;
      if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); this.send(); }
      else if (e.key === "Escape" && this.working()) { e.preventDefault(); this.key("Escape"); }
      else if (e.key === "ArrowUp" && !ta.value) { const a = this.agent(); if (a && a.lastUser) { e.preventDefault(); ta.value = a.lastUser; ta.oninput(); } }
    };
    ta.onpaste = e => { const f = [...((e.clipboardData && e.clipboardData.files) || [])]; if (f.length) { e.preventDefault(); this.upload(f); } };
    this.el.send.onclick = () => this.send();
    this.el.stop.onclick = () => this.key("Escape");
    this.el.file.onchange = () => { this.upload([...this.el.file.files]); this.el.file.value = ""; };
    const d = this.el.dlg;
    d.ondragover = e => { e.preventDefault(); d.classList.add("drop"); };
    d.ondragleave = e => { if (!d.contains(e.relatedTarget)) d.classList.remove("drop"); };
    d.ondrop = e => { e.preventDefault(); d.classList.remove("drop"); this.upload([...e.dataTransfer.files]); };
    this.el.send.disabled = true;
    Dialogue.current = this;
    this.update(); this.poll();
    setTimeout(() => ta.focus(), 0);
  }
  agent() { return S.agents.find(a => a.id === this.id); }
  working() { const a = this.agent(); return !!a && a.status === "busy"; }
  stop() { this.alive = false; clearTimeout(this.timer); if (Dialogue.current === this) Dialogue.current = null; }
  // Portrait, header and input state from /api/state, refreshed by the main loop.
  update() {
    const a = this.agent(); if (!a) return;
    const side = this.el.side;
    if (side.dataset.c !== a.character) {
      side.dataset.c = a.character;
      side.innerHTML = '<img alt=""><div class="nm"></div><div class="st"><i class="dot"></i><span></span></div><div class="act clamp3"></div>';
      const im = side.querySelector("img"); im.onerror = () => { im.onerror = null; im.src = frame(a.character, "walk_down_2"); }; im.src = portrait(a.character);
    }
    side.querySelector(".nm").textContent = a.name;
    side.querySelector(".dot").style.background = actColor(a);
    side.querySelector(".st span").textContent = a.activity;
    side.querySelector(".act").textContent = a.activityCode === "working" ? (a.action || "") : "";
    this.el.tt.textContent = a.title; this.el.pj.textContent = a.project;
    this.host.querySelector('[data-a="clear"]').style.display = a.agent === "Claude" ? "" : "none";
    this.host.querySelector('[data-a="voice"]').style.display = a.agent === "Codex" ? "" : "none";
    this.el.ta.disabled = !a.canSend;
    this.el.ta.placeholder = a.canSend ? a.name + "에게 지시하기 (Enter로 보내기 · Shift+Enter 줄바꿈)" : "이 터미널은 입력을 보낼 수 없음 — 보기만 가능";
    this.el.stop.style.display = this.working() ? "" : "none";
  }
  async poll() {
    clearTimeout(this.timer); if (!this.alive) return;
    try {
      const c = await api("/api/chat?id=" + encodeURIComponent(this.id) + (this.screen ? "&screen=1" : ""));
      if (!this.alive) return;
      const key = JSON.stringify(c);
      if (key !== this.lastKey) { this.lastKey = key; this.draw(c); }
    } catch (e) {}
    if (this.alive) this.timer = setTimeout(() => this.poll(), document.hidden ? 4000 : 1200);
  }
  draw(c) {
    const a = this.agent() || {}, log = this.el.log, stick = log.scrollTop + log.clientHeight > log.scrollHeight - 60;
    const open = new Set([...log.querySelectorAll(".msg.tool.open")].map(d => d.dataset.i));
    log.innerHTML = "";
    (c.items || []).forEach((it, i) => {
      const d = document.createElement("div"); d.className = "msg " + it.role; d.dataset.i = i;
      if (it.role === "me") d.innerHTML = inl(it.text, it.files);
      else if (it.role === "tool") {
        d.innerHTML = ic("hammer") + "<span>" + esc(it.text) + "</span>";
        if (open.has(String(i))) d.classList.add("open");
        d.onclick = () => d.classList.toggle("open");
      } else d.innerHTML = '<div class="who">' + esc(a.name || "") + '</div><div class="bub">' + md(it.text, it.files) + "</div>";
      log.appendChild(d);
    });
    if (c.live) { const d = document.createElement("div"); d.className = "live"; d.textContent = c.live; log.appendChild(d); }
    if (c.menu) {
      const m = document.createElement("div"); m.className = "menu";
      m.innerHTML = "<b>" + esc(c.menuQuestion || "선택해 주세요") + "</b>" + (c.menuContext ? "<pre>" + esc(c.menuContext) + "</pre>" : "");
      c.menu.forEach((o, i) => {
        const b = document.createElement("button");
        b.innerHTML = (i + 1) + ". " + esc(o.label) + (o.detail ? "<small>" + esc(o.detail) + "</small>" : "");
        b.onclick = async () => {
          if (!o.free) return this.choose(i);
          const t = ((await ask("직접 입력", { input: "" })) || "").trim(); if (t) this.choose(i, t);
        };
        m.appendChild(b);
      });
      log.appendChild(m);
    }
    log.querySelectorAll(".code button").forEach(b => b.onclick = e => {
      e.stopPropagation(); navigator.clipboard.writeText(b.nextElementSibling.textContent).then(() => toast("복사함"), () => {});
    });
    this.el.screen.style.display = this.screen && c.screen ? "" : "none"; this.el.screen.textContent = c.screen || "";
    // Keys act on what the terminal shows: offered while a menu is up or the screen is open.
    this.el.keys.innerHTML = c.menu || this.screen ? [["Up", "↑"], ["Down", "↓"], ["Left", "←"], ["Right", "→"], ["Tab", "Tab"], ["Enter", "⏎"], ["Escape", "Esc"], ["1", "1"], ["2", "2"], ["3", "3"]]
      .map(([k, l]) => '<button class="btn small" data-k="' + k + '">' + l + "</button>").join("") : "";
    this.el.keys.querySelectorAll("button").forEach(b => b.onclick = () => this.key(b.dataset.k));
    this.el.usage.innerHTML = usageHTML(c.usage);
    if (stick || !log.dataset.seen) log.scrollTop = log.scrollHeight;
    log.dataset.seen = 1;
  }
  async send() {
    const ta = this.el.ta, text = ta.value.trim(); if (!text) return;
    ta.value = ""; ta.oninput();
    const r = await api("/api/send", { id: this.id, text }).catch(() => ({}));
    if (!r.ok) { ta.value = text; ta.oninput(); toast("보내지 못함"); }
    this.poll();
  }
  async choose(i, text) {
    const r = await api("/api/choose", text ? { id: this.id, index: i, text } : { id: this.id, index: i }).catch(() => ({}));
    if (!r.ok) toast("선택하지 못함");
    this.poll();
  }
  key(k) { api("/api/key", { id: this.id, key: k }).then(() => this.poll(), () => {}); }
  async upload(files) {
    for (const f of files) {
      if (f.size > 25 * 1024 * 1024) { toast("25MB보다 큰 파일은 보낼 수 없음"); continue; }
      this.el.notice.textContent = "올리는 중… " + (f.name || "");
      const r = await fetch("/api/upload?name=" + encodeURIComponent(f.name || "paste.png"), { method: "POST", headers: { "Content-Type": "application/octet-stream" }, body: f, credentials: "same-origin" }).catch(() => null);
      const j = r && r.ok ? await r.json().catch(() => ({})) : {};
      this.el.notice.textContent = j.path ? "" : "올리지 못함: " + (f.name || "");
      if (j.path) { const ta = this.el.ta; ta.value += (ta.value && !/\s$/.test(ta.value) ? " " : "") + j.path + " "; ta.oninput(); }
    }
    this.el.ta.focus();
  }
  async action(k) {
    const a = this.agent(); if (!a) return;
    if (k === "close") return this.opts.onClose ? this.opts.onClose() : go("world");
    if (k === "expand") return this.opts.onExpand && this.opts.onExpand();
    if (k === "terminal") return go("session", a.id, "terminal");
    if (k === "attach") return this.el.file.click();
    if (k === "mic") return macOnly("받아쓰기");
    if (k === "read") return macOnly("답변 읽어 주기");
    if (k === "voice") return macOnly("Codex 음성 대화");
    if (k === "screen") {
      this.screen = !this.screen; this.host.querySelector('[data-a="screen"]').classList.toggle("on", this.screen);
      this.lastKey = ""; return this.poll();
    }
    if (k === "clear") {
      if (!(await ask("새 대화 (/clear)", { text: "이 Claude 세션을 새 대화로 다시 시작할까요?", yes: "새 대화" }))) return;
      const r = await api("/api/action", { id: a.id, action: "clear" }).catch(() => ({}));
      toast(r.ok ? "새 대화를 시작함" : (r.message || "실패함"));
    }
  }
}
Dialogue.current = null;
function usageHTML(u) {  // UsageLine
  if (!u) return "";
  const color = p => p >= 80 ? "#ff453a" : p >= 50 ? "#ffd60a" : "#30d158";
  const tok = n => n >= 1e6 ? (n % 1e6 === 0 ? n / 1e6 : (n / 1e6).toFixed(1)) + "M" : n >= 1000 ? Math.floor(n / 1000) + "k" : String(n);
  const left = r => {
    const s = Math.floor(r - Date.now() / 1000); if (s <= 0) return "";
    const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    return d > 0 ? d + "일" + h + "h" : h > 0 ? h + "h" + String(m).padStart(2, "0") + "m" : m + "m";
  };
  let out = "";
  if (u.model) out += '<span><span class="m">◆ ' + esc(u.model) + "</span>" + (u.effort ? " · " + esc(u.effort) : "") + "</span>";
  if (u.contextUsed != null) out += "<span>컨텍스트 " + (u.contextPercent != null
    ? '<span style="color:' + color(u.contextPercent) + '">' + tok(u.contextUsed) + "/" + tok(u.contextWindow || 0) + " " + Math.round(u.contextPercent) + "%</span>" : tok(u.contextUsed)) + "</span>";
  for (const l of u.limits || []) {
    const f = Math.max(0, Math.min(10, Math.floor(l.percent / 10)));
    out += "<span>" + esc(l.label) + ' <span style="color:' + color(l.percent) + '">' + "▰".repeat(f) + '</span><span style="color:#8e8e93">' + "▱".repeat(10 - f) +
      '</span> <span style="color:' + color(l.percent) + '">' + Math.round(l.percent) + "%</span>" + (l.resetsAt && left(l.resetsAt) ? " ↻" + left(l.resetsAt) : "") + "</span>";
  }
  return out;
}

// MARK: terminal — a tmux session as a screen with colors; keys typed into it go to that session.
class TermView {
  constructor(host, name, readOnlySession) {
    this.host = host; this.name = name; this.ro = readOnlySession; this.alive = true; this.last = ""; this.typed = ""; this.chain = Promise.resolve();
    host.innerHTML = '<div class="termbox"><pre class="term" tabindex="0"></pre><textarea class="termIn" autocomplete="off" spellcheck="false"></textarea></div>';
    this.pre = host.querySelector("pre"); this.tin = host.querySelector("textarea");
    this.focus = () => {};
    if (!this.ro) this.wire();
    this.tick();
  }
  stop() { this.alive = false; clearTimeout(this.timer); }
  async tick() {
    clearTimeout(this.timer); if (!this.alive) return;
    try {
      if (this.ro) { const c = await api("/api/chat?id=" + encodeURIComponent(this.ro) + "&screen=1"); this.pre.textContent = c.screen || "화면을 읽을 수 없는 터미널"; }
      else {
        const s = await api("/api/term?name=" + encodeURIComponent(this.name) + "&history=300");
        if (s.error) this.pre.textContent = "터미널이 닫힘";
        else { const k = JSON.stringify(s); if (k !== this.last) { this.last = k; this.render(s); } }
      }
    } catch (e) {}
    if (this.alive) this.timer = setTimeout(() => this.tick(), document.hidden ? 3000 : 600);
  }
  render(s) {
    const el = this.pre, stick = el.scrollTop + el.clientHeight > el.scrollHeight - 30;
    const cur = Math.max(0, s.lines.length - s.height) + s.cy;
    // Blank rows under the cursor would push the prompt out of a viewport shorter than the pane.
    let end = s.lines.length;
    while (end - 1 > cur && !s.lines[end - 1].replace(/\x1b\[[0-9;:]*m/g, "").trim()) end--;
    el.innerHTML = s.lines.slice(0, end).map((l, i) => ansi(l, i === cur ? s.cx : -1)).join("\n");
    if (stick) el.scrollTop = el.scrollHeight;
  }
  // A hidden textarea takes the keys so Korean IME composition works; text goes in small batches, keys in order.
  wire() {
    const tin = this.tin, pre = this.pre;
    this.focus = () => { if (!getSelection().toString()) { tin.focus(); pre.classList.add("focus"); } };
    pre.onmouseup = this.focus; tin.onblur = () => pre.classList.remove("focus");
    const KEYS = { Enter: "Enter", Tab: "Tab", Backspace: "BSpace", Delete: "DC", Escape: "Escape", ArrowUp: "Up", ArrowDown: "Down",
                   ArrowLeft: "Left", ArrowRight: "Right", Home: "Home", End: "End", PageUp: "PageUp", PageDown: "PageDown" };
    tin.onkeydown = e => {
      if (e.isComposing || e.keyCode === 229) return;
      if (e.key === "Tab" && e.shiftKey) { e.preventDefault(); return this.press("BTab"); }
      if (KEYS[e.key]) { e.preventDefault(); return this.press(KEYS[e.key]); }
      if (e.ctrlKey && !e.altKey && !e.metaKey && /^[a-z]$/i.test(e.key) && e.key.toLowerCase() !== "v") { e.preventDefault(); return this.press("C-" + e.key.toLowerCase()); }
    };
    tin.addEventListener("input", e => { if (e.isComposing || e.inputType === "insertCompositionText") return; if (e.data) this.type(e.data); tin.value = ""; });
    tin.addEventListener("compositionend", e => { if (e.data) this.type(e.data); tin.value = ""; });
    tin.addEventListener("paste", e => { e.preventDefault(); const t = e.clipboardData.getData("text"); if (t) this.type(t); });
  }
  queue(fn) { this.chain = this.chain.then(fn, fn); }
  flush() {
    clearTimeout(this.typeTimer); if (!this.typed) return;
    const text = this.typed, name = this.name; this.typed = "";
    this.queue(() => api("/api/term-input", { name, text }).catch(() => {}));
  }
  type(t) { this.typed += t; clearTimeout(this.typeTimer); this.typeTimer = setTimeout(() => { this.flush(); setTimeout(() => this.tick(), 80); }, 25); }
  press(k) { this.flush(); const name = this.name; this.queue(() => api("/api/term-input", { name, key: k }).catch(() => {})); setTimeout(() => this.tick(), 120); }
}
const TPAL = ["#000000", "#ff5f56", "#27c93f", "#ffbd2e", "#3b82f6", "#c678dd", "#56b6c2", "#d0d0d0", "#6e6e6e", "#ff7b72", "#7ee2a8", "#f0c674", "#79b8ff", "#d2a8ff", "#76e3ea", "#ffffff"];
function c256(n) {
  if (n < 16) return TPAL[n];
  if (n >= 232) { const v = 8 + (n - 232) * 10; return "rgb(" + v + "," + v + "," + v + ")"; }
  n -= 16; const s = [0, 95, 135, 175, 215, 255];
  return "rgb(" + s[Math.floor(n / 36)] + "," + s[Math.floor(n / 6) % 6] + "," + s[n % 6] + ")";
}
const wide = ch => /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]/.test(ch) || ch.codePointAt(0) > 0xffff;
function ansi(line, cur) {  // tmux capture-pane -e: SGR colors only; other escapes dropped
  line = line.replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "").replace(/\x1b\[[0-9;?]*[A-Za-ln-z]/g, "");
  const parts = line.split(/\x1b\[([0-9;:]*)m/);
  let st = {}, out = "", col = 0;
  for (let p = 0; p < parts.length; p++) {
    if (p % 2) { st = sgr(st, parts[p]); continue; }
    if (!parts[p]) continue;
    let fg = st.fg, bg = st.bg; if (st.inv) [fg, bg] = [bg || "#000", fg || "#e6e6e6"];
    const css = (fg ? "color:" + fg + ";" : "") + (bg ? "background:" + bg + ";" : "") + (st.b ? "font-weight:700;" : "") +
                (st.dim ? "opacity:.6;" : "") + (st.it ? "font-style:italic;" : "") + (st.u ? "text-decoration:underline;" : "");
    let chunk = "";
    for (const ch of parts[p]) { chunk += col === cur ? '<span class="cur">' + esc(ch) + "</span>" : esc(ch); col += wide(ch) ? 2 : 1; }
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
    if (n === 0) st = {}; else if (n === 1) st.b = true; else if (n === 2) st.dim = true; else if (n === 3) st.it = true;
    else if (n === 4) st.u = true; else if (n === 7) st.inv = true; else if (n === 22) { st.b = false; st.dim = false; }
    else if (n === 23) st.it = false; else if (n === 24) st.u = false; else if (n === 27) st.inv = false;
    else if (n >= 30 && n <= 37) st.fg = TPAL[n - 30]; else if (n >= 90 && n <= 97) st.fg = TPAL[n - 82];
    else if (n >= 40 && n <= 47) st.bg = TPAL[n - 40]; else if (n >= 100 && n <= 107) st.bg = TPAL[n - 92];
    else if (n === 39) delete st.fg; else if (n === 49) delete st.bg;
    else if (n === 38 || n === 48) {
      let v = null;
      if (c[i + 1] === 5) { v = c256(c[i + 2]); i += 2; } else if (c[i + 1] === 2) { v = "rgb(" + c[i + 2] + "," + c[i + 3] + "," + c[i + 4] + ")"; i += 4; }
      if (v) st[n === 38 ? "fg" : "bg"] = v;
    }
  }
  return st;
}
function mountSessionTerminal(pane, a) {
  pane.innerHTML = '<div class="tpage"><div class="thead">' + pillHTML(a) + '<span class="t">' + esc(a.title) + '</span><span class="mono" style="color:var(--muted);font-size:12px">' + esc(a.project) +
    '</span><span class="sp"></span>' + (a.term ? "" : '<span style="color:var(--muted);font-size:12px">다른 터미널에서 실행 중인 세션 — 화면 보기만 가능</span>') +
    '<button class="btn small" data-back>대화로</button></div><div class="tbox" style="flex:1;min-height:0;display:flex"></div></div>';
  pane.querySelector("[data-back]").onclick = () => go("session", a.id, "dialogue");
  const t = new TermView(pane.querySelector(".tbox"), a.term, a.term ? null : a.id);
  setTimeout(t.focus, 0);
  cleanup.push(() => t.stop());
}
function mountShell(pane, name) {
  pane.innerHTML = '<div class="tpage"><div class="thead">' + ic("term") + '<span class="t">' + esc(termTitle(name)) + '</span><span class="sp"></span></div><div class="tbox" style="flex:1;min-height:0;display:flex"></div></div>';
  const t = new TermView(pane.querySelector(".tbox"), name);
  setTimeout(t.focus, 0);
  cleanup.push(() => t.stop());
}
// Bottom panel terminal (BottomTerminal: ⌘` on the Mac, Ctrl+` here): 수혁's panel shell.
let bottom = null;
addEventListener("keydown", e => {
  if (!(e.ctrlKey && (e.key === "`" || e.code === "Backquote"))) return;
  e.preventDefault();
  const b = $("bottom");
  if (bottom) { bottom.stop(); bottom = null; b.classList.remove("open"); b.innerHTML = ""; sizeWorld(); return; }
  b.classList.add("open"); sizeWorld();
  if (!(S.side && S.side.panel)) { b.innerHTML = '<div class="hint" style="padding:14px">패널 터미널이 꺼져 있음 — Mac의 수혁에서 ⌘`로 연 뒤 사용</div>'; bottom = { stop() {} }; return; }
  bottom = new TermView(b, "suhyeok-panel"); setTimeout(bottom.focus, 0);
});

// MARK: new session (NewSessionSheet)
$("newBtn").onclick = async () => {
  const f = await api("/api/folders").catch(() => null); if (!f) return;
  const pending = ask("새 세션", { yes: "시작" });
  $("askBody").innerHTML =
    '<label>에이전트<select id="nAgent"><option>Claude</option><option>Codex</option><option>Antigravity</option></select></label>' +
    '<label>작업 폴더<input id="nCwd" list="nFolders"><datalist id="nFolders">' + (f.folders || []).map(d => '<option value="' + esc(d) + '">').join("") + "</datalist></label>" +
    '<label>첫 지시 (비워도 됨)<textarea id="nPrompt" rows="3"></textarea></label>';
  $("nCwd").value = (f.folders || [])[0] || f.home || "";
  if (!(await pending)) return;
  const r = await api("/api/new", { agent: $("nAgent").value, cwd: $("nCwd").value.trim(), prompt: $("nPrompt").value }).catch(() => ({}));
  toast(r.ok ? "시작함" : (r.message || "실패함")); setTimeout(refreshSide, 1500);
};

// MARK: loops — state for the map and the dialogue, the sidebar, and events (asking / done) as toasts.
async function refresh() {
  try {
    const s = await api("/api/state");
    $("pair").classList.remove("show");
    S.agents = s.agents || []; S.bosses = s.bosses || []; S.world = s.world || S.world; S.avatar = s.avatar || S.avatar; S.crystals = s.crystals || 0;
    S.lastRefresh = Date.now() / 1000;
    if (W) W.updateOverlays();
    if (Dialogue.current) Dialogue.current.update();
    if (S.pane === "session") $("title").textContent = (S.agents.find(x => x.id === S.sel) || {}).title || "종료된 세션";
  } catch (e) {}
}
let boot = null, seq = 0, unread = 0;
async function events() {
  try {
    const e = await api("/api/events?boot=" + encodeURIComponent(boot || "") + "&after=" + seq);
    if (boot === e.boot) for (const ev of e.events) {
      const line = ev.name + ": " + (ev.text || ev.title || "");
      toast(line, () => go("session", ev.id, "dialogue"));
      if (document.hidden) {
        unread++; document.title = "(" + unread + ") 수혁";
        try { if (window.Notification && Notification.permission === "granted") new Notification("수혁", { body: line }); } catch (x) {}
      }
    }
    boot = e.boot; seq = e.seq;
  } catch (x) {}
  setTimeout(events, 3000);
}
document.addEventListener("visibilitychange", () => { if (!document.hidden) { unread = 0; document.title = "수혁"; } });
document.addEventListener("click", () => { try { if (window.Notification && Notification.permission === "default") Notification.requestPermission(); } catch (x) {} }, { once: true });
function loops() {
  const a = () => refresh().finally(() => setTimeout(a, document.hidden ? 5000 : 1500));
  const b = () => refreshSide().finally(() => setTimeout(b, document.hidden ? 8000 : 3000));
  a(); b(); events();
}
if (store.get("side", true) === false) { $("app").classList.add("noside"); $("sideBtn2").style.display = ""; }
renderSide();
const pm = location.hash.match(/^#pair=([0-9a-f]{32})$/);
if (pm) { history.replaceState(null, "", location.pathname + "#world"); pair(pm[1]).finally(() => { fromHash(); loops(); }); }
else refresh().then(() => { fromHash(); loops(); });
</script>
</body></html>
"""#
    }
}
