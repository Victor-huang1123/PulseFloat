/* PulseFloat concept theme — CONSTELLATION / 星圖
 *
 * Every band is a star scattered (deterministically) around one gentle S-curve,
 * an "ecliptic" that rises from lower-left to upper-right. Low frequencies sit on
 * the left, highs on the right, above a faint planet limb in the bottom-right
 * corner (nod to the Pinterest reference).
 *
 *   silence  : dim star dots + dark halos, dotted ecliptic, octave ticks,
 *              planet limb, very faint math fragments. Fully static.
 *   energy   : stars grow, whiten, glow and drift slightly outward from the curve;
 *              loud stars get "+" diffraction spikes.
 *   links    : each loud star links to its nearest loud forward neighbour, so
 *              constellations form and reorganise with the music.
 *   peaks    : while a peak cap hangs above a falling band, a small "x" twinkle
 *              floats just outside the star and fades as the cap falls.
 *   bass     : onset detector spawns a soft expanding ring at the brightest star (α);
 *              math fragments brighten and drift (drift phase only advances with energy).
 *   HUD      : α gets a reticle + "α 1.2 kHz" readout; β, γ get a Greek letter and a
 *              dashed asterism line. No text in thumbnails.
 *
 * Port notes: only lines, arcs, linear/radial gradients, dashes, text; one shadowBlur
 * per frame (α core). Star glow uses one radial gradient per band, cached per palette,
 * drawn through translate/scale (CoreGraphics: CGGradient cache + drawRadialGradient).
 */
