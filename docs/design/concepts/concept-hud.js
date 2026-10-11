/* PulseFloat concept theme — 儀表 / HUD
 *
 * A precise sci-fi instrument readout floating on a transparent window.
 *   - four corner brackets frame the window (pinwheel: each bracket feeds one circuit trace)
 *   - four PCB traces with 45° jogs, each tied to a quarter of the spectrum; they light up
 *     segment by segment from the bracket outward as that band group gets louder
 *   - spectrum = crisp polyline + faint palette fill + dotted peak line
 *   - baseline with log-frequency ticks (60 · 250 · 1k · 4k · 16k), faint dotted 0 dB ceiling
 *   - spaced monospace title inline with the top frame line, signal dot, bass ring, level readout
 * Silence: every audio-driven quantity is 0, so the frame is a fixed, faint wireframe.
 * Legibility: bright strokes sit on a 2px-wider rgba(0,0,0,.25) halo, text gets a stroked halo.
 * Cost: ~45 canvas draw calls per frame, no shadowBlur at all (glow = one wide faint stroke).
 */
(function () {
  "use strict";

  var TAU = Math.PI * 2;
  var MINUS = "−";
  var FONT = '9px ui-monospace, "SF Mono", Menlo, monospace';
  var TITLE = "P U L S E F L O A T";
  var HALO = "rgba(0,0,0,0.25)";
  var TEXT_HALO = "rgba(0,0,0,0.3)";
  var MAJOR = [[60, "60"], [250, "250"], [1000, "1k"], [4000, "4k"], [16000, "16k"]];
  var MINOR = [31.5, 125, 500, 2000, 8000];
  // band-group ranges (fraction of N) feeding the four circuit traces: bass, low-mid, high-mid, high
  var GROUPS = [[0, 0.18], [0.18, 0.45], [0.45, 0.72], [0.72, 1]];
  var WHITE = [255, 255, 255];

  function c01(v) { return v > 0 ? (v < 1 ? v : 1) : 0; } // also maps NaN to 0
  function mix(a, b, f) {
    return [Math.round(a[0] + (b[0] - a[0]) * f), Math.round(a[1] + (b[1] - a[1]) * f), Math.round(a[2] + (b[2] - a[2]) * f)];
  }
  function pad(s, n) { while (s.length < n) s = " " + s; return s; }
  // one-pole smoothing with separate rise/fall time; the fall has a small linear tail so it
  // lands exactly on the target in finite time (silence becomes truly still, no endless creep)
  function follow(cur, tgt, dt, up, down) {
    if (tgt > cur) return up > 0 ? cur + (tgt - cur) * (1 - Math.exp(-dt / up)) : tgt;
    var v = cur + (tgt - cur) * (1 - Math.exp(-dt / down)) - 0.25 * dt;
    return v > tgt ? v : tgt;
  }
  // visual noise floor: the live pipeline releases exponentially (never exactly 0 for seconds);
  // anything below this is drawn as 0 so the frame freezes once the sound has really gone
  var FLOOR = 0.004;
  function lvl(v) { return v > FLOOR ? (v < 1 ? v : 1) : 0; }
  function fmtHz(f) {
    if (!(f > 0)) return "---";
    if (f < 1000) return Math.round(f) + "Hz";
    return (f / 1000).toFixed(f < 9950 ? 1 : 0) + "kHz";
  }

  // ---- geometry -------------------------------------------------------------------------
  function trace(pts, g) {
    var cum = [0], L = 0;
    for (var i = 1; i < pts.length; i++) {
      var dx = pts[i][0] - pts[i - 1][0], dy = pts[i][1] - pts[i - 1][1];
      L += Math.sqrt(dx * dx + dy * dy);
      cum.push(L);
    }
    return { pts: pts, cum: cum, len: L, g: g };
  }

  function buildTraces(w, h, m, a, compact, titleEnd) {
    var j = compact ? 4 : 6; // 45° jog size
    if (compact) {
      return [
        trace([[m, m + a], [m, h * 0.42], [m + j, h * 0.42 + j], [m + j, h * 0.68]], 0),
        trace([[w - m, h - m - a], [w - m, h * 0.58], [w - m - j, h * 0.58 - j], [w - m - j, h * 0.32]], 3)
      ];
    }
    var topJog = w * 0.62, topEnd = Math.min(topJog - j - 12, Math.max(w * 0.42, titleEnd + 16));
    return [
      trace([[m, m + a], [m, h * 0.40], [m + j, h * 0.40 + j], [m + j, h * 0.66]], 0),
      trace([[m + a, h - m], [w * 0.25, h - m], [w * 0.25 + j, h - m - j], [w * 0.44, h - m - j]], 1),
      trace([[w - m - a, m], [topJog, m], [topJog - j, m + j], [topEnd, m + j]], 2),
      trace([[w - m, h - m - a], [w - m, h * 0.60], [w - m - j, h * 0.60 - j], [w - m - j, h * 0.34]], 3)
    ];
  }

  // append the part of a trace between arc lengths s0..s1 to the current path
  function subPath(ctx, tr, s0, s1) {
    var p = tr.pts, c = tr.cum, started = false;
    for (var k = 0; k < p.length - 1; k++) {
      var a0 = c[k], a1 = c[k + 1], L = a1 - a0;
      if (a1 <= s0 || !(L > 0)) continue;
      if (a0 >= s1) break;
      var u0 = s0 > a0 ? (s0 - a0) / L : 0, u1 = s1 < a1 ? (s1 - a0) / L : 1;
      var dx = p[k + 1][0] - p[k][0], dy = p[k + 1][1] - p[k][1];
      if (!started) { ctx.moveTo(p[k][0] + dx * u0, p[k][1] + dy * u0); started = true; }
      ctx.lineTo(p[k][0] + dx * u1, p[k][1] + dy * u1);
    }
  }

  function haloStroke(ctx, lw, color) {
    ctx.lineWidth = lw + 2; ctx.strokeStyle = HALO; ctx.stroke();
    ctx.lineWidth = lw; ctx.strokeStyle = color; ctx.stroke();
  }

  function haloText(ctx, s, x, y, align, color) {
    ctx.textAlign = align;
    ctx.lineWidth = 1.75; ctx.strokeStyle = TEXT_HALO; ctx.strokeText(s, x, y);
    ctx.fillStyle = color; ctx.fillText(s, x, y);
  }

  // ---- cache (per canvas, rebuilt when palette / size / band count changes) ----------------
  function rebuild(st, ctx, PF, S, L, n, sig) {
    st.key = sig;
    var i, k;
    var fMin = 30, fMax = 16000;
    if (S && S.lo && S.hi && n > 0 && S.lo.length >= n && S.hi.length >= n) {
      var lo = +S.lo[0], hi = +S.hi[n - 1];
      if (lo > 0 && hi > lo * 1.5 && isFinite(hi)) { fMin = lo; fMax = hi; }
    }
    st.fMin = fMin; st.fMax = fMax;
    var lf = Math.log(fMax / fMin);
    var xOf = function (f) { return L.x0 + (Math.log(f / fMin) / lf) * L.W; };

    st.xs = new Float32Array(n); st.ys = new Float32Array(n);
    for (i = 0; i < n; i++) st.xs[i] = L.x0 + ((i + 0.5) / n) * L.W;

    var gS = ctx.createLinearGradient(L.x0, 0, L.x1, 0);
    var gF = ctx.createLinearGradient(L.x0, 0, L.x1, 0);
    var gD = ctx.createLinearGradient(L.x0, 0, L.x1, 0);
    for (k = 0; k <= 4; k++) {
      var c = PF.palAt(k / 4);
      gS.addColorStop(k / 4, PF.rgba(c, 1));
      gF.addColorStop(k / 4, PF.rgba(c, L.small ? 0.16 : 0.12));
      gD.addColorStop(k / 4, PF.rgba(mix(c, WHITE, 0.25), 0.95));
    }
    st.gStroke = gS; st.gFill = gF; st.gDots = gD;

    st.hud = mix(PF.palAt(0.3), WHITE, 0.65);        // pale, palette-tinted HUD ink
    st.bassCol = PF.palAt(0.06);
    st.sigCol = PF.palAt(0);
    st.gcol = [];
    for (k = 0; k < GROUPS.length; k++) st.gcol.push(PF.palAt((GROUPS[k][0] + GROUPS[k][1]) / 2));

    st.major = []; st.minor = [];
    for (k = 0; k < MAJOR.length; k++) {
      var f = MAJOR[k][0];
      if (f >= fMin * 0.98 && f <= fMax * 1.02) st.major.push([Math.min(L.x1, Math.max(L.x0, xOf(f))), MAJOR[k][1]]);
    }
    for (k = 0; k < MINOR.length; k++) {
      if (MINOR[k] > fMin && MINOR[k] < fMax) st.minor.push(xOf(MINOR[k]));
    }

    var titleEnd = 0;
    if (!L.compact) {
      if (!(st.titleW > 0)) {
        ctx.font = FONT;
        var mt = ctx.measureText(TITLE);
        st.titleW = mt && mt.width > 0 ? mt.width : TITLE.length * 5.4;
      }
      titleEnd = L.m + L.a + 6 + st.titleW + 10;
    }
    st.traces = buildTraces(L.w, L.h, L.m, L.a, L.compact, titleEnd);
  }

  // ---- draw -----------------------------------------------------------------------------
  function draw(ctx, w, h, o) {
    o = o || {};
    var PF = window.PF, S = PF && PF.S;
    var st = o.state || (o.state = {});
    var t = +o.t || 0, small = !!o.small;
    var i, k, v;

    ctx.clearRect(0, 0, w, h);
    if (!(w > 8 && h > 8) || !PF) return;

    // time step (only used to smooth audio-derived values; nothing moves on its own)
    var dt = st.lt === undefined ? 1 / 60 : t - st.lt;
    if (!(dt > 0)) dt = 0; else if (dt > 0.1) dt = 0.1;
    if (st.lt !== undefined && t < st.lt - 0.5) st.txtNext = undefined; // clock reset
    st.lt = t;

    // ---- audio frame ----
    var cur = S && S.cur, pk = S && S.peak;
    var n = S ? (S.N | 0) : 0;
    if (!cur || !pk) n = 0; else n = Math.max(0, Math.min(n, cur.length, pk.length));
    var bass = S ? lvl(S.bass) : 0;

    // ---- layout ----
    var compact = small || w < 300 || h < 110;
    var m = small ? 4 : (compact ? 5 : 6);
    var a = compact ? Math.max(6, Math.min(12, h * 0.1)) : Math.max(10, Math.min(20, h * 0.09));
    var x0 = compact ? Math.max(10, w * 0.07) : 28, x1 = w - x0;
    var yT = compact ? h * 0.16 : 32, yB = compact ? h * 0.84 : h - 30;
    var L = { w: w, h: h, m: m, a: a, x0: x0, x1: x1, W: x1 - x0, yT: yT, yB: yB, H: yB - yT, compact: compact, small: small };

    var p0 = PF.palAt(0), p1 = PF.palAt(0.5), p2 = PF.palAt(1);
    var key = p0.join(",") + ";" + p1.join(",") + ";" + p2.join(",") + "|" + w + "x" + h + "|" + n + "|" + (small ? 1 : 0);
    if (st.key !== key) rebuild(st, ctx, PF, S, L, n, key);
    var hud = st.hud, rgba = PF.rgba;

    // ---- analysis: energy, rms, dominant band, group energies ----
    var sum = 0, sq = 0, mx = 0, mi = -1;
    for (i = 0; i < n; i++) {
      v = lvl(cur[i]);
      st.ys[i] = yB - v * L.H;
      sum += v; sq += v * v;
      if (v > mx) { mx = v; mi = i; }
    }
    var mean = n ? sum / n : 0, rms = n ? Math.sqrt(sq / n) : 0;
    st.sig = follow(st.sig || 0, c01(mean * 4), dt, 0.04, 0.35);
    st.lv = follow(st.lv || 0, rms, dt, 0.03, 0.30);
    if (!st.te) st.te = [0, 0, 0, 0];
    for (k = 0; k < GROUPS.length; k++) {
      var e = 0;
      if (n > 0) {
        var g0 = Math.min(n - 1, Math.floor(GROUPS[k][0] * n));
        var g1 = Math.min(n, Math.max(g0 + 1, Math.floor(GROUPS[k][1] * n)));
        var gs = 0, gm = 0;
        for (i = g0; i < g1; i++) { v = lvl(cur[i]); gs += v; if (v > gm) gm = v; }
        e = c01((0.5 * gs / (g1 - g0) + 0.5 * gm) * 1.3);
      }
      st.te[k] = follow(st.te[k], e, dt, 0.02, 0.22);
    }

    // ================= static frame (faint, never moves) =================
    ctx.globalAlpha = 1;
    ctx.lineJoin = "miter"; ctx.lineCap = "butt";

    if (!compact) {
      // dotted 0 dB ceiling
      ctx.setLineDash([1, 4]);
      ctx.beginPath(); ctx.moveTo(x0, yT + 0.5); ctx.lineTo(x1, yT + 0.5);
      ctx.lineWidth = 1; ctx.strokeStyle = rgba(hud, 0.2); ctx.stroke();
      ctx.setLineDash([]);
    }

    // circuit traces (dim base layer) + end vias
    var tr, trs = st.traces, viaR = compact ? 1.5 : 2;
    ctx.beginPath();
    for (k = 0; k < trs.length; k++) {
      tr = trs[k];
      ctx.moveTo(tr.pts[0][0], tr.pts[0][1]);
      for (i = 1; i < tr.pts.length; i++) ctx.lineTo(tr.pts[i][0], tr.pts[i][1]);
      var ve = tr.pts[tr.pts.length - 1];
      ctx.moveTo(ve[0] + viaR, ve[1]); ctx.arc(ve[0], ve[1], viaR, 0, TAU);
    }
    haloStroke(ctx, 1, rgba(hud, 0.28));

    // ================= live: traces light up segment by segment =================
    var K = compact ? 4 : 6, gap = compact ? 1.5 : 2;
    var wide = compact ? 2.5 : 3.5, thin = compact ? 1.1 : 1.3;
    for (k = 0; k < trs.length; k++) {
      tr = trs[k];
      var en = st.te[tr.g];
      if (!(en > 0)) continue;
      var seg = tr.len / K, lit = en * K, nFull = Math.min(K, Math.floor(lit)), frac = nFull < K ? lit - nFull : 0;
      var col = st.gcol[tr.g];
      if (nFull > 0) {
        ctx.beginPath();
        for (i = 0; i < nFull; i++) subPath(ctx, tr, i * seg + (i ? gap / 2 : 0), (i + 1) * seg - gap / 2);
        ctx.lineWidth = wide; ctx.strokeStyle = rgba(col, 0.22); ctx.stroke();
        ctx.lineWidth = thin; ctx.strokeStyle = rgba(col, 0.95); ctx.stroke();
      }
      if (frac > 0.02) {
        ctx.beginPath();
        subPath(ctx, tr, nFull * seg + (nFull ? gap / 2 : 0), (nFull + 1) * seg - gap / 2);
        ctx.lineWidth = wide; ctx.strokeStyle = rgba(col, 0.22 * frac); ctx.stroke();
        ctx.lineWidth = thin; ctx.strokeStyle = rgba(col, 0.95 * frac); ctx.stroke();
      }
      var viaI = nFull >= K ? 1 : (nFull === K - 1 ? frac : 0);
      if (viaI > 0.02) {
        var vp = tr.pts[tr.pts.length - 1];
        ctx.beginPath(); ctx.arc(vp[0], vp[1], viaR + 0.6, 0, TAU);
        ctx.fillStyle = rgba(col, 0.95 * viaI); ctx.fill();
      }
    }

    // ================= corner brackets (pinwheel; dashes on the arms without a trace) =================
    ctx.lineCap = "square";
    ctx.beginPath();
    var C = [[m, m, 1, 1], [w - m, m, -1, 1], [w - m, h - m, -1, -1], [m, h - m, 1, -1]];
    for (k = 0; k < 4; k++) {
      var cx = C[k][0], cy = C[k][1], sx = C[k][2], sy = C[k][3];
      ctx.moveTo(cx + sx * a, cy); ctx.lineTo(cx, cy); ctx.lineTo(cx, cy + sy * a);
    }
    if (!compact) {
      ctx.moveTo(w - m, m + a + 3); ctx.lineTo(w - m, m + a + 6);         // TR vertical arm
      ctx.moveTo(w - m - a - 3, h - m); ctx.lineTo(w - m - a - 6, h - m); // BR horizontal arm
      ctx.moveTo(m, h - m - a - 3); ctx.lineTo(m, h - m - a - 6);         // BL vertical arm
    }
    haloStroke(ctx, compact ? 1 : 1.25, rgba(hud, 0.78));

    // ================= baseline, frequency ticks, level scale =================
    ctx.lineCap = "butt";
    ctx.beginPath();
    ctx.moveTo(x0 - 3, yB); ctx.lineTo(x1 + 3, yB);
    var tl = compact ? 2.5 : 4;
    for (k = 0; k < st.major.length; k++) { ctx.moveTo(st.major[k][0], yB); ctx.lineTo(st.major[k][0], yB + tl); }
    if (!compact) {
      for (k = 0; k < st.minor.length; k++) { ctx.moveTo(st.minor[k], yB); ctx.lineTo(st.minor[k], yB + 2); }
      for (k = 1; k <= 4; k++) {
        var yy = yB - (L.H * k) / 4, len = k === 4 ? 5 : (k === 2 ? 4 : 2.5);
        ctx.moveTo(x0 - 3, yy); ctx.lineTo(x0 - 3 - len, yy);
      }
    }
    haloStroke(ctx, 1, rgba(hud, 0.45));

    // ================= spectrum: faint fill, crisp polyline, dotted peaks =================
    if (n > 0) {
      var xs = st.xs, ys = st.ys;
      if (mx > 0) {
        ctx.beginPath(); ctx.moveTo(x0, yB); ctx.lineTo(x0, ys[0]);
        for (i = 0; i < n; i++) ctx.lineTo(xs[i], ys[i]);
        ctx.lineTo(x1, ys[n - 1]); ctx.lineTo(x1, yB); ctx.closePath();
        ctx.fillStyle = st.gFill; ctx.fill();
      }
      ctx.beginPath(); ctx.moveTo(x0, ys[0]);
      for (i = 0; i < n; i++) ctx.lineTo(xs[i], ys[i]);
      ctx.lineTo(x1, ys[n - 1]);
      ctx.lineJoin = "round"; ctx.lineCap = "round";
      var lw = small ? 1.1 : 1.6;
      ctx.strokeStyle = st.gStroke;
      if (!small && st.sig > 0.02) {
        // glow without shadowBlur: one wide, faint stroke of the same path (bass widens and brightens it)
        ctx.globalAlpha = st.sig * (0.13 + 0.14 * bass); ctx.lineWidth = lw + 4 + 4 * bass; ctx.stroke();
        ctx.globalAlpha = 1;
      }
      ctx.lineWidth = lw + 2; ctx.strokeStyle = HALO; ctx.stroke();
      ctx.globalAlpha = 0.5 + 0.5 * st.sig;
      ctx.lineWidth = lw; ctx.strokeStyle = st.gStroke; ctx.stroke();
      ctx.globalAlpha = 1;

      var pitch = L.W / n, dw = Math.max(1.2, Math.min(3.5, pitch * 0.55)), dh = small ? 1 : 1.5;
      var dots = 0;
      ctx.beginPath();
      for (i = 0; i < n; i++) {
        var pv = lvl(pk[i]);
        if (pv < 0.015) continue;
        ctx.rect(xs[i] - dw / 2, yB - pv * L.H - dh - 1.5, dw, dh); dots++;
      }
      if (dots) { ctx.fillStyle = st.gDots; ctx.fill(); }
    }

    if (compact) return;

    // ================= bass ring (inside the top-right bracket) =================
    var rcx = w - m - 16, rcy = m + 16, rr = 6;
    ctx.lineCap = "butt"; ctx.lineJoin = "miter";
    ctx.beginPath(); ctx.moveTo(rcx + rr, rcy); ctx.arc(rcx, rcy, rr, 0, TAU);
    for (k = 0; k < 4; k++) {
      var ca = Math.cos(k * Math.PI / 2), sa = Math.sin(k * Math.PI / 2);
      ctx.moveTo(rcx + ca * (rr + 2), rcy + sa * (rr + 2)); ctx.lineTo(rcx + ca * (rr + 4), rcy + sa * (rr + 4));
    }
    haloStroke(ctx, 1, rgba(hud, 0.42));
    if (bass > 0) {
      ctx.beginPath(); ctx.arc(rcx, rcy, rr, -Math.PI / 2, -Math.PI / 2 + bass * TAU);
      ctx.lineCap = "round"; ctx.lineWidth = 2; ctx.strokeStyle = rgba(st.bassCol, 0.95); ctx.stroke();
    }
    ctx.beginPath(); ctx.arc(rcx, rcy, 1 + 2.2 * bass, 0, TAU);
    ctx.fillStyle = bass > 0 ? rgba(st.bassCol, 0.4 + 0.6 * bass) : rgba(hud, 0.35); ctx.fill();

    // ================= text: title, signal dot, readout, frequency labels =================
    if (st.txtNext === undefined || t >= st.txtNext) {       // 10 Hz text refresh
      st.txtNext = t + 0.1;
      var db = st.lv > 0.002 ? 20 * Math.log10(st.lv) : -Infinity;
      st.dbS = isFinite(db) ? (db > -0.05 ? "0.0" : MINUS + (-db).toFixed(1)) : MINUS + "∞";
      var hz = "---";
      if (mi >= 0 && mx >= 0.06) {
        var fc = S.fc && S.fc.length > mi && S.fc[mi] > 0 ? +S.fc[mi] : st.fMin * Math.pow(st.fMax / st.fMin, (mi + 0.5) / n);
        hz = fmtHz(fc);
      }
      st.hzS = hz;
    }
    ctx.font = FONT; ctx.textBaseline = "alphabetic"; ctx.lineJoin = "round";
    var tx = m + a + 6;
    haloText(ctx, TITLE, tx, m + 3.5, "left", rgba(hud, 0.7));
    var dx = tx + st.titleW + 7;
    ctx.beginPath(); ctx.arc(dx, m, 2, 0, TAU);
    ctx.lineWidth = 1; ctx.strokeStyle = rgba(hud, 0.5); ctx.stroke();
    if (st.sig > 0.02) { ctx.fillStyle = rgba(st.sigCol, st.sig); ctx.fill(); }

    var rd = (w >= 420 ? "PK " + pad(st.hzS, 6) + "   " : "") + "LVL " + pad(st.dbS, 5) + " dB";
    haloText(ctx, rd, rcx - rr - 7, rcy + 3, "right", rgba(hud, 0.68));

    for (k = 0; k < st.major.length; k++) haloText(ctx, st.major[k][1], st.major[k][0], yB + 13, "center", rgba(hud, 0.58));
  }

  window.PF_EXTRA = window.PF_EXTRA || [];
  window.PF_EXTRA.push({ id: "hud", name: "儀表", en: "HUD", draw: draw });
})();
