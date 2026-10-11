#!/usr/bin/env python3
"""Build the UI proposal page from the committed prototype + concept renderers."""
import glob, json, os, re, sys
ROOT = '/Users/huang/Documents/PulseFloat/docs/design/prototype.html'
CONCEPTS = '/private/tmp/claude-501/-Users-huang/0edfc05b-802c-4868-838d-db56a1e42223/scratchpad/ui-concepts'
OUT = '/private/tmp/claude-501/-Users-huang/0edfc05b-802c-4868-838d-db56a1e42223/scratchpad/ui-proposal/pulsefloat-ui.html'
notes = json.load(open(os.path.join(os.path.dirname(OUT), 'notes.json'))) if os.path.exists(os.path.join(os.path.dirname(OUT), 'notes.json')) else []
order = ['mobius', 'radial', 'orbit', 'hud', 'constellation']

s = open(ROOT, encoding='utf-8').read()
def rep(old, new, count=1):
    global s
    if old not in s:
        sys.exit(f'patch point not found: {old[:70]!r}')
    s = s.replace(old, new, count)

rep('<title>Pulsefloat Prototype</title>', '<title>PulseFloat UI 提案</title>')
rep('<span>設計原型 v0.1 · 視覺與手感基準，Swift 版照這份參數實作</span>',
    '<span>UI 提案 v0.4 · 萊茵生命 3D 雕塑、正在播放封面、太空 HUD（Pinterest）· 預設透明視窗</span>')
# transport: silence preview + wallpaper
rep('<button class="primary" id="playDemo" type="button">▶ 播放示範曲</button>',
    '<button class="primary" id="playDemo" type="button">▶ 播放示範曲</button>\n'
    '      <button type="button" id="silenceBtn" aria-pressed="false">◼︎ 預覽靜音</button>\n'
    '      <div class="seg wall" role="group" aria-label="桌布"><button type="button" data-wall="lab" aria-pressed="false">實驗室</button><button type="button" data-wall="space" aria-pressed="true">太空桌布</button><button type="button" data-wall="light" aria-pressed="false">淺色桌布</button><button type="button" data-wall="proto" aria-pressed="false">原型</button></div>')
# CSS additions
rep('.gallery{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}',
    '.gallery{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px}\n'
    '.tile .name .new{font-style:normal;font-family:var(--f-mono);font-size:10px;color:var(--accent-ink);background:var(--accent);border-radius:4px;padding:1px 5px;margin-left:6px}\n'
    '.seg.wall{display:flex;gap:4px}.seg.wall button{padding:6px 10px;font-size:12px}.seg.wall button[aria-pressed=true]{background:var(--accent);color:var(--accent-ink);border-color:var(--accent);font-weight:600}\n'
    '#silenceBtn[aria-pressed=true]{background:#2a3142;border-color:#5b6888}\n'
    '.stage.wall-space{background:radial-gradient(1.2px 1.2px at 12% 18%,#cfe8ff 50%,transparent 51%),radial-gradient(1px 1px at 33% 9%,#9fc6ff 50%,transparent 51%),radial-gradient(1.4px 1.4px at 61% 22%,#e6f3ff 50%,transparent 51%),radial-gradient(1px 1px at 78% 12%,#a9d4ff 50%,transparent 51%),radial-gradient(1.2px 1.2px at 22% 64%,#bcdcff 50%,transparent 51%),radial-gradient(1px 1px at 47% 41%,#d9ecff 50%,transparent 51%),radial-gradient(1px 1px at 88% 58%,#cfe8ff 50%,transparent 51%),radial-gradient(1.1px 1.1px at 8% 86%,#9fc6ff 50%,transparent 51%),radial-gradient(circle at 128% 70%,transparent 0 46%,rgba(120,220,255,.85) 46.4%,rgba(60,150,255,.35) 47.6%,transparent 52%),radial-gradient(circle at 128% 70%,#081a36 0 46%,transparent 46.2%),radial-gradient(70% 90% at 100% 60%,rgba(40,120,220,.28),transparent 70%),linear-gradient(160deg,#0a1226 0%,#050915 100%)}\n'
    '.stage.wall-lab{background:radial-gradient(70% 90% at 30% 20%,#f4f2ee,transparent 70%),radial-gradient(60% 80% at 85% 85%,#d3cfc7,transparent 70%),linear-gradient(160deg,#ebe8e3 0%,#d9d5ce 100%)}\n'
    '.stage.wall-lab .menubar{background:rgba(255,255,255,.5);color:#1a1d24}\n'
    '.stage.wall-light{background:radial-gradient(60% 80% at 20% 90%,rgba(255,196,214,.75),transparent 60%),radial-gradient(55% 70% at 85% 20%,rgba(160,206,255,.9),transparent 65%),linear-gradient(160deg,#eef2f8 0%,#d9e2ef 100%)}\n'
    '.stage.wall-light .menubar{background:rgba(255,255,255,.55);color:#1a1d24}\n'
    '.concepts{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px}\n'
    '.concept{background:var(--surface);border:1px solid var(--line);border-radius:var(--r-m);padding:14px;display:flex;flex-direction:column;gap:8px;min-width:0}\n'
    '.concept h3{margin:0;font-family:var(--f-display);font-weight:500;font-size:14px;display:flex;align-items:baseline;gap:8px;flex-wrap:wrap}\n'
    '.concept h3 em{font-style:normal;font-family:var(--f-mono);font-size:11px;color:var(--muted)}\n'
    '.concept .pitch{margin:0;color:var(--fg)}\n'
    '.concept .detail{margin:0;color:var(--muted);font-size:12.5px}\n'
    '.concept button{align-self:flex-start}')