(function () {
  "use strict";

  var TAU = Math.PI * 2;
  var MONO = 'ui-monospace, "SF Mono", Menlo, monospace';
  var WHITE = [255, 255, 255];
  var CYAN = [127, 227, 255];
  var BLACK = [0, 0, 0];

  // Background formula fragments: position in window fractions, text alignment.
  var FRAGS = [
    { s: "Σ|X[k]|²", x: 0.045, y: 0.14, al: "left" },               // Σ|X[k]|²
    { s: "20·log₁₀|X|", x: 0.34, y: 0.11, al: "left" },         // 20·log₁₀|X|
    { s: "f = k·fs/N", x: 0.47, y: 0.89, al: "left" },                    // f = k·fs/N
    { s: "∫|H(ω)|²dω", x: 0.955, y: 0.90, al: "right" }    // ∫|H(ω)|²dω
  ];
  var DECADES = [100, 1000, 10000];
  var PH_WRAP = 16 * Math.PI;            // drift uses ph*0.5 and ph*0.375 -> common period 16π
  var RING_LIFE = 1.05;                  // seconds
  var PROM_THR = 0.25;                   // band level at which a local peak may join a constellation

  // ---------------------------------------------------------------- helpers
  function cl01(x) { return x > 0 ? (x < 1 ? x : 1) : 0; }
  // dead zone: residual noise-floor values (< 2%) read as true silence, so the chart stays perfectly still
  function lvl(x) { x = +x || 0; return x > 0.02 ? (x < 1 ? (x - 0.02) / 0.98 : 1) : 0; }
  function smooth01(x) { x = cl01(x); return x * x * (3 - 2 * x); }

  var TMP = [0, 0, 0];
  function mix(c, d, k) {                // writes into a shared scratch array
    TMP[0] = c[0] + (d[0] - c[0]) * k;
    TMP[1] = c[1] + (d[1] - c[1]) * k;
    TMP[2] = c[2] + (d[2] - c[2]) * k;
    return TMP;
  }
  function css(c, a) {
    a = a > 0 ? (a < 1 ? Math.round(a * 1000) / 1000 : 1) : 0;
    return "rgba(" + Math.round(c[0] || 0) + "," + Math.round(c[1] || 0) + "," + Math.round(c[2] || 0) + "," + a + ")";
  }

  // Integer hash -> [0,1). Ports bit-exactly to Swift with UInt32 &* and >>.
  function hash(i, salt) {
    var x = Math.imul(i + 1, 0x9E3779B1) ^ Math.imul(salt + 7, 0x85EBCA77);
    x = Math.imul(x ^ (x >>> 15), 0x2C1B3C6D);
    x = Math.imul(x ^ (x >>> 12), 0x297A2D39);
    x ^= x >>> 15;
    return (x >>> 0) / 4294967296;
  }

  // The ecliptic: y as a fraction of h, for u in [0,1] across the window.
  var A1 = 5.0265, A2 = 14.451;
  function spineY(u, h) { return h * (0.5 + 0.17 * Math.sin(A1 * u + 0.7) + 0.05 * Math.sin(A2 * u + 2.1)); }
  function spineDY(u, h) { return h * (0.17 * A1 * Math.cos(A1 * u + 0.7) + 0.05 * A2 * Math.cos(A2 * u + 2.1)); }

  function fmtHz(f) {
    if (!(f > 0)) return "";
    if (f < 1000) return Math.round(f) + " Hz";
    return (f / 1000).toFixed(f < 9950 ? 1 : 0) + " kHz";
  }

  // ---------------------------------------------------------------- layout (per N / size)
  function build(st, key, N, w, h, small) {
    var padX = w * 0.055, use = w - 2 * padX, pitch = use / N;
    var spread = h * (small ? 0.19 : 0.21);
    var L = {
      N: N, padX: padX, use: use,
      bx: new Float32Array(N), by: new Float32Array(N),   // resting star position
      ox: new Float32Array(N), oy: new Float32Array(N),   // unit vector away from the curve
      X: new Float32Array(N), Y: new Float32Array(N),     // per-frame position
      V: new Float32Array(N), R: new Float32Array(N),     // per-frame level / core radius
      PE: new Float32Array(N), ci: new Int16Array(N),     // prominence envelope / candidate list
      la: new Int16Array(N * 2), lb: new Int16Array(N * 2), lw: new Float32Array(N * 2),
      sp: null
    };
    for (var i = 0; i < N; i++) {
      var x = padX + ((i + 0.5) / N) * use + (hash(i, 1) - 0.5) * 0.85 * pitch;
      var u = (x - padX) / use;
      var ys = spineY(u, h), dyu = spineDY(u, h);
      var len = Math.sqrt(use * use + dyu * dyu) || 1;
      var nx = -dyu / len, ny = use / len;
      var d = (hash(i, 2) + hash(i, 3) - 1) * spread;     // triangular: denser near the curve
      var s = d < 0 ? -1 : 1;
      L.bx[i] = x + nx * d; L.by[i] = ys + ny * d;
      L.ox[i] = nx * s; L.oy[i] = ny * s;
    }
    var M = small ? 24 : 48;
    L.sp = new Float32Array((M + 1) * 2);
    for (var k = 0; k <= M; k++) {
      var uu = -0.03 + 1.06 * k / M;
      L.sp[2 * k] = padX + uu * use; L.sp[2 * k + 1] = spineY(uu, h);
    }
    st.L = L; st.key = key;
    st.tgt = -1; st.b = -1; st.c = -1; st.rx = null; st.ra = 0;
    st.gsig = "";                                         // force gradient rebuild
    return L;
  }

  // ---------------------------------------------------------------- palette caches (per palette / N / size)
  function caches(st, ctx, PF, L, w, h) {
    var p0 = PF.palAt(0), p1 = PF.palAt(0.5), p2 = PF.palAt(1);
    var sig = st.key + "|" + p0.join(",") + "|" + p1.join(",") + "|" + p2.join(",");
    if (st.gsig === sig) return;
    st.gsig = sig;
    var N = L.N, i, g, c;
    st.cols = new Array(N); st.grads = new Array(N);
    for (i = 0; i < N; i++) {
      c = PF.palAt(N > 1 ? i / (N - 1) : 0);
      st.cols[i] = [c[0], c[1], c[2]];
      g = ctx.createRadialGradient(0, 0, 0, 0, 0, 1);    // unit glow, placed by translate/scale
      g.addColorStop(0, css(c, 0.9));
      g.addColorStop(0.28, css(c, 0.3));
      g.addColorStop(1, css(c, 0));
      st.grads[i] = g;
    }
    // horizontal palette ramp for the ecliptic and constellation lines (x ~ band index)
    g = ctx.createLinearGradient(L.padX, 0, L.padX + L.use, 0);
    for (i = 0; i <= 4; i++) g.addColorStop(i / 4, css(PF.palAt(i / 4), 1));
    st.G = g;
    // planet limb: colour stroke + matching dark under-stroke, both fading at the ends
    var lcx = w + h * 0.05, lcy = h * 1.9, lR = h * 1.35, a1 = -Math.PI / 2 - 0.86;
    var lc = PF.palAt(0.3);
    var x0 = w, y0 = lcy - lR, x1 = lcx + lR * Math.cos(a1), y1 = lcy + lR * Math.sin(a1);
    g = ctx.createLinearGradient(x0, y0, x1, y1);
    g.addColorStop(0, css(lc, 0)); g.addColorStop(0.2, css(lc, 1)); g.addColorStop(0.62, css(lc, 0.7)); g.addColorStop(1, css(lc, 0));
    st.limbC = g;
    g = ctx.createLinearGradient(x0, y0, x1, y1);
    g.addColorStop(0, css(BLACK, 0)); g.addColorStop(0.2, css(BLACK, 0.18)); g.addColorStop(0.62, css(BLACK, 0.13)); g.addColorStop(1, css(BLACK, 0));
    st.limbK = g;
  }

  function addLink(L, nl, i, j) {
    var lo = i < j ? i : j, hi = i < j ? j : i, k;
    for (k = 0; k < nl; k++) if (L.la[k] === lo && L.lb[k] === hi) return nl;
    if (nl >= L.la.length) return nl;
    L.la[nl] = lo; L.lb[nl] = hi;
    L.lw[nl] = 0.95 * Math.min(L.PE[lo], L.PE[hi]) * smooth01((Math.min(L.V[lo], L.V[hi]) - 0.2) / 0.35);
    return nl + 1;
  }

  // second-best star away from a (and b), sticky so labels don't flicker
  function pickOther(V, N, a, b, prev) {
    var best = -1, bv = -1, i;
    for (i = 0; i < N; i++) {
      if (Math.abs(i - a) < 4 || (b >= 0 && Math.abs(i - b) < 4)) continue;
      if (V[i] > bv) { bv = V[i]; best = i; }
    }
    if (prev >= 0 && prev < N && prev !== best && Math.abs(prev - a) >= 4 && (b < 0 || Math.abs(prev - b) >= 4) &&
        V[prev] > 0.1 && V[prev] >= bv * 0.85) best = prev;
    return best;
  }

  // ---------------------------------------------------------------- draw
  function draw(ctx, w, h, o) {
    ctx.clearRect(0, 0, w, h);
    var PF = window.PF;
    if (!PF || !PF.S || !(w >= 8) || !(h >= 8)) return;
    var S = PF.S, cur = S.cur, pk = S.peak;
    if (!cur || !pk) return;
    var N = Math.min(S.N | 0, cur.length | 0, pk.length | 0);
    if (N < 2) return;
    o = o || {};
    var st = o.state || (o.state = {});
    var small = !!o.small;

    var t = +o.t; if (!isFinite(t)) t = 0;
    var dt = st.lt == null ? 0 : t - st.lt; st.lt = t;
    dt = dt > 0 ? (dt < 0.1 ? dt : 0.1) : 0;
    var bass = lvl(S.bass);

    var key = N + "|" + w + "|" + h + "|" + (small ? 1 : 0);
    var L = st.key === key ? st.L : build(st, key, N, w, h, small);
    caches(st, ctx, PF, L, w, h);
    var cols = st.cols, X = L.X, Y = L.Y, V = L.V, R = L.R;
    var i, j, k, v, c, x, y;

    // ---- per-star state from audio
    var lift = h * (small ? 0.04 : 0.05), pe;
    var sum = 0, hiSum = 0, hiN = 0, a = 0, av = -1, hi0 = Math.floor(N * 0.75);
    for (i = 0; i < N; i++) {
      v = lvl(cur[i]);
      V[i] = v; sum += v;
      if (i >= hi0) { hiSum += v; hiN++; }
      if (v > av) { av = v; a = i; }
    }
    // Prominence: a star joins the constellation while it is a local spectral peak.
    // PE is a 0..1 envelope (fast in, slow out) so links fade instead of popping.
    var win = N >= 48 ? 2 : 1, eIn = 1 - Math.exp(-dt / 0.04), eOut = 1 - Math.exp(-dt / 0.22), PE = L.PE;
    for (i = 0; i < N; i++) {
      v = V[i];
      var isP = v > PROM_THR, j0 = i - win < 0 ? 0 : i - win, jN = i + win > N - 1 ? N - 1 : i + win;
      for (j = j0; isP && j <= jN; j++) if (j !== i && V[j] > v) isP = false;
      pe = PE[i] + ((isP ? 1 : 0) - PE[i]) * (isP ? eIn : eOut);
      pe = pe < 0.004 ? 0 : pe;
      PE[i] = pe;
      X[i] = L.bx[i] + L.ox[i] * v * lift;
      y = L.by[i] + L.oy[i] * v * lift;
      Y[i] = y < 4 ? 4 : (y > h - 4 ? h - 4 : y);
      R[i] = small ? 0.85 + 1.1 * v * v + 1.5 * pe * v : 1.2 + 1.5 * v * v + 2.3 * pe * v + 0.9 * pe * v * bass;
    }
    var energy = sum / N, hiE = hiN ? hiSum / hiN : 0;
    if (st.tgt >= 0 && st.tgt < N && V[st.tgt] > 0.1 && V[st.tgt] >= av * 0.8) a = st.tgt;  // sticky α
    st.tgt = a; av = V[a];
    var b = -1, cc = -1;
    if (!small) { b = pickOther(V, N, a, -1, st.b); cc = b >= 0 ? pickOther(V, N, a, b, st.c) : -1; }
    st.b = b; st.c = cc;

    // drift phase for the math fragments: advances only with sound
    st.ph = ((st.ph || 0) + dt * (0.35 * energy + 0.8 * bass)) % PH_WRAP;

    // ---- bass onset -> ring at α (hysteresis detector on the smoothed bass)
    if (!st.rings) { st.rings = []; st.arm = true; st.lo = 0; st.hi = 0; st.cool = 0; }
    st.cool = st.cool > dt ? st.cool - dt : 0;
    if (st.arm) {
      if (bass < st.lo) st.lo = bass;
      if (bass > 0.22 && bass - st.lo > 0.12 && st.cool === 0) {
        if (st.rings.length >= 5) st.rings.shift();
        c = cols[a];
        st.rings.push({ x: X[a], y: Y[a], c: [c[0], c[1], c[2]], age: 0, s: Math.min(1, 0.35 + (bass - st.lo) * 2) });
        st.arm = false; st.hi = bass; st.cool = 0.15;
      }
    } else {
      if (bass > st.hi) st.hi = bass;
      if (bass < st.hi - 0.08 || bass < 0.04) { st.arm = true; st.lo = bass; }
    }
    for (k = st.rings.length - 1; k >= 0; k--) {
      st.rings[k].age += dt;
      if (st.rings[k].age >= RING_LIFE) st.rings.splice(k, 1);
    }

    // ---- constellation links: every candidate -> its nearest candidate (distance discounted by
    //      the envelope, so a fading star rarely steals a link), deduped; loud pairs get a 2nd link
    var CI = L.ci, nc = 0, maxD = h * 0.42, nl = 0, p2, q2;
    for (i = 0; i < N; i++) if (PE[i] > 0.04 && V[i] > 0.2) CI[nc++] = i;
    for (p2 = 0; p2 < nc; p2++) {
      i = CI[p2];
      var j1 = -1, d1 = 1e9, j2 = -1, d2 = 1e9;
      for (q2 = 0; q2 < nc; q2++) {
        if (q2 === p2) continue;
        j = CI[q2];
        var dx = X[j] - X[i], dy = Y[j] - Y[i], dd = Math.sqrt(dx * dx + dy * dy);
        if (dd > maxD) continue;
        dd = dd / (0.35 + 0.65 * PE[j]);
        if (dd < d1) { j2 = j1; d2 = d1; j1 = j; d1 = dd; } else if (dd < d2) { j2 = j; d2 = dd; }
      }
      if (j1 >= 0) nl = addLink(L, nl, i, j1);
      if (j2 >= 0 && V[i] > 0.5 && V[j2] > 0.5 && d2 < maxD * 0.8) nl = addLink(L, nl, i, j2);
    }

    ctx.save();
    ctx.lineCap = "round"; ctx.lineJoin = "round";
    ctx.globalAlpha = 1; ctx.globalCompositeOperation = "source-over";

    // ---- 1. formula fragments (static in silence, drift + brighten with sound)
    if (!small) {
      ctx.font = "10px " + MONO; ctx.textBaseline = "middle";
      var tcol = PF.palAt(0.45), ta = 0.17 + 0.25 * bass, ph = st.ph;
      for (k = 0; k < FRAGS.length; k++) {
        var f = FRAGS[k];
        x = f.x * w + Math.sin(ph * 0.5 + k * 2.1) * 9;
        y = f.y * h + Math.sin(ph * 0.375 + k * 1.3) * 2.5;
        ctx.textAlign = f.al;
        ctx.fillStyle = "rgba(0,0,0,0.12)"; ctx.fillText(f.s, x + 0.7, y + 0.7);
        ctx.fillStyle = css(tcol, ta); ctx.fillText(f.s, x, y);
      }
    }

    // ---- 2. planet limb (bottom-right), glow follows treble + bass
    var lk = (small ? 0.3 : 0.28) + 0.42 * (0.55 * hiE + 0.45 * bass);
    ctx.beginPath();
    ctx.arc(w + h * 0.05, h * 1.9, h * 1.35, -Math.PI / 2 - 0.04, -Math.PI / 2 - 0.86, true);
    ctx.strokeStyle = st.limbK; ctx.lineWidth = small ? 2.2 : 2.8; ctx.stroke();
    ctx.strokeStyle = st.limbC;
    if (!small) {
      ctx.lineWidth = 9; ctx.globalAlpha = lk * 0.14; ctx.stroke();
      ctx.lineWidth = 4; ctx.globalAlpha = lk * 0.24; ctx.stroke();
    }
    ctx.lineWidth = small ? 1 : 1.2; ctx.globalAlpha = lk; ctx.stroke();
    ctx.globalAlpha = 1;

    // ---- 3. ecliptic (dotted) + octave ticks
    var sp = L.sp;
    ctx.beginPath(); ctx.moveTo(sp[0], sp[1]);
    for (k = 2; k < sp.length; k += 2) ctx.lineTo(sp[k], sp[k + 1]);
    ctx.setLineDash(small ? [1, 3] : [1.5, 4.5]);
    ctx.strokeStyle = "rgba(0,0,0,0.13)"; ctx.lineWidth = small ? 2 : 2.4; ctx.stroke();
    ctx.strokeStyle = st.G; ctx.lineWidth = 1; ctx.globalAlpha = 0.36 + 0.2 * bass; ctx.stroke();
    ctx.setLineDash([]); ctx.globalAlpha = 1;
    if (!small) {
      var fmin = 30, fmax = 16000;
      if (S.lo && S.hi && S.lo.length >= N && S.hi.length >= N && S.lo[0] > 0 && S.hi[N - 1] > S.lo[0] * 2) { fmin = S.lo[0]; fmax = S.hi[N - 1]; }
      ctx.beginPath();
      for (k = 0; k < DECADES.length; k++) {
        var u = Math.log(DECADES[k] / fmin) / Math.log(fmax / fmin);
        if (!(u > 0.02 && u < 0.98)) continue;
        x = L.padX + u * L.use; y = spineY(u, h);
        var dyu = spineDY(u, h), ln = Math.sqrt(L.use * L.use + dyu * dyu) || 1;
        var nx = -dyu / ln * 4, ny = L.use / ln * 4;
        ctx.moveTo(x - nx, y - ny); ctx.lineTo(x + nx, y + ny);
      }
      ctx.strokeStyle = "rgba(0,0,0,0.15)"; ctx.lineWidth = 2.6; ctx.stroke();
      ctx.strokeStyle = st.G; ctx.lineWidth = 1; ctx.globalAlpha = 0.55; ctx.stroke();
      ctx.globalAlpha = 1;
    }

    // ---- 4. dark halos under every star (one path) — keeps dots readable on light wallpapers
    ctx.beginPath();
    for (i = 0; i < N; i++) {
      var rh = R[i] + 1.4;
      ctx.moveTo(X[i] + rh, Y[i]); ctx.arc(X[i], Y[i], rh, 0, TAU);
    }
    ctx.fillStyle = "rgba(0,0,0,0.2)"; ctx.fill();

    // ---- 5. constellation lines
    var lwL = small ? 0.7 : 1;
    for (k = 0; k < nl; k++) {
      var al = L.lw[k]; if (al < 0.01) continue;
      i = L.la[k]; j = L.lb[k];
      ctx.beginPath(); ctx.moveTo(X[i], Y[i]); ctx.lineTo(X[j], Y[j]);
      ctx.globalAlpha = al * 0.3; ctx.strokeStyle = "#000"; ctx.lineWidth = lwL + 1.8; ctx.stroke();
      ctx.globalAlpha = al; ctx.strokeStyle = st.G; ctx.lineWidth = lwL; ctx.stroke();
    }
    ctx.globalAlpha = 1;

    // ---- 6. asterism α–β–γ (dashed, HUD) — full size only
    if (!small && b >= 0 && cc >= 0) {
      var am = smooth01((Math.min(av, V[b], V[cc]) - 0.4) / 0.3) * 0.32;
      if (am > 0.01) {
        var o3 = [a, b, cc].sort(function (p, q) { return X[p] - X[q]; });
        ctx.beginPath(); ctx.moveTo(X[o3[0]], Y[o3[0]]); ctx.lineTo(X[o3[1]], Y[o3[1]]); ctx.lineTo(X[o3[2]], Y[o3[2]]);
        ctx.setLineDash([2, 4]);
        ctx.strokeStyle = css(BLACK, am * 0.5); ctx.lineWidth = 2.2; ctx.stroke();
        ctx.strokeStyle = css(CYAN, am); ctx.lineWidth = 0.7; ctx.stroke();
        ctx.setLineDash([]);
      }
    }

    // ---- 7. bass rings from α
    var ringR = h * (small ? 0.45 : 0.5);
    for (k = 0; k < st.rings.length; k++) {
      var rg = st.rings[k], p = rg.age / RING_LIFE, q = 1 - p;
      var rad = 3 + ringR * (1 - q * q), ra2 = rg.s * 0.55 * Math.pow(q, 1.5), rlw = 0.5 + 1.3 * q;
      if (ra2 < 0.004) continue;
      ctx.beginPath(); ctx.arc(rg.x, rg.y, rad, 0, TAU);
      ctx.strokeStyle = css(BLACK, ra2 * 0.3); ctx.lineWidth = rlw + 1.6; ctx.stroke();
      ctx.strokeStyle = css(mix(rg.c, WHITE, 0.35), ra2); ctx.lineWidth = rlw; ctx.stroke();
    }

    // ---- 8. star glow (additive, cached unit radial gradients)
    ctx.globalCompositeOperation = "lighter";
    var gk = small ? 4 : 8;
    for (i = 0; i < N; i++) {
      v = V[i]; pe = PE[i];
      var gI = v * v * 0.35 + pe * v * 0.7;
      if (gI < 0.02) continue;
      var gr = R[i] * 2.6 + gk * v * (0.4 + 0.6 * pe) + 4 * bass * pe * v;
      ctx.save();
      ctx.globalAlpha = Math.min(1, gI * (1 + 0.3 * bass));
      ctx.translate(X[i], Y[i]); ctx.scale(gr, gr);
      ctx.fillStyle = st.grads[i];
      ctx.beginPath(); ctx.arc(0, 0, 1, 0, TAU); ctx.fill();
      ctx.restore();
    }
    ctx.globalCompositeOperation = "source-over"; ctx.globalAlpha = 1;

    // ---- 9. star cores (+ diffraction spikes on loud stars)
    var fth = small ? 0.65 : 0.55;
    for (i = 0; i < N; i++) {
      v = V[i]; pe = PE[i]; c = cols[i];
      ctx.fillStyle = css(mix(c, WHITE, 0.22 + (small ? 0.3 : 0.5) * v * (0.4 + 0.6 * pe)), 0.62 + 0.38 * Math.min(1, v * 1.5));
      ctx.beginPath(); ctx.arc(X[i], Y[i], R[i], 0, TAU); ctx.fill();
      if (v > fth && pe > 0.3) {
        var fk = (v - fth) / (1 - fth) * pe, sl = R[i] + 1.5 + fk * (small ? 4 : 9) + 3 * bass * fk;
        ctx.beginPath();
        ctx.moveTo(X[i] - sl, Y[i]); ctx.lineTo(X[i] + sl, Y[i]);
        ctx.moveTo(X[i], Y[i] - sl); ctx.lineTo(X[i], Y[i] + sl);
        ctx.strokeStyle = css(mix(c, WHITE, 0.7), 0.2 + 0.55 * fk); ctx.lineWidth = small ? 0.6 : 0.8; ctx.stroke();
      }
    }

    // ---- 10. peak twinkles: an "x" that hangs just outside the star while the peak cap is above it
    if (!small) {
      ctx.lineWidth = 0.8;
      for (i = 0; i < N; i++) {
        var pv = lvl(pk[i]), gap = pv - V[i];
        if (gap < 0.05 || pv < 0.3 || PE[i] < 0.15) continue;
        var tw = Math.min(1, (gap - 0.05) * 6) * pv * (0.45 + 0.5 * PE[i]);
        if (tw < 0.01) continue;
        var off = pv * lift + 3 + gap * h * 0.09, ts = 1.6 + pv * 2.8;
        x = L.bx[i] + L.ox[i] * off; y = L.by[i] + L.oy[i] * off;
        y = y < 4 ? 4 : (y > h - 4 ? h - 4 : y);
        ctx.beginPath();
        ctx.moveTo(x - ts, y - ts); ctx.lineTo(x + ts, y + ts);
        ctx.moveTo(x + ts, y - ts); ctx.lineTo(x - ts, y + ts);
        ctx.strokeStyle = css(mix(cols[i], WHITE, 0.45), tw); ctx.stroke();
      }
    }

    // ---- 11. α: one blurred core (the frame's only shadowBlur) + reticle + readout
    if (av > 0.05) {
      var ka = smooth01((av - 0.05) / 0.4);
      c = cols[a];
      ctx.shadowBlur = (small ? 4 : 10) + 10 * bass;
      ctx.shadowColor = css(c, 0.9 * ka);
      ctx.fillStyle = css(mix(c, WHITE, 0.7), 0.6 + 0.4 * av);
      ctx.beginPath(); ctx.arc(X[a], Y[a], R[a] * 1.05, 0, TAU); ctx.fill();
      ctx.shadowBlur = 0; ctx.shadowColor = "rgba(0,0,0,0)";
    }
    if (!small) {
      var rk = smooth01((av - 0.18) / 0.35) * 0.8, bx0 = 0, bx1 = -1, by0 = 0, by1 = -1;
      if (st.rx == null || st.ra < 0.02) { st.rx = X[a]; st.ry = Y[a]; }
      else { var e = 1 - Math.exp(-dt / 0.06); st.rx += (X[a] - st.rx) * e; st.ry += (Y[a] - st.ry) * e; }
      st.ra = rk;
      if (rk > 0.01) {
        var rx = st.rx, ry = st.ry, rr0 = R[a] + 6 + 3 * bass;
        ctx.beginPath(); ctx.arc(rx, ry, rr0, 0, TAU);
        for (k = 0; k < 4; k++) {
          var ang = k * Math.PI / 2, cx = Math.cos(ang), sy = Math.sin(ang);
          ctx.moveTo(rx + cx * (rr0 + 1.5), ry + sy * (rr0 + 1.5)); ctx.lineTo(rx + cx * (rr0 + 4.5), ry + sy * (rr0 + 4.5));
        }
        ctx.strokeStyle = css(BLACK, rk * 0.3); ctx.lineWidth = 2.4; ctx.stroke();
        ctx.strokeStyle = css(CYAN, rk); ctx.lineWidth = 0.8; ctx.stroke();

        var fc = (S.fc && S.fc.length > a && S.fc[a] > 0) ? S.fc[a] : 30 * Math.pow(16000 / 30, (a + 0.5) / N);
        var label = "α " + fmtHz(fc);
        ctx.font = "9px " + MONO; ctx.textBaseline = "middle";
        var tw2 = ctx.measureText(label).width || label.length * 5.4;
        var lx = rx + rr0 + 7, ly = ry - rr0 - 2, left = lx + tw2 > w - 4;
        if (left) lx = rx - rr0 - 7;
        if (ly < 7) ly = ry + rr0 + 8;
        ctx.textAlign = left ? "right" : "left";
        ctx.lineWidth = 2.2; ctx.strokeStyle = css(BLACK, rk * 0.32); ctx.strokeText(label, lx, ly);
        ctx.fillStyle = css(CYAN, rk * 0.8); ctx.fillText(label, lx, ly);
        bx0 = left ? lx - tw2 : lx; bx1 = bx0 + tw2; by0 = ly - 6; by1 = ly + 6;
      }
      // β, γ designations
      ctx.font = "9px " + MONO; ctx.textBaseline = "middle"; ctx.textAlign = "left";
      for (k = 0; k < 2; k++) {
        var si = k === 0 ? b : cc;
        if (si < 0) continue;
        var ga = smooth01((V[si] - 0.4) / 0.25) * 0.5;
        if (ga < 0.01) continue;
        x = X[si] + R[si] + 3.5; y = Y[si] - R[si] - 3.5;
        if (y < 6) y = Y[si] + R[si] + 6;
        if (x + 6 > bx0 - 2 && x < bx1 + 2 && y + 5 > by0 && y - 5 < by1) continue;   // never over the α readout
        var g2 = k === 0 ? "\u03B2" : "\u03B3";
        ctx.lineWidth = 2; ctx.strokeStyle = css(BLACK, ga * 0.4); ctx.strokeText(g2, x, y);
        ctx.fillStyle = css(CYAN, ga); ctx.fillText(g2, x, y);
      }
    }

    ctx.restore();
  }

  window.PF_EXTRA = window.PF_EXTRA || [];
  window.PF_EXTRA.push({ id: "constellation", name: "星圖", en: "CONSTELLATION", draw: draw });
})();
