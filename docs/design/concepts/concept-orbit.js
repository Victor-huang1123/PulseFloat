/* PulseFloat concept theme — ORBIT / 軌道
 *
 * The spectrum lives on a glowing planet limb. A huge planet whose centre lies
 * far below the window shows its horizon as a shallow arc across the lower part
 * of the window. Bands rise from the limb as thin light pillars normal to the
 * curve (low → left, high → right): a tapered glow that is wide where it leaves
 * the atmosphere, a crisp core, a bright head. Peaks float above as small dots.
 * The atmosphere breathes with bass, a faint lat/long grid sits on the planet
 * and turns only while there is sound, and a tiny satellite drifts along an
 * orbit ellipse (slipping behind the planet) only while there is sound.
 *
 * Silence: limb + faint atmosphere + dotted tick scale + grid + soft night-side
 * shadow + tiny HUD text, all static. Every moving part is integrated from audio.
 *
 * Port notes: only solid-colour quads, arcs, one ellipse, linear/radial
 * gradients on large shapes, and fillText. No shadowBlur, no clipping, no
 * compositing modes. Per-band colours are cached per palette.
 */
(function () {
  "use strict";

  var TAU = Math.PI * 2, HALF_PI = Math.PI / 2;
  var MONO = 'ui-monospace, "SF Mono", Menlo, monospace';
  var VEIL = "5,12,30";            // night-side navy for the planet shadow
  var INK = "205,240,255";         // pale HUD cyan-white for text / satellite
  var FORMULA = "r = a(1−e²) / (1 + e·cosθ)";
  var TITLE = "O R B I T";

  function c01(v) { return v > 0 ? (v < 1 ? v : 1) : 0; }   // also maps NaN → 0
  function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
  function lift(c, k) {
    return [Math.round(c[0] + (255 - c[0]) * k), Math.round(c[1] + (255 - c[1]) * k), Math.round(c[2] + (255 - c[2]) * k)];
  }
  function col(PF, t, k) { var c = PF.palAt(t); return k ? lift(c, k) : c; }

  // Palette mapped onto the band span [xa, xb], alpha fading to 0 at the window edges.
  function spanGrad(ctx, PF, w, xa, xb, a, k) {
    var g = ctx.createLinearGradient(0, 0, w, 0), fa = xa / w, fb = xb / w;
    g.addColorStop(0, PF.rgba(col(PF, 0, k), 0));
    for (var j = 0; j <= 4; j++) g.addColorStop(fa + (fb - fa) * j / 4, PF.rgba(col(PF, j / 4, k), a));
    g.addColorStop(1, PF.rgba(col(PF, 1, k), 0));
    return g;
  }

  // Quad from radius r0 (half-width h0) to r1 (half-width h1) along unit direction (c, s).
  function quad(ctx, cx, cy, c, s, r0, h0, r1, h1) {
    var nx = -s, ny = c;
    ctx.beginPath();
    ctx.moveTo(cx + c * r0 + nx * h0, cy + s * r0 + ny * h0);
    ctx.lineTo(cx + c * r1 + nx * h1, cy + s * r1 + ny * h1);
    ctx.lineTo(cx + c * r1 - nx * h1, cy + s * r1 - ny * h1);
    ctx.lineTo(cx + c * r0 - nx * h0, cy + s * r0 - ny * h0);
    ctx.closePath();
    ctx.fill();
  }
  function dot(ctx, x, y, r) { ctx.beginPath(); ctx.arc(x, y, r, 0, TAU); ctx.fill(); }

  function build(st, key, w, h, small, n) {
    var yA = h * (small ? 0.72 : 0.70);                 // limb apex
    var d = w * 0.38, s = Math.max(3, h * 0.16);        // band half-span, sagitta over it
    var R = (d * d + s * s) / (2 * s);
    var cx = w / 2, cy = yA + R;
    var th = Math.asin(Math.min(1, d / R));             // band half-angle
    var aF = Math.asin(Math.min(1, (w / 2 + 6) / R));   // limb half-angle (full width)
    var aL = Math.asin(Math.min(1, (d + w * 0.07) / R)); // atmosphere half-angle (lit part)
    var maxLen = Math.max(4, yA - h * (small ? 0.08 : 0.07) - (small ? 3 : 7));
    var ca = new Float32Array(n), sa = new Float32Array(n);
    for (var i = 0; i < n; i++) {
      var p = -HALF_PI + th * (2 * (i + 0.5) / n - 1);
      ca[i] = Math.cos(p); sa[i] = Math.sin(p);
    }
    var pitch = n > 0 ? (2 * th * R) / n : 6;
    var G = {
      yA: yA, R: R, cx: cx, cy: cy, aF: aF, aL: aL, maxLen: maxLen, below: Math.max(8, h - yA),
      xa: cx - d, xb: cx + d,
      core: clamp(pitch * 0.26, small ? 0.8 : 0.9, 2),
      glow: clamp(pitch * 0.95, 2, 8),
      rb: R + (small ? 1.5 : 2.5),                       // pillar base radius
      rt: R + (small ? 3 : 4.5)                          // tick-scale radius
    };
    // satellite orbit and the stretch of it hidden behind the planet (param interval [h0, h1])
    G.ex = cx; G.ey = yA - h * 0.1; G.erx = w * 0.4; G.ery = h * 0.24; G.er = -0.07;
    G.ce = Math.cos(G.er); G.se = Math.sin(G.er); G.h0 = -1; G.h1 = -1;
    for (var k = 0, inRun = false; k <= 256; k++) {
      var q = TAU * k / 256, pt = ellPt(G, q), hid = Math.hypot(pt[0] - cx, pt[1] - cy) < R + 1;
      if (hid && !inRun) { G.h0 = q; inRun = true; }
      if (!hid && inRun) { G.h1 = q; inRun = false; }
    }
    if (G.h1 < G.h0) { G.h0 = G.h1 = -1; }              // no single hidden run: draw all
    st.G = G; st.ca = ca; st.sa = sa; st.L = new Float32Array(n); st.key = key;
  }
  function ellPt(G, p) {
    var cp = Math.cos(p), sp = Math.sin(p);
    return [G.ex + G.erx * cp * G.ce - G.ery * sp * G.se, G.ey + G.erx * cp * G.se + G.ery * sp * G.ce];
  }

  // Per-band colour strings, cached per palette and band count.
  function bandCols(st, PF, n) {
    var a = PF.palAt(0), b = PF.palAt(0.5), c = PF.palAt(1);
    var key = n + ":" + a.join(",") + ":" + b.join(",") + ":" + c.join(",");
    if (st.ck !== key) {
      st.ck = key; st.cBase = []; st.cHead = []; st.cTick = [];
      for (var i = 0; i < n; i++) {
        var p = PF.palAt(n > 1 ? i / (n - 1) : 0);
        st.cBase.push(PF.rgba(p, 1));
        st.cHead.push(PF.rgba(lift(p, 0.5), 1));
        st.cTick.push(PF.rgba(lift(p, 0.3), 0.6));
      }
    }
  }

  function draw(ctx, w, h, o) {
    ctx.clearRect(0, 0, w, h);
    if (!(w > 8 && h > 8)) return;
    var PF = window.PF, S = PF.S, st = o.state, small = !!o.small;
    var cur = S.cur || [], pkA = S.peak || [];
    var n = Math.max(0, Math.min(S.N | 0, cur.length | 0, pkA.length | 0));
    var bass = c01(S.bass);
    var i, j, k, x, y, r, Li, c, s;

    // ---- clock: used ONLY to integrate audio-driven motion
    var t = +o.t; if (!isFinite(t)) t = 0;
    var dt = st.lastT == null ? 0 : t - st.lastT; st.lastT = t;
    dt = dt > 0 ? (dt < 0.1 ? dt : 0.1) : 0;

    var key = w + "x" + h + (small ? "s" : "") + "/" + n;
    if (st.key !== key) build(st, key, w, h, small, n);
    bandCols(st, PF, n);
    var G = st.G, ca = st.ca, sa = st.sa, L = st.L;
    var R = G.R, cx = G.cx, cy = G.cy, below = G.below;
    var a0 = -HALF_PI - G.aF, a1 = -HALF_PI + G.aF;

    var sum = 0;
    for (i = 0; i < n; i++) { var v = c01(cur[i]); L[i] = v * G.maxLen; sum += v; }
    var energy = n ? sum / n : 0;
    var live = c01(energy * 6);                       // 0 in silence, ~1 with any music

    // audio-integrated state (frozen when silent)
    st.rot = ((st.rot || 0) + dt * (0.25 * energy + 0.2 * bass)) % 1;          // grid spin, in cells
    if (st.satPh == null) st.satPh = 3.6;                                          // start upper-left
    st.satPh = (st.satPh + dt * live * (0.18 + 0.7 * bass)) % TAU;
    var sA = st.satA || 0;
    sA += (live - sA) * (1 - Math.exp(-dt / (live > sA ? 0.3 : 0.6)));
    st.satA = sA;

    // ---- 1. planet night-side shadow (elliptical fade centred under the apex)
    ctx.save();
    ctx.beginPath();
    ctx.arc(cx, cy, R, a0, a1);
    ctx.lineTo(w + 2, h + 2); ctx.lineTo(-2, h + 2); ctx.closePath();
    ctx.translate(cx, G.yA); ctx.scale(1, below / (w * 0.5));   // path is already built: only the gradient squashes
    var gv = ctx.createRadialGradient(0, 0, 0, 0, 0, w * 0.5);
    gv.addColorStop(0, "rgba(" + VEIL + ",0.28)"); gv.addColorStop(0.5, "rgba(" + VEIL + ",0.15)"); gv.addColorStop(1, "rgba(" + VEIL + ",0)");
    ctx.fillStyle = gv; ctx.fill();
    ctx.restore();

    // ---- 2. planet grid: latitudes fade with depth, meridians foreshortened and fading to the sides
    var gc = col(PF, 0.5, 0.35), gA = 0.24 + 0.12 * bass;
    ctx.lineWidth = small ? 0.5 : 0.7;
    var lat = small ? [0.16, 0.42, 0.8] : [0.09, 0.22, 0.4, 0.63, 0.92];
    for (j = 0; j < lat.length; j++) {
      r = R - below * lat[j];
      var la = gA * (1 - 0.85 * lat[j]), inner = G.aF * 0.55;
      ctx.strokeStyle = PF.rgba(gc, la);
      ctx.beginPath(); ctx.arc(cx, cy, r, -HALF_PI - inner, -HALF_PI + inner); ctx.stroke();
      ctx.strokeStyle = PF.rgba(gc, la * 0.4);
      ctx.beginPath(); ctx.arc(cx, cy, r, a0, -HALF_PI - inner); ctx.stroke();
      ctx.beginPath(); ctx.arc(cx, cy, r, -HALF_PI + inner, a1); ctx.stroke();
    }
    var dl = Math.PI / (small ? 9 : 14), kmax = Math.ceil(HALF_PI / dl) + 1, rIn = R - below * 0.72;
    for (k = -kmax; k <= kmax; k++) {
      var lam = (k + st.rot) * dl;
      if (lam <= -HALF_PI + 0.05 || lam >= HALF_PI - 0.05) continue;
      var pm = -HALF_PI + G.aF * Math.sin(lam);
      c = Math.cos(pm); s = Math.sin(pm);
      ctx.strokeStyle = PF.rgba(gc, gA * 0.8 * Math.cos(lam));
      ctx.beginPath(); ctx.moveTo(cx + c * (R - 1), cy + s * (R - 1)); ctx.lineTo(cx + c * rIn, cy + s * rIn); ctx.stroke();
    }

    // ---- 3. atmosphere (breathes with bass) + rim light inside the limb + limb line
    ctx.save();
    ctx.lineCap = "butt";
    // Atmosphere = a lens between the limb and an outer arc through the limb's end points,
    // so it is TH thick at the apex and thins to nothing at the window edges. Smooth radial falloff.
    var TH = h * (small ? 0.09 : 0.075) * (1 + 1.6 * bass);
    var X = R * Math.sin(G.aL), yE = cy - R * Math.cos(G.aL), top = G.yA - TH;
    var cy2 = (X * X + yE * yE - top * top) / (2 * (yE - top)), R2 = cy2 - top;
    ctx.beginPath();
    ctx.arc(cx, cy, R, -HALF_PI - G.aL, -HALF_PI + G.aL);
    ctx.arc(cx, cy2, R2, Math.atan2(yE - cy2, X), Math.atan2(yE - cy2, -X), true);
    ctx.closePath();
    var ac = col(PF, 0.5, 0.15), aa = c01(0.3 + 0.45 * bass);
    var ga = ctx.createRadialGradient(cx, cy, R, cx, cy, R + TH);
    ga.addColorStop(0, PF.rgba(ac, aa)); ga.addColorStop(0.22, PF.rgba(ac, aa * 0.55));
    ga.addColorStop(0.6, PF.rgba(ac, aa * 0.16)); ga.addColorStop(1, PF.rgba(ac, 0));
    ctx.fillStyle = ga; ctx.fill();
    var ti = h * (small ? 0.05 : 0.04) * (1 + bass);
    ctx.lineWidth = ti;
    ctx.strokeStyle = spanGrad(ctx, PF, w, G.xa, G.xb, c01(0.12 + 0.22 * bass), 0);
    ctx.beginPath(); ctx.arc(cx, cy, R - ti / 2, a0, a1); ctx.stroke();

    ctx.beginPath(); ctx.arc(cx, cy, R, a0, a1);
    var hg = ctx.createLinearGradient(0, 0, w, 0);     // dark halo so the limb reads on light wallpapers
    hg.addColorStop(0, "rgba(0,0,0,0)"); hg.addColorStop(G.xa / w, "rgba(0,0,0,0.22)");
    hg.addColorStop(G.xb / w, "rgba(0,0,0,0.22)"); hg.addColorStop(1, "rgba(0,0,0,0)");
    ctx.lineWidth = small ? 2.6 : 3.4; ctx.strokeStyle = hg; ctx.stroke();
    ctx.lineWidth = small ? 1 : 1.4;
    ctx.strokeStyle = spanGrad(ctx, PF, w, G.xa, G.xb, c01(0.66 + 0.34 * bass), 0.2);
    ctx.stroke();
    ctx.restore();

    // ---- 4. tick scale along the horizon (the resting "instrument")
    var major = Math.max(4, Math.round(n / 8));
    for (i = 0; i < n; i++) {
      ctx.fillStyle = st.cTick[i];
      dot(ctx, cx + ca[i] * G.rt, cy + sa[i] * G.rt, small ? 0.55 : (i % major === 0 ? 1.15 : 0.7));
    }

    // ---- 5. light pillars: halo, tapered glow, core, head (solid per-band quads)
    var rb = G.rb, hc = G.core / 2, hgw = G.glow / 2;
    ctx.fillStyle = "rgba(0,0,0,0.2)";
    for (i = 0; i < n; i++) { Li = L[i]; if (Li >= 0.75) quad(ctx, cx, cy, ca[i], sa[i], rb - 0.5, hc + 1.1, rb + Li + 1.1, hc + 1.1); }
    ctx.globalAlpha = c01(0.2 + 0.14 * bass);
    for (i = 0; i < n; i++) { Li = L[i]; if (Li >= 0.75) { ctx.fillStyle = st.cBase[i]; quad(ctx, cx, cy, ca[i], sa[i], rb, hgw, rb + Li + 1, hc + 0.5); } }
    ctx.globalAlpha = 0.95;
    for (i = 0; i < n; i++) { Li = L[i]; if (Li >= 0.75) { ctx.fillStyle = st.cBase[i]; quad(ctx, cx, cy, ca[i], sa[i], rb, hc, rb + Li, hc); } }
    ctx.globalAlpha = 1;
    if (!small) {
      ctx.globalAlpha = 0.16;                          // faint reflection down into the atmosphere
      for (i = 0; i < n; i++) {
        var rl = Math.min(L[i] * 0.22, below * 0.45); if (rl < 1.5) continue;
        ctx.fillStyle = st.cBase[i]; quad(ctx, cx, cy, ca[i], sa[i], R - 2, hc, R - 2 - rl, hc * 0.5);
      }
      ctx.globalAlpha = 1;
      var hr = Math.max(1, G.core * 0.8);              // bright heads on the taller pillars
      for (i = 0; i < n; i++) {
        Li = L[i]; if (Li < 6) continue;
        ctx.fillStyle = st.cHead[i]; dot(ctx, cx + ca[i] * (rb + Li), cy + sa[i] * (rb + Li), hr);
      }
    }

    // ---- 6. peaks: floating dots with a hairline dark rim
    var gap = small ? 2 : 3.5, pr = small ? 0.9 : 1.45;
    for (i = 0; i < n; i++) {
      var pv = c01(pkA[i]); if (pv < 0.015) continue;
      r = rb + pv * G.maxLen + gap; x = cx + ca[i] * r; y = cy + sa[i] * r;
      ctx.fillStyle = "rgba(0,0,0,0.2)"; dot(ctx, x, y, pr + 0.7);
      ctx.fillStyle = st.cHead[i]; dot(ctx, x, y, pr);
    }

    // ---- 7. satellite: only while there is sound; slips behind the planet
    if (!small && sA > 0.01) {
      var ph = ((st.satPh % TAU) + TAU) % TAU, hid0 = G.h0, hid1 = G.h1, hasHide = hid1 > hid0;
      ctx.save();
      ctx.lineWidth = 0.7;
      ctx.strokeStyle = "rgba(" + INK + "," + (0.12 * sA) + ")";
      ctx.beginPath();
      if (hasHide) ctx.ellipse(G.ex, G.ey, G.erx, G.ery, G.er, hid1, hid0 + TAU);
      else ctx.ellipse(G.ex, G.ey, G.erx, G.ery, G.er, 0, TAU);
      ctx.stroke();
      if (!(hasHide && ph > hid0 && ph < hid1)) {
        var tl = 0.36, ta = ph - tl;
        if (hasHide && ph >= hid1 && ta < hid1) ta = hid1;
        ctx.lineCap = "round"; ctx.lineWidth = 1.1;
        var tm = (ta + ph) / 2;                          // comet trail in two fading halves
        ctx.strokeStyle = "rgba(" + INK + "," + (0.18 * sA) + ")";
        ctx.beginPath(); ctx.ellipse(G.ex, G.ey, G.erx, G.ery, G.er, ta, tm); ctx.stroke();
        ctx.strokeStyle = "rgba(" + INK + "," + (0.5 * sA) + ")";
        ctx.beginPath(); ctx.ellipse(G.ex, G.ey, G.erx, G.ery, G.er, tm, ph); ctx.stroke();
        var P = ellPt(G, ph); x = P[0]; y = P[1];
        var vis = sA * c01((Math.hypot(x - cx, y - cy) - R) / 8);
        if (vis > 0.01) {
          var cp = Math.cos(ph), sp = Math.sin(ph);
          var tx = -G.erx * sp * G.ce - G.ery * cp * G.se, ty = -G.erx * sp * G.se + G.ery * cp * G.ce;
          var tn = Math.sqrt(tx * tx + ty * ty) || 1, nx = -ty / tn, ny = tx / tn;
          ctx.fillStyle = "rgba(0,0,0," + (0.25 * vis) + ")"; dot(ctx, x, y, 3);
          ctx.lineCap = "butt"; ctx.lineWidth = 1.3;     // solar panels
          ctx.strokeStyle = PF.rgba(col(PF, 0.5, 0.4), 0.8 * vis);
          ctx.beginPath();
          ctx.moveTo(x + nx * 2, y + ny * 2); ctx.lineTo(x + nx * 5, y + ny * 5);
          ctx.moveTo(x - nx * 2, y - ny * 2); ctx.lineTo(x - nx * 5, y - ny * 5);
          ctx.stroke();
          ctx.fillStyle = "rgba(234,249,255," + (0.95 * vis) + ")"; dot(ctx, x, y, 1.5);
        }
      }
      ctx.restore();
    }

    // ---- 8. HUD text, printed on the planet below the spectrum (offset dark copy = cheap halo)
    if (!small && h >= 120) {
      var ty0 = h - 10, half = (G.xb - G.xa) * 0.31, tx0 = cx - half;
      ctx.save();
      ctx.textBaseline = "alphabetic";
      ctx.font = "9.5px " + MONO; ctx.textAlign = "left";
      ctx.fillStyle = "rgba(0,0,0,0.25)"; ctx.fillText(TITLE, tx0 + 0.6, ty0 + 0.8);
      ctx.fillStyle = "rgba(" + INK + ",0.46)"; ctx.fillText(TITLE, tx0, ty0);
      ctx.fillStyle = PF.rgba(col(PF, 0.5, 0.3), 0.28 + 0.62 * c01(energy * 5));   // signal-lock lamp
      dot(ctx, tx0 - 8, ty0 - 3.4, 2);
      if (w >= 360) {
        ctx.font = "9px " + MONO; ctx.textAlign = "right";
        ctx.fillStyle = "rgba(0,0,0,0.18)"; ctx.fillText(FORMULA, cx + half + 0.6, ty0 + 0.8);
        ctx.fillStyle = "rgba(" + INK + ",0.26)"; ctx.fillText(FORMULA, cx + half, ty0);
      }
      ctx.restore();
    }
  }

  window.PF_EXTRA = window.PF_EXTRA || [];
  window.PF_EXTRA.push({ id: "orbit", name: "軌道", en: "ORBIT", draw: draw });
})();
