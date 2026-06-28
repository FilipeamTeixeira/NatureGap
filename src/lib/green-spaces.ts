import localGreenSpaces from '@/data/green-spaces.json';
import localParkStats from '@/data/park-stats.json';
import { CITY, STORAGE } from './config';
import { parseGreenSpaces, parseParkStats, type ParkStats } from './data-validation';
import {
  fetchStorageJson,
  listActivePipelineDatasets,
  resolveDatasetFile,
} from './pipeline-manifest';
import { fetchPipelineJson, mergeCellChunks } from './storage-fetch';

export interface GreenSpace {
  /** Stable identifier — matches hexgrid `parkId` and park-stats `id`. */
  id: string;
  /** Pipeline city slug this park belongs to. */
  cityId: string;
  /** English display name. */
  name: string;
  /** Japanese display name. */
  nameJa: string;
  /** Yokohama ward slug — matches ALL_WARDS. */
  wardId: string;
  /** Closed polygon ring in [lng, lat] order (WGS-84). */
  ring: [number, number][];
  /** Full source geometry, preserving polygon holes and multipolygons. */
  geometry: GeoJSON.Polygon | GeoJSON.MultiPolygon;
}

let runtimeParks: GreenSpace[] = parseGreenSpaces(localGreenSpaces);
let runtimeParkStats: Record<string, ParkStats> = parseParkStats(localParkStats);
let initParksCalled = false;

function deriveId(props: Record<string, unknown>): string {
  const raw = String(props.id ?? props.osm_id ?? '').trim();
  if (raw && raw !== 'undefined') return raw;
  const name = String(props.name ?? props['name:ja'] ?? props.nameJa ?? '').trim();
  if (name) return name;
  return '';
}

function featureToGreenSpace(f: Record<string, unknown>, cityId: string): GreenSpace | null {
  const props = (f.properties as Record<string, unknown>) ?? {};
  const id = deriveId(props);
  if (!id || id === 'undefined') return null;

  const geom = f.geometry as { type: string; coordinates: unknown } | null;
  if (!geom) return null;

  let ring: [number, number][];
  if (geom.type === 'Polygon') {
    ring = (geom.coordinates as [number, number][][])[0];
  } else if (geom.type === 'MultiPolygon') {
    ring = (geom.coordinates as [number, number][][][])[0][0];
  } else {
    return null;
  }

  if (!ring || ring.length < 4) return null;

  return {
    id,
    cityId,
    name:    String(props.name    ?? id),
    nameJa:  String(props.nameJa  ?? props['name:ja'] ?? props.name ?? id),
    wardId:  String(props.wardId  ?? ''),
    ring,
    geometry: geom as GeoJSON.Polygon | GeoJSON.MultiPolygon,
  };
}

function isFeatureCollection(value: unknown): value is GeoJSON.FeatureCollection {
  return (
    typeof value === 'object' &&
    value !== null &&
    (value as GeoJSON.FeatureCollection).type === 'FeatureCollection' &&
    Array.isArray((value as GeoJSON.FeatureCollection).features)
  );
}

async function loadParksForCity(cityId: string): Promise<GreenSpace[]> {
  const datasets = await listActivePipelineDatasets();
  const dataset = datasets.find((item) => item.cityId === cityId);
  if (dataset) {
    const data = await fetchStorageJson(resolveDatasetFile(dataset, 'parks.geojson'));
    if (isFeatureCollection(data)) {
      return data.features
        .map((feature) => featureToGreenSpace(feature as unknown as Record<string, unknown>, cityId))
        .filter((park): park is GreenSpace => park !== null);
    }
  }

  try {
    const response = await fetch(`/api/vector/${encodeURIComponent(cityId)}/green-spaces`);
    if (response.ok) {
      const data = await response.json();
      if (isFeatureCollection(data)) {
        return data.features
          .map((feature) => featureToGreenSpace(feature as unknown as Record<string, unknown>, cityId))
          .filter((park): park is GreenSpace => park !== null);
      }
    }
  } catch {
    /* optional local fallback */
  }

  return [];
}

/**
 * Fetch parks GeoJSON for every configured pipeline city.
 */
export async function initParks(): Promise<void> {
  if (initParksCalled) return;
  initParksCalled = true;

  try {
    const cityIds = [...STORAGE.PIPELINE_CITY_IDS];
    const perCity = await Promise.all(cityIds.map((cityId) => loadParksForCity(cityId)));
    const parks = perCity.flat();
    if (parks.length > 0) {
      runtimeParks = parks;
      console.info(`[green-spaces] Loaded ${parks.length} parks across ${cityIds.length} cities`);
    }
  } catch (e) {
    console.warn('[green-spaces] Failed to load per-city parks:', e);
  }

  try {
    const stats = await fetchPipelineJson(
      STORAGE.PARK_STATS_KEY,
      'park-stats.manifest.json',
      mergeCellChunks,
    );
    if (stats) {
      runtimeParkStats = parseParkStats(stats);
      console.info(`[green-spaces] Loaded ${Object.keys(runtimeParkStats).length} park stats from Storage`);
    }
  } catch (e) {
    console.warn('[green-spaces] Failed to load park stats:', e);
  }
}

export function getParks(): GreenSpace[] {
  return runtimeParks;
}

export function getParkStats(): Record<string, ParkStats> {
  return runtimeParkStats;
}