# concept cards before the existing notes paragraph
cards = []
for n in sorted(notes, key=lambda x: order.index(x['id']) if x['id'] in order else 9):
    cards.append(f'<article class="concept"><h3>{n["name_zh"]} <em>{n["name_en"]}</em></h3>'
                 f'<p class="pitch">{n["tagline_zh"]}</p><p class="detail">{n["design_notes"]}</p>'
                 f'{n.get("extra","")}<button type="button" data-try="{n["id"]}" data-wall-hint="{n.get("wall","")}">套用到浮動視窗</button></article>')
rep('<p class="notes">',
    '<div class="section-h"><h2>新方向</h2><p>3D 無限雕塑（萊茵生命風格）、圓環＋封面、三個 Pinterest 太空 HUD 方向；沒有聲音時都保持靜止</p></div>\n'
    '      <div class="concepts" id="concepts">' + ''.join(cards) + '</div>\n      <p class="notes">', 1)
rep('<div class="section-h"><h2>主題</h2><p>四種主題都吃同一組頻帶資料，只差在繪圖</p></div>',
    '<div class="section-h"><h2>全部主題</h2><p>原本 4 種 + 新提案 4 種（標 NEW）；配色新增 6 組，都吃同一組頻帶資料</p></div>')
# defaults: transparent + first concept; new storage key
rep('theme: "bars", palette: "aurora", mirror: false, reflection: true, barGap: 0.28, windowMode: "card"',
    'theme: "mobius", palette: "aurora", mirror: false, reflection: true, barGap: 0.28, windowMode: "bare"')
s = s.replace('pulsefloat.params.v1', 'pulsefloat.ui-proposal.v2')
# expose helpers + merge concepts
rep('const RENDER = { bars:drawBars, radial:drawRadial, neon:drawNeon, led:drawLed };',
    'const RENDER = { bars:drawBars, radial:drawRadial, neon:drawNeon, led:drawLed };\n'
    'window.PF = { S, palAt, rgba, rr };\n'
    'for (const c of (window.PF_EXTRA || [])) { if (typeof c.draw === "function" && !RENDER[c.id]) { RENDER[c.id] = c.draw; THEMES.push({ id: c.id, name: c.name, en: c.en, isNew: true }); } }\n'
    'if (!RENDER[P.look.theme]) P.look.theme = "bars";')
