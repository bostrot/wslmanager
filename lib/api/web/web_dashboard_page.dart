// The web dashboard, embedded as one self-contained HTML document: no
// external scripts, fonts or images, so it renders on a phone over a LAN
// with no internet access and ships inside the binary rather than as
// loose files. Served by WebDashboardService at `/`.
//
// The page keeps the access token in its own URL (`?token=`) and forwards
// it on every API call, so a scanned QR code or a shared link is all a
// visitor needs. Everything beyond the instance list and start/stop goes
// through `/api/tools/<name>` — the MCP tool set — so the dashboard can do
// whatever the desktop app's AI tools and MCP clients can. The Assistant tab
// is the app's AI chat itself (`/api/chat`, ai-tasks#83): one shared
// transcript, polled while the tab is open because a run outlives what a
// phone keeps a single request open for.

/// Shown when the token is missing or wrong. Deliberately says nothing
/// about the app beyond its name.
const String webDashboardUnauthorizedHtml = r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>WSL Manager</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:#0f1117;color:#e6e8ef}
.box{max-width:420px;padding:32px;border:1px solid #262a36;border-radius:16px;background:#161923;text-align:center}
h1{font-size:20px;margin:0 0 8px}p{margin:0;color:#9aa3b5;line-height:1.5}
</style></head><body><div class="box"><h1>This link is not valid</h1>
<p>The dashboard needs the access token that is part of the link shown in WSL Manager &rarr; Settings &rarr; Web Dashboard. Scan the QR code there or copy the full link.</p>
</div></body></html>''';

/// The dashboard itself.
const String webDashboardHtml = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="dark light">
<meta name="referrer" content="no-referrer">
<title>WSL Manager</title>
<style>
:root{
  --bg:#0f1117;--bg-2:#161923;--bg-3:#1d2130;--line:#262a36;--line-2:#333848;
  --text:#e6e8ef;--muted:#9aa3b5;--faint:#6b7386;
  --accent:#5b8cff;--accent-2:#3f6fe8;--accent-soft:rgba(91,140,255,.16);
  --ok:#3ddc97;--ok-soft:rgba(61,220,151,.16);--warn:#ffb454;--danger:#ff5d6c;--danger-soft:rgba(255,93,108,.14);
  --radius:14px;--shadow:0 10px 30px rgba(0,0,0,.35);
}
@media (prefers-color-scheme:light){
  :root{--bg:#f3f5f9;--bg-2:#ffffff;--bg-3:#eef1f7;--line:#dde2ec;--line-2:#c9d0de;--text:#161a25;--muted:#5b6478;--faint:#8b93a6;
  --accent-soft:rgba(91,140,255,.14);--shadow:0 10px 30px rgba(20,30,60,.10)}
}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,Inter,sans-serif;-webkit-font-smoothing:antialiased}
button,input,select,textarea{font:inherit;color:inherit}
a{color:var(--accent)}
code,pre,.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace}
.wrap{max-width:1180px;margin:0 auto;padding:18px 16px 40px}

header{position:sticky;top:0;z-index:20;backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);background:color-mix(in srgb,var(--bg) 82%,transparent);border-bottom:1px solid var(--line)}
.bar{display:flex;align-items:center;gap:14px;padding:12px 16px;max-width:1180px;margin:0 auto}
.logo{width:36px;height:36px;border-radius:10px;background:linear-gradient(135deg,var(--accent),#8f5bff);display:grid;place-items:center;flex:none;box-shadow:0 6px 18px rgba(91,140,255,.35)}
.logo svg{width:20px;height:20px}
.title{font-weight:700;font-size:17px;letter-spacing:.2px;white-space:nowrap}
.sub{font-size:12px;color:var(--muted);display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.chip{display:inline-flex;align-items:center;gap:6px;padding:2px 9px;border-radius:999px;background:var(--bg-3);border:1px solid var(--line);font-size:12px;color:var(--muted);white-space:nowrap}
.dot{width:8px;height:8px;border-radius:50%;background:var(--faint);flex:none}
.dot.on{background:var(--ok);box-shadow:0 0 0 3px var(--ok-soft)}
.dot.err{background:var(--danger);box-shadow:0 0 0 3px var(--danger-soft)}
.grow{flex:1}
.iconbtn{width:38px;height:38px;border-radius:10px;border:1px solid var(--line);background:var(--bg-2);display:grid;place-items:center;cursor:pointer;color:var(--muted)}
.iconbtn:hover{color:var(--text);border-color:var(--line-2)}
.iconbtn svg{width:18px;height:18px}
.iconbtn.spin svg{animation:spin .8s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}

nav.tabs{display:flex;gap:4px;max-width:1180px;margin:0 auto;padding:0 12px 10px;overflow-x:auto;scrollbar-width:none}
nav.tabs::-webkit-scrollbar{display:none}
nav.tabs button{border:0;background:transparent;color:var(--muted);padding:8px 14px;border-radius:10px;cursor:pointer;font-weight:600;white-space:nowrap}
nav.tabs button.active{background:var(--accent-soft);color:var(--accent)}
nav.tabs button .n{margin-left:6px;font-size:11px;padding:1px 6px;border-radius:999px;background:var(--bg-3);color:var(--muted)}

section[hidden]{display:none}
.toolbar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:16px}
.toolbar h2{margin:0;font-size:20px}
.search{flex:1;min-width:180px;position:relative}
.search input{width:100%;padding:10px 12px 10px 38px;border-radius:12px;border:1px solid var(--line);background:var(--bg-2);outline:none}
.search input:focus{border-color:var(--accent)}
.search svg{position:absolute;left:12px;top:11px;width:18px;height:18px;color:var(--faint)}

.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:9px 14px;border-radius:10px;border:1px solid var(--line);background:var(--bg-2);cursor:pointer;font-weight:600;transition:.15s;white-space:nowrap}
.btn:hover{border-color:var(--line-2);background:var(--bg-3)}
.btn:disabled{opacity:.5;cursor:default}
.btn.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.btn.primary:hover{background:var(--accent-2)}
.btn.danger{color:var(--danger);border-color:color-mix(in srgb,var(--danger) 40%,var(--line))}
.btn.danger:hover{background:var(--danger-soft)}
.btn.ghost{background:transparent}
.btn.sm{padding:6px 10px;font-size:13px;border-radius:8px}
.btn svg{width:16px;height:16px}

.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:14px}
.card{background:var(--bg-2);border:1px solid var(--line);border-radius:var(--radius);padding:16px;display:flex;flex-direction:column;gap:12px;position:relative;transition:.15s}
.card:hover{border-color:var(--line-2);box-shadow:var(--shadow)}
.card.running{border-color:color-mix(in srgb,var(--ok) 35%,var(--line))}
.card .head{display:flex;align-items:center;gap:10px}
.avatar{width:42px;height:42px;border-radius:12px;display:grid;place-items:center;font-weight:800;font-size:16px;color:#fff;flex:none;letter-spacing:.5px}
.card .name{font-weight:700;font-size:16px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.card .meta{font-size:12px;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.pill{display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:600;padding:3px 9px;border-radius:999px;background:var(--bg-3);color:var(--muted);flex:none}
.pill.on{background:var(--ok-soft);color:var(--ok)}
.pill .dot{width:6px;height:6px}
.card .path{font-size:12px;color:var(--faint);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.card .actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:auto}
.menu{position:relative}
.menu .list{position:absolute;right:0;top:calc(100% + 6px);min-width:180px;background:var(--bg-2);border:1px solid var(--line);border-radius:12px;box-shadow:var(--shadow);padding:6px;z-index:10;display:none}
.menu.open .list{display:block}
.menu .list button{display:block;width:100%;text-align:left;padding:9px 12px;border:0;background:transparent;border-radius:8px;cursor:pointer}
.menu .list button:hover{background:var(--bg-3)}
.menu .list button.danger{color:var(--danger)}
.empty{padding:48px 20px;text-align:center;color:var(--muted);border:1px dashed var(--line);border-radius:var(--radius)}
.empty b{display:block;color:var(--text);margin-bottom:6px;font-size:16px}

.panel{background:var(--bg-2);border:1px solid var(--line);border-radius:var(--radius);padding:16px}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
.field{display:flex;flex-direction:column;gap:6px;min-width:0}
.field label{font-size:12px;color:var(--muted);font-weight:600}
.field small{color:var(--faint);font-size:11px}
input[type=text],input[type=number],select,textarea{padding:9px 12px;border-radius:10px;border:1px solid var(--line);background:var(--bg);outline:none;width:100%;min-width:0}
input:focus,select:focus,textarea:focus{border-color:var(--accent)}
textarea{min-height:90px;resize:vertical}
.out{margin:12px 0 0;padding:12px;border-radius:10px;background:var(--bg);border:1px solid var(--line);white-space:pre-wrap;word-break:break-word;max-height:360px;overflow:auto;font-size:13px}
.out.err{border-color:color-mix(in srgb,var(--danger) 40%,var(--line))}
.out:empty{display:none}

.term{background:#0b0d13;color:#d7e0ea;border-radius:12px;border:1px solid var(--line);padding:12px;height:min(52vh,480px);overflow:auto;white-space:pre-wrap;word-break:break-word;font-size:13px;line-height:1.4}
@media (prefers-color-scheme:light){.term{background:#111520}}
.term:empty::before{content:"Start a session to see output here.";color:#5b6478}
.termbar{display:flex;gap:8px;margin-top:10px}
.termbar input{flex:1}
.sessions{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px}
.sessions .chip{cursor:pointer;padding:6px 12px}
.sessions .chip.active{border-color:var(--accent);color:var(--accent);background:var(--accent-soft)}

.tool{border:1px solid var(--line);border-radius:12px;background:var(--bg-2);margin-bottom:8px;overflow:hidden}
.tool>button.h{display:flex;width:100%;align-items:center;gap:10px;padding:12px 14px;border:0;background:transparent;text-align:left;cursor:pointer}
.tool>button.h .nm{font-weight:700}
.tool>button.h .ds{color:var(--muted);font-size:13px;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tool .body{display:none;padding:0 14px 14px;border-top:1px solid var(--line)}
.tool.open .body{display:block}
.tool .body .ds{color:var(--muted);font-size:13px;margin:12px 0}
.tool .form{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:10px}
.tool .form .full{grid-column:1/-1}
.group{margin:22px 0 10px;font-size:12px;letter-spacing:1px;text-transform:uppercase;color:var(--faint);font-weight:700}

.snip{display:flex;gap:12px;align-items:flex-start}
.snip pre{margin:6px 0 0;padding:10px;border-radius:8px;background:var(--bg);border:1px solid var(--line);font-size:12px;max-height:120px;overflow:auto;white-space:pre-wrap}

.overlay{position:fixed;inset:0;background:rgba(5,7,12,.6);display:none;align-items:flex-end;justify-content:center;z-index:50;padding:12px}
.overlay.open{display:flex}
@media (min-width:640px){.overlay{align-items:center}}
.modal{width:min(640px,100%);max-height:90vh;overflow:auto;background:var(--bg-2);border:1px solid var(--line);border-radius:18px;padding:20px;box-shadow:var(--shadow)}
.modal h3{margin:0 0 12px;font-size:18px}
.modal .foot{display:flex;gap:8px;justify-content:flex-end;margin-top:16px}

.toasts{position:fixed;left:50%;bottom:18px;transform:translateX(-50%);display:flex;flex-direction:column;gap:8px;z-index:60;width:min(520px,calc(100% - 24px))}
.toast{padding:12px 14px;border-radius:12px;background:var(--bg-2);border:1px solid var(--line);box-shadow:var(--shadow);font-size:14px;animation:up .2s ease-out}
.toast.ok{border-color:color-mix(in srgb,var(--ok) 45%,var(--line))}
.toast.err{border-color:color-mix(in srgb,var(--danger) 55%,var(--line))}
@keyframes up{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}
.skeleton{height:120px;border-radius:var(--radius);background:linear-gradient(90deg,var(--bg-2),var(--bg-3),var(--bg-2));background-size:200% 100%;animation:sh 1.2s infinite}
@keyframes sh{to{background-position:-200% 0}}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin-bottom:18px}
.stat{padding:12px 14px;border-radius:12px;background:var(--bg-2);border:1px solid var(--line)}
.stat b{display:block;font-size:22px;font-weight:800}
.stat span{font-size:12px;color:var(--muted)}
.hint{font-size:13px;color:var(--muted);margin:0 0 14px}
[hidden]{display:none!important}

.chatlog{display:flex;flex-direction:column;gap:10px;padding:14px;background:var(--bg-2);border:1px solid var(--line);border-radius:var(--radius);height:min(60vh,560px);overflow:auto;overscroll-behavior:contain}
.chatlog .empty{margin:auto 0}
.msg{display:flex}
.msg.user{justify-content:flex-end}
.msg .bubble{max-width:min(85%,640px);padding:10px 13px;border-radius:14px;white-space:pre-wrap;word-break:break-word;font-size:14px;line-height:1.45}
.msg.user .bubble{background:var(--accent);color:#fff;border-bottom-right-radius:4px}
.msg.assistant .bubble{background:var(--bg-3);border:1px solid var(--line);border-bottom-left-radius:4px}
.msg.assistant .bubble.live{border-style:dashed}
.msg .bubble pre{margin:8px 0;padding:10px;border-radius:8px;background:var(--bg);border:1px solid var(--line);font-size:12px;overflow:auto;white-space:pre-wrap}
.msg.user .bubble pre{background:rgba(0,0,0,.25);border-color:transparent;color:#fff}
.msg .bubble code{font-size:13px;padding:1px 5px;border-radius:5px;background:rgba(127,127,127,.18)}
.msg.note{font-size:12px;color:var(--faint);padding:0 4px;gap:6px;align-items:center}
.msg.note .link{border:0;background:transparent;color:var(--accent);cursor:pointer;padding:0;font-size:12px;text-decoration:underline}
.chatstatus{display:flex;align-items:center;gap:10px;margin-top:10px;font-size:13px;color:var(--muted)}
.spinner{width:14px;height:14px;border-radius:50%;border:2px solid var(--line-2);border-top-color:var(--accent);animation:spin .8s linear infinite;flex:none}
.notice{padding:10px 12px;border-radius:10px;border:1px solid color-mix(in srgb,var(--warn) 45%,var(--line));background:color-mix(in srgb,var(--warn) 10%,var(--bg-2));font-size:13px;margin-bottom:12px;display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.notice.err{border-color:color-mix(in srgb,var(--danger) 45%,var(--line));background:color-mix(in srgb,var(--danger) 8%,var(--bg-2))}
.composer{display:flex;gap:8px;margin-top:10px;align-items:flex-end}
.composer textarea{flex:1;min-height:42px;max-height:160px;resize:none}
</style>
</head>
<body>
<header>
  <div class="bar">
    <div class="logo" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="14" rx="3"/><path d="M7 9l3 2.5L7 14M12 14h5"/></svg></div>
    <div>
      <div class="title">WSL Manager</div>
      <div class="sub" id="hostline"><span class="chip"><span class="dot" id="conn"></span><span id="connText">connecting…</span></span></div>
    </div>
    <div class="grow"></div>
    <button class="iconbtn" id="refresh" title="Refresh" aria-label="Refresh"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/></svg></button>
  </div>
  <nav class="tabs" id="tabs">
    <button data-tab="instances" class="active">Instances<span class="n" id="nInst">–</span></button>
    <button data-tab="chat">Assistant<span class="n" id="nChat">–</span></button>
    <button data-tab="terminal">Terminal<span class="n" id="nSess">0</span></button>
    <button data-tab="snippets" id="tabSnippets">Snippets<span class="n" id="nSnip">–</span></button>
    <button data-tab="tools">Tools<span class="n" id="nTools">–</span></button>
  </nav>
</header>

<main class="wrap">
  <section id="instances">
    <div class="stats" id="stats"></div>
    <div class="toolbar">
      <h2 id="instTitle">Instances</h2>
      <div class="search"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg><input id="q" type="search" placeholder="Filter…" autocomplete="off"></div>
      <button class="btn danger" id="shutdownAll">Stop all</button>
    </div>
    <div class="grid" id="cards"><div class="skeleton"></div><div class="skeleton"></div><div class="skeleton"></div></div>
  </section>

  <section id="chat" hidden>
    <div class="toolbar"><h2>Assistant</h2><span class="chip" id="chatModel" hidden></span><div class="grow"></div><button class="btn sm ghost" id="chatClear" disabled>Clear chat</button></div>
    <p class="hint">The app's AI assistant, with the same tools and the same conversation as on the desktop: tell it to start, inspect or set up your instances from here. It runs on the API key configured in the app.</p>
    <div class="notice" id="chatNotice" hidden></div>
    <div class="chatlog" id="chatLog"></div>
    <div class="chatstatus" id="chatStatus" hidden><span class="spinner"></span><span id="chatStatusText">Working…</span><div class="grow"></div><button class="btn sm danger" id="chatStop">Stop</button></div>
    <div class="composer">
      <textarea id="chatIn" rows="1" placeholder="Ask the assistant… (Enter sends, Shift+Enter for a new line)" autocomplete="off" autocapitalize="sentences"></textarea>
      <button class="btn primary" id="chatSend" disabled>Send</button>
    </div>
  </section>

  <section id="terminal" hidden>
    <div class="toolbar"><h2>Terminal</h2></div>
    <p class="hint">A persistent shell inside an instance. Output is polled, so interactive programs that need a real TTY may misbehave — use <b>Kill</b> to unstick one.</p>
    <div class="panel">
      <div class="row" style="margin-bottom:12px">
        <div class="field" style="flex:1;min-width:160px"><label>Instance</label><select id="termDistro"></select></div>
        <div class="field" style="width:140px"><label>User</label><input type="text" id="termUser" placeholder="root"></div>
        <div class="field"><label>&nbsp;</label><button class="btn primary" id="termStart">New session</button></div>
      </div>
      <div class="sessions" id="sessions"></div>
      <div class="term" id="termOut"></div>
      <div class="termbar">
        <input type="text" id="termIn" class="mono" placeholder="Type a command and press Enter" autocomplete="off" autocapitalize="off" spellcheck="false">
        <button class="btn primary" id="termSend">Send</button>
      </div>
      <div class="row" style="margin-top:10px">
        <button class="btn sm" data-sig="ctrl-c">Ctrl-C</button>
        <button class="btn sm" data-sig="ctrl-d">Ctrl-D</button>
        <button class="btn sm danger" data-sig="kill">Kill</button>
        <button class="btn sm ghost" id="termClose">Close session</button>
      </div>
    </div>
  </section>

  <section id="snippets" hidden>
    <div class="toolbar"><h2>Snippets</h2><div class="grow"></div><button class="btn primary" id="snipNew">New snippet</button></div>
    <p class="hint">Saved scripts from the app's Quick Actions. Run one inside any instance as root.</p>
    <div id="snipList"></div>
  </section>

  <section id="tools" hidden>
    <div class="toolbar">
      <h2>All tools</h2>
      <div class="search"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg><input id="tq" type="search" placeholder="Search tools…" autocomplete="off"></div>
    </div>
    <p class="hint">Everything the app can do, as forms: import, export, packaging, configuration, disks, and more. This is the same tool set the app's AI assistant and MCP clients use.</p>
    <div id="toolList"></div>
  </section>
</main>

<div class="overlay" id="overlay"><div class="modal" id="modal"></div></div>
<div class="toasts" id="toasts"></div>
<datalist id="distroList"></datalist>

<script>
(() => {
const TOKEN = new URLSearchParams(location.search).get('token') || '';
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

let state = {host:{features:{}}, instances:[], sessions:[], snippets:[]};
let tools = [];
let filter = '', toolFilter = '';
let activeSession = null, termTimer = null;
let unauthorized = false;

// ---- transport -----------------------------------------------------------
async function api(path, opts = {}) {
  const url = path + (path.includes('?') ? '&' : '?') + 'token=' + encodeURIComponent(TOKEN);
  const res = await fetch(url, {
    method: opts.method || 'GET',
    headers: {'content-type': 'application/json', 'x-dashboard-token': TOKEN},
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  if (res.status === 403) { unauthorized = true; setConn('err', 'link not valid'); throw new Error('This link is not valid any more. Open the dashboard from WSL Manager → Settings → Web Dashboard.'); }
  const data = await res.json().catch(() => ({}));
  if (!res.ok && data.error) throw new Error(data.error);
  return data;
}
async function callTool(name, args = {}) {
  const r = await api('/api/tools/' + encodeURIComponent(name), {method: 'POST', body: {arguments: args}});
  if (!r.ok) throw new Error(r.error || 'Failed');
  return r.text || '';
}
function setConn(cls, text) { const d = $('#conn'); d.className = 'dot ' + cls; $('#connText').textContent = text; }

// ---- toasts & modal --------------------------------------------------------
function toast(msg, kind = '') {
  const el = document.createElement('div'); el.className = 'toast ' + kind; el.textContent = msg;
  $('#toasts').appendChild(el); setTimeout(() => el.remove(), kind === 'err' ? 7000 : 3500);
}
function modal(html) { $('#modal').innerHTML = html; $('#overlay').classList.add('open'); }
function closeModal() { $('#overlay').classList.remove('open'); $('#modal').innerHTML = ''; }
$('#overlay').addEventListener('click', e => { if (e.target === $('#overlay')) closeModal(); });
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeModal(); });
function confirmDialog(title, body, okLabel = 'Continue', danger = true) {
  return new Promise(resolve => {
    modal(`<h3>${esc(title)}</h3><p style="color:var(--muted);margin:0">${esc(body)}</p>
      <div class="foot"><button class="btn" id="mCancel">Cancel</button><button class="btn ${danger ? 'danger' : 'primary'}" id="mOk">${esc(okLabel)}</button></div>`);
    $('#mCancel').onclick = () => { closeModal(); resolve(false); };
    $('#mOk').onclick = () => { closeModal(); resolve(true); };
  });
}
async function busy(btn, fn) {
  const old = btn.textContent; btn.disabled = true; btn.textContent = 'Working…';
  try { return await fn(); }
  catch (e) { toast(e.message || String(e), 'err'); }
  finally { btn.disabled = false; btn.textContent = old; }
}

// ---- state ----------------------------------------------------------------
async function refresh(spin = false) {
  if (unauthorized) return;
  const b = $('#refresh'); if (spin) b.classList.add('spin');
  try {
    state = await api('/api/state');
    setConn('on', state.host.name || 'connected');
    renderHost(); renderInstances(); renderSessions(); renderSnippets();
    if (state.error) toast(state.error, 'err');
  } catch (e) {
    if (unauthorized) { if (!refresh.warned) { refresh.warned = true; toast(e.message, 'err'); } }
    else setConn('err', 'unreachable');
  } finally { b.classList.remove('spin'); }
}
async function loadTools() {
  try { tools = (await api('/api/tools')).tools || []; $('#nTools').textContent = tools.length; renderTools(); }
  catch (e) { /* surfaced by refresh */ }
}

function renderHost() {
  const h = state.host || {};
  const noun = (h.instanceNoun || 'instance');
  $('#instTitle').textContent = noun.charAt(0).toUpperCase() + noun.slice(1) + 's';
  const chips = [`<span class="chip"><span class="dot on" id="conn"></span><span id="connText">${esc(h.name || 'connected')}</span></span>`];
  if (h.backend) chips.push(`<span class="chip">${esc(h.backend === 'wsl' ? 'WSL' : h.backend)}${h.remote ? ' · remote ' + esc(h.remoteLabel) : ''}</span>`);
  if (h.platform) chips.push(`<span class="chip">${esc(h.platform)}</span>`);
  if (h.version) chips.push(`<span class="chip">v${esc(h.version)}</span>`);
  $('#hostline').innerHTML = chips.join('');
  $('#tabSnippets').hidden = !(h.features && h.features.quickActions);
  const running = state.instances.filter(i => i.running).length;
  $('#stats').innerHTML = `
    <div class="stat"><b>${state.instances.length}</b><span>${esc(noun)}s</span></div>
    <div class="stat"><b style="color:var(--ok)">${running}</b><span>running</span></div>
    <div class="stat"><b>${state.sessions.length}</b><span>open terminals</span></div>
    <div class="stat"><b>${h.toolCount ?? '–'}</b><span>tools available</span></div>`;
}

const hue = s => { let h = 0; for (const c of s) h = (h * 31 + c.charCodeAt(0)) >>> 0; return h % 360; };
function renderInstances() {
  $('#nInst').textContent = state.instances.length;
  const list = state.instances.filter(i => i.name.toLowerCase().includes(filter));
  const noun = state.host.instanceNoun || 'instance';
  $('#distroList').innerHTML = state.instances.map(i => `<option value="${esc(i.name)}">`).join('');
  if (!list.length) {
    $('#cards').innerHTML = `<div class="empty" style="grid-column:1/-1"><b>${state.instances.length ? 'Nothing matches' : 'No ' + esc(noun) + 's yet'}</b>${state.instances.length ? 'Try a different filter.' : 'Create or import one from the Tools tab.'}</div>`;
    return;
  }
  $('#cards').innerHTML = list.map(i => `
    <div class="card ${i.running ? 'running' : ''}" data-name="${esc(i.name)}">
      <div class="head">
        <div class="avatar" style="background:linear-gradient(135deg,hsl(${hue(i.name)} 70% 55%),hsl(${(hue(i.name) + 40) % 360} 70% 45%))">${esc(i.name.slice(0, 2).toUpperCase())}</div>
        <div style="min-width:0;flex:1"><div class="name" title="${esc(i.name)}">${esc(i.name)}</div><div class="meta">${esc(i.meta || '')}</div></div>
        <span class="pill ${i.running ? 'on' : ''}"><span class="dot ${i.running ? 'on' : ''}"></span>${i.running ? 'Running' : 'Stopped'}</span>
      </div>
      ${i.path ? `<div class="path" title="${esc(i.path)}">${esc(i.path)}</div>` : ''}
      <div class="actions">
        <button class="btn sm ${i.running ? '' : 'primary'}" data-act="${i.running ? 'stop' : 'start'}">${i.running ? 'Stop' : 'Start'}</button>
        <button class="btn sm" data-act="run">Run…</button>
        <button class="btn sm" data-act="term">Terminal</button>
        <div class="menu"><button class="btn sm ghost" data-act="menu" aria-label="More">⋯</button>
          <div class="list">
            <button data-act="info">Details</button>
            <button data-act="export">Export…</button>
            <button data-act="copy">Duplicate…</button>
            <button data-act="delete" class="danger">Delete…</button>
          </div></div>
      </div>
    </div>`).join('');
}

$('#cards').addEventListener('click', async e => {
  const btn = e.target.closest('button[data-act]'); if (!btn) return;
  const card = btn.closest('.card'); const name = card.dataset.name; const act = btn.dataset.act;
  $$('.menu.open').forEach(m => { if (!m.contains(btn)) m.classList.remove('open'); });
  if (act === 'menu') { btn.parentElement.classList.toggle('open'); return; }
  btn.closest('.menu')?.classList.remove('open');
  if (act === 'start' || act === 'stop') {
    await busy(btn, async () => {
      const r = await api(`/api/instances/${encodeURIComponent(name)}/${act}`, {method: 'POST'});
      if (!r.ok) throw new Error(r.error);
      toast(`${name} ${act === 'start' ? 'started' : 'stopped'}`, 'ok'); await refresh();
    });
  } else if (act === 'run') runDialog(name);
  else if (act === 'term') { showTab('terminal'); $('#termDistro').value = name; startSession(name); }
  else if (act === 'info') { try { modal(`<h3>${esc(name)}</h3><pre class="out" style="display:block">${esc(await callTool('wsl_distro_info', {distro: name}))}</pre><div class="foot"><button class="btn" onclick="this.closest('.overlay').classList.remove('open')">Close</button></div>`); } catch (err) { toast(err.message, 'err'); } }
  else if (act === 'export') openToolForm('wsl_export_distro', {distro: name});
  else if (act === 'copy') copyDialog(name);
  else if (act === 'delete') {
    if (!await confirmDialog(`Delete ${name}?`, `This unregisters the ${state.host.instanceNoun || 'instance'} and deletes its disk. Export it first if you want to keep anything.`, 'Delete')) return;
    try { toast(await callTool('wsl_unregister_distro', {distro: name, confirm: true}), 'ok'); } catch (err) { toast(err.message, 'err'); }
    refresh();
  }
});
document.addEventListener('click', e => { if (!e.target.closest('.menu')) $$('.menu.open').forEach(m => m.classList.remove('open')); });
$('#q').addEventListener('input', e => { filter = e.target.value.trim().toLowerCase(); renderInstances(); });
$('#shutdownAll').addEventListener('click', async e => {
  if (!await confirmDialog('Stop everything?', 'Every running instance is shut down and every process inside it is killed.', 'Stop all')) return;
  await busy(e.target, async () => { const r = await api('/api/shutdown', {method: 'POST'}); if (!r.ok) throw new Error(r.error); toast('All instances stopped', 'ok'); await refresh(); });
});
$('#refresh').addEventListener('click', () => refresh(true));

function runDialog(name) {
  modal(`<h3>Run a command</h3>
    <div class="row"><div class="field" style="flex:1"><label>Instance</label><select id="rDistro">${instanceOptions(name)}</select></div>
    <div class="field" style="width:140px"><label>User</label><input type="text" id="rUser" placeholder="root"></div></div>
    <div class="field" style="margin-top:10px"><label>Command</label><textarea id="rCmd" class="mono" placeholder="uname -a" spellcheck="false"></textarea></div>
    <pre class="out" id="rOut"></pre>
    <div class="foot"><button class="btn" id="rClose">Close</button><button class="btn primary" id="rRun">Run</button></div>`);
  $('#rClose').onclick = closeModal;
  const run = () => busy($('#rRun'), async () => {
    const out = $('#rOut'); out.className = 'out'; out.textContent = 'Running…';
    try { out.textContent = await callTool('wsl_run_command', {distro: $('#rDistro').value, command: $('#rCmd').value, user: $('#rUser').value}); }
    catch (err) { out.className = 'out err'; out.textContent = err.message; }
  });
  $('#rRun').onclick = run;
  $('#rCmd').addEventListener('keydown', e => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) run(); });
  $('#rCmd').focus();
}
function copyDialog(name) {
  modal(`<h3>Duplicate ${esc(name)}</h3><p class="hint">Exports the instance and imports the copy under a new name — this can take a while for large disks.</p>
    <div class="field"><label>New name</label><input type="text" id="cName" value="${esc(name)}-copy"></div>
    <div class="foot"><button class="btn" id="cClose">Cancel</button><button class="btn primary" id="cOk">Duplicate</button></div>`);
  $('#cClose').onclick = closeModal;
  $('#cOk').onclick = () => busy($('#cOk'), async () => {
    const r = await api(`/api/instances/${encodeURIComponent(name)}/copy`, {method: 'POST', body: {new_name: $('#cName').value}});
    if (!r.ok) throw new Error(r.error); toast(`Duplicated ${name}`, 'ok'); closeModal(); refresh();
  });
}
const instanceOptions = sel => state.instances.map(i => `<option value="${esc(i.name)}" ${i.name === sel ? 'selected' : ''}>${esc(i.name)}</option>`).join('');

// ---- terminal --------------------------------------------------------------
function renderSessions() {
  $('#nSess').textContent = state.sessions.length;
  const sel = $('#termDistro'); const cur = sel.value; sel.innerHTML = instanceOptions(cur);
  if (activeSession && !state.sessions.some(s => s.id === activeSession)) { activeSession = null; stopPolling(); }
  $('#sessions').innerHTML = state.sessions.map(s => `<span class="chip ${s.id === activeSession ? 'active' : ''}" data-id="${esc(s.id)}"><span class="dot ${s.alive ? 'on' : 'err'}"></span>${esc(s.distro)} · ${esc(s.user)}</span>`).join('') || '<span class="hint">No open sessions.</span>';
}
$('#sessions').addEventListener('click', e => { const c = e.target.closest('[data-id]'); if (c) selectSession(c.dataset.id); });
function selectSession(id) { activeSession = id; $('#termOut').textContent = ''; renderSessions(); pollTerminal(); startPolling(); $('#termIn').focus(); }
async function startSession(distro) {
  distro = distro || $('#termDistro').value; if (!distro) return toast('Pick an instance first', 'err');
  await busy($('#termStart'), async () => {
    const text = await callTool('wsl_terminal_start', {distro, user: $('#termUser').value || undefined});
    const id = (text.match(/session (\S+)/) || [])[1];
    await refresh(); if (id) selectSession(id); toast(text, 'ok');
  });
}
$('#termStart').addEventListener('click', () => startSession());
function startPolling() { stopPolling(); termTimer = setInterval(pollTerminal, 1500); }
function stopPolling() { if (termTimer) clearInterval(termTimer); termTimer = null; }
async function pollTerminal() {
  if (!activeSession || document.hidden) return;
  try {
    const text = await callTool('wsl_terminal_read', {session_id: activeSession});
    if (text && text !== '(no new output)') appendTerm(text);
  } catch (e) { stopPolling(); activeSession = null; renderSessions(); }
}
function appendTerm(text) { const t = $('#termOut'); t.textContent += text; t.scrollTop = t.scrollHeight; }
async function sendTerm() {
  if (!activeSession) return toast('Start or pick a session first', 'err');
  const inp = $('#termIn'); const line = inp.value; inp.value = '';
  appendTerm((/\n$/.test($('#termOut').textContent) || !$('#termOut').textContent ? '' : '\n') + '$ ' + line + '\n');
  try { const out = await callTool('wsl_terminal_send', {session_id: activeSession, input: line, wait_ms: 800}); if (out && out !== '(no output yet)') appendTerm(out); }
  catch (e) { toast(e.message, 'err'); }
}
$('#termSend').addEventListener('click', sendTerm);
$('#termIn').addEventListener('keydown', e => { if (e.key === 'Enter') sendTerm(); });
$$('[data-sig]').forEach(b => b.addEventListener('click', async () => {
  if (!activeSession) return; try { toast(await callTool('wsl_terminal_signal', {session_id: activeSession, signal: b.dataset.sig}), 'ok'); if (b.dataset.sig === 'kill') { activeSession = null; stopPolling(); refresh(); } } catch (e) { toast(e.message, 'err'); }
}));
$('#termClose').addEventListener('click', async () => {
  if (!activeSession) return; try { await callTool('wsl_terminal_close', {session_id: activeSession}); activeSession = null; stopPolling(); $('#termOut').textContent = ''; refresh(); } catch (e) { toast(e.message, 'err'); }
});

// ---- snippets --------------------------------------------------------------
function renderSnippets() {
  $('#nSnip').textContent = state.snippets.length;
  if (!state.snippets.length) { $('#snipList').innerHTML = '<div class="empty"><b>No snippets yet</b>Create one here or in the app under Quick Actions.</div>'; return; }
  // The periodic refresh re-renders this list; keep whichever instance the
  // user already picked per snippet instead of snapping back to the first.
  const chosen = {};
  $$('[data-i]', $('#snipList')).forEach(box => { chosen[box.dataset.i] = $('.snipTarget', box).value; });
  $('#snipList').innerHTML = state.snippets.map((s, i) => `
    <div class="panel snip" style="margin-bottom:10px" data-i="${i}">
      <div style="flex:1;min-width:0"><b>${esc(s.name)}</b><pre>${esc(s.content)}</pre></div>
      <div class="field" style="width:200px;flex:none"><label>Run in</label><select class="snipTarget">${instanceOptions(chosen[i])}</select>
        <div class="row" style="margin-top:6px"><button class="btn sm primary" data-act="run">Run</button><button class="btn sm danger" data-act="del">Delete</button></div></div>
    </div>`).join('');
}
$('#snipList').addEventListener('click', async e => {
  const btn = e.target.closest('button[data-act]'); if (!btn) return;
  const box = btn.closest('[data-i]'); const s = state.snippets[+box.dataset.i];
  if (btn.dataset.act === 'run') {
    const distro = $('.snipTarget', box).value;
    await busy(btn, async () => {
      const out = await callTool('wsl_run_command', {distro, command: s.content});
      modal(`<h3>${esc(s.name)} · ${esc(distro)}</h3><pre class="out" style="display:block">${esc(out)}</pre><div class="foot"><button class="btn" onclick="this.closest('.overlay').classList.remove('open')">Close</button></div>`);
    });
  } else if (btn.dataset.act === 'del') {
    if (!await confirmDialog(`Delete snippet "${s.name}"?`, 'This removes it from the app as well.', 'Delete')) return;
    try { toast(await callTool('wsl_delete_snippet', {name: s.name}), 'ok'); refresh(); } catch (err) { toast(err.message, 'err'); }
  }
});
$('#snipNew').addEventListener('click', () => {
  modal(`<h3>New snippet</h3><div class="field"><label>Name</label><input type="text" id="sName"></div>
    <div class="field" style="margin-top:10px"><label>Script</label><textarea id="sBody" class="mono" placeholder="apt update && apt upgrade -y" spellcheck="false"></textarea></div>
    <div class="foot"><button class="btn" id="sClose">Cancel</button><button class="btn primary" id="sOk">Save</button></div>`);
  $('#sClose').onclick = closeModal;
  $('#sOk').onclick = () => busy($('#sOk'), async () => { toast(await callTool('wsl_create_snippet', {name: $('#sName').value, content: $('#sBody').value}), 'ok'); closeModal(); refresh(); });
});

// ---- tools -----------------------------------------------------------------
const GROUPS = [
  ['Instances', /^(wsl_list_distros|wsl_distro_info|wsl_stop_distro|wsl_shutdown|wsl_status|wsl_copy_distro|wsl_move_distro|wsl_resize_distro|wsl_compact_disk|wsl_set_default_)/],
  ['Create & import', /^(wsl_list_online|wsl_list_catalog|wsl_install_distro|wsl_import|wsl_export|wsl_package|wsl_install_package|vm_)/],
  ['Configuration', /^(wsl_get_wsl|wsl_set_wsl|wsl_set_version)/],
  ['Files & disks', /^(wsl_copy_to|wsl_copy_from|wsl_mount|wsl_unmount|wsl_list_physical|wsl_list_mounted)/],
  ['Services & snippets', /^(wsl_list_recipes|wsl_install_service|wsl_.*snippet)/],
  ['Commands & terminal', /^(wsl_run_command|wsl_terminal)/],
];
const DESTRUCTIVE = /unregister|delete|move|resize|unmount|set_version|shutdown/;
function groupOf(name) { for (const [g, re] of GROUPS) if (re.test(name)) return g; return 'Other'; }
function renderTools() {
  const q = toolFilter;
  const list = tools.filter(t => !q || t.name.includes(q) || t.description.toLowerCase().includes(q));
  const byGroup = {};
  for (const t of list) (byGroup[groupOf(t.name)] ||= []).push(t);
  const order = [...GROUPS.map(g => g[0]), 'Other'].filter(g => byGroup[g]);
  $('#toolList').innerHTML = order.map(g => `<div class="group">${esc(g)}</div>` + byGroup[g].map(t => `
    <div class="tool" data-tool="${esc(t.name)}">
      <button class="h"><span class="nm mono">${esc(t.name)}</span><span class="ds">${esc(t.description)}</span></button>
      <div class="body"></div>
    </div>`).join('')).join('') || '<div class="empty"><b>No tools match</b></div>';
}
$('#tq').addEventListener('input', e => { toolFilter = e.target.value.trim().toLowerCase(); renderTools(); });
$('#toolList').addEventListener('click', e => {
  const h = e.target.closest('button.h'); if (!h) return;
  const box = h.parentElement; const open = box.classList.toggle('open');
  if (open && !box.querySelector('.form')) buildToolForm(box, tools.find(t => t.name === box.dataset.tool), {});
});
function fieldHtml(key, prop, required, preset) {
  const id = 'f_' + key; const label = `<label for="${id}">${esc(key)}${required ? ' *' : ''}</label>`;
  const val = preset[key] ?? '';
  let input;
  if (prop.type === 'boolean') input = `<select id="${id}" data-key="${esc(key)}" data-type="boolean"><option value="">(default)</option><option value="true" ${val === true ? 'selected' : ''}>true</option><option value="false">false</option></select>`;
  else if (prop.enum) input = `<select id="${id}" data-key="${esc(key)}"><option value="">(default)</option>${prop.enum.map(v => `<option ${v === val ? 'selected' : ''}>${esc(v)}</option>`).join('')}</select>`;
  else if (prop.type === 'integer' || prop.type === 'number') input = `<input type="number" id="${id}" data-key="${esc(key)}" data-type="number" value="${esc(val)}">`;
  else if (/command|content|script|value|lines/.test(key)) input = `<textarea id="${id}" class="mono" data-key="${esc(key)}" spellcheck="false">${esc(val)}</textarea>`;
  else if (/distro/.test(key)) input = `<input type="text" id="${id}" data-key="${esc(key)}" list="distroList" value="${esc(val)}">`;
  else input = `<input type="text" id="${id}" data-key="${esc(key)}" value="${esc(val)}">`;
  const wide = /textarea/.test(input);
  return `<div class="field ${wide ? 'full' : ''}">${label}${input}<small>${esc(prop.description || '')}</small></div>`;
}
function buildToolForm(box, tool, preset) {
  const props = (tool.inputSchema && tool.inputSchema.properties) || {};
  const req = new Set((tool.inputSchema && tool.inputSchema.required) || []);
  const body = $('.body', box);
  body.innerHTML = `<div class="ds">${esc(tool.description)}</div>
    <div class="form">${Object.entries(props).map(([k, p]) => fieldHtml(k, p, req.has(k), preset)).join('') || '<div class="hint">No parameters.</div>'}</div>
    <div class="row" style="margin-top:12px;justify-content:flex-end"><button class="btn ${DESTRUCTIVE.test(tool.name) ? 'danger' : 'primary'}">Run ${esc(tool.name)}</button></div>
    <pre class="out"></pre>`;
  $('.row .btn', body).addEventListener('click', async ev => {
    const args = {};
    $$('[data-key]', body).forEach(el => {
      const v = el.value; if (v === '' || v == null) return;
      args[el.dataset.key] = el.dataset.type === 'number' ? Number(v) : el.dataset.type === 'boolean' ? v === 'true' : v;
    });
    if (DESTRUCTIVE.test(tool.name) && !await confirmDialog('Run ' + tool.name + '?', 'This changes or removes data and cannot be undone from here.', 'Run')) return;
    const out = $('.out', body);
    await busy(ev.target, async () => {
      out.className = 'out'; out.textContent = 'Running…';
      try { out.textContent = await callTool(tool.name, args); refresh(); }
      catch (err) { out.className = 'out err'; out.textContent = err.message; }
    });
  });
}
function openToolForm(name, preset) {
  const tool = tools.find(t => t.name === name); if (!tool) return toast('Tool not available on this backend', 'err');
  showTab('tools'); $('#tq').value = name; toolFilter = name; renderTools();
  const box = $(`.tool[data-tool="${CSS.escape(name)}"]`); if (!box) return;
  box.classList.add('open'); buildToolForm(box, tool, preset); box.scrollIntoView({behavior: 'smooth', block: 'start'});
}

// ---- assistant -------------------------------------------------------------
// One transcript shared with the desktop panel. A run can take minutes of
// tool calls, so Send returns at once and the tab polls /api/chat for the
// notes, the streaming reply and the final answer while it is open.
let chat = {enabled: true, configured: true, pro: true, busy: false, status: null, streaming: '', error: null, count: 0, messages: []};
let chatRevision = null, chatTimer = null, chatLoaded = false;
const CHAT_ERRORS = {
  'busy': 'The assistant is still working — wait for it to finish or stop it.',
  'ai-disabled': 'AI features are turned off in the app under Settings → Bring Your Own AI Key.',
  'pro-required': 'The assistant is a Pro feature.',
  'byok-required': 'No API key yet. Add one in the app under Settings → AI assistant.',
  'byok-request-failed': 'The request to the AI provider failed. Check the key, the endpoint and the network in the app, then retry.',
  'byok-empty-response': 'The provider sent an empty reply. Retry.',
  'cancelled': 'Stopped.',
};
const chatErrorText = code => CHAT_ERRORS[code] || code || 'Something went wrong.';
function fmt(text) {
  // Markdown-lite: fenced blocks, inline code and bold — what the assistant
  // actually produces; the bubble is pre-wrap so line breaks survive.
  return String(text ?? '').split(/```[^\n]*\n?/).map((p, i) => i % 2
    ? `<pre>${esc(p.replace(/\n$/, ''))}</pre>`
    : esc(p).replace(/`([^`\n]+)`/g, '<code>$1</code>').replace(/\*\*([^*\n]+)\*\*/g, '<b>$1</b>')).join('');
}
function chatEntry(m, live) {
  if (m.role === 'tool') return `<div class="msg note">⚙ ran <span class="mono">${esc(m.content)}</span></div>`;
  if (m.role === 'snippet') return `<div class="msg note">Saved this run as snippet <button class="link" data-snippet="${esc(m.content)}">${esc(m.content)}</button></div>`;
  return `<div class="msg ${m.role === 'user' ? 'user' : 'assistant'}"><div class="bubble ${live ? 'live' : ''}">${fmt(m.content)}</div></div>`;
}
function renderChat() {
  $('#nChat').textContent = chat.count;
  $('#chatModel').hidden = !chat.model; $('#chatModel').textContent = chat.model || '';
  const notice = $('#chatNotice');
  let text = '', err = false;
  if (!chat.enabled) text = CHAT_ERRORS['ai-disabled'];
  else if (!chat.pro) text = CHAT_ERRORS['pro-required'];
  else if (!chat.configured) text = CHAT_ERRORS['byok-required'];
  else if (chat.error && chat.error !== 'cancelled') { text = chatErrorText(chat.error); err = true; }
  notice.hidden = !text; notice.className = 'notice' + (err ? ' err' : '');
  notice.innerHTML = text ? `<span style="flex:1">${esc(text)}</span>${err && !chat.busy ? '<button class="btn sm" id="chatRetry">Retry</button>' : ''}` : '';
  const retry = $('#chatRetry'); if (retry) retry.onclick = () => chatAction('retry', retry);
  $('#chatStatus').hidden = !chat.busy;
  $('#chatStatusText').textContent = chat.status ? 'Working… · ' + chat.status : 'Working…';
  $('#chatSend').disabled = chat.busy || !chat.enabled || !chat.configured || !chat.pro;
  $('#chatClear').disabled = chat.busy || !chat.messages.length;
  const log = $('#chatLog');
  const stick = !chatLoaded || log.scrollHeight - log.scrollTop - log.clientHeight < 48;
  const items = chat.messages.map(m => chatEntry(m, false));
  if (chat.busy && chat.streaming) items.push(chatEntry({role: 'assistant', content: chat.streaming}, true));
  log.innerHTML = items.join('') || '<div class="empty"><b>Nothing yet</b>Try “which instances are running?” or “start Ubuntu and update it”.</div>';
  if (stick) log.scrollTop = log.scrollHeight;
  chatLoaded = true;
}
async function pollChat() {
  if (unauthorized || document.hidden) return;
  try {
    const data = await api('/api/chat' + (chatRevision !== null ? '?rev=' + encodeURIComponent(chatRevision) : ''));
    if (data.messages) { chat.messages = data.messages; chatRevision = data.revision; }
    const wasBusy = chat.busy;
    Object.assign(chat, {enabled: data.enabled !== false, configured: data.configured, pro: data.pro, model: data.model, busy: data.busy, status: data.status, streaming: data.streaming || '', error: data.error, count: data.count});
    renderChat();
    // A finished run may have started, stopped or created an instance.
    if (wasBusy && !chat.busy) refresh();
  } catch (e) { /* surfaced by refresh */ }
}
function startChatPolling() { stopChatPolling(); pollChat(); chatTimer = setInterval(pollChat, 1500); }
function stopChatPolling() { if (chatTimer) clearInterval(chatTimer); chatTimer = null; }
async function sendChat() {
  const inp = $('#chatIn'); const text = inp.value.trim();
  if (!text || chat.busy) return;
  try {
    const r = await api('/api/chat', {method: 'POST', body: {message: text}});
    if (!r.ok) throw new Error(r.error);
    inp.value = ''; autosizeChat();
    chat.busy = true; chat.error = null; renderChat(); pollChat();
  } catch (e) { toast(chatErrorText(e.message), 'err'); }
}
async function chatAction(action, btn) {
  try {
    const r = await api('/api/chat/' + action, {method: 'POST'});
    if (!r.ok) throw new Error(r.error);
    if (action === 'clear') { chat.messages = []; chat.error = null; }
    if (action === 'retry') { chat.busy = true; chat.error = null; }
    renderChat(); pollChat();
  } catch (e) { toast(chatErrorText(e.message), 'err'); }
}
function autosizeChat() { const t = $('#chatIn'); t.style.height = 'auto'; t.style.height = Math.min(t.scrollHeight, 160) + 'px'; }
$('#chatSend').addEventListener('click', sendChat);
$('#chatStop').addEventListener('click', () => chatAction('cancel'));
$('#chatClear').addEventListener('click', async () => {
  if (!await confirmDialog('Clear the conversation?', 'This clears it in the app as well.', 'Clear')) return;
  chatAction('clear');
});
$('#chatIn').addEventListener('input', autosizeChat);
$('#chatIn').addEventListener('keydown', e => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendChat(); } });
$('#chatLog').addEventListener('click', e => { const b = e.target.closest('[data-snippet]'); if (b) showTab('snippets'); });

// ---- tabs & lifecycle --------------------------------------------------------
function showTab(id) {
  $$('#tabs button').forEach(b => b.classList.toggle('active', b.dataset.tab === id));
  $$('main > section').forEach(s => s.hidden = s.id !== id);
  if (id === 'terminal' && activeSession) startPolling(); else stopPolling();
  if (id === 'chat') startChatPolling(); else stopChatPolling();
  try { localStorage.setItem('wslm.tab', id); } catch (e) {}
}
$('#tabs').addEventListener('click', e => { const b = e.target.closest('button[data-tab]'); if (b) showTab(b.dataset.tab); });
document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
setInterval(() => { if (!document.hidden) refresh(); }, 6000);
try { const t = localStorage.getItem('wslm.tab'); if (t && $(`#tabs [data-tab="${t}"]`)) showTab(t); } catch (e) {}
refresh(true); loadTools();
})();
</script>
</body>
</html>''';
