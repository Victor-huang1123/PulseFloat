/* concept: MÖBIUS / 無限 — lab-style slatted figure-eight sculpture in real 3D (three.js r128),
 * inspired by the Rhine Lab sculpture look (ribbon form only; no logo).
 * Geometry: Bernoulli lemniscate (symmetric lobes), z = 0.28·sin t so the lobes pass over/under at the crossing,
 * a half-twist ribbon made of ~300 thin fins (InstancedMesh of boxes), lit by a key/fill/hemisphere rig with a soft
 * ground shadow (ShadowMaterial) so it sits on any wallpaper.
 * Audio: band energy lengthens fins (low band → left lobe, high → right lobe); bass onsets launch a pulse from the
 * crossing that brightens fins; the sculpture only sways (symmetrically around front view) while there is sound.
 * Silence: no pulses, no sway, fins at rest → a perfectly still sculpture; the frame is not even re-rendered.
 * Materials (window.PF.mobiusStyle): "porcelain" (default), "graphite", "palette" (follows the active palette).
 * Fallback: if three.js is unavailable, draws the 2D slat version.
 *
 * Swift port notes: SceneKit/RealityKit in a transparent view — one SCNNode per fin or a single geometry with a
 * per-vertex colour buffer rebuilt per frame (300 boxes = 7 200 vertices), a directional light with soft shadow on a
 * shadow-only floor (SCNFloor + shadow-only lighting model). Update only when energy/pulses change.
 */