s = s.replace('{small:false,fade:c.fade}', '{small:false,fade:c.fade,state:(c.st||(c.st={})),t:performance.now()/1000}')
s = s.replace('{small:true,fade:c.fade}', '{small:true,fade:c.fade,state:(c.st||(c.st={})),t:performance.now()/1000}')
# NEW badge in gallery tiles
rep('<div class="name"><span>${t.name}</span><em>${t.en}</em></div>',
    '<div class="name"><span>${t.name}${t.isNew?\'<i class="new">NEW</i>\':\'\'}</span><em>${t.en}</em></div>')
# theme switch resets the main canvas state
rep('function syncTheme(){', 'function syncTheme(){\n  main.st = {};')
# silence preview + wallpaper switch, inserted before the main loop
rep('function frame(now){',
    'let forceSilence = false;\n'
    'const silenceBtn = document.getElementById("silenceBtn");\n'
    'silenceBtn.addEventListener("click", () => { forceSilence = !forceSilence; silenceBtn.setAttribute("aria-pressed", String(forceSilence)); silenceBtn.textContent = forceSilence ? "▶︎ 恢復訊號" : "◼︎ 預覽靜音"; });\n'
    'const wallButtons = [...document.querySelectorAll(".seg.wall button")];\n'
    'function setWall(w){ stage.classList.remove("wall-space","wall-light","wall-lab"); if (w !== "proto") stage.classList.add("wall-" + w); wallButtons.forEach(b => b.setAttribute("aria-pressed", String(b.dataset.wall === w))); try { localStorage.setItem("pulsefloat.ui-proposal.wall", w); } catch (e) {} }\n'
    'wallButtons.forEach(b => b.addEventListener("click", () => setWall(b.dataset.wall)));\n'
    'let savedWall = "lab"; try { savedWall = localStorage.getItem("pulsefloat.ui-proposal.wall") || "lab"; } catch (e) {}\n'
    'setWall(savedWall);\n'
    'document.querySelectorAll("[data-try]").forEach(b => b.addEventListener("click", () => { if (RENDER[b.dataset.try]) { setTheme(b.dataset.try); if (b.dataset.wallHint) setWall(b.dataset.wallHint); stage.scrollIntoView({ behavior: "smooth", block: "center" }); } }));\n'
    'function frame(now){')
rep('  if (live){ analyser.getFloatFrequencyData(freq); bandsFromAnalyser(freq, AC.sampleRate/analyser.fftSize); }\n'
    '  else if (runSim){',
    '  if (forceSilence){ S.raw.fill(-160); }\n'
    '  else if (live){ analyser.getFloatFrequencyData(freq); bandsFromAnalyser(freq, AC.sampleRate/analyser.fftSize); }\n'
    '  else if (runSim){')
rep('  if (live || runSim) processFrame(', '  if (forceSilence || live || runSim) processFrame(')

# --- v0.4 patches: palettes, radial artwork, Möbius material buttons, libraries ---
rep('  mono:    { name: "Mono",    stops: ["#ffffff", "#d5dae5", "#98a1b4"] }\n};',
    '  mono:    { name: "Mono",    stops: ["#ffffff", "#d5dae5", "#98a1b4"] },\n'
    '  lab:     { name: "Lab",     stops: ["#f2eee4", "#c9c3b6", "#e2f096"] },\n'
    '  sakura:  { name: "Sakura",  stops: ["#ffe0e9", "#ff8fab", "#c77dff"] },\n'
    '  sunset:  { name: "Sunset",  stops: ["#ffb703", "#fb5607", "#8338ec"] },\n'
    '  matcha:  { name: "Matcha",  stops: ["#e9f5db", "#95d5b2", "#2d6a4f"] },\n'
    '  neotokyo:{ name: "Neo Tokyo", stops: ["#00f5d4", "#f15bb5", "#9b5de5"] },\n'
    '  graphite:{ name: "Graphite", stops: ["#f5f5f5", "#9e9e9e", "#3a3a3a"] }\n};')
