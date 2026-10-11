/* concept: ANALYSIS OS / 解析 — cinematic lab presentation of the MÖBIUS 3D sculpture
 * (inspired by the Rhine Lab promo: macro fly-through → pull-back, HUD callouts with leader lines,
 * header block, beat meter, bilingual captions). Uses PulseFloat's own names; no Rhine Lab branding.
 * Camera shots change only on bass onsets while sound plays; in silence it eases back to the symmetric
 * full view and stops. Requires concept-mobius.js (window.PF.mobius3D) and three.js; falls back to MÖBIUS 2D.
 */
(function () {
  window.PF_EXTRA = window.PF_EXTRA || [];
  const SHOTS = [
    { name: "FULL VIEW", pos: [0, 0.55, 5.2], look: [0, -0.05, 0], fov: 28, callouts: 1 },
    { name: "THREE-QUARTER", pos: [2.7, 1.15, 3.9], look: [0.15, -0.12, 0], fov: 30, callouts: 1 },
    { name: "MACRO · FINS", macroU: 0.17, fov: 38, callouts: 0 },
    { name: "LOW ANGLE", pos: [-1.3, -0.4, 3.7], look: [0, 0.05, 0], fov: 30, callouts: 1 },
  ];
  const SECTIONS = [
    { key: "BASS", zh: "低頻", range: "20–250 Hz", u: 0.16, from: 0, to: 0.25, place: "bl" },
    { key: "MID", zh: "中頻", range: "250 Hz–4 kHz", u: 0.47, from: 0.25, to: 0.75, place: "tl" },
    { key: "TREBLE", zh: "高頻", range: "4–16 kHz", u: 0.8, from: 0.75, to: 1, place: "tr" },
  ];
  const CAPTIONS = {
    silent: ["等待訊號。", "AWAITING SIGNAL."],
    BASS: ["低頻正在推動回路。", "THE BASS IS DRIVING THE LOOP."],
    MID: ["中頻沿著回路流動。", "THE MIDS FLOW ALONG THE LOOP."],
    TREBLE: ["高頻點亮了邊界。", "THE HIGHS LIGHT UP THE EDGE."],
    macro: ["三百片鰭，一條回路。", "THREE HUNDRED FINS. ONE LOOP."],
  };
  const ease = (x) => x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2;
  const lerp = (a, b, t) => a + (b - a) * t;

  function groupEnergy(S, from, to) {
    const N = S.N | 0; if (!N) return 0;
    const i0 = Math.floor(from * N), i1 = Math.max(i0 + 1, Math.floor(to * N));
    let s = 0; for (let i = i0; i < i1; i++) s += Math.min(1, Math.max(0, +S.cur[i] || 0));
    const v = s / (i1 - i0); return v < 0.01 ? 0 : v;
  }

  function shotCamera(rig, shot) {
    if (shot.macroU == null) return { pos: shot.pos, look: shot.look, fov: shot.fov };
    const THREE = window.THREE, f = rig.frames;
    const i = Math.min(f.M - 1, Math.round(shot.macroU * f.M));
    rig.group.updateMatrixWorld();
    const p = new THREE.Vector3().fromArray(f.P[i]).applyMatrix4(rig.group.matrixWorld);
    const n = new THREE.Vector3().fromArray(f.N[i]).transformDirection(rig.group.matrixWorld);
    const t = new THREE.Vector3().fromArray(f.T[i]).transformDirection(rig.group.matrixWorld);
    const pos = p.clone().addScaledVector(n, 0.42).addScaledVector(t, -0.55).add(new THREE.Vector3(0, 0.12, 0.25));
    const look = p.clone().addScaledVector(t, 0.35);
    return { pos: pos.toArray(), look: look.toArray(), fov: shot.fov };
  }

  function draw(ctx, w, h, o) {
    const PF = window.PF, S = PF.S, st = o.state;
    const api = PF.mobius3D;
    if (!window.THREE || !api || PF.mobiusNo3D) { (api && api.draw2D || (() => ctx.clearRect(0, 0, w, h)))(ctx, w, h, o); return; }
    const small = !!o.small;
    // camera choreography state (advances only with sound)
    st.shot = st.shot ?? 0; st.blend = st.blend ?? 1; st.beats = st.beats ?? 0;
    const prevPulses = (st.pulses || []).length;
    const result = api.render(ctx, w, h, o, small ? "thumb-analysis" : "main-analysis", (rig, dt) => {
      const energy = st.energy || 0;
      const onset = (st.pulses || []).length > prevPulses;
      if (onset) st.beats++;
      st.sinceSwitch = (st.sinceSwitch || 0) + (energy > 0 ? dt : 0);
      let target = st.shot;
      if (!small && energy > 0 && onset && st.sinceSwitch > 3.2) { target = (st.shot + 1) % SHOTS.length; }
      if (energy === 0) target = 0;
      if (target !== st.shot) {
        st.camFrom = st.camNow || shotCamera(rig, SHOTS[st.shot]);
        st.shot = target; st.blend = 0; st.sinceSwitch = 0;
      }
      if (st.blend < 1) st.blend = Math.min(1, st.blend + dt / 1.6);
      const to = shotCamera(rig, SHOTS[st.shot]), from = st.camFrom || to, k = ease(st.blend);
      const cam = {
        pos: [0, 1, 2].map(j => lerp(from.pos[j], to.pos[j], k)),
        look: [0, 1, 2].map(j => lerp(from.look[j], to.look[j], k)),
        fov: lerp(from.fov, to.fov, k),
      };
      st.camNow = cam;
      rig.camera.position.fromArray(cam.pos);
      rig.camera.fov = cam.fov;
      rig.camera.lookAt(cam.look[0], cam.look[1], cam.look[2]);
      rig.camera.updateProjectionMatrix();
      return st.blend < 1; // keep re-rendering while the camera settles
    });
    if (small || h < 120 || !result) return;
    drawHUD(ctx, w, h, st, result);
  }

  let HALO = "rgba(250,248,244,0.55)";
  function inkText(ctx, text, x, y, font, color, align) {
    ctx.font = font; ctx.textAlign = align || "left";
    ctx.lineWidth = 2.4; ctx.strokeStyle = HALO; ctx.strokeText(text, x, y);
    ctx.fillStyle = color; ctx.fillText(text, x, y);
  }

  function drawHUD(ctx, w, h, st, r) {
    const PF = window.PF, S = PF.S;
    const sty = (PF.mobius3D.STYLES[PF.mobiusStyle] || PF.mobius3D.STYLES.porcelain);
    const ink = sty.ink, soft = sty.soft;
    HALO = sty.halo;
    const big = h >= 260;
    const mono = (px, wgt) => `${wgt || 500} ${px}px ui-monospace, "SF Mono", Menlo, monospace`;
    const sans = (px, wgt) => `${wgt || 600} ${px}px "Helvetica Neue", "PingFang TC", system-ui, sans-serif`;
    ctx.save();
    ctx.textBaseline = "alphabetic";
    // header block
    inkText(ctx, "PULSEFLOAT", 14, 22, sans(big ? 15 : 12, 800), ink);
    inkText(ctx, "SYNTHESIZE AUDIO", 14, 30, mono(big ? 7 : 6), soft);
    inkText(ctx, "ANALYSIS", 14, big ? 46 : 41, sans(big ? 13 : 10.5, 300), ink);
    ctx.font = sans(big ? 13 : 10.5, 300);
    const aw = ctx.measureText("ANALYSIS ").width;
    inkText(ctx, "OS", 14 + aw, big ? 46 : 41, sans(big ? 13 : 10.5, 800), ink);
    // beat meter (top right): 4 dots, orange = current beat in the bar
    const dots = 4, dx = 9, x0 = w - 14 - (dots - 1) * dx, y0 = 16;
    ctx.strokeStyle = soft; ctx.lineWidth = 0.8;
    ctx.beginPath(); ctx.moveTo(x0 - 18, y0); ctx.lineTo(w - 14, y0); ctx.stroke();
    for (let i = 0; i < dots; i++) {
      const on = (st.energy || 0) > 0 && (st.beats % dots) === i;
      ctx.fillStyle = on ? sty.accent : soft;
      ctx.beginPath(); ctx.arc(x0 + i * dx, y0, on ? 2.6 : 1.6, 0, Math.PI * 2); ctx.fill();
    }
    const finLabel = `FIN ${String(r.loudestFin).padStart(3, "0")} / ${r.M}`;
    inkText(ctx, `${SHOTS[st.shot].name} · ${finLabel}`, w - 14, 28, mono(6.5), soft, "right");
    // callouts
    const show = SHOTS[st.shot].callouts ? ease(st.blend) : 0;
    if (show > 0.02) {
      ctx.globalAlpha = show;
      for (const sec of SECTIONS) {
        const a = r.project(sec.u);
        if (!a) continue;
        const e = groupEnergy(S, sec.from, sec.to);
        const db = e > 0 ? (20 * Math.log10(e)).toFixed(1) + " dB" : "—∞ dB";
        const lx = sec.place === "tr" ? w - 14 : 14;
        const ly = sec.place === "bl" ? h - (big ? 52 : 40) : (big ? 78 : 62);
        const elbowX = sec.place === "tr" ? lx - (big ? 150 : 112) : lx + (big ? 150 : 112);
        ctx.strokeStyle = soft; ctx.lineWidth = 0.7;
        ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(elbowX, ly + 3); ctx.lineTo(sec.place === "tr" ? elbowX + 6 : elbowX - 6, ly + 3); ctx.stroke();
        ctx.fillStyle = sty.accent; ctx.beginPath(); ctx.arc(a.x, a.y, 2.2, 0, Math.PI * 2); ctx.fill();
        const align = sec.place === "tr" ? "right" : "left";
        // black tag + title + sub line
        ctx.font = mono(5.5, 600);
        const tag = "SPECTRUM SECT.";
        const tw = ctx.measureText(tag).width + 6;
        const tagX = align === "right" ? lx - tw : lx;
        ctx.fillStyle = sty.tagBg;
        ctx.fillRect(tagX, ly - 18, tw, 8);
        ctx.fillStyle = sty.tagFg;
        ctx.textAlign = "left"; ctx.fillText(tag, tagX + 3, ly - 12);
        inkText(ctx, `${sec.key} SECTION`, lx, ly - 1, sans(big ? 11 : 8.5, 800), ink, align);
        inkText(ctx, `${sec.zh} · ${sec.range} · ${db}`, lx, ly + (big ? 11 : 8), mono(big ? 7 : 6), soft, align);
      }
      ctx.globalAlpha = 1;
    }
    // caption (bottom centre), changes at most every 2 s
    const groups = SECTIONS.map(sec => ({ key: sec.key, e: groupEnergy(S, sec.from, sec.to) }));
    const top = groups.reduce((a, b) => (b.e > a.e ? b : a));
    let want = (st.energy || 0) === 0 ? "silent" : (SHOTS[st.shot].macroU != null ? "macro" : top.key);
    st.capT = (st.capT || 0) + 1 / 60;
    if (want !== st.caption && (st.capT > 2 || !st.caption || want === "silent")) { st.caption = want; st.capT = 0; }
    const cap = CAPTIONS[st.caption || "silent"];
    inkText(ctx, cap[0], w / 2, h - (big ? 22 : 17), sans(big ? 11 : 9, 600), ink, "center");
    inkText(ctx, cap[1], w / 2, h - (big ? 11 : 8), mono(big ? 6.5 : 5.5), soft, "center");
    // footer
    inkText(ctx, "POWERED BY PULSEFLOAT —", w - 14, h - 10, mono(big ? 7 : 6, 600), soft, "right");
    ctx.restore();
  }

  window.PF_EXTRA.push({ id: "analysis", name: "解析", en: "ANALYSIS OS", draw });
})();