(function () {
  window.PF_EXTRA = window.PF_EXTRA || [];
  window.PF = window.PF || {};
  if (!window.PF.mobiusStyle) window.PF.mobiusStyle = "porcelain";

  const TAU = Math.PI * 2;
  const CREAM = [242, 238, 228];
  const LIME = [226, 240, 150];

  function lemniscate(t, out) {
    const s = Math.sin(t), c = Math.cos(t), d = 1 + s * s;
    out[0] = c / d; out[1] = (s * c) / d; out[2] = 0.28 * s;
    return out;
  }

  // Frames for M fins: position, width dir W, fin-height dir N, tangent T; u ∈ [0,1) starts at the crossing.
  function buildFrames(M) {
    const f = { M, P: [], W: [], N: [], T: [], u: new Float32Array(M), spacing: 0 };
    const a = [0, 0, 0], b = [0, 0, 0], p = [0, 0, 0];
    let length = 0, prev = null;
    for (let i = 0; i < M; i++) {
      const u = i / M, t = Math.PI / 2 + u * TAU;
      lemniscate(t, p); lemniscate(t - 0.002, a); lemniscate(t + 0.002, b);
      let tx = b[0] - a[0], ty = b[1] - a[1], tz = b[2] - a[2];
      const tl = Math.hypot(tx, ty, tz) || 1; tx /= tl; ty /= tl; tz /= tl;
      // base width = tangent × viewDir(0,0,1) (lies in the picture plane), n0 = width × tangent
      let bx = ty, by = -tx, bz = 0; const bl = Math.hypot(bx, by) || 1; bx /= bl; by /= bl;
      const nx = by * tz - bz * ty, ny = bz * tx - bx * tz, nz = bx * ty - by * tx;
      const twist = u * Math.PI + 0.35 * Math.sin(u * TAU * 2);
      const ct = Math.cos(twist), st = Math.sin(twist);
      const W = [bx * ct + nx * st, by * ct + ny * st, bz * ct + nz * st];
      const T = [tx, ty, tz];
      const N = [T[1] * W[2] - T[2] * W[1], T[2] * W[0] - T[0] * W[2], T[0] * W[1] - T[1] * W[0]];
      f.P.push([p[0], p[1], p[2]]); f.W.push(W); f.N.push(N); f.T.push(T); f.u[i] = u;
      if (prev) length += Math.hypot(p[0] - prev[0], p[1] - prev[1], p[2] - prev[2]);
      prev = [p[0], p[1], p[2]];
    }
    f.spacing = length / (M - 1);
    return f;
  }

  function bandEnergy(S, u) {
    const N = S.N | 0;
    if (N <= 0 || !S.cur) return 0;
    const x = Math.min(N - 1, Math.max(0, u * N)), i = Math.floor(x), j = Math.min(N - 1, i + 1), fr = x - i;
    const v = (+S.cur[i] || 0) * (1 - fr) + (+S.cur[j] || 0) * fr;
    return v < 0.004 ? 0 : Math.min(1, v);
  }

  // Shared audio-driven animation state per canvas (pulses, sway angle).
  function stepAnimation(st, S, t) {
    const dt = Math.min(0.05, Math.max(0, (t - (st.lastT ?? t)) || 0));
    st.lastT = t;
    const bass = Math.min(1, Math.max(0, +S.bass || 0));
    let energy = 0; const N = S.N | 0;
    for (let i = 0; i < N; i++) energy += Math.min(1, Math.max(0, +S.cur[i] || 0));
    energy = N > 0 ? energy / N : 0;
    if (energy < 0.01) energy = 0;
    st.energy = energy;
    st.angle = (st.angle || 0) + dt * energy * 0.9;
    if (energy === 0) st.angle *= Math.exp(-dt * 0.6); // ease back toward the symmetric front view, then stop
    if (Math.abs(st.angle) < 1e-4) st.angle = 0;
    st.pulses = st.pulses || [];
    if (st.armed !== false && bass > 0.55 && bass > (st.prevBass || 0) + 0.02) { st.pulses.push({ u: 0, a: bass }); st.armed = false; }
    if (bass < 0.35) st.armed = true;
    st.prevBass = bass;
    for (const p of st.pulses) { p.u += dt * 0.55; p.a *= Math.exp(-dt * 0.9); }
    st.pulses = st.pulses.filter(p => p.u < 1.05 && p.a > 0.02);
  }

  function pulseAt(st, u) {
    let v = 0;
    for (const p of st.pulses) { const d = u - p.u; v += p.a * Math.exp(-(d * d) / 0.0012); }
    return Math.min(1.5, v);
  }

  // ---------- three.js renderer (one per size class, shared across canvases) ----------
  const renderers = {};
  function getRig(key, wPx, hPx) {
    const THREE = window.THREE;
    let rig = renderers[key];
    if (!rig) {
      const renderer = new THREE.WebGLRenderer({ alpha: true, antialias: true, preserveDrawingBuffer: true });
      renderer.setPixelRatio(1);
      renderer.setClearColor(0x000000, 0);
      renderer.outputEncoding = THREE.sRGBEncoding;
      renderer.toneMapping = THREE.ACESFilmicToneMapping;
      renderer.toneMappingExposure = 1.05;
      renderer.shadowMap.enabled = true;
      renderer.shadowMap.type = THREE.PCFSoftShadowMap;
      const scene = new THREE.Scene();
      const camera = new THREE.PerspectiveCamera(28, wPx / hPx, 0.1, 50);
      camera.position.set(0, 0.55, 5.2);
      camera.lookAt(0, -0.05, 0);
      scene.add(new THREE.HemisphereLight(0xfff8ee, 0x5e5953, 0.62));
      const keyLight = new THREE.DirectionalLight(0xffffff, 1.05);
      keyLight.position.set(-2.2, 3.4, 3.6);
      keyLight.castShadow = true;
      keyLight.shadow.mapSize.set(1024, 1024);
      keyLight.shadow.camera.left = -3; keyLight.shadow.camera.right = 3; keyLight.shadow.camera.top = 3; keyLight.shadow.camera.bottom = -3;
      keyLight.shadow.radius = 4; keyLight.shadow.bias = -0.0008;
      scene.add(keyLight);
      const fill = new THREE.DirectionalLight(0xffefe0, 0.38);
      fill.position.set(3, 0.6, 2.4);
      scene.add(fill);
      const floor = new THREE.Mesh(new THREE.PlaneGeometry(14, 14), new THREE.ShadowMaterial({ opacity: 0.17 }));
      floor.rotation.x = -Math.PI / 2;
      floor.position.y = -1.0;
      floor.receiveShadow = true;
      scene.add(floor);
      const group = new THREE.Group();
      group.rotation.x = -0.32;
      scene.add(group);
      rig = renderers[key] = { renderer, scene, camera, group, mesh: null, M: 0, frames: null, style: "", w: 0, h: 0 };
    }
    if (rig.w !== wPx || rig.h !== hPx) {
      rig.renderer.setSize(wPx, hPx, false);
      rig.camera.aspect = wPx / hPx;
      // fit: keep the sculpture at ~78% of the width, but never taller than the frame allows
      const visibleH = 2 * 5.2 * Math.tan((28 * Math.PI / 180) / 2);
      const visibleW = visibleH * rig.camera.aspect;
      rig.group.scale.setScalar(Math.min(0.78 * visibleW / 2, 0.78 * visibleH / 0.95));
      rig.camera.updateProjectionMatrix();
      rig.w = wPx; rig.h = hPx;
    }
    return rig;
  }

  function ensureMesh(rig, M, styleName) {
    const THREE = window.THREE;
    if (rig.mesh && rig.M === M && rig.style === styleName) return;
    if (rig.mesh) { rig.group.remove(rig.mesh); rig.mesh.geometry.dispose(); rig.mesh.material.dispose(); }
    const graphite = styleName === "graphite";
    const material = new THREE.MeshStandardMaterial({
      color: 0xffffff,
      roughness: graphite ? 0.38 : 0.58,
      metalness: graphite ? 0.35 : 0.04,
    });
    const mesh = new THREE.InstancedMesh(new THREE.BoxGeometry(1, 1, 1), material, M);
    mesh.castShadow = true;
    mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    rig.group.add(mesh);
    rig.mesh = mesh; rig.M = M; rig.style = styleName;
    rig.frames = buildFrames(M);
    rig.dirty = true;
  }

  const tmp = {};
  function baseColor(styleName, u) {
    if (styleName === "graphite") return [44, 44, 48];
    if (styleName === "palette" && window.PF.palAt) {
      const c = window.PF.palAt(u);
      return [c[0] * 0.75 + CREAM[0] * 0.25, c[1] * 0.75 + CREAM[1] * 0.25, c[2] * 0.75 + CREAM[2] * 0.25];
    }
    return CREAM;
  }

  function draw3D(ctx, w, h, o) {
    const THREE = window.THREE;
    const PF = window.PF, S = PF.S, st = o.state;
    const small = !!o.small;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const wPx = Math.max(2, Math.round(w * dpr)), hPx = Math.max(2, Math.round(h * dpr));
    const rig = getRig(small ? "thumb" : "main", wPx, hPx);
    const styleName = PF.mobiusStyle || "porcelain";
    const M = small ? 140 : 300;
    ensureMesh(rig, M, styleName);
    stepAnimation(st, S, o.t);

    // Signature of everything that changes the image; skip rendering when nothing changed (silence = still).
    const sig = `${wPx}x${hPx}|${styleName}|${M}|${st.angle.toFixed(4)}|${st.energy.toFixed(3)}|${st.pulses.length}|${PF.paletteKey || ""}`;
    const moving = st.energy > 0 || st.pulses.length > 0;
    if (moving || rig.dirty || st.sig !== sig || rig.lastOwner !== st) {
      const f = rig.frames, m = new THREE.Matrix4(), col = new THREE.Color();
      const finDepth = f.spacing * 0.38;
      const vW = new THREE.Vector3(), vN = new THREE.Vector3(), vT = new THREE.Vector3();
      for (let i = 0; i < M; i++) {
        const u = f.u[i], e = bandEnergy(S, u), pu = pulseAt(st, u);
        const half = 0.085 * (1 + 1.5 * e + 0.55 * pu);
        const finH = 0.05 * (1 + 0.7 * e + 0.4 * pu);
        vW.fromArray(f.W[i]); vN.fromArray(f.N[i]); vT.fromArray(f.T[i]);
        m.makeBasis(vW, vN, vT);
        m.scale(new THREE.Vector3(half * 2, finH, finDepth));
        m.setPosition(f.P[i][0], f.P[i][1], f.P[i][2]);
        rig.mesh.setMatrixAt(i, m);
        const base = baseColor(styleName, u);
        const g = Math.min(1, pu * 0.9 + e * (styleName === "graphite" ? 0.25 : 0.1));
        col.setRGB(
          (base[0] * (1 - g) + LIME[0] * g) / 255,
          (base[1] * (1 - g) + LIME[1] * g) / 255,
          (base[2] * (1 - g) + LIME[2] * g) / 255
        ).convertSRGBToLinear();
        rig.mesh.setColorAt(i, col);
      }
      rig.mesh.instanceMatrix.needsUpdate = true;
      if (rig.mesh.instanceColor) rig.mesh.instanceColor.needsUpdate = true;
      rig.group.rotation.y = 0.28 * Math.sin(st.angle);
      rig.renderer.render(rig.scene, rig.camera);
      rig.dirty = false; rig.lastOwner = st; st.sig = sig;
    }
    ctx.clearRect(0, 0, w, h);
    ctx.drawImage(rig.renderer.domElement, 0, 0, w, h);
    if (!small && h >= 120) drawLabels(ctx, w, h, st.energy);
  }

  function drawLabels(ctx, w, h, energy) {
    ctx.save();
    ctx.font = '500 9px ui-monospace, "SF Mono", Menlo, monospace';
    const label = (text, x, y, align) => {
      ctx.textAlign = align;
      ctx.lineWidth = 2.5; ctx.strokeStyle = "rgba(20,18,16,0.35)"; ctx.strokeText(text, x, y);
      ctx.fillStyle = "rgba(242,238,228,0.8)"; ctx.fillText(text, x, y);
    };
    label("SPECIMEN ∞ — ANALYSIS", 14, 18, "left");
    const level = energy > 0 ? (20 * Math.log10(Math.max(1e-4, energy))).toFixed(1) + " dB" : "—∞ dB";
    label(`LVL ${level}`, w - 14, 18, "right");
    label("LOW ◂", 14, h - 12, "left");
    label("▸ HIGH", w - 14, h - 12, "right");
    ctx.restore();
  }

  // ---------- 2D fallback (symmetric front view) ----------
  function draw2D(ctx, w, h, o) {
    const S = window.PF.S, st = o.state, small = !!o.small;
    const M = small ? 110 : 280;
    if (!st.frames2d || st.frames2d.M !== M) st.frames2d = buildFrames(M);
    stepAnimation(st, S, o.t);
    const f = st.frames2d;
    const yaw = 0.28 * Math.sin(st.angle), pitch = 0.42;
    const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
    const rot = (v) => { const x1 = v[0] * cy + v[2] * sy, z1 = -v[0] * sy + v[2] * cy; return [x1, v[1] * cp - z1 * sp, v[1] * sp + z1 * cp]; };
    const scale = Math.min(w * 0.4, h * 1.02), cx0 = w / 2, cy0 = h / 2;
    const items = [];
    for (let i = 0; i < M; i++) {
      const u = f.u[i], e = bandEnergy(S, u), pu = pulseAt(st, u);
      const P = rot(f.P[i]), W = rot(f.W[i]), N = rot(f.N[i]);
      const half = 0.085 * (1 + 1.5 * e + 0.55 * pu);
      const shade = 0.58 + 0.42 * Math.abs(N[0] * -0.45 + N[1] * -0.65 + N[2] * 0.62);
      items.push({ z: P[2], ax: cx0 + (P[0] + W[0] * half) * scale, ay: cy0 - (P[1] + W[1] * half) * scale,
        bx: cx0 + (P[0] - W[0] * half) * scale, by: cy0 - (P[1] - W[1] * half) * scale, shade, g: Math.min(1, pu) });
    }
    items.sort((a, b) => a.z - b.z);
    ctx.clearRect(0, 0, w, h);
    const lw = Math.max(0.8, (scale * TAU * 0.62) / M * 0.72);
    for (const it of items) {
      ctx.strokeStyle = `rgba(46,42,38,${0.2 + 0.25 * (1 - it.shade)})`; ctx.lineWidth = lw + 0.7;
      ctx.beginPath(); ctx.moveTo(it.ax, it.ay); ctx.lineTo(it.bx, it.by); ctx.stroke();
      const r = CREAM[0] * it.shade * (1 - it.g) + LIME[0] * it.g, g = CREAM[1] * it.shade * (1 - it.g) + LIME[1] * it.g, b = CREAM[2] * it.shade * (1 - it.g) + LIME[2] * it.g;
      ctx.strokeStyle = `rgb(${r | 0},${g | 0},${b | 0})`; ctx.lineWidth = lw;
      ctx.beginPath(); ctx.moveTo(it.ax, it.ay); ctx.lineTo(it.bx, it.by); ctx.stroke();
    }
    if (!small && h >= 120) drawLabels(ctx, w, h, st.energy);
  }

  function draw(ctx, w, h, o) {
    if (window.THREE && !window.PF.mobiusNo3D) {
      try { draw3D(ctx, w, h, o); return; } catch (e) { window.PF.mobiusNo3D = true; console.warn("MÖBIUS 3D unavailable, using 2D", e); }
    }
    draw2D(ctx, w, h, o);
  }

  window.PF_EXTRA.push({ id: "mobius", name: "無限", en: "MÖBIUS 3D", draw });
})();
