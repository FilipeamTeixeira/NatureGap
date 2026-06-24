import { GREEN_SPACES, type GreenSpace } from './green-spaces';
import { getScoreColor } from './utils';
import { HEX_CONFIG, STORAGE } from './config';
import { supabase } from './supabase';

const HEX_RADIUS_M = HEX_CONFIG.radiusM;

function mToLng(m: number, lat: number) {
  return m / (111_319.5 * Math.cos((lat * Math.PI) / 180));
}
function mToLat(m: number) {
  return m / 111_319.5;
}

/** Ray-casting point-in-polygon test. */
function pointInRing(lng: number, lat: number, ring: [number, number][]): boolean {
  let inside = false;
  for (let i = 0, j = ring.length - 2; i < ring.length - 1; j = i++) {
    const [xi, yi] = ring[i];
    const [xj, yj] = ring[j];
    if ((yi > lat) !== (yj > lat) && lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

function ringBbox(ring: [number, number][]) {
  let minLng = Infinity;
  let maxLng = -Infinity;
  let minLat = Infinity;
  let maxLat = -Infinity;
  for (const [lng, lat] of ring) {
    minLng = Math.min(minLng, lng);
    maxLng = Math.max(maxLng, lng);
    minLat = Math.min(minLat, lat);
    maxLat = Math.max(maxLat, lat);
  }
  return { minLng, maxLng, minLat, maxLat };
}

/**
 * Synthetic residual score for a vegetation cell — used only when the
 * precomputed pipeline hexgrid is not yet available from Supabase.
 *
 * All geography constants below are Yokohama-specific and match the
 * spatial model in pipeline/05_residuals/score.R.
 */
const SYNTH = {
  // Urban-centre reference (Nishi-ku CBD proxy for decay modelling)
  urbanCentreLng: 139.621,
  urbanCentreLat: 35.466,
  urbanCentreCosLat: 35.47,   // latitude used for cos() projection
  urbanDecay: -30,
  urbanDecayRadius: 4_200,    // metres

  // Western green belt
  greenBeltLngThreshold: 139.56,
  greenBeltLatThreshold:  35.43,
  greenBeltMax:           22,
  greenBeltSlope:        210,

  // Northern uplift
  northernLatThreshold: 35.53,
  northernMax:          12,
  northernSlope:       190,

  // Coastal penalty
  coastalLatThreshold:  35.4,
  coastalLngThreshold: 139.6,
  coastalMax:           14,
  coastalSlope:        120,

  // Port zone penalty
  portLngThreshold: 139.655,
  portLatThreshold:  35.47,
  portPenalty:      -18,

  // Noise model coefficients (decorrelate the synthetic scores)
  noiseLng1: 531.3, noiseLat1: 213.7, noiseAmp1: 5,
  noiseLng2: 317.9, noiseLat2: 489.1, noiseAmp2: 3.5,
  noiseLng3: 721.1,                   noiseAmp3: 2,

  // Per-park overrides
  honmokuParkIds: ['honmoku-sancho', 'shinhonmoku-park'] as string[],
  honmokuPenalty: -6,
} as const;

function hexScore(lng: number, lat: number, park: GreenSpace): number {
  const dxM =
    (lng - SYNTH.urbanCentreLng) *
    111_319.5 *
    Math.cos((SYNTH.urbanCentreCosLat * Math.PI) / 180);
  const dyM = (lat - SYNTH.urbanCentreLat) * 111_319.5;
  const distM = Math.sqrt(dxM * dxM + dyM * dyM);
  const urban = SYNTH.urbanDecay * Math.exp(-distM / SYNTH.urbanDecayRadius);

  const green =
    lng < SYNTH.greenBeltLngThreshold && lat > SYNTH.greenBeltLatThreshold
      ? Math.min(SYNTH.greenBeltMax, (SYNTH.greenBeltLngThreshold - lng) * SYNTH.greenBeltSlope)
      : 0;
  const north =
    lat > SYNTH.northernLatThreshold
      ? Math.min(SYNTH.northernMax, (lat - SYNTH.northernLatThreshold) * SYNTH.northernSlope)
      : 0;
  const coast =
    lat < SYNTH.coastalLatThreshold && lng > SYNTH.coastalLngThreshold
      ? -Math.min(SYNTH.coastalMax, (SYNTH.coastalLatThreshold - lat) * SYNTH.coastalSlope)
      : 0;
  const port =
    lng > SYNTH.portLngThreshold && lat > SYNTH.portLatThreshold ? SYNTH.portPenalty : 0;
  const noise =
    Math.sin(lng * SYNTH.noiseLng1 + lat * SYNTH.noiseLat1) * SYNTH.noiseAmp1 +
    Math.cos(lng * SYNTH.noiseLng2 - lat * SYNTH.noiseLat2) * SYNTH.noiseAmp2 +
    Math.sin((lng + lat) * SYNTH.noiseLng3) * SYNTH.noiseAmp3;

  // Port-adjacent parks underperform relative to interior parks
  const honmoku = SYNTH.honmokuParkIds.includes(park.id) ? SYNTH.honmokuPenalty : 0;

  return Math.max(
    HEX_CONFIG.minScore,
    Math.min(HEX_CONFIG.maxScore, Math.round(urban + green + north + coast + port + noise + honmoku)),
  );
}

function hexRing(cx: number, cy: number, rLng: number, rLat: number): [number, number][] {
  const ring: [number, number][] = [];
  for (let v = 0; v < 6; v++) {
    const a = ((30 + 60 * v) * Math.PI) / 180;
    ring.push([cx + rLng * Math.cos(a), cy + rLat * Math.sin(a)]);
  }
  ring.push(ring[0]);
  return ring;
}

/** 10 m hex cells clipped to vegetation polygons only. */
export function buildHexGrid() {
  const features: GeoJSON.Feature[] = [];

  for (const park of GREEN_SPACES) {
    const bbox = ringBbox(park.ring);
    const refLat = (bbox.minLat + bbox.maxLat) / 2;
    const rLng = mToLng(HEX_RADIUS_M, refLat);
    const rLat = mToLat(HEX_RADIUS_M);
    const cs = Math.sqrt(3) * rLng;
    const rs = 1.5 * rLat;

    // Pad bbox so edge hexes aren't missed
    const pad = rs * 2;
    let row = 0;
    for (let cLat = bbox.minLat - pad; cLat <= bbox.maxLat + pad; cLat += rs, row++) {
      const xOff = row % 2 === 1 ? cs / 2 : 0;
      let col = 0;
      for (let cLng = bbox.minLng - pad + xOff; cLng <= bbox.maxLng + pad; cLng += cs, col++) {
        if (!pointInRing(cLng, cLat, park.ring)) continue;

        const score = hexScore(cLng, cLat, park);
        features.push({
          type: 'Feature',
          properties: {
            cellId: `${park.id}-${row}-${col}`,
            score,
            color: getScoreColor(score),
            wardId: park.wardId,
            parkId: park.id,
            parkName: park.name,
          },
          geometry: { type: 'Polygon', coordinates: [hexRing(cLng, cLat, rLng, rLat)] },
        });
      }
    }
  }

  return { type: 'FeatureCollection' as const, features };
}

let cached: ReturnType<typeof buildHexGrid> | null = null;
let runtimeHexGrid: ReturnType<typeof buildHexGrid> | null = null;
let initHexCalled = false;

/**
 * Fetch the precomputed hexgrid.geojson from Supabase Storage.
 * When present, getHexGrid() returns pipeline data instead of the synthetic grid.
 * Call once at app boot.
 */
export async function initHexGrid(): Promise<void> {
  if (initHexCalled || !supabase) return;
  initHexCalled = true;
  try {
    const { data, error } = await supabase.storage
      .from(STORAGE.PIPELINE_BUCKET)
      .download('hexgrid.geojson');
    if (error || !data) return;
    runtimeHexGrid = JSON.parse(await data.text());
  } catch (e) {
    console.warn('[hex-grid] Storage fetch failed, using generated grid:', e);
  }
}

export function getHexGrid() {
  if (runtimeHexGrid) return runtimeHexGrid;
  if (!cached) cached = buildHexGrid();
  return cached;
}

/** Median impact score across all hex cells for a given park. Returns 0 when unknown. */
export function medianScoreForPark(parkId: string): number {
  const scores = getHexGrid()
    .features
    .filter((f) => f.properties?.parkId === parkId)
    .map((f) => Number(f.properties?.score))
    .filter((s) => !Number.isNaN(s))
    .sort((a, b) => a - b);
  return scores.length ? scores[Math.floor(scores.length / 2)] : 0;
}

export { GREEN_SPACES };
