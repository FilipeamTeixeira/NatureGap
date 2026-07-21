import { STORAGE } from './config';
import {
  fetchStorageJson,
  listActivePipelineDatasets,
  resolveDatasetFile,
} from './pipeline-manifest';

/**
 * Lightweight per-hex observation point — centroid geometry + counts only,
 * written by the pipeline as hex_observations.geojson. Kept separate from the
 * full cell_attributes.geojson/hexgrid.pmtiles because MapLibre's built-in
 * GeoJSON clustering (`cluster: true`) only works on GeoJSON sources, not the
 * PMTiles vector tiles the full hex grid is served through.
 */
export interface HexObservationProperties {
  cellId: string;
  nObs: number;
  speciesRichnessRaw: number;
  observedRichness: number;
}

let runtimeHexObservations: GeoJSON.FeatureCollection = { type: 'FeatureCollection', features: [] };
let initHexObservationsCalled = false;

function isFeatureCollection(value: unknown): value is GeoJSON.FeatureCollection {
  return (
    typeof value === 'object' &&
    value !== null &&
    (value as GeoJSON.FeatureCollection).type === 'FeatureCollection' &&
    Array.isArray((value as GeoJSON.FeatureCollection).features)
  );
}

async function loadHexObservationsForCity(cityId: string): Promise<GeoJSON.Feature[]> {
  const datasets = await listActivePipelineDatasets();
  const dataset = datasets.find((item) => item.cityId === cityId);
  if (!dataset) return [];

  const data = await fetchStorageJson(resolveDatasetFile(dataset, 'hex_observations.geojson'));
  return isFeatureCollection(data) ? data.features : [];
}

/**
 * Fetch hex-observations GeoJSON for every configured pipeline city.
 */
export async function initHexObservations(): Promise<void> {
  if (initHexObservationsCalled) return;
  initHexObservationsCalled = true;

  try {
    const cityIds = [...STORAGE.PIPELINE_CITY_IDS];
    const perCity = await Promise.all(cityIds.map((cityId) => loadHexObservationsForCity(cityId)));
    const features = perCity.flat();
    if (features.length > 0) {
      runtimeHexObservations = { type: 'FeatureCollection', features };
      console.info(`[hex-observations] Loaded ${features.length} hex observation points across ${cityIds.length} cities`);
    }
  } catch (e) {
    console.warn('[hex-observations] Failed to load hex observations:', e);
  }
}

export function getHexObservationsGeoJSON(): GeoJSON.FeatureCollection {
  return runtimeHexObservations;
}