rep('  ctx.globalAlpha=0.25+0.5*S.bass; ctx.lineWidth=o.small?0.8:1; ctx.beginPath(); ctx.arc(cx,cy,rc*0.72,0,Math.PI*2); ctx.stroke(); ctx.globalAlpha=1;',
    '  const art = window.PF && window.PF.art;\n'
    '  if (art) { const ar = rc*0.9; ctx.save(); ctx.beginPath(); ctx.arc(cx,cy,ar,0,Math.PI*2); ctx.clip(); ctx.drawImage(art, cx-ar, cy-ar, ar*2, ar*2); ctx.restore();\n'
    '    ctx.globalAlpha=0.35+0.4*S.bass; ctx.lineWidth=o.small?0.8:1.2; ctx.beginPath(); ctx.arc(cx,cy,ar,0,Math.PI*2); ctx.stroke(); ctx.globalAlpha=1; }\n'
    '  else { ctx.globalAlpha=0.25+0.5*S.bass; ctx.lineWidth=o.small?0.8:1; ctx.beginPath(); ctx.arc(cx,cy,rc*0.72,0,Math.PI*2); ctx.stroke(); ctx.globalAlpha=1; }')
rep('function frame(now){', 'function frame(now){\n  window.PF.paletteKey = P.look.palette;')
rep('let forceSilence = false;',
    'function makeCover(title, sub){ const c=document.createElement("canvas"); c.width=c.height=256; const x=c.getContext("2d");\n'
    '  const g=x.createLinearGradient(0,0,256,256); g.addColorStop(0,rgba(palAt(0),1)); g.addColorStop(0.55,rgba(palAt(0.5),1)); g.addColorStop(1,rgba(palAt(1),1)); x.fillStyle=g; x.fillRect(0,0,256,256);\n'
    '  x.fillStyle="rgba(10,12,18,.35)"; x.fillRect(0,170,256,86); x.fillStyle="#fff"; x.textAlign="center"; x.font="700 64px Unbounded, system-ui, sans-serif"; x.fillText(title.slice(0,4).toUpperCase(),128,130);\n'
    '  x.font="500 22px IBM Plex Mono, monospace"; x.fillText(sub.slice(0,18),128,222); return c; }\n'
    'function setArtFromFile(file){ const fallback=()=>{ window.PF.art = makeCover(file.name.replace(/\\.[^.]+$/,""), "LOCAL FILE"); };\n'
    '  if (!window.jsmediatags) return fallback();\n'
    '  try { window.jsmediatags.read(file, { onSuccess(tag){ const pic=tag && tag.tags && tag.tags.picture; if (!pic) return fallback();\n'
    '      const blob=new Blob([new Uint8Array(pic.data)], {type: pic.format || "image/jpeg"}); const img=new Image(); img.onload=()=>{ window.PF.art=img; }; img.onerror=fallback; img.src=URL.createObjectURL(blob); }, onError: fallback }); }\n'
    '  catch (e) { fallback(); } }\n'
    'document.querySelectorAll("[data-mstyle]").forEach(b => b.addEventListener("click", () => { window.PF.mobiusStyle = b.dataset.mstyle; document.querySelectorAll("[data-mstyle]").forEach(x => x.setAttribute("aria-pressed", String(x === b))); }));\n'
    'let forceSilence = false;')
rep('mode="demo"; playing=true; setChip("示範曲 · 128 BPM"); setPlayBtn();', 'mode="demo"; playing=true; setChip("示範曲 · 128 BPM"); setPlayBtn(); window.PF.art = makeCover("DEMO", "128 BPM · SYNTH");')
rep('mode="file"; playing=true; setChip(', 'mode="file"; playing=true; setArtFromFile(file); setChip(')

# concept scripts go right before the main inline script
concept_js = '<script src="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"></script>\n<script src="https://cdnjs.cloudflare.com/ajax/libs/jsmediatags/3.9.5/jsmediatags.min.js"></script>\n'
for cid in order:
    path = os.path.join(CONCEPTS, f'concept-{cid}.js')
    if os.path.exists(path):
        concept_js += f'<script>\n/* concept: {cid} */\n' + open(path, encoding='utf-8').read() + '\n</script>\n'
idx = s.index('<script>\n(() => {')
s = s[:idx] + concept_js + s[idx:]
open(OUT, 'w', encoding='utf-8').write(s)
print('wrote', OUT, len(s), 'bytes; concepts:', [c for c in order if os.path.exists(os.path.join(CONCEPTS, f'concept-{c}.js'))])
