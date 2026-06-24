import { getParks } from './green-spaces';
import { STORAGE } from './config';
import {
  fetchPipelineJson,
  mergeGeoJsonChunks,
} from './storage-fetch';

const EMPTY_GRID: GeoJSON.FeatureCollection = { type: 'FeatureCollection', features: [] };

/** Raw data from Supabase or public assets. */
let rawRuntimeHexGrid: GeoJSON.FeatureCollection | null = null;
/** Filtered + park-attributed grid. */
let filteredHexGrid: GeoJSON.FeatureCollection | null = null;
let initHexCalled = false;

/**
 * Fetch precomputed hexgrid from Supabase Storage or bundled public assets.
 * Supports hexgrid.manifest.json + chunked geojson parts under the 50 MB limit.
 */
export async function initHexGrid(): Promise<void> {
  if (initHexCalled) return;
  initHexCalled = true;

  try {
    const data = await fetchPipelineJson(
      'hexgrid.geojson',
      STORAGE.HEXGRID_MANIFEST_KEY,
      mergeGeoJsonChunks,
    );

    if (data && (data as GeoJSON.FeatureCollection).features?.length) {
      rawRuntimeHexGrid = data as GeoJSON.FeatureCollection;
      console.info(
        `[hex-grid] Loaded ${rawRuntimeHexGrid.features.length} cells from Storage/public`,
      );
    }
  } catch (e) {
    console.warn('[hex-grid] Failed to load pipeline hexgrid:', e);
  }
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

/**
 * Re-assign parkId for city-green cells inside named park polygons.
 * All habitat cells are kept — nothing is clipped away.
 */
export function filterHexGridToParks(): void {
  const raw = rawRuntimeHexGrid;
  if (!raw) return;

  const parks = getParks();
  if (parks.length === 0) {
    filteredHexGrid = raw;
    return;
  }

  const parkIndex = parks.map((p) => ({ park: p, bbox: ringBbox(p.ring) }));

  const features = raw.features.map((f) => {
    const existingParkId = (f.properties?.parkId as string | undefined) ?? '';
    if (existingParkId && existingParkId !== 'city-green') return f;

    const coords = (f.geometry as GeoJSON.Polygon).coordinates[0];
    const lng = coords.reduce((s, p) => s + p[0], 0) / coords.length;
    const lat = coords.reduce((s, p) => s + p[1], 0) / coords.length;

    for (const { park, bbox } of parkIndex) {
      if (lng < bbox.minLng || lng > bbox.maxLng || lat < bbox.minLat || lat > bbox.maxLat) {
        continue;
      }
      if (pointInRing(lng, lat, park.ring)) {
        return {
          ...f,
          properties: { ...f.properties, parkId: park.id, parkName: park.name },
        };
      }
    }

    return f;
  });

  filteredHexGrid = { ...raw, features };
  console.info(`[hex-grid] ${features.length} cells (park labels updated where matched)`);
}

export function getHexGrid(): GeoJSON.FeatureCollection {
  return filteredHexGrid ?? rawRuntimeHexGrid ?? EMPTY_GRID;
}

export function medianScoreForPark(parkId: string): number {
  const scores = getHexGrid()
    .features
    .filter((f) => f.properties?.parkId === parkId)
    .map((f) => Number(f.properties?.score))
    .filter((s) => !Number.isNaN(s))
    .sort((a, b) => a - b);
  return scores.length ? scores[Math.floor(scores.length / 2)] : 0;
}

export function medianHexForPark(parkId: string): { cellId: string; score: number } | null {
  const cells = getHexGrid()
    .features
    .filter((f) => f.properties?.parkId === parkId)
    .map((f) => ({
      cellId: String(f.properties?.cellId ?? ''),
      score: Number(f.properties?.score),
    }))
    .filter((c) => c.cellId && !Number.isNaN(c.score))
    .sort((a, b) => a.score - b.score);

  if (!cells.length) return null;
  return cells[Math.floor(cells.length / 2)];
}
