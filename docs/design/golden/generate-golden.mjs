// Golden fixture generator for the PulseFloat DSP pipeline.
//
// The functions below are copied from docs/design/prototype.html (rebuildBands,
// bandsSimulated, processFrame) with two deliberate changes:
//   1. state lives in an explicit object instead of the page's closure, and
//   2. bandsSimulated's Math.random() noise term is injectable (fixtures use 0).
// Everything else — constants, order of operations, Float32 storage — is the
// prototype's. If the prototype changes, update this file and re-run:
//
//   node docs/design/golden/generate-golden.mjs > docs/design/golden/pipeline_golden.json
//
// The Swift port (T02) must reproduce every recorded frame within the
// tolerance stated in the JSON (`tolerance`).

const DEFAULTS = {
  bands:  { count: 64, fMinHz: 30, fMaxHz: 16000, tiltDbPerOct: 3.0 },
  level:  { agc: true, rangeDb: 54, ceilingDb: -12, agcReleaseDbPerSec: 6, gamma: 1.3, gateDb: -90 },
  motion: { attackMs: 12, releaseMs: 140, spatial: 0.35, peakHoldMs: 160, peakGravity: 3.2 },
};
const clone = o => JSON.parse(JSON.stringify(o));

function makeState(P) {
  const N = P.bands.count | 0, f0 = P.bands.fMinHz, f1 = P.bands.fMaxHz;
  const S = { N, fc: new Float32Array(N), lo: new Float32Array(N), hi: new Float32Array(N),
    raw: new Float32Array(N).fill(-160), cur: new Float32Array(N), peak: new Float32Array(N),
    peakT: new Float32Array(N), peakV: new Float32Array(N), tmp: new Float32Array(N), ceil: -12, bass: 0 };
  for (let i = 0; i < N; i++) {
    const a = f0 * Math.pow(f1 / f0, i / N), b = f0 * Math.pow(f1 / f0, (i + 1) / N);
    S.lo[i] = a; S.hi[i] = b; S.fc[i] = Math.sqrt(a * b);
  }
  return S;
}

const SPB = 60 / 128;
function gauss(x, w) { return Math.exp(-(x * x) / (2 * w * w)); }
function bandsSimulated(S, t, noise) {
  const ph = (t / SPB) % 1, kick = Math.exp(-ph * 7), hat = Math.exp(-(((ph + .5) % 1)) * 16);
  const bar = ((Math.floor(t / (SPB * 4)) % 4) + 4) % 4, chordHz = [220, 174.6, 261.6, 196][bar];
  const sweep = 900 * Math.pow(2, Math.sin(t * 0.45) * 2);
  for (let i = 0; i < S.N; i++) {
    const f = S.fc[i], o = Math.log2(f / 60);
    let d = -20 - 4.2 * o;
    d += 16 * kick * gauss(Math.log2(f / 55), .7);
    d += 9 * gauss(Math.log2(f / chordHz), .35) * (0.7 + 0.3 * Math.sin(t * 3));
    d += 7 * gauss(Math.log2(f / sweep), .5);
    d += 11 * hat * gauss(Math.log2(f / 9500), .9);
    d += noise() * 7;
    S.raw[i] = d;
  }
}

function processFrame(P, S, dt) {
  const N = S.N, L = P.level, M = P.motion, tilt = P.bands.tiltDbPerOct;
  let frameMax = -160;
  for (let i = 0; i < N; i++) { const d = S.raw[i] + tilt * Math.log2(S.fc[i] / 1000); S.tmp[i] = d; if (d > frameMax) frameMax = d; }
  if (L.agc) {
    if (frameMax > S.ceil) S.ceil += (frameMax - S.ceil) * (1 - Math.exp(-dt / 0.05));
    else S.ceil -= L.agcReleaseDbPerSec * dt;
    S.ceil = Math.min(6, Math.max(-45, S.ceil));
  } else S.ceil = L.ceilingDb;
  const floor = S.ceil - L.rangeDb;
  for (let i = 0; i < N; i++) {
    const d = S.tmp[i];
    let v = (S.raw[i] < L.gateDb) ? 0 : (d - floor) / L.rangeDb;
    v = v < 0 ? 0 : v > 1 ? 1 : v;
    S.tmp[i] = Math.pow(v, L.gamma);
  }
  const s = M.spatial; let prev = S.tmp[0];
  for (let i = 0; i < N; i++) {
    const c = S.tmp[i], nx = S.tmp[Math.min(N - 1, i + 1)];
    const sm = (1 - s) * c + s * 0.5 * (prev + nx); prev = c; S.tmp[i] = sm;
  }
  if (!(dt > 0)) return;
  const aA = 1 - Math.exp(-dt / (M.attackMs / 1000)), aR = 1 - Math.exp(-dt / (M.releaseMs / 1000));
  let bass = 0, nb = 0;
  for (let i = 0; i < N; i++) {
    const tgt = S.tmp[i], c = S.cur[i];
    const v = c + (tgt - c) * (tgt > c ? aA : aR); S.cur[i] = v;
    if (v >= S.peak[i]) { S.peak[i] = v; S.peakT[i] = 0; S.peakV[i] = 0; }
    else {
      S.peakT[i] += dt;
      if (S.peakT[i] * 1000 > M.peakHoldMs) { S.peakV[i] += M.peakGravity * dt; S.peak[i] -= S.peakV[i] * dt; if (S.peak[i] < v) { S.peak[i] = v; S.peakV[i] = 0; } }
    }
    if (S.fc[i] < 150) { bass += v; nb++; }
  }
  const b = nb ? bass / nb : 0;
  S.bass += (b - S.bass) * (1 - Math.exp(-dt / (b > S.bass ? 0.03 : 0.18)));
}

