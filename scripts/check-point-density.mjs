/**
 * Point-density calibration check for the vegetation point layer.
 *
 * The vegetation layer draws one symbol per 20 m cell carrying canopy, which
 * risks reading as a regular lattice of dots rather than as vegetation. This
 * script measures the real thing: it decodes the exported hexgrid PMTiles,
 * finds the densest tile at each zoom, replays MapLibre's greedy collision
 * placement using the same icon-size / icon-padding / allow-overlap values as
 * vegetationPointLayout(), and reports the drawn dot diameter against the
 * median nearest-neighbour spacing of the dots that survive.
 *
 * A high-canopy diameter/spacing ratio near or above 1 means dense vegetation
 * merges into a mass; a low ratio at every canopy level means a lattice.
 *
 * Usage:
 *   node scripts/check-point-density.mjs [path/to/hexgrid.pmtiles] [p05] [p95]
 *
 * p05/p95 come from that city's canopy_height_idx row in city_layer_stats.json
 * and default to Porto's. Purely a diagnostic — it reads exports and writes
 * nothing.
 */
import { PMTiles } from 'pmtiles';
import { readFileSync } from 'fs';
import zlib from 'zlib';
import Pbf from 'pbf';
import { VectorTile } from '@mapbox/vector-tile';

const FILE = process.argv[2] ?? 'pipeline-export/porto-center/20260818T042832Z/hexgrid.pmtiles';
const buf = readFileSync(FILE);
class BufSource {
  constructor(b) { this.b = b; }
  getKey() { return FILE; }
  async getBytes(o, l) { return { data: new Uint8Array(this.b.subarray(o, o + l)).buffer }; }
}
const pm = new PMTiles(new BufSource(buf));
const decode = (d0) => {
  let d = new Uint8Array(d0);
  if (d[0] === 0x1f && d[1] === 0x8b) d = zlib.gunzipSync(Buffer.from(d));
  return new VectorTile(new Pbf(d));
};
const TILE_PX = 512, ICON_BOX = 24, ICON_VIS = 18;

const lerp = (stops, t) => {
  if (t <= stops[0][0]) return stops[0][1];
  if (t >= stops[stops.length - 1][0]) return stops[stops.length - 1][1];
  for (let i = 1; i < stops.length; i++) {
    if (t <= stops[i][0]) {
      const [x0, y0] = stops[i - 1], [x1, y1] = stops[i];
      return y0 + (y1 - y0) * (t - x0) / (x1 - x0);
    }
  }
};

// Mirrors vegetationPointLayout()'s icon-size / icon-padding / allow-overlap.
const VEG_SIZE = { 14: [0.50, 0.95], 15: [0.35, 0.85], 16: [0.35, 1.25], 17: [0.70, 2.50], 18: [1.20, 3.50] };
// Defaults are Porto's canopy_height_idx p05/p95 — the same stretch
// canopyStretchedExpression() applies before sizing a dot.
const P05 = Number(process.argv[3] ?? 0), P95 = Number(process.argv[4] ?? 0.1157);
const stretch = (raw) => Math.max(0, Math.min(1, (raw - P05) / (P95 - P05)));
const vegSize = (z, canopy) => { const [lo, hi] = VEG_SIZE[z]; return lo + (hi - lo) * Math.min(1, canopy); };
const vegPadding = (z) => lerp([[14, 1], [16, 0]], z);
const vegOverlap = (z) => z >= 16;

const median = (a) => { if (!a.length) return null; const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };
const nnMedian = (pts) => {
  if (pts.length < 2) return null;
  const s = pts.length > 1200 ? pts.slice(0, 1200) : pts, d = [];
  for (let i = 0; i < s.length; i++) {
    let b = Infinity;
    for (let j = 0; j < s.length; j++) { if (i !== j) { const v = Math.hypot(s[i].x - s[j].x, s[i].y - s[j].y); if (v < b) b = v; } }
    if (b < Infinity) d.push(b);
  }
  return median(d);
};

const lonLatToTile = (lon, lat, z) => {
  const n = 2 ** z, r = lat * Math.PI / 180;
  return [Math.floor((lon + 180) / 360 * n), Math.floor((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * n)];
};
const [cx14, cy14] = lonLatToTile(-8.6123, 41.1593, 14);

console.log('VEGETATION — greedy collision simulation on the densest real tile');
console.log('z   drawn/cells  medianNN  medianDia  dia/NN   highCanopyDia/NN  verdict');

for (let z = 14; z <= 18; z++) {
  const span = 2 ** (z - 14);
  let best = null;
  for (let dx = 0; dx < span; dx++) for (let dy = 0; dy < span; dy++) {
    const t = await pm.getZxy(z, cx14 * span + dx, cy14 * span + dy);
    if (!t) continue;
    const layer = decode(t.data).layers.hexgrid;
    const pts = [];
    for (let i = 0; i < layer.length; i++) {
      const f = layer.feature(i), p = f.properties, g = f.loadGeometry()[0];
      const c = (p.canopyHeightIdx ?? 0);
      if (c <= 0) continue;
      let sx = 0, sy = 0; for (const q of g) { sx += q.x; sy += q.y; }
      const k = TILE_PX / layer.extent;
      pts.push({ x: sx / g.length * k, y: sy / g.length * k, c: stretch(c) });
    }
    if (!best || pts.length > best.length) best = pts;
  }
  if (!best || best.length < 2) { console.log(`z${z}  (too few cells)`); continue; }

  // MapLibre places in ascending sort-key order; sort-key here is 1 - canopy.
  const ordered = [...best].sort((a, b) => (1 - a.c) - (1 - b.c));
  const pad = vegPadding(z), overlap = vegOverlap(z);
  const placed = [];
  for (const p of ordered) {
    const box = vegSize(z, p.c) * ICON_BOX + 2 * pad;
    if (!overlap) {
      let hit = false;
      for (const q of placed) {
        const qb = vegSize(z, q.c) * ICON_BOX + 2 * pad;
        if (Math.abs(p.x - q.x) < (box + qb) / 2 && Math.abs(p.y - q.y) < (box + qb) / 2) { hit = true; break; }
      }
      if (hit) continue;
    }
    placed.push(p);
  }

  const nn = nnMedian(placed);
  const dias = placed.map((p) => vegSize(z, p.c) * ICON_VIS);
  const dia = median(dias);
  const high = placed.filter((p) => p.c >= 0.7).map((p) => vegSize(z, p.c) * ICON_VIS);
  const highDia = high.length ? median(high) : null;
  const ratio = dia / nn, highRatio = highDia ? highDia / nn : null;
  const verdict = (highRatio ?? ratio) >= 0.85 ? 'coalesces  ✓'
    : (highRatio ?? ratio) >= 0.55 ? 'clustered  ✓'
    : 'LATTICE RISK ✗';
  console.log(`z${z}  ${String(placed.length).padStart(4)}/${String(best.length).padEnd(5)} ${nn.toFixed(1).padStart(7)}  ${dia.toFixed(1).padStart(8)}  ${ratio.toFixed(2).padStart(6)}   ${(highRatio ?? NaN).toFixed(2).padStart(14)}   ${verdict}`);
}
