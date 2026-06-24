import { GREEN_SPACES, type GreenSpace } from './green-spaces';
import { getScoreColor } from './utils';

/** Circumradius in metres — 10 m hex cells (pipeline default). */
const HEX_RADIUS_M = 10;

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

/** Residual score for a vegetation cell — mimics pipeline output. */
function hexScore(lng: number, lat: number, park: GreenSpace): number {
  const dxM = (lng - 139.621) * 111_319.5 * Math.cos(35.47 * Math.PI / 180);
  const dyM = (lat - 35.466) * 111_319.5;
  const distM = Math.sqrt(dxM * dxM + dyM * dyM);
  const urban = -30 * Math.exp(-distM / 4_200);

  const green =
    lng < 139.56 && lat > 35.43 ? Math.min(22, (139.56 - lng) * 210) : 0;
  const north = lat > 35.53 ? Math.min(12, (lat - 35.53) * 190) : 0;
  const coast =
    lat < 35.4 && lng > 139.6 ? -Math.min(14, (35.4 - lat) * 120) : 0;
  const port = lng > 139.655 && lat > 35.47 ? -18 : 0;
  const noise =
    Math.sin(lng * 531.3 + lat * 213.7) * 5 +
    Math.cos(lng * 317.9 - lat * 489.1) * 3.5 +
    Math.sin((lng + lat) * 721.1) * 2;

  // Honmoku parks: slightly underperforming (port-adjacent pressure)
  const honmoku =
    park.id === 'sancho-park' || park.id === 'shinhonmoku-park' ? -6 : 0;

  return Math.max(
    -48,
    Math.min(48, Math.round(urban + green + north + coast + port + noise + honmoku)),
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

export function getHexGrid() {
  if (!cached) cached = buildHexGrid();
  return cached;
}

export { GREEN_SPACES };