const r6 = x => Math.round(x * 1e6) / 1e6;
const snap = (S, frame) => ({ frame, ceilDb: r6(S.ceil), bass: r6(S.bass),
  values: Array.from(S.cur, r6), peaks: Array.from(S.peak, r6) });

// Each scenario: config overrides, a per-frame raw-dB source, a dt schedule, and which frames to record.
function run(name, description, overrides, frames, rawAt, dtAt, recordEvery) {
  const P = clone(DEFAULTS);
  for (const g in overrides) Object.assign(P[g], overrides[g]);
  const S = makeState(P);
  const out = [];
  for (let f = 0; f < frames; f++) {
    rawAt(S, f);
    processFrame(P, S, dtAt(f));
    if ((f + 1) % recordEvery === 0 || f === frames - 1) out.push(snap(S, f));
  }
  return { name, description, config: P, frames, recordEvery,
    bandCenterHz: Array.from(S.fc, r6),
    bandLowHz: Array.from(S.lo, r6), bandHighHz: Array.from(S.hi, r6), snapshots: out };
}
const zeroNoise = () => 0;
const DT = 1 / 60;

const scenarios = [
  run("simulated_defaults",
    "Default config, 180 frames at dt=1/60. raw(frame f) = bandsSimulated(t = (f+1)/60) with noise term 0.",
    {}, 180, (S, f) => bandsSimulated(S, (f + 1) * DT, zeroNoise), () => DT, 15),
  run("step_gate_release",
    "Default config. Frames 0-9 raw=-160 (below gate), 10-69 raw=-20 flat, 70-159 raw=-160. dt=1/60. Exercises gate, AGC attack/release, attack/release smoothing, peak hold and gravity.",
    {}, 160, (S, f) => S.raw.fill(f >= 10 && f < 70 ? -20 : -160), () => DT, 5),
  run("fixed_ceiling_no_smoothing",
    "agc=false, ceilingDb=-12, 32 bands 40 Hz-12 kHz, tilt 0, spatial 0, gamma 1. raw_i(f) = -30 + 20*sin(0.37*i + 0.21*f). dt(f) = 1/60 if f is even, 1/120 if f is odd (frame 0 uses 1/60).",
    { bands: { count: 32, fMinHz: 40, fMaxHz: 12000, tiltDbPerOct: 0 }, level: { agc: false, gamma: 1.0 }, motion: { spatial: 0 } },
    90, (S, f) => { for (let i = 0; i < S.N; i++) S.raw[i] = -30 + 20 * Math.sin(0.37 * i + 0.21 * f); },
    f => (f % 2 === 0 ? DT : DT / 2), 10),
  run("zero_dt_frames",
    "Default config. raw = bandsSimulated(t=0.5) every frame (noise 0). dt=1/60 except every 4th frame (f%4==3) where dt=0: values/peaks/bass must not move on dt=0 frames; AGC may not move either.",
    {}, 40, (S) => bandsSimulated(S, 0.5, zeroNoise), f => (f % 4 === 3 ? 0 : DT), 1),
];

console.log(JSON.stringify({
  generator: "docs/design/golden/generate-golden.mjs",
  source: "docs/design/prototype.html (processFrame / rebuildBands / bandsSimulated)",
  tolerance: { absolute: 1e-4, note: "values, peaks, bass, ceilDb; band edges use relative 1e-5" },
  replay: "Build a fresh pipeline from scenario.config (decode it with VisualizerConfig's lenient decoder; initial state: ceilDb -12, rawDb -160, values/peaks/bass 0). Frames are 0-based: for f = 0 ..< frames, write raw(f) into rawDb, then call process(dt: dt(f)). The snapshot with frame = f is the state after that call (values, peaks, bass, ceilDb = pipeline.ceilingDb). Snapshots are recorded when (f+1) % recordEvery == 0 or f == frames-1. raw(f) and dt(f) are given in each scenario's description; time t for bandsSimulated is in seconds.",
  scenarios,
}, null, 1));
